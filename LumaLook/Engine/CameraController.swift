import Foundation
import AVFoundation
import CoreImage
import Photos
import SwiftUI

/// Post-MVP camera (SPEC_ADDENDUM §4): the live preview is filtered through
/// the shared LookPipeline, and recording bakes the look in by writing the
/// filtered frames with AVAssetWriter. What you see is what you record.
final class CameraController: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var isRecording = false
    @Published var permissionDenied = false
    @Published var cameraUnavailable = false
    @Published var lastSavedToPhotos = false
    /// The finished recording, kept for the hand-off card (Grade / Edit).
    @Published var lastRecordingURL: URL?
    @Published var previewImage: CGImage?

    /// Injected from AppModel so camera, preview and export share one grade.
    var lookState: LookState?

    /// Live zoom readout for the HUD (1.0x / 2.0x / 3.0x cycle).
    @Published var zoomFactor: CGFloat = 1
    /// Which camera feeds the session (flip toggles it).
    @Published var cameraPosition: AVCaptureDevice.Position = .back

    let session = AVCaptureSession()
    private var activeVideoDevice: AVCaptureDevice?    // sessionQueue only
    private var activeVideoInput: AVCaptureDeviceInput?  // sessionQueue only
    private let sessionQueue = DispatchQueue(label: "com.emotiveimpact.lumalook.camera.session")
    private let mediaQueue = DispatchQueue(label: "com.emotiveimpact.lumalook.camera.media")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let pipeline = LookPipeline.shared
    private var configured = false // sessionQueue only

    // Writer state — touched only on mediaQueue.
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAudio: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStarted = false
    private var wantsRecording = false
    private var outputURL: URL?

    // MARK: - Permissions & lifecycle

    func requestAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startSession() : (self?.permissionDenied = true)
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in self?.cameraUnavailable = true }
            return
        }
        session.addInput(videoInput)
        activeVideoDevice = device
        activeVideoInput = videoInput

        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: mediaQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90   // portrait-upright buffers
        }

        audioOutput.setSampleBufferDelegate(self, queue: mediaQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        session.commitConfiguration()
        configured = true
    }

    // MARK: - Zoom & flip (were placebo buttons — now real)

    /// Cycles 1x → 2x → 3x → 1x, clamped to what the device supports.
    func cycleZoom() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            let next: CGFloat = self.zoomFactor >= 2.5 ? 1 : (self.zoomFactor >= 1.5 ? 3 : 2)
            let clamped = min(next, device.maxAvailableVideoZoomFactor)
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: clamped, withRate: 8)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch {}
        }
    }

    /// Switches front/back. Blocked while recording (the writer's frame
    /// geometry must stay stable for the whole take).
    func flipCamera() {
        guard !isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let target: AVCaptureDevice.Position = self.cameraPosition == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                       for: .video, position: target),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            self.session.beginConfiguration()
            if let current = self.activeVideoInput {
                self.session.removeInput(current)
            }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.activeVideoDevice = device
                self.activeVideoInput = input
            } else if let current = self.activeVideoInput {
                self.session.addInput(current)   // roll back
            }
            if let connection = self.videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                connection.isVideoMirrored = target == .front
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                self.cameraPosition = target
                self.zoomFactor = 1
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.isRunning = false }
        }
    }

    // MARK: - Recording (baked-in look)

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard isRunning else { return }
        lastSavedToPhotos = false
        isRecording = true
        mediaQueue.async { [weak self] in
            self?.beginWriter()
        }
    }

    func stopRecording() {
        isRecording = false
        mediaQueue.async { [weak self] in
            self?.finishWriter()
        }
    }

    /// mediaQueue only.
    private func beginWriter() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Live_\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920
            ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true

        if writer.canAdd(video) { writer.add(video) }
        if writer.canAdd(audio) { writer.add(audio) }
        guard writer.startWriting() else { return }

        self.writer = writer
        self.writerVideo = video
        self.writerAudio = audio
        self.pixelAdaptor = adaptor
        self.writerStarted = false
        self.outputURL = url
        self.wantsRecording = true
    }

    /// mediaQueue only.
    private func finishWriter() {
        wantsRecording = false
        guard let writer, writer.status == .writing, let url = outputURL else {
            cleanupWriter()
            return
        }
        writerVideo?.markAsFinished()
        writerAudio?.markAsFinished()
        writer.finishWriting { [weak self] in
            let succeeded = writer.status == .completed
            self?.cleanupWriter()
            guard succeeded else { return }
            DispatchQueue.main.async { self?.lastRecordingURL = url }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { return }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, _ in
                    DispatchQueue.main.async { self?.lastSavedToPhotos = success }
                }
            }
        }
    }

    private func cleanupWriter() {
        writer = nil
        writerVideo = nil
        writerAudio = nil
        pixelAdaptor = nil
        writerStarted = false
        outputURL = nil
    }
}

// MARK: - Frame processing

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let graded: CIImage
        if let lookState {
            graded = pipeline.apply(state: lookState, to: source.clampedToExtent(), includeSplit: false)
                .cropped(to: source.extent)
        } else {
            graded = source
        }

        appendVideo(graded, sourceExtent: source.extent,
                    time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        publishPreview(graded)
    }

    /// mediaQueue. Writes the graded frame when recording.
    private func appendVideo(_ image: CIImage, sourceExtent: CGRect, time: CMTime) {
        guard wantsRecording,
              let writer, writer.status == .writing,
              let input = writerVideo, let adaptor = pixelAdaptor,
              let pool = adaptor.pixelBufferPool else { return }

        if !writerStarted {
            writer.startSession(atSourceTime: time)
            writerStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }

        // Aspect-fill the graded frame into the 1080x1920 output.
        let target = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let scale = max(target.width / sourceExtent.width, target.height / sourceExtent.height)
        var frame = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        frame = frame.transformed(by: CGAffineTransform(
            translationX: (target.width - frame.extent.width) / 2 - frame.extent.minX,
            y: (target.height - frame.extent.height) / 2 - frame.extent.minY))

        pipeline.context.render(frame.cropped(to: target), to: buffer,
                                bounds: target, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        adaptor.append(buffer, withPresentationTime: time)
    }

    /// mediaQueue. Audio passthrough while recording.
    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard wantsRecording, writerStarted,
              let writer, writer.status == .writing,
              let input = writerAudio, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Renders a downscaled preview frame and publishes it to SwiftUI.
    private func publishPreview(_ image: CIImage) {
        var preview = image
        let longest = max(preview.extent.width, preview.extent.height)
        if longest > 1280 {
            let scale = 1280 / longest
            preview = preview.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = pipeline.context.createCGImage(preview, from: preview.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.previewImage = cg
        }
    }
}

// MARK: - SwiftUI filtered preview

struct FilteredCameraPreview: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        GeometryReader { geo in
            if let frame = camera.previewImage {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Color.black
            }
        }
    }
}

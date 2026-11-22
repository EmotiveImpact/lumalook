import Foundation
import AVFoundation
import CoreImage
import CoreMotion
import ImageIO
import Photos
import SwiftUI

/// Post-MVP camera (SPEC_ADDENDUM §4): the live preview is filtered through
/// the shared LookPipeline, and recording bakes the look in by writing the
/// filtered frames with AVAssetWriter. What you see is what you record.
final class CameraController: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var isRecording = false
    @Published private(set) var isPreparingRecording = false
    @Published private(set) var recordingError: String?
    @Published var permissionDenied = false
    @Published private(set) var microphoneDenied = false
    @Published var cameraUnavailable = false
    @Published var lastSavedToPhotos = false
    /// The finished recording, kept for the hand-off card (Grade / Edit).
    @Published var lastRecordingURL: URL?
    @Published var previewImage: CGImage?
    /// The histogram pill's data, sampled from the graded preview about four
    /// times a second while `histogramOn`.
    @Published private(set) var histogram: CameraHistogram?
    /// Whether the histogram pill shows. On by default, like the pill, so
    /// sampling never waits on the screen to switch it on.
    var histogramOn = true
    /// Frames since the last histogram sample (preview queue only).
    private var histogramTick = 0

    /// Injected from AppModel so camera, preview and export share one grade.
    var lookState: LookState?

    /// C3 — the capture format the user ASKED for (resolution / fps / codec),
    /// persisted. The format picker shows this.
    @Published var spec = CameraSpec.load()
    /// What the sensor is actually delivering. A camera that cannot do the
    /// request (4K on the front camera, 60 fps at a size that tops out at 30)
    /// falls back, and the HUD and the recording follow the fallback: the
    /// writer used to record the REQUESTED size, upscaling a 1080 feed to 4K
    /// while the chip claimed 4K.
    @Published private(set) var activeSpec = CameraSpec.load()
    /// Highest frame rate the current camera offers at each resolution; a
    /// resolution it cannot shoot is absent. Drives which format options the
    /// picker enables.
    @Published private(set) var maxFrameRates: [CameraSpec.Resolution: Double] = [:]

    // MARK: Night Lab capture modes (slo-mo, photo format, portrait)

    /// The fastest slow-motion rate this camera offers (120 or 240), nil when
    /// it has no high-frame-rate format. Drives whether Slo-mo is offered.
    @Published private(set) var slowMotionFPS: Int?
    /// True while the sensor is running the slow-motion format.
    @Published private(set) var isSlowMotion = false
    /// True while a finished slow-motion take is being conformed to 30 fps.
    @Published private(set) var isConformingSlowMo = false
    /// HEIF / JPEG and the requested size, persisted.
    @Published private(set) var photoSpec = PhotoCaptureSpec.load()
    /// Photo sizes the current camera format can deliver (12 / 24 / 48 MP).
    @Published private(set) var photoSizes: [PhotoCaptureSpec.Size] = []
    /// The size stills are actually captured at (after any fallback).
    @Published private(set) var activePhotoSize: PhotoCaptureSpec.Size?
    /// Megapixels of what is actually captured, for an honest chip.
    @Published private(set) var activePhotoMegapixels = PhotoCaptureSpec.load().size.rawValue
    /// True when this camera can deliver depth with a still (Portrait).
    @Published private(set) var depthSupported = false
    /// sessionQueue only.
    private var wantsSlowMotion = false
    private var wantsDepth = false
    private var requestedPhotoSize = PhotoCaptureSpec.load().size
    /// mediaQueue only: preview throttle at high frame rates, and the
    /// slow-down factor of the take being written (1 = real time).
    private var previewTick = 0
    private var recordSlowFactor: Double = 1
    /// sessionQueue writes, mediaQueue reads at record start.
    private let deliveredLock = NSLock()
    private var _deliveredSpec = CameraSpec.load()
    private var deliveredSpec: CameraSpec {
        get { deliveredLock.lock(); defer { deliveredLock.unlock() }; return _deliveredSpec }
        set { deliveredLock.lock(); _deliveredSpec = newValue; deliveredLock.unlock() }
    }
    /// C8/C9 — viewfinder assists (preview-only; never recorded).
    @Published var peakingOn = false
    @Published var zebrasOn = false
    /// C12 — live mic level 0…1 for the HUD meter (dB-mapped, throttled).
    @Published var audioLevel: Double = 0
    private var audioLevelTick = 0   // mediaQueue only

    /// C4 — physical orientation (the UI is portrait-locked; gravity tells the
    /// truth when the phone is held sideways). Sampled at record start.
    @Published var isLandscape = false
    /// Which way the phone is tilted: connection angle 0 vs 180 (sign of
    /// gravity.x). Exact mapping flagged for device QA — one flip if inverted.
    private var landscapeAngle: CGFloat = 0
    private let orientationMotion = CMMotionManager()

    private func startOrientationTracking() {
        guard orientationMotion.isDeviceMotionAvailable else { return }
        orientationMotion.deviceMotionUpdateInterval = 0.25
        orientationMotion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            // Sideways when gravity pulls mostly along the device's x axis.
            let landscape = abs(g.x) > abs(g.y) * 1.2
            if landscape { self.landscapeAngle = g.x > 0 ? 0 : 180 }
            if landscape != self.isLandscape { self.isLandscape = landscape }
        }
    }

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
    /// C5 — real sensor-resolution stills (the old path saved the ~1MP preview).
    private let photoOutput = AVCapturePhotoOutput()
    private var stillCompletion: ((CapturedStill?) -> Void)?   // sessionQueue set, delegate read
    /// What the in-flight still was asked for (format, portrait aperture).
    private var stillRequest: StillRequest?
    private let pipeline = LookPipeline.shared
    private var configured = false // sessionQueue only

    // Writer state — touched only on mediaQueue.
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAudio: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStarted = false
    private var wantsRecording = false
    /// Main-thread intent and media-queue execution are kept separate so the
    /// delayed session-rotation hop cannot resurrect a cancelled start.
    private var requestedRecordingID: UUID?
    private var activeRecordingID: UUID? // mediaQueue only
    private var outputURL: URL?
    /// Output geometry for the CURRENT take (from spec at record start).
    private var recordSize = CGSize(width: 1080, height: 1920)
    /// C4 — take orientation, committed at record start. mediaQueue only.
    private var recordLandscape = false

    // MARK: - Permissions & lifecycle

    #if DEBUG
    /// C0 — sim preview stub: the simulator has no camera, so
    /// `LUMA_SEED_CAMFRAME=<image path>` feeds a test frame through the SAME
    /// grading path into `previewImage` at 30 Hz. Every HUD/overlay/gesture
    /// feature becomes screenshot-verifiable headlessly; capture paths still
    /// need device QA.
    private var stubTimer: DispatchSourceTimer?

    private func startStubIfSeeded() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["LUMA_SEED_CAMFRAME"],
              let source = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return false }
        let upright = source.transformed(by: CGAffineTransform(
            translationX: -source.extent.minX, y: -source.extent.minY))
        let timer = DispatchSource.makeTimerSource(queue: mediaQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let graded: CIImage
            if let lookState {
                graded = self.pipeline.apply(state: lookState, to: upright, includeSplit: false)
            } else {
                graded = upright
            }
            self.publishPreview(graded)
        }
        timer.resume()
        stubTimer = timer
        DispatchQueue.main.async { self.isRunning = true }
        print("[LUMA] CAMSTUB running frame=\(Int(upright.extent.width))x\(Int(upright.extent.height))")
        return true
    }
    #endif

    func requestAndStart() {
        #if DEBUG
        if startStubIfSeeded() { return }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestAudioAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.requestAudioAndStart() : (self?.permissionDenied = true)
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func requestAudioAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneDenied = false
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneDenied = !granted
                    self?.startSession()
                }
            }
        default:
            microphoneDenied = true
            startSession()
        }
    }

    private func startSession() {
        DispatchQueue.main.async { self.startOrientationTracking() }
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
        session.sessionPreset = .hd1920x1080   // fallback; applyFormat overrides

        // C2: prefer a virtual multi-camera so pinch can reach the 0.5x
        // ultra-wide; the system handles lens switchover inside one device.
        let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device,
              let videoInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(videoInput) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in self?.cameraUnavailable = true }
            return
        }
        session.addInput(videoInput)
        activeVideoDevice = device
        activeVideoInput = videoInput
        applyCurrentFormat(on: device)
        configureZoomBaseline(for: device)

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
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

        // C5: photo output rides the same session; capture pulls the FULL
        // sensor image, not the preview buffer.
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
        configured = true
        // Photo sizes and depth depend on the output being connected, so
        // they are read once the configuration above is committed.
        refreshPhotoCapabilities(on: device)
    }

    // MARK: - C3: capture format (resolution / fps / codec)

    /// User picked a new format. Blocked mid-recording (writer geometry must
    /// stay stable for the take). Applies live to the running session.
    func setSpec(_ newSpec: CameraSpec) {
        guard !isRecording, !isPreparingRecording else { return }
        DispatchQueue.main.async { self.spec = newSpec }
        newSpec.save()
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else {
                print("[LUMA] CAMSPEC stored=\(newSpec.rawValue) (no device — sim)")
                // No sensor to fall back from: what was asked is what runs.
                self?.deliveredSpec = newSpec
                DispatchQueue.main.async { self?.activeSpec = newSpec }
                return
            }
            self.session.beginConfiguration()
            // Slo-mo keeps its own size and rate (only the codec follows);
            // the rest of the new spec applies once it ends.
            if self.wantsSlowMotion, self.isSlowMotionFormatActive(on: device) {
                self.publishDeliveredFormat(requested: newSpec, on: device)
            } else {
                self.applyFormat(newSpec, on: device)
            }
            self.session.commitConfiguration()
            self.refreshPhotoCapabilities(on: device)
        }
    }

    /// sessionQueue only. Picks an activeFormat matching the spec's dimensions
    /// + fps and pins the frame duration. Buffers arrive sensor-landscape, so
    /// the target format is (portraitH × portraitW). Falls back gracefully:
    /// wrong fps → nearest the format supports; no matching dims → leave the
    /// session preset alone.
    private func applyFormat(_ spec: CameraSpec, on device: AVCaptureDevice) {
        let dims = spec.resolution.portrait
        let targetW = Int32(dims.h), targetH = Int32(dims.w)   // landscape sensor
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == targetW && d.height == targetH
        }
        guard !candidates.isEmpty else {
            print("[LUMA] CAMSPEC \(spec.rawValue) — no matching format, keeping preset")
            publishDeliveredFormat(requested: spec, on: device)
            return
        }
        let wanted = Double(spec.fps)
        let format = candidates.first { f in
            f.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= wanted && wanted <= $0.maxFrameRate
            }
        } ?? candidates[0]
        let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let actualFPS = min(wanted, maxRate)
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            print("[LUMA] CAMSPEC applied \(spec.rawValue) fps=\(Int(actualFPS))")
        } catch {
            print("[LUMA] CAMSPEC lock failed: \(error)")
        }
        publishDeliveredFormat(requested: spec, on: device)
    }

    /// sessionQueue only. Reads back what the device is ACTUALLY set to after
    /// `applyFormat` (which may have fallen back) and publishes it, plus the
    /// camera's per-resolution frame-rate ceilings for the picker.
    private func publishDeliveredFormat(requested: CameraSpec, on device: AVCaptureDevice) {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let shortSide = Int(min(dims.width, dims.height))
        // Never claim more than the sensor delivers: pick the largest
        // resolution that fits inside the delivered short side.
        let resolution = CameraSpec.Resolution.allCases
            .filter { $0.portrait.w <= shortSide }
            .max { $0.portrait.w < $1.portrait.w } ?? .hd720
        let frame = device.activeVideoMinFrameDuration
        let deliveredFPS = frame.isValid && frame.seconds > 0
            ? Int((1 / frame.seconds).rounded()) : requested.fps
        var delivered = requested
        delivered.resolution = resolution
        delivered.fps = deliveredFPS
        deliveredSpec = delivered

        var ceilings: [CameraSpec.Resolution: Double] = [:]
        for res in CameraSpec.Resolution.allCases {
            let w = Int32(res.portrait.h), h = Int32(res.portrait.w)   // landscape sensor
            let rates = device.formats
                .filter {
                    let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    return d.width == w && d.height == h
                }
                .flatMap { $0.videoSupportedFrameRateRanges.map(\.maxFrameRate) }
            if let best = rates.max() { ceilings[res] = best }
        }
        let slowRate = slowMotionFormat(on: device).map { Int($0.rate.rounded()) }
        DispatchQueue.main.async {
            self.activeSpec = delivered
            self.maxFrameRates = ceilings
            self.slowMotionFPS = slowRate
        }
    }

    // MARK: - Slo-mo (high frame rate)

    /// sessionQueue only. The spec's format, or the slow-motion format while
    /// Slo-mo is on (falling back to the spec where the camera has none).
    private func applyCurrentFormat(on device: AVCaptureDevice) {
        if wantsSlowMotion, applySlowMotionFormat(on: device) {
            DispatchQueue.main.async { self.isSlowMotion = true }
            return
        }
        applyFormat(spec, on: device)
        DispatchQueue.main.async { self.isSlowMotion = false }
    }

    /// Turns Slo-mo on or off. Blocked mid-take, like a format change.
    func setSlowMotion(_ on: Bool) {
        guard !isRecording, !isPreparingRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsSlowMotion = on
            guard let device = self.activeVideoDevice else {
                print("[LUMA] SLOMO \(on ? "on" : "off") (no device — sim)")
                return
            }
            let display = self.zoomFactor
            self.session.beginConfiguration()
            self.applyCurrentFormat(on: device)
            // A format change can reset the zoom; keep the lens you framed on.
            self.applyDisplayZoom(display, on: device, ramped: false)
            self.session.commitConfiguration()
            self.refreshPhotoCapabilities(on: device)
        }
    }

    /// The best high-frame-rate format: the highest rate (120 or 240), then
    /// 1080p over 720p. Only 16:9 sizes the writer knows, so the grade and
    /// the encoder keep up. nil when the camera has no rate above 100 fps.
    private func slowMotionFormat(on device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, rate: Double)? {
        var best: (format: AVCaptureDevice.Format, rate: Double, score: Double)?
        for format in device.formats {
            let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard rate >= 100 else { continue }
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let shortSide = min(d.width, d.height), longSide = max(d.width, d.height)
            guard shortSide == 1080 || shortSide == 720 else { continue }
            guard abs(Double(longSide) / Double(max(shortSide, 1)) - 16.0 / 9.0) < 0.05 else { continue }
            let score = rate * 10 + (shortSide == 1080 ? 2 : 1)
            if best == nil || score > (best?.score ?? 0) {
                best = (format, rate, score)
            }
        }
        guard let best else { return nil }
        return (best.format, best.rate)
    }

    /// sessionQueue only. True while the device runs faster than 90 fps.
    private func isSlowMotionFormatActive(on device: AVCaptureDevice) -> Bool {
        let frame = device.activeVideoMinFrameDuration
        return frame.isValid && frame.seconds > 0 && 1 / frame.seconds > 90
    }

    /// sessionQueue only. Switches the sensor to the slow-motion format.
    /// Returns false when the camera has none (the caller falls back).
    private func applySlowMotionFormat(on device: AVCaptureDevice) -> Bool {
        guard let pick = slowMotionFormat(on: device) else { return false }
        let fps = max(1, Int(pick.rate.rounded()))
        do {
            try device.lockForConfiguration()
            device.activeFormat = pick.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            print("[LUMA] SLOMO applied fps=\(fps)")
        } catch {
            print("[LUMA] SLOMO lock failed: \(error)")
            return false
        }
        publishDeliveredFormat(requested: spec, on: device)
        return true
    }

    // MARK: - Photo format, size and depth

    /// HEIF / JPEG and 12 / 24 / 48 MP. Applies the size to the photo output
    /// straight away so the next still is taken at it.
    func setPhotoSpec(_ newSpec: PhotoCaptureSpec) {
        newSpec.save()
        photoSpec = newSpec
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedPhotoSize = newSpec.size
            guard let device = self.activeVideoDevice else {
                DispatchQueue.main.async { self.activePhotoMegapixels = newSpec.size.rawValue }
                return
            }
            self.refreshPhotoCapabilities(on: device)
        }
    }

    /// Portrait: asks the photo output for depth (and the portrait matte
    /// where the camera has it) with every still. Off outside Portrait,
    /// because depth delivery narrows the session.
    func setDepthCapture(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsDepth = on
            guard let device = self.activeVideoDevice else { return }
            self.refreshPhotoCapabilities(on: device)
        }
    }

    /// sessionQueue only. Re-reads photo sizes and depth for the device in
    /// its own configuration pass. Always called after a format or input
    /// change is committed, so the photo output already sees the device.
    private func refreshPhotoCapabilities(on device: AVCaptureDevice) {
        session.beginConfiguration()
        applyPhotoCapabilities(on: device)
        session.commitConfiguration()
    }

    /// sessionQueue only. Sets the photo output's size from what the active
    /// format supports, switches depth delivery to match Portrait, and
    /// publishes what the camera can do.
    private func applyPhotoCapabilities(on device: AVCaptureDevice) {
        guard session.outputs.contains(photoOutput) else { return }

        let depthAvailable = photoOutput.isDepthDataDeliverySupported
        let wantDepthNow = wantsDepth && depthAvailable

        // Depth off first when leaving Portrait (the matte before depth, as
        // it needs depth), so the size below is set without it.
        if !wantDepthNow {
            if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
            }
            if photoOutput.isDepthDataDeliveryEnabled {
                photoOutput.isDepthDataDeliveryEnabled = false
            }
        }

        // Size: the largest supported resolution at or under the request
        // (or the smallest there is), never a value the format lacks.
        // Portrait stays at 12 MP, where depth is offered.
        let wanted = wantDepthNow ? PhotoCaptureSpec.Size.mp12 : requestedPhotoSize
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        let ordered = supported.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        let target = wanted.pixelCount + wanted.pixelCount / 10
        let pick = ordered.last(where: { Int64($0.width) * Int64($0.height) <= target }) ?? ordered.first
        if let pick {
            let current = photoOutput.maxPhotoDimensions
            if current.width != pick.width || current.height != pick.height {
                photoOutput.maxPhotoDimensions = pick
            }
        }
        var sizes: [PhotoCaptureSpec.Size] = []
        for d in ordered {
            if let size = PhotoCaptureSpec.Size.matching(width: d.width, height: d.height),
               !sizes.contains(size) {
                sizes.append(size)
            }
        }
        let delivered = photoOutput.maxPhotoDimensions
        let activeSize = PhotoCaptureSpec.Size.matching(width: delivered.width, height: delivered.height)
        let megapixels = max(1, Int((Double(Int64(delivered.width) * Int64(delivered.height)) / 1_000_000).rounded()))

        // Depth on (then the matte) when entering Portrait.
        if wantDepthNow {
            if !photoOutput.isDepthDataDeliveryEnabled {
                photoOutput.isDepthDataDeliveryEnabled = true
            }
            if photoOutput.isPortraitEffectsMatteDeliverySupported,
               !photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
            }
        }
        print("[LUMA] PHOTO size=\(delivered.width)x\(delivered.height) sizes=\(sizes.map(\.rawValue)) depth=\(depthAvailable)")
        DispatchQueue.main.async {
            self.photoSizes = sizes
            self.activePhotoSize = activeSize
            self.activePhotoMegapixels = megapixels
            self.depthSupported = depthAvailable
        }
    }

    // MARK: - C5: full-resolution graded still

    /// True when the REAL session can shoot a sensor still (false in the sim
    /// stub, where the caller falls back to grabbing the preview frame).
    var canCaptureFullRes: Bool { session.isRunning }

    /// Captures a full-resolution photo at the chosen size, adds the portrait
    /// blur when an aperture is given (and depth came back), grades it
    /// through the SAME look pipeline as the preview and encodes it as HEIF
    /// or JPEG. Callback on main; nil on failure.
    func captureStill(portraitAperture: Double?, completion: @escaping (CapturedStill?) -> Void) {
        // Orientation is committed at the press, like a take (C4).
        let angle: CGFloat = isLandscape ? landscapeAngle : 90
        let request = StillRequest(format: photoSpec.format, aperture: portraitAperture)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning,
                  self.session.outputs.contains(self.photoOutput) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // One shared completion slot: a second tap overwrote the first
            // before its delegate callback arrived, so the FIRST photo was
            // delivered to the SECOND closure and the second result was
            // dropped entirely. Refuse to start a capture while one is in
            // flight — the delegate clears the slot when it completes.
            guard self.stillCompletion == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.stillCompletion = completion
            self.stillRequest = request
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let settings = AVCapturePhotoSettings()
            var dims = self.photoOutput.maxPhotoDimensions
            // Portrait shoots at 12 MP at most: depth is not offered with
            // the large sensor modes.
            if request.aperture != nil, let device = self.activeVideoDevice {
                let cap = PhotoCaptureSpec.Size.mp12.pixelCount + PhotoCaptureSpec.Size.mp12.pixelCount / 10
                let outPixels = Int64(dims.width) * Int64(dims.height)
                let smaller = device.activeFormat.supportedMaxPhotoDimensions
                    .filter { Int64($0.width) * Int64($0.height) <= cap }
                    .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
                if outPixels > cap, let smaller { dims = smaller }
            }
            settings.maxPhotoDimensions = dims
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            // Depth only when the output has it switched on (Portrait), and
            // the matte only alongside depth: either out of order throws.
            if request.aperture != nil, self.photoOutput.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                if self.photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                    settings.isPortraitEffectsMatteDeliveryEnabled = true
                }
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// The preview frame as a finished still in the chosen format: the
    /// simulator path, and the fallback when a sensor capture fails.
    func makeStill(fromPreview frame: CGImage) -> CapturedStill? {
        makeStill(from: CIImage(cgImage: frame), format: photoSpec.format)
    }

    /// Encodes a graded still and a small thumbnail for the last-shot button.
    private func makeStill(from image: CIImage, format: PhotoCaptureSpec.Format) -> CapturedStill? {
        guard let encoded = StillEncoder.encode(image, format: format, context: pipeline.context) else {
            return nil
        }
        let thumb = StillEncoder.thumbnail(of: image, longSide: 360, context: pipeline.context)
        return CapturedStill(data: encoded.data, fileExtension: encoded.fileExtension, thumbnail: thumb)
    }

    // MARK: - C6: manual exposure (ISO / shutter angle / EV bias)

    /// Display state for the exposure HUD. `manualExposure` false = full auto.
    @Published var manualExposure = false
    @Published var currentISO: Float = 0          // read-back for the panel
    @Published var shutterAngle: Double = 180     // cine convention
    @Published var evBias: Float = 0

    /// Supported ISO range of the active format (for the slider bounds).
    var isoRange: ClosedRange<Float> {
        guard let device = activeVideoDevice else { return 50...3200 }
        let f = device.activeFormat
        return f.minISO...f.maxISO
    }

    /// C6 — sets manual ISO + shutter ANGLE. Angle → duration via the cine
    /// identity duration = (angle/360) / fps, so 180° at 30fps = 1/60s.
    /// nil leaves that component at its current value.
    func setManualExposure(iso: Float? = nil, angle: Double? = nil) {
        let targetAngle = angle ?? shutterAngle
        DispatchQueue.main.async {
            self.manualExposure = true
            self.shutterAngle = targetAngle
            if let iso { self.currentISO = iso }
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice,
                  device.isExposureModeSupported(.custom) else {
                print("[LUMA] EXPOSURE manual iso=\(iso.map { String(Int($0)) } ?? "keep") angle=\(Int(targetAngle)) (no device — sim)")
                return
            }
            // The shutter angle is relative to the rate actually running.
            let fps = Double(max(1, self.deliveredSpec.fps))
            let seconds = (targetAngle / 360.0) / fps
            let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            let clampedDuration = CMTimeClampToRange(
                duration, range: CMTimeRange(start: device.activeFormat.minExposureDuration,
                                             end: device.activeFormat.maxExposureDuration))
            let clampedISO = min(max(iso ?? device.iso,
                                     device.activeFormat.minISO), device.activeFormat.maxISO)
            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentISO = clampedISO }
                print("[LUMA] EXPOSURE iso=\(Int(clampedISO)) angle=\(Int(targetAngle)) dur=1/\(Int(1/seconds))s")
            } catch {}
        }
    }

    /// Snaps the shutter to the 180° rule for the current fps.
    func snapTo180() { setManualExposure(angle: 180) }

    /// C6 — exposure-compensation bias in EV (auto modes only).
    func setEVBias(_ ev: Float) {
        DispatchQueue.main.async { self.evBias = ev }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            let clamped = min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Back to full auto exposure.
    func resetAutoExposure() {
        DispatchQueue.main.async {
            self.manualExposure = false
            self.evBias = 0
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(0)
                device.unlockForConfiguration()
                print("[LUMA] EXPOSURE auto")
            } catch {}
        }
    }

    // MARK: - C7: manual white balance (temperature / tint)

    @Published var manualWB = false
    @Published var wbTemperature: Float = 5600
    @Published var wbTint: Float = 0

    /// C7 — locks WB to a temperature (K) + tint. Gains are clamped to the
    /// device's legal range component-wise (out-of-gamut gains crash).
    func setWhiteBalance(temperature: Float, tint: Float) {
        DispatchQueue.main.async {
            self.manualWB = true
            self.wbTemperature = temperature
            self.wbTint = tint
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice,
                  device.isWhiteBalanceModeSupported(.locked) else {
                print("[LUMA] WB \(Int(temperature))K tint=\(Int(tint)) (no device — sim)")
                return
            }
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature, tint: tint)
            var gains = device.deviceWhiteBalanceGains(for: tt)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            do {
                try device.lockForConfiguration()
                device.setWhiteBalanceModeLocked(with: gains)
                device.unlockForConfiguration()
                print("[LUMA] WB locked \(Int(temperature))K tint=\(Int(tint))")
            } catch {}
        }
    }

    /// Back to continuous auto white balance.
    func resetAutoWB() {
        DispatchQueue.main.async { self.manualWB = false }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice,
                  device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
            do {
                try device.lockForConfiguration()
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Zoom & flip (were placebo buttons — now real)

    /// C2 — on a virtual multi-camera, videoZoomFactor 1.0 is the ULTRA-WIDE;
    /// the wide lens sits at the first switch-over factor. `wideBaseline`
    /// converts between raw factors and the display convention users know
    /// (0.5x = ultra-wide, 1x = wide). 1 on single-lens devices.
    private var wideBaseline: CGFloat = 1   // sessionQueue only
    private var pinchBase: CGFloat = 1      // display zoom at pinch start

    private func configureZoomBaseline(for device: AVCaptureDevice) {
        wideBaseline = device.virtualDeviceSwitchOverVideoZoomFactors.first
            .map { CGFloat(truncating: $0) } ?? 1
        // Start at 1x wide (raw = baseline), matching the old behaviour.
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = wideBaseline
            device.unlockForConfiguration()
        } catch {}
        DispatchQueue.main.async { self.zoomFactor = 1 }
    }

    /// Cycles 0.5x (if the ultra-wide exists) → 1x → 2x → 3x →, clamped.
    func cycleZoom() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            let hasUltraWide = self.wideBaseline > 1
            let current = self.zoomFactor
            let next: CGFloat
            if current >= 2.5 { next = hasUltraWide ? 0.5 : 1 }
            else if current >= 1.5 { next = 3 }
            else if current >= 0.75 { next = 2 }
            else { next = 1 }
            self.applyDisplayZoom(next, on: device, ramped: true)
        }
    }

    /// Jumps to a display zoom (0.5x ultra-wide, 1x wide, 2x, 3x…), ramped.
    /// Out-of-range values clamp to what the device has, so the lens ruler can
    /// offer the same stops on every iPhone.
    func setDisplayZoom(_ display: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            self.applyDisplayZoom(display, on: device, ramped: true)
        }
    }

    /// C2 — continuous pinch. Call `beginPinch` on gesture start, then
    /// `updatePinch(scale:)` with the live magnification.
    func beginPinch() {
        pinchBase = zoomFactor
    }

    func updatePinch(scale: CGFloat) {
        let target = pinchBase * scale
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            self.applyDisplayZoom(target, on: device, ramped: false)
        }
    }

    /// sessionQueue only. Display zoom → raw factor, clamp, apply, publish.
    private func applyDisplayZoom(_ display: CGFloat, on device: AVCaptureDevice, ramped: Bool) {
        let raw = display * wideBaseline
        let clampedRaw = min(max(raw, device.minAvailableVideoZoomFactor),
                             min(device.maxAvailableVideoZoomFactor, wideBaseline * 10))
        do {
            try device.lockForConfiguration()
            if ramped {
                device.ramp(toVideoZoomFactor: clampedRaw, withRate: 8)
            } else {
                device.videoZoomFactor = clampedRaw
            }
            device.unlockForConfiguration()
            let display = clampedRaw / wideBaseline
            DispatchQueue.main.async { self.zoomFactor = display }
        } catch {}
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
            var didSwitch = false
            if let current = self.activeVideoInput {
                self.session.removeInput(current)
            }
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.activeVideoDevice = device
                self.activeVideoInput = input
                self.applyCurrentFormat(on: device)
                self.configureZoomBaseline(for: device)
                didSwitch = true
            } else if let current = self.activeVideoInput {
                self.session.addInput(current)   // roll back
            }
            if let connection = self.videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                connection.isVideoMirrored = target == .front
            }
            self.session.commitConfiguration()
            guard didSwitch else { return }
            self.refreshPhotoCapabilities(on: device)
            DispatchQueue.main.async {
                self.cameraPosition = target
            }
        }
    }

    func stopSession() {
        if isRecording || isPreparingRecording {
            stopRecording()
        }
        #if DEBUG
        stubTimer?.cancel()
        stubTimer = nil
        #endif
        // startSession() also starts device-motion updates (capture
        // orientation). Nothing ever stopped them, so the gyro stayed live and
        // the handler kept firing for the rest of the app's lifetime after the
        // first visit to the camera. They restart with the next session.
        orientationMotion.stopDeviceMotionUpdates()
        // If a capture was in flight when the session went away its delegate
        // may never fire, and the in-flight guard in captureFullResStill would
        // then reject every future still. Release the slot.
        if let pending = stillCompletion {
            stillCompletion = nil
            DispatchQueue.main.async { pending(nil) }
        }
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async { self?.isRunning = false }
        }
    }

    // MARK: - C1: tap-to-focus / tap-to-expose + AE/AF lock

    /// Whether AE/AF is user-locked (drives the HUD badge).
    @Published var aeafLocked = false
    /// Where the last focus tap landed, in unit preview coords (for the reticle).
    @Published var focusPoint: CGPoint?

    /// Focus + expose at a point in UNIT PREVIEW coordinates (portrait-upright,
    /// y-down, matching the on-screen image). Buffers are rotated 90° to
    /// portrait, so the sensor-native (landscape) device point is
    /// (y, 1 - x); the front camera is additionally mirrored in x.
    func focusExpose(at unit: CGPoint) {
        DispatchQueue.main.async {
            self.focusPoint = unit
            self.aeafLocked = false
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            var devicePoint = CGPoint(x: unit.y, y: 1 - unit.x)
            if self.cameraPosition == .front { devicePoint.y = 1 - devicePoint.y }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
                print("[LUMA] FOCUS unit=\(unit) device=\(devicePoint)")
            } catch {}
        }
    }

    /// Long-press AE/AF lock: freezes focus + exposure where they are.
    /// Call again (or tap anywhere) to release back to continuous auto.
    func toggleAEAFLock() {
        if aeafLocked { return unlockAEAF() }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.aeafLocked = true }
                print("[LUMA] AEAF locked")
            } catch {}
        }
    }

    func unlockAEAF() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.aeafLocked = false }
                print("[LUMA] AEAF released")
            } catch {}
        }
    }

    // MARK: - Recording (baked-in look)

    func toggleRecording() {
        isRecording || isPreparingRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard isRunning, !isRecording, !isPreparingRecording else { return }
        let requestID = UUID()
        lastSavedToPhotos = false
        recordingError = nil
        isPreparingRecording = true
        requestedRecordingID = requestID
        mediaQueue.async { [weak self] in
            self?.activeRecordingID = requestID
        }
        // C4 — commit the take's orientation NOW: rotate the capture
        // connection so buffers arrive upright for how the phone is held,
        // and let beginWriter size the file to match. Mid-take rotation
        // deliberately does NOT re-orient (standard camera behaviour).
        let landscape = isLandscape
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let connection = self.videoOutput.connection(with: .video) {
                let angle: CGFloat = landscape ? self.landscapeAngle : 90
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
            self.mediaQueue.async {
                guard self.activeRecordingID == requestID else { return }
                self.recordLandscape = landscape
                self.beginWriter(requestID: requestID)
            }
        }
        print("[LUMA] REC start orientation=\(landscape ? "landscape" : "portrait")")
    }

    func stopRecording() {
        requestedRecordingID = nil
        isPreparingRecording = false
        isRecording = false
        mediaQueue.async { [weak self] in
            self?.activeRecordingID = nil
            self?.finishWriter()
        }
        // C4 — back to portrait-upright buffers for the viewfinder.
        sessionQueue.async { [weak self] in
            guard let self,
                  let connection = self.videoOutput.connection(with: .video),
                  connection.isVideoRotationAngleSupported(90) else { return }
            connection.videoRotationAngle = 90
        }
    }

    /// mediaQueue only.
    private func beginWriter(requestID: UUID) {
        guard activeRecordingID == requestID else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Live_\(UUID().uuidString).mov")
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            failRecording(requestID: requestID, message: "Couldn’t create the recording: \(error.localizedDescription)")
            return
        }

        // C3/C4: geometry + codec follow what the sensor is DELIVERING (the
        // user's spec after any fallback), captured once per take so a
        // mid-take change can never tear frames. Recording the requested size
        // instead upscaled a 1080 feed whenever 4K was unavailable.
        let take = deliveredSpec
        let dims = take.resolution.portrait
        // C4: landscape takes swap the spec's portrait geometry.
        recordSize = recordLandscape
            ? CGSize(width: dims.h, height: dims.w)
            : CGSize(width: dims.w, height: dims.h)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: take.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(recordSize.width),
            AVVideoHeightKey: Int(recordSize.height)
        ]
        // Slo-mo: the take runs faster than any spec rate (120 / 240), so it
        // is conformed to 30 fps when it finishes. Tell the encoder the rate.
        recordSlowFactor = take.fps > 60 ? Double(take.fps) / 30.0 : 1
        if recordSlowFactor > 1 {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoExpectedSourceFrameRateKey: take.fps
            ]
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(recordSize.width),
                kCVPixelBufferHeightKey as String: Int(recordSize.height)
            ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true

        guard writer.canAdd(video) else {
            failRecording(requestID: requestID, message: "This capture format can’t be recorded on this device.")
            return
        }
        writer.add(video)
        if writer.canAdd(audio) { writer.add(audio) }
        guard writer.startWriting() else {
            failRecording(requestID: requestID,
                          message: writer.error?.localizedDescription ?? "The recording could not be started.")
            return
        }
        guard activeRecordingID == requestID else {
            writer.cancelWriting()
            return
        }

        self.writer = writer
        self.writerVideo = video
        self.writerAudio = audio
        self.pixelAdaptor = adaptor
        self.writerStarted = false
        self.outputURL = url
        self.wantsRecording = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedRecordingID == requestID else { return }
            self.isPreparingRecording = false
            self.isRecording = true
        }
    }

    /// mediaQueue only. Clears a failed start and exposes a useful message to UI.
    private func failRecording(requestID: UUID, message: String) {
        guard activeRecordingID == requestID else { return }
        activeRecordingID = nil
        wantsRecording = false
        cleanupWriter()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedRecordingID == requestID else { return }
            self.requestedRecordingID = nil
            self.isPreparingRecording = false
            self.isRecording = false
            self.recordingError = message
        }
    }

    /// mediaQueue only.
    private func finishWriter() {
        wantsRecording = false
        activeRecordingID = nil
        guard let writer, writer.status == .writing, let url = outputURL else {
            cleanupWriter()
            return
        }
        let slowFactor = recordSlowFactor
        recordSlowFactor = 1
        writerVideo?.markAsFinished()
        writerAudio?.markAsFinished()
        writer.finishWriting { [weak self] in
            let succeeded = writer.status == .completed
            self?.cleanupWriter()
            guard succeeded else { return }
            guard slowFactor > 1 else {
                self?.deliverRecording(url)
                return
            }
            // Slo-mo: play the high-rate take back slowed, conformed to 30
            // fps, so Photos, the grade room and the editor all see a slow
            // clip. If conforming fails the real-time take is kept.
            DispatchQueue.main.async { self?.isConformingSlowMo = true }
            SlowMotionConformer.conform(url, factor: slowFactor) { slowed in
                DispatchQueue.main.async { self?.isConformingSlowMo = false }
                self?.deliverRecording(slowed ?? url)
            }
        }
    }

    /// Hands a finished take to the hand-off card and saves it to Photos.
    private func deliverRecording(_ url: URL) {
        DispatchQueue.main.async { self.lastRecordingURL = url }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                DispatchQueue.main.async { self?.lastSavedToPhotos = success }
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

    // MARK: - D2: manual focus (lens position)

    /// false = continuous autofocus. The pro panel's Focus dial needs a real
    /// lens-position write; without it the dial would be a placebo.
    @Published var manualFocus = false
    /// 0 = near, 1 = infinity — AVFoundation's normalised lens position.
    @Published var lensPosition: Float = 0.5

    func setManualFocus(_ position: Float) {
        let clamped = min(max(position, 0), 1)
        DispatchQueue.main.async {
            self.manualFocus = true
            self.lensPosition = clamped
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice,
                  device.isFocusModeSupported(.locked) else {
                print("[LUMA] FOCUS manual pos=\(clamped) (no device — sim)")
                return
            }
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                device.unlockForConfiguration()
                print("[LUMA] FOCUS manual pos=\(clamped)")
            } catch {}
        }
    }

    func resetAutoFocus() {
        DispatchQueue.main.async { self.manualFocus = false }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
                print("[LUMA] FOCUS auto")
            } catch {}
        }
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
            // C12 — publish a throttled mic level (~8 Hz) from the channel's
            // average power: -50 dB → 0, 0 dB → 1.
            audioLevelTick += 1
            if audioLevelTick % 5 == 0,
               let power = connection.audioChannels.first?.averagePowerLevel {
                let level = min(max((Double(power) + 50) / 50, 0), 1)
                DispatchQueue.main.async { self.audioLevel = level }
            }
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let graded: CIImage
        if let lookState {
            graded = pipeline.apply(state: lookState, to: source, includeSplit: false)
                .cropped(to: source.extent)
        } else {
            graded = source
        }

        appendVideo(graded, sourceExtent: source.extent,
                    time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        // Slo-mo delivers 120 / 240 frames a second. Every one is recorded,
        // but the viewfinder only needs about 30, so skip the rest (each
        // preview is a full CGImage render).
        let rate = deliveredSpec.fps
        if rate > 60 {
            previewTick += 1
            if previewTick % max(1, rate / 30) != 0 { return }
        }
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

        // Aspect-fill the graded frame into the take's output geometry.
        let target = CGRect(origin: .zero, size: recordSize)
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
        // C8/C9 viewfinder assists — applied AFTER the downscale (cheap) and
        // only to the preview; recordings never carry them.
        if zebrasOn { preview = ZebraRenderer.apply(to: preview) }
        if peakingOn { preview = FocusPeakingRenderer.apply(to: preview) }
        guard let cg = pipeline.context.createCGImage(preview, from: preview.extent) else { return }
        // Sampled here, on the preview's own queue, rather than in a Swift
        // task: on a busy phone (or the CI simulator) the shared task pool
        // can be tied up grading look thumbnails for seconds, which left the
        // pill empty. A 64 px sample costs about a millisecond.
        var sampled: CameraHistogram? = nil
        if histogramOn {
            histogramTick += 1
            if histogramTick >= 8 {
                histogramTick = 0
                sampled = CameraHistogram.analyse(cg)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.previewImage = cg
            if let sampled { self?.histogram = sampled }
        }
    }
}

// MARK: - SwiftUI filtered preview

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let completion = stillCompletion
        let request = stillRequest
        stillCompletion = nil
        stillRequest = nil
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            DispatchQueue.main.async { completion?(nil) }
            return
        }
        // Grade at FULL resolution through the same pipeline as the preview,
        // off the delegate queue (a 48MP grade is not free).
        mediaQueue.async { [weak self] in
            guard let self else { return }
            var upright = source.transformed(by: CGAffineTransform(
                translationX: -source.extent.minX, y: -source.extent.minY))
            // Portrait: blur the background from the matte (or depth) before
            // the look goes on, so the grade sees the finished picture.
            if let aperture = request?.aperture {
                upright = PortraitBlur.apply(to: upright, photo: photo, aperture: aperture)
            }
            let graded: CIImage
            if let lookState {
                graded = self.pipeline.apply(state: lookState, to: upright, includeSplit: false)
                    .cropped(to: upright.extent)
            } else {
                graded = upright
            }
            let still = self.makeStill(from: graded, format: request?.format ?? .heif)
            print("[LUMA] STILL full-res \(Int(graded.extent.width))x\(Int(graded.extent.height)) \(still?.fileExtension ?? "FAILED")")
            DispatchQueue.main.async { completion?(still) }
        }
    }
}

struct FilteredCameraPreview: View {
    @ObservedObject var camera: CameraController
    /// C1 — tap-to-focus: called with (unit point in IMAGE space, raw view
    /// point). Unit accounts for how the frame is fitted, so the sensor is
    /// focused where the user actually touched the picture.
    var onTapUnit: ((CGPoint, CGPoint) -> Void)? = nil
    /// C1 — long-press AE/AF lock.
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            if let frame = camera.previewImage {
                // WYSIWYG: capture is 9:16 and the screen is taller, so
                // aspect-FILL cropped ~18% off each side of the frame that was
                // actually being recorded — you framed a shot and the file
                // contained more than you saw. FIT letterboxes instead, so the
                // viewfinder is the recording. Chrome then sits on the mattes
                // rather than over the picture, which is the whole point of a
                // clean viewfinder.
                let iw = CGFloat(frame.width), ih = CGFloat(frame.height)
                let s = min(geo.size.width / iw, geo.size.height / ih)
                let fitted = CGSize(width: iw * s, height: ih * s)
                let originX = (geo.size.width - fitted.width) / 2
                let originY = (geo.size.height - fitted.height) / 2

                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        // Long-press wins over tap; tap fires on release.
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in onLongPress?() }
                            .exclusively(before: SpatialTapGesture()
                                .onEnded { value in
                                    let p = value.location
                                    // Invert the FIT mapping: taps on a matte
                                    // clamp to the nearest edge of the image
                                    // rather than focusing off-frame.
                                    let unit = CGPoint(
                                        x: min(max((p.x - originX) / fitted.width, 0), 1),
                                        y: min(max((p.y - originY) / fitted.height, 0), 1))
                                    onTapUnit?(unit, p)
                                })
                    )
            } else {
                Color.black
            }
        }
    }
}

// MARK: - Stills: request, result, encoding

/// What a still was asked for, held while the sensor capture is in flight.
struct StillRequest {
    let format: PhotoCaptureSpec.Format
    /// f-number for Portrait's background blur; nil for a plain photo.
    let aperture: Double?
}

/// A finished, graded still: the encoded file and a small thumbnail.
struct CapturedStill {
    let data: Data
    /// "heic" or "jpg", matching `data`.
    let fileExtension: String
    let thumbnail: CGImage?
}

enum StillEncoder {
    /// HEIF or JPEG data for a finished still. HEIF falls back to JPEG where
    /// there is no HEVC encoder (the simulator).
    static func encode(_ image: CIImage, format: PhotoCaptureSpec.Format,
                       context: CIContext) -> (data: Data, fileExtension: String)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        if format == .heif,
           let data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: space, options: [:]) {
            return (data, "heic")
        }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if let data = context.jpegRepresentation(of: image, colorSpace: space, options: [quality: 0.92]) {
            return (data, "jpg")
        }
        return nil
    }

    /// A small render for the last-shot button.
    static func thumbnail(of image: CIImage, longSide: CGFloat, context: CIContext) -> CGImage? {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        let scale = min(1, longSide / longest)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent)
    }
}

// MARK: - Portrait blur

/// Background blur for Portrait stills. The subject comes from the portrait
/// effects matte when the camera found a person, else from the depth map
/// (nearest third kept sharp). The radius follows the f-number: f/1.4 is
/// the strongest, f/16 barely there.
enum PortraitBlur {
    static func apply(to image: CIImage, photo: AVCapturePhoto, aperture: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1,
              let mask = backgroundMask(for: photo, fitting: extent) else { return image }
        let shortSide = Double(min(extent.width, extent.height))
        let radius = shortSide * 0.018 * (1.4 / max(aperture, 1.4))
        guard radius >= 0.5 else { return image }
        let blurred = image.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": mask.clampedToExtent(),
            "inputRadius": radius,
        ])
        return blurred.cropped(to: extent)
    }

    /// White where the picture should blur (background), black on the
    /// subject, upright and scaled to the photo.
    private static func backgroundMask(for photo: AVCapturePhoto, fitting extent: CGRect) -> CIImage? {
        var subject: CIImage?
        if let matte = photo.portraitEffectsMatte {
            subject = CIImage(cvPixelBuffer: matte.mattingImage)
        } else if let depth = photo.depthData {
            subject = subjectFromDepth(depth)
        }
        guard var mask = subject else { return nil }
        // Depth and matte arrive in sensor orientation; the photo was made
        // upright from its EXIF orientation, so turn the mask the same way.
        mask = mask.oriented(exifOrientation(of: photo))
        mask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                      y: extent.height / mask.extent.height))
        mask = mask.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        // Invert (subject sharp, background blurred) using the first channel
        // for all three, so a one-channel buffer reads the same either way.
        let inverted = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        // Soften the edge so hair does not cut out hard.
        let sigma = Double(min(extent.width, extent.height)) * 0.004
        return inverted.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    }

    /// Near things white, far things black, from a disparity map.
    private static func subjectFromDepth(_ depthData: AVDepthData) -> CIImage? {
        let disparity = depthData.depthDataType == kCVPixelFormatType_DisparityFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = disparity.depthDataMap
        guard let range = disparityRange(map) else { return nil }
        let span = max(range.max - range.min, 0.0001)
        // n = (d - min) / span. Keep n above 0.65 sharp, blur fully below 0.4.
        let gain = CGFloat(4 / span)
        let bias = CGFloat(-(range.min / span + 0.4) * 4)
        return CIImage(cvPixelBuffer: map).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    private static func disparityRange(_ buffer: CVPixelBuffer) -> (min: Float, max: Float)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let value = row[x]
                if value.isFinite {
                    lo = min(lo, value)
                    hi = max(hi, value)
                }
            }
        }
        return hi > lo ? (lo, hi) : nil
    }

    private static func exifOrientation(of photo: AVCapturePhoto) -> CGImagePropertyOrientation {
        let key = kCGImagePropertyOrientation as String
        if let number = photo.metadata[key] as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) {
            return orientation
        }
        return .up
    }
}

// MARK: - Slo-mo conform

/// Turns a high-frame-rate take into a slow clip: the video track is
/// stretched by rate / 30 with `scaleTimeRange`, so a 240 fps take plays at
/// 30 fps, eight times slower. Audio is left out (slowed eight times it is
/// only noise). Returns nil on failure; the caller keeps the original.
enum SlowMotionConformer {
    static func conform(_ url: URL, factor: Double, completion: @escaping (URL?) -> Void) {
        Task {
            let slowed = await makeSlow(url, factor: factor)
            completion(slowed)
        }
    }

    static func makeSlow(_ url: URL, factor: Double) async -> URL? {
        guard factor > 1 else { return nil }
        let asset = AVURLAsset(url: url)
        guard let source = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              duration.seconds > 0 else { return nil }
        let transform = (try? await source.load(.preferredTransform)) ?? .identity

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let range = CMTimeRange(start: .zero, duration: duration)
        do {
            try track.insertTimeRange(range, of: source, at: .zero)
        } catch {
            return nil
        }
        track.preferredTransform = transform
        track.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(duration, multiplier: factor))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_SloMo_\(UUID().uuidString).mov")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
                ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        export.outputURL = output
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else {
            print("[LUMA] SLOMO conform failed: \(export.error?.localizedDescription ?? "unknown")")
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        print("[LUMA] SLOMO conformed x\(factor)")
        try? FileManager.default.removeItem(at: url)
        return output
    }
}

// MARK: - Live histogram

/// The camera's histogram pill: luminance plus the three channels, binned
/// the same way as the RGB histogram in `Scopes`, from a tiny downscale of
/// the graded preview so it costs nothing next to the frame rate.
struct CameraHistogram: Equatable {
    static let binCount = 48
    /// Each array is `binCount` long, normalised so the tallest bin is 1.
    var luma: [Float]
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    static func analyse(_ image: CGImage) -> CameraHistogram? {
        guard image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = 64
        let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let bins = binCount
        var l = [Float](repeating: 0, count: bins)
        var r = [Float](repeating: 0, count: bins)
        var g = [Float](repeating: 0, count: bins)
        var b = [Float](repeating: 0, count: bins)
        let top = Float(bins - 1)
        for p in 0..<(width * height) {
            let i = p * 4
            let rv = Float(pixels[i]) / 255
            let gv = Float(pixels[i + 1]) / 255
            let bv = Float(pixels[i + 2]) / 255
            let lv = 0.2126 * rv + 0.7152 * gv + 0.0722 * bv
            r[min(bins - 1, Int(rv * top))] += 1
            g[min(bins - 1, Int(gv * top))] += 1
            b[min(bins - 1, Int(bv * top))] += 1
            l[min(bins - 1, Int(lv * top))] += 1
        }
        return CameraHistogram(luma: normalised(smoothed(l)),
                               red: normalised(smoothed(r)),
                               green: normalised(smoothed(g)),
                               blue: normalised(smoothed(b)))
    }

    /// Three-tap smoothing so a small sample reads as a curve.
    private static func smoothed(_ values: [Float]) -> [Float] {
        guard values.count > 2 else { return values }
        var out = values
        for i in values.indices {
            let a = values[max(0, i - 1)], c = values[min(values.count - 1, i + 1)]
            out[i] = (a + values[i] * 2 + c) / 4
        }
        return out
    }

    private static func normalised(_ values: [Float]) -> [Float] {
        let peak = max(values.max() ?? 1, 1)
        return values.map { $0 / peak }
    }
}

// MARK: - Library thumbnail

enum CameraLibraryThumb {
    /// The newest photo or video in the library, small, for the last-shot
    /// button. Only when access is already granted: the camera never asks.
    static func latest(side: CGFloat) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { return nil }
        let request = PHImageRequestOptions()
        // One callback, the finished image (no degraded first pass).
        request.deliveryMode = .highQualityFormat
        request.resizeMode = .fast
        request.isNetworkAccessAllowed = true
        let size = CGSize(width: side, height: side)
        let gate = CameraResumeGate()
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFill,
                                                  options: request) { image, _ in
                // Photos calls back once in this mode; the gate makes a
                // second call harmless rather than a double resume.
                guard gate.claim() else { return }
                continuation.resume(returning: image)
            }
        }
    }
}

/// Lets exactly one caller through.
private final class CameraResumeGate {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

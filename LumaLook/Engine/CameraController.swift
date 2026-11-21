import Foundation
import AVFoundation
import CoreImage
import CoreMotion
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
    private var stillCompletion: ((CGImage?) -> Void)?   // sessionQueue set, delegate read
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
        applyFormat(spec, on: device)
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
            self.applyFormat(newSpec, on: device)
            self.session.commitConfiguration()
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
        DispatchQueue.main.async {
            self.activeSpec = delivered
            self.maxFrameRates = ceilings
        }
    }

    // MARK: - C5: full-resolution graded still

    /// True when the REAL session can shoot a sensor still (false in the sim
    /// stub, where the caller falls back to grabbing the preview frame).
    var canCaptureFullRes: Bool { session.isRunning }

    /// Captures a full-resolution photo, grades it through the SAME look
    /// pipeline as the preview, and returns the finished CGImage (nil on
    /// failure). Callback on main.
    func captureFullResStill(_ completion: @escaping (CGImage?) -> Void) {
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
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
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
                self.applyFormat(self.spec, on: device)
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
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: take.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(recordSize.width),
            AVVideoHeightKey: Int(recordSize.height)
        ]
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
        DispatchQueue.main.async { [weak self] in
            self?.previewImage = cg
        }
    }
}

// MARK: - SwiftUI filtered preview

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let completion = stillCompletion
        stillCompletion = nil
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
            let upright = source.transformed(by: CGAffineTransform(
                translationX: -source.extent.minX, y: -source.extent.minY))
            let graded: CIImage
            if let lookState {
                graded = self.pipeline.apply(state: lookState, to: upright, includeSplit: false)
            } else {
                graded = upright
            }
            let cg = self.pipeline.context.createCGImage(
                graded, from: graded.extent,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            print("[LUMA] STILL full-res \(cg.map { "\($0.width)x\($0.height)" } ?? "FAILED")")
            DispatchQueue.main.async { completion?(cg) }
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

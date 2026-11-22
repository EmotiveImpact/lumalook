import SwiftUI
import CoreImage
import AVFoundation
import Photos

// =============================================================================
// CameraLiveLookView — the shipping camera, in the approved design language.
//
// Promoted from the retired Design Lab preview with full feature
// parity against the previous full-bleed build. Nothing was dropped for the
// look; the carry-across items are marked (carried) below.
//
// FEATURE INVENTORY — verified line by line against the previous shipping view.
//
//   ✓ Capture-format chip (live off camera.activeSpec, the delivered format, never lies)
//   ✓ Resolution / frame rate / codec selection  (drawer panel, not a sheet)
//   ✓ Look filmstrip — every tile is the REAL grade of the live frame
//   ✓ Look source badge on the tile — LUT / Log / Saved          (carried)
//   ✓ Scene-art tile fallback tinted by the look, before a frame (carried)
//   ✓ OFF tile with intensity stash (tap twice restores the old strength)
//   ✓ Look intensity — a first-class drawer slider, not buried in a sheet
//   ✓ All Looks → the full LookBrowserSheet (purchased packs reachable),
//     reachable from the name line AND the strip's trailing tile   (carried)
//   ✓ Zoom — tap to cycle, continuous pinch on the viewfinder
//   ✓ EV bias / white balance / manual focus / ISO / shutter angle (dial)
//   ✓ PRO panel — the five readouts as a selector + ONE shared ruler dial
//   ✓ Auto all (drops manual exposure, WB, focus and the AE/AF lock)
//   ✓ Zebras (real ZebraRenderer pass) · focus peaking (FocusPeakingRenderer)
//   ✓ Rule-of-thirds grid · gyro level horizon
//   ✓ Frame guides — cycles 2.39 / 1.85 / 9:16 / 1:1 / 4:5; long-press = safe zone
//   ✓ Live scope — waveform → parade → vectorscope → histogram → false colour
//   ✓ Front/back flip (blocked mid-take, as the writer requires)
//   ✓ Graded still capture at full sensor resolution → Photos
//   ✓ Recording with baked-in look + SMPTE timecode + live mic meter
//   ✓ Recording saved-to-Photos confirmation off the controller   (carried)
//   ✓ Post-recording hand-off card — Retake / Grade / Edit (carries the shot's
//     grade into the clip)
//   ✓ Gallery shortcut (→ Select Clip)
//   ✓ Tap-to-focus with reticle, long-press AE/AF lock + lock badge
//   ✓ Saved-to-Photos + permission-denied status captions
//   ✓ Camera-unavailable / permission-denied fallback with Settings deep link
//   ✓ LUMA_SEED_CAMFRAME / _CAMASSIST / _CAMPRO / _BROWSER seeding (carried)
//
//   Night Lab round two:
//   ✓ Live histogram pill (top right, on by default, tap hides it)
//   ✓ Corner focus brackets: faint at rest, lit where you tap, then settle
//   ✓ Modes Photo · Video · Slo-mo · Portrait (Slo-mo and Portrait only on
//     cameras that can; all four in the DEBUG preview)
//   ✓ Slo-mo: highest-rate format (120 / 240, 1080p preferred), conformed to
//     30 fps when the take ends so it plays back slowed everywhere
//   ✓ Last shot by the shutter (this session, else the newest library item)
//   ✓ Photo pill "HEIF · 24 MP": format and the sizes this camera supports
//   ✓ Roll mode: 36 frames counted down on a signal-yellow shutter, Roll done
//     with Develop / New roll, persisted, toggled in the photo format panel
//   ✓ Portrait: depth (and the portrait matte) with each still, background
//     blur at the ruler's aperture, f/1.4 to f/16
//   ✓ LUMA_SEED_CAMMODE / _CAMROLL / _CAMFOCUS seeding
//
//   DEVICE QA only (wired here, but the simulator cannot exercise them): the
//   sensor writes — flip, full-res still, ISO/shutter/WB/focus/zoom lock-and-set
//   — and the AVAssetWriter recording path. The CAMFRAME stub feeds
//   `previewImage` through the real grading path, so every piece of chrome
//   above is still screenshot-verifiable headlessly.
//
// THE DESIGN LANGUAGE
//   1. The image is the interface. The viewfinder letterboxes to the 9:16
//      capture aspect — what you frame IS what is written — and every control
//      sits on the black mattes above and below it. Only overlays that must
//      register with the picture (grid, level, guides, reticle) are drawn on
//      the frame.
//   2. Monochrome chrome. The only colour is the armed/recording state and
//      the scope's own trace; everything else comes from the footage and the
//      looks.
//   3. Stroke means selection — one thin white ring. The single hairline over
//      live video is edge definition against unpredictable content.
//   4. The tile IS the preview.
//   5. Mono type is for NUMBERS ONLY. Names, labels and headings are the
//      system font, sentence case.
//   6. Prefer a live value over a glyph: the exposure row reads
//      1.0× · 100 · 1/60 · +0.0 · 5600K · AF, and every number is live.
// =============================================================================

struct CameraLiveLookView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()
    @StateObject private var thumbs = LookThumbs()

    /// Which expandable panel the drawer is showing. One at a time — the
    /// drawer is a single object, not a stack of trays.
    private enum Panel: Equatable { case none, pro, format }
    @State private var panel: Panel = .none
    /// The filmstrip tile the user last tapped, so the strip never scrolls
    /// after a tile that is already in front of them.
    @State private var tappedStripID: String?
    @State private var activeProParam: ProParameter = .shutter

    /// What the main ruler is driving. Tapping a readout cell re-targets it.
    /// Aperture only exists in Portrait.
    private enum RulerTarget: Equatable { case look, lens, shutter, iso, aperture }
    @State private var rulerTarget: RulerTarget = .lens
    /// Photo takes a graded still; Video records with the look baked in;
    /// Slo-mo records at the camera's highest rate and plays back slowed;
    /// Portrait takes a still with a depth blur. Slo-mo and Portrait only
    /// show on cameras that can do them.
    private enum CaptureMode: String, CaseIterable {
        case photo = "Photo", video = "Video", slowMo = "Slo-mo", portrait = "Portrait"

        var takesStills: Bool { self == .photo || self == .portrait }
    }
    @State private var captureMode: CaptureMode = .video
    /// Portrait's f-number, as an index into `apertureStops` (f/2.8).
    @State private var apertureIndex = 2
    /// The live histogram pill, on by default; tap hides it to a small glyph.
    @AppStorage("lumalook.camera.histogram") private var showHistogram = true
    /// Roll mode: an optional roll of 36 that the shutter counts down.
    /// Persists across launches, off by default.
    @AppStorage("lumalook.camera.rollOn") private var rollOn = false
    @AppStorage("lumalook.camera.rollLeft") private var rollLeft = 36
    @State private var showRollDone = false
    /// The newest capture (or library item) for the button by the shutter.
    @State private var lastShot: LastShot?
    /// The 120 ms white blink when a still is taken.
    @State private var shutterFlash = false

    @State private var liveThumbSource: CIImage?
    @State private var showGrid = false
    @State private var showLevel = false
    @State private var frameGuide: FrameGuide = .off
    @State private var showSafeZone = false
    @State private var scopeMode: ScopeMode?
    @State private var scopeImage: CGImage?
    @State private var recordStart: Date?
    @State private var statusCaption: String?
    @State private var stillSavedFlash = 0
    /// Where the focus brackets sit (nil: centred at rest, faint), whether
    /// they are still lit from the tap, and a counter that restarts the
    /// animate-in on every tap.
    @State private var focusPoint: CGPoint?
    @State private var focusActive = false
    @State private var focusTapID = 0
    /// DEBUG only: a unit point for lit brackets in the preview screenshot.
    @State private var focusSeed: CGPoint?
    @State private var isPinching = false
    /// Unified look browser over the viewfinder (mid detent, undimmed).
    @State private var showLookBrowser =
        ProcessInfo.processInfo.environment["LUMA_SEED_BROWSER"] == "1"
    /// OFF-tile stash so tapping OFF twice restores the previous strength.
    @State private var stashedLookIntensity: Double?
    /// A premium look is live on the viewfinder but not unlocked: shooting
    /// with it asks first (framing and previewing it stays free).
    @State private var lookLock: LookLock?

    // MARK: - Body

    var body: some View {
        mainBody
            .onChange(of: captureMode) { old, new in
                modeChanged(from: old, to: new)
            }
            // A camera that loses a mode (the front camera has no depth, or
            // no high frame rate) drops back to its plain sibling.
            .onChange(of: camera.slowMotionFPS) { _, fps in
                if fps == nil, captureMode == .slowMo, !showsAllModesForPreview { captureMode = .video }
            }
            .onChange(of: camera.depthSupported) { _, supported in
                if !supported, captureMode == .portrait, !showsAllModesForPreview { captureMode = .photo }
            }
            .onChange(of: camera.lastRecordingURL) { _, url in
                if let url { rememberClip(url) }
            }
            .onChange(of: camera.isConformingSlowMo) { _, conforming in
                if conforming { flash("Slowing the clip down") }
            }
            .onChange(of: showHistogram, initial: true) { _, on in
                camera.histogramOn = on
            }
            .task { await loadLibraryThumb() }
    }

    private var mainBody: some View {
        ZStack(alignment: .top) {
            LumaTheme.ink.ignoresSafeArea()

            // Night Lab: the picture runs full width from the top edge, and
            // the controls sit over its lower part on an ink gradient, so the
            // frame stays as large as the phone allows.
            viewfinder
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 0) {
                topMatte
                // Without a live picture, the permission or status message
                // sits in the clear space above the drawer, so the drawer can
                // never cover Open Settings on a short iPhone.
                if showsLivePicture {
                    Spacer(minLength: 0)
                } else {
                    fallbackMessage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                drawer
            }

            if let recording = camera.lastRecordingURL, !camera.isRecording {
                CameraHandOffCard(url: recording,
                                  onRetake: { camera.lastRecordingURL = nil },
                                  onGrade: { handOffToGrade(recording) },
                                  onEdit: { handOffToEditor(recording) })
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(50)
            }

            if showRollDone {
                CameraRollDoneCard(frames: Self.rollLength,
                                   onNewRoll: { loadNewRoll() },
                                   onDevelop: { developRoll() })
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(51)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: panel)
        .animation(.easeOut(duration: 0.15), value: showGrid)
        .animation(.easeOut(duration: 0.15), value: showLevel)
        .animation(.easeOut(duration: 0.18), value: frameGuide)
        .animation(.spring(response: 0.34, dampingFraction: 0.85),
                   value: camera.lastRecordingURL != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: showRollDone)
        // The full library over the viewfinder: opens at a mid detent so the
        // live feed stays visible, undimmed and interactive above the sheet.
        .lumaToolSheet(isPresented: $showLookBrowser, style: .panel) {
            LookBrowserSheet(context: .camera, intensity: $app.settings.intensity)
        }
        // No auto-start after a purchase or a swap: a camera that begins
        // recording on its own as a sheet slides away would catch the floor.
        .lockedLookSheet($lookLock, context: .camera) {
            flash("Look unlocked. Ready when you are")
        } onUseFreeLook: {
            app.useFreeLookInGrade(storeService)
            flash("Now on \(LookSignature.title(in: app.selectedLook.name)). Ready when you are")
        }
        .onAppear {
            app.library.settleOrder()
            start()
        }
        .onDisappear { camera.stopSession() }
        .onChange(of: camera.isRecording) { _, recording in
            recordStart = recording ? Date() : nil
            if recording, panel == .format { panel = .none }
        }
        .onChange(of: app.settings) { _, _ in
            syncCameraLook()
        }
        .onChange(of: app.selectedLook.id) { _, _ in
            syncCameraLook()
        }
        .onChange(of: app.selectedLUT?.id) { _, _ in
            syncCameraLook()
        }
        .onChange(of: camera.recordingError) { _, error in
            if let error { flash(error) }
        }
        .onChange(of: camera.microphoneDenied) { _, denied in
            if denied { flash("Microphone access is off, so recordings will be silent") }
        }
        // The controller writes the finished take to the photo library on its
        // own clock, well after the writer closes. Confirm it when it actually
        // lands — as a caption that times out, not as a badge that then owns
        // the status line until the next take (the old pill never cleared).
        .onChange(of: camera.lastSavedToPhotos) { _, saved in
            if saved { flash("Clip saved to Photos") }
        }
        .task(id: scopeMode) { await runScopeLoop() }
        // Grade the look strip with a real frame from the live camera as soon
        // as one arrives.
        .onReceive(camera.$previewImage) { frame in
            guard liveThumbSource == nil, let frame else { return }
            liveThumbSource = CIImage(cgImage: frame)
            thumbs.render(source: liveThumbSource, library: stripLooks,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
    }

    private func start() {
        // Defensive: a restored/hot scene must never open ON a panel — a pro
        // exposure panel over a black feed is the worst possible first frame.
        panel = .none
        camera.lookState = app.lookState
        camera.requestAndStart()
        #if DEBUG
        // Verification: switch viewfinder assists on at launch,
        // e.g. LUMA_SEED_CAMASSIST=peak,zebra,guide916,safe
        if let assists = ProcessInfo.processInfo.environment["LUMA_SEED_CAMASSIST"] {
            if assists.contains("peak") { camera.peakingOn = true }
            if assists.contains("zebra") { camera.zebrasOn = true }
            if assists.contains("guide916") { frameGuide = .vertical }
            if assists.contains("guide239") { frameGuide = .cinemascope }
            if assists.contains("safe") { showSafeZone = true }
            if assists.contains("scope") { scopeMode = .waveform }
            if assists.contains("grid") { showGrid = true }
            if assists.contains("level") { showLevel = true }
        }
        // Verification: open the pro panel with a chosen active parameter,
        // e.g. LUMA_SEED_CAMPRO=shutter (bare "1" defaults to shutter).
        if let pro = ProcessInfo.processInfo.environment["LUMA_SEED_CAMPRO"] {
            panel = .pro
            if let match = ProParameter.allCases.first(where: {
                $0.rawValue.lowercased() == pro.lowercased()
            }) { activeProParam = match }
        }
        // Verification: open on another mode, with a roll loaded, or with
        // the focus brackets lit, e.g. LUMA_SEED_CAMMODE=photo
        // LUMA_SEED_CAMROLL=24 LUMA_SEED_CAMFOCUS=1.
        let env = ProcessInfo.processInfo.environment
        if let mode = env["LUMA_SEED_CAMMODE"] {
            switch mode.lowercased() {
            case "photo": captureMode = .photo
            case "slomo", "slo-mo": captureMode = .slowMo
            case "portrait": captureMode = .portrait
            default: break
            }
        }
        if let roll = env["LUMA_SEED_CAMROLL"], let left = Int(roll) {
            rollOn = true
            rollLeft = min(max(left, 0), Self.rollLength)
        }
        if env["LUMA_SEED_CAMFOCUS"] == "1" {
            focusSeed = CGPoint(x: 0.56, y: 0.3)
            focusActive = true
        }
        #endif
        thumbs.render(source: liveThumbSource, library: stripLooks,
                      fileURL: { app.lutRepository.fileURL(for: $0) })
    }

    private func syncCameraLook() {
        camera.lookState = app.lookState
    }

    /// ~5 Hz scope render. The preview frame is ALREADY graded, so the scope
    /// analyses it with a neutral state.
    private func runScopeLoop() async {
        guard scopeMode != nil else { scopeImage = nil; return }
        let neutral = LookState()
        while !Task.isCancelled, let mode = scopeMode {
            if let frame = camera.previewImage {
                scopeImage = await Scopes.render(frame: CIImage(cgImage: frame),
                                                 state: neutral, mode: mode,
                                                 size: CGSize(width: 200, height: 92))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }


    // MARK: - Top matte
    //
    // The first half of the point of this screen: this row is chrome sitting on
    // BLACK, above the picture, not a scrim laid over the user's frame.

    private var topMatte: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                closeButton
                if captureMode.takesStills {
                    photoPills
                } else {
                    videoFormatButton
                }

                Spacer(minLength: 0)

                if camera.isRecording {
                    recordTimer
                }

                if captureMode.takesStills {
                    focusModePill
                } else {
                    // What the lens is doing never leaves the top line.
                    Text(String(format: "%.1f×", camera.zoomFactor))
                        .font(.luma(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lumaGlassPill()
                }
            }

            statusLine
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.18), value: camera.isRecording)
        .animation(.easeOut(duration: 0.18), value: captureMode)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color(hex: 0x0C0C0E).opacity(0.45), in: Circle())
                .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Close camera")
    }

    /// Live from the ACTIVE spec, so the HUD never lies. Tap to change
    /// resolution, frame rate and codec.
    private var videoFormatButton: some View {
        Button {
            panel = panel == .format ? .none : .format
            LumaHaptics.shared.tap()
        } label: {
            CaptureFormatChip(spec: camera.activeSpec)
                .lumaGlassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .disabled(camera.isRecording || camera.isPreparingRecording)
        .accessibilityHint(camera.isRecording || camera.isPreparingRecording
                           ? "Stop recording to change the capture format"
                           : "Change resolution, frame rate, and codec")
    }

    /// Photo modes: the still format and size, and the roll when one is
    /// loaded. Either opens the photo format panel.
    private var photoPills: some View {
        HStack(spacing: 8) {
            Button {
                panel = panel == .format ? .none : .format
                LumaHaptics.shared.tap()
            } label: {
                PhotoFormatChip(format: camera.photoSpec.format.rawValue,
                                megapixels: camera.activePhotoMegapixels)
                    .lumaGlassPill()
                    .contentShape(Capsule())
            }
            .buttonStyle(.lumaPress)
            .accessibilityHint("Change the photo format and size")

            if rollOn {
                Button {
                    panel = panel == .format ? .none : .format
                    LumaHaptics.shared.tap()
                } label: {
                    Text("Roll · \(rollLeft) left")
                        .font(.luma(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .padding(.vertical, 5)
                        .lumaGlassPill()
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
                .transition(.opacity)
            }
        }
    }

    /// Photo modes show the focus mode where video shows zoom: AF, MF, or
    /// AF L while AE/AF is locked. Tap opens the focus dial.
    private var focusModePill: some View {
        Button { openPro(.focus) } label: {
            Text(camera.aeafLocked ? "AF L" : (camera.manualFocus ? "MF" : "AF"))
                .font(.luma(size: 12, weight: .semibold))
                .foregroundStyle(camera.aeafLocked ? LumaTheme.signal : .white)
                .lineLimit(1)
                .lumaGlassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Focus")
    }

    private var recordTimer: some View {
        // Slo-mo runs at 120 / 240: the timecode keeps a readable frame
        // count and redraws at no more than 60 Hz.
        let fps = min(max(1, camera.activeSpec.fps), 60)
        return HStack(spacing: 6) {
            RecordTally()
            TimelineView(.periodic(from: recordStart ?? Date(), by: 1.0 / Double(fps))) { context in
                Text(Timecode.string(
                    seconds: context.date.timeIntervalSince(recordStart ?? context.date),
                    fps: Double(fps)))
                    .font(.luma(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .lumaGlassPill()
        .transition(.opacity)
    }

    /// Captions and the live mic meter, in a pill over the picture.
    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 10) {
            if camera.isRecording {
                InputMeterView(level: camera.audioLevel)
                    .grayscale(1)
                    .lumaGlassPill()
            } else if let statusCaption {
                Text(statusCaption)
                    .font(.luma(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .lumaGlassPill()
                    .id(statusCaption)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            histogramControl
        }
        .frame(minHeight: 28)
        .animation(.easeOut(duration: 0.18), value: statusCaption)
        .animation(.easeOut(duration: 0.18), value: showHistogram)
    }

    /// The histogram pill, or a small glyph to bring it back.
    @ViewBuilder
    private var histogramControl: some View {
        if showHistogram {
            Button {
                showHistogram = false
                LumaHaptics.shared.tap()
            } label: {
                CameraHistogramPill(histogram: camera.histogram)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.lumaPress)
            .accessibilityHint("Hide the histogram")
            .transition(.opacity)
        } else {
            Button {
                showHistogram = true
                LumaHaptics.shared.tap()
            } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color(hex: 0x0C0C0E).opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel("Show histogram")
            .transition(.opacity)
        }
    }

    private var idleStatusLine: String {
        let iso = Int(camera.currentISO > 0 ? camera.currentISO : 100)
        let mode = camera.manualExposure ? "M" : "A"
        let wb = camera.manualWB ? "\(Int(camera.wbTemperature))K" : "AWB"
        return "ISO \(iso) · \(shutterLabel(camera.shutterAngle)) · \(wb) · \(mode)"
    }

    private func matteButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: - Viewfinder
    //
    // Letterboxed to the 9:16 capture aspect. What you frame is what is
    // written — and everything that is not the picture lives on the mattes.

    private var showsLivePicture: Bool { camera.isRunning && !camera.cameraUnavailable }

    private var viewfinder: some View {
        ZStack {
            Group {
                if showsLivePicture {
                    FilteredCameraPreview(
                        camera: camera,
                        onTapUnit: { unit, viewPoint in
                            if camera.aeafLocked { camera.unlockAEAF() }
                            camera.focusExpose(at: unit)
                            placeFocusBrackets(at: viewPoint)
                            LumaHaptics.shared.tap()
                        },
                        onLongPress: {
                            camera.toggleAEAFLock()
                            LumaHaptics.shared.tap()
                        })
                } else {
                    ZStack {
                        HeroImage(photo: .golden)
                        Color.black.opacity(0.45)
                    }
                }
            }
            // Only overlays that must REGISTER with the picture are drawn on
            // the picture. Everything else went to the mattes.
            .overlay { if showGrid { RuleOfThirdsGrid().transition(.opacity) } }
            // Desaturated: the level snap still reads (the line grows to the
            // full reference width), it just no longer turns green over
            // footage the user is judging colour on.
            .overlay { if showLevel { LevelIndicator().grayscale(1).transition(.opacity) } }
            .overlay {
                if frameGuide != .off {
                    FrameGuidesOverlay(guide: frameGuide, showSafeZone: showSafeZone)
                        .transition(.opacity)
                }
            }
            .overlay { focusBracketsLayer }
            .overlay(alignment: .top) {
                if camera.aeafLocked {
                    Text("AE/AF locked")
                        .font(.luma(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(LumaTheme.edge, lineWidth: 0.5))
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: camera.aeafLocked)
            .overlay {
                if shutterFlash {
                    Color.white.opacity(0.8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        // A hairline is the one stroke allowed over live video: it is what
        // separates an unpredictable frame from the matte around it.
        .overlay(Rectangle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .contentShape(Rectangle())
        // Continuous pinch zoom, simultaneous so tap-to-focus and the
        // long-press AE/AF lock keep working.
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if !isPinching { isPinching = true; camera.beginPinch() }
                    camera.updatePinch(scale: scale)
                }
                .onEnded { _ in isPinching = false }
        )
    }

    @ViewBuilder
    private var fallbackMessage: some View {
        VStack(spacing: 10) {
            Image(systemName: camera.permissionDenied ? "lock.shield" : "camera.badge.ellipsis")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.8))
            if camera.permissionDenied {
                Text("Camera access is off")
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            } else if camera.cameraUnavailable {
                Text("No camera on this device")
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Run LumaLook on an iPhone to shoot with live looks.")
                    .font(.luma(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView().tint(.white)
            }
        }
        .padding(20)
    }

    // MARK: Focus brackets
    //
    // Four signal-yellow corners. At rest they sit faint around the middle
    // of the clear picture; a tap snaps them to that point, they animate in
    // lit, then settle dimmer where focus and exposure are now held.

    private var focusBracketsLayer: some View {
        GeometryReader { geo in
            let point = focusPoint ?? seededFocusPoint(in: geo.size)
            ZStack {
                if let point {
                    CameraFocusBrackets(colour: LumaTheme.signal.opacity(bracketOpacity),
                                        lineWidth: 2, arm: 16)
                        .frame(width: 84, height: 84)
                        .position(point)
                        .id(focusTapID)
                        .transition(.scale(scale: 1.45).combined(with: .opacity))
                } else {
                    let rest = restBracketRect(in: geo.size)
                    CameraFocusBrackets(colour: LumaTheme.signal.opacity(camera.aeafLocked ? 1 : 0.42),
                                        lineWidth: 1.5, arm: 18)
                        .frame(width: rest.width, height: rest.height)
                        .position(x: rest.midX, y: rest.midY)
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.35), value: focusActive)
        .animation(.easeOut(duration: 0.18), value: camera.aeafLocked)
    }

    /// Lit just after a tap or while AE/AF is locked, then settled.
    private var bracketOpacity: Double {
        camera.aeafLocked || focusActive ? 1 : 0.6
    }

    /// The resting frame: in the part of the picture left clear between the
    /// top pills (and histogram) and the drawer, as on the approved mock.
    private func restBracketRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 26
        let top = size.height * 0.235
        let height = size.height * 0.35
        return CGRect(x: inset, y: top, width: max(0, size.width - inset * 2), height: height)
    }

    private func seededFocusPoint(in size: CGSize) -> CGPoint? {
        guard let seed = focusSeed else { return nil }
        return CGPoint(x: seed.x * size.width, y: seed.y * size.height)
    }

    private func placeFocusBrackets(at point: CGPoint) {
        focusTapID += 1
        let tap = focusTapID
        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
            focusPoint = point
            focusActive = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard tap == focusTapID else { return }
            focusActive = false
        }
    }

    /// Back to the faint resting frame (auto all, a flip).
    private func resetFocusBrackets() {
        focusTapID += 1
        focusSeed = nil
        withAnimation(.easeOut(duration: 0.25)) {
            focusPoint = nil
            focusActive = false
        }
    }

    // MARK: - Drawer
    //
    // The second half of the point: every control that is not an image-
    // registered overlay lives down here, on black.

    private var drawer: some View {
        VStack(spacing: 0) {
            if scopeMode != nil { scopeStrip.padding(.bottom, 12) }
            lookReadout.padding(.bottom, 10)
            filmstrip.padding(.bottom, 12)

            switch panel {
            case .pro:
                proPanel.padding(.bottom, 10)
            case .format:
                formatPanel.padding(.bottom, 10)
            case .none:
                readoutRow.padding(.bottom, 2)
                mainRuler.padding(.bottom, 4)
            }

            toolRow.padding(.bottom, 6)
            modeSwitch.padding(.bottom, 12)
            captureRow
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
        // An ink gradient rather than a black slab: the lower picture still
        // reads through the top of the drawer, as on the approved mock.
        .background {
            LinearGradient(stops: [
                .init(color: LumaTheme.ink.opacity(0), location: 0),
                .init(color: LumaTheme.ink.opacity(0.82), location: 0.16),
                .init(color: LumaTheme.ink, location: 0.42),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: Scope — off the picture, onto the drawer

    @ViewBuilder
    private var scopeStrip: some View {
        HStack(spacing: 12) {
            Group {
                if let scopeImage {
                    Image(decorative: scopeImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LumaTheme.surface
                }
            }
            .frame(width: 200, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // clipShape clips pixels, NOT touches.
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(scopeName(scopeMode))
                    .font(.luma(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text("Reading the graded frame")
                    .font(.luma(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(2)
                Button {
                    scopeMode = scopeMode?.next
                    LumaHaptics.shared.tap()
                } label: {
                    Text("Next scope")
                        .font(.luma(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .transition(.opacity)
    }

    /// Sentence-case scope names — `ScopeMode.title` is shouted caps, which is
    /// the mono instrument voice and wrong for a heading.
    private func scopeName(_ mode: ScopeMode?) -> String {
        switch mode {
        case .waveform:    return "RGB waveform"
        case .parade:      return "RGB parade"
        case .vectorscope: return "Vectorscope"
        case .histogram:   return "RGB histogram"
        case .falseColor:  return "False colour"
        case nil:          return ""
        }
    }

    // MARK: Look readout + filmstrip

    /// The LIBRARY strip: recently used, then favourites, then the rest (saved
    /// looks, installed pack LUTs and imports included), bounded so live
    /// thumbnail rendering stays cheap.
    private var stripLooks: [LibraryLook] { app.library.stripLooks() }

    /// The current look's signature colour (imports are matched by name).
    private var currentSignature: Color {
        if let lut = app.selectedLUT { return LookSignature.colour(name: lut.displayName) }
        return app.selectedLook.signature
    }

    /// The one name surface: the look chip in its signature colour, the
    /// strength beside it, and the way into the full library.
    private var lookReadout: some View {
        let name = app.selectedLUT?.displayName ?? app.selectedLook.name
        let strength = Int(app.settings.intensity.rounded())
        return HStack(spacing: 10) {
            Button {
                showLookBrowser = true
                LumaHaptics.shared.tap()
            } label: {
                HStack(spacing: 8) {
                    LookChip(name: name,
                             colour: strength == 0 ? LumaTheme.textMuted : currentSignature,
                             size: 13)
                    Text(strength == 0 ? "Off" : "\(strength)%")
                        .font(.luma(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            Spacer(minLength: 0)
            Button {
                showLookBrowser = true
                LumaHaptics.shared.tap()
            } label: {
                HStack(spacing: 3) {
                    Text("All looks")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
        .padding(.horizontal, 16)
    }

    /// Every tile is the actual grade of the live frame. The selected one wears
    /// the only stroke in the drawer.
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    offTile
                    ForEach(stripLooks) { look in
                        Button {
                            // Selection derives from ONE source of truth
                            // (app.isCurrent) so a LUT and a built-in can never
                            // highlight at the same time.
                            tappedStripID = look.id
                            app.select(look: look)
                            LumaHaptics.shared.tap()
                        } label: {
                            lookTile(look)
                        }
                        .buttonStyle(.lumaPress)
                        .id(look.id)
                    }
                    Button {
                        showLookBrowser = true
                        LumaHaptics.shared.tap()
                    } label: {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LumaTheme.surfaceStrong)
                            .frame(width: 56, height: 56)
                            .overlay {
                                Image(systemName: "square.grid.3x3")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.lumaPress)
                }
                .padding(.horizontal, 18)
            }
            // The ramp width matches the content inset, so at rest the fade sits
            // entirely over the gutter and no tile is dimmed for no reason.
            .lumaEdgeFade(leading: 18, trailing: 18)
            .sensoryFeedback(.selection, trigger: app.selectedLook.id)
            .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
            // A look picked in All looks keeps its place in the strip, so fetch
            // it into view. A tile the user tapped is already under their thumb.
            .onChange(of: currentStripID) { _, new in
                guard let new else { return }
                if let tapped = tappedStripID,
                   let look = stripLooks.first(where: { $0.id == tapped }),
                   app.isCurrent(look) { return }
                tappedStripID = nil
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    /// Strip id of the look that is applied now, if the strip holds it.
    private var currentStripID: String? {
        stripLooks.first(where: { app.isCurrent($0) })?.id
    }

    /// One filmstrip tile. Before a live frame exists the tile still previews
    /// the look — scene art carrying that look's own grade tint — rather than
    /// collapsing the whole strip into identical grey squares.
    private func lookTile(_ look: LibraryLook) -> some View {
        Group {
            if let cg = thumbs.images[look.thumbKey] {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SceneArt(scene: .sunsetRoad, grade: fallbackTint(look))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // clipShape clips pixels, NOT touches — without this the overflowing
        // scaled fill steals taps from its neighbours.
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .topLeading) {
            // Source is information, not decoration: a LUT and a built-in are
            // different things to reach for. Monochrome, so the badge never
            // competes with the grade it sits on.
            if let badge = sourceBadge(look) {
                Text(badge)
                    .font(.luma(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if storeService.isLocked(look) { LookLockGlyph(compact: true) }
        }
        .pickedRing(app.isCurrent(look), cornerRadius: 9)
    }

    private func sourceBadge(_ look: LibraryLook) -> String? {
        switch look.source {
        case .saved:      return "Saved"
        case .lut(let f): return f.isLogTarget ? "Log" : "LUT"
        case .builtIn:    return nil
        }
    }

    private func fallbackTint(_ look: LibraryLook) -> Color? {
        switch look.source {
        case .builtIn(let preset): return preset.gradeTint
        case .saved(let saved):    return MockData.looks.first { $0.name == saved.baseLookName }?.gradeTint
        case .lut:                 return LumaTheme.cyan
        }
    }

    /// Shoot clean in one tap; tap again and the previous strength comes back.
    private var offTile: some View {
        let active = app.settings.intensity == 0
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                if active {
                    app.settings.intensity = stashedLookIntensity ?? 75
                    stashedLookIntensity = nil
                } else {
                    stashedLookIntensity = app.settings.intensity
                    app.settings.intensity = 0
                }
            }
            LumaHaptics.shared.tap()
        } label: {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LumaTheme.surfaceStrong)
                .frame(width: 56, height: 56)
                .overlay {
                    Text("Off")
                        .font(.luma(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(active ? 0.95 : 0.45))
                }
                .pickedRing(active, cornerRadius: 9)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: Readouts and ruler
    //
    // Four live values. Tap one to put it on the ruler; the active one turns
    // signal yellow. Look strength is a shooting decision, so it lives here
    // rather than two taps deep inside a sheet.

    private var readoutRow: some View {
        let strength = Int(app.settings.intensity.rounded())
        return HStack(spacing: 6) {
            ReadoutCell(label: "Look", value: strength == 0 ? "Off" : "\(strength)%",
                        active: rulerTarget == .look) { retarget(.look) }
            // Portrait trades the lens readout for the aperture (pinch still
            // zooms).
            if captureMode == .portrait {
                ReadoutCell(label: "Aperture", value: Self.fNumber(apertureIndex),
                            active: rulerTarget == .aperture) { retarget(.aperture) }
            } else {
                ReadoutCell(label: "Lens", value: "\(Self.millimetres(camera.zoomFactor)) mm",
                            active: rulerTarget == .lens) { retarget(.lens) }
            }
            ReadoutCell(label: "Shutter", value: readout(for: .shutter), dimmed: isAuto(.shutter),
                        active: rulerTarget == .shutter) { retarget(.shutter) }
            ReadoutCell(label: "ISO", value: readout(for: .iso), dimmed: isAuto(.iso),
                        active: rulerTarget == .iso) { retarget(.iso) }
        }
        .padding(.horizontal, 12)
    }

    private func retarget(_ target: RulerTarget) {
        rulerTarget = target
        LumaHaptics.shared.tap()
    }

    private var mainRuler: some View {
        LumaRuler(stops: rulerStops, index: rulerIndex,
                  needle: rulerTarget == .look ? currentSignature : LumaTheme.signal) { index in
            applyRuler(index)
        }
        .id(rulerTarget)
        .transition(.opacity)
    }

    private static let strengthStops: [Double] = stride(from: 0.0, through: 100.0, by: 10.0).map { $0 }
    private static let lensStops: [CGFloat] = [0.5, 1, 1.5, 2, 3, 5]
    /// Portrait's f-numbers: f/1.4 blurs the most, f/16 barely at all.
    private static let apertureStops: [Double] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16]
    /// A roll of film, as on the approved mock.
    static let rollLength = 36

    /// "f/1.4", "f/2", "f/11" for an index into `apertureStops`.
    private static func fNumber(_ index: Int) -> String {
        guard apertureStops.indices.contains(index) else { return "f/2.8" }
        let value = apertureStops[index]
        if value == value.rounded() { return "f/\(Int(value))" }
        return String(format: "f/%.1f", value)
    }

    /// 35 mm-equivalent focal length for a display zoom, from the familiar
    /// iPhone marks (0.5× 13 mm, 1× 24 mm, 2× 48 mm, 3× 77 mm, 5× 120 mm).
    static func millimetres(_ zoom: CGFloat) -> Int {
        let marks: [(CGFloat, CGFloat)] = [(0.5, 13), (1, 24), (2, 48), (3, 77), (5, 120)]
        guard zoom > marks[0].0 else { return Int(marks[0].1) }
        for (a, b) in zip(marks, marks.dropFirst()) where zoom <= b.0 {
            let t = (zoom - a.0) / (b.0 - a.0)
            return Int((a.1 + t * (b.1 - a.1)).rounded())
        }
        return Int((zoom / 5 * 120).rounded())
    }

    private var rulerStops: [String] {
        switch rulerTarget {
        case .look:    return Self.strengthStops.map { "\(Int($0))" }
        case .lens:    return Self.lensStops.map { "\(Self.millimetres($0))" }
        case .shutter: return dialTicks(for: .shutter)
        case .iso:     return dialTicks(for: .iso)
        case .aperture: return Self.apertureStops.indices.map { Self.fNumber($0) }
        }
    }

    private var rulerIndex: Int {
        switch rulerTarget {
        case .look:
            let value = app.settings.intensity
            return Self.strengthStops.indices.min {
                abs(Self.strengthStops[$0] - value) < abs(Self.strengthStops[$1] - value)
            } ?? 0
        case .lens:
            let zoom = camera.zoomFactor
            return Self.lensStops.indices.min {
                abs(Self.lensStops[$0] - zoom) < abs(Self.lensStops[$1] - zoom)
            } ?? 1
        case .shutter: return dialIndex(for: .shutter)
        case .iso:     return dialIndex(for: .iso)
        case .aperture: return apertureIndex
        }
    }

    private func applyRuler(_ index: Int) {
        switch rulerTarget {
        case .look:
            guard Self.strengthStops.indices.contains(index) else { return }
            app.settings.intensity = Self.strengthStops[index]
        case .lens:
            guard Self.lensStops.indices.contains(index) else { return }
            camera.setDisplayZoom(Self.lensStops[index])
        case .shutter: applyDial(index, to: .shutter)
        case .iso:     applyDial(index, to: .iso)
        case .aperture:
            guard Self.apertureStops.indices.contains(index) else { return }
            apertureIndex = index
        }
    }

    /// The modes this camera can shoot. Slo-mo needs a high-frame-rate
    /// format and Portrait needs depth; DEBUG preview shows every mode,
    /// because the simulator has no camera to ask.
    private var visibleModes: [CaptureMode] {
        CaptureMode.allCases.filter { mode in
            switch mode {
            case .photo, .video: return true
            case .slowMo:        return camera.slowMotionFPS != nil || showsAllModesForPreview
            case .portrait:      return camera.depthSupported || showsAllModesForPreview
            }
        }
    }

    private var showsAllModesForPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LUMA_SEED_CAMFRAME"] != nil
        #else
        return false
        #endif
    }

    /// Photo, Video, Slo-mo, Portrait. Locked while a take is rolling.
    private var modeSwitch: some View {
        HStack(spacing: 24) {
            ForEach(visibleModes, id: \.self) { mode in
                Button {
                    captureMode = mode
                    LumaHaptics.shared.tap()
                } label: {
                    Text(mode.rawValue)
                        .font(.luma(size: 13, weight: .semibold))
                        .foregroundStyle(captureMode == mode ? LumaTheme.signal : LumaTheme.textMuted)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityAddTraits(captureMode == mode ? .isSelected : [])
            }
        }
        .disabled(camera.isRecording || camera.isPreparingRecording)
        .opacity(camera.isRecording || camera.isPreparingRecording ? 0.45 : 1)
        .animation(.easeOut(duration: 0.18), value: captureMode)
    }

    // MARK: Tool row — icon over label, unboxed, the last item deliberately clipped

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Exposure tools show their VALUE, not a glyph. A thermometer
                // does not tell you the white balance is 5600K; "5600K" does.
                // The number is the better icon, and it is live.
                // Lens, shutter and ISO live on the readout row above; the
                // rest of the exposure triangle opens the pro panel.
                valueTool(readout(for: .ev), "Exposure", on: camera.evBias != 0) {
                    openPro(.ev)
                }
                valueTool(readout(for: .wb), "White bal.", on: camera.manualWB) {
                    openPro(.wb)
                }
                valueTool(readout(for: .focus), "Focus", on: camera.manualFocus) {
                    openPro(.focus)
                }

                toolDivider

                tool("slider.horizontal.3", "Pro", on: panel == .pro) {
                    if panel == .pro { panel = .none }
                    else { openPro(camera.manualExposure ? .iso : .shutter) }
                }
                tool("rectangle.dashed", frameGuide == .off ? "Guides" : frameGuide.label,
                     on: frameGuide != .off) {
                    let all = FrameGuide.allCases
                    let idx = (all.firstIndex(of: frameGuide)! + 1) % all.count
                    frameGuide = all[idx]
                    flash(frameGuide == .off ? "Guides off" : "Guide \(frameGuide.label)")
                }
                // Long-press toggles the social safe zone inside the guide.
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    showSafeZone.toggle()
                    flash(showSafeZone ? "Safe zone on" : "Safe zone off")
                })
                .sensoryFeedback(.selection, trigger: frameGuide)
                tool("waveform.path.ecg.rectangle", "Scope", on: scopeMode != nil) {
                    cycleScope()
                }
                tool("light.beacon.max", "Zebras", on: camera.zebrasOn) {
                    camera.zebrasOn.toggle()
                    flash(camera.zebrasOn ? "Zebras on" : "Zebras off")
                }
                tool("camera.metering.spot", "Peaking", on: camera.peakingOn) {
                    camera.peakingOn.toggle()
                    flash(camera.peakingOn ? "Peaking on" : "Peaking off")
                }
                tool("grid", "Grid", on: showGrid) { showGrid.toggle() }
                tool("level", "Level", on: showLevel) { showLevel.toggle() }
                tool("rectangle.on.rectangle", "Format", on: panel == .format,
                     enabled: !camera.isRecording && !camera.isPreparingRecording) {
                    panel = panel == .format ? .none : .format
                }
                .accessibilityHint(camera.isRecording || camera.isPreparingRecording
                                   ? "Stop recording to change the capture format"
                                   : (captureMode.takesStills
                                      ? "Change the photo format, size and roll"
                                      : "Change resolution, frame rate, and codec"))
                tool("a.circle", "Auto all", on: false) { autoAll() }
            }
            .padding(.horizontal, 16)
        }
        .lumaEdgeFade(leading: 16, trailing: 16)
    }

    private var toolDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 6)
    }

    /// The instrument cluster: a live value in mono, its name beneath in plain
    /// sentence case. Weight and contrast do the work that tracked caps at 42%
    /// white could not.
    private func valueTool(_ value: String, _ label: String, on: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.luma(size: 15, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(on ? .white : .white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.7 : 0.45))
                    .lineLimit(1)
            }
            .frame(width: 68, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }

    private func tool(_ symbol: String, _ label: String, on: Bool,
                      enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                Text(label)
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(on ? 0.7 : 0.45))
                    .lineLimit(1)
            }
            // No box, no chip, no pill — separation is by value alone. An
            // engaged tool is simply brighter than a resting one.
            .foregroundStyle(on ? .white : .white.opacity(0.5))
            .frame(width: 68, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    // MARK: PRO panel — five readouts and one shared dial
    //
    // The capture row never leaves, so a take can be started and stopped with
    // the panel open; the old build had to grow a second REC button inside the
    // panel because the shutter disappeared underneath it.

    private var proPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(ProParameter.allCases) { parameter in
                    CameraProReadout(parameter: parameter,
                                     value: readout(for: parameter),
                                     auto: isAuto(parameter),
                                     active: activeProParam == parameter) {
                        activeProParam = parameter
                        LumaHaptics.shared.tap()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)

            // One dial, re-targeted by the readout row above it.
            CameraRulerDial(ticks: dialTicks(for: activeProParam),
                            index: dialIndex(for: activeProParam)) { newIndex in
                applyDial(newIndex, to: activeProParam)
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

    // MARK: Format panel — resolution / fps / codec, in the drawer
    //
    // The photo modes swap it for the still format, size and roll.

    @ViewBuilder
    private var formatPanel: some View {
        if captureMode.takesStills {
            photoFormatPanel
        } else {
            videoFormatPanel
        }
    }

    private var videoFormatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if camera.isRecording || camera.isPreparingRecording {
                Text("Stop recording to change format.")
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            // Options this camera cannot shoot are dimmed rather than offered
            // and then quietly swapped for something else. Selection shows what
            // is actually running. Slo-mo owns the size and rate.
            formatRow("Resolution", options: CameraSpec.Resolution.allCases,
                      label: { $0.rawValue }, isOn: { camera.activeSpec.resolution == $0 },
                      enabled: { captureMode != .slowMo && resolutionAvailable($0) }) { r in
                var s = camera.spec; s.resolution = r; camera.setSpec(s)
            }
            formatRow("Frame rate", options: CameraSpec.fpsOptions,
                      label: { "\($0)" }, isOn: { camera.activeSpec.fps == $0 },
                      enabled: { captureMode != .slowMo && fpsAvailable($0) }) { f in
                var s = camera.spec; s.fps = f; camera.setSpec(s)
            }
            formatRow("Codec", options: CameraSpec.Codec.allCases,
                      label: { $0.rawValue }, isOn: { camera.activeSpec.codec == $0 }) { c in
                var s = camera.spec; s.codec = c; camera.setSpec(s)
            }
            if let note = formatFallbackNote {
                Text(note)
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(camera.isRecording || camera.isPreparingRecording)
        .opacity(camera.isRecording || camera.isPreparingRecording ? 0.45 : 1)
        .padding(.horizontal, 18)
        .transition(.opacity)
    }

    /// Unknown capabilities (simulator, camera not configured yet) enable
    /// everything rather than greying out the whole panel.
    private func resolutionAvailable(_ resolution: CameraSpec.Resolution) -> Bool {
        camera.maxFrameRates.isEmpty || camera.maxFrameRates[resolution] != nil
    }

    private func fpsAvailable(_ fps: Int) -> Bool {
        guard let ceiling = camera.maxFrameRates[camera.activeSpec.resolution] else { return true }
        return Double(fps) <= ceiling + 0.5
    }

    /// Says so when the camera is running something other than what was
    /// picked (4K on the front camera, 60 at a size that tops out at 30).
    private var formatFallbackNote: String? {
        if captureMode == .slowMo {
            return "Slo-mo shoots \(camera.activeSpec.resolution.rawValue) at \(camera.activeSpec.fps) fps and plays back at 30, so it's slowed down."
        }
        let asked = camera.spec, running = camera.activeSpec
        guard asked.resolution != running.resolution || asked.fps != running.fps else { return nil }
        return "This camera can't shoot \(asked.resolution.rawValue) at \(asked.fps) fps, so it's recording \(running.resolution.rawValue) at \(running.fps) fps."
    }

    /// Still format, size and the roll. Sizes are only the ones this camera
    /// can deliver right now.
    private var photoFormatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            formatRow("Format", options: PhotoCaptureSpec.Format.allCases,
                      label: { $0.rawValue }, isOn: { camera.photoSpec.format == $0 }) { format in
                var spec = camera.photoSpec
                spec.format = format
                camera.setPhotoSpec(spec)
            }
            formatRow("Size", options: offeredPhotoSizes,
                      label: { $0.label }, isOn: { photoSizeIsOn($0) }) { size in
                var spec = camera.photoSpec
                spec.size = size
                camera.setPhotoSpec(spec)
            }
            if captureMode == .portrait {
                Text("Portrait shoots at up to 12 MP, where depth is available.")
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            formatRow("Roll", options: [false, true],
                      label: { $0 ? "\(Self.rollLength) frames" : "Off" },
                      isOn: { rollOn == $0 }) { on in
                setRoll(on)
            }
            if rollOn {
                HStack(spacing: 10) {
                    Text(rollLeft == 0 ? "Roll done" : "\(rollLeft) of \(Self.rollLength) left")
                        .font(.luma(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                    Button {
                        loadNewRoll()
                    } label: {
                        Text("New roll")
                            .font(.luma(size: 11, weight: .semibold))
                            .foregroundStyle(LumaTheme.signal)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.lumaPress)
                    .disabled(rollLeft == Self.rollLength)
                    .opacity(rollLeft == Self.rollLength ? 0.4 : 1)
                }
                .padding(.leading, 94)
            }
        }
        .padding(.horizontal, 18)
        .transition(.opacity)
    }

    /// Sizes the camera reported; before it has (or in the simulator) only
    /// the size in force.
    private var offeredPhotoSizes: [PhotoCaptureSpec.Size] {
        if !camera.photoSizes.isEmpty { return camera.photoSizes }
        return [camera.activePhotoSize ?? camera.photoSpec.size]
    }

    private func photoSizeIsOn(_ size: PhotoCaptureSpec.Size) -> Bool {
        if let active = camera.activePhotoSize { return active == size }
        return camera.photoSpec.size == size
    }

    private func formatRow<T: Hashable>(_ title: String, options: [T],
                                        label: @escaping (T) -> String,
                                        isOn: @escaping (T) -> Bool,
                                        enabled: @escaping (T) -> Bool = { _ in true },
                                        pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.luma(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 84, alignment: .leading)
            ForEach(options, id: \.self) { option in
                Button {
                    pick(option)
                    LumaHaptics.shared.tap()
                } label: {
                    // Format codes are values, so they keep the mono voice —
                    // but selection is the ring, and everything else is a
                    // bare word.
                    Text(label(option))
                        .font(.luma(size: 12, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(isOn(option) ? 0.95 : 0.42))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay {
                            if isOn(option) {
                                Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
                .disabled(!enabled(option))
                .opacity(enabled(option) ? 1 : 0.35)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Capture row

    /// The shutter stays optically centred; the two secondary actions (open
    /// footage, shoot a graded still) sit on the outside so the row never grows
    /// a fourth control creeping toward the middle.
    private var captureRow: some View {
        HStack(spacing: 0) {
            // The last shot replaces the gallery glyph once there is one.
            CameraLastShotButton(image: lastShot?.thumbnail) { openLastShot() }
                .animation(.easeOut(duration: 0.25), value: lastShot?.id)

            Spacer(minLength: 0)

            CameraShutterButton(isRecording: camera.isRecording,
                                photoMode: captureMode.takesStills,
                                rollCount: captureMode.takesStills && rollOn ? rollLeft : nil) {
                if captureMode.takesStills {
                    captureStill()
                    return
                }
                // Stopping a take is never gated; only starting one with a
                // locked look on the viewfinder asks first.
                if !camera.isRecording, !camera.isPreparingRecording,
                   let lock = app.lockedLookInGrade(storeService) {
                    lookLock = lock
                    return
                }
                camera.toggleRecording()
            }

            Spacer(minLength: 0)

            Button {
                camera.flipCamera()
                resetFocusBrackets()
                LumaHaptics.shared.tap()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .frame(width: 46, height: 46)
                    .background(LumaTheme.raised, in: Circle())
                    .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.lumaPress)
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.35 : 1)
            .accessibilityLabel("Flip camera")
        }
        .padding(.horizontal, 30)
        // Puts the record button's centre exactly where the tab bar's yellow
        // shutter sits, so the camera opens with its button under the thumb
        // that just tapped (both measure from the bottom safe area).
        .padding(.bottom, 14)
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.isRecording)
        .sensoryFeedback(.success, trigger: stillSavedFlash)
    }

    // MARK: - Actions

    /// Opens the pro panel already targeting the parameter the tool names, so a
    /// tap lands on the control it advertises rather than a generic panel.
    private func openPro(_ parameter: ProParameter) {
        activeProParam = parameter
        panel = .pro
        LumaHaptics.shared.tap()
    }

    /// All five scopes, then off — every mode `Scopes` can render is reachable.
    private func cycleScope() {
        let all = ScopeMode.allCases
        if let current = scopeMode, let idx = all.firstIndex(of: current) {
            scopeMode = idx + 1 < all.count ? all[idx + 1] : nil
        } else {
            scopeMode = all.first
        }
        flash(scopeMode.map { "Scope: \(scopeName($0))" } ?? "Scope off")
        LumaHaptics.shared.tap()
    }

    /// The escape hatch: everything back to automatic in one tap, including the
    /// AE/AF lock, so no invisible manual state can survive it.
    private func autoAll() {
        camera.resetAutoExposure()
        camera.resetAutoWB()
        camera.resetAutoFocus()
        camera.unlockAEAF()
        resetFocusBrackets()
        flash("Everything back to auto")
        LumaHaptics.shared.tap()
    }

    /// Transient state caption on the matte's status line.
    private func flash(_ text: String) {
        withAnimation(.snappy(duration: 0.2)) { statusCaption = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if statusCaption == text {
                withAnimation(.easeOut(duration: 0.25)) { statusCaption = nil }
            }
        }
    }

    private func handOffToGrade(_ url: URL) {
        camera.lastRecordingURL = nil
        app.selectedVideoURL = url
        app.path = [.selectClip, .applyLook]
    }

    private func handOffToEditor(_ url: URL) {
        camera.lastRecordingURL = nil
        let editor = app.editor
        // Carry the shot's look into the clip so the grade you framed with
        // survives into editing.
        let shotGrade = ClipGrade(
            baseLookName: app.selectedLUT == nil ? app.selectedLook.name : "",
            lutID: app.selectedLUT?.id,
            settings: app.settings)
        Task {
            await editor.addClip(from: url)
            if let id = editor.clips.last?.id {
                editor.selectedClipID = id
                editor.setClipGrade(id: id, shotGrade)
            }
        }
        app.path = [.editor]
    }

    /// Full sensor resolution through AVCapturePhotoOutput at the chosen
    /// size, graded with the live look and saved as HEIF or JPEG. Portrait
    /// adds the depth blur at the ruler's aperture. Sim falls back to the
    /// preview buffer. With a roll loaded, every press spends a frame.
    private func captureStill() {
        if let lock = app.lockedLookInGrade(storeService) {
            lookLock = lock
            return
        }
        if rollOn, rollLeft <= 0 {
            showRollDone = true
            return
        }
        shutterFlash = true
        withAnimation(.easeOut(duration: 0.12).delay(0.06)) { shutterFlash = false }
        let aperture: Double? = captureMode == .portrait && Self.apertureStops.indices.contains(apertureIndex)
            ? Self.apertureStops[apertureIndex] : nil
        if camera.canCaptureFullRes {
            camera.captureStill(portraitAperture: aperture) { still in
                if let still {
                    saveStill(still)
                } else if let frame = camera.previewImage,
                          let fallback = camera.makeStill(fromPreview: frame) {
                    // Sensor capture failed — degrade gracefully to the preview.
                    saveStill(fallback)
                }
            }
        } else if let frame = camera.previewImage, let still = camera.makeStill(fromPreview: frame) {
            saveStill(still)
        }
        spendRollFrame()
    }

    private func saveStill(_ still: CapturedStill) {
        // Keep a copy for the last-shot button, so tapping it opens this
        // photo in the grade room.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Still_\(UUID().uuidString).\(still.fileExtension)")
        let wrote = (try? still.data.write(to: file)) != nil
        if let thumb = still.thumbnail {
            lastShot = LastShot(thumbnail: UIImage(cgImage: thumb),
                                source: wrote ? .still(file) : .library)
        }
        let data = still.data
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                // Compare against the SAME literal we set — a prefix guard on
                // different wording never matched, so the caption stayed
                // pinned to the status line forever.
                let denied = "Turn on Add Photos Only in Settings to save"
                withAnimation(.snappy(duration: 0.2)) { statusCaption = denied }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if statusCaption == denied {
                    withAnimation(.easeOut(duration: 0.25)) { statusCaption = nil }
                }
                return
            }
            do {
                // Added as a resource so the file stays the HEIF or JPEG the
                // format pill promised.
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }
                stillSavedFlash += 1
                flash("Saved to Photos")
            } catch {
                flash("Couldn't save the photo")
            }
        }
    }

    // MARK: Roll

    private func spendRollFrame() {
        guard rollOn, rollLeft > 0 else { return }
        rollLeft -= 1
        guard rollLeft == 0 else { return }
        // Let the flash land before the roll-done card comes up.
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            if rollOn, rollLeft == 0 { showRollDone = true }
        }
    }

    private func setRoll(_ on: Bool) {
        rollOn = on
        if on, rollLeft <= 0 { rollLeft = Self.rollLength }
        if !on { showRollDone = false }
        flash(on ? "Roll loaded · \(rollLeft) frames" : "Roll off")
    }

    private func loadNewRoll() {
        rollLeft = Self.rollLength
        showRollDone = false
        flash("New roll loaded")
        LumaHaptics.shared.tap()
    }

    /// Develop: open the photos, with a fresh roll loaded for next time.
    private func developRoll() {
        rollLeft = Self.rollLength
        showRollDone = false
        app.path = [.selectClip]
    }

    // MARK: Modes

    private func modeChanged(from old: CaptureMode, to new: CaptureMode) {
        if panel == .format { panel = .none }
        if old == .slowMo, new != .slowMo { camera.setSlowMotion(false) }
        if old == .portrait, new != .portrait {
            camera.setDepthCapture(false)
            if rulerTarget == .aperture { rulerTarget = .lens }
        }
        switch new {
        case .slowMo:
            camera.setSlowMotion(true)
            if let fps = camera.slowMotionFPS {
                flash("Slo-mo · \(fps) fps")
            } else {
                flash("Slo-mo")
            }
        case .portrait:
            camera.setDepthCapture(true)
            rulerTarget = .aperture
            flash("Background blur goes on as you shoot")
        case .photo, .video:
            if rulerTarget == .aperture { rulerTarget = .lens }
        }
    }

    // MARK: Last shot

    /// The newest capture opens in the grade room, as the hand-off card's
    /// Grade does; with only a library item to show it opens your clips, as
    /// the gallery button did.
    private func openLastShot() {
        LumaHaptics.shared.tap()
        guard let shot = lastShot else {
            app.path = [.selectClip]
            return
        }
        switch shot.source {
        case .clip(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                handOffToGrade(url)
            } else {
                app.path = [.selectClip]
            }
        case .still(let url):
            if let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
                app.selectedImage = image
                app.path = [.selectClip, .applyLook]
            } else {
                app.path = [.selectClip]
            }
        case .library:
            app.path = [.selectClip]
        }
    }

    /// A finished take becomes the last shot.
    private func rememberClip(_ url: URL) {
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            guard let frame = try? await generator.image(
                at: CMTime(seconds: 0.05, preferredTimescale: 600)).image else { return }
            lastShot = LastShot(thumbnail: UIImage(cgImage: frame), source: .clip(url))
        }
    }

    /// Before anything is shot this session, the newest library item (only
    /// when Photos access is already granted; the camera never asks).
    private func loadLibraryThumb() async {
        guard lastShot == nil else { return }
        #if DEBUG
        // The simulator preview shows the seeded frame by the shutter (its
        // library can be empty, and a library request there may never
        // answer).
        if let path = ProcessInfo.processInfo.environment["LUMA_SEED_CAMFRAME"],
           let image = UIImage(contentsOfFile: path) {
            lastShot = LastShot(thumbnail: image, source: .library)
            return
        }
        #endif
        if let image = await CameraLibraryThumb.latest(side: 160) {
            if lastShot == nil { lastShot = LastShot(thumbnail: image, source: .library) }
            return
        }
    }

    // MARK: - Dial stops (cine practice: discrete, repeatable between takes)

    private static let isoStops: [Float] = [25, 32, 50, 64, 100, 125, 160, 200, 250, 320,
                                            400, 500, 640, 800, 1000, 1250, 1600, 2000,
                                            2500, 3200, 4000, 5000, 6400]
    /// Ordered so faster shutters move RIGHT (1/30 → 1/240 at 30fps).
    private static let shutterAngles: [Double] = [360, 270, 180, 90, 45]
    private static let wbStops: [Float] = [2500, 2800, 3200, 3600, 4000, 4500, 5000,
                                           5600, 6500, 7500, 9000]
    private static let evStops: [Float] = [-2, -1.7, -1.3, -1, -0.7, -0.3, 0,
                                            0.3, 0.7, 1, 1.3, 1.7, 2]
    /// Index 0 is AF; the rest are normalised lens positions, near → far.
    private static let focusStops: [Float] = stride(from: 0.0, through: 1.0, by: 0.1)
        .map { Float($0) }

    private var isoStopsInRange: [Float] {
        let range = camera.isoRange
        let inRange = Self.isoStops.filter { range.contains($0) }
        return inRange.isEmpty ? Self.isoStops : inRange
    }

    /// Shutter speed implied by an angle at the current frame rate.
    private func shutterLabel(_ angle: Double) -> String {
        "1/\(Int((360.0 / max(angle, 1)) * Double(camera.activeSpec.fps)))"
    }

    /// True when the camera — not the user — is choosing this parameter. The
    /// readout still prints the concrete value the dial points at; `auto` only
    /// changes how it is presented.
    private func isAuto(_ parameter: ProParameter) -> Bool {
        switch parameter {
        case .iso, .shutter: return !camera.manualExposure
        case .wb:            return !camera.manualWB
        case .ev, .focus:    return false
        }
    }

    private func readout(for parameter: ProParameter) -> String {
        switch parameter {
        case .iso:     return "\(Int(camera.currentISO > 0 ? camera.currentISO : 100))"
        case .shutter: return shutterLabel(camera.shutterAngle)
        case .wb:      return "\(Int(camera.wbTemperature))K"
        case .ev:      return String(format: "%+.1f", camera.evBias)
        case .focus:   return camera.manualFocus ? String(format: "%.1f", camera.lensPosition) : "AF"
        }
    }

    private func dialTicks(for parameter: ProParameter) -> [String] {
        switch parameter {
        case .iso:     return isoStopsInRange.map { "\(Int($0))" }
        case .shutter: return Self.shutterAngles.map(shutterLabel)
        case .wb:      return Self.wbStops.map { "\(Int($0))K" }
        case .ev:      return Self.evStops.map { String(format: "%+.1f", $0) }
        case .focus:   return ["AF"] + Self.focusStops.map { String(format: "%.1f", $0) }
        }
    }

    /// Nearest stop to the value currently in force, so the dial always opens
    /// centred on what the camera is actually doing.
    private func dialIndex(for parameter: ProParameter) -> Int {
        func nearest<T: BinaryFloatingPoint>(_ value: T, in stops: [T]) -> Int {
            stops.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
        }
        switch parameter {
        case .iso:
            let stops = isoStopsInRange
            let iso = camera.currentISO > 0 ? camera.currentISO : (stops.first ?? 100)
            return nearest(iso, in: stops)
        case .shutter: return nearest(camera.shutterAngle, in: Self.shutterAngles)
        case .wb:      return nearest(camera.wbTemperature, in: Self.wbStops)
        case .ev:      return nearest(camera.evBias, in: Self.evStops)
        case .focus:
            guard camera.manualFocus else { return 0 }
            return nearest(camera.lensPosition, in: Self.focusStops) + 1
        }
    }

    /// Every dial move writes straight through to the device — moving a stop is
    /// also what engages manual, so there is no AUTO/MANUAL switch to forget.
    private func applyDial(_ index: Int, to parameter: ProParameter) {
        switch parameter {
        case .iso:
            let stops = isoStopsInRange
            guard stops.indices.contains(index) else { return }
            camera.setManualExposure(iso: stops[index])
        case .shutter:
            guard Self.shutterAngles.indices.contains(index) else { return }
            camera.setManualExposure(angle: Self.shutterAngles[index])
        case .wb:
            guard Self.wbStops.indices.contains(index) else { return }
            camera.setWhiteBalance(temperature: Self.wbStops[index], tint: camera.wbTint)
        case .ev:
            guard Self.evStops.indices.contains(index) else { return }
            camera.setEVBias(Self.evStops[index])
        case .focus:
            if index == 0 { camera.resetAutoFocus(); return }
            let stops = Self.focusStops
            guard stops.indices.contains(index - 1) else { return }
            camera.setManualFocus(stops[index - 1])
        }
    }
}

// MARK: - Monochrome camera chrome
//
// The screen's own parts. They are not a parallel token set — they use the
// same LumaTheme values and the same type voice as the rest of the app; they
// simply drop the violet accent, which this screen reserves for nothing at all.

/// The armed tally: the one colour this screen allows itself, breathing so
/// "am I rolling?" is answered from across the room.
private struct RecordTally: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(LumaTheme.recordRed)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// One of the five pro readouts. Tapping it re-targets the shared dial — the
/// readout row is a selector, not decoration. The name is plain type; only the
/// value speaks mono.
private struct CameraProReadout: View {
    let parameter: ProParameter
    let value: String
    /// True when the camera is choosing this value itself. The concrete value
    /// is still shown — it is what the dial points at — but dimmed and tagged,
    /// so the readout and the dial can never state two different truths.
    var auto: Bool = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    Text(parameter.rawValue)
                        .font(.luma(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(active ? 0.8 : 0.4))
                    if auto {
                        Text("auto")
                            .font(.luma(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                Text(value)
                    .font(.luma(size: 15, weight: active ? .bold : .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(active ? 1 : (auto ? 0.42 : 0.62)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(minWidth: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }
}

/// Detented ruler. One dial, re-targeted by the readout row above it; the
/// current stop sits under the caret at the row's own centre.
private struct CameraRulerDial: View {
    /// Tick labels, in order. The dial is index-based so any parameter — ISO
    /// stops, shutter angles, kelvin, EV thirds — uses the same widget.
    let ticks: [String]
    let index: Int
    let onChange: (Int) -> Void

    /// Drag distance that advances one detent.
    private let stride: CGFloat = 46
    @State private var dragBase: Int?

    var body: some View {
        // No GeometryReader: the caret is the ZStack's own centre and the tick
        // rail is offset relative to that same centre, so the readout row above
        // and the dial can never disagree about where "centre" is.
        ZStack {
            HStack(spacing: 0) {
                ForEach(ticks.indices, id: \.self) { i in
                    let current = i == index
                    VStack(spacing: 5) {
                        Rectangle()
                            .fill(.white.opacity(current ? 0.95 : 0.20))
                            .frame(width: current ? 2 : 1, height: current ? 15 : 9)
                        Text(ticks[i])
                            .font(.luma(size: current ? 12 : 10,
                                          weight: current ? .bold : .regular,
                                          design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(current ? 1 : 0.32))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(width: stride)
                }
            }
            .offset(x: stride * (CGFloat(ticks.count) / 2 - CGFloat(index) - 0.5))
            .animation(.snappy(duration: 0.14), value: index)

            Rectangle()
                .fill(.white)
                .frame(width: 2, height: 8)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let base = dragBase ?? index
                    if dragBase == nil { dragBase = index }
                    let steps = Int((-value.translation.width / stride).rounded())
                    let target = min(max(base + steps, 0), max(ticks.count - 1, 0))
                    if target != index { onChange(target) }
                }
                .onEnded { _ in dragBase = nil }
        )
        .sensoryFeedback(.selection, trigger: index)
    }
}

/// White ring. Video mode has a red core that squares off while rolling;
/// photo mode has a white core, or a signal-yellow frame counter while a
/// roll is loaded.
private struct CameraShutterButton: View {
    let isRecording: Bool
    var photoMode: Bool = false
    /// Frames left on the roll; nil when no roll is loaded.
    var rollCount: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 70, height: 70)
                if photoMode, let rollCount {
                    rollCore(rollCount)
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 8 : 28)
                        .fill(photoMode ? Color.white : LumaTheme.recordRed)
                        .frame(width: isRecording ? 28 : 56, height: isRecording ? 28 : 56)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isRecording)
            .animation(.easeOut(duration: 0.18), value: photoMode)
            .animation(.snappy(duration: 0.2), value: rollCount)
            .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(accessibilityText)
    }

    private func rollCore(_ count: Int) -> some View {
        ZStack {
            Circle()
                .fill(LumaTheme.signal)
                .frame(width: 56, height: 56)
            Text("\(count)")
                .font(.luma(size: 22, weight: .bold))
                .kerning(-0.6)
                .monospacedDigit()
                .foregroundStyle(LumaTheme.onSignal)
                .contentTransition(.numericText(countsDown: true))
        }
    }

    private var accessibilityText: String {
        if photoMode, let rollCount { return "Take photo, \(rollCount) frames left" }
        if photoMode { return "Take photo" }
        return isRecording ? "Stop recording" : "Record"
    }
}

/// The newest capture for the button by the shutter, and what tapping it
/// opens.
private struct LastShot {
    enum Source {
        /// A still from this session, kept as a file for the grade room.
        case still(URL)
        /// A take from this session.
        case clip(URL)
        /// The newest library item (or the DEBUG seed frame).
        case library
    }

    let id = UUID()
    let thumbnail: UIImage
    let source: Source
}

/// The take returns a result: the clip is written, now choose where it goes.
/// A dialogue on black, three plain words, the recommended step filled.
private struct CameraHandOffCard: View {
    let url: URL
    let onRetake: () -> Void
    let onGrade: () -> Void
    let onEdit: () -> Void

    @State private var thumb: CGImage?

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let thumb {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LumaTheme.surfaceStrong
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // clipShape clips pixels, NOT touches.
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Clip saved · look baked in")
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 0) {
                handButton("Retake", solid: false, action: onRetake)
                handButton("Grade", solid: false, action: onGrade)
                handButton("Edit", solid: true, action: onEdit)
            }
        }
        .padding(16)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(LumaTheme.edge, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
        .task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            thumb = try? await generator.image(
                at: CMTime(seconds: 0.05, preferredTimescale: 600)).image
        }
    }

    private func handButton(_ title: String, solid: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(solid ? .black : .white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(solid ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }
}

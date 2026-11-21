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
    @State private var activeProParam: ProParameter = .shutter

    /// What the main ruler is driving. Tapping a readout cell re-targets it.
    private enum RulerTarget: Equatable { case look, lens, shutter, iso }
    @State private var rulerTarget: RulerTarget = .lens
    /// Photo takes a graded still; Video records with the look baked in.
    private enum CaptureMode: String, CaseIterable { case photo = "Photo", video = "Video" }
    @State private var captureMode: CaptureMode = .video
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
    @State private var reticlePoint: CGPoint?
    @State private var reticlePulse = false
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
                Spacer(minLength: 0)
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
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: panel)
        .animation(.easeOut(duration: 0.15), value: showGrid)
        .animation(.easeOut(duration: 0.15), value: showLevel)
        .animation(.easeOut(duration: 0.18), value: frameGuide)
        .animation(.spring(response: 0.34, dampingFraction: 0.85),
                   value: camera.lastRecordingURL != nil)
        // The full library over the viewfinder: opens at a mid detent so the
        // live feed stays visible, undimmed and interactive above the sheet.
        .lumaToolSheet(isPresented: $showLookBrowser, style: .panel) {
            LookBrowserSheet(context: .camera, intensity: $app.settings.intensity)
        }
        // No auto-start after a purchase: a camera that begins recording on
        // its own as a sheet slides away would catch the floor.
        .lockedLookSheet($lookLock) { flash("Look unlocked. Ready when you are") }
        .onAppear { start() }
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
            if denied { flash("Microphone access is off — recordings will be silent") }
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
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(Color(hex: 0x0C0C0E).opacity(0.45), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.09), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Close camera")

                // Live from the ACTIVE spec, so the HUD never lies. Tap to
                // change resolution, frame rate and codec.
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

                Spacer(minLength: 0)

                if camera.isRecording {
                    HStack(spacing: 6) {
                        RecordTally()
                        TimelineView(.periodic(from: recordStart ?? Date(),
                                               by: 1.0 / Double(max(1, camera.activeSpec.fps)))) { context in
                            Text(Timecode.string(
                                seconds: context.date.timeIntervalSince(recordStart ?? context.date),
                                fps: Double(max(1, camera.activeSpec.fps))))
                                .font(.luma(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                    }
                    .lumaGlassPill()
                    .transition(.opacity)
                }

                // What the lens is doing never leaves the top line.
                Text(String(format: "%.1f×", camera.zoomFactor))
                    .font(.luma(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lumaGlassPill()
            }

            statusLine
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.18), value: camera.isRecording)
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
        }
        .frame(minHeight: 28)
        .animation(.easeOut(duration: 0.18), value: statusCaption)
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

    private var viewfinder: some View {
        ZStack {
            Group {
                if camera.isRunning && !camera.cameraUnavailable {
                    FilteredCameraPreview(
                        camera: camera,
                        onTapUnit: { unit, viewPoint in
                            if camera.aeafLocked { camera.unlockAEAF() }
                            camera.focusExpose(at: unit)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                reticlePoint = viewPoint
                                reticlePulse.toggle()
                            }
                            LumaHaptics.shared.tap()
                            Task {                       // reticle fades after 1.1 s
                                try? await Task.sleep(nanoseconds: 1_100_000_000)
                                withAnimation(.easeOut(duration: 0.3)) { reticlePoint = nil }
                            }
                        },
                        onLongPress: {
                            camera.toggleAEAFLock()
                            LumaHaptics.shared.tap()
                        })
                } else {
                    ZStack {
                        HeroImage(photo: .golden)
                        Color.black.opacity(0.45)
                        fallbackMessage
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
            .overlay {
                if let p = reticlePoint {
                    CameraFocusReticle(pulse: reticlePulse)
                        .position(p)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if camera.aeafLocked {
                    Text("AE/AF locked")
                        .font(.luma(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                offTile
                ForEach(stripLooks) { look in
                    Button {
                        // Selection derives from ONE source of truth
                        // (app.isCurrent) so a LUT and a built-in can never
                        // highlight at the same time.
                        app.select(look: look)
                        LumaHaptics.shared.tap()
                    } label: {
                        lookTile(look)
                    }
                    .buttonStyle(.lumaPress)
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
        .overlay {
            if app.isCurrent(look) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(look.signature, lineWidth: 2)
            }
        }
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
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.white, lineWidth: 2)
                    }
                }
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
            ReadoutCell(label: "Lens", value: "\(Self.millimetres(camera.zoomFactor)) mm",
                        active: rulerTarget == .lens) { retarget(.lens) }
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
        }
    }

    /// Photo or Video. Locked while a take is rolling.
    private var modeSwitch: some View {
        HStack(spacing: 28) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
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
                                   : "Change resolution, frame rate, and codec")
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

    private var formatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if camera.isRecording || camera.isPreparingRecording {
                Text("Stop recording to change format.")
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            // Options this camera cannot shoot are dimmed rather than offered
            // and then quietly swapped for something else. Selection shows what
            // is actually running.
            formatRow("Resolution", options: CameraSpec.Resolution.allCases,
                      label: { $0.rawValue }, isOn: { camera.activeSpec.resolution == $0 },
                      enabled: { resolutionAvailable($0) }) { r in
                var s = camera.spec; s.resolution = r; camera.setSpec(s)
            }
            formatRow("Frame rate", options: CameraSpec.fpsOptions,
                      label: { "\($0)" }, isOn: { camera.activeSpec.fps == $0 },
                      enabled: { fpsAvailable($0) }) { f in
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
        let asked = camera.spec, running = camera.activeSpec
        guard asked.resolution != running.resolution || asked.fps != running.fps else { return nil }
        return "This camera can't shoot \(asked.resolution.rawValue) at \(asked.fps) fps, so it's recording \(running.resolution.rawValue) at \(running.fps) fps."
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
            Button { app.path = [.selectClip] } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .frame(width: 46, height: 46)
                    .background(LumaTheme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LumaTheme.border, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel("Open your clips")

            Spacer(minLength: 0)

            CameraShutterButton(isRecording: camera.isRecording,
                                photoMode: captureMode == .photo) {
                if captureMode == .photo {
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
                LumaHaptics.shared.tap()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .frame(width: 46, height: 46)
                    .background(LumaTheme.raised, in: Circle())
                    .overlay(Circle().strokeBorder(LumaTheme.hairline, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.lumaPress)
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.35 : 1)
            .accessibilityLabel("Flip camera")
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 6)
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

    /// Full sensor resolution through AVCapturePhotoOutput, graded with the
    /// live look. Sim falls back to the preview buffer.
    private func captureStill() {
        if let lock = app.lockedLookInGrade(storeService) {
            lookLock = lock
            return
        }
        shutterFlash = true
        withAnimation(.easeOut(duration: 0.12).delay(0.06)) { shutterFlash = false }
        if camera.canCaptureFullRes {
            camera.captureFullResStill { cg in
                guard let cg else {
                    // Sensor capture failed — degrade gracefully to the preview.
                    if let frame = camera.previewImage { saveStill(UIImage(cgImage: frame)) }
                    return
                }
                saveStill(UIImage(cgImage: cg))
            }
        } else if let frame = camera.previewImage {
            saveStill(UIImage(cgImage: frame))
        }
    }

    private func saveStill(_ image: UIImage) {
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
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            stillSavedFlash += 1
            flash("Saved to Photos")
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
/// photo mode has a white core.
private struct CameraShutterButton: View {
    let isRecording: Bool
    var photoMode: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 70, height: 70)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 28)
                    .fill(photoMode ? Color.white : LumaTheme.recordRed)
                    .frame(width: isRecording ? 28 : 56, height: isRecording ? 28 : 56)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isRecording)
            .animation(.easeOut(duration: 0.18), value: photoMode)
            .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(photoMode ? "Take photo" : (isRecording ? "Stop recording" : "Record"))
    }
}

/// Tap-to-focus reticle — monochrome, because a gold box over footage biases
/// the very perception the screen exists to serve. Pure chrome; the device work
/// happens in the controller.
private struct CameraFocusReticle: View {
    var pulse: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(.white, lineWidth: 1.2)
            .frame(width: 72, height: 72)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(.white.opacity(0.9), lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
            .transition(.scale(scale: 1.3).combined(with: .opacity))
            .allowsHitTesting(false)
            .shadow(color: .black.opacity(0.5), radius: 4)
    }
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
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
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

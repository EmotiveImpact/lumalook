import SwiftUI
import CoreImage
import AVFoundation
import Photos

// =============================================================================
// LDCameraDemoView — the Camera rebuilt in the Lens-Distortions direction.
// A WORKING preview, not a mock: it drives the real `CameraController`, the
// real `LookPipeline` and the real library. Reachable headlessly with
// LUMA_ROUTE=ldCamera (+ LUMA_SEED_CAMFRAME to feed the viewfinder in the sim).
//
// FEATURE INVENTORY vs CameraLiveLookView — nothing is dropped for the look.
//
//   ✓ Capture-format chip (live off camera.spec, never lies)
//   ✓ Resolution / frame rate / codec selection  (drawer panel, not a sheet)
//   ✓ Look filmstrip — every tile is the REAL grade of the live frame
//   ✓ OFF tile with intensity stash (tap twice restores the old strength)
//   ✓ Look intensity — now a first-class drawer slider, not buried in a sheet
//   ✓ All Looks → the full LookBrowserSheet (purchased packs reachable)
//   ✓ Zoom — tap to cycle 0.5/1/2/3×, continuous pinch on the viewfinder
//   ✓ EV bias                      (dial)
//   ✓ White balance (kelvin)       (dial)
//   ✓ Manual focus / AF            (dial)
//   ✓ ISO                          (dial)
//   ✓ Shutter angle → 1/x at fps   (dial)
//   ✓ PRO panel — the five readouts as a selector + ONE shared ruler dial
//   ✓ Auto all (drops manual exposure, WB, focus and the AE/AF lock)
//   ✓ Zebras            (real ZebraRenderer pass on the preview)
//   ✓ Focus peaking     (real FocusPeakingRenderer pass)
//   ✓ Rule-of-thirds grid
//   ✓ Gyro level horizon
//   ✓ Frame guides — cycles 2.39 / 1.85 / 9:16 / 1:1 / 4:5; long-press = safe zone
//   ✓ Live scope — waveform → parade → vectorscope → histogram → false colour,
//     rendered at ~5 Hz. Moved OFF the picture onto the drawer.
//   ✓ Front/back flip (blocked mid-take, as the writer requires)
//   ✓ Graded still capture at full sensor resolution → Photos
//   ✓ Recording with baked-in look + SMPTE timecode
//   ✓ Live mic meter during the take
//   ✓ Post-recording hand-off card — Retake / Grade / Edit (carries the shot's
//     grade into the clip)
//   ✓ Gallery shortcut (→ Select Clip)
//   ✓ Tap-to-focus with reticle, long-press AE/AF lock + lock badge
//   ✓ Saved-to-Photos + permission-denied status captions
//   ✓ Camera-unavailable / permission-denied fallback with Settings deep link
//   ✓ LUMA_SEED_CAMFRAME / _CAMASSIST / _CAMPRO headless seeding preserved
//
//   ✗ Nothing is out of scope. Two things are DEVICE QA only (wired here, but
//     the simulator cannot exercise them): the actual sensor writes — flip,
//     full-res still, ISO/shutter/WB/focus/zoom lock-and-set — and the
//     AVAssetWriter recording path. The stub feeds `previewImage` so every
//     piece of chrome above is still screenshot-verifiable headlessly.
//
// THE DESIGN LANGUAGE (extending LDGradeDemoView)
//   1. The image is the interface. The viewfinder letterboxes to the 9:16
//      capture aspect — what you frame IS what is written — and then every
//      control moves ONTO the black mattes above and below it. Only overlays
//      that must register with the picture (grid, level, guides, reticle)
//      are ever drawn on the frame.
//   2. Monochrome chrome. The single permitted exception is the armed/recording
//      state (red) and the scope's own trace.
//   3. Stroke means selection — one thin white ring, on the selected look only.
//   4. The tile IS the preview.
//   6. TechReadout mono microtype for every number.
//   7. Tool rows are icon-over-label and unboxed, the last item clipped.
// =============================================================================

struct LDCameraDemoView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()
    @StateObject private var thumbs = LookThumbs()

    /// Which expandable panel the drawer is showing. One at a time — the
    /// drawer is a single object, not a stack of trays.
    private enum Panel: Equatable { case none, pro, format }
    @State private var panel: Panel = .none
    @State private var activeProParam: ProParameter = .shutter

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
    @State private var showLookBrowser = false
    @State private var stashedLookIntensity: Double?

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topMatte
                viewfinder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                drawer
            }

            if let recording = camera.lastRecordingURL, !camera.isRecording {
                LDHandOffCard(url: recording,
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
        .lumaToolSheet(isPresented: $showLookBrowser, style: .panel) {
            LookBrowserSheet(context: .camera, intensity: $app.settings.intensity)
        }
        .onAppear { start() }
        .onDisappear { camera.stopSession() }
        .onChange(of: camera.isRecording) { _, recording in
            recordStart = recording ? Date() : nil
        }
        .task(id: scopeMode) { await runScopeLoop() }
        .onReceive(camera.$previewImage) { frame in
            guard liveThumbSource == nil, let frame else { return }
            liveThumbSource = CIImage(cgImage: frame)
            thumbs.render(source: liveThumbSource, library: stripLooks,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
    }

    private func start() {
        panel = .none
        camera.lookState = app.lookState
        camera.requestAndStart()
        #if DEBUG
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
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                matteButton(system: "xmark") { dismiss() }

                Button {
                    panel = panel == .format ? .none : .format
                    LumaHaptics.shared.tap()
                } label: {
                    CaptureFormatChip(spec: camera.spec)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.lumaPress)
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.45 : 1)

                Spacer(minLength: 0)

                // The one number that must never leave the top line: what the
                // lens is actually doing.
                TechReadout(String(format: "%.1f×", camera.zoomFactor), size: 10,
                            color: .white.opacity(0.8))

                matteButton(system: "photo.on.rectangle") { app.path = [.selectClip] }
            }

            // The status line — recording, mic, captions. On the matte, so a
            // take never gets a red pill stamped across the subject's face.
            statusLine
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 10) {
            if camera.isRecording {
                // The permitted colour exception: armed means armed.
                Circle()
                    .fill(LumaTheme.recordRed)
                    .frame(width: 8, height: 8)
                TimelineView(.periodic(from: recordStart ?? Date(), by: 1.0 / 30.0)) { context in
                    TechReadout(Timecode.string(
                        seconds: context.date.timeIntervalSince(recordStart ?? context.date)),
                                size: 11, color: .white)
                }
                // The real meter, desaturated: the segment count still reads
                // level and clipping, without a teal bar on a mono line.
                InputMeterView(level: camera.audioLevel)
                    .grayscale(1)
            } else if let statusCaption {
                TechReadout(statusCaption, size: 10, color: .white.opacity(0.75))
                    .id(statusCaption)
                    .transition(.opacity)
            } else {
                TechReadout(idleStatusLine, size: 10, color: .white.opacity(0.34))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.18), value: statusCaption)
    }

    /// With nothing happening the line still earns its space: it states the
    /// exposure the camera has settled on.
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
                            Task {
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
            // full 150pt reference width), it just no longer turns green over
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
                    LDFocusReticle(pulse: reticlePulse)
                        .position(p)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if camera.aeafLocked {
                    TechReadout("AE/AF LOCK", size: 9, color: .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: camera.aeafLocked)
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        // A hairline is the one stroke allowed over live video: it is what
        // separates an unpredictable frame from the matte around it.
        .overlay(Rectangle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .contentShape(Rectangle())
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            } else if camera.cameraUnavailable {
                Text("No camera on this device")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                TechReadout("RUN ON IPHONE TO SHOOT LIVE", size: 9,
                            color: .white.opacity(0.45))
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
            filmstrip.padding(.bottom, 10)
            intensityRow.padding(.bottom, 12)
            toolRow.padding(.bottom, panel == .none ? 12 : 10)

            switch panel {
            case .pro:    proPanel.padding(.bottom, 12)
            case .format: formatPanel.padding(.bottom, 12)
            case .none:   EmptyView()
            }

            captureRow
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
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
                    Color(white: 0.08)
                }
            }
            .frame(width: 200, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                TechReadout(scopeMode?.title ?? "", size: 9, color: .white.opacity(0.72))
                Text("Reading the graded frame")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.32))
                Button {
                    scopeMode = scopeMode?.next
                    LumaHaptics.shared.tap()
                } label: {
                    TechReadout("NEXT SCOPE", size: 9, color: .white.opacity(0.7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .transition(.opacity)
    }

    // MARK: Look readout + filmstrip

    private var stripLooks: [LibraryLook] { app.library.stripLooks() }

    /// The one name surface — the tiles carry no captions at 56pt.
    private var lookReadout: some View {
        let name = app.selectedLUT?.displayName ?? app.selectedLook.name
        let strength = Int(app.settings.intensity.rounded())
        return HStack {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(strength == 0 ? 0.5 : 0.95))
                    .lineLimit(1)
                Text(strength == 0 ? "Off" : "\(strength)%")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            Button {
                showLookBrowser = true
                LumaHaptics.shared.tap()
            } label: {
                Text("All looks")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
        .padding(.horizontal, 18)
    }

    /// Every tile is the actual grade of the live frame. The selected one wears
    /// the only stroke in the drawer.
    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                offTile
                ForEach(stripLooks) { look in
                    Button {
                        app.select(look: look)
                        LumaHaptics.shared.tap()
                    } label: {
                        Group {
                            if let cg = thumbs.images[look.thumbKey] {
                                Image(decorative: cg, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color(white: 0.12)
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        // clipShape clips pixels, NOT touches — without this the
                        // overflowing fill steals taps from its neighbours.
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            if app.isCurrent(look) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(.white, lineWidth: 2)
                            }
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
                Button {
                    showLookBrowser = true
                    LumaHaptics.shared.tap()
                } label: {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(white: 0.10))
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
        .lumaEdgeFade(leading: 18, trailing: 18)
        .sensoryFeedback(.selection, trigger: app.selectedLook.id)
        .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
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
                .fill(Color(white: 0.10))
                .frame(width: 56, height: 56)
                .overlay {
                    TechReadout("OFF", size: 9,
                                color: .white.opacity(active ? 0.95 : 0.45))
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

    /// Intensity is a shooting decision, so it is on the drawer rather than two
    /// taps deep inside a browser sheet.
    private var intensityRow: some View {
        HStack(spacing: 12) {
            Text("Strength")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Slider(value: $app.settings.intensity, in: 0...100)
                .tint(.white.opacity(0.85))
            Text("\(Int(app.settings.intensity.rounded()))%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 18)
    }

    // MARK: Tool row — icon over label, unboxed, last item deliberately clipped

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Exposure tools show their VALUE, not a glyph. A thermometer
                // does not tell you the white balance is 5600K; "5600K" does.
                // The number is the better icon, and it is live.
                valueTool(String(format: "%.1f×", camera.zoomFactor), "Zoom",
                          on: camera.zoomFactor != 1) {
                    camera.cycleZoom()
                    LumaHaptics.shared.tap()
                }
                valueTool(readout(for: .iso), "ISO", on: camera.manualExposure) {
                    openPro(.iso)
                }
                valueTool(readout(for: .shutter), "Shutter", on: camera.manualExposure) {
                    openPro(.shutter)
                }
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
                tool("arrow.triangle.2.circlepath", "Flip",
                     on: camera.cameraPosition == .front,
                     enabled: !camera.isRecording) {
                    camera.flipCamera()
                    LumaHaptics.shared.tap()
                }
                tool("rectangle.dashed", frameGuide == .off ? "Guides" : frameGuide.label,
                     on: frameGuide != .off) {
                    let all = FrameGuide.allCases
                    let idx = (all.firstIndex(of: frameGuide)! + 1) % all.count
                    frameGuide = all[idx]
                    flash(frameGuide == .off ? "Guides off" : "Guide \(frameGuide.label)")
                }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    showSafeZone.toggle()
                    flash(showSafeZone ? "Safe zone on" : "Safe zone off")
                })
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
                tool("rectangle.on.rectangle", "Format", on: panel == .format) {
                    panel = panel == .format ? .none : .format
                }
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
    /// sentence case. Weight and contrast do the work that 8pt tracked caps
    /// at 42% white could not.
    private func valueTool(_ value: String, _ label: String, on: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(on ? .white : .white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 11, weight: .medium))
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

    private var proPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(ProParameter.allCases) { parameter in
                    LDProReadout(parameter: parameter,
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

            LDRulerDial(ticks: dialTicks(for: activeProParam),
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
            formatRow("RESOLUTION", options: CameraSpec.Resolution.allCases,
                      label: { $0.rawValue }, isOn: { camera.spec.resolution == $0 }) { r in
                var s = camera.spec; s.resolution = r; camera.setSpec(s)
            }
            formatRow("FRAME RATE", options: CameraSpec.fpsOptions,
                      label: { "\($0)" }, isOn: { camera.spec.fps == $0 }) { f in
                var s = camera.spec; s.fps = f; camera.setSpec(s)
            }
            formatRow("CODEC", options: CameraSpec.Codec.allCases,
                      label: { $0.rawValue }, isOn: { camera.spec.codec == $0 }) { c in
                var s = camera.spec; s.codec = c; camera.setSpec(s)
            }
        }
        .padding(.horizontal, 18)
        .transition(.opacity)
    }

    private func formatRow<T: Hashable>(_ title: String, options: [T],
                                        label: @escaping (T) -> String,
                                        isOn: @escaping (T) -> Bool,
                                        pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 10) {
            TechReadout(title, size: 8, color: .white.opacity(0.34))
                .frame(width: 84, alignment: .leading)
            ForEach(options, id: \.self) { option in
                Button {
                    pick(option)
                    LumaHaptics.shared.tap()
                } label: {
                    TechReadout(label(option), size: 10,
                                color: .white.opacity(isOn(option) ? 0.95 : 0.42))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        // Selection is the ring. Everything else is a bare word.
                        .overlay {
                            if isOn(option) {
                                Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Capture row

    private var captureRow: some View {
        ZStack {
            LDShutterButton(isRecording: camera.isRecording) {
                camera.toggleRecording()
            }
            HStack {
                matteButton(system: "photo.on.rectangle") { app.path = [.selectClip] }
                Spacer()
                matteButton(system: "camera") { captureStill() }
            }
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 6)
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.isRecording)
        .sensoryFeedback(.success, trigger: stillSavedFlash)
    }

    // MARK: - Actions

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
        flash(scopeMode.map { "SCOPE \($0.rawValue.uppercased())" } ?? "SCOPE OFF")
        LumaHaptics.shared.tap()
    }

    private func autoAll() {
        camera.resetAutoExposure()
        camera.resetAutoWB()
        camera.resetAutoFocus()
        camera.unlockAEAF()
        flash("AUTO ALL")
        LumaHaptics.shared.tap()
    }

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
        if camera.canCaptureFullRes {
            camera.captureFullResStill { cg in
                guard let cg else {
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
                let denied = "TURN ON ADD PHOTOS ONLY IN SETTINGS"
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
            flash("SAVED TO PHOTOS")
        }
    }

    // MARK: - Dial stops (cine practice: discrete, repeatable between takes)

    private static let isoStops: [Float] = [25, 32, 50, 64, 100, 125, 160, 200, 250, 320,
                                            400, 500, 640, 800, 1000, 1250, 1600, 2000,
                                            2500, 3200, 4000, 5000, 6400]
    private static let shutterAngles: [Double] = [360, 270, 180, 90, 45]
    private static let wbStops: [Float] = [2500, 2800, 3200, 3600, 4000, 4500, 5000,
                                           5600, 6500, 7500, 9000]
    private static let evStops: [Float] = [-2, -1.7, -1.3, -1, -0.7, -0.3, 0,
                                            0.3, 0.7, 1, 1.3, 1.7, 2]
    private static let focusStops: [Float] = stride(from: 0.0, through: 1.0, by: 0.1)
        .map { Float($0) }

    private var isoStopsInRange: [Float] {
        let range = camera.isoRange
        let inRange = Self.isoStops.filter { range.contains($0) }
        return inRange.isEmpty ? Self.isoStops : inRange
    }

    private func shutterLabel(_ angle: Double) -> String {
        "1/\(Int((360.0 / max(angle, 1)) * Double(camera.spec.fps)))"
    }

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

// MARK: - Monochrome chrome parts
//
// These are the LD-language counterparts of `ProReadout`, `RulerDial` and the
// shutter. They are not a parallel token set — they use the same LumaTheme
// values and the same TechReadout voice; they simply drop the violet accent,
// which this direction reserves for nothing at all.

/// One of the five pro readouts. Tapping it re-targets the shared dial.
private struct LDProReadout: View {
    let parameter: ProParameter
    let value: String
    var auto: Bool = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                TechReadout(auto ? "\(parameter.rawValue) A" : parameter.rawValue, size: 8,
                            color: .white.opacity(active ? 0.8 : 0.32))
                Text(value)
                    .font(.system(size: 15, weight: active ? .bold : .medium, design: .monospaced))
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
private struct LDRulerDial: View {
    let ticks: [String]
    let index: Int
    let onChange: (Int) -> Void

    private let stride: CGFloat = 46
    @State private var dragBase: Int?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(ticks.indices, id: \.self) { i in
                    let current = i == index
                    VStack(spacing: 5) {
                        Rectangle()
                            .fill(.white.opacity(current ? 0.95 : 0.20))
                            .frame(width: current ? 2 : 1, height: current ? 15 : 9)
                        Text(ticks[i])
                            .font(.system(size: current ? 12 : 10,
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

/// White ring, red core. Red is the ONE colour this screen allows itself:
/// armed is a state you must never have to read.
private struct LDShutterButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 28)
                    .fill(LumaTheme.recordRed)
                    .frame(width: isRecording ? 28 : 56, height: isRecording ? 28 : 56)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isRecording)
            .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
    }
}

/// Tap-to-focus reticle — monochrome, because a gold box over footage biases
/// the very perception the screen exists to serve.
private struct LDFocusReticle: View {
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
private struct LDHandOffCard: View {
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
                    Color(white: 0.10)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            TechReadout("CLIP SAVED · LOOK BAKED IN", size: 9, color: .white.opacity(0.55))

            HStack(spacing: 0) {
                handButton("RETAKE", solid: false, action: onRetake)
                handButton("GRADE", solid: false, action: onGrade)
                handButton("EDIT", solid: true, action: onEdit)
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
            TechReadout(title, size: 10, color: solid ? .black : .white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(solid ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }
}

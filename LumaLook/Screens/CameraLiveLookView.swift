import SwiftUI
import CoreImage
import AVFoundation
import Photos

/// Full-bleed cinematic viewfinder: the camera feed owns the entire
/// screen and every control floats above it on scrims and glass —
/// the shape of a real camera app, not a page with a preview box.
struct CameraLiveLookView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var camera = CameraController()
    @StateObject private var thumbs = LookThumbs()
    @State private var liveThumbSource: CIImage?
    @State private var showGrid = false
    /// D2 — the gyro horizon is its own assist now, independent of the grid.
    @State private var showLevel = false
    @State private var recordStart: Date?
    @State private var statusCaption: String?
    @State private var stillSavedFlash = 0
    /// C1 — focus reticle (view-space position; fades out after a beat).
    @State private var reticlePoint: CGPoint?
    @State private var reticlePulse = false
    /// C2 — pinch-zoom gesture state.
    @State private var isPinching = false
    /// C3 — capture-format picker sheet.
    @State private var showFormatSheet = false
    /// C10 — aspect frame guide + social safe zone.
    @State private var frameGuide: FrameGuide = .off
    @State private var showSafeZone = false
    /// C6/C7/D2 — manual exposure + white balance panel, now an in-frame
    /// bottom-third overlay rather than a sheet (a sheet dims the subject).
    @State private var showProPanel = false
    /// D2 — which of the five readouts the shared ruler dial is driving.
    @State private var activeProParam: ProParameter = .shutter
    /// C13 — live viewfinder scope (nil = off).
    @State private var scopeMode: ScopeMode?
    @State private var scopeImage: CGImage?
    /// Unified look browser over the viewfinder (mid detent, undimmed).
    @State private var showLookBrowser =
        ProcessInfo.processInfo.environment["LUMA_SEED_BROWSER"] == "1"
    /// OFF-tile stash so tapping OFF twice restores the previous strength.
    @State private var stashedLookIntensity: Double?

    /// Graded still capture — C5: shoots the FULL sensor resolution through
    /// AVCapturePhotoOutput and grades it with the live look (the old path
    /// saved the ~1MP preview buffer). Sim stub falls back to the preview.
    private func captureStill() {
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
                // different wording never matched, so the pill stayed pinned
                // over the viewfinder forever.
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
            statusCaption = "Saved to Photos"
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if statusCaption == "Saved to Photos" { statusCaption = nil }
        }
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            viewfinder

            if showGrid {
                RuleOfThirdsGrid()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            // C11 — gyro horizon level: line counter-rotates with roll,
            // snaps green when level. D2 splits it off the grid so each
            // assist chip owns exactly one overlay.
            if showLevel {
                LevelIndicator()
                    .transition(.opacity)
            }

            // C10 — frame guide mattes sit over the feed, under the controls.
            if frameGuide != .off {
                FrameGuidesOverlay(guide: frameGuide, showSafeZone: showSafeZone)
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                topStrip
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    .background {
                        LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .top)
                    }

                Spacer()

                // D1 — the bottom cluster steps aside for the pro panel so
                // the two never stack into two-thirds of the frame.
                if !showProPanel {
                    VStack(spacing: 12) {
                        activeLookReadout
                        looksRow
                        bottomControls
                    }
                    .padding(.top, 26)
                    .background {
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.8)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Hand-off card: the recording returns a result (img.ly pattern) —
            // Retake / Grade / Edit, footage lands where you choose.
            if let recording = camera.lastRecordingURL, !camera.isRecording {
                HandOffCard(url: recording,
                            onRetake: { camera.lastRecordingURL = nil },
                            onGrade: {
                                camera.lastRecordingURL = nil
                                app.selectedVideoURL = recording
                                app.path = [.selectClip, .applyLook]
                            },
                            onEdit: {
                                camera.lastRecordingURL = nil
                                let editor = app.editor
                                // Carry the shot's look into the clip so the
                                // grade you framed with survives into editing.
                                let shotGrade = ClipGrade(
                                    baseLookName: app.selectedLUT == nil ? app.selectedLook.name : "",
                                    lutID: app.selectedLUT?.id,
                                    settings: app.settings)
                                Task {
                                    await editor.addClip(from: recording)
                                    if let id = editor.clips.last?.id {
                                        editor.selectedClipID = id
                                        editor.setClipGrade(id: id, shotGrade)
                                    }
                                }
                                app.path = [.editor]
                            })
                    // The card is a dialogue, not a bar: capped so it never
                    // stretches into a 410pt-wide slab on a Pro Max, and on
                    // the app's 20pt gutter rather than a 10pt one.
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 200)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(50)
            }

            // C13 — live mini-scope, bottom-left above the look strip.
            if scopeMode != nil, let scopeImage {
                Image(decorative: scopeImage, scale: 1)
                    .resizable()
                    .frame(width: 176, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.25), lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        TechReadout(scopeMode?.rawValue.uppercased() ?? "", size: 8,
                                    color: .white.opacity(0.8))
                            .padding(4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(.leading, 16)
                    .padding(.bottom, showProPanel ? 300 : 250)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Status pills float over the feed, top centre.
            VStack(spacing: 8) {
                if camera.isRecording {
                    RecordingPill(start: recordStart ?? Date())
                    // C12 — live mic meter rides under the REC pill: clipped or
                    // dead audio is visible DURING the take, not after.
                    // InputMeterView already carries its own padded capsule —
                    // wrapping it in a second one drew a pill inside a pill.
                    // It only needs the dark backing under its material so the
                    // segments stay readable over a blown-out frame.
                    InputMeterView(level: camera.audioLevel)
                        .background(.black.opacity(0.35), in: Capsule())
                        .transition(.opacity)
                }
                if let statusCaption {
                    TechReadout(statusCaption, size: 11)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .id(statusCaption)
                }
                if camera.lastSavedToPhotos, camera.lastRecordingURL == nil {
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumaTheme.teal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(.black.opacity(0.3), in: Capsule())
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 58)

            // D1 — the pro rail: every viewfinder control lives on the right
            // edge so nothing crosses the subject zone.
            if !showProPanel {
                proRail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .transition(.opacity)
            }

            // D2 — the pro panel is bottom-third chrome, not a sheet.
            if showProPanel {
                proPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom))
                    .zIndex(20)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showProPanel)
        // The full library over the viewfinder: opens at a mid detent so the
        // live feed stays visible, undimmed and interactive above the sheet —
        // pick a purchased pack look and frame the shot through it.
        .lumaToolSheet(isPresented: $showLookBrowser, style: .panel) {
            LookBrowserSheet(context: .camera, intensity: $app.settings.intensity)
        }
        .sheet(isPresented: $showFormatSheet) {
            CameraFormatSheet(camera: camera)
                // Three labelled chip rows + a title + the bottom safe-area
                // inset measure ~315pt; at 300 the last row was squeezed
                // against the home indicator.
                .presentationDetents([.height(344)])
                .presentationBackground(LumaTheme.background)
                .preferredColorScheme(.dark)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // Defensive: a restored/hot scene must never open ON the Pro sheet
            // — a pro exposure panel over a black feed is the worst possible
            // first frame of the camera (seen intermittently in audit).
            showProPanel = false
            showFormatSheet = false
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
            // Verification: open D2 with a chosen active parameter,
            // e.g. LUMA_SEED_CAMPRO=shutter (bare "1" defaults to shutter).
            if let pro = ProcessInfo.processInfo.environment["LUMA_SEED_CAMPRO"] {
                showProPanel = true
                if let match = ProParameter.allCases.first(where: {
                    $0.rawValue.lowercased() == pro.lowercased()
                }) {
                    activeProParam = match
                }
            }
            #endif
            thumbs.render(source: liveThumbSource, library: cameraStripLooks,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        .onDisappear { camera.stopSession() }
        .task(id: scopeMode) {
            // C13 render loop: ~5 Hz while a scope is up. The preview frame is
            // ALREADY graded, so the scope gets a neutral LookState.
            guard scopeMode != nil else { scopeImage = nil; return }
            let neutral = LookState()
            while !Task.isCancelled, let mode = scopeMode {
                if let frame = camera.previewImage {
                    scopeImage = await Scopes.render(frame: CIImage(cgImage: frame),
                                                     state: neutral, mode: mode,
                                                     size: CGSize(width: 176, height: 96))
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        .onChange(of: camera.isRecording) { _, recording in
            recordStart = recording ? Date() : nil
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.85),
                   value: camera.lastRecordingURL != nil)
        .animation(.easeOut(duration: 0.15), value: showGrid)
        .animation(.easeOut(duration: 0.15), value: showLevel)
        // Grade the look strip with a real frame from the live camera as
        // soon as one arrives.
        .onReceive(camera.$previewImage) { frame in
            guard liveThumbSource == nil, let frame else { return }
            liveThumbSource = CIImage(cgImage: frame)
            thumbs.render(source: liveThumbSource, library: cameraStripLooks,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
    }

    // MARK: - Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        Group {
            if camera.isRunning && !camera.cameraUnavailable {
                FilteredCameraPreview(
                    camera: camera,
                    onTapUnit: { unit, viewPoint in
                        if camera.aeafLocked {
                            camera.unlockAEAF()          // tap releases the lock
                        }
                        camera.focusExpose(at: unit)
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            reticlePoint = viewPoint
                            reticlePulse.toggle()
                        }
                        LumaHaptics.shared.tap()
                        Task {                           // reticle fades after 1.1 s
                            try? await Task.sleep(nanoseconds: 1_100_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { reticlePoint = nil }
                        }
                    },
                    onLongPress: {
                        camera.toggleAEAFLock()
                        LumaHaptics.shared.tap()
                    })
                .overlay {
                    if let p = reticlePoint {
                        FocusReticle(pulse: reticlePulse)
                            .position(p)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if camera.aeafLocked {
                        Text("AE/AF LOCK")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(LumaTheme.gold, in: Capsule())
                            .padding(.top, 110)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: camera.aeafLocked)
            } else {
                ZStack {
                    HeroImage(photo: .golden)
                    Color.black.opacity(0.38)
                    fallbackMessage
                }
            }
        }
        .ignoresSafeArea()
        // C2 — continuous pinch zoom, live on the whole viewfinder.
        // simultaneous so tap-to-focus and long-press keep working.
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if !isPinching { isPinching = true; camera.beginPinch() }
                    camera.updatePinch(scale: scale)
                }
                .onEnded { _ in isPinching = false }
        )
    }

    // MARK: - Top bar

    /// D1 — the top bar carries identity only: the way out, the honest
    /// capture-format signal, and the two framing assists that must stay one
    /// tap away while composing. Everything else moved to the rail or D2.
    private var topStrip: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 32, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            // Live from the ACTIVE spec (C3) — the HUD never lies. Tap to
            // change resolution / fps / codec.
            Button {
                showFormatSheet = true
                LumaHaptics.shared.tap()
            } label: {
                CaptureFormatChip(spec: camera.spec)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.lumaPress)
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.5 : 1)
            Spacer()
            // Only real controls live in the strip — no placebo buttons.
            // C10 — frame guides: tap cycles aspects, long-press toggles the
            // social safe zone (vertical guide only).
            Button {
                let all = FrameGuide.allCases
                let idx = (all.firstIndex(of: frameGuide)! + 1) % all.count
                frameGuide = all[idx]
                flashCaption(frameGuide == .off ? "GUIDES OFF" : "GUIDE \(frameGuide.label)")
            } label: {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(frameGuide != .off ? LumaTheme.accentBright : .white)
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                showSafeZone.toggle()
                flashCaption(showSafeZone ? "SAFE ZONE ON" : "SAFE ZONE OFF")
            })
            .sensoryFeedback(.selection, trigger: frameGuide)
            // C13 — live scope: cycles waveform → histogram → false colour.
            Button {
                switch scopeMode {
                case nil: scopeMode = .waveform
                case .waveform: scopeMode = .histogram
                case .histogram: scopeMode = .falseColor
                default: scopeMode = nil
                }
                flashCaption(scopeMode.map { "SCOPE \($0.rawValue.uppercased())" } ?? "SCOPE OFF")
            } label: {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(scopeMode != nil ? LumaTheme.accentBright : .white)
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    // MARK: - D1: right-edge pro rail

    /// Six equally-weighted chips down the edge read as a stack of buttons,
    /// not as an instrument. They are three classes of control, so the rail
    /// is now three objects: the zoom readout (a value), one glass cluster
    /// holding the three exposure controls (they belong together and all open
    /// the same panel), and the two session controls below it. Every hit
    /// target is still 40pt — only the visual weight came down.
    private var proRail: some View {
        VStack(spacing: 9) {
            ProRailButton {
                camera.cycleZoom()
                LumaHaptics.shared.tap()
            } label: {
                Text(String(format: "%.1f×", camera.zoomFactor))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .monospacedDigit()
            }

            ProRailGroup {
                ProRailButton(active: camera.evBias != 0, grouped: true) {
                    openPro(.ev)
                } label: {
                    Image(systemName: "plusminus.circle")
                        .font(.system(size: 17, weight: .medium))
                }
                ProRailDivider()
                ProRailButton(active: camera.manualWB, grouped: true) {
                    openPro(.wb)
                } label: {
                    Text("WB")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                ProRailDivider()
                ProRailButton(active: camera.manualFocus, grouped: true) {
                    openPro(.focus)
                } label: {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 17, weight: .medium))
                }
            }

            ProRailGroup {
                ProRailButton(active: camera.cameraPosition == .front, grouped: true) {
                    camera.flipCamera()
                    LumaHaptics.shared.tap()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                }
                .opacity(camera.isRecording ? 0.35 : 1)
                .disabled(camera.isRecording)
                ProRailDivider()
                ProRailButton(active: camera.manualExposure || camera.manualWB || camera.manualFocus,
                              grouped: true) {
                    openPro(camera.manualExposure ? .iso : .shutter)
                } label: {
                    Text("PRO")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(1)
                }
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
    }

    /// Opens D2 already targeting the parameter the rail button names, so a
    /// rail tap lands on the control it advertises rather than a generic panel.
    private func openPro(_ parameter: ProParameter) {
        activeProParam = parameter
        showProPanel = true
        LumaHaptics.shared.tap()
    }

    /// Transient state caption (Halide-style contextual labeling): flashes
    /// a small mono caption near the top for ~900ms, then fades.
    private func flashCaption(_ text: String) {
        withAnimation(.snappy(duration: 0.2)) { statusCaption = text }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if statusCaption == text {
                withAnimation(.easeOut(duration: 0.25)) { statusCaption = nil }
            }
        }
    }

    // MARK: - Looks

    /// What the camera strip shows — the LIBRARY strip: recently used, then
    /// favourites, then the rest (saved looks, installed pack LUTs and imports
    /// included), bounded so live thumbnail rendering stays cheap. The full
    /// library opens behind the All Looks tile, so every purchased pack is
    /// reachable while framing a shot.
    private var cameraStripLooks: [LibraryLook] {
        app.library.stripLooks()
    }

    /// D1 — the active look reads as a cinema-monitor LUT line above the
    /// filmstrip. Tapping it opens the browser, where intensity is set.
    private var activeLookReadout: some View {
        let name = app.selectedLUT?.displayName ?? app.selectedLook.name
        let strength = Int(app.settings.intensity.rounded())
        return Button {
            showLookBrowser = true
            LumaHaptics.shared.tap()
        } label: {
            // The strip carries no per-tile names, so this line is the ONE
            // name surface — it gets its own contrast carrier rather than
            // relying on a scrim that has not ramped up yet at this height.
            TechReadout(strength == 0 ? "\(name) · OFF" : "\(name) · \(strength)%",
                        size: 10, color: strength == 0 ? .white.opacity(0.7)
                                                       : LumaTheme.accentBright)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
    }

    private var looksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                // OFF leads the strip — shooting clean is one tap.
                offTile
                ForEach(cameraStripLooks) { look in
                    // Selection derives from ONE source of truth
                    // (app.isCurrent) so a LUT and a built-in can never
                    // highlight at the same time.
                    LookStripTile(look: look,
                                  image: thumbs.images[look.thumbKey],
                                  selected: app.isCurrent(look),
                                  size: CGSize(width: 52, height: 52),
                                  radius: 12,
                                  onMedia: true,
                                  // D1 — no per-tile captions on the camera
                                  // strip: 52pt fits no real look name, so the
                                  // mono readout above is the single name surface.
                                  showsName: false) {
                        app.select(look: look)
                        LumaHaptics.shared.tap()
                    }
                }
                AllLooksTile(size: CGSize(width: 52, height: 52), radius: 12, onMedia: true,
                             showsName: false) {
                    showLookBrowser = true
                    LumaHaptics.shared.tap()
                }
            }
            .padding(.horizontal, 20)
        }
        // Every other horizontal strip in the app fades at its edges; without
        // it the last tile is hard-cut by the screen edge and the All Looks
        // tile past it reads as nothing at all.
        //
        // The ramp width MATCHES the content inset above deliberately: at rest
        // the fade sits entirely over the 20pt gutter, so the first and last
        // tiles are never dimmed for no reason — and the moment the strip
        // scrolls, a tile leaving the frame gets a full 20pt ramp instead of
        // being guillotined by the screen edge. The old 12pt was too short to
        // read as a fade at all against a 52pt tile.
        .lumaEdgeFade(leading: 20, trailing: 20)
        .sensoryFeedback(.selection, trigger: app.selectedLook.id)
        .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
    }

    /// Dashed OFF tile: zero the grade to shoot clean, tap again to restore.
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
            // Same 52pt / radius-12 metrics as the look tiles beside it, and
            // one OFF label rather than the word twice on one control.
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.3))
                .frame(width: 52, height: 52)
                .overlay {
                    TechReadout("OFF", size: 10,
                                color: active ? LumaTheme.accentBright : .white.opacity(0.7))
                }
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]))
                    .foregroundStyle(active ? LumaTheme.accentBright : .white.opacity(0.3)))
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: - Bottom controls

    /// D1 — the shutter stays optically centred; the two secondary actions
    /// (open footage, shoot a graded still) sit on the outside so the row
    /// never grows a fourth control creeping toward the middle.
    private var bottomControls: some View {
        ZStack {
            ShutterButton(isRecording: camera.isRecording) {
                camera.toggleRecording()
            }
            HStack {
                secondaryCaptureButton("photo.on.rectangle") { app.path = [.selectClip] }
                Spacer()
                secondaryCaptureButton("camera") { captureStill() }
            }
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 6)
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.isRecording)
        .sensoryFeedback(.success, trigger: stillSavedFlash)
    }

    private func secondaryCaptureButton(_ symbol: String,
                                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: - D2: pro panel (bottom third only)

    private var proPanel: some View {
        VStack(spacing: 13) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: 38, height: 4)

            HStack {
                // D2 — a take can be started and stopped WITHOUT dismissing
                // the exposure controls: the record control follows the panel
                // into its header instead of disappearing with the shutter.
                Button {
                    camera.toggleRecording()
                } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: camera.isRecording ? 3 : 8)
                            .fill(LumaTheme.recordRed)
                            .frame(width: 16, height: 16)
                        Text(camera.isRecording ? "STOP" : "REC")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .tracking(1)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.lumaPress)
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: camera.isRecording)
                .sensoryFeedback(.impact(weight: .heavy), trigger: camera.isRecording)
                Spacer()
                Button("Auto all") {
                    autoAll()
                }
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(LumaTheme.accentBright)
                .buttonStyle(.lumaPress)
                Text("·").foregroundStyle(LumaTheme.textMuted)
                Button("Close") {
                    showProPanel = false
                    LumaHaptics.shared.tap()
                }
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(LumaTheme.accentBright)
                .buttonStyle(.lumaPress)
            }
            .padding(.horizontal, 20)

            HStack(spacing: 0) {
                ForEach(ProParameter.allCases) { parameter in
                    ProReadout(parameter: parameter,
                               value: readout(for: parameter),
                               auto: isAuto(parameter),
                               active: activeProParam == parameter) {
                        activeProParam = parameter
                        LumaHaptics.shared.tap()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14)

            // One dial, re-targeted by the readout row above it.
            RulerDial(ticks: dialTicks(for: activeProParam),
                      index: dialIndex(for: activeProParam)) { newIndex in
                applyDial(newIndex, to: activeProParam)
            }
            .padding(.horizontal, 20)

            // Left-aligned to the same 20pt gutter as the panel header. Centred
            // in the row they read as four chips floating in the middle of the
            // panel with no relationship to anything above them.
            HStack(spacing: 7) {
                CameraAssistChip(title: "Zebras", on: camera.zebrasOn) {
                    camera.zebrasOn.toggle()
                }
                CameraAssistChip(title: "Focus peaking", on: camera.peakingOn) {
                    camera.peakingOn.toggle()
                }
                CameraAssistChip(title: "Grid", on: showGrid) {
                    showGrid.toggle()
                }
                CameraAssistChip(title: "Level", on: showLevel) {
                    showLevel.toggle()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 10)
        // The background extends THROUGH the bottom safe area, so the home
        // indicator inset already clears the chips — padding here stacks on
        // top of it. Keep it symmetric with the 10pt above the grab handle.
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background { proPanelBackground }
        .overlay(alignment: .top) { Hairline() }
    }

    /// The panel fill runs all the way to the screen bottom (only the top
    /// corners round) — the home indicator must never sit on raw live video.
    /// The shape itself carries `ignoresSafeArea`, so the extension is filled
    /// rather than clipped away.
    private var proPanelBackground: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 22, topTrailing: 22))
        return ZStack {
            shape.fill(LumaTheme.bar.opacity(0.78))
            shape.fill(.ultraThinMaterial)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// The escape hatch: everything back to automatic in one tap, including
    /// the AE/AF lock, so no invisible manual state can survive it.
    private func autoAll() {
        camera.resetAutoExposure()
        camera.resetAutoWB()
        camera.resetAutoFocus()
        camera.unlockAEAF()
        flashCaption("AUTO ALL")
        LumaHaptics.shared.tap()
    }

    // MARK: - D2: dial stops

    /// Discrete stops, cine practice rather than continuous sliders — a
    /// detented dial is what makes a value repeatable between takes.
    private static let isoStops: [Float] = [25, 32, 50, 64, 100, 125, 160, 200, 250, 320,
                                            400, 500, 640, 800, 1000, 1250, 1600, 2000,
                                            2500, 3200, 4000, 5000, 6400]
    /// Ordered so faster shutters move RIGHT (1/30 → 1/240 at 30fps), matching
    /// the D2 mockup. 172.8° is gone: at any frame rate it prints within a
    /// frame or two of 180° and gave the user nothing to choose between.
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
        "1/\(Int((360.0 / max(angle, 1)) * Double(camera.spec.fps)))"
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
        case .iso:
            // Always the value the dial is pointing at — an "AUTO" here while
            // the dial highlighted a concrete stop was two truths at once.
            return "\(Int(camera.currentISO > 0 ? camera.currentISO : 100))"
        case .shutter:
            return shutterLabel(camera.shutterAngle)
        case .wb:
            return "\(Int(camera.wbTemperature))K"
        case .ev:
            return String(format: "%+.1f", camera.evBias)
        case .focus:
            return camera.manualFocus ? String(format: "%.1f", camera.lensPosition) : "AF"
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
        case .shutter:
            return nearest(camera.shutterAngle, in: Self.shutterAngles)
        case .wb:
            return nearest(camera.wbTemperature, in: Self.wbStops)
        case .ev:
            return nearest(camera.evBias, in: Self.evStops)
        case .focus:
            guard camera.manualFocus else { return 0 }
            return nearest(camera.lensPosition, in: Self.focusStops) + 1
        }
    }

    /// Every dial move writes straight through to the controller — moving the
    /// ISO or shutter stop is also what engages manual exposure, so there is
    /// no separate AUTO/MANUAL switch to forget.
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

    @ViewBuilder
    private var fallbackMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: camera.permissionDenied ? "lock.shield" : "camera.badge.ellipsis")
                .font(.system(size: 30))
                .foregroundStyle(.white)
            if camera.permissionDenied {
                Text("Camera access is off")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LumaTheme.accentBright)
            } else if camera.cameraUnavailable {
                Text("No camera on this device")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Run LumaLook on an iPhone to shoot with live looks.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Shutter

/// Camera-app style shutter: white ring, red core that morphs into a
/// rounded square while recording, with a breathing glow.
private struct ShutterButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var breathe = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(LumaTheme.recordRed.opacity(breathe ? 0.45 : 0.12), lineWidth: 10)
                        .frame(width: 96, height: 96)
                        .scaleEffect(breathe ? 1.04 : 0.96)
                }
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 82, height: 82)
                RoundedRectangle(cornerRadius: isRecording ? 9 : 34)
                    .fill(LumaTheme.recordRed)
                    .frame(width: isRecording ? 34 : 68, height: isRecording ? 34 : 68)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isRecording)
        }
        .buttonStyle(.lumaPress)
        .onChange(of: isRecording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { breathe = false }
            }
        }
    }
}

/// Pulsing REC indicator with a live SMPTE timecode, shown over the
/// viewfinder while recording. The timecode ticks at frame rate off the
/// recording start date, so it stops the moment the pill disappears.
private struct RecordingPill: View {
    let start: Date
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(LumaTheme.recordRed)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
            Text("REC")
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.white)
            TimelineView(.periodic(from: start, by: 1.0 / 30.0)) { context in
                Text(Timecode.string(seconds: context.date.timeIntervalSince(start)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .kerning(0.6)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.black.opacity(0.3), in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}


// MARK: - Recording hand-off (queue #5)

/// After a take: the clip is saved, now choose where it goes. The camera
/// behaves like an appliance that returns a result.
private struct HandOffCard: View {
    let url: URL
    let onRetake: () -> Void
    let onGrade: () -> Void
    let onEdit: () -> Void

    @State private var thumb: CGImage?

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                Group {
                    if let thumb {
                        Image(decorative: thumb, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LumaTheme.surfaceStrong
                    }
                }
                .frame(width: 52, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip saved")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    TechReadout("SAVED TO PHOTOS · LOOK BAKED IN", size: 8,
                                color: LumaTheme.textMuted)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                handButton("RETAKE", solid: false, action: onRetake)
                handButton("GRADE", solid: false, action: onGrade)
                handButton("EDIT →", solid: true, action: onEdit)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .background(LumaTheme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            thumb = try? await generator.image(
                at: CMTime(seconds: 0.05, preferredTimescale: 600)).image
        }
    }

    private func handButton(_ title: String, solid: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(solid
                            ? AnyShapeStyle(LinearGradient(colors: [LumaTheme.accent, LumaTheme.accentDeep],
                                                           startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(.white.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                // No stroke: these sit INSIDE the card, on a surface whose
                // value is known, so they separate by fill like every other
                // button in the app. The card itself keeps its hairline —
                // that one has live video behind it and needs the edge.
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }
}


/// C1 — the tap-to-focus reticle: a rounded square that lands with a small
/// settle, camera-app grammar. Pure chrome; the device work happens in the
/// controller.
private struct FocusReticle: View {
    var pulse: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(LumaTheme.gold, lineWidth: 1.6)
            .frame(width: 76, height: 76)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(LumaTheme.gold.opacity(0.9), lineWidth: 1.2)
                    .frame(width: 8, height: 8)
            }
            .scaleEffect(pulse ? 1.0 : 1.0)   // keyed by toggle to re-trigger
            .transition(.scale(scale: 1.35).combined(with: .opacity))
            .allowsHitTesting(false)
            .shadow(color: .black.opacity(0.5), radius: 4)
    }
}


/// C3 — capture-format picker: resolution / fps / codec chips. Writes through
/// CameraController.setSpec, which re-formats the live session and persists.
private struct CameraFormatSheet: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    private func chipRow<T: Hashable>(_ title: String, options: [T],
                                      label: @escaping (T) -> String,
                                      isOn: @escaping (T) -> Bool,
                                      pick: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TechReadout(title, size: 10, color: LumaTheme.textMuted)
            HStack(spacing: 7) {
                ForEach(options, id: \.self) { option in
                    Button {
                        pick(option)
                        LumaHaptics.shared.tap()
                    } label: {
                        // These are all numeric/format values, so they speak in
                        // the mono instrument voice — and the selected one is
                        // stated by accent type on a raised surface, not by a
                        // block of saturated violet with black text on it.
                        Text(label(option))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .kerning(0.6)
                            .foregroundStyle(isOn(option) ? LumaTheme.accentBright
                                                          : .white.opacity(0.7))
                            .padding(.horizontal, 15).padding(.vertical, 9)
                            .background(isOn(option) ? LumaTheme.cardRaised : LumaTheme.surface,
                                        in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Capture Format")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.footnote.weight(.semibold)).foregroundStyle(LumaTheme.accentBright)
            }
            chipRow("RESOLUTION", options: CameraSpec.Resolution.allCases,
                    label: { $0.rawValue }, isOn: { camera.spec.resolution == $0 }) { r in
                var s = camera.spec; s.resolution = r; camera.setSpec(s)
            }
            chipRow("FRAME RATE", options: CameraSpec.fpsOptions,
                    label: { "\($0)" }, isOn: { camera.spec.fps == $0 }) { f in
                var s = camera.spec; s.fps = f; camera.setSpec(s)
            }
            chipRow("CODEC", options: CameraSpec.Codec.allCases,
                    label: { $0.rawValue }, isOn: { camera.spec.codec == $0 }) { c in
                var s = camera.spec; s.codec = c; camera.setSpec(s)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}


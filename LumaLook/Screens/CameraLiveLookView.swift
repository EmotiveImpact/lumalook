import SwiftUI
import CoreImage
import AVFoundation
import Photos

// =============================================================================
// CameraLiveLookView — camera A from the Camera Lab, "one camera that grows".
//
// Built to the lab's own measurements (LumaLook/Design/CameraDial.swift holds
// the parts). The lab was drawn on a 402 x 874 screen; everything here hangs
// off the top safe area or the bottom edge at the same distances, so the
// plate, the dial and the shutter sit where they were designed on every
// iPhone.
//
// The picture fills the whole screen. On it, from the top:
//   · close, the capture format (the take's clock while rolling) and the
//     live histogram
//   · the look at top left (ring, name, code and strength, a dot for each
//     favourite) and Pro at top right
//   · the chips over the dial: Lens (Aperture in Portrait), Shutter, ISO,
//     Exposure, WB, Focus. One big dial on an arc centred on the shutter
//     turns whichever chip is lit; drag it up for Pro
//   · the plate: last shot, flip, the shutter in its notch, and Photo ·
//     Video · Slo-mo · Portrait
//
// Four ways it grows:
//   1. Swipe the picture sideways to step through your favourite looks.
//      Tap the look for every look in the app (CameraLooksSheet), which
//      opens over the lower picture while the picture slides up.
//   2. Pull the dial or the plate up, or tap Pro: six readouts on one ruler
//      and every tool as a tile.
//   3. Press and hold anywhere on the picture: the tools fan out above the
//      thumb. Slide onto one and let go. Let go where you pressed to lock
//      focus and exposure there.
//   4. Turn the phone sideways: readouts along the top, the look at bottom
//      left, tools at bottom right, every label upright. The plate and the
//      shutter stay where the thumb already is.
//
// FEATURE INVENTORY. Nothing from the previous camera was dropped:
//   ✓ Capture format off camera.activeSpec; resolution, frame rate and codec
//     (tap the format chip, or Pro → Format, or Format in the fan)
//   ✓ Every look in the app with live graded tiles, search, filters,
//     favourites and strength; paid looks free to try, asked for at record
//   ✓ Zoom: the Lens chip on the dial, and continuous pinch
//   ✓ Shutter, ISO, exposure, white balance and manual focus on the dial and
//     in Pro, each with Auto; Auto all in Pro
//   ✓ Zebras, focus peaking, grid, level, frame guides (long-press for the
//     social safe zone), live scope in five modes, histogram
//   ✓ AE/AF lock (hold and let go, or the sideways tools) with its badge
//   ✓ Tap to focus; front/back flip (blocked mid-take)
//   ✓ Photo · Video · Slo-mo · Portrait; roll mode; portrait blur at the
//     dial's aperture; full-resolution graded stills
//   ✓ Recording with the look baked in, the take's clock, mic meter, the
//     saved-to-Photos caption and the hand-off card (Retake / Grade / Edit)
//   ✓ Last shot on the plate; permission and no-camera fallbacks
//   ✓ DEBUG seeds: CAMFRAME, CAMASSIST, CAMPRO, CAMMODE, CAMROLL, CAMFOCUS,
//     BROWSER, CAMLOOK, CAMLOCK, CAMLAND, CAMFAN, CAMSWIPE
//
//   DEVICE QA only: the sensor writes, recording, and turning the phone
//   (the simulator has no gravity, so LUMA_SEED_CAMLAND forces sideways).
// =============================================================================

struct CameraLiveLookView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()

    /// Pro, pulled up over the lower picture.
    @State private var proOpen = false
    /// The format card under the format chip.
    @State private var formatOpen = false

    /// What the dial, Pro's ruler and the sideways ruler turn.
    @State private var dialTarget: DialTarget = .lens

    /// Photo takes a graded still; Video records with the look baked in;
    /// Slo-mo records at the camera's highest rate and plays back slowed;
    /// Portrait takes a still with a depth blur. All four always show on the
    /// plate; the two a camera cannot do are dimmed.
    private enum CaptureMode: String, CaseIterable {
        case photo = "Photo", video = "Video", slowMo = "Slo-mo", portrait = "Portrait"

        var takesStills: Bool { self == .photo || self == .portrait }

        var icon: CamIcon {
            switch self {
            case .photo:    return .photo
            case .video:    return .video
            case .slowMo:   return .slomo
            case .portrait: return .portrait
            }
        }
    }
    @State private var captureMode: CaptureMode = .video
    /// Portrait's f-number, as an index into `apertureStops` (f/2.8).
    @State private var apertureIndex = 2
    /// Roll mode: an optional roll of 36 that the shutter counts down.
    @AppStorage("lumalook.camera.rollOn") private var rollOn = false
    @AppStorage("lumalook.camera.rollLeft") private var rollLeft = 36
    @State private var showRollDone = false
    /// The newest capture (or library item) for the thumb on the plate.
    @State private var lastShot: LastShot?
    /// The white blink when a still is taken.
    @State private var shutterFlash = false

    @State private var showGrid = false
    @State private var showLevel = false
    @State private var frameGuide: FrameGuide = .off
    @State private var showSafeZone = false
    @State private var scopeMode: ScopeMode?
    @State private var scopeImage: CGImage?
    @State private var recordStart: Date?
    @State private var statusCaption: String?
    @State private var stillSavedFlash = 0
    /// The square a tap (or a lock) leaves on the picture.
    @State private var focusMark: FocusMark?
    @State private var focusToken = 0
    /// DEBUG only: a unit point for a held square in the preview screenshot.
    @State private var focusSeed: CGPoint?
    @State private var isPinching = false
    /// A paid look is on the picture but not unlocked: shooting with it asks
    /// first (framing and previewing it stays free).
    @State private var lookLock: LookLock?

    // MARK: Looks
    /// Every look, over the lower picture (sideways: a panel at the side).
    @State private var showLookBrowser =
        ProcessInfo.processInfo.environment["LUMA_SEED_BROWSER"] == "1"
    @AppStorage(CameraFavourites.key) private var favouritesRaw = ""
    /// The camera's own frame before any look, for the looks' tiles.
    @State private var rawFrame: CIImage?
    @State private var rawFrameID = 0
    /// The look's name, large, for a moment after a swipe.
    @State private var nameFlash: CameraLook?
    @State private var nameFlashID = 0

    // MARK: A finger on the picture
    @State private var touch: TouchState?
    @State private var touchToken = 0
    @State private var swipe: SwipeState?
    @State private var swipeToken = 0
    /// The next look graded over a still of the frame, wiped in by a swipe.
    @State private var swipeReveal: CGImage?
    @State private var fan: FanState?
    /// The whole screen, edge to edge, and its top safe inset.
    @State private var screenSize: CGSize = .zero
    @State private var topInset: CGFloat = 59

    // MARK: Sideways
    /// DEBUG: LUMA_SEED_CAMLAND forces the sideways layout.
    @State private var forcedLandscape = false
    @State private var forcedClockwise = false
    /// The ruler under the sideways readouts.
    @State private var landscapeDropOpen = false

    private static let space = "camera"
    /// The lab's ease for sheets and the picture: quick out, soft landing.
    private static let glide = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)

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
            .onChange(of: camera.aeafLocked) { _, locked in
                // A held square belongs to the lock: it goes when the lock does.
                if !locked, focusMark?.hold == true { focusMark = nil }
            }
            .onChange(of: isLandscapeLayout) { _, _ in
                // Pro and the format card live upright; sideways has its own
                // readouts, so nothing carries across the turn.
                proOpen = false
                formatOpen = false
                landscapeDropOpen = false
                cancelTouch()
            }
            .onChange(of: showLookBrowser) { _, open in
                if open { refreshRawFrame() }
            }
            .task { await loadLibraryThumb() }
    }

    private var mainBody: some View {
        // The outer reader keeps the safe area (for the top inset, and the
        // keyboard under the looks' search); the inner one is the whole
        // screen, which everything is placed in.
        GeometryReader { safe in
            let top = safe.safeAreaInsets.top
            let keyboard = safe.safeAreaInsets.bottom
            GeometryReader { geo in
                screen(size: geo.size, top: top, keyboard: keyboard)
                    .onAppear {
                        screenSize = geo.size
                        topInset = top
                    }
                    .onChange(of: geo.size) { _, size in screenSize = size }
                    .onChange(of: top) { _, inset in topInset = inset }
            }
            .ignoresSafeArea()
        }
        .background(CamLab.ink.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .animation(Self.glide, value: proOpen)
        .animation(Self.glide, value: showLookBrowser)
        .animation(.easeOut(duration: 0.18), value: formatOpen)
        .animation(.easeOut(duration: 0.15), value: showGrid)
        .animation(.easeOut(duration: 0.15), value: showLevel)
        .animation(.easeOut(duration: 0.18), value: frameGuide)
        .animation(.easeOut(duration: 0.18), value: scopeMode)
        .animation(.easeOut(duration: 0.25), value: isLandscapeLayout)
        .animation(.easeOut(duration: 0.15), value: fan != nil)
        .animation(.easeOut(duration: 0.25), value: nameFlash?.id)
        .animation(.easeOut(duration: 0.2), value: statusCaption)
        .animation(.easeOut(duration: 0.18), value: camera.isRecording)
        .animation(.easeOut(duration: 0.18), value: camera.aeafLocked)
        .animation(.easeOut(duration: 0.18), value: captureMode)
        .animation(.spring(response: 0.34, dampingFraction: 0.85),
                   value: camera.lastRecordingURL != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: showRollDone)
        // No auto-start after a purchase or a swap: a camera that begins
        // recording on its own as a sheet slides away would catch the floor.
        .lockedLookSheet($lookLock, context: .camera) {
            app.settlePackPreview(storeService)
            flash("Look unlocked. Ready when you are")
        } onUseFreeLook: {
            app.useFreeLookInGrade(storeService)
            flash("Now on \(LookSignature.title(in: app.cameraLookName)). Ready when you are")
        }
        .onAppear {
            app.library.settleOrder()
            start()
        }
        .onDisappear { camera.stopSession() }
        .onChange(of: camera.isRecording) { _, recording in
            recordStart = recording ? Date() : nil
            if recording {
                formatOpen = false
                cancelTouch()
            }
        }
        .onChange(of: app.settings) { _, _ in syncCameraLook() }
        .onChange(of: app.selectedLook.id) { _, _ in syncCameraLook() }
        .onChange(of: app.selectedLUT?.id) { _, _ in syncCameraLook() }
        .onChange(of: app.packPreview) { _, _ in syncCameraLook() }
        .onChange(of: camera.recordingError) { _, error in
            if let error { flash(error) }
        }
        .onChange(of: camera.microphoneDenied) { _, denied in
            if denied { flash("Microphone access is off, so recordings will be silent") }
        }
        // The controller writes the finished take to the photo library on its
        // own clock, well after the writer closes. Confirm it when it lands.
        .onChange(of: camera.lastSavedToPhotos) { _, saved in
            if saved { flash("Clip saved to Photos") }
        }
        .task(id: scopeMode) { await runScopeLoop() }
    }

    // MARK: - The screen
    //
    // One stack in the whole screen's own coordinates. Every child is placed
    // from the top left with the lab's left and top, so the numbers here can
    // be read straight against the design.

    private func screen(size: CGSize, top: CGFloat, keyboard: CGFloat) -> some View {
        let upright = !isLandscapeLayout
        return ZStack(alignment: .topLeading) {
            CamLab.ink
            viewfinder(size: size, top: top)
                .offset(y: pictureLift)
            touchSurface
            pictureMarks(size: size, top: top)
            if upright {
                uprightChrome(size: size, top: top)
            } else {
                landscapeChrome(size: size, top: top)
                    .transition(.opacity)
            }
            if proOpen && upright {
                proSheet(size: size)
                    .transition(.move(edge: .bottom))
            }
            plate(size: size)
            if showLookBrowser && upright {
                looksLibrary(size: size, top: top, keyboard: keyboard)
                    .transition(.opacity.combined(with: .offset(y: 30)))
            }
            overlays(size: size)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    /// The picture slides up while the looks are open, so the face stays in
    /// view above them.
    private var pictureLift: CGFloat {
        showLookBrowser && !isLandscapeLayout ? -104 : 0
    }

    /// Whatever sits over everything: the caption, the fan, and the cards a
    /// take or a finished roll returns.
    @ViewBuilder
    private func overlays(size: CGSize) -> some View {
        if !isLandscapeLayout, let statusCaption {
            CamToast(text: statusCaption)
                .id(statusCaption)
                .frame(width: size.width)
                .offset(y: size.height - (proOpen ? 524 : (showLookBrowser ? 596 : 374)))
                .transition(.opacity)
        }
        if let fan {
            CamFan(touch: fan.touch, centre: fan.centre, items: fanItems,
                   positions: fan.positions, hot: fan.hot,
                   restLabel: fan.resting ? (camera.aeafLocked ? "Let go to unlock AE/AF"
                                                               : "Let go to lock AE/AF") : nil)
                .frame(width: size.width, height: size.height)
                .transition(.opacity)
        }
        if let recording = camera.lastRecordingURL, !camera.isRecording {
            CameraHandOffCard(url: recording,
                              onRetake: { camera.lastRecordingURL = nil },
                              onGrade: { handOffToGrade(recording) },
                              onEdit: { handOffToEditor(recording) })
                .frame(maxWidth: 380)
                .rotationEffect(.degrees(controlTurn))
                .padding(.horizontal, 20)
                .frame(width: size.width, height: size.height)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        if showRollDone {
            CameraRollDoneCard(frames: Self.rollLength,
                               onNewRoll: { loadNewRoll() },
                               onDevelop: { developRoll() })
                .frame(maxWidth: 360)
                .rotationEffect(.degrees(controlTurn))
                .padding(.horizontal, 24)
                .frame(width: size.width, height: size.height)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    private func start() {
        // A restored scene must never open ON a panel.
        proOpen = false
        formatOpen = false
        camera.lookState = app.lookState
        camera.requestAndStart()
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // Viewfinder assists at launch, e.g. LUMA_SEED_CAMASSIST=peak,zebra
        if let assists = env["LUMA_SEED_CAMASSIST"] {
            if assists.contains("peak") { camera.peakingOn = true }
            if assists.contains("zebra") { camera.zebrasOn = true }
            if assists.contains("guide916") { frameGuide = .vertical }
            if assists.contains("guide239") { frameGuide = .cinemascope }
            if assists.contains("safe") { showSafeZone = true }
            if assists.contains("scope") { scopeMode = .waveform }
            if assists.contains("grid") { showGrid = true }
            if assists.contains("level") { showLevel = true }
        }
        // Pro open on a chosen readout, e.g. LUMA_SEED_CAMPRO=shutter.
        if let pro = env["LUMA_SEED_CAMPRO"] {
            proOpen = true
            dialTarget = DialTarget.named(pro) ?? .lens
        }
        // Another mode, a roll loaded, or the focus square held, e.g.
        // LUMA_SEED_CAMMODE=photo LUMA_SEED_CAMROLL=24 LUMA_SEED_CAMFOCUS=1.
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
            focusSeed = CGPoint(x: 0.56, y: 0.36)
        }
        // A look on the picture, e.g. LUMA_SEED_CAMLOOK=pack:film-neg-archive:FN400,
        // and with LUMA_SEED_CAMLOCK=1 the ask a paid one makes at record.
        if let id = env["LUMA_SEED_CAMLOOK"], let look = app.cameraLook(id: id) {
            app.wear(look, store: storeService)
        }
        if env["LUMA_SEED_CAMLOCK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                lookLock = app.lockedLookInGrade(storeService)
            }
        }
        // Sideways: LUMA_SEED_CAMLAND=cw (turned clockwise) or ccw.
        if let land = env["LUMA_SEED_CAMLAND"] {
            forcedLandscape = true
            forcedClockwise = land.lowercased() == "cw"
        }
        // The thumb fan held open, or a swipe caught half way.
        if env["LUMA_SEED_CAMFAN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { seedFan() }
        }
        if env["LUMA_SEED_CAMSWIPE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { seedSwipe() }
        }
        #endif
        if showLookBrowser { refreshRawFrame() }
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
                                                 size: CGSize(width: 232, height: 108))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The camera's own frame, before any look, for the looks' tiles.
    private func refreshRawFrame() {
        camera.requestRawFrame(maxSide: 480) { cg in
            guard let cg else { return }
            rawFrame = CIImage(cgImage: cg)
            rawFrameID += 1
        }
    }

    // MARK: - The picture
    //
    // Edge to edge behind everything. Only what must register with the
    // picture is drawn on it: the wipe of a swipe, the grid, the level, a
    // frame guide, the shutter's blink, and the two scrims the controls read
    // against. It takes no touches of its own; `touchSurface` does.

    private var showsLivePicture: Bool { camera.isRunning && !camera.cameraUnavailable }

    private func viewfinder(size: CGSize, top: CGFloat) -> some View {
        let upright = !isLandscapeLayout
        return ZStack(alignment: .topLeading) {
            livePicture
            swipeRevealLayer(size: size)
            if showGrid {
                CamGrid().transition(.opacity)
            }
            if showLevel {
                LevelIndicator(restTurn: controlTurn)
                    .frame(width: size.width, height: 40)
                    .offset(y: levelCentre(size: size) - 20)
                    .transition(.opacity)
            }
            if upright, frameGuide != .off {
                CamGuide(box: guideBox(size: size, top: top), label: frameGuide.label,
                         safeZone: showSafeZone && frameGuide == .vertical)
                    .transition(.opacity)
            }
            if upright {
                scrims(size: size)
            }
            if shutterFlash {
                Color.white.opacity(0.8).transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var livePicture: some View {
        if showsLivePicture {
            FilteredCameraPreview(camera: camera, fill: true)
        } else {
            ZStack {
                HeroImage(photo: .golden)
                Color.black.opacity(0.45)
            }
        }
    }

    /// The lab's two scrims: 170 pt down from the top, and the lower 404 pt.
    private func scrims(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: 170)
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.55), location: 0.45),
                .init(color: .black.opacity(0.82), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: 404)
                .offset(y: size.height - 404)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// The level sits a little above the middle; sideways, in the middle of
    /// the picture left clear of the plate.
    private func levelCentre(size: CGSize) -> CGFloat {
        isLandscapeLayout ? (size.height - CamLab.plateHeight) / 2 : size.height * 0.46
    }

    /// The guide's box, in the picture left clear between the top bar and the
    /// plate.
    private func guideBox(size: CGSize, top: CGFloat) -> CGRect {
        let aspect = CGFloat(frameGuide.aspect ?? 1)
        let top0 = top + 48
        let clear = size.height - 124 - top0
        var gw = size.width - 24
        var gh = gw / aspect
        if gh > clear - 20 {
            gh = clear - 20
            gw = gh * aspect
        }
        return CGRect(x: (size.width - gw) / 2, y: top0 + (clear - gh) / 2, width: gw, height: gh)
    }

    /// The next look, graded over a still of this frame, wiped in from the
    /// side the finger is pulling from. It fills the screen as the live
    /// picture does, so the two line up.
    @ViewBuilder
    private func swipeRevealLayer(size: CGSize) -> some View {
        if let swipe, let swipeReveal, !isLandscapeLayout {
            let edge = swipe.edge(in: size.width)
            let shown = swipe.direction == 1 ? size.width - edge : edge
            Image(decorative: swipeReveal, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: max(shown, 0))
                        .offset(x: swipe.direction == 1 ? edge : 0)
                }
        }
    }

    // MARK: Marks on the picture

    /// The focus square, the swipe's edge and the look's name; and, with no
    /// camera to show, why.
    @ViewBuilder
    private func pictureMarks(size: CGSize, top: CGFloat) -> some View {
        if !showsLivePicture {
            fallbackMessage
                .rotationEffect(.degrees(controlTurn))
                .frame(width: size.width, height: max(size.height - 424 - top, 120))
                .offset(y: top + 110)
        }
        focusLayer(size: size)
        if !isLandscapeLayout {
            if let swipe {
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2, height: size.height)
                    .shadow(color: .white.opacity(0.6), radius: 7)
                    .offset(x: swipe.edge(in: size.width) - 1)
                    .allowsHitTesting(false)
            }
            bigName(width: size.width)
                .offset(y: size.height - 474)
        }
    }

    @ViewBuilder
    private var fallbackMessage: some View {
        VStack(spacing: 10) {
            if camera.permissionDenied {
                CamGlyph(icon: .lock, size: 28)
                    .foregroundStyle(Color.white.opacity(0.8))
                Text("Camera access is off")
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(CamLab.text)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    CamMiniLabel(title: "Open Settings")
                }
                .buttonStyle(CamPressStyle())
            } else if camera.cameraUnavailable {
                CamGlyph(icon: .photo, size: 28)
                    .foregroundStyle(Color.white.opacity(0.8))
                Text("No camera on this device")
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(CamLab.text)
                Text("Run LumaLook on an iPhone to shoot with live looks.")
                    .font(.luma(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.55))
            } else {
                ProgressView().tint(.white)
            }
        }
        .padding(20)
    }

    /// The square a tap leaves, or the one held while AE/AF is locked.
    @ViewBuilder
    private func focusLayer(size: CGSize) -> some View {
        if let mark = focusMark {
            CamFocusPulse(label: mark.label, hold: mark.hold)
                .rotationEffect(.degrees(controlTurn))
                .id(mark.id)
                .offset(x: mark.point.x - 37, y: mark.point.y - 37)
        } else if let seed = focusSeed, showsLivePicture {
            CamFocusPulse(label: "AF", hold: true)
                .offset(x: seed.x * size.width - 37, y: seed.y * size.height - 37)
        }
    }

    /// The look's name, large, while it is swiped in and for a moment after.
    @ViewBuilder
    private func bigName(width: CGFloat) -> some View {
        if let look = swipe?.next ?? nameFlash {
            let strength = Int(app.settings.intensity.rounded())
            VStack(spacing: 4) {
                Text(look.title)
                    .font(.luma(size: 32, weight: .bold))
                    .kerning(-0.96)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(look.code) · \(strength)%")
                    .font(.luma(size: 13))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            .padding(.horizontal, 24)
            .frame(width: width)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private func placeFocusMark(at point: CGPoint, label: String, hold: Bool) {
        focusToken += 1
        let token = focusToken
        focusSeed = nil
        focusMark = FocusMark(id: token, point: point, label: label, hold: hold)
        guard !hold else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            if focusMark?.id == token { focusMark = nil }
        }
    }

    /// No square on the picture (auto all, a flip).
    private func clearFocusMark() {
        focusToken += 1
        focusSeed = nil
        focusMark = nil
    }

    /// A point on the screen as a unit point in the picture, which fills the
    /// screen and so runs off its sides.
    private func unitPoint(for point: CGPoint) -> CGPoint? {
        guard let frame = camera.previewImage, screenSize.width > 0, screenSize.height > 0,
              frame.width > 0, frame.height > 0 else { return nil }
        let iw = CGFloat(frame.width), ih = CGFloat(frame.height)
        let scale = max(screenSize.width / iw, screenSize.height / ih)
        let shownW = iw * scale, shownH = ih * scale
        let x = (point.x - (screenSize.width - shownW) / 2) / shownW
        let y = (point.y - pictureLift - (screenSize.height - shownH) / 2) / shownH
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: - A finger on the picture
    //
    // One clear layer over the picture and under every control. A tap
    // focuses there; a sideways drag steps through the favourites; a hold
    // fans the tools out; two fingers zoom.

    private var touchSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture)
            .simultaneousGesture(touchGesture)
            .accessibilityHidden(true)
    }

    private var canSwipe: Bool {
        guard !recordingBusy, showsLivePicture, !showLookBrowser else { return false }
        return !cameraFavourites.isEmpty
    }

    private var canFan: Bool {
        !isLandscapeLayout && showsLivePicture && !showLookBrowser
    }

    /// How far a full swipe travels: the picture's width as it is held.
    private var swipeWidth: CGFloat {
        let width = screenSize.width > 0 ? screenSize.width : 393
        let height = screenSize.height > 0 ? screenSize.height : 852
        return isLandscapeLayout ? height : width
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if !isPinching {
                    isPinching = true
                    camera.beginPinch()
                    cancelTouch()
                }
                camera.updatePinch(scale: scale)
            }
            .onEnded { _ in isPinching = false }
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { touchChanged($0) }
            .onEnded { touchEnded($0) }
    }

    /// Whatever is open over the picture goes away under a finger; true when
    /// something did, so that touch does nothing else.
    private func putAwayPanels() -> Bool {
        var closed = false
        if proOpen { proOpen = false; closed = true }
        if formatOpen { formatOpen = false; closed = true }
        if showLookBrowser { showLookBrowser = false; closed = true }
        if landscapeDropOpen { landscapeDropOpen = false; closed = true }
        return closed
    }

    private func touchChanged(_ value: DragGesture.Value) {
        if isPinching {
            cancelTouch()
            return
        }
        // A gesture the system took away never ends; a new start replaces it.
        if let stale = touch, stale.start != value.startLocation {
            cancelTouch()
            touch = nil
        }
        if touch == nil {
            touchToken += 1
            let token = touchToken
            if putAwayPanels() {
                touch = TouchState(mode: .ignored, start: value.startLocation,
                                   last: value.location, token: token)
                return
            }
            touch = TouchState(mode: .pending, start: value.startLocation,
                               last: value.location, token: token)
            if canFan {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                    openFanIfHeld(token: token)
                }
            }
        }
        guard var state = touch else { return }
        state.last = value.location
        let travel = userTravel(value.translation)
        if state.mode == .pending,
           hypot(value.translation.width, value.translation.height) > 10 {
            state.mode = canSwipe && abs(travel.width) > abs(travel.height) * 1.2 ? .swipe : .ignored
        }
        touch = state
        switch state.mode {
        case .swipe: moveSwipe(travel.width)
        case .fan: moveFan(to: value.location)
        case .pending, .ignored: break
        }
    }

    private func touchEnded(_ value: DragGesture.Value) {
        let mode = touch?.mode
        touch = nil
        switch mode {
        case .swipe: endSwipe()
        case .fan: endFan()
        case .pending: tapPicture(at: value.location)
        default: break
        }
    }

    /// Drops whatever the finger was doing (a pinch began, a take started).
    private func cancelTouch() {
        if touch != nil { touch?.mode = .ignored }
        if swipe != nil {
            withAnimation(.easeOut(duration: 0.2)) { swipe = nil }
            swipeReveal = nil
        }
        if fan != nil { fan = nil }
    }

    /// A tap focuses and exposes there. Focus set by hand goes back to auto
    /// first, and a lock lets go.
    private func tapPicture(at point: CGPoint) {
        guard showsLivePicture, fan == nil, let unit = unitPoint(for: point) else { return }
        if camera.manualFocus {
            camera.resetAutoFocus()
            flash("Focus back on auto")
        }
        if camera.aeafLocked { camera.unlockAEAF() }
        camera.focusExpose(at: unit)
        placeFocusMark(at: point, label: "AF", hold: false)
        LumaHaptics.shared.tap()
    }

    /// Hold, then let go where you pressed: focus and exposure lock there
    /// (or, already locked, let go again).
    private func lockFocus(at point: CGPoint) {
        if camera.aeafLocked {
            camera.unlockAEAF()
            clearFocusMark()
            flash("AE/AF unlocked")
            LumaHaptics.shared.tap()
            return
        }
        guard let unit = unitPoint(for: point) else { return }
        camera.focusExpose(at: unit)
        placeFocusMark(at: point, label: "AE/AF L", hold: true)
        let token = focusToken
        // The lens needs a moment to settle on the point before it is held.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard focusToken == token, !camera.aeafLocked else { return }
            camera.toggleAEAFLock()
        }
        flash("AE/AF locked")
        LumaHaptics.shared.tap()
    }

    /// The finger's travel as the person holding the phone sees it.
    private func userTravel(_ t: CGSize) -> CGSize {
        guard isLandscapeLayout else { return t }
        return landscapeTurn < 0
            ? CGSize(width: -t.height, height: t.width)
            : CGSize(width: t.height, height: -t.width)
    }

    // MARK: Swipe through favourites

    private var cameraFavourites: [CameraLook] {
        app.cameraFavourites(raw: favouritesRaw)
    }

    private func moveSwipe(_ travel: CGFloat) {
        let direction = travel < 0 ? 1 : -1
        if let current = swipe {
            if current.finishing { return }
            if current.direction == direction {
                swipe?.travel = travel
                return
            }
        }
        guard travel != 0, let next = nextFavourite(direction) else { return }
        swipeToken += 1
        swipe = SwipeState(direction: direction, next: next, travel: travel, token: swipeToken)
        swipeReveal = nil
        if !isLandscapeLayout { prepareReveal(of: next, token: swipeToken) }
    }

    /// Past about a fifth of the picture the look changes; short of it, the
    /// wipe slides back.
    private func endSwipe() {
        guard let current = swipe, !current.finishing else { return }
        let width = swipeWidth
        let commit = abs(current.travel) > width * 0.18
        swipe?.finishing = true
        withAnimation(.easeOut(duration: 0.22)) {
            swipe?.travel = commit ? (current.direction == 1 ? -width : width) : 0
        }
        let token = current.token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) {
            guard swipe?.token == token else { return }
            if commit { wearFromSwipe(current.next) }
            // The wipe holds a beat longer than the swap, so the live grade
            // has a frame to catch up before the still comes off.
            DispatchQueue.main.asyncAfter(deadline: .now() + (commit ? 0.12 : 0)) {
                guard swipe?.token == token else { return }
                swipe = nil
                swipeReveal = nil
            }
        }
    }

    private func wearFromSwipe(_ look: CameraLook) {
        let installed = app.wear(look, store: storeService)
        showName(look, for: 0.65)
        if let installed { flash("\(installed) is in your library now") }
        LumaHaptics.shared.tap()
    }

    private func showName(_ look: CameraLook, for seconds: Double = 0.9) {
        nameFlashID += 1
        let id = nameFlashID
        nameFlash = look
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard nameFlashID == id else { return }
            nameFlash = nil
        }
    }

    /// The favourite after (or before) the look on the picture. A look that
    /// is not in the swipe starts it from either end.
    private func nextFavourite(_ direction: Int) -> CameraLook? {
        let favourites = cameraFavourites
        guard !favourites.isEmpty else { return nil }
        let worn = app.cameraWornLook.id
        let next: CameraLook
        if let at = favourites.firstIndex(where: { $0.id == worn }) {
            next = favourites[(at + direction + favourites.count) % favourites.count]
        } else {
            next = direction == 1 ? favourites[0] : favourites[favourites.count - 1]
        }
        return next.id == worn ? nil : next
    }

    private func prepareReveal(of look: CameraLook, token: Int) {
        let job = app.cameraLookJob(for: look, intensity: app.settings.intensity)
        camera.requestRawFrame(maxSide: 1080) { cg in
            guard let cg, swipe?.token == token else { return }
            CameraLookThumbs.grade(CIImage(cgImage: cg), job: job, maxDimension: 1080) { image in
                guard swipe?.token == token else { return }
                swipeReveal = image
            }
        }
    }

    // MARK: The thumb fan

    private var fanItems: [CamFanItem] {
        [
            CamFanItem(id: "pro", icon: .pro, label: "Pro", on: proOpen),
            CamFanItem(id: "format", icon: .format, label: "Format", on: formatOpen),
            CamFanItem(id: "guides", icon: .guides,
                       label: frameGuide == .off ? "Guides" : frameGuide.label, on: frameGuide != .off),
            CamFanItem(id: "scope", icon: .scope, label: "Scope", on: scopeMode != nil),
            CamFanItem(id: "zebras", icon: .zebras, label: "Zebras", on: camera.zebrasOn),
            CamFanItem(id: "peaking", icon: .peaking, label: "Peaking", on: camera.peakingOn),
            CamFanItem(id: "grid", icon: .grid, label: "Grid", on: showGrid),
            CamFanItem(id: "level", icon: .level, label: "Level", on: showLevel),
        ]
    }

    private func openFanIfHeld(token: Int) {
        guard let state = touch, state.token == token, state.mode == .pending, canFan else { return }
        let size = screenSize == .zero ? CGSize(width: 393, height: 852) : screenSize
        let centre = CamFan.centre(for: state.last, in: size)
        fan = FanState(touch: state.last, origin: state.last, centre: centre,
                       positions: CamFan.layout(centre: centre, count: fanItems.count),
                       hot: nil)
        touch?.mode = .fan
        LumaHaptics.shared.tap()
    }

    private func moveFan(to point: CGPoint) {
        guard var state = fan else { return }
        state.touch = point
        var best: Int?
        var bestDistance: CGFloat = 44
        for (index, position) in state.positions.enumerated() {
            let distance = hypot(position.x - point.x, position.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        if let best, best != state.hot { LumaHaptics.shared.tap() }
        state.hot = best
        fan = state
    }

    private func endFan() {
        guard let state = fan else { return }
        fan = nil
        if let hot = state.hot, fanItems.indices.contains(hot) {
            useTool(fanItems[hot].id)
        } else if state.resting {
            lockFocus(at: state.origin)
        }
    }

    private func useTool(_ id: String) {
        switch id {
        case "pro": openPro()
        case "format": toggleFormat()
        case "guides": cycleGuide()
        case "scope": cycleScope()
        case "zebras": toggleZebras()
        case "peaking": togglePeaking()
        case "grid": toggleGrid()
        case "level": toggleLevel()
        case "aeaf": toggleAEAF()
        case "auto": autoAll()
        default: break
        }
    }

    #if DEBUG
    private func seedFan() {
        let size = screenSize == .zero ? CGSize(width: 393, height: 852) : screenSize
        let press = CGPoint(x: size.width * 0.5, y: size.height * 0.56)
        let centre = CamFan.centre(for: press, in: size)
        let positions = CamFan.layout(centre: centre, count: fanItems.count)
        fan = FanState(touch: positions[2], origin: press, centre: centre,
                       positions: positions, hot: 2)
    }

    private func seedSwipe() {
        guard let next = nextFavourite(1) else { return }
        swipeToken += 1
        swipe = SwipeState(direction: 1, next: next, travel: -swipeWidth * 0.42, token: swipeToken)
        if !isLandscapeLayout { prepareReveal(of: next, token: swipeToken) }
    }
    #endif

    // MARK: - Over the picture, upright
    //
    // The lab's own positions: the top bar on the safe area's edge, the look
    // 48 pt under it, the chips 314 pt up from the bottom, the dial turning
    // on the shutter's centre.

    /// The look, Pro, the chips and the dial step back while Pro is up and
    /// while a look is being swiped in.
    private var chromeQuiet: Bool { proOpen || swipe != nil }
    private var dialQuiet: Bool { chromeQuiet || showLookBrowser }

    @ViewBuilder
    private func uprightChrome(size: CGSize, top: CGFloat) -> some View {
        let w = size.width
        topBar
            .frame(width: max(w - 32, 0), height: 34)
            .offset(x: 16, y: top)
        lookTag(ring: 42)
            .offset(x: 16, y: top + 48)
            .opacity(chromeQuiet ? 0 : 1)
            .allowsHitTesting(!chromeQuiet)
            .animation(.easeOut(duration: 0.2), value: chromeQuiet)
        proPill
            .frame(width: max(w - 16, 0), alignment: .trailing)
            .offset(y: top + 52)
            .opacity(chromeQuiet ? 0 : 1)
            .allowsHitTesting(!chromeQuiet)
            .animation(.easeOut(duration: 0.2), value: chromeQuiet)
        sideStack
            .offset(x: 16, y: top + 98)
        dialDeck(size: size)
            .opacity(dialQuiet ? 0 : 1)
            .allowsHitTesting(!dialQuiet)
            .animation(.easeOut(duration: 0.2), value: dialQuiet)
        if formatOpen {
            formatCard
                .frame(width: min(264, max(w - 76, 0)), alignment: .leading)
                .offset(x: 60, y: top + 42)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            closeButton
            formatChip
            Spacer(minLength: 0)
            histogramButton
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            CamGlyph(icon: .close, size: 18)
                .foregroundStyle(CamLab.text)
                .frame(width: 34, height: 34)
                .camGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel("Close camera")
    }

    /// What the camera is writing, live from the spec in force. While a take
    /// rolls it is the take's clock, on red.
    private var formatChip: some View {
        Button {
            toggleFormat()
        } label: {
            formatChipLabel
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel(camera.isRecording ? "Recording" : "Format, \(formatSummary)")
        .accessibilityHint(camera.isRecording ? "" : "Changes what the camera shoots")
    }

    @ViewBuilder
    private var formatChipLabel: some View {
        if camera.isRecording {
            TimelineView(.periodic(from: recordStart ?? Date(), by: 0.5)) { context in
                chipText("● " + Self.clock(context.date.timeIntervalSince(recordStart ?? context.date)))
                    .background(CamLab.rec.opacity(0.85), in: Capsule())
            }
        } else {
            chipText(formatSummary)
                .camGlass(Capsule())
        }
    }

    private func chipText(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 13, weight: .semibold))
            .foregroundStyle(CamLab.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
    }

    private var formatSummary: String {
        if captureMode.takesStills {
            return "\(camera.photoSpec.format.rawValue) · \(camera.activePhotoMegapixels) MP"
        }
        let spec = camera.activeSpec
        return "\(spec.resolution.rawValue) · \(spec.fps) · \(spec.codec.rawValue)"
    }

    /// "00:07" for a take seven seconds in.
    private static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// The live histogram. Tap it for the scope.
    private var histogramButton: some View {
        Button {
            cycleScope()
        } label: {
            CamHistogramGlyph(bins: camera.histogram?.luma)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .camGlass(RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel("Histogram")
        .accessibilityHint("Shows the scope")
    }

    // MARK: The look

    /// The look on the picture: its ring (filled to the strength), its name,
    /// code and strength, and a dot for each favourite in the swipe. Tap for
    /// every look.
    private func lookTag(ring: CGFloat) -> some View {
        let worn = app.cameraWornLook
        let strength = app.settings.intensity
        let locked = app.lockedLookInGrade(storeService) != nil
        let large = ring > 40
        return Button {
            openLooks()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                CamRing(code: worn.code, colour: worn.signature, strength: strength / 100, size: ring)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(worn.title)
                            .font(.luma(size: large ? 14.5 : 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if locked {
                            CamGlyph(icon: .lock, size: 11, weight: 2.2)
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }
                    Text("\(worn.code) · \(Int(strength.rounded()))%")
                        .font(.luma(size: large ? 11.5 : 11))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)
                        .padding(.top, 1)
                    if large {
                        favouriteDots(worn)
                            .padding(.top, 6)
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel("Looks: \(app.cameraLookName)")
        .accessibilityHint("Opens every look. Swipe the picture for your favourites")
    }

    /// Where the look on the picture sits in the swipe.
    @ViewBuilder
    private func favouriteDots(_ worn: CameraLook) -> some View {
        let favourites = cameraFavourites
        let current = favourites.firstIndex { $0.id == worn.id }
        if favourites.count > 12 {
            Text(current.map { "\($0 + 1) of \(favourites.count) favourites" }
                 ?? "\(favourites.count) favourites")
                .font(.luma(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
        } else if favourites.count > 1 {
            HStack(spacing: 4) {
                ForEach(Array(favourites.enumerated()), id: \.element.id) { index, _ in
                    Capsule()
                        .fill(index == current ? worn.signature : Color.white.opacity(0.4))
                        .frame(width: index == current ? 12 : 4, height: 4)
                }
            }
            .animation(.easeOut(duration: 0.2), value: current)
        }
    }

    /// Pro: pulls up the readouts and every tool.
    private var proPill: some View {
        Button {
            openPro()
        } label: {
            HStack(spacing: 5) {
                CamGlyph(icon: .up, size: 18, weight: 2.2)
                    .foregroundStyle(CamLab.sig)
                Text("Pro")
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(CamLab.text)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: 34)
            .camGlass(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel("Pro controls")
    }

    // MARK: Scope, mic and the lock

    /// Down the left under the look: the scope when it is on, the mic while
    /// a take rolls, and the AE/AF lock (tap to let go).
    private var sideStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scopeMode != nil {
                scopeBox.transition(.opacity)
            }
            if camera.isRecording {
                micMeter.transition(.opacity)
            }
            if camera.aeafLocked {
                aeafBadge.transition(.opacity)
            }
        }
    }

    private var scopeBox: some View {
        Button {
            scopeMode = scopeMode?.next
            if let scopeMode { flash("Scope: \(scopeName(scopeMode))") }
            LumaHaptics.shared.tap()
        } label: {
            scopePicture
                .frame(width: 116, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(8)
                .camGlass(RoundedRectangle(cornerRadius: 12), tint: Color(hex: 0x0E0F12), opacity: 0.62)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel(scopeMode.map { "Scope: \(scopeName($0))" } ?? "Scope")
        .accessibilityHint("Shows the next scope")
    }

    @ViewBuilder
    private var scopePicture: some View {
        if let scopeImage {
            Image(decorative: scopeImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.white.opacity(0.04)
        }
    }

    private func scopeName(_ mode: ScopeMode) -> String {
        switch mode {
        case .waveform:    return "RGB waveform"
        case .parade:      return "RGB parade"
        case .vectorscope: return "Vectorscope"
        case .histogram:   return "RGB histogram"
        case .falseColor:  return "False colour"
        }
    }

    private var micMeter: some View {
        let level = camera.audioLevel
        return HStack(spacing: 2.5) {
            Text("MIC")
                .font(.luma(size: 9, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(CamLab.text)
                .padding(.trailing, 3)
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(level >= Double(index + 1) / 12
                          ? (index >= 10 ? CamLab.rec : CamLab.text)
                          : Color.white.opacity(0.18))
                    .frame(width: 3, height: 10)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .camGlass(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
    }

    private var aeafBadge: some View {
        Button {
            camera.unlockAEAF()
            clearFocusMark()
            flash("AE/AF unlocked")
            LumaHaptics.shared.tap()
        } label: {
            HStack(spacing: 5) {
                CamGlyph(icon: .lock, size: 12, weight: 2.4)
                Text("AE/AF locked")
                    .font(.luma(size: 12, weight: .semibold))
            }
            .foregroundStyle(CamLab.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(CamLab.sig, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(CamPressStyle())
        .accessibilityHint("Unlocks focus and exposure")
    }

    // MARK: Chips and the dial

    private var lensTarget: DialTarget { captureMode == .portrait ? .aperture : .lens }
    private var chipTargets: [DialTarget] { [lensTarget, .shutter, .iso, .ev, .wb, .focus] }
    private var proTargets: [DialTarget] { [lensTarget, .iso, .shutter, .wb, .ev, .focus] }

    /// The chips, the arc and the value on it.
    @ViewBuilder
    private func dialDeck(size: CGSize) -> some View {
        let w = size.width, h = size.height
        chipsRow
            .frame(width: max(w - 20, 0))
            .offset(x: 10, y: h - 314)
        CamDial(ticks: dialTicks(for: dialTarget), index: dialPosition(for: dialTarget),
                onChange: { applyDial($0, to: dialTarget) },
                onPullUp: { openPro() })
            .id(dialTarget)
            .frame(width: w, height: CamDial.height)
            .offset(y: h - 290)
        dialReadout
            .frame(width: w)
            .offset(y: h - 194)
            .allowsHitTesting(false)
    }

    /// One row, centred. A phone too narrow for the lab's chips gets the
    /// same row with tighter sides.
    private var chipsRow: some View {
        ViewThatFits(in: .horizontal) {
            chips(compact: false, gap: 4)
            chips(compact: true, gap: 3)
        }
    }

    private func chips(compact: Bool, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(chipTargets, id: \.self) { target in
                CamChip(title: target.chip, active: dialTarget == target, compact: compact) {
                    dialTarget = target
                    LumaHaptics.shared.tap()
                }
            }
        }
    }

    /// The value on the dial, and under it what it is (and "AUTO" while the
    /// camera is choosing it).
    private var dialReadout: some View {
        let parts = dialValueParts(for: dialTarget)
        let caption = dialTarget.caption + (isAutoTarget(dialTarget) ? " · AUTO" : "")
        return VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.value)
                    .font(.luma(size: 34, weight: .semibold))
                    .kerning(-1)
                    .foregroundStyle(CamLab.text)
                if let unit = parts.unit {
                    Text(unit)
                        .font(.luma(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
            .lineLimit(1)
            .frame(height: 38)
            Text(caption)
                .font(.luma(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
        }
        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The plate
    //
    // Full width, 100 pt up from the bottom edge, in panel grey with the
    // look's colour glowing from its lower left. The shutter sits in the
    // notch, its centre 74 pt up from the bottom: the dial turns on it.

    private func plate(size: CGSize) -> some View {
        let w = size.width
        return ZStack(alignment: .topLeading) {
            CamPlate(glow: app.cameraWornLook.signature)
                .frame(width: w, height: CamLab.plateHeight)
                .contentShape(Rectangle())
                .gesture(platePull)
                .accessibilityHidden(true)
            lastShotButton
                .offset(x: 22, y: 15)
            flipButton
                .offset(x: 80, y: 15)
            modeSwitch
                .frame(width: max(w - 18, 0), alignment: .trailing)
                .offset(y: 15)
            CamShutter(isRecording: camera.isRecording,
                       photoMode: captureMode.takesStills,
                       rollCount: captureMode.takesStills && rollOn ? rollLeft : nil) {
                shutterPressed()
            }
            .rotationEffect(.degrees(controlTurn))
            .offset(x: w / 2 - 35, y: CamLab.plateHeight - CamLab.shutterRise - 35)
        }
        .frame(width: w, height: CamLab.plateHeight, alignment: .topLeading)
        .offset(y: size.height - CamLab.plateHeight)
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.isRecording)
        .sensoryFeedback(.success, trigger: stillSavedFlash)
    }

    /// Dragging the plate up pulls up Pro.
    private var platePull: some Gesture {
        DragGesture(minimumDistance: 14)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if dy < -34, abs(dy) > abs(dx) * 1.3 { openPro() }
            }
    }

    /// The newest shot; a plain tile until there is one.
    private var lastShotButton: some View {
        Button {
            openLastShot()
        } label: {
            ZStack {
                CamLab.raised
                if let image = lastShot?.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 46, height: 46)
                } else {
                    CamGlyph(icon: .photo, size: 20)
                        .foregroundStyle(CamLab.grey)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1.5))
            .rotationEffect(.degrees(controlTurn))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(CamPressStyle())
        .animation(.easeOut(duration: 0.25), value: lastShot?.id)
        .accessibilityLabel("Last shot")
    }

    private var flipButton: some View {
        Button {
            guard !camera.isRecording else {
                flash("Stop recording first")
                return
            }
            camera.flipCamera()
            clearFocusMark()
            LumaHaptics.shared.tap()
        } label: {
            CamGlyph(icon: .flip, size: 20)
                .foregroundStyle(CamLab.text)
                .rotationEffect(.degrees(controlTurn))
                .frame(width: 46, height: 46)
                .background(CamLab.raised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(CamPressStyle())
        .opacity(camera.isRecording ? 0.4 : 1)
        .accessibilityLabel("Flip camera")
    }

    /// Photo, Video, Slo-mo and Portrait always show. The two a camera
    /// cannot do are dimmed, and say why when tapped.
    private var modeSwitch: some View {
        let modes = CaptureMode.allCases.map { mode in
            CamMode(id: mode.rawValue, icon: mode.icon, label: mode.rawValue,
                    enabled: modeAvailable(mode))
        }
        return CamModeSwitch(modes: modes, selected: captureMode.rawValue, turn: controlTurn) { picked in
            guard let mode = CaptureMode(rawValue: picked.id), mode != captureMode else { return }
            if recordingBusy {
                flash("Stop recording first")
                return
            }
            guard modeAvailable(mode) else {
                flash(mode == .slowMo ? "This camera has no slo-mo" : "This camera has no depth for Portrait")
                return
            }
            captureMode = mode
            LumaHaptics.shared.tap()
        }
        .opacity(recordingBusy ? 0.5 : 1)
    }

    private func modeAvailable(_ mode: CaptureMode) -> Bool {
        switch mode {
        case .photo, .video: return true
        case .slowMo:        return camera.slowMotionFPS != nil || showsAllModesForPreview
        case .portrait:      return camera.depthSupported || showsAllModesForPreview
        }
    }

    /// DEBUG preview shows every mode, because the simulator has no camera
    /// to ask.
    private var showsAllModesForPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LUMA_SEED_CAMFRAME"] != nil
        #else
        return false
        #endif
    }

    private var recordingBusy: Bool { camera.isRecording || camera.isPreparingRecording }

    private func shutterPressed() {
        if captureMode.takesStills {
            captureStill()
            return
        }
        // Stopping a take is never gated; only starting one with a locked
        // look on the picture asks first. A try-on whose pack is now owned
        // becomes the real look before anything is written.
        if !camera.isRecording, !camera.isPreparingRecording {
            app.settlePackPreview(storeService)
            if let lock = app.lockedLookInGrade(storeService) {
                lookLock = lock
                return
            }
            cancelTouch()
        }
        camera.toggleRecording()
    }

    // MARK: - Pro
    //
    // Pulled up over the lower picture: six readouts on one ruler, and every
    // tool as a tile. The plate stays in front of it, so a take can start
    // (or stop) without putting Pro away.

    private func proSheet(size: CGSize) -> some View {
        let w = size.width
        let target = dialTarget
        let shape = UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: w, height: 56)
                .contentShape(Rectangle())
                .gesture(proDismissDrag)
            CamGrab()
                .frame(width: w)
                .offset(y: 8)
                .allowsHitTesting(false)
            proHeader
                .frame(width: max(w - 36, 0), height: 32)
                .offset(x: 20, y: 20)
            proReadouts
                .frame(width: max(w - 40, 0))
                .offset(x: 20, y: 66)
            CamRuler(ticks: dialTicks(for: target), index: dialPosition(for: target),
                     spacing: target.spacing) { applyDial($0, to: target) }
                .id(target)
                .frame(width: w)
                .offset(y: 124)
            proTiles
                .frame(width: max(w - 32, 0))
                .offset(x: 16, y: 186)
        }
        .frame(width: w, height: 476, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(hex: 0x0C0D0F).opacity(0.84))
            }
        }
        .contentShape(Rectangle())
        .offset(y: size.height - 476)
    }

    private var proDismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                if value.translation.height > 36 { proOpen = false }
            }
    }

    private var proHeader: some View {
        let target = dialTarget
        return HStack(spacing: 0) {
            Text("Pro")
                .font(.luma(size: 17, weight: .bold))
                .kerning(-0.3)
                .foregroundStyle(CamLab.text)
            Spacer(minLength: 0)
            Button {
                toggleAuto(target)
            } label: {
                CamMiniLabel(title: autoTitle(for: target), lit: isAutoTarget(target))
            }
            .buttonStyle(CamPressStyle())
            .padding(.trailing, 8)
            Button {
                proOpen = false
            } label: {
                CamMiniLabel(icon: .down)
            }
            .buttonStyle(CamPressStyle())
            .accessibilityLabel("Close Pro")
        }
    }

    /// Lens, ISO, shutter, white balance, exposure, focus: spread edge to
    /// edge. Tap one to put the ruler on it.
    private var proReadouts: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(proTargets.enumerated()), id: \.element) { index, target in
                if index > 0 { Spacer(minLength: 4) }
                CamReadout(name: target.short, value: dialValue(for: target),
                           auto: isAutoTarget(target), active: dialTarget == target) {
                    dialTarget = target
                    LumaHaptics.shared.tap()
                }
            }
        }
    }

    private var proTiles: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            CamTile(icon: .format, label: "Format", on: formatOpen, enabled: !recordingBusy) {
                useTool("format")
            }
            CamTile(icon: .guides, label: frameGuide == .off ? "Guides" : frameGuide.label,
                    on: frameGuide != .off) {
                useTool("guides")
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                toggleSafeZone()
            })
            CamTile(icon: .scope, label: "Scope", on: scopeMode != nil) { useTool("scope") }
            CamTile(icon: .zebras, label: "Zebras", on: camera.zebrasOn) { useTool("zebras") }
            CamTile(icon: .peaking, label: "Peaking", on: camera.peakingOn) { useTool("peaking") }
            CamTile(icon: .grid, label: "Grid", on: showGrid) { useTool("grid") }
            CamTile(icon: .level, label: "Level", on: showLevel) { useTool("level") }
            CamTile(icon: .auto, label: "Auto all") { useTool("auto") }
        }
    }

    // MARK: - Format
    //
    // A card under the format chip: resolution, frame rate and codec; the
    // photo modes swap those for the still format, size and the roll.

    private var formatCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Format")
                .font(.luma(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.top, 2)
                .padding(.horizontal, 4)
                .padding(.bottom, 10)
            if captureMode.takesStills {
                photoFormatRows
            } else {
                videoFormatRows
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.black.opacity(0.4))
                    .blur(radius: 20)
                    .offset(y: 18)
                RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22).fill(Color(hex: 0x0E0F12).opacity(0.78))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

    private var videoFormatRows: some View {
        // Options this camera cannot shoot are dimmed rather than offered and
        // then quietly swapped. Selection shows what is actually running.
        // Slo-mo owns the size and the rate.
        VStack(alignment: .leading, spacing: 10) {
            formatGroup("RESOLUTION") {
                ForEach(CameraSpec.Resolution.allCases, id: \.self) { resolution in
                    CamOption(title: resolution.rawValue,
                              on: camera.activeSpec.resolution == resolution,
                              enabled: captureMode != .slowMo && resolutionAvailable(resolution)) {
                        var spec = camera.spec
                        spec.resolution = resolution
                        camera.setSpec(spec)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            formatGroup("FRAME RATE") {
                ForEach(CameraSpec.fpsOptions, id: \.self) { fps in
                    CamOption(title: "\(fps)", on: camera.activeSpec.fps == fps,
                              enabled: captureMode != .slowMo && fpsAvailable(fps)) {
                        var spec = camera.spec
                        spec.fps = fps
                        camera.setSpec(spec)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            formatGroup("CODEC") {
                ForEach(CameraSpec.Codec.allCases, id: \.self) { codec in
                    CamOption(title: codec.rawValue, on: camera.activeSpec.codec == codec) {
                        var spec = camera.spec
                        spec.codec = codec
                        camera.setSpec(spec)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            if let note = formatFallbackNote {
                formatNote(note)
            }
        }
    }

    /// Still format, size and the roll. Sizes are only the ones this camera
    /// can deliver right now.
    private var photoFormatRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            formatGroup("FORMAT") {
                ForEach(PhotoCaptureSpec.Format.allCases, id: \.self) { format in
                    CamOption(title: format.rawValue, on: camera.photoSpec.format == format) {
                        var spec = camera.photoSpec
                        spec.format = format
                        camera.setPhotoSpec(spec)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            formatGroup("SIZE") {
                ForEach(offeredPhotoSizes, id: \.self) { size in
                    CamOption(title: size.label, on: photoSizeIsOn(size)) {
                        var spec = camera.photoSpec
                        spec.size = size
                        camera.setPhotoSpec(spec)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            if captureMode == .portrait {
                formatNote("Portrait shoots at up to 12 MP, where depth is available.")
            }
            formatGroup("ROLL") {
                CamOption(title: "Off", on: !rollOn) { setRoll(false) }
                CamOption(title: "\(Self.rollLength) frames", on: rollOn) { setRoll(true) }
            }
            if rollOn {
                HStack(spacing: 10) {
                    Text(rollLeft == 0 ? "Roll done" : "\(rollLeft) of \(Self.rollLength) left")
                        .font(.luma(size: 11.5, weight: .medium))
                        .foregroundStyle(CamLab.grey)
                    Button {
                        loadNewRoll()
                    } label: {
                        Text("New roll")
                            .font(.luma(size: 11.5, weight: .semibold))
                            .foregroundStyle(CamLab.sig)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CamPressStyle())
                    .disabled(rollLeft == Self.rollLength)
                    .opacity(rollLeft == Self.rollLength ? 0.4 : 1)
                }
                .padding(.leading, 4)
            }
        }
    }

    private func formatGroup<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.luma(size: 9, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(CamLab.label)
                .padding(.leading, 4)
            HStack(spacing: 6) {
                content()
            }
        }
    }

    private func formatNote(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 11.5, weight: .medium))
            .foregroundStyle(CamLab.grey)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// Unknown capabilities (simulator, camera not configured yet) enable
    /// everything rather than greying out the whole card.
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

    // MARK: - Every look
    //
    // Over the lower picture, which slides up so the face stays in view.
    // With the keyboard up it runs from under the look to the keyboard.

    private func looksLibrary(size: CGSize, top: CGFloat, keyboard: CGFloat) -> some View {
        let typing = keyboard > 120
        let y = typing ? top + 100 : max(size.height - 552, top + 44)
        let below = typing ? keyboard + 8 : 112
        let height = max(size.height - y - below, 160)
        return CameraLooksSheet(frame: rawFrame, frameID: rawFrameID, compact: typing,
                                onClose: { showLookBrowser = false },
                                onNote: { flash($0) })
            .frame(width: max(size.width - 16, 0), height: height)
            .camGlass(RoundedRectangle(cornerRadius: 26), tint: Color(hex: 0x0A0B0D), opacity: 0.9)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .contentShape(RoundedRectangle(cornerRadius: 26))
            .offset(x: 8, y: y)
    }

    // MARK: - Sideways
    //
    // The interface stays fixed to the phone. Held sideways, the controls on
    // the picture are laid out for the long edge and turned to read upright:
    // the top bar by the island, the readouts along the top with their ruler
    // dropping under them, the look at the bottom by the island and the tools
    // at the bottom by the plate. The plate stays where the thumb is and only
    // its icons turn.

    private var isLandscapeLayout: Bool { forcedLandscape || camera.isLandscape }
    private var landscapeClockwise: Bool {
        forcedLandscape ? forcedClockwise : camera.landscapeClockwise
    }
    /// How far the sideways controls turn to read upright.
    private var landscapeTurn: Double { landscapeClockwise ? -90 : 90 }
    /// The turn for anything that stays put on the plate.
    private var controlTurn: Double { isLandscapeLayout ? landscapeTurn : 0 }

    private func landscapeChrome(size: CGSize, top: CGFloat) -> some View {
        let long = size.height, short = size.width
        return landscapeContent(long: long, short: short, top: top)
            .frame(width: long, height: short, alignment: .topLeading)
            .rotationEffect(.degrees(landscapeTurn))
            .frame(width: size.width, height: size.height)
    }

    /// Where things hang when the phone is held sideways: `long` across and
    /// `short` tall. Turned anticlockwise (+90) the island is on the left and
    /// the plate on the right; the other way round they swap, and so does
    /// everything hung off them.
    private struct Sideways {
        let long: CGFloat
        let short: CGFloat
        let islandLeading: Bool
        let islandInset: CGFloat
        let plateInset: CGFloat = 112

        var inner: CGFloat { max(long - islandInset - plateInset, 0) }
        var originX: CGFloat { islandLeading ? islandInset : plateInset }
        var islandSide: HorizontalAlignment { islandLeading ? .leading : .trailing }
        var plateSide: HorizontalAlignment { islandLeading ? .trailing : .leading }
        /// The picture left clear of the plate.
        var pictureX: CGFloat { islandLeading ? 0 : CamLab.plateHeight }
        var pictureW: CGFloat { max(long - CamLab.plateHeight, 0) }
        var stripWidth: CGFloat { min(390, max(inner - 250, 200)) }

        func at(_ horizontal: HorizontalAlignment, _ vertical: VerticalAlignment = .center) -> Alignment {
            Alignment(horizontal: horizontal, vertical: vertical)
        }
    }

    private func landscapeContent(long: CGFloat, short: CGFloat, top: CGFloat) -> some View {
        let layout = Sideways(long: long, short: short, islandLeading: landscapeTurn > 0,
                              islandInset: max(top - 2, 16))
        return ZStack(alignment: .topLeading) {
            landscapeScrims(long: long, short: short)
            landscapeMarks(layout)
            landscapeBars(layout)
            landscapeCorners(layout)
            landscapePanels(layout)
        }
        .frame(width: long, height: short, alignment: .topLeading)
        .animation(.easeOut(duration: 0.18), value: landscapeDropOpen)
    }

    /// The guide, the swipe's edge and the look's name.
    @ViewBuilder
    private func landscapeMarks(_ layout: Sideways) -> some View {
        if frameGuide != .off {
            CamGuide(box: landscapeGuideBox(x: layout.pictureX, width: layout.pictureW,
                                            height: layout.short),
                     label: frameGuide.label,
                     safeZone: showSafeZone && frameGuide == .vertical)
                .frame(width: layout.long, height: layout.short)
                .transition(.opacity)
        }
        if let swipe {
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 2, height: layout.short)
                .shadow(color: .white.opacity(0.6), radius: 7)
                .offset(x: swipe.edge(in: layout.long) - 1)
                .allowsHitTesting(false)
        }
        bigName(width: layout.pictureW)
            .offset(x: layout.pictureX, y: 150)
    }

    /// Along the top: the bar by the island, the readouts by the plate, and
    /// their ruler dropping under them.
    @ViewBuilder
    private func landscapeBars(_ layout: Sideways) -> some View {
        landscapeTopBar
            .frame(width: layout.inner, alignment: layout.at(layout.islandSide))
            .offset(x: layout.originX, y: 14)
        landscapeStrip
            .frame(width: layout.stripWidth, height: 50, alignment: .top)
            .landscapeGlass(opacity: 0.55)
            .frame(width: layout.inner, alignment: layout.at(layout.plateSide))
            .offset(x: layout.originX, y: 10)
        if landscapeDropOpen {
            landscapeDrop(width: layout.stripWidth)
                .frame(width: layout.inner, alignment: layout.at(layout.plateSide))
                .offset(x: layout.originX, y: 66)
                .transition(.opacity)
        }
        sideStack
            .frame(width: layout.inner, alignment: layout.at(layout.islandSide))
            .offset(x: layout.originX, y: 60)
    }

    /// Along the bottom: the look by the island, the tools by the plate.
    @ViewBuilder
    private func landscapeCorners(_ layout: Sideways) -> some View {
        lookTag(ring: 40)
            .frame(width: layout.inner, height: max(layout.short - 12, 0),
                   alignment: layout.at(layout.islandSide, .bottom))
            .offset(x: layout.originX)
            .opacity(swipe != nil ? 0 : 1)
        landscapeTools
            .frame(width: max(layout.inner - 4, 0), height: max(layout.short - 10, 0),
                   alignment: layout.at(layout.plateSide, .bottom))
            .offset(x: layout.islandLeading ? layout.originX : layout.originX + 4)
    }

    /// The caption, the format card and every look.
    @ViewBuilder
    private func landscapePanels(_ layout: Sideways) -> some View {
        if let statusCaption {
            let naming = swipe != nil || nameFlash != nil
            CamToast(text: statusCaption)
                .id(statusCaption)
                .frame(width: layout.pictureW)
                .offset(x: layout.pictureX, y: naming ? 104 : 150)
                .transition(.opacity)
        }
        if formatOpen {
            let cardX = layout.islandLeading ? layout.islandInset + 50
                                             : layout.long - layout.islandInset - 314
            formatCard
                .frame(width: 264, alignment: .leading)
                .offset(x: cardX, y: 56)
                .transition(.opacity)
        }
        if showLookBrowser {
            landscapeLooks(long: layout.long, short: layout.short,
                           islandLeading: layout.islandLeading, islandInset: layout.islandInset)
        }
    }

    private func landscapeScrims(long: CGFloat, short: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: long, height: 120)
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.55), location: 0.45),
                .init(color: .black.opacity(0.82), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(width: long, height: 132)
                .offset(y: short - 132)
        }
        .frame(width: long, height: short, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func landscapeGuideBox(x: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        let aspect = CGFloat(frameGuide.aspect ?? 1)
        var gw = width - 24
        var gh = gw / aspect
        if gh > height - 20 {
            gh = height - 20
            gw = gh * aspect
        }
        return CGRect(x: x + (width - gw) / 2, y: (height - gh) / 2, width: gw, height: gh)
    }

    private var landscapeTopBar: some View {
        HStack(spacing: 8) {
            closeButton
            formatChip
            histogramButton
        }
    }

    /// The readouts along the top. Tap one and its ruler drops under them.
    private var landscapeStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(proTargets.enumerated()), id: \.element) { index, target in
                if index > 0 { Spacer(minLength: 2) }
                CamReadout(name: target.short, value: dialValue(for: target),
                           auto: isAutoTarget(target),
                           active: landscapeDropOpen && dialTarget == target) {
                    if landscapeDropOpen, dialTarget == target {
                        landscapeDropOpen = false
                    } else {
                        dialTarget = target
                        landscapeDropOpen = true
                        formatOpen = false
                    }
                    LumaHaptics.shared.tap()
                }
            }
        }
        .padding(.top, 7)
        .padding(.horizontal, 14)
    }

    private func landscapeDrop(width: CGFloat) -> some View {
        let target = dialTarget
        let auto = isAutoTarget(target)
        return ZStack(alignment: .topLeading) {
            CamRuler(ticks: dialTicks(for: target), index: dialPosition(for: target),
                     spacing: target.spacing) { applyDial($0, to: target) }
                .id(target)
                .frame(width: max(width - 50, 0))
                .offset(y: 3)
            Button {
                toggleAuto(target)
            } label: {
                Text("A")
                    .font(.luma(size: 12, weight: .bold))
                    .foregroundStyle(auto ? CamLab.ink : CamLab.text)
                    .frame(width: 28, height: 28)
                    .background(auto ? CamLab.sig : CamLab.raised, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(CamPressStyle())
            .accessibilityLabel(autoTitle(for: target))
            .offset(x: width - 40, y: 11)
        }
        .frame(width: width, height: 50, alignment: .topLeading)
        .landscapeGlass(opacity: 0.62)
    }

    private var landscapeTools: some View {
        HStack(spacing: 4) {
            landscapeTool(.guides, "Guides", on: frameGuide != .off) { cycleGuide() }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    toggleSafeZone()
                })
            landscapeTool(.zebras, "Zebras", on: camera.zebrasOn) { toggleZebras() }
            landscapeTool(.peaking, "Peaking", on: camera.peakingOn) { togglePeaking() }
            landscapeTool(.grid, "Grid", on: showGrid) { toggleGrid() }
            landscapeTool(.level, "Level", on: showLevel) { toggleLevel() }
            landscapeTool(.scope, "Scope", on: scopeMode != nil) { cycleScope() }
            landscapeTool(.lock, "AE/AF lock", on: camera.aeafLocked) { toggleAEAF() }
            landscapeTool(.format, "Format", on: formatOpen) { toggleFormat() }
        }
        .padding(4)
        .camGlass(RoundedRectangle(cornerRadius: 22), tint: Color(hex: 0x0C0D0F), opacity: 0.55)
    }

    private func landscapeTool(_ icon: CamIcon, _ label: String, on: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CamGlyph(icon: icon, size: 21, weight: 1.6)
                .foregroundStyle(on ? CamLab.sig : Color.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(on ? CamLab.sig.opacity(0.15) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Every look, as a panel down the island's side of the picture.
    private func landscapeLooks(long: CGFloat, short: CGFloat, islandLeading: Bool,
                                islandInset: CGFloat) -> some View {
        let width = min(440 + max(islandInset - 60, 0), max(long - 130, 0))
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: islandLeading ? 0 : 26, bottomLeadingRadius: islandLeading ? 0 : 26,
            bottomTrailingRadius: islandLeading ? 26 : 0, topTrailingRadius: islandLeading ? 26 : 0)
        return CameraLooksSheet(frame: rawFrame, frameID: rawFrameID, compact: false,
                                onClose: { showLookBrowser = false },
                                onNote: { flash($0) })
            .padding(islandLeading ? .leading : .trailing, max(islandInset - 14, 0))
            .frame(width: width, height: short)
            .camGlass(shape, tint: Color(hex: 0x0A0B0D), opacity: 0.9)
            .clipShape(shape)
            .contentShape(Rectangle())
            .offset(x: islandLeading ? 0 : long - width)
            .transition(.move(edge: islandLeading ? .leading : .trailing).combined(with: .opacity))
    }

    // MARK: - Actions

    private func openPro() {
        guard !isLandscapeLayout else { return }
        formatOpen = false
        showLookBrowser = false
        proOpen = true
        LumaHaptics.shared.tap()
    }

    private func openLooks() {
        landscapeDropOpen = false
        formatOpen = false
        proOpen = false
        showLookBrowser.toggle()
        LumaHaptics.shared.tap()
    }

    private func toggleFormat() {
        guard !recordingBusy else {
            flash("Stop recording to change the format")
            return
        }
        landscapeDropOpen = false
        showLookBrowser = false
        proOpen = false
        formatOpen.toggle()
        LumaHaptics.shared.tap()
    }

    /// All five scopes, then off.
    private func cycleScope() {
        let all = ScopeMode.allCases
        if let current = scopeMode, let index = all.firstIndex(of: current) {
            scopeMode = index + 1 < all.count ? all[index + 1] : nil
        } else {
            scopeMode = all.first
        }
        flash(scopeMode.map { "Scope: \(scopeName($0))" } ?? "Scope off")
        LumaHaptics.shared.tap()
    }

    private func cycleGuide() {
        let all = FrameGuide.allCases
        let index = ((all.firstIndex(of: frameGuide) ?? 0) + 1) % all.count
        frameGuide = all[index]
        flash(frameGuide == .off ? "Guides off" : "Guide \(frameGuide.label)")
        LumaHaptics.shared.tap()
    }

    private func toggleSafeZone() {
        showSafeZone.toggle()
        flash(showSafeZone ? "Safe zone on" : "Safe zone off")
        LumaHaptics.shared.tap()
    }

    private func toggleZebras() {
        camera.zebrasOn.toggle()
        flash(camera.zebrasOn ? "Zebras on" : "Zebras off")
        LumaHaptics.shared.tap()
    }

    private func togglePeaking() {
        camera.peakingOn.toggle()
        flash(camera.peakingOn ? "Peaking on" : "Peaking off")
        LumaHaptics.shared.tap()
    }

    private func toggleGrid() {
        showGrid.toggle()
        flash(showGrid ? "Grid on" : "Grid off")
        LumaHaptics.shared.tap()
    }

    private func toggleLevel() {
        showLevel.toggle()
        flash(showLevel ? "Level on" : "Level off")
        LumaHaptics.shared.tap()
    }

    private func toggleAEAF() {
        // The lock lands on the session queue, so read the intent first.
        let locking = !camera.aeafLocked
        camera.toggleAEAFLock()
        if !locking { clearFocusMark() }
        flash(locking ? "AE/AF locked" : "AE/AF unlocked")
        LumaHaptics.shared.tap()
    }

    /// The escape hatch: everything back to automatic in one tap, including
    /// the AE/AF lock, so no invisible manual state can survive it.
    private func autoAll() {
        camera.resetAutoExposure()
        camera.resetAutoWB()
        camera.resetAutoFocus()
        camera.setEVBias(0)
        camera.unlockAEAF()
        clearFocusMark()
        flash("Everything back to auto")
        LumaHaptics.shared.tap()
    }

    /// A short caption over the picture.
    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { statusCaption = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
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

    // MARK: Stills

    /// A roll of film.
    static let rollLength = 36
    /// Portrait's f-numbers: f/1.4 blurs the most, f/16 barely at all.
    private static let apertureStops: [Double] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16]

    /// Full sensor resolution through AVCapturePhotoOutput at the chosen
    /// size, graded with the live look and saved as HEIF or JPEG. Portrait
    /// adds the depth blur at the dial's aperture. The simulator falls back
    /// to the preview buffer. With a roll loaded, every press spends a frame.
    private func captureStill() {
        app.settlePackPreview(storeService)
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
                    // Sensor capture failed: fall back to the preview.
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
                // Compare against the SAME literal we set, so the caption
                // always clears.
                let denied = "Turn on Add Photos Only in Settings to save"
                withAnimation(.easeOut(duration: 0.2)) { statusCaption = denied }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if statusCaption == denied {
                    withAnimation(.easeOut(duration: 0.25)) { statusCaption = nil }
                }
                return
            }
            do {
                // Added as a resource so the file stays the HEIF or JPEG the
                // format chip promised.
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
        guard on != rollOn else { return }
        rollOn = on
        if on, rollLeft <= 0 { rollLeft = Self.rollLength }
        if !on { showRollDone = false }
        flash(on ? "Roll loaded · \(rollLeft) frames" : "Roll off")
        LumaHaptics.shared.tap()
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
        formatOpen = false
        if old == .slowMo, new != .slowMo { camera.setSlowMotion(false) }
        if old == .portrait, new != .portrait { camera.setDepthCapture(false) }
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
            flash("Background blur goes on as you shoot")
        case .photo, .video:
            flash(new.rawValue)
        }
        // The first chip is Lens, or Aperture in Portrait.
        if new == .portrait, dialTarget == .lens { dialTarget = .aperture }
        if new != .portrait, dialTarget == .aperture { dialTarget = .lens }
    }

    // MARK: Last shot

    /// The newest capture opens in the grade room, as the hand-off card's
    /// Grade does; with only a library item to show it opens your clips.
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
        // The simulator preview shows the seeded frame by the shutter.
        if let path = ProcessInfo.processInfo.environment["LUMA_SEED_CAMFRAME"],
           let image = UIImage(contentsOfFile: path) {
            lastShot = LastShot(thumbnail: image, source: .library)
            return
        }
        #endif
        if let image = await CameraLibraryThumb.latest(side: 160) {
            if lastShot == nil { lastShot = LastShot(thumbnail: image, source: .library) }
        }
    }

    // MARK: - What the dial turns
    //
    // The dial, Pro's ruler and the sideways ruler all step through the same
    // stops (cine practice: discrete, repeatable between takes).

    /// The lab's lens stops, as 35 mm focal lengths.
    private static let lensMillimetres: [Int] = [13, 16, 20, 24, 28, 35, 48, 65, 77, 100]
    private static let isoStops: [Float] = [25, 32, 50, 64, 100, 125, 160, 200, 250, 320,
                                            400, 500, 640, 800, 1000, 1250, 1600, 2000,
                                            2500, 3200, 4000, 5000, 6400]
    /// Ordered so faster shutters move RIGHT (1/30 to 1/240 at 30 fps).
    private static let shutterAngles: [Double] = [360, 270, 180, 90, 45]
    private static let wbStops: [Float] = [2500, 2800, 3200, 3600, 4000, 4500, 5000,
                                           5600, 6500, 7500, 9000]
    private static let evStops: [Float] = [-2, -1.7, -1.3, -1, -0.7, -0.3, 0,
                                            0.3, 0.7, 1, 1.3, 1.7, 2]
    /// Normalised lens positions, near to far. The dial puts AF before them.
    private static let focusStops: [Float] = stride(from: 0.0, through: 1.0, by: 0.1)
        .map { Float($0) }

    /// The familiar iPhone marks: display zoom against 35 mm focal length.
    private static let lensMarks: [(zoom: CGFloat, mm: CGFloat)] =
        [(0.5, 13), (1, 24), (2, 48), (3, 77), (5, 120)]

    /// 35 mm-equivalent focal length for a display zoom.
    static func millimetres(_ zoom: CGFloat) -> Int {
        let marks = lensMarks
        guard zoom > marks[0].zoom else { return Int(marks[0].mm) }
        for (a, b) in zip(marks, marks.dropFirst()) where zoom <= b.zoom {
            let t = (zoom - a.zoom) / (b.zoom - a.zoom)
            return Int((a.mm + t * (b.mm - a.mm)).rounded())
        }
        return Int((zoom / 5 * 120).rounded())
    }

    /// The display zoom that gives a focal length: `millimetres` backwards.
    static func zoom(forMillimetres mm: CGFloat) -> CGFloat {
        let marks = lensMarks
        guard mm > marks[0].mm else { return marks[0].zoom }
        for (a, b) in zip(marks, marks.dropFirst()) where mm <= b.mm {
            let t = (mm - a.mm) / (b.mm - a.mm)
            return a.zoom + t * (b.zoom - a.zoom)
        }
        return mm / 120 * 5
    }

    /// The lab's stops this camera can reach (a camera with no ultra-wide
    /// starts at 24).
    private var lensStops: [Int] {
        let range = camera.zoomRange
        let reachable = Self.lensMillimetres.filter { mm in
            let zoom = Self.zoom(forMillimetres: CGFloat(mm))
            return zoom >= range.lowerBound - 0.02 && zoom <= range.upperBound + 0.02
        }
        return reachable.count > 1 ? reachable : Self.lensMillimetres
    }

    private var isoStopsInRange: [Float] {
        let range = camera.isoRange
        let inRange = Self.isoStops.filter { range.contains($0) }
        return inRange.isEmpty ? Self.isoStops : inRange
    }

    /// "f/1.4", "f/2", "f/11" for an index into `apertureStops`.
    private static func fNumber(_ index: Int) -> String {
        guard apertureStops.indices.contains(index) else { return "f/2.8" }
        let value = apertureStops[index]
        if value == value.rounded() { return "f/\(Int(value))" }
        return String(format: "f/%.1f", value)
    }

    /// Shutter speed implied by an angle at the current frame rate.
    private func shutterLabel(_ angle: Double) -> String {
        "1/\(Int((360.0 / max(angle, 1)) * Double(camera.activeSpec.fps)))"
    }

    /// "+0.3", "−1.0": a real minus sign, one decimal.
    private static func evLabel(_ value: Float) -> String {
        let size = String(format: "%.1f", abs(value))
        return (value < -0.04 ? "\u{2212}" : "+") + size
    }

    private static func nearest<T: BinaryFloatingPoint>(_ value: T, in stops: [T]) -> Int {
        stops.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
    }

    private func dialTicks(for target: DialTarget) -> [String] {
        switch target {
        case .lens:     return lensStops.map { "\($0)" }
        case .aperture: return Self.apertureStops.indices.map { Self.fNumber($0) }
        case .shutter:  return Self.shutterAngles.map { shutterLabel($0) }
        case .iso:      return isoStopsInRange.map { "\(Int($0))" }
        case .ev:       return Self.evStops.map { Self.evLabel($0) }
        case .wb:       return Self.wbStops.map { "\(Int($0))" }
        case .focus:    return ["AF"] + Self.focusStops.map { String(format: "%.1f", $0) }
        }
    }

    /// The stop nearest the value in force, so the dial always opens centred
    /// on what the camera is actually doing.
    private func dialPosition(for target: DialTarget) -> Int {
        switch target {
        case .lens:
            let mm = Self.millimetres(camera.zoomFactor)
            let stops = lensStops
            return stops.indices.min { abs(stops[$0] - mm) < abs(stops[$1] - mm) } ?? 0
        case .aperture:
            return apertureIndex
        case .shutter:
            return Self.nearest(camera.shutterAngle, in: Self.shutterAngles)
        case .iso:
            let stops = isoStopsInRange
            let iso = camera.currentISO > 0 ? camera.currentISO : (stops.first ?? 100)
            return Self.nearest(iso, in: stops)
        case .ev:
            return Self.nearest(camera.evBias, in: Self.evStops)
        case .wb:
            return Self.nearest(camera.wbTemperature, in: Self.wbStops)
        case .focus:
            guard camera.manualFocus else { return 0 }
            return Self.nearest(camera.lensPosition, in: Self.focusStops) + 1
        }
    }

    /// Every move writes straight through to the camera. Moving a stop is
    /// also what takes a value off auto, so there is no switch to forget.
    private func applyDial(_ index: Int, to target: DialTarget) {
        switch target {
        case .lens:
            let stops = lensStops
            guard stops.indices.contains(index) else { return }
            camera.setDisplayZoom(Self.zoom(forMillimetres: CGFloat(stops[index])))
        case .aperture:
            guard Self.apertureStops.indices.contains(index) else { return }
            apertureIndex = index
        case .shutter:
            guard Self.shutterAngles.indices.contains(index) else { return }
            camera.setManualExposure(angle: Self.shutterAngles[index])
        case .iso:
            let stops = isoStopsInRange
            guard stops.indices.contains(index) else { return }
            camera.setManualExposure(iso: stops[index])
        case .ev:
            guard Self.evStops.indices.contains(index) else { return }
            camera.setEVBias(Self.evStops[index])
        case .wb:
            guard Self.wbStops.indices.contains(index) else { return }
            camera.setWhiteBalance(temperature: Self.wbStops[index], tint: camera.wbTint)
        case .focus:
            if index == 0 {
                camera.resetAutoFocus()
                return
            }
            guard Self.focusStops.indices.contains(index - 1) else { return }
            camera.setManualFocus(Self.focusStops[index - 1])
        }
    }

    /// The value as Pro and the sideways readouts show it.
    private func dialValue(for target: DialTarget) -> String {
        switch target {
        case .lens:     return "\(Self.millimetres(camera.zoomFactor))mm"
        case .aperture: return Self.fNumber(apertureIndex)
        case .shutter:  return shutterLabel(camera.shutterAngle)
        case .iso:      return "\(Int(camera.currentISO > 0 ? camera.currentISO : 100))"
        case .ev:       return Self.evLabel(camera.evBias)
        case .wb:       return "\(Int(camera.wbTemperature))K"
        case .focus:    return camera.manualFocus ? String(format: "%.1f", camera.lensPosition) : "AF"
        }
    }

    /// The value on the dial: the lens sets its unit smaller beside it.
    private func dialValueParts(for target: DialTarget) -> (value: String, unit: String?) {
        if target == .lens {
            return ("\(Self.millimetres(camera.zoomFactor))", "mm")
        }
        return (dialValue(for: target), nil)
    }

    /// The camera, not the person, is choosing this value.
    private func isAutoTarget(_ target: DialTarget) -> Bool {
        switch target {
        case .shutter, .iso: return !camera.manualExposure
        case .wb:            return !camera.manualWB
        case .focus:         return !camera.manualFocus
        case .lens, .aperture, .ev: return false
        }
    }

    /// Pro's Auto button: "Auto on" while the camera chooses, "Auto" to hand
    /// it back, "Manual" for the values that are always set by hand.
    private func autoTitle(for target: DialTarget) -> String {
        switch target {
        case .lens, .aperture, .ev: return "Manual"
        case .shutter, .iso, .wb, .focus: return isAutoTarget(target) ? "Auto on" : "Auto"
        }
    }

    private func toggleAuto(_ target: DialTarget) {
        switch target {
        case .lens, .aperture:
            flash("\(target.spoken) is always manual")
        case .ev:
            if camera.evBias != 0 {
                camera.setEVBias(0)
                flash("Exposure back to 0")
            } else {
                flash("Exposure is always manual")
            }
        case .shutter, .iso, .wb:
            if isAutoTarget(target) {
                // Leaving auto holds the value auto was showing.
                applyDial(dialPosition(for: target), to: target)
                flash("\(target.spoken) on manual")
            } else {
                setAuto(target)
            }
        case .focus:
            if isAutoTarget(target) {
                applyDial(6, to: target)
                flash("Focus on manual")
            } else {
                setAuto(target)
            }
        }
        LumaHaptics.shared.tap()
    }

    private func setAuto(_ target: DialTarget) {
        switch target {
        case .shutter, .iso: camera.resetAutoExposure()
        case .wb:            camera.resetAutoWB()
        case .focus:         camera.resetAutoFocus()
        case .ev:            camera.setEVBias(0)
        case .lens, .aperture: return
        }
        flash("\(target.spoken) back to auto")
    }
}

// MARK: - What the dial turns

/// One of the camera's dialable values: the chips, Pro's readouts and the
/// sideways readouts all pick from these.
private enum DialTarget: Hashable, CaseIterable {
    case lens, aperture, shutter, iso, ev, wb, focus

    /// On its chip.
    var chip: String {
        switch self {
        case .lens:     return "Lens"
        case .aperture: return "Aperture"
        case .shutter:  return "Shutter"
        case .iso:      return "ISO"
        case .ev:       return "Exposure"
        case .wb:       return "WB"
        case .focus:    return "Focus"
        }
    }

    /// Under the dial's value.
    var caption: String {
        switch self {
        case .lens:     return "LENS"
        case .aperture: return "APERTURE"
        case .shutter:  return "SHUTTER"
        case .iso:      return "ISO"
        case .ev:       return "EXPOSURE"
        case .wb:       return "WHITE BAL."
        case .focus:    return "FOCUS"
        }
    }

    /// Under a readout.
    var short: String {
        switch self {
        case .lens:     return "LENS"
        case .aperture: return "APERTURE"
        case .shutter:  return "SS"
        case .iso:      return "ISO"
        case .ev:       return "EV"
        case .wb:       return "WB"
        case .focus:    return "FOCUS"
        }
    }

    /// In a sentence.
    var spoken: String {
        switch self {
        case .lens:     return "Lens"
        case .aperture: return "Aperture"
        case .shutter:  return "Shutter"
        case .iso:      return "ISO"
        case .ev:       return "Exposure"
        case .wb:       return "White balance"
        case .focus:    return "Focus"
        }
    }

    /// Points between stops on a ruler, as the lab spaces each one.
    var spacing: CGFloat {
        switch self {
        case .lens:     return 34
        case .aperture: return 40
        case .shutter:  return 46
        case .iso:      return 42
        case .ev:       return 34
        case .wb:       return 48
        case .focus:    return 42
        }
    }

    /// For the preview's seed, e.g. LUMA_SEED_CAMPRO=shutter.
    static func named(_ raw: String) -> DialTarget? {
        switch raw.lowercased() {
        case "lens":            return .lens
        case "aperture":        return .aperture
        case "shutter", "ss":   return .shutter
        case "iso":             return .iso
        case "ev", "exposure":  return .ev
        case "wb":              return .wb
        case "focus":           return .focus
        default:                return nil
        }
    }
}

// MARK: - A finger on the picture

/// The square on the picture: where it is, what it says, and whether it
/// stays (a lock) or fades (a tap).
private struct FocusMark: Equatable {
    let id: Int
    let point: CGPoint
    let label: String
    let hold: Bool
}

/// A tap, a swipe through looks, or a hold for the fan.
private struct TouchState {
    enum Mode { case pending, swipe, fan, ignored }
    var mode: Mode
    let start: CGPoint
    var last: CGPoint
    let token: Int
}

/// A swipe through the favourites, in progress.
private struct SwipeState: Equatable {
    /// +1 brings in the next favourite (the finger moving left), -1 the one
    /// before.
    let direction: Int
    let next: CameraLook
    /// The finger's travel along the swipe, signed.
    var travel: CGFloat
    let token: Int
    /// Let go: sliding home or off, and no longer following a finger.
    var finishing = false

    /// Where the wipe's edge sits across a picture this wide.
    func edge(in width: CGFloat) -> CGFloat {
        direction == 1 ? min(max(width + travel, 0), width) : min(max(travel, 0), width)
    }
}

/// The thumb fan, open.
private struct FanState {
    var touch: CGPoint
    /// Where the finger went down.
    let origin: CGPoint
    let centre: CGPoint
    let positions: [CGPoint]
    var hot: Int?

    /// Still where it pressed, on no tool: letting go here locks AE/AF.
    var resting: Bool {
        hot == nil && hypot(touch.x - origin.x, touch.y - origin.y) < 30
    }
}

/// The newest capture for the tile on the plate, and what tapping it opens.
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

private extension View {
    /// The sideways readouts' glass.
    func landscapeGlass(opacity: Double) -> some View {
        camGlass(RoundedRectangle(cornerRadius: 18), tint: Color(hex: 0x0C0D0F), opacity: opacity)
    }
}

/// The take returns a result: the clip is written, now choose where it goes.
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
                    CamLab.raised
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            // clipShape clips pixels, NOT touches.
            .contentShape(RoundedRectangle(cornerRadius: 14))

            Text("Clip saved · look baked in")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0xC9CBD0))

            HStack(spacing: 8) {
                handButton("Retake", solid: false, action: onRetake)
                handButton("Grade", solid: false, action: onGrade)
                handButton("Edit", solid: true, action: onEdit)
            }
        }
        .padding(18)
        .background(Color(hex: 0x0C0D0F).opacity(0.95), in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
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
                .font(.luma(size: 14, weight: .bold))
                .foregroundStyle(solid ? CamLab.ink : CamLab.text)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(solid ? CamLab.sig : Color.white.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(CamPressStyle())
    }
}

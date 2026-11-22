import SwiftUI
import CoreImage
import AVFoundation
import Photos

// =============================================================================
// CameraLiveLookView — camera A, "one camera that grows".
//
// The picture fills the screen. What sits on it, from the top:
//   · close, the capture format, the take's timecode, and zoom (the focus
//     mode in the photo modes)
//   · the look on the picture at top left (ring, name, strength, a dot for
//     each favourite), the histogram and Pro at top right
//   · the chips over the dial: Look, Lens (Aperture in Portrait), Shutter,
//     ISO, EV, WB, Focus. The dial curves over the shutter and turns
//     whichever chip is lit; drag it up for Pro
//   · the modes and the capture row, where they always were, so the tab
//     bar's yellow shutter still lands on the record button
//
// Four ways it grows:
//   1. Swipe the picture sideways to step through your favourite looks.
//      Tap the look name for every look in the app (CameraLooksSheet).
//   2. Pull the dial up, or tap Pro: six readouts on one ruler and every
//      tool as a tile, with the format page inside.
//   3. Press and hold anywhere on the picture: the tools fan out above the
//      thumb. Slide onto one and let go.
//   4. Turn the phone sideways: readouts along the top, the look at bottom
//      left, tools at bottom right, every label upright. The shutter stays
//      where the thumb already is.
//
// FEATURE INVENTORY. Nothing from the previous camera was dropped:
//   ✓ Capture-format chip off camera.activeSpec; resolution, frame rate and
//     codec (tap the chip, or Pro → Format)
//   ✓ Every look in the app with live graded tiles, search, filters,
//     favourites and strength; paid looks free to try, asked for at record
//   ✓ Look strength on the dial (Look chip) and in the looks sheet
//   ✓ Zoom: the Lens chip on the dial, and continuous pinch
//   ✓ Shutter, ISO, EV, white balance and manual focus on the dial and in
//     Pro, each with Auto; Auto all in Pro
//   ✓ Zebras, focus peaking, grid, level, frame guides (long-press for the
//     social safe zone), live scope in five modes, histogram
//   ✓ AE/AF lock (the fan, Pro and the sideways tools) with its badge
//   ✓ Tap to focus with brackets; front/back flip (blocked mid-take)
//   ✓ Photo · Video · Slo-mo · Portrait; roll mode; portrait blur at the
//     dial's aperture; full-resolution graded stills
//   ✓ Recording with the look baked in, timecode, mic meter, the
//     saved-to-Photos caption and the hand-off card (Retake / Grade / Edit)
//   ✓ Last shot by the shutter; permission and no-camera fallbacks
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

    /// Pro, or the format page inside it, over the shutter. The sideways
    /// layout shows the format page as a card instead.
    private enum Panel: Equatable { case none, pro, format }
    @State private var panel: Panel = .none

    /// What the dial, Pro's ruler and the sideways ruler turn.
    @State private var dialTarget: DialTarget = .lens

    /// Photo takes a graded still; Video records with the look baked in;
    /// Slo-mo records at the camera's highest rate and plays back slowed;
    /// Portrait takes a still with a depth blur. Slo-mo and Portrait only
    /// show on cameras that can do them.
    private enum CaptureMode: String, CaseIterable {
        case photo = "Photo", video = "Video", slowMo = "Slo-mo", portrait = "Portrait"

        var takesStills: Bool { self == .photo || self == .portrait }

        var symbol: String {
            switch self {
            case .photo:    return "camera.fill"
            case .video:    return "video.fill"
            case .slowMo:   return "slowmo"
            case .portrait: return "person.fill"
            }
        }
    }
    @State private var captureMode: CaptureMode = .video
    /// Portrait's f-number, as an index into `apertureStops` (f/2.8).
    @State private var apertureIndex = 2
    /// The live histogram pill, on by default; tap hides it to a small glyph.
    @AppStorage("lumalook.camera.histogram") private var showHistogram = true
    /// Roll mode: an optional roll of 36 that the shutter counts down.
    @AppStorage("lumalook.camera.rollOn") private var rollOn = false
    @AppStorage("lumalook.camera.rollLeft") private var rollLeft = 36
    @State private var showRollDone = false
    /// The newest capture (or library item) for the button by the shutter.
    @State private var lastShot: LastShot?
    /// The 120 ms white blink when a still is taken.
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
    /// Where the focus brackets sit (nil: at rest, faint), whether they are
    /// still lit from the tap, and a counter that restarts the animate-in.
    @State private var focusPoint: CGPoint?
    @State private var focusActive = false
    @State private var focusTapID = 0
    /// DEBUG only: a unit point for lit brackets in the preview screenshot.
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
    @State private var screenSize: CGSize = .zero

    // MARK: Sideways
    /// DEBUG: LUMA_SEED_CAMLAND forces the sideways layout.
    @State private var forcedLandscape = false
    @State private var forcedClockwise = false
    /// The ruler under the sideways readouts.
    @State private var landscapeDropOpen = false

    private static let space = "camera"
    private static let looksSheetStyle = LumaSheetStyle(
        detents: [.lumaSmall, .fraction(0.56), .large],
        defaultDetent: .fraction(0.56),
        undimmedUpThrough: .fraction(0.56))

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
            .onChange(of: isLandscapeLayout) { _, _ in
                // Pro lives over the shutter upright; sideways has its own
                // readouts, so nothing carries across the turn.
                panel = .none
                landscapeDropOpen = false
                cancelTouch()
            }
            .onChange(of: showLookBrowser) { _, open in
                if open { refreshRawFrame() }
            }
            .task { await loadLibraryThumb() }
    }

    private var mainBody: some View {
        ZStack(alignment: .top) {
            LumaTheme.ink.ignoresSafeArea()

            // The picture runs full width from the top edge; everything else
            // sits over it.
            viewfinder
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)

            controls

            if let fan {
                CameraToolFan(touch: fan.touch, centre: fan.centre, items: fanItems,
                              positions: fan.positions, hot: fan.hot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(40)
            }

            if let recording = camera.lastRecordingURL, !camera.isRecording {
                CameraHandOffCard(url: recording,
                                  onRetake: { camera.lastRecordingURL = nil },
                                  onGrade: { handOffToGrade(recording) },
                                  onEdit: { handOffToEditor(recording) })
                    .frame(maxWidth: 380)
                    .rotationEffect(.degrees(controlTurn))
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
                    .rotationEffect(.degrees(controlTurn))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(51)
            }
        }
        .coordinateSpace(name: Self.space)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { screenSize = geo.size }
                    .onChange(of: geo.size) { _, size in screenSize = size }
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: panel)
        .animation(.easeOut(duration: 0.15), value: showGrid)
        .animation(.easeOut(duration: 0.15), value: showLevel)
        .animation(.easeOut(duration: 0.18), value: frameGuide)
        .animation(.easeOut(duration: 0.25), value: isLandscapeLayout)
        .animation(.easeOut(duration: 0.15), value: fan != nil)
        .animation(.easeOut(duration: 0.2), value: nameFlash?.id)
        .animation(.spring(response: 0.34, dampingFraction: 0.85),
                   value: camera.lastRecordingURL != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: showRollDone)
        // Every look over the lower picture, which stays live, undimmed and
        // swipeable above the sheet.
        .lumaToolSheet(isPresented: looksSheetBinding, style: Self.looksSheetStyle) {
            CameraLooksSheet(frame: rawFrame, frameID: rawFrameID,
                             onClose: { showLookBrowser = false })
        }
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
                if panel == .format { panel = .none }
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

    /// The sheet is the upright way in; sideways, the looks open as a panel
    /// on the picture instead.
    private var looksSheetBinding: Binding<Bool> {
        Binding(get: { showLookBrowser && !isLandscapeLayout },
                set: { showLookBrowser = $0 })
    }

    private func start() {
        // A restored scene must never open ON a panel.
        panel = .none
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
            panel = .pro
            dialTarget = DialTarget.allCases.first { $0.title.lowercased() == pro.lowercased() } ?? .shutter
        }
        // Another mode, a roll loaded, or the focus brackets lit, e.g.
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
            focusSeed = CGPoint(x: 0.56, y: 0.3)
            focusActive = true
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
                                                 size: CGSize(width: 200, height: 92))
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

    // MARK: - Controls over the picture

    private var controls: some View {
        VStack(spacing: 0) {
            if !isLandscapeLayout {
                topBar
                    .transition(.opacity)
            }
            // Without a live picture, the permission or status message sits
            // in the clear space, so nothing can cover Open Settings.
            if showsLivePicture {
                Spacer(minLength: 0)
            } else {
                fallbackMessage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !isLandscapeLayout {
                deckExtras
            }
            VStack(spacing: 0) {
                if !isLandscapeLayout {
                    deckMain
                }
                captureRow
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) { bottomBackground }
        }
    }

    /// An ink gradient under the dial (the picture reads through it), or the
    /// panel's own dark glass while Pro is up.
    @ViewBuilder
    private var bottomBackground: some View {
        if panel != .none && !isLandscapeLayout {
            ZStack {
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .fill(LumaTheme.ink.opacity(0.8))
            }
            .ignoresSafeArea(edges: .bottom)
            .transition(.opacity)
        } else {
            LinearGradient(stops: [
                .init(color: LumaTheme.ink.opacity(0), location: 0),
                .init(color: LumaTheme.ink.opacity(0.5), location: 0.45),
                .init(color: LumaTheme.ink.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .padding(.top, -60)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    zoomPill
                }
            }
            HStack(alignment: .top, spacing: 8) {
                lookTag(ring: 42)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    histogramControl
                    proPill
                }
                .padding(.top, 6)
            }
            if camera.isRecording || camera.aeafLocked {
                statusRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.18), value: camera.isRecording)
        .animation(.easeOut(duration: 0.18), value: camera.aeafLocked)
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
        .disabled(recordingBusy)
        .accessibilityHint(recordingBusy
                           ? "Stop recording to change the capture format"
                           : "Change resolution, frame rate, and codec")
    }

    /// Photo modes: the still format and size, and the roll when one is
    /// loaded. Either opens the photo format page.
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

    /// What the lens is doing never leaves the top line. Tap puts the lens
    /// on the dial.
    private var zoomPill: some View {
        Button {
            dialTarget = .lens
            if panel != .none { panel = .none }
            LumaHaptics.shared.tap()
        } label: {
            Text(String(format: "%.1f×", camera.zoomFactor))
                .font(.luma(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lumaGlassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(String(format: "Zoom %.1f times", camera.zoomFactor))
        .accessibilityHint("Puts the lens on the dial")
    }

    /// Photo modes show the focus mode where video shows zoom: AF, MF, or
    /// AF L while AE/AF is locked. Tap puts focus on the dial.
    private var focusModePill: some View {
        Button {
            dialTarget = .focus
            if panel != .none { panel = .none }
            LumaHaptics.shared.tap()
        } label: {
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

    /// Pro: pulls up every pro control. A dot while anything is set by hand.
    private var proPill: some View {
        Button { openPro() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                Text("Pro")
                    .font(.luma(size: 13, weight: .semibold))
                if anyManual {
                    Circle().fill(LumaTheme.signal).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(.white)
            .lumaGlassPill()
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Pro controls")
    }

    /// The mic meter while rolling, and the AE/AF lock (tap to undo it).
    private var statusRow: some View {
        HStack(spacing: 8) {
            if camera.isRecording {
                InputMeterView(level: camera.audioLevel)
                    .grayscale(1)
            }
            if camera.aeafLocked {
                aeafBadge
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    private var aeafBadge: some View {
        Button {
            camera.unlockAEAF()
            flash("AE/AF unlocked")
            LumaHaptics.shared.tap()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("AE/AF locked")
                    .font(.luma(size: 12, weight: .semibold))
            }
            .foregroundStyle(LumaTheme.onSignal)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(LumaTheme.signal, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityHint("Unlocks focus and exposure")
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

    // MARK: The look tag

    /// The look on the picture: its ring (filled to the strength), its name,
    /// code and strength, and a dot for each favourite in the swipe. Tap for
    /// every look.
    private func lookTag(ring: CGFloat) -> some View {
        let worn = app.cameraWornLook
        let strength = app.settings.intensity
        let locked = app.lockedLookInGrade(storeService) != nil
        return Button { openLooks() } label: {
            HStack(spacing: 10) {
                CameraLookRing(code: worn.code,
                               colour: strength == 0 ? LumaTheme.textMuted : worn.signature,
                               strength: strength / 100, size: ring)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(worn.title)
                            .font(.luma(size: ring > 40 ? 14.5 : 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    Text(lookSubtitle(worn, locked: locked))
                        .font(.luma(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    favouriteDots(worn)
                        .padding(.top, 5)
                }
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Looks: \(app.cameraLookName)")
        .accessibilityHint("Opens every look. Swipe the picture for your favourites")
    }

    private func lookSubtitle(_ look: CameraLook, locked: Bool) -> String {
        let strength = Int(app.settings.intensity.rounded())
        let amount = strength == 0 ? "Off" : "\(strength)%"
        return locked ? "\(look.code) · \(amount) · free to try" : "\(look.code) · \(amount)"
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
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
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

    private var cameraFavourites: [CameraLook] {
        app.cameraFavourites(raw: favouritesRaw)
    }

    // MARK: - The deck over the shutter

    /// Captions and the scope, just above the chips.
    private var deckExtras: some View {
        VStack(spacing: 10) {
            if let statusCaption {
                toast(statusCaption)
            }
            if scopeMode != nil {
                scopeStrip
            }
        }
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.18), value: statusCaption)
        .animation(.easeOut(duration: 0.18), value: scopeMode)
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .lumaGlassPill()
            .id(text)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var deckMain: some View {
        switch panel {
        case .none:
            dialDeck
                .transition(.opacity)
        case .pro:
            proPanel
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .format:
            formatPage
                .transition(.opacity)
        }
    }

    // MARK: Chips and the dial

    private var lensTarget: DialTarget { captureMode == .portrait ? .aperture : .lens }
    private var chipTargets: [DialTarget] { [.look, lensTarget, .shutter, .iso, .ev, .wb, .focus] }
    private var proTargets: [DialTarget] { [lensTarget, .shutter, .iso, .wb, .ev, .focus] }

    private var dialDeck: some View {
        VStack(spacing: 4) {
            chipsRow
            ZStack(alignment: .bottom) {
                // The arc's centre is the shutter's: 43 pt below this strip
                // (the gap above the dock, then half the dock).
                CameraArcDial(ticks: dialTicks(for: dialTarget),
                              index: dialPosition(for: dialTarget),
                              centreBelow: 43, radius: 140,
                              onChange: { applyDial($0, to: dialTarget) },
                              onPullUp: { openPro() })
                    .id(dialTarget)
                dialReadout
                    .padding(.bottom, 8)
            }
            .frame(height: 128)
        }
    }

    private var chipsRow: some View {
        HStack(spacing: 4) {
            ForEach(chipTargets, id: \.self) { target in
                CameraDialChip(title: target.title, active: dialTarget == target,
                               manual: isManual(target)) {
                    dialTarget = target
                    LumaHaptics.shared.tap()
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// The dial's value, large, under the needle; Auto beside it when the
    /// value is set by hand.
    private var dialReadout: some View {
        VStack(spacing: 0) {
            Text(dialValue(for: dialTarget))
                .font(.luma(size: 30, weight: .semibold))
                .kerning(-0.8)
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(isAutoTarget(dialTarget) ? "\(dialTarget.longName) · auto" : dialTarget.longName)
                .font(.luma(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        .allowsHitTesting(false)
        .overlay(alignment: .trailing) {
            if isManual(dialTarget) {
                autoButton(for: dialTarget)
                    .fixedSize()
                    .offset(x: 62)
            }
        }
        .animation(.snappy(duration: 0.14), value: dialValue(for: dialTarget))
    }

    private func autoButton(for target: DialTarget) -> some View {
        Button { setAuto(target) } label: {
            Text("Auto")
                .font(.luma(size: 12, weight: .bold))
                .foregroundStyle(LumaTheme.onSignal)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(LumaTheme.signal, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(target.longName) back to auto")
    }

    // MARK: Pro panel
    //
    // The capture row never leaves, so a take can be started and stopped with
    // Pro up.

    private var proPanel: some View {
        VStack(spacing: 12) {
            panelHeader("Pro", showsAuto: isManual(dialTarget))
            HStack(spacing: 0) {
                ForEach(proTargets, id: \.self) { target in
                    CameraProReadout(title: target.title,
                                     value: dialValue(for: target),
                                     auto: isAutoTarget(target),
                                     active: dialTarget == target) {
                        dialTarget = target
                        LumaHaptics.shared.tap()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            // One ruler, re-targeted by the readouts above it.
            CameraRulerDial(ticks: dialTicks(for: dialTarget),
                            index: dialPosition(for: dialTarget)) { newIndex in
                applyDial(newIndex, to: dialTarget)
            }
            .id(dialTarget)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                      spacing: 8) {
                proTiles
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var proTiles: some View {
        CameraToolTile(symbol: "rectangle.on.rectangle", label: "Format", enabled: !recordingBusy) {
            panel = .format
            LumaHaptics.shared.tap()
        }
        CameraToolTile(symbol: "rectangle.dashed",
                       label: frameGuide == .off ? "Guides" : frameGuide.label,
                       on: frameGuide != .off) { cycleGuide() }
            // Long-press toggles the social safe zone inside the guide.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                toggleSafeZone()
            })
        CameraToolTile(symbol: "waveform.path.ecg.rectangle", label: "Scope",
                       on: scopeMode != nil) { cycleScope() }
        CameraToolTile(symbol: "light.beacon.max", label: "Zebras",
                       on: camera.zebrasOn) { toggleZebras() }
        CameraToolTile(symbol: "camera.metering.spot", label: "Peaking",
                       on: camera.peakingOn) { togglePeaking() }
        CameraToolTile(symbol: "grid", label: "Grid", on: showGrid) { toggleGrid() }
        CameraToolTile(symbol: "level", label: "Level", on: showLevel) { toggleLevel() }
        CameraToolTile(symbol: camera.aeafLocked ? "lock.fill" : "lock.open", label: "AE/AF lock",
                       on: camera.aeafLocked) { toggleAEAF() }
        CameraToolTile(symbol: "chart.bar.fill", label: "Histogram", on: showHistogram) {
            showHistogram.toggle()
            flash(showHistogram ? "Histogram on" : "Histogram off")
        }
        CameraToolTile(symbol: "a.circle", label: "Auto all") { autoAll() }
    }

    /// The grab bar and title; drag it down (or tap the chevron) to close.
    private func panelHeader(_ title: String, showsAuto: Bool,
                             back: (() -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 36, height: 5)
            HStack(spacing: 8) {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.lumaPress)
                    .accessibilityLabel("Back to Pro")
                }
                Text(title)
                    .font(.luma(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if showsAuto {
                    autoButton(for: dialTarget)
                }
                Button { closePanel() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Close")
            }
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height > 40 { closePanel() }
                }
        )
    }

    private var formatPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader("Format", showsAuto: false, back: { panel = .pro })
            formatPanel
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    // MARK: Scope

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
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
                Button {
                    scopeMode = scopeMode?.next
                    LumaHaptics.shared.tap()
                } label: {
                    Text("Next scope")
                        .font(.luma(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
            .shadow(color: .black.opacity(0.5), radius: 4)
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

    // MARK: - Viewfinder
    //
    // Letterboxed to the 9:16 capture aspect: what you frame is what is
    // written. Only overlays that must register with the picture (grid,
    // level, guides, brackets) are drawn on it, plus the swipe's wipe.

    private var showsLivePicture: Bool { camera.isRunning && !camera.cameraUnavailable }

    private var viewfinder: some View {
        pictureStack
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            // A hairline is the one stroke allowed over live video: it is
            // what separates an unpredictable frame from the matte around it.
            .overlay(Rectangle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .contentShape(Rectangle())
            // Pinch zooms; a finger swipes looks or holds for the fan. Both
            // simultaneous, so tap-to-focus keeps working.
            .simultaneousGesture(pinchGesture)
            .simultaneousGesture(touchGesture)
            .overlay {
                if isLandscapeLayout {
                    landscapeChrome
                        .transition(.opacity)
                }
            }
    }

    private var pictureStack: some View {
        ZStack {
            Group {
                if showsLivePicture {
                    FilteredCameraPreview(camera: camera, onTapUnit: { unit, viewPoint in
                        tapPicture(unit: unit, at: viewPoint)
                    })
                } else {
                    ZStack {
                        HeroImage(photo: .golden)
                        Color.black.opacity(0.45)
                    }
                }
            }
            .overlay { if showGrid { RuleOfThirdsGrid().transition(.opacity) } }
            // Desaturated: the level snap still reads, it just no longer
            // turns green over footage the user is judging colour on.
            .overlay { if showLevel { LevelIndicator().grayscale(1).transition(.opacity) } }
            .overlay {
                if frameGuide != .off {
                    FrameGuidesOverlay(guide: frameGuide, showSafeZone: showSafeZone)
                        .transition(.opacity)
                }
            }
            .overlay { focusBracketsLayer }
            .overlay { swipeRevealLayer }
            .overlay {
                if shutterFlash {
                    Color.white.opacity(0.8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                if !isLandscapeLayout {
                    ZStack {
                        swipeEdgeLayer
                        bigNameLayer
                    }
                }
            }
        }
    }

    private func tapPicture(unit: CGPoint, at viewPoint: CGPoint) {
        guard fan == nil else { return }
        // A tap on the picture puts away whatever is open over it first.
        if panel != .none {
            closePanel()
            return
        }
        if isLandscapeLayout, landscapeDropOpen || showLookBrowser {
            landscapeDropOpen = false
            showLookBrowser = false
            return
        }
        if camera.aeafLocked { camera.unlockAEAF() }
        camera.focusExpose(at: unit)
        placeFocusBrackets(at: viewPoint)
        LumaHaptics.shared.tap()
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
    // Four signal-yellow corners. At rest they sit faint in the clear middle
    // of the picture; a tap snaps them to that point, they animate in lit,
    // then settle dimmer where focus and exposure are now held.

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
                } else if !isLandscapeLayout {
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
    /// look tag and the chips.
    private func restBracketRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 26
        let top = size.height * 0.24
        let height = size.height * 0.34
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

    // MARK: - Swipe through favourites

    /// The next look, graded over a still of this frame, wiped in from the
    /// side the finger is pulling from.
    @ViewBuilder
    private var swipeRevealLayer: some View {
        if let swipe, let swipeReveal, !isLandscapeLayout {
            GeometryReader { geo in
                let edge = swipe.edge(in: geo.size.width)
                // Fitted, as the viewfinder fits its frames, so the still
                // lines up with the live picture under it.
                Image(decorative: swipeReveal, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: swipe.direction == 1 ? geo.size.width - edge : edge)
                            .offset(x: swipe.direction == 1 ? edge : 0)
                    }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var swipeEdgeLayer: some View {
        if let swipe {
            GeometryReader { geo in
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2)
                    .shadow(color: .white.opacity(0.6), radius: 7)
                    .position(x: swipe.edge(in: geo.size.width), y: geo.size.height / 2)
            }
            .allowsHitTesting(false)
        }
    }

    /// The look's name, large, while it is swiped in and for a moment after.
    @ViewBuilder
    private var bigNameLayer: some View {
        if let look = swipe?.next ?? nameFlash {
            let strength = Int(app.settings.intensity.rounded())
            VStack(spacing: 4) {
                Text(look.title)
                    .font(.luma(size: 32, weight: .bold))
                    .kerning(-0.9)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(look.code) · \(strength == 0 ? "Off" : "\(strength)%")")
                    .font(.luma(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.78))
            }
            .shadow(color: .black.opacity(0.45), radius: 12, y: 2)
            .padding(.horizontal, 24)
            .offset(y: -30)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private var canSwipe: Bool {
        guard !recordingBusy, showsLivePicture else { return false }
        if panel != .none && !isLandscapeLayout { return false }
        return !cameraFavourites.isEmpty
    }

    private var canFan: Bool {
        !isLandscapeLayout && panel == .none && showsLivePicture
    }

    /// How far a full swipe travels: the picture's width as it is held.
    private var swipeWidth: CGFloat {
        let width = screenSize.width > 0 ? screenSize.width : 393
        return isLandscapeLayout ? width * 16 / 9 : width
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

    private func touchChanged(_ value: DragGesture.Value) {
        if isPinching {
            cancelTouch()
            return
        }
        if touch == nil {
            touchToken += 1
            let token = touchToken
            touch = TouchState(mode: .pending, last: value.location, token: token)
            if canFan {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    openFanIfHeld(token: token)
                }
            }
        }
        guard var state = touch else { return }
        state.last = value.location
        let travel = userTravel(value.translation)
        if state.mode == .pending,
           hypot(value.translation.width, value.translation.height) > 12 {
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

    /// The finger's travel as the person holding the phone sees it.
    private func userTravel(_ t: CGSize) -> CGSize {
        guard isLandscapeLayout else { return t }
        return landscapeTurn < 0
            ? CGSize(width: -t.height, height: t.width)
            : CGSize(width: t.height, height: -t.width)
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
        showName(look)
        if let installed { flash("\(installed) is in your library now") }
        LumaHaptics.shared.tap()
    }

    private func showName(_ look: CameraLook) {
        nameFlashID += 1
        let id = nameFlashID
        nameFlash = look
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
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

    // MARK: - The thumb fan

    private var fanItems: [CameraFanItem] {
        [
            CameraFanItem(id: "pro", symbol: "slider.horizontal.3", label: "Pro", on: panel == .pro),
            CameraFanItem(id: "aeaf", symbol: camera.aeafLocked ? "lock.fill" : "lock.open",
                          label: camera.aeafLocked ? "Unlock AE/AF" : "Lock AE/AF", on: camera.aeafLocked),
            CameraFanItem(id: "guides", symbol: "rectangle.dashed",
                          label: frameGuide == .off ? "Guides" : frameGuide.label, on: frameGuide != .off),
            CameraFanItem(id: "scope", symbol: "waveform.path.ecg.rectangle", label: "Scope",
                          on: scopeMode != nil),
            CameraFanItem(id: "zebras", symbol: "light.beacon.max", label: "Zebras", on: camera.zebrasOn),
            CameraFanItem(id: "peaking", symbol: "camera.metering.spot", label: "Peaking",
                          on: camera.peakingOn),
            CameraFanItem(id: "grid", symbol: "grid", label: "Grid", on: showGrid),
            CameraFanItem(id: "level", symbol: "level", label: "Level", on: showLevel),
        ]
    }

    private func openFanIfHeld(token: Int) {
        guard let state = touch, state.token == token, state.mode == .pending, canFan else { return }
        let centre = CameraToolFan.centre(for: state.last, in: screenSize)
        fan = FanState(touch: state.last, centre: centre,
                       positions: CameraToolFan.layout(centre: centre, count: fanItems.count),
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
        let hot = fan?.hot
        fan = nil
        guard let hot, fanItems.indices.contains(hot) else { return }
        useTool(fanItems[hot].id)
    }

    private func useTool(_ id: String) {
        switch id {
        case "pro": openPro()
        case "aeaf": toggleAEAF()
        case "guides": cycleGuide()
        case "scope": cycleScope()
        case "zebras": toggleZebras()
        case "peaking": togglePeaking()
        case "grid": toggleGrid()
        case "level": toggleLevel()
        default: break
        }
    }

    #if DEBUG
    private func seedFan() {
        let size = screenSize == .zero ? CGSize(width: 393, height: 760) : screenSize
        let centre = CameraToolFan.centre(for: CGPoint(x: size.width * 0.5, y: size.height * 0.56),
                                          in: size)
        let positions = CameraToolFan.layout(centre: centre, count: fanItems.count)
        fan = FanState(touch: positions[2], centre: centre, positions: positions, hot: 2)
    }

    private func seedSwipe() {
        guard let next = nextFavourite(1) else { return }
        swipeToken += 1
        swipe = SwipeState(direction: 1, next: next, travel: -swipeWidth * 0.42, token: swipeToken)
        if !isLandscapeLayout { prepareReveal(of: next, token: swipeToken) }
    }
    #endif

    // MARK: - Sideways
    //
    // The interface stays fixed to the phone; when it is held sideways the
    // controls on the picture turn to read upright, laid out for the long
    // edge. The shutter, modes, last shot and flip stay where the thumb is
    // and only their labels turn.

    private var isLandscapeLayout: Bool { forcedLandscape || camera.isLandscape }
    private var landscapeClockwise: Bool {
        forcedLandscape ? forcedClockwise : camera.landscapeClockwise
    }
    /// How far the sideways controls turn to read upright.
    private var landscapeTurn: Double { landscapeClockwise ? -90 : 90 }
    /// The turn for anything that stays put in the bottom matte.
    private var controlTurn: Double { isLandscapeLayout ? landscapeTurn : 0 }

    /// The sideways chrome, laid out upright for the long edge, then turned
    /// onto the picture.
    private var landscapeChrome: some View {
        GeometryReader { geo in
            let size = CGSize(width: geo.size.height, height: geo.size.width)
            landscapeContent(size: size)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(landscapeTurn))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private func landscapeContent(size: CGSize) -> some View {
        // Turned anticlockwise (+90) the island sits on the left; the
        // shutter is always on the far side from it.
        let islandLeading = landscapeTurn > 0
        return ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
            }
            .allowsHitTesting(false)

            if let swipe {
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: size.height)
                    .shadow(color: .white.opacity(0.6), radius: 7)
                    .position(x: swipe.edge(in: size.width), y: size.height / 2)
                    .allowsHitTesting(false)
            }
            bigNameLayer

            VStack(alignment: .leading, spacing: 8) {
                landscapeTopStrip
                if landscapeDropOpen {
                    landscapeDrop
                        .transition(.opacity)
                }
                if scopeMode != nil {
                    scopeStrip
                }
                if camera.isRecording || camera.aeafLocked {
                    statusRow
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 12) {
                    lookTag(ring: 40)
                    Spacer(minLength: 0)
                    landscapeTools
                }
            }
            .padding(.leading, islandLeading ? 52 : 16)
            .padding(.trailing, islandLeading ? 16 : 52)
            .padding(.vertical, 12)

            if let statusCaption {
                toast(statusCaption)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 120)
            }
            if panel == .format {
                landscapeFormatCard
            }
            if showLookBrowser {
                landscapeLooksPanel(islandLeading: islandLeading)
            }
        }
        .animation(.easeOut(duration: 0.18), value: landscapeDropOpen)
        .animation(.easeOut(duration: 0.18), value: statusCaption)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showLookBrowser)
    }

    private var landscapeTopStrip: some View {
        HStack(spacing: 8) {
            closeButton
            if camera.isRecording {
                recordTimer
            } else if captureMode.takesStills {
                photoPills
            } else {
                videoFormatButton
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(proTargets, id: \.self) { target in
                    landscapeReadout(target)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(Color(hex: 0x0C0C0E).opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            histogramControl
        }
    }

    /// A value along the top. Tap it and its ruler drops down beneath.
    private func landscapeReadout(_ target: DialTarget) -> some View {
        let active = landscapeDropOpen && dialTarget == target
        return Button {
            if active {
                landscapeDropOpen = false
            } else {
                dialTarget = target
                landscapeDropOpen = true
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 1) {
                Text(dialValue(for: target))
                    .font(.luma(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(active ? LumaTheme.signal
                                     : .white.opacity(isAutoTarget(target) ? 0.62 : 0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 2) {
                    Text(target.title)
                    if isManual(target) {
                        Circle().fill(LumaTheme.signal).frame(width: 4, height: 4)
                    }
                }
                .font(.luma(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            }
            .frame(width: 54, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(target.longName) \(dialValue(for: target))")
    }

    private var landscapeDrop: some View {
        HStack(spacing: 10) {
            CameraRulerDial(ticks: dialTicks(for: dialTarget),
                            index: dialPosition(for: dialTarget)) { newIndex in
                applyDial(newIndex, to: dialTarget)
            }
            .id(dialTarget)
            .frame(width: 320)
            if isManual(dialTarget) {
                autoButton(for: dialTarget)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Color(hex: 0x0C0C0E).opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var landscapeTools: some View {
        HStack(spacing: 2) {
            landscapeTool("rectangle.dashed", "Guides", on: frameGuide != .off) { cycleGuide() }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    toggleSafeZone()
                })
            landscapeTool("light.beacon.max", "Zebras", on: camera.zebrasOn) { toggleZebras() }
            landscapeTool("camera.metering.spot", "Peaking", on: camera.peakingOn) { togglePeaking() }
            landscapeTool("grid", "Grid", on: showGrid) { toggleGrid() }
            landscapeTool("level", "Level", on: showLevel) { toggleLevel() }
            landscapeTool("waveform.path.ecg.rectangle", "Scope", on: scopeMode != nil) { cycleScope() }
            landscapeTool(camera.aeafLocked ? "lock.fill" : "lock.open", "AE/AF lock",
                          on: camera.aeafLocked) { toggleAEAF() }
            landscapeTool("rectangle.on.rectangle", "Format", on: panel == .format) {
                panel = panel == .format ? .none : .format
            }
            .disabled(recordingBusy)
            .opacity(recordingBusy ? 0.35 : 1)
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color(hex: 0x0C0C0E).opacity(0.45), in: Capsule())
    }

    private func landscapeTool(_ symbol: String, _ label: String, on: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
            LumaHaptics.shared.tap()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? LumaTheme.onSignal : Color.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(on ? LumaTheme.signal : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var landscapeFormatCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Format")
                    .font(.luma(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button { panel = .none } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Close")
            }
            formatPanel
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(LumaTheme.bar.opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LumaTheme.edge, lineWidth: 0.5))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    /// Every look, as a panel down the shutter side of the picture.
    private func landscapeLooksPanel(islandLeading: Bool) -> some View {
        CameraLooksSheet(frame: rawFrame, frameID: rawFrameID,
                         onClose: { showLookBrowser = false })
            .frame(width: 392)
            .frame(maxHeight: .infinity)
            .background(LumaTheme.bar, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.vertical, 8)
            .padding(islandLeading ? .trailing : .leading, 8)
            .frame(maxWidth: .infinity, alignment: islandLeading ? .trailing : .leading)
            .transition(.move(edge: islandLeading ? .trailing : .leading).combined(with: .opacity))
    }

    // MARK: - Modes

    private static let strengthStops: [Double] = stride(from: 0.0, through: 100.0, by: 10.0).map { $0 }
    private static let lensStops: [CGFloat] = [0.5, 1, 1.5, 2, 3, 5]
    /// Portrait's f-numbers: f/1.4 blurs the most, f/16 barely at all.
    private static let apertureStops: [Double] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16]
    /// A roll of film.
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

    private var recordingBusy: Bool { camera.isRecording || camera.isPreparingRecording }

    /// Photo, Video, Slo-mo, Portrait as icons in the dock's right pill;
    /// the one in use sits in a white circle. Locked while a take is rolling.
    private var modePill: some View {
        HStack(spacing: 0) {
            ForEach(visibleModes, id: \.self) { mode in
                let on = captureMode == mode
                Button {
                    captureMode = mode
                    LumaHaptics.shared.tap()
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? LumaTheme.ink : Color.white.opacity(0.62))
                        .frame(width: 32, height: 32)
                        .background(on ? Color.white : Color.clear, in: Circle())
                        .rotationEffect(.degrees(controlTurn))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel(mode.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .disabled(recordingBusy)
        .opacity(recordingBusy ? 0.45 : 1)
        .animation(.snappy(duration: 0.18), value: captureMode)
    }

    // MARK: Format — resolution / fps / codec; the photo modes swap it for
    // the still format, size and roll.

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
            if recordingBusy {
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
        .disabled(recordingBusy)
        .opacity(recordingBusy ? 0.45 : 1)
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
                    // Format codes are values, so they keep the mono voice;
                    // selection is the ring, everything else is a bare word.
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

    /// The dock: the last shot and flip in a grey pill on the left, the
    /// shutter in the notch between, the modes in a grey pill on the right.
    /// Sideways, each icon turns in place.
    private var captureRow: some View {
        HStack(spacing: -Self.dockOverlap) {
            HStack(spacing: 8) {
                // The last shot replaces the gallery glyph once there is one.
                CameraLastShotButton(image: lastShot?.thumbnail) { openLastShot() }
                    .rotationEffect(.degrees(controlTurn))
                    .animation(.easeOut(duration: 0.25), value: lastShot?.id)
                Spacer(minLength: 0)
                flipButton
            }
            .padding(.leading, 6)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity)
            .frame(height: Self.dockHeight)
            .background { dockPill(notchLeading: false) }

            CameraShutterButton(isRecording: camera.isRecording,
                                photoMode: captureMode.takesStills,
                                rollCount: captureMode.takesStills && rollOn ? rollLeft : nil) {
                shutterPressed()
            }
            .rotationEffect(.degrees(controlTurn))
            .zIndex(1)

            modePill
                .padding(.leading, 18)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity)
                .frame(height: Self.dockHeight)
                .background { dockPill(notchLeading: true) }
        }
        .padding(.horizontal, 12)
        // The tab bar's yellow shutter is placed to land on this button's
        // centre (see LumaTabBar), so keep the row 70 tall with 6 under it.
        .frame(height: 70)
        .padding(.bottom, 6)
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.isRecording)
        .sensoryFeedback(.success, trigger: stillSavedFlash)
    }

    private static let dockHeight: CGFloat = 58
    /// How far each pill runs under the shutter's frame, so its notch hugs
    /// the ring with a 6 pt gap (see `CameraDockPill`).
    private static let dockOverlap: CGFloat = 6

    private func dockPill(notchLeading: Bool) -> some View {
        ZStack {
            CameraDockPill(notchLeading: notchLeading).fill(.ultraThinMaterial)
            CameraDockPill(notchLeading: notchLeading).fill(LumaTheme.raised.opacity(0.88))
        }
    }

    private var flipButton: some View {
        Button {
            camera.flipCamera()
            resetFocusBrackets()
            LumaHaptics.shared.tap()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LumaTheme.textPrimary)
                .frame(width: 42, height: 42)
                .background(LumaTheme.control, in: Circle())
                .rotationEffect(.degrees(controlTurn))
                .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.35 : 1)
        .accessibilityLabel("Flip camera")
    }

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

    // MARK: - Actions

    private func openPro() {
        guard !isLandscapeLayout else { return }
        // The look's strength has no readout in Pro; it stays on the dial.
        if dialTarget == .look { dialTarget = lensTarget }
        panel = .pro
        LumaHaptics.shared.tap()
    }

    private func closePanel() {
        panel = .none
    }

    private func openLooks() {
        landscapeDropOpen = false
        if isLandscapeLayout {
            if panel == .format { panel = .none }
            showLookBrowser.toggle()
        } else {
            if panel != .none { panel = .none }
            showLookBrowser = true
        }
        LumaHaptics.shared.tap()
    }

    /// All five scopes, then off.
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

    private func cycleGuide() {
        let all = FrameGuide.allCases
        let idx = ((all.firstIndex(of: frameGuide) ?? 0) + 1) % all.count
        frameGuide = all[idx]
        flash(frameGuide == .off ? "Guides off" : "Guide \(frameGuide.label)")
        LumaHaptics.shared.tap()
    }

    private func toggleSafeZone() {
        showSafeZone.toggle()
        flash(showSafeZone ? "Safe zone on" : "Safe zone off")
    }

    private func toggleZebras() {
        camera.zebrasOn.toggle()
        flash(camera.zebrasOn ? "Zebras on" : "Zebras off")
    }

    private func togglePeaking() {
        camera.peakingOn.toggle()
        flash(camera.peakingOn ? "Peaking on" : "Peaking off")
    }

    private func toggleGrid() {
        showGrid.toggle()
        flash(showGrid ? "Grid on" : "Grid off")
    }

    private func toggleLevel() {
        showLevel.toggle()
        flash(showLevel ? "Level on" : "Level off")
    }

    private func toggleAEAF() {
        // The lock lands on the session queue, so read the intent first.
        let locking = !camera.aeafLocked
        camera.toggleAEAFLock()
        flash(locking ? "AE/AF locked" : "AE/AF unlocked")
        LumaHaptics.shared.tap()
    }

    /// The escape hatch: everything back to automatic in one tap, including the
    /// AE/AF lock, so no invisible manual state can survive it.
    private func autoAll() {
        camera.resetAutoExposure()
        camera.resetAutoWB()
        camera.resetAutoFocus()
        camera.setEVBias(0)
        camera.unlockAEAF()
        resetFocusBrackets()
        flash("Everything back to auto")
        LumaHaptics.shared.tap()
    }

    private var anyManual: Bool {
        camera.manualExposure || camera.manualWB || camera.manualFocus
            || camera.evBias != 0 || camera.aeafLocked
    }

    /// A short caption over the picture.
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
    /// adds the depth blur at the dial's aperture. Sim falls back to the
    /// preview buffer. With a roll loaded, every press spends a frame.
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
                // Compare against the SAME literal we set, so the caption
                // always clears.
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
            dialTarget = .aperture
            flash("Background blur goes on as you shoot")
        case .photo, .video:
            flash(new.rawValue)
        }
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
            return
        }
    }

    // MARK: - What the dial turns

    private func dialTicks(for target: DialTarget) -> [String] {
        switch target {
        case .look:     return Self.strengthStops.map { "\(Int($0))" }
        case .lens:     return Self.lensStops.map { "\(Self.millimetres($0))" }
        case .aperture: return Self.apertureStops.indices.map { Self.fNumber($0) }
        case .shutter:  return paramTicks(for: .shutter)
        case .iso:      return paramTicks(for: .iso)
        case .ev:       return paramTicks(for: .ev)
        case .wb:       return paramTicks(for: .wb)
        case .focus:    return paramTicks(for: .focus)
        }
    }

    private func dialPosition(for target: DialTarget) -> Int {
        switch target {
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
        case .aperture: return apertureIndex
        case .shutter:  return paramIndex(for: .shutter)
        case .iso:      return paramIndex(for: .iso)
        case .ev:       return paramIndex(for: .ev)
        case .wb:       return paramIndex(for: .wb)
        case .focus:    return paramIndex(for: .focus)
        }
    }

    private func applyDial(_ index: Int, to target: DialTarget) {
        switch target {
        case .look:
            guard Self.strengthStops.indices.contains(index) else { return }
            app.settings.intensity = Self.strengthStops[index]
        case .lens:
            guard Self.lensStops.indices.contains(index) else { return }
            camera.setDisplayZoom(Self.lensStops[index])
        case .aperture:
            guard Self.apertureStops.indices.contains(index) else { return }
            apertureIndex = index
        case .shutter: applyParam(index, to: .shutter)
        case .iso:     applyParam(index, to: .iso)
        case .ev:      applyParam(index, to: .ev)
        case .wb:      applyParam(index, to: .wb)
        case .focus:   applyParam(index, to: .focus)
        }
    }

    private func dialValue(for target: DialTarget) -> String {
        switch target {
        case .look:
            let strength = Int(app.settings.intensity.rounded())
            return strength == 0 ? "Off" : "\(strength)%"
        case .lens:     return "\(Self.millimetres(camera.zoomFactor)) mm"
        case .aperture: return Self.fNumber(apertureIndex)
        case .shutter:  return paramReadout(for: .shutter)
        case .iso:      return paramReadout(for: .iso)
        case .ev:       return paramReadout(for: .ev)
        case .wb:       return paramReadout(for: .wb)
        case .focus:    return paramReadout(for: .focus)
        }
    }

    /// The camera, not the person, is choosing this value.
    private func isAutoTarget(_ target: DialTarget) -> Bool {
        switch target {
        case .shutter: return paramIsAuto(.shutter)
        case .iso:     return paramIsAuto(.iso)
        case .wb:      return paramIsAuto(.wb)
        case .focus:   return !camera.manualFocus
        case .look, .lens, .aperture, .ev: return false
        }
    }

    /// Set by hand, so Auto has something to undo.
    private func isManual(_ target: DialTarget) -> Bool {
        switch target {
        case .shutter, .iso: return camera.manualExposure
        case .wb:            return camera.manualWB
        case .focus:         return camera.manualFocus
        case .ev:            return camera.evBias != 0
        case .look, .lens, .aperture: return false
        }
    }

    private func setAuto(_ target: DialTarget) {
        switch target {
        case .shutter, .iso: camera.resetAutoExposure()
        case .wb:            camera.resetAutoWB()
        case .focus:         camera.resetAutoFocus()
        case .ev:            camera.setEVBias(0)
        case .look, .lens, .aperture: return
        }
        flash("\(target.longName) back to auto")
        LumaHaptics.shared.tap()
    }

    // MARK: Dial stops (cine practice: discrete, repeatable between takes)

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

    private func paramIsAuto(_ parameter: ProParameter) -> Bool {
        switch parameter {
        case .iso, .shutter: return !camera.manualExposure
        case .wb:            return !camera.manualWB
        case .ev, .focus:    return false
        }
    }

    private func paramReadout(for parameter: ProParameter) -> String {
        switch parameter {
        case .iso:     return "\(Int(camera.currentISO > 0 ? camera.currentISO : 100))"
        case .shutter: return shutterLabel(camera.shutterAngle)
        case .wb:      return "\(Int(camera.wbTemperature))K"
        case .ev:      return String(format: "%+.1f", camera.evBias)
        case .focus:   return camera.manualFocus ? String(format: "%.1f", camera.lensPosition) : "AF"
        }
    }

    private func paramTicks(for parameter: ProParameter) -> [String] {
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
    private func paramIndex(for parameter: ProParameter) -> Int {
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
    private func applyParam(_ index: Int, to parameter: ProParameter) {
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

// MARK: - What the dial turns

/// One of the camera's dialable values: the chips, Pro's readouts and the
/// sideways readouts all pick from these.
private enum DialTarget: Hashable, CaseIterable {
    case look, lens, aperture, shutter, iso, ev, wb, focus

    /// The chip and readout name.
    var title: String {
        switch self {
        case .look:     return "Look"
        case .lens:     return "Lens"
        case .aperture: return "Aperture"
        case .shutter:  return "Shutter"
        case .iso:      return "ISO"
        case .ev:       return "EV"
        case .wb:       return "WB"
        case .focus:    return "Focus"
        }
    }

    /// The name under the dial's value.
    var longName: String {
        switch self {
        case .look: return "Look strength"
        case .ev:   return "Exposure"
        case .wb:   return "White balance"
        default:    return title
        }
    }
}

// MARK: - A finger on the picture

/// A tap, a swipe through looks, or a hold for the fan.
private struct TouchState {
    enum Mode { case pending, swipe, fan, ignored }
    var mode: Mode
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
    let centre: CGPoint
    let positions: [CGPoint]
    var hot: Int?
}

// MARK: - Monochrome camera chrome
//
// The screen's own parts. They use the same LumaTheme values and type voice
// as the rest of the app.

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

/// One of Pro's readouts. Tapping it re-targets the shared ruler; the name
/// is plain type, only the value speaks mono.
private struct CameraProReadout: View {
    let title: String
    let value: String
    /// True when the camera is choosing this value itself. The concrete value
    /// is still shown (it is what the ruler points at), dimmed and tagged.
    var auto: Bool = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.luma(size: 11, weight: .medium))
                        .foregroundStyle(active ? LumaTheme.signal : .white.opacity(0.45))
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
            .frame(minWidth: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Detented ruler. One ruler, re-targeted by the readouts above it; the
/// current stop sits under the caret at the row's own centre.
private struct CameraRulerDial: View {
    /// Tick labels, in order. Index based, so any parameter (ISO stops,
    /// shutter angles, kelvin, EV thirds) uses the same widget.
    let ticks: [String]
    let index: Int
    let onChange: (Int) -> Void

    /// Drag distance that advances one detent.
    private let stride: CGFloat = 46
    @State private var dragBase: Int?

    var body: some View {
        // No GeometryReader: the caret is the ZStack's own centre and the tick
        // rail is offset relative to that same centre.
        ZStack {
            HStack(spacing: 0) {
                ForEach(ticks.indices, id: \.self) { i in
                    let current = i == index
                    VStack(spacing: 5) {
                        Rectangle()
                            .fill(current ? LumaTheme.signal : .white.opacity(0.20))
                            .frame(width: current ? 2 : 1, height: current ? 15 : 9)
                        Text(ticks[i])
                            .font(.luma(size: current ? 12 : 10,
                                        weight: current ? .bold : .regular,
                                        design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(current ? LumaTheme.signal : .white.opacity(0.32))
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

/// One of the dock's two grey pills: round at the outer end, and at the
/// inner end a notch that hugs the shutter's ring with a 6 pt gap. The
/// notch is a circle of radius 41 round the shutter's centre, which sits
/// 29 pt past the pill's inner edge (where that circle meets the pill's top
/// and bottom edges on a 58 pt pill).
private struct CameraDockPill: Shape {
    var notchLeading: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = h / 2
        let notch: CGFloat = 41
        let reach = sqrt(max(notch * notch - r * r, 0))
        var path = Path()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        // The notch, from the top edge round to the bottom edge, through
        // the side of the circle that faces the pill.
        let centre = CGPoint(x: w + reach, y: r)
        let top = atan2(Double(-r), Double(-reach))
        let sweep = 2 * atan2(Double(r), Double(reach))
        for step in 1...24 {
            let a = top - sweep * Double(step) / 24
            path.addLine(to: CGPoint(x: centre.x + notch * CGFloat(cos(a)),
                                     y: centre.y + notch * CGFloat(sin(a))))
        }
        path.addLine(to: CGPoint(x: r, y: h))
        // The round outer end.
        for step in 1...24 {
            let a = Double.pi / 2 + Double.pi * Double(step) / 24
            path.addLine(to: CGPoint(x: r + r * CGFloat(cos(a)), y: r + r * CGFloat(sin(a))))
        }
        path.closeSubpath()
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        if notchLeading {
            transform = transform.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        }
        return path.applying(transform)
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

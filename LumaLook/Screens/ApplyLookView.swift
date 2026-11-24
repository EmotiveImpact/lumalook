import SwiftUI
import AVKit

// =============================================================================
// C1 — THE GRADE ROOM, in the approved design language.
//
// This is the SHIPPING screen. The retired Design Lab sketch (`LDGradeDemoView`,
// since deleted) was the first pass at the language (category bar, look tiles,
// instruction bar); it was the STYLE reference here and nothing more.
// Everything the shipping room could do it still does — the controls moved off
// the picture and into the drawer, and the interface went quiet so the footage
// and the looks (each in its own colour) are the coloured things on screen.
//
// FEATURE INVENTORY — "I'm not trying to lose features." Nothing is dropped.
//
//   ✓ Look strip — every tile is the REAL grade of the user's frame (LookThumbs)
//   ✓ Two-axis browsing — categories as text tabs (All looks, Favourites,
//     Mine, then Recent, Skin first, Purchased, Imported), looks scroll along
//   ✓ Auto-scroll: the applied look is centred in the strip, never parked off it
//   ✓ Source badges on tiles (Log / LUT / Saved) so a log cube is never a
//     surprise
//   ✓ "All looks" tile → the full LookBrowserSheet (search, chips, collections,
//     import) at the medium detent, canvas undimmed  [LUMA_SEED_BROWSER=1]
//   ✓ ORIGINAL tile — tap latches the grade to 0 and tapping again restores the
//     previous strength; press-and-hold peeks. It renders the real ungraded
//     frame, so it is also the corner Compare tile, moved off the picture.
//   ✓ Full-bleed picture with a straight Original / Graded wipe: a white line
//     and a glass handle, drag across the picture to move it, double tap for
//     the whole frame (GradeWipeStage.swift). Stills only; a playing video
//     fills the stage.
//   ✓ Press-and-hold anywhere on the picture to peek the original
//   ✓ Compare tool → BeforeAfterView, the deep-compare surface
//   ✓ LUT compare grid (LUTCompareView) — same grade, many LUTs, side by side
//   ✓ Pinned Apply — always enabled, never a dead end (no media ⇢ the picker)
//   ✓ Favourite — stores look + opacity; for a LUT the opacity is real stored
//     state, so starring at 62% brings it back at 62% everywhere
//   ✓ Strength (opacity) row pinned directly above Apply, 0…100 = engine range,
//     drawn as the ruler or the dial the Appearance setting picks
//   ✓ Adjust tools — Grain / Bloom / Halation / Vignette / Lens as five quiet
//     tiles, each showing its LIVE VALUE rather than a glyph, edited by one
//     shared slider (tap the tile again to put it away)
//   ✓ Lens panel — eight lens kinds, Pro-locked ones open the paywall
//   ✓ Auto-grade (off behind LumaFeatures.autoGrade until it leaves skin alone)
//   ✓ WB eyedropper (tap a neutral in the frame)
//   ✓ Skin First presets — research-tuned for Black & deep skin, now rendered
//     as real graded tiles instead of painted swatches
//   ✓ Slot chain — Slot 1 conversion × Slot 2 creative, per-slot strength by
//     horizontal drag, blend mode row for the creative LUT
//   ✓ Source-format picker — built-in log profiles + conversion LUTs, log
//     targets sorted first
//   ✓ Log-LUT warning chip + its explainer alert
//   ✓ Scopes — waveform / parade / vectorscope / histogram / false colour, off
//     the picture and into the drawer, tap to cycle, preference persisted
//   ✓ Histogram (a scope mode, plus the CIAreaHistogram renderer below)
//   ✓ Media readout — resolution · frame rate · duration, in mono
//   ✓ Batch count — "N clips queued" when a batch is loaded
//   ✓ Empty-state hint when no clip is picked (the hero photo still grades live)
//   ✓ Grade-session autosave on disappear and on Apply
//   ✓ Export-error surfacing (transient, over the drawer — never the picture)
//   ✓ Letterbox mattes for ≥1.4 video. The media box is now cut to the source
//     aspect, so the picture edge IS the rounded frame edge and the mattes
//     usually have nothing left to draw — the code path is preserved.
//   ✓ LUMA_SEED_TOOL / LUMA_SEED_BROWSER headless seeding preserved
//
// THE LANGUAGE (calm, with the colour back: mock v2, 07-grade-room)
//   1. The image is the interface. Media full bleed at the top, edge to edge,
//      rounded at the foot; every control lives in the drawer below it. Drawn
//      on the frame: back, the wipe (a white line and a glass handle), the
//      "Original" and look labels, and the transient states (the
//      hold-to-compare peek, the eyedropper's prompt).
//   2. Quiet chrome: black, glass, white and grey. The colour on this screen
//      is the footage and the looks: each look's code and name wear the look's
//      own colour (`LookNameText`, which follows the Names setting).
//   3. Signal yellow only on the slider's needle and on Apply look, the one
//      main action (`LumaMainPill`, which follows the Main buttons setting).
//   4. Stroke means selection and nothing else: the pale yellow picked ring
//      (`pickedRing`) on the applied look.
//   5. The tile IS the preview — every tile is the real grade, including the
//      Skin First presets and the ORIGINAL tile.
//   6. Text tabs for categories: the picked one white on light glass, the
//      rest grey.
//   7. Prefer a live value over a glyph. Grain, Bloom, Halation, Vignette, Lens
//      and Source all show their number on a quiet tile.
//   8. A calm bottom row: Cancel at one edge, the applied look in its colour in
//      the middle, Apply look at the other.
// =============================================================================

/// Video preview with the live look applied, falling back to the painted
/// scene when no real clip is selected.
struct LookPreviewSurface: View {
    @EnvironmentObject private var app: AppModel
    var radius: CGFloat = 18
    /// Hosts that carry their own bottom-leading readout stack must switch this
    /// off and place the hint themselves — otherwise two independent overlays
    /// claim the same anchor and composite on top of each other.
    var showsEmptyHint: Bool = true

    var body: some View {
        Group {
            if let player = app.player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let still = app.selectedImage {
                GradedStillView(source: still)
            } else {
                GradedHeroPreview()
                    .overlay(alignment: .bottomLeading) {
                        if showsEmptyHint {
                            EmptyMediaHint().padding(10)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // clipShape clips pixels, not touches.
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The "no clip picked yet" pill. Shared so the surface and the hosts that
/// place it inside their own readout stack render exactly one visual language.
struct EmptyMediaHint: View {
    var body: some View {
        Label("Sample photo. Pick a clip to grade live", systemImage: "film")
            .font(.luma(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
    }
}

/// The single source-resolution ladder for every RENDER SURFACE in the
/// grade/compare flow — stage, original tile, scope, side-by-side panes.
/// They must all describe the same photograph: a stage showing the hero while
/// the original tile shows a different picture is not a before/after.
///
/// `LookSwatch.referenceFrame` (photo + calibration patch band) is deliberately
/// NOT in this ladder: it exists so twelve look TILES read as twelve grades,
/// and it must never reach a surface the user is judging their image on.
enum GradeSourceFrame {
    /// Decoded once — `HeroPhoto.ciImage` re-reads the file on every access.
    private static let hero: CIImage? = HeroPhoto.golden.ciImage

    @MainActor static func current(_ app: AppModel) -> CIImage {
        app.previewFrame ?? app.selectedImage ?? hero ?? LookThumbs.fallbackFrame
    }
}

/// Empty-state preview: the bundled hero photograph run through the LIVE
/// grade, so the look responds in real time even before a clip is picked.
struct GradedHeroPreview: View {
    var body: some View {
        if let ci = HeroPhoto.golden.ciImage {
            GradedStillView(source: ci)
        } else {
            SceneArt(scene: .sunsetRoad)
        }
    }
}

/// Live-graded still image preview: re-renders whenever the grade changes.
struct GradedStillView: View {
    @EnvironmentObject private var app: AppModel
    let source: CIImage

    var body: some View {
        // Reading app.settings / selectedLook / selectedLUT here makes the
        // view re-render the still whenever the grade changes.
        let _ = app.settings
        let _ = app.selectedLook
        let _ = app.selectedLUT
        Group {
            if let cg = LookPipeline.shared.gradedStill(source, state: app.lookState,
                                                        maxDimension: 1400, includeSplit: true) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                Color.black
            }
        }
    }
}

// MARK: - The grade room

struct ApplyLookView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()

    /// Which expandable panel the drawer is showing. One at a time — the drawer
    /// is a single object, not a stack of trays.
    enum Panel: Equatable { case none, chain, scope, lens }
    @State private var panel: Panel = .none

    /// Which value the shared ruler dial is editing. "Opacity"/"Adjust" mean
    /// "the pinned Strength row owns this", so no dial is shown.
    @State private var activeTool =
        ProcessInfo.processInfo.environment["LUMA_SEED_TOOL"] ?? "Opacity"

    @State private var category: GradeCategory = .looks
    @State private var showLensPaywall = false
    @State private var mediaReadout: String?
    @State private var videoAspect: CGFloat?
    /// The unified look browser — chips, search, favourites and import all live
    /// in the sheet, not in the drawer.
    @State private var showLookBrowser =
        ProcessInfo.processInfo.environment["LUMA_SEED_BROWSER"] == "1"
    @State private var showLogExplainer = false
    @State private var stashedLookIntensity: Double?
    @State private var showConversionPicker = false
    /// Side-by-side LUT compare grid.
    @State private var showCompareGrid = false

    @AppStorage("lumalook.showScope") private var showScope = false
    @AppStorage("lumalook.scopeMode") private var scopeModeRaw = ScopeMode.waveform.rawValue
    @State private var scopeImage: CGImage?
    var scopeMode: ScopeMode { ScopeMode(rawValue: scopeModeRaw) ?? .waveform }

    /// Ungraded render of the current frame. It is the ORIGINAL tile's picture,
    /// which is also the press-and-hold compare tile.
    @State private var originalThumb: CGImage?
    /// Real graded tiles for the Skin First presets, which are settings-only
    /// and therefore have no entry in `LookThumbs`.
    @State private var skinThumbs: [String: CGImage] = [:]

    @State private var holdingOriginal = false
    @State private var eyedropping = false
    @State private var stashedIntensity: Double?
    /// Where the straight wipe sits, as a fraction of the picture's width.
    /// Original on the left, graded on the right.
    @State private var wipe: CGFloat = 0.5

    /// Look tiles are portrait (4:5), like the mock: room for a face, with the
    /// look's code and name under it.
    private static let tile: CGFloat = 62
    private static let tileHeight: CGFloat = 78
    private static let tileRadius: CGFloat = 13
    /// Thumb, the code line and the name line.
    private static let stripHeight: CGFloat = 116

    // MARK: Categories — the second axis

    /// The library categories this screen browses, plus the Skin First shelf,
    /// which is a settings preset family rather than a library section.
    /// Declared in tab order: the three the mock shows first, then the rest,
    /// which scroll in from the right.
    enum GradeCategory: String, CaseIterable, Identifiable {
        case looks, favourites, saved, recents, skin, purchased, imported
        var id: String { rawValue }

        var title: String {
            switch self {
            case .looks:      return "All looks"
            case .favourites: return "Favourites"
            case .recents:    return "Recent"
            case .skin:       return "Skin first"
            case .saved:      return "Mine"
            case .purchased:  return "Purchased"
            case .imported:   return "Imported"
            }
        }

        /// nil for the shelf that is not a library category.
        var library: LookLibraryStore.Category? {
            switch self {
            case .looks:      return .all
            case .favourites: return .favourites
            case .recents:    return .recents
            case .skin:       return nil
            case .saved:      return .saved
            case .purchased:  return .purchased
            case .imported:   return .imported
            }
        }
    }

    private var categories: [GradeCategory] { GradeCategory.allCases }

    /// The look tile the user last tapped in the strip, so the strip does
    /// not scroll after a tile that is already in front of them.
    @State private var tappedLookID: String?

    /// A horizontal strip is eagerly laid out, so it stays bounded — the full
    /// library is always one tap away behind "All looks". 60 is over four times
    /// the strip the room shipped with.
    private static let stripCap = 60

    /// "All looks" keeps the shipping strip's PRIORITY — the pinned collection
    /// first, then recently used, then favourites, then the rest.
    private var categoryLooks: [LibraryLook] {
        switch category {
        case .skin:  return []
        case .looks: return app.library.stripLooks(limit: Self.stripCap)
        default:
            guard let library = category.library else { return [] }
            return Array(app.library.looks(category: library).prefix(Self.stripCap))
        }
    }

    // MARK: Media identity

    private var thumbStamp: String {
        "\(mediaKey)-\(app.library.all.count)-\(app.tileStamp)"
    }

    private var mediaKey: String {
        if let url = app.selectedVideoURL { return url.absoluteString }
        if let still = app.selectedImage {
            return "still-\(ObjectIdentifier(still))"
        }
        if let player = app.player { return "player-\(ObjectIdentifier(player))" }
        return "none"
    }

    /// True while the stage is showing the bundled hero photo rather than the
    /// user's own media.
    private var hasRealMedia: Bool {
        app.player != nil || app.selectedImage != nil
    }

    /// Width / height of whatever is on the stage, so the media box can be cut
    /// to the picture instead of framing a black box around it.
    private var mediaAspect: CGFloat {
        if let videoAspect { return videoAspect }
        let extent = GradeSourceFrame.current(app).extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return 16.0 / 9.0 }
        return extent.width / extent.height
    }

    /// Loads a technical metadata readout for the selected media:
    /// `1920 × 1080 · 30 fps · 00:12` for video, `W × H · still` for photos.
    private func loadMediaReadout() async {
        if let url = app.selectedVideoURL {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (naturalSize, transform, fps) = try? await track.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate)
            else {
                mediaReadout = nil
                videoAspect = nil
                return
            }
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let w = Int(abs(rect.width).rounded())
            let h = Int(abs(rect.height).rounded())

            var parts = ["\(w) × \(h)"]
            if fps > 0 {
                let rounded = fps.rounded()
                parts.append(abs(Double(fps) - Double(rounded)) < 0.01
                             ? "\(Int(rounded)) fps"
                             : String(format: "%.2f fps", fps))
            }
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                let s = Int(seconds.rounded())
                parts.append(String(format: "%02d:%02d", s / 60, s % 60))
            }
            mediaReadout = parts.joined(separator: " · ")
            videoAspect = h > 0 ? CGFloat(w) / CGFloat(h) : nil
        } else if let still = app.selectedImage {
            let extent = still.extent
            mediaReadout = "\(Int(extent.width)) × \(Int(extent.height)) · still"
            videoAspect = nil
        } else {
            mediaReadout = nil
            videoAspect = nil
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                media
                drawer
            }
            topBar
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: thumbStamp) {
            thumbs.render(source: app.previewFrame,
                          library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) },
                          under: app.lookState.conversionSlot)
        }
        .task(id: mediaKey) { await loadMediaReadout() }
        .task(id: mediaKey) { renderOriginalThumb() }
        .task(id: "\(mediaKey)|\(app.selectedLook.id)|\(category == .skin)|\(app.tileStamp)") {
            await renderSkinThumbs()
        }
        .onAppear {
            app.exportError = nil          // never a stale error from a previous flow
            app.library.settleOrder()      // strips catch up with last visit's picks
            if showScope { panel = .scope }
            if activeTool == "Lens" { panel = .lens }
        }
        .onChange(of: panel) { _, new in showScope = (new == .scope) }
        .onDisappear {
            peekOriginal(false)            // never leave the grade stuck at 0
            app.saveGradeSession()
        }
        .sheet(isPresented: $showLensPaywall) { PaywallView() }
        .sheet(isPresented: $showCompareGrid) { LUTCompareView() }
        .overlay(alignment: .bottom) { exportErrorToast }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.exportError != nil)
        .lumaToolSheet(isPresented: $showConversionPicker, style: .panel) {
            ScrollView {
                conversionPicker.padding(.top, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .alert("Log LUT active", isPresented: $showLogExplainer) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("This LUT was built for Log footage (flat, low-contrast source). On regular footage it can look harsh. Lower the strength, or shoot Log for the intended result.")
        }
        // The preview must stay visible above the sheet at all times, so the
        // grade-room browser opens at MEDIUM (canvas still live and undimmed)
        // and only grows if the user drags it up.
        .lumaToolSheet(isPresented: $showLookBrowser, style: Self.lookBrowserSheetStyle) {
            LookBrowserSheet(context: .grade, intensity: $app.settings.intensity)
        }
    }

    /// Look browser as presented from the grade room: same detent ladder as
    /// `.tallPanel`, but it OPENS at medium so the fitted preview it is meant
    /// to be previewing against is never buried.
    private static let lookBrowserSheetStyle = LumaSheetStyle(
        detents: [.lumaMedium, .lumaLarge, .large],
        defaultDetent: .lumaMedium,
        undimmedUpThrough: .lumaMedium
    )

    /// Export failures and refusals. Transient, monochrome, and anchored over
    /// the DRAWER — never over the picture.
    @ViewBuilder
    private var exportErrorToast: some View {
        if let error = app.exportError {
            Text(error)
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(LumaTheme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { app.exportError = nil }
                }
        }
    }

    // MARK: Media — full bleed, with the straight Original / Graded wipe

    /// The still on stage at full size (the sample photo until media is
    /// picked); nil while a video plays.
    private var stageStill: CIImage? {
        guard app.player == nil else { return nil }
        return app.selectedImage ?? StillCompare.hero
    }

    /// The Skin first preset on the picture, if one is worn. It is picked
    /// like a look, so while it is on, the picture carries its name. The
    /// label used to keep the name of the built-in look underneath.
    private var wornPreset: SkinFirstPreset? {
        app.selectedLUT == nil ? SkinFirstPreset.worn(by: app.settings) : nil
    }

    private var currentLookName: String {
        if let preset = wornPreset { return preset.name }
        return app.selectedLUT?.displayName ?? app.selectedLook.name
    }

    private var currentLookColour: Color {
        if let preset = wornPreset { return Color(hex: preset.tintHex) }
        return app.selectedLUT.map { LookSignature.colour(name: $0.displayName) }
            ?? app.selectedLook.signature
    }

    /// The picture's foot is rounded, like the mock's frame.
    private static let frameShape = UnevenRoundedRectangle(
        topLeadingRadius: 0, bottomLeadingRadius: 34,
        bottomTrailingRadius: 34, topTrailingRadius: 0, style: .continuous)

    /// Edge to edge and up under the status bar. Drag across the picture to
    /// move the wipe, hold still to peek at the original, double tap to see
    /// the whole frame. The stage owns the eyedropper too, because it knows
    /// where the picture sits.
    private var media: some View {
        GradeWipeStage(aspect: mediaAspect,
                       still: stageStill,
                       focus: hasRealMedia ? .center : HeroPhoto.golden.focus,
                       wipe: $wipe,
                       eyedropping: $eyedropping,
                       showsWipe: !holdingOriginal && app.settings.intensity > 0,
                       label: currentLookName,
                       signature: currentLookColour,
                       onHold: { pressing in peekOriginal(pressing) })
            .clipShape(Self.frameShape)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)
            .sensoryFeedback(.impact(weight: .light), trigger: holdingOriginal)
            .animation(.easeOut(duration: 0.12), value: holdingOriginal)
            .animation(.easeOut(duration: 0.15), value: eyedropping)
    }

    /// Back on a glass circle, and the transient "Original" badge in the
    /// middle while a peek is held. The look itself is labelled on the
    /// picture and in the bottom row, so nothing else sits up here.
    private var topBar: some View {
        ZStack {
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(Color(hex: 0x101114).opacity(0.58), in: Circle())
                        .environment(\.colorScheme, .dark)
                        .contentShape(Circle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Back")
                Spacer(minLength: 0)
            }
            if holdingOriginal {
                Text("Original")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .modifier(StageGlassLabel())
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    /// Zeroes strength while held and restores it on release — one stash so a
    /// second press mid-peek can never strand the grade at 0.
    private func peekOriginal(_ pressing: Bool) {
        if pressing {
            if stashedIntensity == nil { stashedIntensity = app.settings.intensity }
            holdingOriginal = true
            app.settings.intensity = 0
        } else if let stashed = stashedIntensity {
            app.settings.intensity = stashed
            stashedIntensity = nil
            holdingOriginal = false
        }
    }

    /// Ungraded render of the current preview frame for the ORIGINAL tile.
    /// Must be the ungraded twin of whatever the stage is showing — the tile's
    /// whole contract is "this is your frame, without the look".
    private func renderOriginalThumb() {
        let frame = GradeSourceFrame.current(app)
        let extent = frame.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else {
            originalThumb = nil
            return
        }
        originalThumb = LookPipeline.shared.context.createCGImage(frame, from: extent)
    }

    /// Skin First presets carry settings, not a library entry, so `LookThumbs`
    /// never sees them. Render them here through the same pipeline against the
    /// current recipe — which is exactly what applying one would produce.
    /// Detached, like every other thumbnail render, so the drawer never stalls;
    /// only rendered while that shelf is actually on screen.
    private func renderSkinThumbs() async {
        guard category == .skin else { return }
        let frame = GradeSourceFrame.current(app)
        let extent = frame.extent
        // Never hand an infinite (clamped) extent to the pipeline's spatial ops.
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return }
        let recipe = app.selectedLook.recipe
        let conversion = app.lookState.conversionSlot
        let jobs = SkinFirstPreset.allCases.map { ($0.rawValue, $0.settings) }
        let rendered = await Task.detached(priority: .userInitiated) { () -> [String: CGImage] in
            var out: [String: CGImage] = [:]
            for (key, settings) in jobs {
                if Task.isCancelled { break }
                let state = LookState()
                state.conversionSlot = conversion
                state.recipe = recipe
                state.settings = settings
                if let cg = LookPipeline.shared.gradedStill(frame, state: state, maxDimension: 220) {
                    out[key] = cg
                }
            }
            return out
        }.value
        guard !Task.isCancelled, !rendered.isEmpty else { return }
        skinThumbs = rendered
    }

    // MARK: Drawer — everything that is not the image

    private var drawer: some View {
        VStack(spacing: 0) {
            statusLine
                .padding(.top, 14)
                .padding(.bottom, 7)
            categoryBar
                .padding(.bottom, 14)
            tiles
                .padding(.bottom, 2)
            panelView
            toolRow
                .padding(.bottom, 8)
            if showsEffectDial {
                GradeOpacityRow(title: activeTool, value: dialBinding,
                                format: { "\(Int($0.rounded()))" })
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
            strengthRow
                .padding(.bottom, 4)
            instructionBar
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: panel)
        .animation(.easeOut(duration: 0.18), value: showsEffectDial)
        .background { Color.black.ignoresSafeArea(edges: .bottom) }
    }

    /// What the frame IS, in numbers, on the left; on the right, whether the
    /// look is free or unlocks at export, plus the two states that qualify it.
    private var statusLine: some View {
        HStack(spacing: 10) {
            Group {
                if !hasRealMedia {
                    Text("Sample photo. Pick a clip to grade your own")
                } else if let mediaReadout {
                    Text(mediaReadout)
                        .monospacedDigit()
                }
            }
            .font(.luma(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.42))
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if !app.batchItems.isEmpty {
                    Text("\(app.batchItems.count) clips queued")
                        .font(.luma(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                if app.selectedLUT?.isLogTarget == true {
                    Button { showLogExplainer = true } label: {
                        HStack(spacing: 5) {
                            Circle().fill(.white.opacity(0.85)).frame(width: 5, height: 5)
                            Text("Log LUT")
                                .font(.luma(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.lumaPress)
                }
                if let access = lookAccessLine {
                    Text(access)
                        .font(.luma(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                }
            }
            .lineLimit(1)
            .layoutPriority(1)
        }
        // Fixed so the drawer does not jump when the readout finishes loading.
        .frame(height: 16)
        .padding(.horizontal, 20)
    }

    /// "Free look", or the pack that opens a premium look and the fact that
    /// it only asks at export ("After Dark · unlocks at export"). Nothing for
    /// the Original or a LUT file, which are always the user's own.
    private var lookAccessLine: String? {
        guard app.settings.intensity > 0 || holdingOriginal else { return nil }
        if let lock = app.lockedLookInGrade(storeService) {
            return "\(Self.unlockName(for: lock)) · unlocks at export"
        }
        if holdingOriginal, app.selectedLUT == nil,
           let lock = storeService.lock(forBuiltIn: app.selectedLook) {
            return "\(Self.unlockName(for: lock)) · unlocks at export"
        }
        return app.selectedLUT == nil ? "Free look" : nil
    }

    /// The pack that opens a locked look: the pack it names, the pack being
    /// tried on, else the Pro pack that carries a look of the same name
    /// (After Dark for Neon Nights), else Pro itself.
    private static func unlockName(for lock: LookLock) -> String {
        if let pack = lock.pack { return pack.name }
        if let id = lock.previewPackID, let pack = PackCatalog.pack(id: id) { return pack.name }
        let title = lock.lookName.components(separatedBy: " · ").last ?? lock.lookName
        let proPack = PackCatalog.packs.first { pack in
            pack.isProIncluded && pack.looks.contains { look in
                (look.name.components(separatedBy: " · ").last ?? look.name) == title
            }
        }
        return proPack?.name ?? "Pro"
    }

    /// Text tabs: the picked category white on light glass, the rest grey.
    /// All looks, Favourites and Mine lead; the rest scroll in.
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(categories) { item in
                    categoryTab(item)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 28)
    }

    private func categoryTab(_ item: GradeCategory) -> some View {
        let on = item == category
        return Button { pickCategory(item) } label: {
            Text(item.title)
                .font(.luma(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.5))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(on ? Color.white.opacity(0.13) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pickCategory(_ item: GradeCategory) {
        guard item != category else { return }
        withAnimation(.snappy(duration: 0.22)) { category = item }
        LumaHaptics.shared.tap()
    }

    // MARK: Tiles — every one of them is the real grade

    /// Strip id of the look that is currently applied, if it is in this
    /// category at all. A selected tile parked off-screen reads as "nothing
    /// applied", so the strip scrolls it to the middle.
    private var selectedTileID: String? {
        categoryLooks.first(where: { app.isCurrent($0) })?.id
    }

    private var tiles: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    originalTile
                    if category == .skin {
                        ForEach(SkinFirstPreset.allCases) { skinTile($0) }
                    } else {
                        ForEach(categoryLooks) { lookTile($0).id($0.id) }
                    }
                    allLooksTile
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 1)
            }
            .lumaEdgeFade(leading: 20, trailing: 20)
            .sensoryFeedback(.selection, trigger: app.selectedLook.id)
            .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
            .onAppear {
                guard let id = selectedTileID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onChange(of: selectedTileID) { _, new in
                // A tile the user just tapped is already under their thumb:
                // scrolling after it would lose their place. Only a pick made
                // elsewhere (All looks, undo, a category switch) is fetched.
                // A saved look also lights its base tile, which can sit
                // earlier in the strip, so test the tapped tile itself.
                guard let new else { return }
                if let tapped = tappedLookID,
                   let look = categoryLooks.first(where: { $0.id == tapped }),
                   app.isCurrent(look) { return }
                tappedLookID = nil
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(new, anchor: .center) }
            }
            // Fixed so the drawer never jumps as categories change.
            .frame(height: Self.stripHeight)
        }
    }

    /// One shared tile geometry, so a look, a preset and the original all read
    /// as the same object at the same size.
    private func tileFrame<Content: View>(selected: Bool,
                                          @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: Self.tile, height: Self.tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
            // clipShape clips PIXELS, not touches: a landscape frame scaled to
            // fill a square tile overflows well past its bounds and eats its
            // neighbours' taps without this.
            .contentShape(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
            .pickedRing(selected, cornerRadius: Self.tileRadius)
    }

    /// The two lines under a tile: the code (a look's in its own colour) and
    /// the name in grey, brighter on the picked tile.
    private func tileCaption<Code: View>(name: String, selected: Bool,
                                         @ViewBuilder code: () -> Code) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            code()
                .frame(height: 14)
            Text(name)
                .font(.luma(size: 10.5, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.7) : LumaTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: Self.tile, alignment: .leading)
    }

    /// A white code line, for the tiles that are not a look.
    private func plainCode(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 11, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Tap latches the grade off and tapping again brings the old strength
    /// back; press and hold peeks. This IS the corner Compare tile, moved off
    /// the picture and now showing the real ungraded frame.
    private var originalTile: some View {
        let active = app.settings.intensity == 0
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                if app.settings.intensity == 0 {
                    app.settings.intensity = stashedLookIntensity ?? 75
                    stashedLookIntensity = nil
                } else {
                    stashedLookIntensity = app.settings.intensity
                    app.settings.intensity = 0
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                tileFrame(selected: active || holdingOriginal) {
                    Group {
                        if let originalThumb {
                            Image(decorative: originalThumb, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            LumaTheme.surface
                        }
                    }
                }
                tileCaption(name: active ? "Look off" : "No look", selected: active) {
                    plainCode("Original")
                }
            }
        }
        .buttonStyle(.lumaPress)
        .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 40) {
        } onPressingChanged: { pressing in
            peekOriginal(pressing)
        }
        .accessibilityLabel("Original. Tap to bypass the look, hold to peek")
    }

    private func lookTile(_ look: LibraryLook) -> some View {
        let selected = app.isCurrent(look)
        return Button {
            tappedLookID = look.id
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                app.select(look: look)
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                tileFrame(selected: selected) {
                    // Color.clear holds the tile's size, so the fill image
                    // sits inside it.
                    Color.clear
                        .overlay { lookThumb(look) }
                }
                .overlay(alignment: .topLeading) {
                    if let badge = sourceBadge(look) {
                        Text(badge)
                            .font(.luma(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if storeService.isLocked(look) { LookLockGlyph(compact: true) }
                }
                tileCaption(name: look.nameSplit.title, selected: selected) {
                    LookNameText(LookCode.short(look), colour: look.signature,
                                 size: 11, weight: .bold)
                }
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(lookTileLabel(look))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The look's name, plus what its badges say on screen.
    private func lookTileLabel(_ look: LibraryLook) -> String {
        var parts = [look.name]
        if let badge = sourceBadge(look) { parts.append(badge) }
        if storeService.isLocked(look) { parts.append("locked look") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func lookThumb(_ look: LibraryLook) -> some View {
        if let cg = thumbs.images[look.thumbKey] {
            Image(decorative: cg, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LumaTheme.surfaceStrong
        }
    }

    private func sourceBadge(_ look: LibraryLook) -> String? {
        switch look.source {
        case .saved:      return "Saved"
        case .lut(let f): return f.isLogTarget ? "Log" : "LUT"
        case .builtIn:    return nil
        }
    }

    /// Research-tuned presets for Black & deep skin — settings, no LUT, so
    /// they bake cleanly. Rendered through the real pipeline like everything
    /// else on this row.
    private func skinTile(_ preset: SkinFirstPreset) -> some View {
        let selected = app.selectedLUT == nil && SkinFirstPreset.worn(by: app.settings) == preset
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                app.selectedLUT = nil
                app.settings = preset.settings
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                tileFrame(selected: selected) {
                    Group {
                        if let cg = skinThumbs[preset.rawValue] {
                            Image(decorative: cg, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            LumaTheme.surfaceStrong
                        }
                    }
                }
                tileCaption(name: "Skin first", selected: selected) {
                    plainCode(preset.name)
                }
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityHint(preset.blurb)
    }

    private var allLooksTile: some View {
        Button {
            showLookBrowser = true
            LumaHaptics.shared.tap()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                tileFrame(selected: false) {
                    Color.white.opacity(0.055)
                        .overlay {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                }
                tileCaption(name: "\(app.library.all.count) looks", selected: false) {
                    plainCode("All looks")
                }
            }
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: Panels — one at a time

    @ViewBuilder
    private var panelView: some View {
        switch panel {
        case .none:  EmptyView()
        case .chain: chainPanel.padding(.bottom, 12)
        case .scope: scopePanel.padding(.bottom, 12)
        case .lens:  lensPanel.padding(.bottom, 12)
        }
    }

    // MARK: Tool row — five quiet tiles first, the number is the better icon

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                valueTool(amount(app.settings.grain), "Grain",
                          on: app.settings.grain > 0,
                          picked: activeTool == "Grain") { selectDial("Grain") }
                valueTool(amount(app.settings.bloom), "Bloom",
                          on: app.settings.bloom > 0,
                          picked: activeTool == "Bloom") { selectDial("Bloom") }
                valueTool(amount(app.settings.halation), "Halation",
                          on: app.settings.halation > 0,
                          picked: activeTool == "Halation") { selectDial("Halation") }
                valueTool(amount(app.settings.vignette), "Vignette",
                          on: app.settings.vignette > 0,
                          picked: activeTool == "Vignette") { selectDial("Vignette") }
                valueTool(lensValue, "Lens", on: activeLens != .none,
                          picked: activeTool == "Lens") {
                    if activeTool == "Lens", panel == .lens {
                        activeTool = "Opacity"
                        panel = .none
                    } else {
                        activeTool = "Lens"
                        panel = .lens
                    }
                    LumaHaptics.shared.tap()
                }
                valueTool(sourceValue, "Source", on: hasConversion, picked: false) {
                    showConversionPicker = true
                    LumaHaptics.shared.tap()
                }

                toolDivider

                // Auto takes a colour cast off and nothing else. What it sets
                // is a white balance, so the White bal. tile next to it lights
                // up and takes it off again. For a moment its own tile says
                // what it found, so a tap that changes nothing is not a tap
                // that did nothing.
                if LumaFeatures.autoGrade {
                    tool("wand.and.stars", autoLabel,
                         on: app.isAutoGrading || app.autoFound != nil,
                         enabled: hasRealMedia && !app.isAutoGrading) {
                        guard hasRealMedia else { return }
                        Task { await app.autoGrade() }
                    }
                    .accessibilityHint(hasRealMedia ? "Takes a colour cast off the picture" : "Pick a photo or video first")
                }
                // Lit while a white balance is on, so it is never on unseen
                // (it carries to the next look and the next photo). Tapping
                // the lit tile takes it off; tapping again picks a new one.
                tool("eyedropper.halffull", "White bal.", on: eyedropping || app.whiteBalanceIsOn,
                     enabled: hasRealMedia || app.whiteBalanceIsOn) {
                    if app.whiteBalanceIsOn, !eyedropping {
                        app.clearWhiteBalance()
                    } else {
                        guard hasRealMedia else { return }
                        withAnimation(.easeOut(duration: 0.15)) { eyedropping.toggle() }
                    }
                    LumaHaptics.shared.tap()
                }
                .accessibilityValue(app.whiteBalanceIsOn ? "On" : "Off")
                .accessibilityHint(app.whiteBalanceIsOn && !eyedropping
                                   ? "Takes the white balance off"
                                   : (hasRealMedia ? "Choose a neutral point in the selected media" : "Pick a photo or video first"))
                tool(isFavourite ? "star.fill" : "star",
                     isFavourite ? "Favourited" : "Favourite",
                     on: isFavourite, enabled: currentLibraryLook != nil) {
                    toggleFavourite()
                }
                tool("square.stack.3d.down.right", "Chain", on: panel == .chain || app.chainIsAdjusted) {
                    panel = panel == .chain ? .none : .chain
                    LumaHaptics.shared.tap()
                }
                tool("waveform.path.ecg.rectangle", "Scope", on: panel == .scope) {
                    panel = panel == .scope ? .none : .scope
                    LumaHaptics.shared.tap()
                }
                tool("rectangle.split.2x1", "Compare", on: false) {
                    LumaHaptics.shared.tap()
                    app.path.append(.beforeAfter)
                }
                tool("square.grid.2x2", "LUT grid", on: false) {
                    showCompareGrid = true
                    LumaHaptics.shared.tap()
                }
                tool("dial.high", "More", on: app.gradeIsAdjusted) {
                    app.path.append(.customLook)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 1)
        }
        .lumaEdgeFade(leading: 20, trailing: 20)
    }

    /// A little more air between the value tiles and the action tiles; no
    /// rule, because nothing on this screen is outlined.
    private var toolDivider: some View {
        Color.clear.frame(width: 4, height: 46)
    }

    private static let toolWidth: CGFloat = 66
    private static let toolHeight: CGFloat = 46
    private static let toolRadius: CGFloat = 13

    /// A quiet glass tile: the live value, its name beneath in small caps.
    /// A tool that is doing something reads brighter; the one on the slider
    /// sits on lighter glass.
    private func valueTool(_ value: String, _ label: String, on: Bool, picked: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(value)
                    .font(.luma(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(on || picked ? Color.white : Color.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                toolLabel(label, on: on || picked)
            }
            .frame(width: Self.toolWidth, height: Self.toolHeight)
            .background(Color.white.opacity(picked ? 0.12 : 0.055),
                        in: RoundedRectangle(cornerRadius: Self.toolRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.toolRadius, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// The Auto tile's word: what it is doing, or for a moment what it found.
    private var autoLabel: String {
        if app.isAutoGrading { return "Working" }
        switch app.autoFound {
        case .fixed: return "Fixed"
        case .nothingToFix: return "No change"
        case nil: return "Auto"
        }
    }

    /// The same quiet tile with a glyph where the value would be.
    private func tool(_ symbol: String, _ label: String, on: Bool,
                      enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.8))
                    .frame(height: 18)
                toolLabel(label, on: on)
            }
            .frame(width: Self.toolWidth, height: Self.toolHeight)
            .background(Color.white.opacity(on ? 0.12 : 0.055),
                        in: RoundedRectangle(cornerRadius: Self.toolRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.toolRadius, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    private func toolLabel(_ text: String, on: Bool) -> some View {
        Text(text.uppercased())
            .font(.luma(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.white.opacity(on ? 0.7 : 0.42))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 3)
    }

    private func amount(_ value: Double) -> String { "\(Int(value.rounded()))" }

    private var activeLens: LensKind {
        LensKind(rawValue: app.settings.lensKind) ?? .none
    }

    private var lensValue: String {
        activeLens == .none ? "Off" : "\(Int(app.settings.lensAmount.rounded()))"
    }

    private var hasConversion: Bool {
        app.conversionProfile != nil || app.conversionLUT != nil
    }

    /// Short enough for a 68pt tool, honest about what is in slot 1.
    private var sourceValue: String {
        if let profile = app.conversionProfile { return profile.label }
        if app.conversionLUT != nil { return "LUT" }
        return "None"
    }

    /// Puts a tool on the shared slider; tapping the same tile again puts
    /// it away and leaves the Strength slider on its own.
    private func selectDial(_ tool: String) {
        activeTool = activeTool == tool ? "Opacity" : tool
        if panel == .lens { panel = .none }
        LumaHaptics.shared.tap()
    }

    /// One dial, five parameters: the dial always edits the active tool.
    /// Every one of them is 0…100 in user space and `/100` in the engine, so
    /// there is no dead travel at either end.
    private var dialBinding: Binding<Double> {
        switch activeTool {
        case "Grain":    return $app.settings.grain
        case "Bloom":    return $app.settings.bloom
        case "Halation": return $app.settings.halation
        case "Vignette": return $app.settings.vignette
        case "Lens":     return $app.settings.lensAmount
        default:         return $app.settings.intensity
        }
    }

    /// "Adjust" is the legacy value LUMA_SEED_TOOL may still pass for the
    /// strength tool; both mean "the pinned Strength row owns this".
    private var showsEffectDial: Bool {
        activeTool != "Opacity" && activeTool != "Adjust"
    }

    // MARK: Strength — pinned directly above Apply

    private var strengthRow: some View {
        GradeOpacityRow(title: "Strength", value: $app.settings.intensity)
    }

    // MARK: Instruction bar — dismiss, the statement, Apply

    /// The library entry matching the grade currently on screen, via the one
    /// selection truth. nil only for a fully hand-built grade (Skin First
    /// preset, custom settings) that no library look describes.
    private var currentLibraryLook: LibraryLook? {
        app.library.all.first { app.isCurrent($0) }
    }

    private var isFavourite: Bool {
        currentLibraryLook.map { app.library.isFavourite($0.id) } ?? false
    }

    /// One tap saves the look + strength combo. For a LUT the opacity is real
    /// stored state (`defaultOpacity`), so starring at 62% brings it back at
    /// 62% from Favourites anywhere in the app.
    private func toggleFavourite() {
        guard let look = currentLibraryLook else { return }
        if !isFavourite, case .lut(let file) = look.source {
            app.lutRepository.setDefaults(for: file.id,
                                          opacity: app.creativeOpacity,
                                          blend: app.creativeBlend.rawValue)
        }
        app.library.toggleFavourite(look)
        LumaHaptics.shared.tap()
    }

    /// Cancel, the applied look in its own colour, and Apply look: the one
    /// main action, so it is the one place signal yellow (or the quiet white
    /// the person picked) appears in the drawer.
    private var instructionBar: some View {
        let strength = Int(app.settings.intensity.rounded())
        return HStack(spacing: 10) {
            Button { dismiss() } label: {
                Text("Cancel")
                    .font(.luma(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel("Close the grade room")

            Spacer(minLength: 0)
            Group {
                if strength == 0 {
                    Text("Original")
                        .font(.luma(size: 13, weight: .medium))
                        .foregroundStyle(LumaTheme.textMuted)
                } else {
                    LookNameText(currentLookName, colour: currentLookColour, size: 13)
                }
            }
            .lineLimit(1)
            .allowsHitTesting(false)
            Spacer(minLength: 0)

            applyButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    /// The one main action on the screen. Apply is never disabled: the
    /// current look at the current strength is always a valid answer.
    private var applyButton: some View {
        LumaMainPill(title: "Apply look", height: 36) { applyAndAdvance() }
            .accessibilityLabel("Apply this look and compare")
    }

    /// With no media the forward move is the picker, not a disabled button.
    private func applyAndAdvance() {
        LumaHaptics.shared.tap()
        guard app.player != nil || app.selectedImage != nil else {
            app.path = [.selectClip]
            return
        }
        if let look = currentLibraryLook { app.library.noteUsed(look) }
        app.saveGradeSession()
        app.exportError = nil
        app.path.append(.beforeAfter)      // compare, confirm, export
    }
}

// MARK: - Lens panel

extension ApplyLookView {
    /// Eight kinds of glass. The strength lives on the shared dial below, so
    /// the panel is only ever a choice of lens.
    fileprivate var lensPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(LensKind.allCases, id: \.self) { lens in
                    lensTile(lens)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 1)
        }
        .lumaEdgeFade(leading: 20, trailing: 20)
        .transition(.opacity)
    }

    private func lensTile(_ lens: LensKind) -> some View {
        let selected = app.settings.lensKind == lens.rawValue
        let locked = lens.requiresPro && !storeService.isPro
        return Button {
            if locked {
                showLensPaywall = true
                LumaHaptics.shared.tap()
                return
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                app.settings.lensKind = lens.rawValue
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : 0.055))
                    .frame(width: 68, height: 50)
                    .overlay {
                        Image(systemName: lens.icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    }
                    .pickedRing(selected, cornerRadius: 12)
                    .overlay(alignment: .topTrailing) {
                        if locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(3)
                                .background(.white.opacity(0.85), in: Circle())
                                .offset(x: 4, y: -4)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(lens.label)
                    .font(.luma(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 74)
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityHint(lens.blurb)
    }
}

// MARK: - Scope panel

extension ApplyLookView {
    fileprivate var scopeStamp: String {
        "\(app.settings)-\(app.selectedLook.id)-\(app.selectedLUT?.id.uuidString ?? "")-\(app.conversionLUT?.id.uuidString ?? "")-\(Int(app.conversionOpacity))-\(Int(app.creativeOpacity))-\(mediaKey)"
    }

    /// Sentence case: a scope name is a NAME, not a readout.
    fileprivate var scopeTitle: String {
        switch scopeMode {
        case .waveform:    return "RGB waveform"
        case .parade:      return "RGB parade"
        case .vectorscope: return "Vectorscope"
        case .histogram:   return "RGB histogram"
        case .falseColor:  return "False colour"
        }
    }

    /// Off the picture, onto the drawer — the scope reads the GRADED frame, so
    /// it shows exactly what will be exported.
    fileprivate var scopePanel: some View {
        let vector = scopeMode == .vectorscope
        let scopeW: CGFloat = vector ? 110 : 200
        let scopeH: CGFloat = vector ? 110 : 96
        return HStack(spacing: 14) {
            Group {
                if let scopeImage {
                    Image(decorative: scopeImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }
            }
            .frame(width: scopeW, height: scopeH)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                scopeModeRaw = scopeMode.next.rawValue
                LumaHaptics.shared.tap()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(scopeTitle)
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Reading the graded frame")
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Button {
                    scopeModeRaw = scopeMode.next.rawValue
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
        .padding(.horizontal, 20)
        .transition(.opacity)
        .task(id: "\(scopeStamp)|\(scopeModeRaw)|\(Int(scopeW))x\(Int(scopeH))") {
            scopeImage = await Scopes.render(frame: GradeSourceFrame.current(app),
                                             state: app.lookState, mode: scopeMode,
                                             size: CGSize(width: scopeW, height: scopeH))
        }
    }

    /// Histogram of the GRADED frame — the scope reads what you'll export.
    /// Kept alongside `ScopeMode.histogram` as the CIAreaHistogram renderer.
    fileprivate static func renderHistogram(frame: CIImage, state: LookState) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let graded = LookPipeline.shared.apply(state: state, to: frame, includeSplit: false)
            let area = CIFilter.areaHistogram()
            area.inputImage = graded
            area.extent = graded.extent
            area.count = 64
            area.scale = 12
            guard let histogram = area.outputImage else { return nil }
            let display = CIFilter.histogramDisplay()
            display.inputImage = histogram
            display.height = 44
            display.highLimit = 1
            display.lowLimit = 0
            guard let image = display.outputImage else { return nil }
            return LookPipeline.shared.context.createCGImage(image, from: image.extent)
        }.value
    }
}

// MARK: - Slot chain panel

extension ApplyLookView {
    /// Conversion × Creative — the PeekLut/Lutter stacking model. Drag a slot
    /// horizontally to set its strength; tap it to change what is in it.
    fileprivate var chainPanel: some View {
        VStack(spacing: 8) {
            GradeSlotRow(kind: "Source",
                         name: conversionName,
                         opacity: $app.conversionOpacity,
                         isActive: hasConversion) {
                showConversionPicker = true
            }
            // With a LUT loaded the slot owns the LUT's own opacity. With a
            // preset look it is LABELLED with that look, so it must drive the
            // look's strength — the same value the Strength row and the
            // instruction bar show. Two numbers for one look is a bug.
            GradeSlotRow(kind: "Look",
                         name: currentLookName,
                         colour: currentLookColour,
                         opacity: app.selectedLUT != nil ? $app.creativeOpacity
                                                         : $app.settings.intensity,
                         isActive: true) {
                showLookBrowser = true
                LumaHaptics.shared.tap()
            }
            if app.selectedLUT != nil { blendRow }
        }
        .padding(.horizontal, 20)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: app.selectedLUT?.id)
    }

    /// Slot 1 reports the log PROFILE as well as a conversion LUT — with a
    /// profile picked, "None" was a lie.
    private var conversionName: String {
        app.conversionLUT?.displayName ?? app.conversionProfile?.label ?? "None"
    }

    /// Blend mode for the creative LUT slot. Selected separates by SURFACE
    /// value, not by an outline and not by an accent.
    private var blendRow: some View {
        HStack(spacing: 6) {
            ForEach(LUTBlendMode.allCases, id: \.self) { mode in
                let on = app.creativeBlend == mode
                Button {
                    app.creativeBlend = mode
                    LumaHaptics.shared.tap()
                } label: {
                    Text(mode.label)
                        .font(.luma(size: 11.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? .white : .white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(on ? LumaTheme.cardRaised : LumaTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.lumaPress)
            }
        }
        .transition(.opacity)
    }

    // MARK: Source-format picker

    fileprivate var conversionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            pickerHeading("Source format")
            // Built-in log profiles: the public transfer math baked to a cube.
            // No vendor files; mutually exclusive with a conversion LUT.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LogProfile.allCases, id: \.self) { profile in
                        let on = app.conversionProfile == profile
                        Button {
                            app.conversionProfile = on ? nil : profile
                            LumaHaptics.shared.tap()
                        } label: {
                            Text(profile.label)
                                .font(.luma(size: 13, weight: .semibold))
                                .fixedSize()
                                .foregroundStyle(on ? .black : .white.opacity(0.85))
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(on ? AnyShapeStyle(.white)
                                               : AnyShapeStyle(LumaTheme.surface), in: Capsule())
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.horizontal, 22)
            }
            pickerHeading("Conversion LUT, applied first")
                .padding(.top, 6)
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        app.conversionLUT = nil
                        app.conversionProfile = nil
                        showConversionPicker = false
                    } label: {
                        pickerRow(name: "None", tag: nil,
                                  selected: app.conversionLUT == nil && app.conversionProfile == nil)
                    }
                    .buttonStyle(.lumaPress)
                    // Log-target LUTs first: that's what conversion slots are for.
                    ForEach(app.lutRepository.luts.sorted {
                        ($0.isLogTarget ? 0 : 1, $0.displayName) < ($1.isLogTarget ? 0 : 1, $1.displayName)
                    }) { lut in
                        Button {
                            app.conversionLUT = lut
                            showConversionPicker = false
                        } label: {
                            pickerRow(name: lut.displayName,
                                      tag: lut.isLogTarget ? "Log" : nil,
                                      selected: app.conversionLUT?.id == lut.id)
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }

    private func pickerHeading(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 22)
    }

    private func pickerRow(name: String, tag: String?, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? .white : .white.opacity(0.35))
            Text(name)
                .font(.luma(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let tag {
                Text(tag)
                    .font(.luma(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(LumaTheme.surfaceStrong, in: Capsule())
            }
            Spacer()
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// MARK: - Slot row

/// One slot in the chain: what it is, what is in it, how strong it is.
/// Horizontal drag sets the strength; tap changes the contents.
private struct GradeSlotRow: View {
    let kind: String
    let name: String
    /// A look's own colour: its name follows the Names setting.
    var colour: Color? = nil
    @Binding var opacity: Double
    let isActive: Bool
    let onTap: () -> Void

    @State private var dragStart: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind)
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 52, alignment: .leading)
                nameText
                Spacer(minLength: 4)
                // An empty slot has no strength to report: "Off" matches the
                // empty track and the dimmed "None" title.
                Text(isActive ? "\(Int(opacity.rounded()))%" : "Off")
                    .font(.luma(size: 12, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                    .foregroundStyle(isActive ? .white.opacity(0.85) : .white.opacity(0.35))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: isActive ? geo.size.width * opacity / 100 : 0)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LumaTheme.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { drag in
                    guard isActive else { return }
                    if dragStart == nil { dragStart = opacity }
                    opacity = min(max(0, (dragStart ?? opacity) + Double(drag.translation.width) / 1.4), 100)
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: Int(opacity / 10))
        .animation(.snappy(duration: 0.15), value: opacity)
        .accessibilityLabel("\(kind) slot, \(name)")
    }

    @ViewBuilder
    private var nameText: some View {
        if let colour, isActive {
            LookNameText(name, colour: colour, size: 13)
        } else {
            Text(name)
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? .white.opacity(0.95) : .white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Shared pieces

/// Painted-swatch thumbnail cell. Kept for surfaces that have no real graded
/// frame to show; the grade room itself renders every tile through the
/// pipeline now.
struct LookThumbCell: View {
    let title: String
    var grade: Color? = nil
    var selected: Bool = false
    var badge: String? = nil
    var image: CGImage? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let image {
                        GradedThumb(image: image, selected: selected)
                    } else {
                        SceneThumb(scene: .sunsetRoad, grade: grade, radius: 16, selected: selected)
                    }
                }
                    .frame(width: 96, height: 96)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge)
                                .font(.luma(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.5), in: Capsule())
                                .padding(6)
                        }
                    }
                Text(title)
                    .font(.luma(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 96)
            }
        }
        .buttonStyle(.lumaPress)
    }
}

/// The pinned strength row. Shared by the grade room and the compare screen so
/// the control that decides how strong a look is looks and feels identical in
/// both. As the Sliders setting says: a "Strength 75%" line over the straight
/// ruler, or the curved dial, which draws its own title and big value (so the
/// line is hidden). The needle is signal yellow, the only yellow on the
/// screen besides the main action. Full width; the line insets itself.
struct GradeOpacityRow: View {
    var title: String = "Strength"
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var format: (Double) -> String = { "\(Int($0.rounded()))%" }
    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue

    private var isDial: Bool {
        (LumaSliderStyle(rawValue: sliderRaw) ?? .ruler) == .dial
    }

    var body: some View {
        VStack(spacing: 6) {
            if !isDial {
                HStack {
                    Text(title)
                        .font(.luma(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer(minLength: 0)
                    Text(format(value))
                        .font(.luma(size: 13, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.15), value: Int(value))
                        .foregroundStyle(LumaTheme.textPrimary)
                }
                .padding(.horizontal, 20)
            }
            LumaValueSlider(value: $value, range: range, title: title, format: format)
                // The shared ruler always calls itself "Strength" to
                // VoiceOver; this row edits Grain, Bloom and the rest too,
                // so it speaks for itself with its own title.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
                .accessibilityAdjustableAction { direction in
                    let step: Double = direction == .increment ? 5 : -5
                    value = min(max(range.lowerBound, value + step), range.upperBound)
                }
        }
    }
}

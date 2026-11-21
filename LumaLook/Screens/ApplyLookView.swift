import SwiftUI
import AVKit

// =============================================================================
// C1 — THE GRADE ROOM, in the approved design language.
//
// This is the SHIPPING screen. The retired Design Lab sketch (`LDGradeDemoView`,
// since deleted) was the first pass at the language (category bar, look tiles,
// instruction bar); it was the STYLE reference here and nothing more.
// Everything the shipping room could do it still does — the controls moved off
// the picture and into the drawer, and every scrap of accent colour came out so
// the footage and the looks are the only coloured things on screen.
//
// FEATURE INVENTORY — "I'm not trying to lose features." Nothing is dropped.
//
//   ✓ Look strip — every tile is the REAL grade of the user's frame (LookThumbs)
//   ✓ Two-axis browsing — categories swipe left/right, looks scroll along
//   ✓ Auto-scroll: the applied look is centred in the strip, never parked off it
//   ✓ Source badges on tiles (Log / LUT / Saved) so a log cube is never a
//     surprise
//   ✓ "All looks" tile → the full LookBrowserSheet (search, chips, collections,
//     import) at the medium detent, canvas undimmed  [LUMA_SEED_BROWSER=1]
//   ✓ ORIGINAL tile — tap latches the grade to 0 and tapping again restores the
//     previous strength; press-and-hold peeks. It renders the real ungraded
//     frame, so it is also the corner Compare tile, moved off the picture.
//   ✓ Press-and-hold anywhere on the picture to peek the original (transient —
//     the ONE thing still allowed to draw over the frame)
//   ✓ Compare tool → BeforeAfterView, the deep-compare surface
//   ✓ LUT compare grid (LUTCompareView) — same grade, many LUTs, side by side
//   ✓ Pinned Apply — always enabled, never a dead end (no media ⇢ the picker)
//   ✓ Favourite — stores look + opacity; for a LUT the opacity is real stored
//     state, so starring at 62% brings it back at 62% everywhere
//   ✓ Strength (opacity) row pinned directly above Apply, 0…100 = engine range
//   ✓ Adjust tools — Grain / Bloom / Halation / Vignette / Lens, each showing
//     its LIVE VALUE rather than a glyph, edited by one shared ruler dial
//   ✓ Lens panel — eight lens kinds, Pro-locked ones open the paywall
//   ✓ Auto-grade  ✓ WB eyedropper (tap a neutral in the frame)
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
// THE LANGUAGE
//   1. The image is the interface. Media uncovered at the top with a generous
//      radius; every control lives in the drawer below it. The only things ever
//      drawn on the frame are the two TRANSIENT states that must register with
//      the picture: the hold-to-compare peek, and the eyedropper's target
//      prompt (you are literally choosing a pixel).
//   2. Monochrome chrome. Black, near-black, white, grey. No accent anywhere.
//      All colour on this screen comes from the footage and the looks.
//   3. Stroke means selection and nothing else — one thin white ring on the
//      selected look. Everything else separates by surface value.
//   4. The tile IS the preview — every tile is the real grade, including the
//      Skin First presets and the ORIGINAL tile.
//   5. Two-axis browsing — the current category centred, neighbours faded
//      either side, swipeable, so the gesture teaches itself.
//   6. Mono type is for NUMBERS ONLY. Percentages, resolutions, frame rates,
//      durations. Every label is the system font in sentence case at 11–17pt.
//      `TechReadout` appears nowhere on this screen: its forced uppercase and
//      1.2pt kerning cannot look anything but timid at small size.
//   7. Prefer a live value over a glyph. Grain, Bloom, Halation, Vignette, Lens
//      and Source all show their number — the number is the better icon, and it
//      is live. Same voice as the camera drawer's value tools.
//   8. A calm instruction bar: dismiss at one edge, the applied look and its
//      strength stated in the middle, Apply at the other. Apply is the one
//      place a filled button is still correct.
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
        Label("Preview — pick a clip to grade live", systemImage: "film")
            .font(.system(size: 12, weight: .medium))
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

    private static let tile: CGFloat = 78
    private static let tileRadius: CGFloat = 12

    // MARK: Categories — the second axis

    /// The library categories this screen browses, plus the Skin First shelf,
    /// which is a settings preset family rather than a library section.
    enum GradeCategory: String, CaseIterable, Identifiable {
        case looks, favourites, recents, skin, saved, purchased, imported
        var id: String { rawValue }

        var title: String {
            switch self {
            case .looks:      return "All looks"
            case .favourites: return "Favourites"
            case .recents:    return "Recent"
            case .skin:       return "Skin first"
            case .saved:      return "Your looks"
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
    private var categoryIndex: Int { categories.firstIndex(of: category) ?? 0 }

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
        "\(mediaKey)-\(app.library.all.count)"
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
    /// `1920×1080 · 30 fps · 00:12` for video, `W×H · Still` for photos.
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

            var parts = ["\(w)×\(h)"]
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
            mediaReadout = "\(Int(extent.width))×\(Int(extent.height)) · Still"
            videoAspect = nil
        } else {
            mediaReadout = nil
            videoAspect = nil
        }
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                media
                drawer
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: thumbStamp) {
            thumbs.render(source: app.previewFrame,
                          library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        .task(id: mediaKey) { await loadMediaReadout() }
        .task(id: mediaKey) { renderOriginalThumb() }
        .task(id: "\(mediaKey)|\(app.selectedLook.id)|\(category == .skin)") {
            await renderSkinThumbs()
        }
        .onAppear {
            app.exportError = nil          // never a stale error from a previous flow
            if showScope { panel = .scope }
            if activeTool == "Lens" { panel = .lens }
        }
        .onChange(of: panel) { _, new in showScope = (new == .scope) }
        .onDisappear { app.saveGradeSession() }
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
            Text("This LUT was built for Log footage (flat, low-contrast source). On regular footage it can look harsh — lower the strength, or shoot Log for the intended result.")
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(LumaTheme.bar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { app.exportError = nil }
                }
        }
    }

    // MARK: Media — uncovered, cut to the picture, generous radius

    private var media: some View {
        ZStack {
            LookPreviewSurface(radius: 22, showsEmptyHint: false)
            // ≥1.4 video keeps its frame-edge hairline. With the box cut to the
            // source aspect there is normally nothing left to matte.
            if app.player != nil, let aspect = videoAspect, aspect >= 1.4 {
                LetterboxMattes(contentAspect: aspect)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // clipShape clips PIXELS, not touches.
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // Press-and-hold anywhere on the image to see the original — the
        // industry-standard before/after peek. Attached BEFORE the aspect box
        // so it lives on the picture, not on the void beside it.
        .onLongPressGesture(minimumDuration: 0.18, maximumDistance: 60) {
        } onPressingChanged: { pressing in
            peekOriginal(pressing)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: holdingOriginal)
        .overlay(alignment: .top) { peekBadge }
        .overlay { eyedropperLayer }
        // The media box is cut to the source, so the rounded frame hugs the
        // picture instead of framing a black box around it.
        .aspectRatio(mediaAspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: mediaAspect)
        .animation(.easeOut(duration: 0.12), value: holdingOriginal)
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// The one transient state allowed to draw on the frame.
    @ViewBuilder
    private var peekBadge: some View {
        if holdingOriginal {
            Text("Original")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.top, 14)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// WB eyedropper: tap a neutral in the frame to balance to it. It has to be
    /// on the picture — the gesture IS a pixel choice.
    @ViewBuilder
    private var eyedropperLayer: some View {
        if eyedropping {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    Color.white.opacity(0.001)
                    Text("Tap something that should be neutral grey or white")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.top, 14)
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    let n = CGPoint(x: min(max(0, loc.x / geo.size.width), 1),
                                    y: min(max(0, loc.y / geo.size.height), 1))
                    Task { await app.whiteBalance(atNormalized: n) }
                    eyedropping = false
                }
            }
            .transition(.opacity)
        }
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
        let jobs = SkinFirstPreset.allCases.map { ($0.rawValue, $0.settings) }
        let rendered = await Task.detached(priority: .userInitiated) { () -> [String: CGImage] in
            var out: [String: CGImage] = [:]
            for (key, settings) in jobs {
                if Task.isCancelled { break }
                let state = LookState()
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
                .padding(.top, 12)
                .padding(.bottom, 12)
            categoryBar
                .padding(.bottom, 12)
            tiles
                .padding(.bottom, 12)
            panelView
            toolRow
                .padding(.bottom, showsEffectDial ? 6 : 12)
            if showsEffectDial {
                GradeRulerDial(title: activeTool, value: dialBinding)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
            strengthRow
                .padding(.bottom, 12)
            instructionBar
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: panel)
        .animation(.easeOut(duration: 0.18), value: showsEffectDial)
        .background { Color.black.ignoresSafeArea(edges: .bottom) }
    }

    /// What the frame IS, in numbers, plus the two states that qualify it.
    private var statusLine: some View {
        HStack(spacing: 10) {
            if !hasRealMedia {
                Text("Previewing the sample photo — pick a clip to grade your own")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if let mediaReadout {
                Text(mediaReadout)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !app.batchItems.isEmpty {
                HStack(spacing: 4) {
                    Text("\(app.batchItems.count)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("clips queued")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            if app.selectedLUT?.isLogTarget == true {
                Button { showLogExplainer = true } label: {
                    HStack(spacing: 5) {
                        Circle().fill(.white.opacity(0.85)).frame(width: 5, height: 5)
                        Text("Log LUT")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
        }
        // Fixed so the drawer does not jump when the readout finishes loading.
        .frame(height: 16)
        .padding(.horizontal, 20)
    }

    /// The current category centred, its neighbours faded either side — the
    /// gesture teaches itself because you can see what you would swipe to.
    private var categoryBar: some View {
        HStack(spacing: 0) {
            categoryLabel(at: categoryIndex - 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(category.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
            categoryLabel(at: categoryIndex + 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let delta = value.translation.width < 0 ? 1 : -1
                    stepCategory(to: categoryIndex + delta)
                }
        )
    }

    private func stepCategory(to index: Int) {
        guard categories.indices.contains(index) else { return }
        withAnimation(.snappy(duration: 0.22)) { category = categories[index] }
        LumaHaptics.shared.tap()
    }

    @ViewBuilder
    private func categoryLabel(at index: Int) -> some View {
        if categories.indices.contains(index) {
            Button { stepCategory(to: index) } label: {
                Text(categories[index].title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        } else {
            Color.clear.frame(height: 1)
        }
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
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(new, anchor: .center) }
            }
            // Fixed so the drawer never jumps as categories change.
            .frame(height: Self.tile + 26)
        }
    }

    /// One shared tile geometry, so a look, a preset and the original all read
    /// as the same object at the same size.
    private func tileFrame<Content: View>(selected: Bool,
                                          @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: Self.tile, height: Self.tile)
            .clipShape(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
            // clipShape clips PIXELS, not touches: a landscape frame scaled to
            // fill a square tile overflows well past its bounds and eats its
            // neighbours' taps without this.
            .contentShape(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
                        .strokeBorder(.white, lineWidth: 2)
                }
            }
    }

    private func tileCaption(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? .white : .white.opacity(0.62))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(width: Self.tile)
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
            VStack(spacing: 7) {
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
                tileCaption("Original", selected: active)
            }
        }
        .buttonStyle(.lumaPress)
        .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 40) {
        } onPressingChanged: { pressing in
            peekOriginal(pressing)
        }
        .accessibilityLabel("Original — tap to bypass the look, hold to peek")
    }

    private func lookTile(_ look: LibraryLook) -> some View {
        let selected = app.isCurrent(look)
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                app.select(look: look)
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 7) {
                tileFrame(selected: selected) {
                    Group {
                        if let cg = thumbs.images[look.thumbKey] {
                            Image(decorative: cg, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            LumaTheme.surfaceStrong
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let badge = sourceBadge(look) {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                tileCaption(look.nameSplit.title, selected: selected)
            }
        }
        .buttonStyle(.lumaPress)
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
        let selected = app.selectedLUT == nil && app.settings == preset.settings
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                app.selectedLUT = nil
                app.settings = preset.settings
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 7) {
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
                tileCaption(preset.name, selected: selected)
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
            VStack(spacing: 7) {
                tileFrame(selected: false) {
                    LumaTheme.surface
                        .overlay {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                }
                tileCaption("All looks", selected: false)
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

    // MARK: Tool row — the number is the better icon, and it is live

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                valueTool(amount(app.settings.grain), "Grain",
                          on: app.settings.grain > 0) { selectDial("Grain") }
                valueTool(amount(app.settings.bloom), "Bloom",
                          on: app.settings.bloom > 0) { selectDial("Bloom") }
                valueTool(amount(app.settings.halation), "Halation",
                          on: app.settings.halation > 0) { selectDial("Halation") }
                valueTool(amount(app.settings.vignette), "Vignette",
                          on: app.settings.vignette > 0) { selectDial("Vignette") }
                valueTool(lensValue, "Lens", on: activeLens != .none) {
                    activeTool = "Lens"
                    panel = panel == .lens ? .none : .lens
                    LumaHaptics.shared.tap()
                }
                valueTool(sourceValue, "Source", on: hasConversion) {
                    showConversionPicker = true
                    LumaHaptics.shared.tap()
                }

                toolDivider

                tool("wand.and.stars", app.isAutoGrading ? "Working" : "Auto",
                     on: app.isAutoGrading, enabled: hasRealMedia && !app.isAutoGrading) {
                    guard hasRealMedia else { return }
                    Task { await app.autoGrade() }
                    LumaHaptics.shared.tap()
                }
                .accessibilityHint(hasRealMedia ? "Automatically grades the selected media" : "Pick a photo or video first")
                tool("eyedropper.halffull", "White bal.", on: eyedropping,
                     enabled: hasRealMedia) {
                    guard hasRealMedia else { return }
                    withAnimation(.easeOut(duration: 0.15)) { eyedropping.toggle() }
                    LumaHaptics.shared.tap()
                }
                .accessibilityHint(hasRealMedia ? "Choose a neutral point in the selected media" : "Pick a photo or video first")
                tool(isFavourite ? "star.fill" : "star",
                     isFavourite ? "Favourited" : "Favourite",
                     on: isFavourite, enabled: currentLibraryLook != nil) {
                    toggleFavourite()
                }
                tool("square.stack.3d.down.right", "Chain", on: panel == .chain) {
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
                tool("dial.high", "More", on: false) {
                    app.path.append(.customLook)
                }
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

    /// A live value in mono, its name beneath in plain sentence case. Weight and
    /// contrast do the work that tracked caps at 42% white could not.
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
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 68, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }

    /// No box, no chip, no pill — separation is by value alone. An engaged tool
    /// is simply brighter than a resting one.
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
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? .white : .white.opacity(0.5))
            .frame(width: 68, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
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

    private func selectDial(_ tool: String) {
        activeTool = tool
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
            .padding(.horizontal, 18)
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

    private var instructionBar: some View {
        let name = app.selectedLUT?.displayName ?? app.selectedLook.name
        let strength = Int(app.settings.intensity.rounded())
        return ZStack {
            // Centred absolutely rather than between two unequal buttons, so
            // the statement sits on the optical middle of the bar.
            Group {
                if strength == 0 {
                    Text("Showing the original")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text("\(strength)%")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 104)
            .allowsHitTesting(false)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Close the grade room")
                Spacer(minLength: 0)
                applyButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// The one filled button on the screen. Apply is never disabled: the
    /// current look at the current strength is always a valid answer.
    private var applyButton: some View {
        Button { applyAndAdvance() } label: {
            Text("Apply")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .frame(height: 40)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.lumaPress)
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
                    .fill(LumaTheme.surface)
                    .frame(width: 68, height: 50)
                    .overlay {
                        Image(systemName: lens.icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(selected ? .white : .white.opacity(0.6))
                    }
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white, lineWidth: 2)
                        }
                    }
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
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Reading the graded frame")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Button {
                    scopeModeRaw = scopeMode.next.rawValue
                    LumaHaptics.shared.tap()
                } label: {
                    Text("Next scope")
                        .font(.system(size: 12, weight: .medium))
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
                         name: app.selectedLUT?.displayName ?? app.selectedLook.name,
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
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
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
                                .font(.system(size: 13, weight: .semibold))
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
            pickerHeading("Conversion LUT — applied first")
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
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 22)
    }

    private func pickerRow(name: String, tag: String?, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? .white : .white.opacity(0.35))
            Text(name)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let tag {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
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
    @Binding var opacity: Double
    let isActive: Bool
    let onTap: () -> Void

    @State private var dragStart: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 52, alignment: .leading)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? .white.opacity(0.95) : .white.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                // An empty slot has no strength to report — an em dash matches
                // the empty track and the dimmed "None" title.
                Text(isActive ? "\(Int(opacity.rounded()))%" : "—")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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
}

// MARK: - Ruler dial

/// Precision dial in the monochrome voice: a tick ruler slides under a fixed
/// centre indicator, every 5-unit detent ticks. The name is a name; only the
/// value is mono. Range matches the engine exactly (0…100 → /100), so there is
/// no dead travel at either end.
private struct GradeRulerDial: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100

    @State private var dragStartValue: Double?
    private let pointsPerUnit: CGFloat = 4.5
    private var detent: Int { Int(value / 5) }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: Int(value))
                    .foregroundStyle(.white)
            }
            ZStack {
                ruler
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 22)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if dragStartValue == nil { dragStartValue = value }
                        let delta = Double(-drag.translation.width / pointsPerUnit)
                        value = min(max(range.lowerBound, (dragStartValue ?? value) + delta),
                                    range.upperBound)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            .sensoryFeedback(.selection, trigger: detent)
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value.rounded()))")
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            value = min(max(range.lowerBound, value + step), range.upperBound)
        }
    }

    /// Tick ruler that slides with the value: major tick every 10 units, minor
    /// every 2, fading at the edges.
    private var ruler: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let unitsVisible = size.width / pointsPerUnit
            let first = max(range.lowerBound, value - Double(unitsVisible / 2) - 2)
            let last = min(range.upperBound, value + Double(unitsVisible / 2) + 2)
            var unit = (first / 2).rounded(.down) * 2
            while unit <= last {
                let x = centerX + CGFloat(unit - value) * pointsPerUnit
                let isMajor = Int(unit) % 10 == 0
                let height: CGFloat = isMajor ? 16 : 8
                let edgeFade = 1 - abs(x - centerX) / centerX
                context.fill(
                    Path(CGRect(x: x - 0.5, y: (size.height - height) / 2,
                                width: 1, height: height)),
                    with: .color(.white.opacity((isMajor ? 0.5 : 0.22) * Double(edgeFade)))
                )
                unit += 2
            }
        }
        .allowsHitTesting(false)
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
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.5), in: Capsule())
                                .padding(6)
                        }
                    }
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
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
/// both. Label in the system font, value in mono — it is a number.
struct GradeOpacityRow: View {
    var title: String = "Strength"
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100

    // Same 5-unit detents as the ruler dial, so the two feel like one control.
    private var detent: Int { Int(value / 5) }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 58, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(.white.opacity(0.85))
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: Int(value))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, alignment: .trailing)
        }
        .sensoryFeedback(.selection, trigger: detent)
    }
}

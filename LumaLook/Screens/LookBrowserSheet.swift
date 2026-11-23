import SwiftUI
import UniformTypeIdentifiers

// =============================================================================
// LookBrowserSheet — THE one reusable look browser (steps 4–6 of the unified
// Look Library migration). Presented identically from the grade room, the
// camera, and the editor via .lumaToolSheet, and hosted full-screen as the
// Looks tab. Two-axis category bar + folded search + 3-up grid + favourite
// stars + intensity footer, all reading LookLibraryStore and applying through
// AppModel.select(look:).
// =============================================================================

/// Where a selection routes; drives select(look:) vs select(look:forClip:).
enum LookBrowserContext: Equatable {
    case grade            // ApplyLookView / global grade state
    case camera           // live camera preview
    case editorTimeline   // timeline-wide grade
    case editorClip(UUID) // per-clip ClipGrade
    case library          // Looks tab: select, then route into a grade flow
}

// MARK: - Name splitting (shared by every look tile)

extension LibraryLook {
    /// Library names follow "CODE · Descriptive Name", which is systematically
    /// wider than one grid column or strip tile — so the differentiating half
    /// is the half that truncates ("KD52 · Cine N…"). Split the code off so
    /// the descriptive half owns the label and the code rides the subtitle or
    /// the badge. One helper, so the grid and the strip can never disagree.
    var nameSplit: (title: String, code: String?) {
        let parts = name.components(separatedBy: " · ")
        guard parts.count == 2,
              let code = parts.first, let rest = parts.last,
              code.count <= 6, !code.contains(" "), !rest.isEmpty
        else { return (name, nil) }
        return (rest, code)
    }
}

// MARK: - Looks tab shelves

/// The Looks tab's shelves (Night Lab): For you (recently used, favourites
/// and picks), three families, the user's own looks, and the packs that used
/// to live in a separate Store.
enum LooksShelf: String, CaseIterable, Identifiable {
    case forYou, film, night, pro, mine, packs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .forYou: return "For you"
        case .film:   return "Film"
        case .night:  return "Night"
        case .pro:    return "Pro"
        case .mine:   return "Mine"
        case .packs:  return "Packs"
        }
    }

    /// Heading over the rail of packs on this shelf.
    var railTitle: String {
        switch self {
        case .film:  return "More film in packs"
        case .night: return "More night in packs"
        case .pro:   return "Pro packs"
        default:     return "Packs"
        }
    }

    /// The packs that belong on this shelf, newest first.
    func shelfPacks(from catalog: [LookPack]) -> [LookPack] {
        let ordered = catalog.filter { $0.isNew } + catalog.filter { !$0.isNew }
        switch self {
        case .forYou, .packs: return ordered
        case .film:  return ordered.filter { LooksShelf.isFilmPack($0) }
        case .night: return ordered.filter { LooksShelf.isNightPack($0) }
        case .pro:   return ordered.filter { LooksShelf.isProPack($0) }
        case .mine:  return []
        }
    }

    /// Film stocks: colour negative, slide, measured film, mono and instant.
    static func isFilmPack(_ pack: LookPack) -> Bool {
        StoreCategory.film.contains(pack) || StoreCategory.mono.contains(pack)
            || StoreCategory.instant.contains(pack)
    }

    /// Pro: the packs that come with Pro, cinema prints and camera profiles.
    static func isProPack(_ pack: LookPack) -> Bool {
        pack.isProIncluded || StoreCategory.cinema.contains(pack)
            || StoreCategory.camera.contains(pack)
    }

    /// A night pack: at least two of its looks, and two in five, are night looks.
    static func isNightPack(_ pack: LookPack) -> Bool {
        let night = pack.looks.filter { LibraryLook.isNightName($0.name) }.count
        return night >= 2 && night * 5 >= pack.looks.count * 2
    }
}

extension LibraryLook {
    private static let nightWords = ["neon", "night", "drive", "dark", "club", "flash",
                                     "party", "afrobeats", "cyber", "noir", "evening",
                                     "midnight", "tungsten", "sodium"]

    /// Night, neon and flash looks, read from the name.
    static func isNightName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return nightWords.contains { lower.contains($0) }
    }

    /// The catalog pack this look was installed from, if any.
    var sourcePack: LookPack? {
        guard case .lut(let file) = source, let id = file.packID else { return nil }
        return PackCatalog.pack(id: id)
    }

    /// Looks for the Night shelf: night, neon and flash looks, and every look
    /// in After Dark.
    var isNightLook: Bool {
        switch source {
        case .builtIn: return Self.isNightName(name)
        case .lut: return Self.isNightName(name) || sourcePack?.id == "after-dark"
        case .saved: return false
        }
    }

    /// Looks for the Film shelf: the film-stock looks.
    var isFilmLook: Bool {
        switch source {
        case .builtIn(let preset):
            return preset.category == "Negative" || preset.category == "Slide"
                || preset.category == "B&W"
        case .lut:
            guard let pack = sourcePack else { return false }
            return LooksShelf.isFilmPack(pack)
        case .saved:
            return false
        }
    }

    /// Looks for the Pro shelf: LUTs, log conversions, cinema looks and the
    /// looks from pro packs.
    var isProLook: Bool {
        switch source {
        case .builtIn(let preset):
            return preset.category == "Cine"
        case .lut(let file):
            // Imports and the factory LUTs are the pro tools themselves.
            guard let id = file.packID, id != LUTRepository.bundledBasicsPackID,
                  let pack = PackCatalog.pack(id: id) else { return true }
            return LooksShelf.isProPack(pack)
        case .saved:
            return false
        }
    }

    /// Looks for the Mine shelf: saved looks and imports.
    var isMine: Bool {
        switch source {
        case .saved: return true
        case .lut(let file): return file.packID == nil
        case .builtIn: return false
        }
    }

    /// The short word in a poster's corner (Free, Night, Film, Cine, Yours).
    var posterTag: String {
        switch source {
        case .saved:
            return "Yours"
        case .lut(let file):
            guard let pack = sourcePack else { return file.isLogTarget ? "Log" : "LUT" }
            if isNightLook { return "Night" }
            let family = StoreCategory.allCases.first { $0 != .all && $0 != .free && $0.contains(pack) }
            return family?.title ?? "Pack"
        case .builtIn(let preset):
            if isNightLook { return "Night" }
            switch preset.category {
            case "Cine": return "Cine"
            case "B&W":  return "Mono"
            default:     return preset.isPremium ? "Film" : "Free"
            }
        }
    }
}

// MARK: - Bottom edge fade

private extension View {
    /// Vertical sibling of `.lumaEdgeFade()` for the look grid: a scrolling
    /// grid that butts against a pinned footer must fade out, never present a
    /// razor cut through the middle of a caption.
    func lookGridBottomFade(_ height: CGFloat = 28) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
            }
        }
    }
}

// MARK: - Selection truth

extension AppModel {
    /// The ONE "is this look currently applied globally?" check — every strip
    /// and grid derives its highlight from this, so a LUT and a built-in can
    /// never read as selected at the same time (camera double-highlight bug).
    func isCurrent(_ look: LibraryLook) -> Bool {
        switch look.source {
        case .builtIn(let p): return selectedLUT == nil && selectedLook.name == p.name
        case .lut(let f):     return selectedLUT?.id == f.id
        case .saved(let s):
            return selectedLook.name == s.baseLookName
                && selectedLUT?.id == s.lutID && settings == s.settings
        }
    }
}

// MARK: - The browser

// =============================================================================
// THE DESIGN LANGUAGE, APPLIED HERE
//   1. The image is the interface. Full-screen hosting (the Looks tab) leads
//      with the live grade, uncovered, and puts every control in the drawer
//      beneath it. In the three SHEET contexts the image is the canvas the
//      sheet is docked over, so the sheet stays a drawer and draws nothing on
//      top of it.
//   2. Monochrome chrome — black, near-black, white, grey. The only colour on
//      this screen lives inside the tiles, which is where looks belong.
//   3. Stroke means selection and nothing else: one thin white ring.
//   4. The tile IS the preview — every tile is the real grade of the real frame.
//   5. Two-axis browsing — the current category centred, neighbours faded
//      either side, swipeable, so the gesture teaches itself.
//   6. Mono is for NUMBERS ONLY. Counts and strengths keep the instrument
//      voice; names, categories, headings, badges and buttons are the system
//      face in sentence case.
//   7. Prefer a live value over a glyph (see the camera drawer's value tools).
//
// WHAT COMPACT MODE STILL OWES THE HALF-SHEET
// The same view is hosted at ~340 pt (grade / camera), ~620 pt (editor) and
// full screen (Looks tab). Compact keeps its whole budget: folded search, a
// SOLVED tile height so exactly two complete named rows fit, one-line names
// and a single-row footer. The sheet confirms with Done in its header.
//
// THE LOOKS TAB (Night Lab)
// Full screen is its own layout: title, shelf pills (For you, Film, Night,
// Pro, Mine, Packs) and a clean two-column grid of posters, each look graded
// on its own bundled person. Packs from the old Store sit in a rail and on
// their own shelf. Nothing floats over the grid.
// =============================================================================

struct LookBrowserSheet: View {
    let context: LookBrowserContext
    /// Intensity of the APPLIED look; nil hides the footer slider.
    var intensity: Binding<Double>? = nil
    /// Full-screen hosting (Looks tab): adds the Create New Look door.
    var showsCreateCTA: Bool = false
    /// Full-screen hosting via a pushed route: leading back chevron.
    var showsBackButton: Bool = false

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()
    @State private var category: LookLibraryStore.Category = .all
    @State private var search = ""
    @State private var renameLUT: LUTFile?
    @State private var renameText = ""
    @State private var noneStashedIntensity: Double?
    @State private var compareStashedIntensity: Double?
    /// Height the presentation actually gave us (detent height minus safe
    /// area), measured rather than assumed — the same view is hosted at
    /// ~340 pt, ~620 pt and full screen.
    @State private var panelHeight: CGFloat = 0
    /// Height the scrolling grid ended up with, which is what the compact
    /// tile size is solved against.
    @State private var gridHeight: CGFloat = 0
    /// The search field is folded behind a glyph in every context.
    @State private var searchExpanded = false
    /// Full-screen hosting only: the live grade on the hero, rendered once per
    /// look change rather than on every keystroke.
    @State private var heroImage: CGImage?
    /// Looks tab only: the shelf on show.
    @State private var shelf: LooksShelf = {
        #if DEBUG
        // LUMA_SEED_LOOKSHELF=forYou|film|night|pro|mine|packs opens the
        // Looks tab on that shelf, for preview screenshots.
        if let raw = ProcessInfo.processInfo.environment["LUMA_SEED_LOOKSHELF"],
           let seeded = LooksShelf(rawValue: raw) { return seeded }
        #endif
        return .forYou
    }()
    /// Looks tab only: pack covers, each pack's people in its lead look.
    @StateObject private var packThumbs = PackThumbs()

    /// Square tiles mean the COLUMN COUNT carries the density difference
    /// between the half-sheet and the full screen, instead of the tile shape.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: compact ? 4 : (isSheet ? 3 : 2))
    }

    private var categories: [LookLibraryStore.Category] { LookLibraryStore.Category.allCases }
    private var categoryIndex: Int { categories.firstIndex(of: category) ?? 0 }

    private var visibleLooks: [LibraryLook] {
        app.library.looks(category: category, search: search)
    }

    /// The half-sheet detent (~340 pt) cannot carry the full-size stack: header
    /// readout + search field + category bar + a 96 pt thumb with a two-line
    /// name + a two-row footer overflows it, so the grid used to be sliced
    /// through the middle of the thumbnails with not one look name left
    /// readable. Compact mode spends that budget differently — folded search,
    /// no header readout, one-row footer, one-line names — and then *solves*
    /// the tile height so exactly two complete named rows fit (A2).
    private var compact: Bool { isSheet && panelHeight > 0 && panelHeight < 470 }

    private var rowSpacing: CGFloat { compact ? 8 : 14 }

    /// True when this browser is presented as a half-sheet over a live canvas
    /// (grade / camera / editor) rather than hosted full-screen as the Looks tab.
    private var isSheet: Bool { context != .library }

    /// Hero height for full-screen hosting. Capped so a small phone still gets
    /// a usable grid under it.
    private var heroHeight: CGFloat {
        guard panelHeight > 0 else { return 210 }
        return max(132, min(210, panelHeight * 0.27))
    }

    var body: some View {
        GeometryReader { geo in
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onChange(of: geo.size.height, initial: true) { _, height in
                    panelHeight = height
                }
        }
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.library.all.count)") {
            // The sheets keep grading the user's own frame. The Looks tab
            // grades every look on its own person, tile by tile, as the tiles
            // scroll in (LookPosterArt); here it only renders the pack covers.
            if isSheet {
                thumbs.render(source: app.previewFrame, library: app.library.all,
                              fileURL: { app.lutRepository.fileURL(for: $0) })
            } else {
                packThumbs.render(packs: PackCatalog.packs, source: nil, maxDimension: 720)
            }
        }
        .alert("Rename LUT", isPresented: Binding(
            get: { renameLUT != nil },
            set: { if !$0 { renameLUT = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let lut = renameLUT {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { app.lutRepository.rename(lut, to: name) }
                }
                renameLUT = nil
            }
            Button("Cancel", role: .cancel) { renameLUT = nil }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Full screen only: as a sheet, the strip behind would reshuffle.
            if context == .library { app.library.settleOrder() }
            consumePackFilter()
        }
        // The Looks tab stays mounted under a pushed store, so a hand-off
        // that arrives while it is already on screen is caught here.
        .onChange(of: app.libraryPackFilter) { _, _ in
            consumePackFilter()
        }
    }

    /// Store → Library hand-off (F1): an owned pack tapped in the store lands
    /// here already filtered to that pack. Consumed once.
    private func consumePackFilter() {
        guard let packName = app.libraryPackFilter else { return }
        app.libraryPackFilter = nil
        if isSheet {
            category = .purchased
        } else if shelf == .packs {
            shelf = .forYou
        }
        search = packName
        // The field is folded away by default; a filter arriving from the
        // store has to be visible and clearable.
        searchExpanded = true
    }

    /// Everything that actually changes the hero pixels. Deliberately does NOT
    /// include `search`.
    private var heroKey: String {
        "\(app.selectedLook.name)-\(String(describing: app.selectedLUT?.id))-\(Int(app.settings.intensity))-\(app.previewFrame?.extent.debugDescription ?? "none")"
    }

    private var panel: some View {
        drawer
    }

    // MARK: Media — the live grade, uncovered (full-screen hosting only)

    private var media: some View {
        GeometryReader { geo in
            Group {
                if let heroImage {
                    Image(decorative: heroImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.08)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // clipShape clips PIXELS not touches: a scaledToFill image
            // overflows its frame and the invisible remainder steals taps from
            // the drawer beneath. Confine the touch region.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: Drawer — everything that is not the image

    @ViewBuilder
    private var drawer: some View {
        if isSheet {
            sheetDrawer
        } else {
            libraryDrawer
        }
    }

    private var sheetDrawer: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, compact ? 10 : 14)
                .padding(.bottom, compact ? 10 : 12)
            categoryBar
                .padding(.bottom, compact ? 10 : 12)
            if searchExpanded {
                searchField
                    .padding(.bottom, compact ? 8 : 12)
            }
            grid
            footer
        }
        // Dragging the sheet up past the compact threshold restores the
        // subtitle and the full-size tiles — as a settle, not a snap.
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: compact)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searchExpanded)
    }

    /// The Looks tab (Night Lab): title, shelves, and a clean grid of posters
    /// all the way down. Nothing floats over the grid.
    private var libraryDrawer: some View {
        VStack(spacing: 0) {
            Group {
                if showsBackButton {
                    pageHeader
                } else {
                    // The tab's one row: Looks, then Pro and You. Search is
                    // the first shelf pill; New look and import are in Mine.
                    LumaTopBar(title: "Looks")
                }
            }
            .padding(.top, LumaTabMetrics.top)
            .padding(.bottom, 12)
            shelfPills
                .padding(.bottom, 14)
            if searchExpanded {
                searchField
                    .padding(.bottom, 12)
            }
            libraryScroll
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searchExpanded)
    }

    // MARK: Header

    /// A count is one instrument value and one plain word. The digits are the
    /// only part that earns mono; "looks" is not a readout.
    private func countText(_ value: Int, _ word: String, size: CGFloat) -> Text {
        Text("\(value)")
            .font(.luma(size: size, weight: .medium, design: .monospaced))
        + Text(" \(word)")
            .font(.luma(size: size, weight: .medium))
    }

    private var totals: Text {
        countText(app.library.all.count, "looks", size: 12)
            + Text(" · ").font(.luma(size: 12, weight: .medium))
            + countText(app.lutRepository.collections.count, "collections", size: 12)
    }

    /// Looks pushed from another screen (not the tab): the back arrow and the
    /// title, with search, import and new look as plain glyphs.
    private var pageHeader: some View {
        LumaTabHeader {
            HStack(spacing: 8) {
                if showsBackButton {
                    BackArrow()
                }
                LumaTabTitle(text: "Looks")
            }
        } trailing: {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    searchExpanded.toggle()
                    if !searchExpanded { search = "" }
                }
                LumaHaptics.shared.tap()
            } label: {
                LumaTabGlyph(systemName: searchExpanded ? "xmark" : "magnifyingglass",
                             active: searchExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchExpanded ? "Close search" : "Search looks")

            LUTImportButton { imported in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    select(LibraryLook(lut: imported), navigate: false)
                }
            } label: {
                LumaTabGlyph(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Import a LUT")

            if showsCreateCTA {
                // New look lives up here (and first in Mine), never floating
                // over the grid.
                Button {
                    app.path.append(.customLook)
                    LumaHaptics.shared.tap()
                } label: {
                    LumaTabGlyph(systemName: "plus")
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Create a new look")
            }
        }
    }

    /// Looks tab: the shelves as pills, the current one filled white. On the
    /// tab, search leads the row as a round pill (its header has no glyphs).
    private var shelfPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !showsBackButton {
                    searchPill
                }
                ForEach(LooksShelf.allCases) { item in
                    shelfPill(item)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Opens and closes the search field under the pills; white while open.
    private var searchPill: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                searchExpanded.toggle()
                if !searchExpanded { search = "" }
            }
            LumaHaptics.shared.tap()
        } label: {
            Image(systemName: searchExpanded ? "xmark" : "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(searchExpanded ? LumaTheme.onLight : LumaTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(searchExpanded ? LumaTheme.textPrimary : LumaTheme.chip, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(searchExpanded ? "Close search" : "Search looks")
    }

    private func shelfPill(_ item: LooksShelf) -> some View {
        let on = item == shelf
        return Button {
            withAnimation(.snappy(duration: 0.22)) { shelf = item }
            LumaHaptics.shared.tap()
        } label: {
            Text(item.title)
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(on ? LumaTheme.onLight : LumaTheme.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(on ? LumaTheme.textPrimary : LumaTheme.chip, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? LumaTheme.textPrimary : LumaTheme.edge,
                                                lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showsBackButton {
                BackArrow()
            }
            if isSheet {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looks")
                        .font(.luma(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    if !compact {
                        totals
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            } else {
                // Full screen: the tab bar already says "Looks", so the header
                // spends its line on the number that grows instead.
                totals
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    searchExpanded.toggle()
                    if !searchExpanded { search = "" }
                }
                LumaHaptics.shared.tap()
            } label: {
                glyph(searchExpanded ? "xmark" : "magnifyingglass", active: searchExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchExpanded ? "Close search" : "Search looks")

            LUTImportButton { imported in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    select(LibraryLook(lut: imported), navigate: false)
                }
            } label: {
                // A bare "+" reads as "create". Importing a .cube is a file
                // coming IN, and this glyph actually depicts that.
                glyph("square.and.arrow.down", active: false)
            }
            .accessibilityLabel("Import a LUT")

            if isSheet {
                // A2: the sheet must have a visible way out. `undimmedUpThrough`
                // is below the detent this opens at, so tapping the preview
                // behind does nothing — Done is the only discoverable exit.
                Button {
                    openLibrary()
                } label: {
                    Text("Open library")
                        .font(.luma(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                Button {
                    LumaHaptics.shared.tap()
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.luma(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private func glyph(_ name: String, active: Bool) -> some View {
        let side: CGFloat = compact ? 30 : 34
        return Image(systemName: name)
            .font(.system(size: compact ? 13 : 14, weight: .medium))
            .foregroundStyle(active ? LumaTheme.onLight : LumaTheme.textSecondary)
            .frame(width: side, height: side)
            .background {
                Circle().fill(active ? AnyShapeStyle(LumaTheme.textPrimary) : AnyShapeStyle(LumaTheme.raised))
            }
            .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: active ? 0 : 1))
    }

    /// Leave the sheet for the full Looks library. The push has to wait for the
    /// dismissal, otherwise the new screen lands *behind* the sheet.
    private func openLibrary() {
        LumaHaptics.shared.tap()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            app.path.append(.savedLooks)
        }
    }

    // MARK: Category bar — two-axis browsing

    /// The chip titles carry a "★ " prefix for the accented design. On a
    /// monochrome screen the star is noise — the bar spells the name out.
    private func title(_ cat: LookLibraryStore.Category) -> String {
        cat.title.replacingOccurrences(of: "★ ", with: "")
    }

    private func count(of cat: LookLibraryStore.Category) -> Int {
        cat == .collections ? app.lutRepository.collections.count
                            : app.library.looks(category: cat).count
    }

    /// The current category centred with its neighbours faded either side, so
    /// the swipe teaches itself. The count rides underneath in mono, which is
    /// where the chip row's count badge went.
    private var categoryBar: some View {
        VStack(spacing: compact ? 2 : 4) {
            HStack(spacing: 0) {
                neighbour(at: categoryIndex - 1, alignment: .leading)
                Text(title(categories[categoryIndex]))
                    .font(.luma(size: compact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 10)
                neighbour(at: categoryIndex + 1, alignment: .trailing)
            }
            countText(count(of: category),
                      category == .collections ? "collections" : "looks",
                      size: compact ? 11 : 12)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        // Simultaneous, and horizontal-only: inside a sheet a plain .gesture
        // here would swallow the vertical drag the detents are steered with.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    step(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    @ViewBuilder
    private func neighbour(at index: Int, alignment: Alignment) -> some View {
        if categories.indices.contains(index) {
            Button {
                step(index - categoryIndex)
            } label: {
                Text(title(categories[index]))
                    .font(.luma(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(height: 1).frame(maxWidth: .infinity)
        }
    }

    private func step(_ delta: Int) {
        let next = categoryIndex + delta
        guard categories.indices.contains(next) else { return }
        withAnimation(.snappy(duration: 0.22)) { category = categories[next] }
        LumaHaptics.shared.tap()
    }

    // MARK: Search — folded away until asked for

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
            TextField("Search looks, packs, tags…", text: $search)
                .font(.luma(size: 15))
                .foregroundStyle(.white)
                .tint(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: compact ? 34 : 38)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            if category == .collections {
                collectionsBody
            } else {
                LazyVGrid(columns: columns, spacing: isSheet ? rowSpacing : 10) {
                    if isSheet, search.isEmpty, category == .all || category == .recents {
                        noneTile
                    }
                    ForEach(visibleLooks) { look in
                        tile(for: look)
                    }
                }
                .padding(.horizontal, isSheet ? 20 : 16)
                // Clears the pinned footer by more than one caption block, so
                // a partly-scrolled row degrades into the fade below rather
                // than being sliced through its own text.
                .padding(.bottom, compact ? 18 : 44)

                if visibleLooks.isEmpty {
                    emptyState
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background {
            // The tile size is solved against the height the grid actually
            // got, so no detent can ever hand it half a row.
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.height, initial: true) { _, height in
                        gridHeight = height
                    }
            }
        }
        .lookGridBottomFade(compact ? 18 : 28)
    }

    @ViewBuilder
    private var collectionsBody: some View {
        let matchingIDs = Set(visibleLooks.map(\.id))
        let groups = app.library.collectionGroups.compactMap { group in
            guard !search.isEmpty else { return group }
            let matches = group.looks.filter { matchingIDs.contains($0.id) }
            return matches.isEmpty ? nil : (collection: group.collection, looks: matches)
        }
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            // Manage only from the full-screen Looks tab: from a sheet a push
            // would land behind the sheet, which would be a dead tap.
            if context == .library {
                HStack {
                    // A section heading should read as a heading.
                    Text("Collections")
                        .font(.luma(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Spacer()
                    Button {
                        app.path.append(.collections)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text("Manage")
                            .font(.luma(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups, id: \.collection.id) { group in
                    let groupPhotos = posterPhotos(for: group.looks)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            // The collection's name is a name; only its size
                            // is a number.
                            Text(group.collection.name)
                                .font(.luma(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Text("\(group.looks.count)")
                                .font(.luma(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            if group.collection.pinnedToCamera == true {
                                Text("Pinned")
                                    .font(.luma(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Color(white: 0.16), in: Capsule())
                            }
                        }
                        if group.looks.isEmpty {
                            Text("Long-press any look to add it here.")
                                .font(.luma(size: 13))
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            LazyVGrid(columns: columns, spacing: rowSpacing) {
                                ForEach(group.looks) { look in
                                    tile(for: look, photo: groupPhotos[look.id])
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, compact ? 18 : 44)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(search.isEmpty ? "Nothing here yet" : "No looks match “\(search)”")
                .font(.luma(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            if !compact {
                Text(search.isEmpty ? "Import a .cube or buy a pack to fill this shelf."
                                    : "Try a pack name, a look code, or a tag.")
                    .font(.luma(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 26 : 44)
    }

    @ViewBuilder
    private func tile(for look: LibraryLook, photo: HeroPhoto? = nil) -> some View {
        if isSheet {
            sheetTile(for: look)
        } else {
            posterTile(for: look,
                       photo: photo ?? LookPhotos.preferred(forName: photoName(look))
                           ?? LookPhotos.stable(forKey: look.id))
        }
    }

    /// A Looks tab poster: the look graded on its own person.
    private func posterTile(for look: LibraryLook, photo: HeroPhoto) -> some View {
        LookPosterTile(look: look,
                       job: posterJob(for: look),
                       photo: photo,
                       selected: isSelected(look),
                       isFavourite: app.library.isFavourite(look.id),
                       locked: storeService.isLocked(look)) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                select(look, navigate: true)
            }
            LumaHaptics.shared.tap()
        } onFavourite: {
            app.library.toggleFavourite(look)
            LumaHaptics.shared.tap()
        }
        .contextMenu { contextMenu(for: look) }
    }

    private func sheetTile(for look: LibraryLook) -> some View {
        LookTile(look: look,
                 image: thumbs.images[look.thumbKey],
                 selected: isSelected(look),
                 isFavourite: app.library.isFavourite(look.id),
                 compact: compact,
                 locked: storeService.isLocked(look)) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                select(look, navigate: true)
            }
            LumaHaptics.shared.tap()
        } onFavourite: {
            app.library.toggleFavourite(look)
            LumaHaptics.shared.tap()
        }
        .contextMenu { contextMenu(for: look) }
    }

    /// None / Off leads the grid — clearing a look is as easy as applying one.
    /// Dashed, because it is the one tile that has no image.
    private var noneTile: some View {
        let active = noneActive
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { tapNone() }
            LumaHaptics.shared.tap()
        } label: {
            // Same skeleton as LookTile — leading alignment, the fixed caption
            // box and a subtitle line — so the first grid row shares one
            // baseline instead of centring the shorter cell.
            VStack(alignment: .leading, spacing: compact ? LookTile.compactSpacing : 7) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.07))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Text(context == .camera ? "Off" : "None")
                            .font(.luma(size: compact ? 12 : 14, weight: .semibold))
                            .foregroundStyle(active ? .white : .white.opacity(0.55))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]))
                            .foregroundStyle(active ? .white : .white.opacity(0.18))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Original")
                        .font(.luma(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? .white : .white.opacity(0.72))
                        .lineLimit(compact ? 1 : 2)
                        .frame(height: compact ? LookTile.compactCaptionHeight : 32,
                               alignment: .top)
                    if !compact {
                        Text("No look")
                            .font(.luma(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.lumaPress)
    }

    private var noneActive: Bool {
        if case .editorClip(let id) = context {
            return app.editor.clips.first(where: { $0.id == id })?.grade == nil
        }
        return app.settings.intensity == 0
    }

    private func tapNone() {
        if case .editorClip(let id) = context {
            app.editor.setClipGrade(id: id, nil)
            return
        }
        if app.settings.intensity == 0 {
            app.settings.intensity = noneStashedIntensity ?? 75
            noneStashedIntensity = nil
        } else {
            noneStashedIntensity = app.settings.intensity
            app.settings.intensity = 0
        }
    }

    @ViewBuilder
    private func contextMenu(for look: LibraryLook) -> some View {
        Button {
            app.library.toggleFavourite(look)
        } label: {
            Label(app.library.isFavourite(look.id) ? "Unfavourite" : "Favourite",
                  systemImage: app.library.isFavourite(look.id) ? "star.slash" : "star")
        }
        // Any library look can belong to a collection since G3, not just LUTs.
        if !app.lutRepository.collections.isEmpty {
            Menu {
                ForEach(app.lutRepository.collections) { collection in
                    let isIn = app.lutRepository.contains(lookID: look.id, in: collection.id)
                    Button {
                        app.lutRepository.toggleLook(id: look.id, in: collection.id)
                    } label: {
                        Label(collection.name,
                              systemImage: isIn ? "checkmark.circle.fill" : "folder")
                    }
                }
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
            }
        }
        if case .lut(let f) = look.source {
            if f.packID == nil {
                Button {
                    renameText = f.displayName
                    renameLUT = f
                } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) {
                    app.lutRepository.delete(f)
                } label: { Label("Delete", systemImage: "trash") }
            } else if f.packID != LUTRepository.bundledBasicsPackID {
                Button {
                    app.selectedPackID = f.packID
                    app.path.append(.filterPack)
                } label: { Label("View Pack…", systemImage: "square.grid.2x2") }
            }
        }
        if case .saved(let s) = look.source {
            Button(role: .destructive) {
                app.store.deleteLook(s.id)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: Looks tab — shelves, posters and packs

    private var posterColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
    }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var libraryScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                libraryContent
            }
            .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
        .scrollDismissesKeyboard(.immediately)
        // The last row fades into the tab bar instead of being cut by it.
        .lookGridBottomFade(22)
    }

    @ViewBuilder
    private var libraryContent: some View {
        if shelf == .packs {
            packsShelf
        } else if !trimmedSearch.isEmpty {
            searchResults
        } else if shelf == .forYou {
            forYouShelf
        } else if shelf == .mine {
            mineShelf
        } else {
            familyShelf
        }
    }

    /// Two rows of looks, then the packs (the store, folded in), then the
    /// rest of the looks. The first screen reads as looks; the packs peek.
    @ViewBuilder
    private var forYouShelf: some View {
        let looks = shelfLooks(.forYou)
        let photos = posterPhotos(for: looks)
        posterGrid(Array(looks.prefix(4)), photos: photos)
        packRail(for: .forYou)
        posterGrid(Array(looks.dropFirst(4)), photos: photos)
    }

    /// Film, Night and Pro: their looks, then the packs with more of them.
    @ViewBuilder
    private var familyShelf: some View {
        let looks = shelfLooks(shelf)
        if looks.isEmpty {
            emptyState
        } else {
            posterGrid(looks, photos: posterPhotos(for: looks))
        }
        packRail(for: shelf)
    }

    /// Saved looks and imports, led by New look, then collections.
    @ViewBuilder
    private var mineShelf: some View {
        let looks = shelfLooks(.mine)
        posterGrid(looks, photos: posterPhotos(for: looks), leadingNewLook: showsCreateCTA)
        if looks.isEmpty {
            Text("Looks you save and LUTs you import live here.")
                .font(.luma(size: 13))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.horizontal, 16)
                .padding(.top, 4)
        }
        // Import lives here on the tab, next to the LUTs it brings in.
        LUTImportButton { imported in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                select(LibraryLook(lut: imported), navigate: false)
            }
        } label: {
            linkRow(symbol: "square.and.arrow.down",
                    title: "Import a LUT",
                    detail: "A .cube file from Files")
        }
        .accessibilityLabel("Import a LUT")
        .padding(.horizontal, 16)
        .padding(.top, 18)
        mineCollections
            .padding(.top, 10)
    }

    @ViewBuilder
    private var mineCollections: some View {
        if app.lutRepository.collections.isEmpty {
            Button {
                app.path.append(.collections)
                LumaHaptics.shared.tap()
            } label: {
                linkRow(symbol: "square.stack",
                        title: "Collections",
                        detail: "Group the looks you shoot with")
            }
            .buttonStyle(.lumaPress)
            .padding(.horizontal, 16)
        } else {
            collectionsBody
        }
    }

    /// Search covers the whole library, whatever the shelf.
    @ViewBuilder
    private var searchResults: some View {
        let looks = app.library.looks(category: .all, search: search)
        if looks.isEmpty {
            emptyState
        } else {
            countText(looks.count, looks.count == 1 ? "look" : "looks", size: 12)
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            posterGrid(looks, photos: posterPhotos(for: looks))
        }
    }

    /// Every pack as a cover, then the door to the full store.
    @ViewBuilder
    private var packsShelf: some View {
        let packs = searchedPacks
        if packs.isEmpty {
            Text("No packs match “\(trimmedSearch)”")
                .font(.luma(size: 15, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            LazyVGrid(columns: posterColumns, spacing: 10) {
                ForEach(packs) { pack in
                    packCover(pack)
                }
            }
            .padding(.horizontal, 16)
        }
        Button {
            app.path.append(.filterStore)
            LumaHaptics.shared.tap()
        } label: {
            linkRow(symbol: "bag",
                    title: "Browse the store",
                    detail: "Search every pack and restore purchases")
        }
        .buttonStyle(.lumaPress)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var searchedPacks: [LookPack] {
        let all = LooksShelf.packs.shelfPacks(from: PackCatalog.packs)
        let needle = trimmedSearch.lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { pack in
            pack.name.lowercased().contains(needle)
                || pack.eraTag.lowercased().contains(needle)
                || pack.looks.contains { $0.name.lowercased().contains(needle) }
        }
    }

    @ViewBuilder
    private func posterGrid(_ looks: [LibraryLook], photos: [String: HeroPhoto],
                            leadingNewLook: Bool = false) -> some View {
        if !looks.isEmpty || leadingNewLook {
            LazyVGrid(columns: posterColumns, spacing: 10) {
                if leadingNewLook {
                    NewLookTile {
                        app.path.append(.customLook)
                        LumaHaptics.shared.tap()
                    }
                }
                ForEach(looks) { look in
                    posterTile(for: look,
                               photo: photos[look.id] ?? LookPhotos.stable(forKey: look.id))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    /// A rail of pack covers with a way to every pack.
    @ViewBuilder
    private func packRail(for item: LooksShelf) -> some View {
        let packs = item.shelfPacks(from: PackCatalog.packs)
        if !packs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.railTitle)
                        .font(.luma(size: 17, weight: .semibold))
                        .kerning(-0.3)
                        .foregroundStyle(LumaTheme.textPrimary)
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { shelf = .packs }
                        LumaHaptics.shared.tap()
                    } label: {
                        Text("See all")
                            .font(.luma(size: 13, weight: .medium))
                            .foregroundStyle(LumaTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(packs) { pack in
                            packCover(pack)
                                .frame(width: 138)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
    }

    /// A pack cover that opens the pack page (the Store's detail screen).
    private func packCover(_ pack: LookPack) -> some View {
        LookPackCover(pack: pack,
                      image: packThumbs.images[pack.id],
                      state: app.packStore.isInstalled(pack) ? "In library"
                                                              : StoreNav.price(pack, storeService)) {
            app.selectedPackID = pack.id
            app.path.append(.filterPack)
            LumaHaptics.shared.tap()
        }
    }

    private func linkRow(symbol: String, title: String, detail: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LumaTheme.textPrimary)
                .frame(width: 36, height: 36)
                .background(LumaTheme.control, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(LumaTheme.textPrimary)
                Text(detail)
                    .font(.luma(size: 12))
                    .foregroundStyle(LumaTheme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LumaTheme.textMuted)
        }
        .padding(12)
        .background(LumaTheme.panel, in: shape)
        .overlay(shape.strokeBorder(LumaTheme.edge, lineWidth: 1))
        .contentShape(shape)
    }

    /// For you: recently used, then favourites, then the picks (the
    /// signature looks and the newest pack's looks), each look once.
    private var forYouLooks: [LibraryLook] {
        let all = app.library.all
        var seen = Set<String>()
        var out: [LibraryLook] = []
        for look in app.library.recents where seen.insert(look.id).inserted {
            out.append(look)
        }
        for look in all where look.isFavourite && seen.insert(look.id).inserted {
            out.append(look)
        }
        for look in all where look.section == .builtIn && seen.insert(look.id).inserted {
            out.append(look)
        }
        for look in all where look.sourcePack?.isNew == true && seen.insert(look.id).inserted {
            out.append(look)
        }
        return out
    }

    private func shelfLooks(_ item: LooksShelf) -> [LibraryLook] {
        switch item {
        case .forYou: return forYouLooks
        case .film:   return app.library.all.filter { $0.isFilmLook }
        case .night:  return app.library.all.filter { $0.isNightLook }
        case .pro:    return app.library.all.filter { $0.isProLook }
        case .mine:   return app.library.all.filter { $0.isMine }
        case .packs:  return []
        }
    }

    /// What the photo picker reads: the name, plus a saved look's base look.
    private func photoName(_ look: LibraryLook) -> String {
        if case .saved(let saved) = look.source { return "\(saved.name) \(saved.baseLookName)" }
        return look.name
    }

    /// Each look on the photo that suits it, spread so a tile never shares
    /// its photo with the tile beside it or the one above it.
    private func posterPhotos(for looks: [LibraryLook]) -> [String: HeroPhoto] {
        let names = looks.map { photoName($0) }
        let keys = looks.map { $0.id }
        let picked = LookPhotos.spread(names: names, keys: keys)
        var out: [String: HeroPhoto] = [:]
        for index in looks.indices where index < picked.count && out[looks[index].id] == nil {
            out[looks[index].id] = picked[index]
        }
        return out
    }

    /// Everything a poster needs to grade off the main actor.
    private func posterJob(for look: LibraryLook) -> LookPosterJob {
        var full = LookSettings()
        full.intensity = 100
        switch look.source {
        case .builtIn(let preset):
            return LookPosterJob(key: look.thumbKey, recipe: preset.recipe,
                                 settings: full, lutURL: nil)
        case .lut(let file):
            return LookPosterJob(key: look.thumbKey, recipe: nil, settings: full,
                                 lutURL: app.lutRepository.fileURL(for: file))
        case .saved(let saved):
            let recipe = MockData.looks.first { $0.name == saved.baseLookName }?.recipe
            let lut = saved.lutID.flatMap { id in app.lutRepository.luts.first { $0.id == id } }
            return LookPosterJob(key: look.thumbKey, recipe: recipe, settings: saved.settings,
                                 lutURL: lut.map { app.lutRepository.fileURL(for: $0) })
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: compact ? 8 : 10) {
            // A2: the strength of the applied look and hold-to-Compare, on one
            // calm row. Each appears only when it can actually do something —
            // Compare needs an intensity to stash (the editor sheet passes
            // none), Apply-to-all needs more than one clip to apply to. A dead
            // control is worse than an absent one.
            if let intensity {
                intensityRow(intensity)
                    .padding(.horizontal, 20)
            }
            if canApplyToAllClips {
                Button(action: applyToAllClips) {
                    Text("Apply to all clips")
                        .font(.luma(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 32 : 38)
                        .background(Color(white: 0.13),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.lumaPress)
                .padding(.horizontal, 20)
            }
            // The Looks tab has no bar here any more: the grid runs clean to
            // the bottom and New look sits in the header and in Mine.
        }
        .padding(.top, intensity != nil || canApplyToAllClips ? (compact ? 8 : 12) : 0)
        .padding(.bottom, intensity != nil || canApplyToAllClips ? 8 : 0)
    }

    /// Intensity label + slider + live value + Compare, all on one row — the
    /// whole footer budget a half-sheet can afford without eating the grid,
    /// and the same voice at full size.
    private func intensityRow(_ intensity: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text("Intensity")
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
            Slider(value: intensity, in: 0...100)
                .tint(.white)
            // The one genuine instrument value in this row — mono stays.
            Text("\(Int(intensity.wrappedValue))%")
                .font(.luma(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: Int(intensity.wrappedValue))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, alignment: .trailing)
            compareButton(intensity)
        }
    }

    /// Press-and-hold drops intensity to 0 and shows the ungraded frame. Its
    /// stash is deliberately separate from None's persistent restore value.
    private func compareButton(_ intensity: Binding<Double>) -> some View {
        let comparing = compareStashedIntensity != nil
        let canCompare = intensity.wrappedValue > 0 || comparing
        return Text("Compare")
            .font(.luma(size: 13, weight: .semibold))
            .foregroundStyle(comparing ? .black : .white.opacity(0.8))
            .frame(width: 84, height: compact ? 30 : 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(comparing ? AnyShapeStyle(.white) : AnyShapeStyle(Color(white: 0.13)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard canCompare, compareStashedIntensity == nil else { return }
                        compareStashedIntensity = intensity.wrappedValue
                        intensity.wrappedValue = 0
                        LumaHaptics.shared.tap()
                    }
                    .onEnded { _ in
                        guard let stash = compareStashedIntensity else { return }
                        intensity.wrappedValue = stash
                        compareStashedIntensity = nil
                        LumaHaptics.shared.tap()
                    }
            )
            .allowsHitTesting(canCompare)
            .opacity(canCompare ? 1 : 0.45)
            .accessibilityLabel("Compare, hold")
            .accessibilityHint(canCompare ? "Shows the original while held" : "Unavailable while the original is selected")
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: comparing)
    }

    /// Only meaningful in the editor, and only with clips to spread across.
    private var canApplyToAllClips: Bool {
        switch context {
        case .editorClip, .editorTimeline:
            return app.editor.clips.count > 1 && currentLook != nil
        default:
            return false
        }
    }

    /// The library look currently applied in this context, if any.
    private var currentLook: LibraryLook? {
        app.library.all.first(where: isSelected)
    }

    private func applyToAllClips() {
        guard let look = currentLook else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            for clip in app.editor.clips {
                app.select(look: look, forClip: clip.id)
            }
        }
        LumaHaptics.shared.exportSuccess()
    }

    // MARK: Selection

    private func isSelected(_ look: LibraryLook) -> Bool {
        if case .editorClip(let id) = context {
            guard let g = app.editor.clips.first(where: { $0.id == id })?.grade else { return false }
            switch look.source {
            case .builtIn(let p): return g.lutID == nil && g.baseLookName == p.name
            case .lut(let f):     return g.lutID == f.id
            case .saved(let s):   return g.baseLookName == s.baseLookName
                                        && g.lutID == s.lutID
                                        && g.settings == s.settings
            }
        }
        return app.isCurrent(look)
    }

    private func select(_ look: LibraryLook, navigate: Bool) {
        switch context {
        case .editorClip(let id):
            app.select(look: look, forClip: id)
        case .editorTimeline, .grade, .camera:
            app.select(look: look)
        case .library:
            app.select(look: look)
            guard navigate else { return }
            // Land the pick in a grade flow: straight into the grade room when
            // media is loaded, else via Select Clip (the look stays selected).
            if app.selectedVideoURL != nil || app.selectedImage != nil {
                app.path.append(.applyLook)
            } else {
                app.path.append(.selectClip)
            }
        }
    }
}

// MARK: - Lock glyph

/// The one mark for a premium look this user has not unlocked: it grades for
/// free, and exporting it will ask. Bottom-trailing on every tile, clear of the
/// source badge and the favourite star, monochrome like the rest of the chrome.
struct LookLockGlyph: View {
    var compact: Bool = false

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: compact ? 7 : 8, weight: .bold))
            .foregroundStyle(.white.opacity(0.95))
            .frame(width: compact ? 15 : 18, height: compact ? 15 : 18)
            .background(.black.opacity(0.6), in: Circle())
            .padding(compact ? 3 : 5)
            .allowsHitTesting(false)
            .accessibilityLabel("Locked look")
    }
}

// MARK: - Grid tile

/// One look in the browser grid: the live-graded thumbnail IS the tile, with
/// the source badge and the favourite star separating by surface value rather
/// than by hue. Selection is the only stroke on the screen.
struct LookTile: View {
    let look: LibraryLook
    var image: CGImage? = nil
    var selected: Bool = false
    var isFavourite: Bool = false
    /// Half-sheet variant: shorter thumb, one-line name, no subtitle line —
    /// so a ~340 pt panel can still show two COMPLETE, named rows.
    var compact: Bool = false
    /// Premium and not unlocked: draws `LookLockGlyph`.
    var locked: Bool = false
    let action: () -> Void
    var onFavourite: (() -> Void)? = nil

    /// Caption metrics the browser solves `thumbHeight` against — one source
    /// of truth, so the arithmetic and the layout can never disagree.
    static let compactCaptionHeight: CGFloat = 16
    static let compactSpacing: CGFloat = 4

    /// "LUT" stays upper — it is an acronym, not a shouted label.
    private var badge: String? {
        switch look.source {
        case .saved:          return "Saved"
        case .lut(let f):     return f.packID == nil ? (f.isLogTarget ? "Log" : "LUT") : nil
        case .builtIn:        return nil
        }
    }

    /// Shared with `LookStripTile` — see `LibraryLook.nameSplit`.
    private var split: (title: String, code: String?) { look.nameSplit }

    private var subtitle: String {
        let source = look.packName ?? look.section.title
        if let code = split.code { return "\(code) · \(source)" }
        return source
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: compact ? Self.compactSpacing : 7) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    // Square, always. Height follows the column width so the
                    // tile is the same object on every surface.
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(white: 0.12)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    // clipShape clips pixels but NOT touches: a scaledToFill
                    // image overflows and its invisible remainder steals taps
                    // from the neighbouring tile. Confine hit-testing.
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .pickedRing(selected, cornerRadius: 12)
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge)
                                .font(.luma(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(compact ? 4 : 5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if locked { LookLockGlyph(compact: compact) }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)

                VStack(alignment: .leading, spacing: 1) {
                    Text(split.title)
                        .font(.luma(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : .white.opacity(0.8))
                        .lineLimit(compact ? 1 : 2)
                        .minimumScaleFactor(compact ? 0.82 : 0.85)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Fixed caption box keeps every grid row on the same
                        // baseline whether a name wraps or not.
                        .frame(height: compact ? Self.compactCaptionHeight : 32,
                               alignment: .top)
                    if !compact {
                        Text(subtitle)
                            .font(.luma(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.lumaPress)

            if let onFavourite {
                Button(action: onFavourite) {
                    Image(systemName: isFavourite ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isFavourite ? .white : .white.opacity(0.6))
                        .frame(width: compact ? 22 : 24, height: compact ? 22 : 24)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(compact ? 3 : 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavourite ? "Unfavourite" : "Favourite")
            }
        }
    }
}

// MARK: - Poster tile (Looks tab)

/// A look as a poster: graded on its own person, its code large in the
/// look's signature colour, the name and its family along the bottom.
struct LookPosterTile: View {
    let look: LibraryLook
    let job: LookPosterJob
    let photo: HeroPhoto
    var selected: Bool = false
    var isFavourite: Bool = false
    var locked: Bool = false
    let action: () -> Void
    var onFavourite: (() -> Void)? = nil

    private var split: (title: String, code: String?) { look.nameSplit }

    /// The stock code; for looks without one, the first word when it is
    /// short ("Neon"), else the initials ("Documentary Grit" as DG).
    private var code: String {
        if let code = split.code { return code }
        let words = split.title.split(separator: " ")
        if let first = words.first, first.count <= 9 { return String(first) }
        let initials = words.prefix(3).compactMap(\.first)
        return initials.isEmpty ? "?" : String(initials).uppercased()
    }

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                Color.clear
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay { LookPosterArt(job: job, photo: photo) }
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.3), location: 0),
                            .init(color: .clear, location: 0.3),
                            .init(color: .clear, location: 0.55),
                            .init(color: .black.opacity(0.82), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .overlay(alignment: .topLeading) { codeLabel }
                    .overlay(alignment: .bottomLeading) { caption }
                    .clipShape(shape)
                    // scaledToFill overflows: confine touches to the tile.
                    .contentShape(shape)
                    .overlay(shape.strokeBorder(LumaTheme.edge, lineWidth: 1).opacity(selected ? 0 : 1))
                    .pickedRing(selected, cornerRadius: 16)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel(look.name)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if let onFavourite {
                Button(action: onFavourite) {
                    Image(systemName: isFavourite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isFavourite ? LumaTheme.signal : .white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.4), in: Circle())
                        .padding(7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavourite ? "Unfavourite" : "Favourite")
            }
        }
    }

    private var codeLabel: some View {
        Text(code)
            .font(.luma(size: 30, weight: .heavy))
            .kerning(-1.4)
            .foregroundStyle(look.signature)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 1)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(.leading, 12)
            .padding(.trailing, 44)
            .padding(.top, 9)
    }

    private var caption: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(split.title)
                .font(.luma(size: 14, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityLabel("Locked")
            }
            Text(look.posterTag)
                .font(.luma(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .padding(12)
    }
}

// MARK: - Poster art (Looks tab)

/// What a poster needs to grade one look, resolved on the main actor so the
/// render never touches the repository.
struct LookPosterJob {
    let key: String
    let recipe: LookRecipe?
    let settings: LookSettings
    let lutURL: URL?
}

/// Grades a look on its own bundled photo for the Looks tab posters. The
/// photos are cropped and decoded once; the posters live in a small recently
/// used cache, so scrolling back never regrades and memory stays flat.
enum LookPosterRenderer {
    /// Long side in pixels: a two-column tile at 3x is about 540.
    static let maxDimension: CGFloat = 600

    final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 36
        return cache
    }()

    private static let frameLock = NSLock()
    private static var frames: [String: CIImage] = [:]

    static func key(_ job: LookPosterJob, _ photo: HeroPhoto) -> String {
        "\(job.key)|\(photo.rawValue)"
    }

    static func cached(_ key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    static func store(_ image: CGImage, key: String) {
        cache.setObject(Box(image), forKey: key as NSString)
    }

    /// The photo cropped 4:5 around its subject and decoded once.
    static func frame(for photo: HeroPhoto) -> CIImage? {
        frameLock.lock()
        let hit = frames[photo.rawValue]
        frameLock.unlock()
        if let hit { return hit }
        guard let cropped = photo.posterFrame(aspect: 0.8, longest: maxDimension),
              let cg = LookPipeline.shared.context.createCGImage(cropped, from: cropped.extent)
        else { return nil }
        let decoded = CIImage(cgImage: cg)
        frameLock.lock()
        frames[photo.rawValue] = decoded
        frameLock.unlock()
        return decoded
    }

    /// The look at full strength through the real pipeline.
    static func render(_ job: LookPosterJob, photo: HeroPhoto) -> CGImage? {
        guard let frame = frame(for: photo) else { return nil }
        let state = LookState()
        if let recipe = job.recipe { state.recipe = recipe }
        state.settings = job.settings
        if let url = job.lutURL {
            guard let parsed = try? LookPipeline.shared.loadLUT(at: url) else { return nil }
            state.lut = parsed
        }
        return LookPipeline.shared.gradedStill(frame, state: state, maxDimension: maxDimension)
    }
}

/// One look graded on one photo, rendered when the tile scrolls in.
struct LookPosterArt: View {
    let job: LookPosterJob
    let photo: HeroPhoto
    @State private var image: CGImage?

    init(job: LookPosterJob, photo: HeroPhoto) {
        self.job = job
        self.photo = photo
        _image = State(initialValue: LookPosterRenderer.cached(LookPosterRenderer.key(job, photo)))
    }

    private var renderKey: String { LookPosterRenderer.key(job, photo) }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    LumaTheme.raised
                }
            }
            .animation(.easeOut(duration: 0.3), value: image != nil)
            .task(id: renderKey) {
                let key = renderKey
                if let hit = LookPosterRenderer.cached(key) {
                    image = hit
                    return
                }
                let job = self.job
                let photo = self.photo
                let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    LookPosterRenderer.render(job, photo: photo)
                }.value
                guard let rendered else { return }
                LookPosterRenderer.store(rendered, key: key)
                if !Task.isCancelled { image = rendered }
            }
    }
}

// MARK: - Pack cover (Looks tab)

/// A pack as a cover: its people graded in the pack's lead look, the pack
/// line in signal and the name as a light word and a heavy word.
struct LookPackCover: View {
    let pack: LookPack
    var image: CGImage? = nil
    /// "Free", "Pro", a price, or "In library".
    let state: String
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(0.8, contentMode: .fit)
                .overlay { art }
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.25), location: 0),
                        .init(color: .clear, location: 0.3),
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.86), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .topTrailing) { statePill }
                .overlay(alignment: .bottomLeading) { caption }
                .clipShape(shape)
                .contentShape(shape)
                .overlay(shape.strokeBorder(LumaTheme.edge, lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(pack.name), \(pack.looks.count) looks, \(state)")
    }

    private var art: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    LumaTheme.raised
                }
            }
            .frame(width: geo.size.width, height: geo.size.height,
                   alignment: pack.coverPhoto.cropAlignment)
            .clipped()
        }
    }

    private var statePill: some View {
        Text(state)
            .font(.luma(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pack.packLine)
                .font(.luma(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(LumaTheme.signal)
                .lineLimit(1)
            LumaHeadline(light: pack.titleParts.light, heavy: pack.titleParts.heavy, size: 20)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

// MARK: - New look tile (Looks tab, Mine)

/// Mine's first tile: build a look from scratch.
struct NewLookTile: View {
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(0.8, contentMode: .fit)
                .background(LumaTheme.panel, in: shape)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(LumaTheme.onLight)
                            .frame(width: 42, height: 42)
                            .background(LumaTheme.textPrimary, in: Circle())
                        Text("New look")
                            .font(.luma(size: 15, weight: .semibold))
                            .foregroundStyle(LumaTheme.textPrimary)
                        Text("Build one from scratch")
                            .font(.luma(size: 12))
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                }
                .overlay {
                    shape
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(LumaTheme.border)
                }
                .contentShape(shape)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Create a new look")
    }
}

// MARK: - Strip tile

/// Compact horizontal-strip tile shared by the grade room, camera and editor
/// strips — one look, one selection ring, one badge scheme everywhere.
struct LookStripTile: View {
    let look: LibraryLook
    var image: CGImage? = nil
    var selected: Bool = false
    var size: CGSize = CGSize(width: 96, height: 96)
    var radius: CGFloat = 16
    /// Camera-style label shadow over the viewfinder.
    var onMedia: Bool = false
    /// Off for tiles too small to hold a real look name (the 52pt camera
    /// filmstrip) — there the active name is carried by the mono readout.
    var showsName: Bool = true
    let action: () -> Void

    private var badge: String? {
        switch look.source {
        case .saved:      return "SAVED"
        case .lut(let f): return f.isLogTarget ? "LOG" : "LUT"
        case .builtIn:    return nil
        }
    }

    private var tint: Color? {
        switch look.source {
        case .builtIn(let p): return p.gradeTint
        case .saved(let s):   return MockData.looks.first { $0.name == s.baseLookName }?.gradeTint
        case .lut:            return Color(red: 0.3, green: 0.8, blue: 0.9)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let image {
                        GradedThumb(image: image, size: size, radius: radius, selected: selected)
                    } else {
                        SceneThumb(scene: .sunsetRoad, grade: tint, radius: radius,
                                   selected: selected)
                    }
                }
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.luma(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.16), in: Capsule())
                            .padding(5)
                    }
                }
                if showsName {
                    // Drop the "KD52 · " code prefix: in a 100pt tile it eats
                    // the half of the name that actually tells looks apart
                    // ("KD52 · Cine N…"), and the badge already carries source.
                    Text(look.nameSplit.title)
                        .font(.luma(size: size.width > 80 ? 13 : 12,
                                      weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white
                                         : onMedia ? .white.opacity(0.7) : LumaTheme.textSecondary)
                        .shadow(color: onMedia ? .black.opacity(0.6) : .clear, radius: 2, y: 1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(width: size.width + 4)
                }
            }
        }
        .buttonStyle(.lumaPress)
    }
}

/// Trailing strip tile opening the full LookBrowserSheet.
struct AllLooksTile: View {
    var size: CGSize = CGSize(width: 96, height: 96)
    var radius: CGFloat = 16
    var onMedia: Bool = false
    /// Matches `LookStripTile.showsName` so the camera strip stays captionless.
    var showsName: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(onMedia ? AnyShapeStyle(.black.opacity(0.3))
                                  : AnyShapeStyle(LumaTheme.surface))
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: size.width > 80 ? 22 : 18, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }

                if showsName {
                    Text("All Looks")
                        .font(.luma(size: size.width > 80 ? 13 : 12))
                        .foregroundStyle(onMedia ? .white.opacity(0.7) : LumaTheme.textSecondary)
                        .shadow(color: onMedia ? .black.opacity(0.6) : .clear, radius: 2, y: 1)
                        .lineLimit(1)
                        .frame(width: size.width + 4)
                }
            }
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Import button

/// The ONE LUT import door for browser surfaces. Picking a file no longer
/// imports it: the file is handed to `LUTImportSheet` (G2), which validates,
/// previews and names it before anything reaches the library. Feedback still
/// lands on the app-wide import toast.
struct LUTImportButton<Label: View>: View {
    var onImported: ((LUTFile) -> Void)? = nil
    @ViewBuilder let label: () -> Label

    @EnvironmentObject private var app: AppModel
    @State private var showImporter = false
    @State private var picked: PickedFile?

    private static var cubeType: UTType { UTType(filenameExtension: "cube") ?? .data }

    var body: some View {
        Button {
            showImporter = true
            LumaHaptics.shared.tap()
        } label: {
            label()
        }
        .buttonStyle(.lumaPress)
        .sheet(item: $picked) { file in
            LUTImportSheet(sourceURL: file.url, origin: file.origin) { imported in
                onImported?(imported)
            }
            .environmentObject(app)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [Self.cubeType, .plainText, .png, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                picked = PickedFile(url: url)
            case .failure(let error):
                app.importToast = error.localizedDescription
            }
        }
    }
}

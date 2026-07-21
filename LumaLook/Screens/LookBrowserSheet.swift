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

extension LookLibraryStore {
    /// The bounded strip every apply surface leads with: the collection pinned
    /// to the camera filmstrip (G3) first, then recently used, then favourites,
    /// then the rest of the library, deduped and capped so thumbnail rendering
    /// stays cheap. The full library lives one tap away behind "All Looks".
    func stripLooks(limit: Int = 14) -> [LibraryLook] {
        var seen = Set<String>()
        var out: [LibraryLook] = []
        for look in pinnedCollectionLooks + recents + all.filter(\.isFavourite) + all {
            guard out.count < limit else { break }
            guard seen.insert(look.id).inserted else { continue }
            out.append(look)
        }
        return out
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
//   7. Prefer a live value over a glyph (see `valueTool` in LDCameraDemoView).
//
// WHAT COMPACT MODE STILL OWES THE HALF-SHEET
// The same view is hosted at ~340 pt (grade / camera), ~620 pt (editor) and
// full screen (Looks tab). Compact keeps its whole budget: folded search, a
// SOLVED tile height so exactly two complete named rows fit, one-line names
// and a single-row footer. The instruction bar is deliberately full-screen
// only — a 44 pt bar costs the half-sheet its second tile row, and the sheet
// already confirms with Done in its header.
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()
    @State private var category: LookLibraryStore.Category = .all
    @State private var search = ""
    @State private var renameLUT: LUTFile?
    @State private var renameText = ""
    @State private var stashedIntensity: Double?
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

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

    /// Thumbnail height that makes two whole rows fit the measured grid, with
    /// a 14 pt sliver of the third row left under the fade so the grid still
    /// reads as scrollable. Clamped so it degrades gracefully either way.
    private var compactThumbHeight: CGFloat {
        let caption = LookTile.compactCaptionHeight + LookTile.compactSpacing
        let perRow = (gridHeight - rowSpacing - 14) / 2 - caption
        return min(96, max(46, perRow.rounded(.down)))
    }

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
            thumbs.render(source: app.previewFrame, library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        // Only the full-screen host draws a hero, and it re-renders on the
        // applied look — never on a keystroke in the search field.
        .task(id: heroKey) {
            guard !isSheet else { return }
            let source = app.previewFrame ?? HeroPhoto.golden.ciImage ?? LookThumbs.fallbackFrame
            heroImage = LookPipeline.shared.gradedStill(source, state: app.lookState,
                                                        maxDimension: 900)
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
            // Store → Library hand-off (F1): an owned pack tapped in the store
            // lands here already filtered to that pack. Consumed once.
            guard let packName = app.libraryPackFilter else { return }
            app.libraryPackFilter = nil
            category = .purchased
            search = packName
            // The field is folded away by default; a filter arriving from the
            // store has to be visible and clearable.
            searchExpanded = true
        }
    }

    /// Everything that actually changes the hero pixels. Deliberately does NOT
    /// include `search`.
    private var heroKey: String {
        "\(app.selectedLook.name)-\(String(describing: app.selectedLUT?.id))-\(Int(app.settings.intensity))-\(app.previewFrame?.extent.debugDescription ?? "none")"
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if !isSheet {
                media.frame(height: heroHeight)
            }
            drawer
        }
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

    private var drawer: some View {
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

    // MARK: Header

    /// A count is one instrument value and one plain word. The digits are the
    /// only part that earns mono; "looks" is not a readout.
    private func countText(_ value: Int, _ word: String, size: CGFloat) -> Text {
        Text("\(value)")
            .font(.system(size: size, weight: .medium, design: .monospaced))
        + Text(" \(word)")
            .font(.system(size: size, weight: .medium))
    }

    private var totals: Text {
        countText(app.library.all.count, "looks", size: 12)
            + Text(" · ").font(.system(size: 12, weight: .medium))
            + countText(app.lutRepository.collections.count, "collections", size: 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showsBackButton {
                BackArrow()
            }
            if isSheet {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looks")
                        .font(.system(size: 17, weight: .semibold))
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                Button {
                    LumaHaptics.shared.tap()
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 14, weight: .semibold))
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
            .foregroundStyle(active ? .black : .white.opacity(0.8))
            .frame(width: side, height: side)
            .background {
                Circle().fill(active ? AnyShapeStyle(.white) : AnyShapeStyle(Color(white: 0.13)))
            }
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
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
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
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
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
                .font(.system(size: 15))
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
                LazyVGrid(columns: columns, spacing: rowSpacing) {
                    if search.isEmpty, category == .all || category == .recents {
                        noneTile
                    }
                    ForEach(visibleLooks) { look in
                        tile(for: look)
                    }
                }
                .padding(.horizontal, 20)
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
        let groups = app.library.collectionGroups
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            // Manage only from the full-screen Looks tab: from a sheet a push
            // would land behind the sheet, which would be a dead tap.
            if context == .library {
                HStack {
                    // A section heading should read as a heading.
                    Text("Collections")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Spacer()
                    Button {
                        app.path.append(.collections)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text("Manage")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups, id: \.collection.id) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            // The collection's name is a name; only its size
                            // is a number.
                            Text(group.collection.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Text("\(group.looks.count)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            if group.collection.pinnedToCamera == true {
                                Text("Pinned")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Color(white: 0.16), in: Capsule())
                            }
                        }
                        if group.looks.isEmpty {
                            Text("Long-press any look to add it here.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            LazyVGrid(columns: columns, spacing: rowSpacing) {
                                ForEach(group.looks) { look in tile(for: look) }
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
                .font(.system(size: compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            if !compact {
                Text(search.isEmpty ? "Import a .cube or buy a pack to fill this shelf."
                                    : "Try a pack name, a look code, or a tag.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 26 : 44)
    }

    private func tile(for look: LibraryLook) -> some View {
        LookTile(look: look,
                 image: thumbs.images[look.thumbKey],
                 selected: isSelected(look),
                 isFavourite: app.library.isFavourite(look.id),
                 compact: compact,
                 thumbHeight: compact ? compactThumbHeight : 96) {
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
                    .frame(height: compact ? compactThumbHeight : 96)
                    .overlay {
                        Text(context == .camera ? "Off" : "None")
                            .font(.system(size: compact ? 12 : 14, weight: .semibold))
                            .foregroundStyle(active ? .white : .white.opacity(0.55))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]))
                            .foregroundStyle(active ? .white : .white.opacity(0.18))
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Original")
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? .white : .white.opacity(0.72))
                        .lineLimit(compact ? 1 : 2)
                        .frame(height: compact ? LookTile.compactCaptionHeight : 32,
                               alignment: .top)
                    if !compact {
                        Text("No look")
                            .font(.system(size: 11))
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
            app.settings.intensity = stashedIntensity ?? 75
            stashedIntensity = nil
        } else {
            stashedIntensity = app.settings.intensity
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
                        .font(.system(size: 13, weight: .semibold))
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
            // Full screen only: a 44 pt bar would cost the half-sheet its
            // second tile row, and the sheet already exits through Done.
            if !isSheet {
                instructionBar
            }
        }
        .padding(.top, intensity != nil || canApplyToAllClips ? (compact ? 8 : 12) : 0)
        .padding(.bottom, isSheet ? (intensity != nil || canApplyToAllClips ? 8 : 0) : 4)
    }

    /// Intensity label + slider + live value + Compare, all on one row — the
    /// whole footer budget a half-sheet can afford without eating the grid,
    /// and the same voice at full size.
    private func intensityRow(_ intensity: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text("Intensity")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
            Slider(value: intensity, in: 0...100)
                .tint(.white)
            // The one genuine instrument value in this row — mono stays.
            Text("\(Int(intensity.wrappedValue))%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: Int(intensity.wrappedValue))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, alignment: .trailing)
            compareButton(intensity)
        }
    }

    /// Press-and-hold drops intensity to 0 and shows the ungraded frame, using
    /// the same stash/restore the None tile uses; releasing restores it.
    private func compareButton(_ intensity: Binding<Double>) -> some View {
        let comparing = stashedIntensity != nil && intensity.wrappedValue == 0
        return Text("Compare")
            .font(.system(size: 13, weight: .semibold))
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
                        guard stashedIntensity == nil else { return }
                        stashedIntensity = intensity.wrappedValue
                        intensity.wrappedValue = 0
                        LumaHaptics.shared.tap()
                    }
                    .onEnded { _ in
                        guard let stash = stashedIntensity else { return }
                        intensity.wrappedValue = stash
                        stashedIntensity = nil
                        LumaHaptics.shared.tap()
                    }
            )
            .accessibilityLabel("Compare, hold")
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: comparing)
    }

    // MARK: Instruction bar — a sentence, not a slogan (full screen only)

    private var instruction: String {
        if noneActive { return "Showing the original" }
        if let current = currentLook { return current.nameSplit.title }
        return "Choose a look to grade with"
    }

    /// A NAME of an applied look is a fact and reads at full weight; the two
    /// other sentences are prompts and stay calm.
    private var instructionIsName: Bool { !noneActive && currentLook != nil }

    private var instructionBar: some View {
        HStack(spacing: 10) {
            Text(instruction)
                .font(.system(size: 15, weight: instructionIsName ? .semibold : .medium))
                .foregroundStyle(.white.opacity(instructionIsName ? 0.95 : 0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let intensity, !noneActive {
                Text("\(Int(intensity.wrappedValue))%")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            if showsCreateCTA {
                // The Create New Look door, kept as a word rather than a filled
                // violet CTA: a store's buy button is the one place a filled
                // button is still correct.
                Button {
                    app.path.append(.customLook)
                    LumaHaptics.shared.tap()
                } label: {
                    Text("New look")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color(white: 0.15), in: Capsule())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Create a new look")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 6)
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
            case .saved(let s):   return g.baseLookName == s.baseLookName && g.lutID == s.lutID
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
    var thumbHeight: CGFloat = 96
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
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? Self.compactSpacing : 7) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: thumbHeight)
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
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white, lineWidth: 2)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(compact ? 4 : 5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            onFavourite?()
                        } label: {
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
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)

                VStack(alignment: .leading, spacing: 1) {
                    Text(split.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
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
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.lumaPress)
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
                            .font(.system(size: 8, weight: .heavy))
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
                        .font(.system(size: size.width > 80 ? 13 : 12,
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
                        .font(.system(size: size.width > 80 ? 13 : 12))
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

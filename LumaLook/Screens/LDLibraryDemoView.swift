import SwiftUI

// =============================================================================
// LDLibraryDemoView — the Look Library rebuilt in the LD (Lens Distortions)
// direction. A WORKING screen, not a mock: real LookLibraryStore queries, real
// graded thumbnails through LookThumbs, real selection through
// AppModel.select(look:), real context menus, real .cube import.
//
// -----------------------------------------------------------------------------
// FEATURE INVENTORY vs LookBrowserSheet (the screen this previews)
// -----------------------------------------------------------------------------
// ✓ All seven categories (All / Favourites / Recents / Your Looks / Purchased /
//   Imported / Collections) — as a swipeable two-axis category bar
// ✓ Per-category live counts (mono readout under the category name)
// ✓ Library totals readout — N looks · M collections (mono digits, plain words)
// ✓ Search across look name, pack name and LUT tags (folded behind a glyph,
//   exactly like the compact browser)
// ✓ Clear-search control
// ✓ Favourites — star on every tile, cross-source via library.toggleFavourite
// ✓ Recents — recently USED, fed by AppModel.select(look:)
// ✓ Collections — grouped sections, per-collection count, PINNED marker,
//   empty-collection hint, Manage → .collections route
// ✓ Long-press menu: Favourite / Unfavourite
// ✓ Long-press menu: Add to Collection (submenu, per-collection checkmark)
// ✓ Long-press menu: Rename… (imported LUTs) with the rename alert
// ✓ Long-press menu: Delete (imported LUTs and saved looks)
// ✓ Long-press menu: View Pack… (pack-installed LUTs) → .filterPack
// ✓ Import .cube — LUTImportButton → LUTImportSheet, i.e. the real format
//   validation / preview / naming path. Imported look is selected on return.
// ✓ Intensity slider (0–100) bound to the live look settings
// ✓ Hold-to-Compare (stash intensity → 0 → restore), shared stash with None
// ✓ None / Original tile — clears the grade, leads All and Recents
// ✓ Selection state — one thin white ring, nothing else
// ✓ Source badges (SAVED / LUT / LOG) — restated monochrome
// ✓ Empty state, including the "no looks match …" variant
// ✓ Create New Look → .customLook
// ✓ Store → Library hand-off: consumes app.libraryPackFilter, lands filtered
// ✓ Tiles ARE the preview — every one is the real grade of the real frame
//
// ✗ Half-sheet compact mode (folded search, solved tile height, one-row footer)
//   — out of scope: the Design Lab hosts this as a pushed full-screen route, so
//   there is no detent to solve against. The folded search is kept anyway.
// ✗ "Open Library ↗" / "Done" header pair — sheet-only affordances; this screen
//   IS the library, and the instruction bar carries the exit.
// ✗ "Apply to all clips" — only meaningful from LookBrowserContext.editorClip /
//   .editorTimeline with >1 clip. This preview has no clip context to spread to.
// ✗ Per-clip selection truth (editorClip grade comparison) — same reason.
// -----------------------------------------------------------------------------
//
// The grammar, extended from LDGradeDemoView:
//   1. The image is the interface — the graded frame sits uncovered on top,
//      every control lives in the drawer below it.
//   2. Monochrome chrome — black, near-black, white, grey. The only colour on
//      this screen is inside the tiles, which is exactly where looks live.
//   3. Stroke means selection and nothing else — one thin white ring.
//   4. The tile IS the preview.
//   5. Two-axis browsing — the current category centred, neighbours faded.
//   6. A calm instruction bar — the live look and its strength, with ✕ and ✓
//      at the edges.
//   7. Mono for NUMBERS ONLY — counts, strengths. Every name, category,
//      section heading, badge and button word is the system font in sentence
//      case, weighted and contrasted enough to read as deliberate.
// =============================================================================

struct LDLibraryDemoView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()

    @State private var category: LookLibraryStore.Category = .all
    @State private var search = ""
    @State private var searchOpen = false
    @State private var renameLUT: LUTFile?
    @State private var renameText = ""
    /// Shared by Compare and the None tile, so the two can never fight over
    /// the same intensity value.
    @State private var stashedIntensity: Double?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var categories: [LookLibraryStore.Category] { LookLibraryStore.Category.allCases }
    private var categoryIndex: Int { categories.firstIndex(of: category) ?? 0 }

    private var visibleLooks: [LibraryLook] {
        app.library.looks(category: category, search: search)
    }

    private func count(of cat: LookLibraryStore.Category) -> Int {
        cat == .collections ? app.lutRepository.collections.count
                            : app.library.looks(category: cat).count
    }

    /// A count is one instrument value and one plain word. The digits are the
    /// only part that earns mono; "looks" is not a readout.
    private func countText(_ value: Int, _ word: String, size: CGFloat) -> Text {
        Text("\(value)")
            .font(.system(size: size, weight: .medium, design: .monospaced))
        + Text(" \(word)")
            .font(.system(size: size, weight: .medium))
    }

    /// The chip titles carry a "★ " prefix for the accented design. On a
    /// monochrome screen the star is noise — the category bar spells it out.
    private func title(_ cat: LookLibraryStore.Category) -> String {
        cat.title.replacingOccurrences(of: "★ ", with: "")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                media
                    .frame(height: 210)
                drawer
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.library.all.count)") {
            thumbs.render(source: app.previewFrame, library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
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
        .onAppear {
            // Store → Library hand-off: an owned pack tapped in the store lands
            // here already filtered to that pack. Consumed once.
            guard let packName = app.libraryPackFilter else { return }
            app.libraryPackFilter = nil
            category = .purchased
            search = packName
            searchOpen = true
        }
    }

    // MARK: Media — the live grade, uncovered

    private var media: some View {
        GeometryReader { geo in
            Group {
                if let frame = app.previewFrame ?? HeroPhoto.golden.ciImage,
                   let cg = LookPipeline.shared.context.createCGImage(
                    LookPipeline.shared.apply(state: app.lookState, to: frame),
                    from: frame.extent) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.08)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // scaledToFill overflows its frame and the invisible remainder
            // steals taps from the drawer beneath. Confine the touch region.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: Drawer — everything that is not the image

    private var drawer: some View {
        VStack(spacing: 0) {
            toolRow
                .padding(.top, 14)
                .padding(.bottom, 12)
            categoryBar
                .padding(.bottom, 12)
            if searchOpen {
                searchField
                    .padding(.bottom, 12)
            }
            grid
            intensityRow
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)
            instructionBar
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searchOpen)
    }

    /// Library totals on the left; the three doors that are not browsing —
    /// search, import, create — as bare glyphs on the right.
    private var toolRow: some View {
        HStack(spacing: 4) {
            (countText(app.library.all.count, "looks", size: 12)
             + Text(" · ").font(.system(size: 12, weight: .medium))
             + countText(app.lutRepository.collections.count, "collections", size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    searchOpen.toggle()
                    if !searchOpen { search = "" }
                }
                LumaHaptics.shared.tap()
            } label: {
                glyph(searchOpen ? "xmark" : "magnifyingglass", active: searchOpen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchOpen ? "Close search" : "Search looks")

            LUTImportButton { imported in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    app.select(look: LibraryLook(lut: imported))
                }
            } label: {
                // A bare "+" reads as "create". Importing a .cube is a file
                // coming IN, and this glyph actually depicts that.
                glyph("square.and.arrow.down", active: false)
            }
            .accessibilityLabel("Import a LUT")

            Button {
                app.path.append(.customLook)
                LumaHaptics.shared.tap()
            } label: {
                glyph("wand.and.stars", active: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create a new look")
        }
        .padding(.horizontal, 20)
    }

    private func glyph(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? .black : .white.opacity(0.8))
            .frame(width: 34, height: 34)
            .background {
                Circle().fill(active ? AnyShapeStyle(.white) : AnyShapeStyle(Color(white: 0.13)))
            }
    }

    /// Rule 5. The current category centred with its neighbours faded either
    /// side, so the swipe teaches itself. The count rides underneath in mono,
    /// which is where the chip row's count badge went.
    private var categoryBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                neighbour(at: categoryIndex - 1, alignment: .leading)
                Text(title(categories[categoryIndex]))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 10)
                neighbour(at: categoryIndex + 1, alignment: .trailing)
            }
            countText(count(of: category),
                      category == .collections ? "collections" : "looks", size: 12)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
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
                    .font(.system(size: 13, weight: .medium))
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
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            if category == .collections {
                collectionsBody
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    if search.isEmpty, category == .all || category == .recents {
                        noneTile
                    }
                    ForEach(visibleLooks) { look in
                        tile(for: look)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

                if visibleLooks.isEmpty {
                    emptyState
                }
            }
        }
        .frame(maxHeight: .infinity)
        .mask {
            // A grid that butts against a pinned footer must fade out rather
            // than cut a caption in half.
            VStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
            }
        }
    }

    @ViewBuilder
    private var collectionsBody: some View {
        let groups = app.library.collectionGroups
        VStack(alignment: .leading, spacing: 18) {
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
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(group.looks) { look in tile(for: look) }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(search.isEmpty ? "Nothing here yet" : "No looks match “\(search)”")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text(search.isEmpty ? "Import a .cube or buy a pack to fill this shelf."
                                : "Try a pack name, a look code, or a tag.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func tile(for look: LibraryLook) -> some View {
        LDLookTile(look: look,
                   image: thumbs.images[look.thumbKey],
                   selected: app.isCurrent(look),
                   isFavourite: app.library.isFavourite(look.id)) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                app.select(look: look)
            }
            LumaHaptics.shared.tap()
        } onFavourite: {
            app.library.toggleFavourite(look)
            LumaHaptics.shared.tap()
        }
        .contextMenu { contextMenu(for: look) }
    }

    /// None / Original leads the grid — clearing a look must be as easy as
    /// applying one. Dashed, because it is the one tile that has no image.
    private var noneTile: some View {
        let active = app.settings.intensity == 0
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { tapNone() }
            LumaHaptics.shared.tap()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.07))
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .overlay {
                        Text("None")
                            .font(.system(size: 14, weight: .semibold))
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
                        .lineLimit(2)
                        .frame(height: 32, alignment: .top)
                    Text("No look")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.lumaPress)
    }

    private func tapNone() {
        if app.settings.intensity == 0 {
            app.settings.intensity = stashedIntensity ?? 75
            stashedIntensity = nil
        } else {
            stashedIntensity = app.settings.intensity
            app.settings.intensity = 0
        }
    }

    /// The long-press menu, carried across whole from LookBrowserSheet.
    @ViewBuilder
    private func contextMenu(for look: LibraryLook) -> some View {
        Button {
            app.library.toggleFavourite(look)
        } label: {
            Label(app.library.isFavourite(look.id) ? "Unfavourite" : "Favourite",
                  systemImage: app.library.isFavourite(look.id) ? "star.slash" : "star")
        }
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

    // MARK: Intensity + Compare — one calm row

    private var intensityRow: some View {
        HStack(spacing: 12) {
            Text("Intensity")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
            Slider(value: $app.settings.intensity, in: 0...100)
                .tint(.white)
            // The one genuine instrument value in this row — mono stays.
            Text("\(Int(app.settings.intensity))%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: Int(app.settings.intensity))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 42, alignment: .trailing)
            compareButton
        }
    }

    /// Press and hold drops intensity to 0 and shows the ungraded frame,
    /// releasing restores it — the same stash the None tile uses.
    private var compareButton: some View {
        let comparing = stashedIntensity != nil && app.settings.intensity == 0
        return Text("Compare")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(comparing ? .black : .white.opacity(0.8))
            .frame(width: 84, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(comparing ? AnyShapeStyle(.white) : AnyShapeStyle(Color(white: 0.13)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard stashedIntensity == nil else { return }
                        stashedIntensity = app.settings.intensity
                        app.settings.intensity = 0
                        LumaHaptics.shared.tap()
                    }
                    .onEnded { _ in
                        guard let stash = stashedIntensity else { return }
                        app.settings.intensity = stash
                        stashedIntensity = nil
                        LumaHaptics.shared.tap()
                    }
            )
            .accessibilityLabel("Compare, hold")
    }

    // MARK: Instruction bar — a sentence, not a slogan

    private var instruction: String {
        if app.settings.intensity == 0 { return "Showing the original" }
        if let current = app.library.all.first(where: { app.isCurrent($0) }) {
            return current.nameSplit.title
        }
        return "Choose a look"
    }

    private var instructionBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer()
            // The applied look is the anchor of this bar: a name at full
            // weight, its strength beside it as the live value.
            if app.settings.intensity == 0 {
                Text(instruction)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            } else {
                HStack(spacing: 7) {
                    Text(instruction)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    Text("\(Int(app.settings.intensity))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - Tile

/// One look. The tile IS the grade — no icon stands in for anything that can
/// be shown as itself. Selection is the only stroke; the badge and the star
/// separate by surface value instead of by hue.
private struct LDLookTile: View {
    let look: LibraryLook
    var image: CGImage?
    var selected: Bool
    var isFavourite: Bool
    let action: () -> Void
    var onFavourite: () -> Void

    /// "LUT" stays upper — it is an acronym, not a shouted label.
    private var badge: String? {
        switch look.source {
        case .saved:      return "Saved"
        case .lut(let f): return f.packID == nil ? (f.isLogTarget ? "Log" : "LUT") : nil
        case .builtIn:    return nil
        }
    }

    private var subtitle: String {
        let source = look.packName ?? look.section.title
        if let code = look.nameSplit.code { return "\(code) · \(source)" }
        return source
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
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
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button(action: onFavourite) {
                            Image(systemName: isFavourite ? "star.fill" : "star")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isFavourite ? .white : .white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isFavourite ? "Unfavourite" : "Favourite")
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)

                VStack(alignment: .leading, spacing: 1) {
                    Text(look.nameSplit.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : .white.opacity(0.8))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(height: 32, alignment: .top)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.lumaPress)
    }
}

import SwiftUI
import UniformTypeIdentifiers

// =============================================================================
// LookBrowserSheet — THE one reusable look browser (steps 4–6 of the unified
// Look Library migration). Presented identically from the grade room, the
// camera, and the editor via .lumaToolSheet, and hosted full-screen as the
// Looks tab. Chips + search + 3-up grid + favourite stars + intensity footer,
// all reading LookLibraryStore and applying through AppModel.select(look:).
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

struct LookBrowserSheet: View {
    let context: LookBrowserContext
    /// Intensity of the APPLIED look; nil hides the footer slider.
    var intensity: Binding<Double>? = nil
    /// Full-screen hosting (Looks tab): adds the Create New Look CTA.
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var visibleLooks: [LibraryLook] {
        app.library.looks(category: category, search: search)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            searchField
            chips
            grid
            footer
        }
        .padding(.top, 14)
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
        .preferredColorScheme(.dark)
        .onAppear {
            // Store → Library hand-off (F1): an owned pack tapped in the store
            // lands here already filtered to that pack. Consumed once.
            guard let packName = app.libraryPackFilter else { return }
            app.libraryPackFilter = nil
            category = .purchased
            search = packName
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if showsBackButton {
                BackArrow()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Looks")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                TechReadout("\(app.library.all.count) LOOKS · \(app.lutRepository.collections.count) COLLECTIONS",
                            size: 8, color: LumaTheme.textMuted)
            }
            Spacer()
            LUTImportButton { imported in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    select(LibraryLook(lut: imported), navigate: false)
                }
            } label: {
                if isSheet {
                    // Compact in the half-sheet: the header also has to carry
                    // Open Library + Done (A2), so Import loses its word.
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(LumaTheme.accent, in: Circle())
                } else {
                    Label("Import", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(LumaTheme.accent, in: Capsule())
                }
            }
            if isSheet {
                // A2: the sheet must have a visible way out. `undimmedUpThrough`
                // is below the detent this opens at, so tapping the preview
                // behind does nothing — Done is the only discoverable exit.
                Button {
                    openLibrary()
                } label: {
                    Text("Open Library ↗")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .buttonStyle(.lumaPress)
                Button {
                    LumaHaptics.shared.tap()
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .buttonStyle(.lumaPress)
            }
        }
        .padding(.horizontal, 20)
    }

    /// True when this browser is presented as a half-sheet over a live canvas
    /// (grade / camera / editor) rather than hosted full-screen as the Looks tab.
    private var isSheet: Bool { context != .library }

    /// Leave the sheet for the full Looks library. The push has to wait for the
    /// dismissal, otherwise the new screen lands *behind* the sheet.
    private func openLibrary() {
        LumaHaptics.shared.tap()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            app.path.append(.savedLooks)
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
            TextField("Search looks, packs, tags…", text: $search)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }

    // MARK: Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LookLibraryStore.Category.allCases) { cat in
                    let count = cat == .collections
                        ? app.lutRepository.collections.count
                        : app.library.looks(category: cat).count
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            category = cat
                        }
                        LumaHaptics.shared.tap()
                    } label: {
                        HStack(spacing: 6) {
                            Text(cat.title)
                                .font(.system(size: 13,
                                              weight: category == cat ? .semibold : .regular))
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(category == cat ? .white.opacity(0.85)
                                                                 : LumaTheme.textMuted)
                        }
                        .foregroundStyle(category == cat ? .white : LumaTheme.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background {
                            if category == cat {
                                Capsule().fill(LumaTheme.accent)
                            } else {
                                Capsule().fill(LumaTheme.surface)
                            }
                        }
                        .overlay(Capsule().strokeBorder(
                            .white.opacity(category == cat ? 0.18 : 0.06), lineWidth: 1))
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.horizontal, 20)
        }
        .lumaEdgeFade()
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
                // Clears the pinned footer by more than one caption block, so
                // a partly-scrolled row degrades into the fade below rather
                // than being sliced through its own text.
                .padding(.bottom, 44)

                if visibleLooks.isEmpty {
                    emptyState
                }
            }
        }
        .frame(maxHeight: .infinity)
        .lookGridBottomFade()
    }

    @ViewBuilder
    private var collectionsBody: some View {
        let groups = app.library.collectionGroups
        VStack(alignment: .leading, spacing: 16) {
            // Manage only from the full-screen Looks tab: from a sheet a push
            // would land behind the sheet, which would be a dead tap.
            if context == .library {
                SectionHeader(title: "Collections", actionTitle: "Manage") {
                    app.path.append(.collections)
                    LumaHaptics.shared.tap()
                }
            }
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups, id: \.collection.id) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            TechReadout("\(group.collection.name.uppercased()) · \(group.looks.count)",
                                        size: 10, color: LumaTheme.textMuted)
                            if group.collection.pinnedToCamera == true {
                                TechReadout("PINNED", size: 9, color: LumaTheme.accentBright)
                            }
                        }
                        if group.looks.isEmpty {
                            Text("Long-press any look to add it here.")
                                .font(.system(size: 12))
                                .foregroundStyle(LumaTheme.textMuted)
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
        .padding(.bottom, 44)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.filters")
                .font(.system(size: 30))
                .foregroundStyle(LumaTheme.textMuted)
            Text(search.isEmpty ? "Nothing here yet" : "No looks match “\(search)”")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LumaTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func tile(for look: LibraryLook) -> some View {
        LookTile(look: look,
                 image: thumbs.images[look.thumbKey],
                 selected: isSelected(look),
                 isFavourite: app.library.isFavourite(look.id)) {
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

    /// None / OFF leads the grid — clearing a look is as easy as applying one.
    private var noneTile: some View {
        let active = noneActive
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { tapNone() }
            LumaHaptics.shared.tap()
        } label: {
            // Same skeleton as LookTile — leading alignment, 96pt thumb, the
            // fixed two-line title box and a subtitle line — so the first grid
            // row shares one baseline instead of centring the shorter cell.
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LumaTheme.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .overlay {
                        TechReadout(context == .camera ? "OFF" : "NONE", size: 10,
                                    color: active ? LumaTheme.accentBright : LumaTheme.textMuted)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]))
                        .foregroundStyle(active ? LumaTheme.accentBright : .white.opacity(0.18)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Original")
                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? .white : LumaTheme.textSecondary)
                        .lineLimit(2)
                        .frame(height: 30, alignment: .top)
                    Text("No look")
                        .font(.system(size: 10))
                        .foregroundStyle(LumaTheme.textMuted)
                        .lineLimit(1)
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
        VStack(spacing: 10) {
            if let intensity {
                InlineSlider(title: "Intensity", value: intensity)
                    .padding(.horizontal, 22)
            }
            // A2: hold-to-Compare and Apply-to-all sit directly under the
            // slider. Each appears only when it can actually do something —
            // Compare needs an intensity to stash (the editor sheet passes
            // none), Apply-to-all needs more than one clip to apply to. A
            // dead control is worse than an absent one.
            if isSheet, intensity != nil || canApplyToAllClips {
                HStack(spacing: 10) {
                    if let intensity {
                        compareButton(intensity)
                    }
                    if canApplyToAllClips {
                        smallGhostButton(title: "Apply to all clips",
                                         action: applyToAllClips)
                    }
                }
                .padding(.horizontal, 22)
            }
            if showsCreateCTA {
                SolidCTA(title: "Create New Look") {
                    app.path.append(.customLook)
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, showsCreateCTA || intensity != nil || canApplyToAllClips ? 8 : 0)
    }

    /// Press-and-hold drops intensity to 0 and shows the ungraded frame, using
    /// the same stash/restore the None tile uses; releasing restores it.
    private func compareButton(_ intensity: Binding<Double>) -> some View {
        let comparing = stashedIntensity != nil && intensity.wrappedValue == 0
        return HStack(spacing: 6) {
            Text("Compare")
            Text("HOLD")
                .font(.system(size: 8, weight: .heavy).monospaced())
                .foregroundStyle(LumaTheme.textMuted)
        }
        .modifier(SmallGhostChrome(active: comparing))
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
    }

    private func smallGhostButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .modifier(SmallGhostChrome(active: false))
        }
        .buttonStyle(.lumaPress)
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

// MARK: - Small ghost chrome

/// The compact sibling of `GhostCTA` (58pt is far too tall for a half-sheet
/// footer) — same material, same hairline, same corner radius, just sized for
/// a two-up row under the intensity slider.
private struct SmallGhostChrome: ViewModifier {
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? .white : LumaTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 12).fill(LumaTheme.accent.opacity(0.28))
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(active ? 0.28 : 0.10), lineWidth: 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: active)
    }
}

// MARK: - Grid tile

/// `GradedThumb` sized by height only: the grid columns are `.flexible()`, so
/// a hard-coded thumbnail width leaves the image narrower than its own caption
/// and than the dashed None tile. Same chrome, width driven by the column.
private struct FlexibleGradedThumb: View {
    let image: CGImage
    var height: CGFloat = 96
    var radius: CGFloat = 14
    var selected: Bool = false

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? LumaTheme.accentBright : .white.opacity(0.08),
                                  lineWidth: selected ? 2.5 : 1)
            )
            .shadow(color: selected ? LumaTheme.accent.opacity(0.45) : .clear, radius: 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

/// One look in the browser grid: live-graded thumbnail, badge, favourite star
/// top-right, name + source line below.
struct LookTile: View {
    let look: LibraryLook
    var image: CGImage? = nil
    var selected: Bool = false
    var isFavourite: Bool = false
    let action: () -> Void
    var onFavourite: (() -> Void)? = nil

    private var badge: String? {
        switch look.source {
        case .saved:          return "SAVED"
        case .lut(let f):     return f.packID == nil ? (f.isLogTarget ? "LOG" : "LUT") : nil
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
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let image {
                        FlexibleGradedThumb(image: image, height: 96,
                                            radius: 14, selected: selected)
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LumaTheme.surfaceStrong)
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(selected ? LumaTheme.accentBright : .white.opacity(0.08),
                                              lineWidth: selected ? 2.5 : 1))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(LumaTheme.accent, in: Capsule())
                            .padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        onFavourite?()
                    } label: {
                        Image(systemName: isFavourite ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isFavourite ? LumaTheme.gold : .white.opacity(0.75))
                            .frame(width: 26, height: 26)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(split.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Two-line box keeps every grid row on the same baseline
                        // whether a name wraps or not.
                        .frame(height: 30, alignment: .top)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(LumaTheme.textMuted)
                        .lineLimit(1)
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
                            .background(LumaTheme.accent, in: Capsule())
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
                                .foregroundStyle(LumaTheme.accentBright)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1))
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

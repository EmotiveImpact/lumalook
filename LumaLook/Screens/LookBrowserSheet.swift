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
    /// The bounded strip every apply surface leads with: recently used first,
    /// then favourites, then the rest of the library, deduped and capped so
    /// thumbnail rendering stays cheap. The full library lives one tap away
    /// behind the "All Looks" tile.
    func stripLooks(limit: Int = 14) -> [LibraryLook] {
        var seen = Set<String>()
        var out: [LibraryLook] = []
        for look in recents + all.filter(\.isFavourite) + all {
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
                Label("Import", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(LumaTheme.accent, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
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
                .padding(.bottom, 16)

                if visibleLooks.isEmpty {
                    emptyState
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var collectionsBody: some View {
        let groups = app.library.collectionGroups
        if groups.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.collection.id) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        TechReadout("\(group.collection.name.uppercased()) · \(group.looks.count)",
                                    size: 10, color: LumaTheme.textMuted)
                        if group.looks.isEmpty {
                            Text("Long-press any LUT to add it here.")
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
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
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
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LumaTheme.background)
                    .frame(height: 96)
                    .overlay {
                        TechReadout(context == .camera ? "OFF" : "NONE", size: 10,
                                    color: active ? LumaTheme.accentBright : LumaTheme.textMuted)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]))
                        .foregroundStyle(active ? LumaTheme.accentBright : .white.opacity(0.18)))
                Text("Original")
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? .white : LumaTheme.textSecondary)
                    .lineLimit(1)
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
        if case .lut(let f) = look.source {
            if !app.lutRepository.collections.isEmpty {
                Menu {
                    ForEach(app.lutRepository.collections) { collection in
                        let isIn = (f.collectionIDs ?? []).contains(collection.id)
                        Button {
                            app.lutRepository.toggle(f, in: collection)
                        } label: {
                            Label(collection.name,
                                  systemImage: isIn ? "checkmark.circle.fill" : "folder")
                        }
                    }
                } label: {
                    Label("Add to Collection", systemImage: "folder.badge.plus")
                }
            }
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
            if showsCreateCTA {
                SolidCTA(title: "Create New Look") {
                    app.path.append(.customLook)
                }
                .padding(.horizontal, 22)
            }
        }
        .padding(.bottom, showsCreateCTA || intensity != nil ? 8 : 0)
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

    private var subtitle: String {
        look.packName ?? look.section.title
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let image {
                        GradedThumb(image: image,
                                    size: CGSize(width: 110, height: 96),
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
                    Text(look.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                        .lineLimit(1)
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
                Text(look.name)
                    .font(.system(size: size.width > 80 ? 13 : 12,
                                  weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white
                                     : onMedia ? .white.opacity(0.7) : LumaTheme.textSecondary)
                    .shadow(color: onMedia ? .black.opacity(0.6) : .clear, radius: 2, y: 1)
                    .lineLimit(1)
                    .frame(width: size.width + 4)
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
                Text("All Looks")
                    .font(.system(size: size.width > 80 ? 13 : 12))
                    .foregroundStyle(onMedia ? .white.opacity(0.7) : LumaTheme.textSecondary)
                    .shadow(color: onMedia ? .black.opacity(0.6) : .clear, radius: 2, y: 1)
                    .lineLimit(1)
                    .frame(width: size.width + 4)
            }
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Import button

/// The ONE LUT import door for browser surfaces — wraps the exact validation
/// and repository call LUTManagerView's fileImporter used, so import logic
/// exists once. Feedback lands on the app-wide import toast.
struct LUTImportButton<Label: View>: View {
    var onImported: ((LUTFile) -> Void)? = nil
    @ViewBuilder let label: () -> Label

    @EnvironmentObject private var app: AppModel
    @State private var showImporter = false

    private static var cubeType: UTType { UTType(filenameExtension: "cube") ?? .data }

    var body: some View {
        Button {
            showImporter = true
            LumaHaptics.shared.tap()
        } label: {
            label()
        }
        .buttonStyle(.lumaPress)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [Self.cubeType, .plainText, .png, .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let ext = url.pathExtension.lowercased()
                guard ["cube", "3dl", "png"].contains(ext) else {
                    app.importToast = "Choose a .cube, .3dl or HALD .png LUT."
                    return
                }
                do {
                    let file = try app.lutRepository.importLUT(from: url)
                    app.importToast = "\(file.displayName) imported"
                    onImported?(file)
                } catch {
                    app.importToast = "Couldn't read that file as a LUT."
                }
            case .failure(let error):
                app.importToast = error.localizedDescription
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// LUT Files — the file-management back office for .cube records (step 6):
/// import, rename, tags, collections, per-pack grouping. Browsing/applying
/// looks lives in the Look Library (Looks tab); this screen manages the
/// files behind them. NATIVE inset-grouped List: swipe to delete/favourite.
struct LUTManagerView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var thumbs = LookThumbs()
    @State private var filter = "All"
    @State private var showImporter = false
    /// T2.7 — live search over names + tags.
    @State private var searchText = ""
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var importError: String?
    /// The picked file, held until the G2 import sheet validates and saves it.
    @State private var pendingImport: PickedFile?
    @State private var renaming: LUTFile?
    @State private var renameText = ""
    /// Delete is confirmed, never one gesture — and only user imports can be
    /// deleted at all (pack/bundled cubes have no in-app recovery).
    @State private var deleting: LUTFile?

    private static let cubeType = UTType(filenameExtension: "cube") ?? .data

    /// Recently USED LUTs from the library's cross-surface history — not
    /// "last 3 imported", which is what this filter used to show.
    private var recentLUTs: [LUTFile] {
        app.library.recents.compactMap { look in
            guard case .lut(let f) = look.source else { return nil }
            return app.lutRepository.luts.first { $0.id == f.id }
        }
    }

    private var visibleLUTs: [LUTFile] {
        let base: [LUTFile]
        switch filter {
        case "Favourites": base = app.lutRepository.luts.filter(\.isFavourite)
        case "Recents": base = recentLUTs
        default: base = app.lutRepository.luts
        }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { lut in
            lut.displayName.lowercased().contains(q)
                || (lut.tags ?? []).contains { $0.lowercased().contains(q) }
        }
    }

    /// The default view groups installed looks by the pack they came from
    /// (preserving the purchased-pack identity) with a "Your Imports" section
    /// for user `.cube` files; the other filters are one flat group.
    private var lutGroups: [(id: String, title: String, luts: [LUTFile])] {
        if !searchText.isEmpty {
            return [("search", "Results", visibleLUTs)]
        }
        switch filter {
        case "Favourites": return [("fav", "Favourites", visibleLUTs)]
        case "Recents":   return [("rec", "Recents", visibleLUTs)]
        default:
            var groups: [(String, String, [LUTFile])] = []
            let all = app.lutRepository.luts
            // Your collections lead — that's what curation is FOR.
            for collection in app.lutRepository.collections {
                let members = app.lutRepository.members(of: collection)
                if !members.isEmpty {
                    groups.append(("col-\(collection.id)", collection.name, members))
                }
            }
            let installed = all.filter { $0.packID != nil }
            for (pid, luts) in Dictionary(grouping: installed, by: { $0.packID! })
                .sorted(by: { $0.key < $1.key }) {
                groups.append((pid, LookLibraryStore.packDisplayName(id: pid) ?? "Installed Pack", luts))
            }
            let imports = all.filter { $0.packID == nil }
            if !imports.isEmpty { groups.append(("imports", "Your Imports", imports)) }
            return groups.map { ($0.0, $0.1, $0.2) }
        }
    }

    @ViewBuilder
    private func lutRow(_ lut: LUTFile, _ index: Int) -> some View {
        LUTRow(lut: lut,
               image: thumbs.images[LookThumbs.key(LibraryLook(lut: lut))],
               onRename: { target in
                   renameText = target.displayName
                   renaming = target
               },
               onNewCollection: { showNewCollection = true },
               onDelete: { deleting = $0 })
            .listRowBackground(LumaTheme.surface)
            // Only user imports are deletable, and never on a full swipe:
            // bundled Basics can't be re-seeded and pack cubes belong to the
            // pack, so a stray gesture would destroy them with no way back.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if lut.packID == nil {
                    Button(role: .destructive) { deleting = lut } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .swipeActions(edge: .leading) {
                Button { app.lutRepository.toggleFavourite(lut) } label: {
                    Label(lut.isFavourite ? "Unfavourite" : "Favourite",
                          systemImage: lut.isFavourite ? "star.slash" : "star")
                }
                .tint(LumaTheme.gold)
            }
            .contextMenu {
                // T2.7 — collection membership.
                if app.lutRepository.collections.isEmpty {
                    Button { showNewCollection = true } label: {
                        Label("New Collection…", systemImage: "folder.badge.plus")
                    }
                } else {
                    ForEach(app.lutRepository.collections) { collection in
                        let isIn = (lut.collectionIDs ?? []).contains(collection.id)
                        Button {
                            app.lutRepository.toggle(lut, in: collection)
                        } label: {
                            Label(collection.name,
                                  systemImage: isIn ? "checkmark.circle.fill" : "folder")
                        }
                    }
                    Divider()
                    Button { showNewCollection = true } label: {
                        Label("New Collection…", systemImage: "folder.badge.plus")
                    }
                }
            }
    }

    var body: some View {
        LumaScreen(title: "LUT Files", trailingIcon: "plus",
                   trailingAction: { showImporter = true }, showBack: true,
                   scrollable: false) {
            filterChips

            searchField

            listBody
                .padding(.horizontal, -22)   // the List brings its own insets
        }
        // Real rendered thumbnails (same renderer as every apply surface) —
        // the rows used to show index-rotated stock art.
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.lutRepository.luts.count)") {
            thumbs.render(source: app.previewFrame,
                          library: app.lutRepository.luts.map { LibraryLook(lut: $0) },
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        .alert("New Collection", isPresented: $showNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { app.lutRepository.createCollection(name: name) }
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        } message: {
            Text("Group LUTs your way — long-press any LUT to add it.")
        }
        .alert("Rename LUT", isPresented: Binding(get: { renaming != nil },
                                                 set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let lut = renaming, !name.isEmpty { app.lutRepository.rename(lut, to: name) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete \(deleting?.displayName ?? "LUT")?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let lut = deleting { app.lutRepository.delete(lut) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This removes the .cube file from your library. You'll need to import it again.")
        }
        // Picking a file no longer imports it — G2 validates and previews
        // first, and only saves on the user's word.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [Self.cubeType, .plainText, .png, .data],
                      allowsMultipleSelection: false) { result in
            importError = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pendingImport = PickedFile(url: url)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(item: $pendingImport) { picked in
            LUTImportSheet(sourceURL: picked.url, origin: picked.origin)
                .environmentObject(app)
        }
        // Headless check of G2: LUMA_SEED_LUT_IMPORT=<path> opens the import
        // sheet on that file straight from LUT Files.
        .task {
            #if DEBUG
            if let path = ProcessInfo.processInfo.environment["LUMA_SEED_LUT_IMPORT"],
               FileManager.default.fileExists(atPath: path) {
                pendingImport = PickedFile(url: URL(fileURLWithPath: path), origin: "Files")
            }
            #endif
        }
    }

    /// Live count behind each filter, so the chips say what they'd show
    /// before you tap them.
    private func count(for option: String) -> Int {
        switch option {
        case "Favourites": return app.lutRepository.luts.filter(\.isFavourite).count
        case "Recents":    return recentLUTs.count
        default:           return app.lutRepository.luts.count
        }
    }

    /// The same counted scrolling chips the Looks tab uses (LookBrowserSheet),
    /// not a separate segmented control — these are two views onto one library
    /// and must read as one system.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["All", "Favourites", "Recents"], id: \.self) { option in
                    let selected = filter == option
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            filter = option
                        }
                        LumaHaptics.shared.tap()
                    } label: {
                        HStack(spacing: 6) {
                            Text(option)
                                .font(.luma(size: 13, weight: selected ? .semibold : .regular))
                            Text("\(count(for: option))")
                                .font(.luma(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(selected ? .white.opacity(0.85)
                                                          : LumaTheme.textMuted)
                        }
                        .foregroundStyle(selected ? LumaTheme.onSignal : LumaTheme.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background {
                            if selected {
                                Capsule().fill(LumaTheme.accent)
                            } else {
                                Capsule().fill(LumaTheme.chip)
                            }
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
                Spacer(minLength: 0)
            }
        }
        .scrollClipDisabled()
    }

    /// T2.7 search, rendered inline. `.searchable` needs a navigation bar and
    /// LumaScreen hides it, so the bar never appeared — same field treatment as
    /// LookBrowserSheet so the two library surfaces match.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
            TextField("Search LUTs and tags", text: $searchText)
                .font(.luma(size: 15))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
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
    }

    private var listBody: some View {
        List {
            if let importError {
                Section {
                    Label(importError, systemImage: "exclamationmark.triangle")
                        .font(.luma(.subheadline))
                        .foregroundStyle(LumaTheme.orange)
                        .listRowBackground(LumaTheme.surface)
                }
            }

            if visibleLUTs.isEmpty {
                // Import lives in the header on every other state; the empty
                // state is the one place it earns a second, labelled door,
                // because there is nothing else on screen to act on.
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 34))
                            .foregroundStyle(LumaTheme.textMuted)
                        Text("No LUTs Here Yet")
                            .font(.luma(.headline))
                            .foregroundStyle(LumaTheme.textSecondary)
                        Text("Import a .cube file to get started.")
                            .font(.luma(.subheadline))
                            .foregroundStyle(LumaTheme.textMuted)
                        Button {
                            showImporter = true
                            LumaHaptics.shared.tap()
                        } label: {
                            Label("Import LUT", systemImage: "plus")
                                .font(.luma(size: 13, weight: .semibold))
                                .foregroundStyle(LumaTheme.onSignal)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(LumaTheme.accent, in: Capsule())
                        }
                        .buttonStyle(.lumaPress)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(lutGroups, id: \.id) { group in
                    Section {
                        ForEach(Array(group.luts.enumerated()), id: \.element.id) { index, lut in
                            lutRow(lut, index)
                        }
                    } header: {
                        Text("\(group.title) · \(group.luts.count)")
                    }
                }
            }

            // Kept as a closing note rather than a banner above the library —
            // it explains a route into the app, it is not an action.
            Section {
                EmptyView()
            } footer: {
                Text("You can also open .cube files or ZIP packs from the Files app — they import straight into this library.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // The List sat under LumaScreen's 20pt stack spacing AND contributed
        // its own ~35pt top inset, so a 2-item library opened with a band of
        // empty black between the search field and the first group.
        .listSectionSpacing(16)
        .contentMargins(.top, 0, for: .scrollContent)
        // LumaScreen's VStack already spaces this band; the List's own section
        // inset on top of it read as a ~55pt void under the search field.
        .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct LUTRow: View {
    @EnvironmentObject private var app: AppModel
    let lut: LUTFile
    /// Live-rendered graded thumbnail (nil until the renderer lands it).
    var image: CGImage? = nil
    /// Rename is hosted by the parent (one alert, not one per row).
    var onRename: (LUTFile) -> Void
    var onNewCollection: () -> Void
    /// Delete is hosted by the parent so one confirmation covers swipe + menu.
    var onDelete: (LUTFile) -> Void

    /// Provenance, not a blanket "Imported" — the factory Basics cubes and
    /// purchased pack cubes were never imported by the user, and saying so
    /// contradicted the same file's subtitle in the Looks grid.
    private var agoText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let ago = formatter.localizedString(for: lut.importedAt, relativeTo: Date())
        guard let packID = lut.packID else { return "Imported \(ago)" }
        if packID == LUTRepository.bundledBasicsPackID { return "Included with Lumalook" }
        if let name = LookLibraryStore.packDisplayName(id: packID) { return "From \(name)" }
        return "Installed \(ago)"
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    GradedThumb(image: image, size: CGSize(width: 56, height: 42), radius: 8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LumaTheme.surfaceStrong)
                        .overlay(Image(systemName: "cube.transparent")
                            .font(.luma(size: 14))
                            .foregroundStyle(LumaTheme.textMuted))
                }
            }
            .frame(width: 56, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(lut.displayName)
                        .font(.luma(.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if lut.isFavourite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(LumaTheme.gold)
                    }
                }
                Text(agoText)
                    .font(.luma(.footnote))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            Spacer()
            Menu {
                Button("Apply to Current Clip") {
                    app.select(look: LibraryLook(lut: lut))
                    // If nothing's loaded, pick media first (LUT stays selected)
                    // instead of landing on an empty grade room.
                    if app.selectedVideoURL != nil || app.selectedImage != nil {
                        app.path.append(.applyLook)
                    } else {
                        app.path.append(.selectClip)
                    }
                }
                if lut.packID == nil {
                    Button("Rename…") { onRename(lut) }
                }
                Button(lut.isFavourite ? "Remove Favourite" : "Favourite") {
                    app.lutRepository.toggleFavourite(lut)
                }
                Menu("Collections") {
                    ForEach(app.lutRepository.collections) { collection in
                        let isIn = (lut.collectionIDs ?? []).contains(collection.id)
                        Button {
                            app.lutRepository.toggle(lut, in: collection)
                        } label: {
                            Label(collection.name,
                                  systemImage: isIn ? "checkmark.circle.fill" : "folder")
                        }
                    }
                    Button("New Collection…") { onNewCollection() }
                }
                // Same ownership rule as the Look Library's row menu: only
                // your own imports can be deleted; pack cubes route to the
                // pack, and bundled Basics offer nothing destructive at all.
                if lut.packID == nil {
                    Button("Delete", role: .destructive) { onDelete(lut) }
                } else if lut.packID != LUTRepository.bundledBasicsPackID {
                    Button {
                        app.selectedPackID = lut.packID
                        app.path.append(.filterPack)
                    } label: { Label("View Pack…", systemImage: "square.grid.2x2") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(width: 32, height: 36)
            }
        }
        .padding(.vertical, 2)
    }
}

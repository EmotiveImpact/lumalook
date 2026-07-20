import SwiftUI
import UniformTypeIdentifiers

/// My LUTs as a NATIVE inset-grouped List (Apple-native tranche 2): swipe
/// to delete/favourite, native separators and grouping — the moment a
/// screen becomes a list of records, it should feel like Settings does.
struct LUTManagerView: View {
    @EnvironmentObject private var app: AppModel
    @State private var filter = "All"
    @State private var showImporter = false
    /// T2.7 — live search over names + tags.
    @State private var searchText = ""
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var importError: String?
    @State private var importedName: String?

    private static let cubeType = UTType(filenameExtension: "cube") ?? .data

    private var visibleLUTs: [LUTFile] {
        let base: [LUTFile]
        switch filter {
        case "Favorites": base = app.lutRepository.luts.filter(\.isFavourite)
        case "Recents": base = Array(app.lutRepository.luts.prefix(3))
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
        case "Favorites": return [("fav", "Favorites", visibleLUTs)]
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
        LUTRow(lut: lut, scene: MockScene.allCases[index % MockScene.allCases.count])
            .listRowBackground(LumaTheme.surface)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { app.lutRepository.delete(lut) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                Button { app.lutRepository.toggleFavourite(lut) } label: {
                    Label(lut.isFavourite ? "Unfavorite" : "Favorite",
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
        LumaScreen(title: "My LUTs", trailingIcon: "plus",
                   trailingAction: { showImporter = true }, showBack: true,
                   scrollable: false) {
            SegmentPills(options: ["All", "Favorites", "Recents"], selection: $filter)

            listBody
                .padding(.horizontal, -22)   // the List brings its own insets
        }
        .searchable(text: $searchText, prompt: "Search LUTs and tags")
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
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [Self.cubeType, .plainText, .png, .data],
                      allowsMultipleSelection: false) { result in
            importError = nil
            importedName = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let ext = url.pathExtension.lowercased()
                guard ["cube", "3dl", "png"].contains(ext) else {
                    importError = "Choose a .cube, .3dl or HALD .png LUT."
                    return
                }
                do {
                    let file = try app.lutRepository.importLUT(from: url)
                    importedName = file.displayName
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var listBody: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Import LUT", systemImage: "square.and.arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .listRowBackground(LumaTheme.surface)

                if let importedName {
                    Label("\(importedName) imported", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaTheme.teal)
                        .listRowBackground(LumaTheme.surface)
                }
                if let importError {
                    Label(importError, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(LumaTheme.orange)
                        .listRowBackground(LumaTheme.surface)
                }
            } footer: {
                Text("You can also open .cube files or ZIP packs from the Files app — they import straight into this library.")
            }

            if visibleLUTs.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 34))
                            .foregroundStyle(LumaTheme.textMuted)
                        Text("No LUTs Here Yet")
                            .font(.headline)
                            .foregroundStyle(LumaTheme.textSecondary)
                        Text("Import a .cube file to get started.")
                            .font(.subheadline)
                            .foregroundStyle(LumaTheme.textMuted)
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

private struct LUTRow: View {
    @EnvironmentObject private var app: AppModel
    let lut: LUTFile
    var scene: MockScene = .sunsetRoad

    private var agoText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Imported \(formatter.localizedString(for: lut.importedAt, relativeTo: Date()))"
    }

    var body: some View {
        HStack(spacing: 14) {
            SceneThumb(scene: scene, radius: 8)
                .frame(width: 56, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(lut.displayName)
                        .font(.body.weight(.semibold))
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
                    .font(.footnote)
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
                Button(lut.isFavourite ? "Remove Favorite" : "Favorite") {
                    app.lutRepository.toggleFavourite(lut)
                }
                Button("Delete", role: .destructive) {
                    app.lutRepository.delete(lut)
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

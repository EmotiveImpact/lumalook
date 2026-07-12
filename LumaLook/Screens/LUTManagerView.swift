import SwiftUI
import UniformTypeIdentifiers

/// My LUTs as a NATIVE inset-grouped List (Apple-native tranche 2): swipe
/// to delete/favourite, native separators and grouping — the moment a
/// screen becomes a list of records, it should feel like Settings does.
struct LUTManagerView: View {
    @EnvironmentObject private var app: AppModel
    @State private var filter = "Imported"
    @State private var showImporter = false
    @State private var importError: String?
    @State private var importedName: String?

    private static let cubeType = UTType(filenameExtension: "cube") ?? .data

    private var visibleLUTs: [LUTFile] {
        switch filter {
        case "Favorites": return app.lutRepository.luts.filter(\.isFavourite)
        case "Recents": return Array(app.lutRepository.luts.prefix(3))
        default: return app.lutRepository.luts
        }
    }

    var body: some View {
        LumaScreen(title: "My LUTs", trailingIcon: "plus",
                   trailingAction: { showImporter = true }, showBack: true,
                   scrollable: false) {
            SegmentPills(options: ["Imported", "Favorites", "Recents"], selection: $filter)

            listBody
                .padding(.horizontal, -22)   // the List brings its own insets
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [Self.cubeType, .plainText, .data],
                      allowsMultipleSelection: false) { result in
            importError = nil
            importedName = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.pathExtension.lowercased() == "cube" else {
                    importError = "Please choose a .cube LUT file."
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
                Section {
                    ForEach(Array(visibleLUTs.enumerated()), id: \.element.id) { index, lut in
                        LUTRow(lut: lut, scene: MockScene.allCases[index % MockScene.allCases.count])
                            .listRowBackground(LumaTheme.surface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    app.lutRepository.delete(lut)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    app.lutRepository.toggleFavourite(lut)
                                } label: {
                                    Label(lut.isFavourite ? "Unfavorite" : "Favorite",
                                          systemImage: lut.isFavourite ? "star.slash" : "star")
                                }
                                .tint(LumaTheme.gold)
                            }
                    }
                } header: {
                    Text("\(visibleLUTs.count) LUT\(visibleLUTs.count == 1 ? "" : "s")")
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
                    Text(lut.originalFileName)
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
                    app.selectedLUT = lut
                    app.path.append(.applyLook)
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

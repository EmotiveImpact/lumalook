import SwiftUI
import UniformTypeIdentifiers

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
                   trailingAction: { showImporter = true }, showBack: true) {
            SegmentPills(options: ["Imported", "Favorites", "Recents"], selection: $filter)

            SolidCTA(title: "+ Import LUT", height: 56, fill: LumaTheme.accentDeep) {
                showImporter = true
            }

            if let importedName {
                Label("\(importedName) imported", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.teal)
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(LumaTheme.orange)
            }

            if visibleLUTs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 34))
                        .foregroundStyle(LumaTheme.textMuted)
                    Text("No LUTs here yet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
                    Text("Import a .cube file to get started.")
                        .font(.system(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleLUTs.enumerated()), id: \.element.id) { index, lut in
                        LUTRow(lut: lut, scene: MockScene.allCases[index % MockScene.allCases.count])
                        if index < visibleLUTs.count - 1 {
                            Hairline().padding(.leading, 78)
                        }
                    }
                }
            }
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
            SceneThumb(scene: scene, radius: 10)
                .frame(width: 64, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(lut.originalFileName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .truncationMode(.middle)
                Text(agoText)
                    .font(.system(size: 14))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            Spacer()
            Button {
                app.lutRepository.toggleFavourite(lut)
            } label: {
                Image(systemName: lut.isFavourite ? "star.fill" : "star")
                    .font(.system(size: 20))
                    .foregroundStyle(lut.isFavourite ? LumaTheme.gold : LumaTheme.textSecondary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            Menu {
                Button("Apply to current clip") {
                    app.selectedLUT = lut
                    app.path.append(.applyLook)
                }
                Button("Delete", role: .destructive) {
                    app.lutRepository.delete(lut)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(width: 30, height: 36)
            }
        }
        .padding(.vertical, 12)
    }
}

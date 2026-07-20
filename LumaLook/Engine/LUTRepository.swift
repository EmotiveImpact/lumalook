import Foundation

@MainActor
final class LUTRepository: ObservableObject {
    @Published private(set) var luts: [LUTFile] = []
    /// T2.7 — user collections, persisted beside the LUT index.
    @Published private(set) var collections: [LUTCollection] = []

    private let folderName = "ImportedLUTs"
    private let indexFileName = "luts_index.json"

    var lutFolderURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(folderName, isDirectory: true)
    }

    private var indexURL: URL {
        lutFolderURL.appendingPathComponent(indexFileName)
    }

    init() {
        load()
        loadCollections()
        seedBundledLUTsIfNeeded()
    }

    // MARK: - T2.7 collections + tags

    private var collectionsURL: URL {
        lutFolderURL.appendingPathComponent("collections_index.json")
    }

    private func loadCollections() {
        guard let data = try? Data(contentsOf: collectionsURL),
              let decoded = try? JSONDecoder().decode([LUTCollection].self, from: data) else { return }
        collections = decoded
    }

    private func saveCollections() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: collectionsURL, options: .atomic)
    }

    @discardableResult
    func createCollection(name: String, symbol: String = "folder") -> LUTCollection {
        let collection = LUTCollection(name: name, symbol: symbol)
        collections.append(collection)
        saveCollections()
        return collection
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        for i in luts.indices { luts[i].collectionIDs?.remove(id) }
        saveCollections(); save()
    }

    func toggle(_ lut: LUTFile, in collection: LUTCollection) {
        guard let li = luts.firstIndex(where: { $0.id == lut.id }),
              let ci = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        var ids = luts[li].collectionIDs ?? []
        if ids.contains(collection.id) {
            ids.remove(collection.id)
            collections[ci].orderedLUTIDs.removeAll { $0 == lut.id }
        } else {
            ids.insert(collection.id)
            collections[ci].orderedLUTIDs.append(lut.id)
        }
        luts[li].collectionIDs = ids
        saveCollections(); save()
    }

    func setTags(_ tags: [String], for lut: LUTFile) {
        guard let i = luts.firstIndex(where: { $0.id == lut.id }) else { return }
        luts[i].tags = tags.isEmpty ? nil : tags
        save()
    }

    /// Members of a collection in its stored order.
    func members(of collection: LUTCollection) -> [LUTFile] {
        collection.orderedLUTIDs.compactMap { id in luts.first { $0.id == id } }
    }

    func fileURL(for lut: LUTFile) -> URL {
        lutFolderURL.appendingPathComponent(lut.fileName)
    }

    @discardableResult
    func importLUT(from sourceURL: URL, displayName: String? = nil, packID: String? = nil) throws -> LUTFile {
        try FileManager.default.createDirectory(at: lutFolderURL, withIntermediateDirectories: true)

        let needsAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        // Parse before storing so invalid files are rejected with a useful error.
        let parsed = try LUTParser.parseCubeFile(at: sourceURL)

        let uniqueName = "\(UUID().uuidString)_\(sourceURL.lastPathComponent)"
        let destination = lutFolderURL.appendingPathComponent(uniqueName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let file = LUTFile(
            displayName: displayName
                ?? sourceURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
            originalFileName: sourceURL.lastPathComponent,
            fileName: uniqueName,
            cubeSize: parsed.size,
            fileSizeBytes: (attrs?[.size] as? NSNumber)?.intValue,
            importedAt: Date(),
            isFavourite: false,
            packID: packID
        )

        luts.insert(file, at: 0)
        save()
        return file
    }

    func toggleFavourite(_ lut: LUTFile) {
        guard let index = luts.firstIndex(where: { $0.id == lut.id }) else { return }
        luts[index].isFavourite.toggle()
        save()
    }

    func delete(_ lut: LUTFile) {
        try? FileManager.default.removeItem(at: fileURL(for: lut))
        luts.removeAll { $0.id == lut.id }
        save()
    }

    /// Remembers this LUT's creative-slot opacity + blend (per-LUT strength).
    func setDefaults(for id: UUID, opacity: Double, blend: String) {
        guard let index = luts.firstIndex(where: { $0.id == id }) else { return }
        luts[index].defaultOpacity = opacity
        luts[index].defaultBlend = blend
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LUTFile].self, from: data) else { return }
        luts = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(at: lutFolderURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(luts) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Pack id stamped on the factory-seeded bundle cubes so they read as the
    /// "Basics" pack, not user imports (they'd otherwise pollute "Your
    /// Imports" and be silently deletable with no in-app recovery).
    static let bundledBasicsPackID = "bundled-basics"

    private func seedBundledLUTsIfNeeded() {
        guard luts.isEmpty else { return }
        let bundled = Bundle.main.urls(forResourcesWithExtension: "cube", subdirectory: nil) ?? []
        // FS_ film stocks are pack-managed (installed from the Store), not
        // auto-seeded — otherwise fresh installs get 14 duplicates.
        for url in bundled
        where !url.lastPathComponent.hasPrefix("Identity")
            && !url.lastPathComponent.hasPrefix("FS_") {
            _ = try? importLUT(from: url, packID: Self.bundledBasicsPackID)
        }
    }
}

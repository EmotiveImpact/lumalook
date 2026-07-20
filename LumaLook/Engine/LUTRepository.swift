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
        toggleLook(id: "lut:\(lut.id.uuidString)", in: collection.id)
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

    // MARK: - G3 collections: widened membership, ordering, camera pin

    /// A collection's members as `LibraryLook.id` strings, in stored order.
    /// Pre-G3 indexes have no `orderedLookIDs`, so their LUT uuids are lifted
    /// into the id scheme on read; the file itself migrates on the next write.
    func memberLookIDs(of collection: LUTCollection) -> [String] {
        collection.orderedLookIDs ?? collection.orderedLUTIDs.map { "lut:\($0.uuidString)" }
    }

    func contains(lookID: String, in collectionID: UUID) -> Bool {
        guard let c = collections.first(where: { $0.id == collectionID }) else { return false }
        return memberLookIDs(of: c).contains(lookID)
    }

    func addLook(id lookID: String, to collectionID: UUID) {
        guard let ci = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var ids = memberLookIDs(of: collections[ci])
        guard !ids.contains(lookID) else { return }
        ids.append(lookID)
        writeMembers(ids, into: ci)
        setCollectionBit(lookID, collectionID, member: true)
        saveCollections(); save()
    }

    func removeLook(id lookID: String, from collectionID: UUID) {
        guard let ci = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var ids = memberLookIDs(of: collections[ci])
        guard let at = ids.firstIndex(of: lookID) else { return }
        ids.remove(at: at)
        writeMembers(ids, into: ci)
        setCollectionBit(lookID, collectionID, member: false)
        saveCollections(); save()
    }

    func toggleLook(id lookID: String, in collectionID: UUID) {
        if contains(lookID: lookID, in: collectionID) {
            removeLook(id: lookID, from: collectionID)
        } else {
            addLook(id: lookID, to: collectionID)
        }
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].name = trimmed
        saveCollections()
    }

    /// Display order of the collections list itself.
    func moveCollections(fromOffsets source: IndexSet, toOffset destination: Int) {
        collections.move(fromOffsets: source, toOffset: destination)
        saveCollections()
    }

    /// The collection currently acting as the camera filmstrip palette.
    var pinnedCollection: LUTCollection? {
        collections.first { $0.pinnedToCamera == true }
    }

    /// Pins one collection to the camera filmstrip, unpinning any other.
    /// Passing nil (or the already-pinned id) restores the default ordering.
    func setPinnedCollection(_ id: UUID?) {
        for i in collections.indices {
            collections[i].pinnedToCamera = (collections[i].id == id) ? true : nil
        }
        saveCollections()
    }

    /// Canonical write: `orderedLookIDs` is the truth, `orderedLUTIDs` is kept
    /// as its LUT-only projection so existing readers stay correct.
    private func writeMembers(_ ids: [String], into index: Int) {
        collections[index].orderedLookIDs = ids
        collections[index].orderedLUTIDs = ids.compactMap(Self.lutID)
    }

    /// LUT files carry a reverse membership set used by the LUT manager's
    /// filters — keep it in step for LUT members only.
    private func setCollectionBit(_ lookID: String, _ collectionID: UUID, member: Bool) {
        guard let uuid = Self.lutID(lookID),
              let li = luts.firstIndex(where: { $0.id == uuid }) else { return }
        var ids = luts[li].collectionIDs ?? []
        if member { ids.insert(collectionID) } else { ids.remove(collectionID) }
        luts[li].collectionIDs = ids
    }

    private static func lutID(_ lookID: String) -> UUID? {
        guard lookID.hasPrefix("lut:") else { return nil }
        return UUID(uuidString: String(lookID.dropFirst(4)))
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

    /// Renames an imported LUT's display name (the stored file is untouched).
    func rename(_ lut: LUTFile, to newName: String) {
        guard let index = luts.firstIndex(where: { $0.id == lut.id }) else { return }
        luts[index].displayName = newName
        save()
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

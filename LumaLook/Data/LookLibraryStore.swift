import Foundation
import Combine

/// The one aggregation point for every look the user can apply — saved looks,
/// built-in signature presets, installed pack LUTs, and imported LUTs — plus
/// the cross-source features no single underlying store could own: favourites
/// that span sources, true recently-USED looks, search, and category filters.
///
/// Reads the three live stores (`PersistenceStore`, `LUTRepository`,
/// `PackStore`) and re-publishes whenever any of them mutate, so every
/// surface stays current when a pack installs or a LUT imports.
@MainActor
final class LookLibraryStore: ObservableObject {
    private let persistence: PersistenceStore
    private let luts: LUTRepository
    private let packs: PackStore
    private var cancellables = Set<AnyCancellable>()

    /// Favourite ids for sources that have no favourite bit of their own
    /// (built-in + saved looks). LUT favourites stay in luts_index.json —
    /// `LUTRepository.toggleFavourite` remains that single truth.
    private var favouriteIDs: Set<String> = []
    /// Most-recently-used look ids, newest first, capped at `recentsCap`.
    private var recentIDs: [String] = []
    private static let recentsCap = 12

    init(persistence: PersistenceStore, luts: LUTRepository, packs: PackStore) {
        self.persistence = persistence
        self.luts = luts
        self.packs = packs
        loadPersisted()
        // Forward the underlying stores' changes as our own so views observing
        // `library` (or AppModel, which forwards us) refresh on pack install,
        // LUT import/favourite, or saved-look changes.
        for publisher in [persistence.objectWillChange,
                          luts.objectWillChange,
                          packs.objectWillChange] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    // MARK: - Categories

    enum Category: String, CaseIterable, Identifiable {
        case all, favourites, recents, saved, purchased, imported, collections
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all:         return "All"
            case .favourites:  return "★ Favourites"
            case .recents:     return "Recents"
            case .saved:       return "Your Looks"
            case .purchased:   return "Purchased"
            case .imported:    return "Imported"
            case .collections: return "Collections"
            }
        }
    }

    // MARK: - The library

    /// Display name for a pack id — catalog packs by name, plus the factory
    /// seed pack that never appears in the Store catalog.
    static func packDisplayName(id: String) -> String? {
        if id == LUTRepository.bundledBasicsPackID { return "Basics" }
        return PackCatalog.pack(id: id)?.name
    }

    /// Full library, ordered Saved → Signature → Installed(purchased) → Imported.
    var all: [LibraryLook] {
        var out: [LibraryLook] = []
        for s in persistence.savedLooks {
            let id = "saved:\(s.id.uuidString)"
            out.append(LibraryLook(id: id, name: s.name, section: .saved,
                                   source: .saved(s),
                                   isFavourite: favouriteIDs.contains(id)))
        }
        for p in MockData.looks {
            let id = "builtin:\(p.name)"
            out.append(LibraryLook(id: id, name: p.name, section: .builtIn,
                                   source: .builtIn(p),
                                   isFavourite: favouriteIDs.contains(id)))
        }
        for f in luts.luts {
            let section: LibraryLook.Section = f.packID == nil ? .imported : .installed
            out.append(LibraryLook(id: "lut:\(f.id.uuidString)", name: f.displayName,
                                   section: section, source: .lut(f),
                                   isFavourite: f.isFavourite,
                                   packName: f.packID.flatMap(Self.packDisplayName)))
        }
        return out
    }

    /// Grouped for sectioned pickers, omitting empty sections.
    var bySection: [(section: LibraryLook.Section, looks: [LibraryLook])] {
        let all = self.all
        return LibraryLook.Section.allCases.compactMap { sec in
            let looks = all.filter { $0.section == sec }
            return looks.isEmpty ? nil : (sec, looks)
        }
    }

    /// Filter + search in one call — the ONLY query every surface uses.
    /// Search matches look name, pack name, and LUT tags.
    func looks(category: Category, search: String = "") -> [LibraryLook] {
        let base: [LibraryLook]
        switch category {
        case .all:         base = all
        case .favourites:  base = all.filter(\.isFavourite)
        case .recents:     base = recents
        case .saved:       base = all.filter { $0.section == .saved }
        case .purchased:   base = all.filter { $0.section == .installed }
        case .imported:    base = all.filter { $0.section == .imported }
        case .collections: base = collectionGroups.flatMap(\.looks)
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { look in
            if look.name.localizedCaseInsensitiveContains(query) { return true }
            if look.packName?.localizedCaseInsensitiveContains(query) == true { return true }
            if case .lut(let f) = look.source,
               f.tags?.contains(where: { $0.localizedCaseInsensitiveContains(query) }) == true {
                return true
            }
            return false
        }
    }

    /// [(collection, members-as-LibraryLook)] in each collection's stored
    /// order, for the Collections category. Empty collections included so the
    /// user can see (and fill) them.
    var collectionGroups: [(collection: LUTCollection, looks: [LibraryLook])] {
        let lutLooks = Dictionary(
            all.compactMap { look -> (UUID, LibraryLook)? in
                guard case .lut(let f) = look.source else { return nil }
                return (f.id, look)
            },
            uniquingKeysWith: { a, _ in a })
        return luts.collections.map { collection in
            (collection, collection.orderedLUTIDs.compactMap { lutLooks[$0] })
        }
    }

    // MARK: - Favourites (cross-source)

    func isFavourite(_ id: LibraryLook.ID) -> Bool {
        if favouriteIDs.contains(id) { return true }
        // LUT favourites live on the file record.
        if id.hasPrefix("lut:"), let uuid = UUID(uuidString: String(id.dropFirst(4))) {
            return luts.luts.first { $0.id == uuid }?.isFavourite ?? false
        }
        return false
    }

    func toggleFavourite(_ look: LibraryLook) {
        if case .lut(let f) = look.source {
            luts.toggleFavourite(f)      // single truth stays in luts_index.json
            return
        }
        objectWillChange.send()
        if favouriteIDs.contains(look.id) {
            favouriteIDs.remove(look.id)
        } else {
            favouriteIDs.insert(look.id)
        }
        savePersisted()
    }

    // MARK: - Recents (recently USED, not recently imported)

    /// Records a look application. Call from the one selection entry point
    /// (`AppModel.select(look:)`) so every surface feeds the same history.
    func noteUsed(_ look: LibraryLook) {
        objectWillChange.send()
        recentIDs.removeAll { $0 == look.id }
        recentIDs.insert(look.id, at: 0)
        if recentIDs.count > Self.recentsCap {
            recentIDs = Array(recentIDs.prefix(Self.recentsCap))
        }
        savePersisted()
    }

    /// Most-recently-used first; ids whose look no longer exists drop out.
    var recents: [LibraryLook] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return recentIDs.compactMap { byID[$0] }
    }

    // MARK: - Persistence (Documents/LookLibrary.json — NEW file, additive)

    private struct Persisted: Codable {
        var favouriteIDs: [String]
        var recentIDs: [String]
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LookLibrary.json")
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        favouriteIDs = Set(decoded.favouriteIDs)
        recentIDs = decoded.recentIDs
    }

    private func savePersisted() {
        let payload = Persisted(favouriteIDs: Array(favouriteIDs), recentIDs: recentIDs)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

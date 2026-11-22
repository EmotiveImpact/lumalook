import Foundation
import Combine
import CoreImage

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

    /// Built-in signature looks superseded by installable pack looks (gap 7):
    /// built-in display name → the pack-look name/code that replaces it. Once
    /// the matching pack LUT is installed the built-in is hidden, so the
    /// library never shows visually-duplicate pairs with different pipelines.
    private static let builtInReplacements: [String: String] = [
        "KD2 · Golden Hour":       "KD2",
        "KD52 · Cine Negative":    "KD52",
        "CN83 · Teal & Orange":    "CN83",
        "CN93 · Luxury Campaign":  "CN93",
        "BW32 · Documentary Grit": "BW32",
        "Neon Nights":             "Neon Nights",
        "Night Drive":             "Night Drive",
        "Afrobeats Glow":          "Afrobeats Glow",
    ]

    /// The Store pack that sells the full version of a built-in signature
    /// look, if any. The same table drives library de-duplication above and
    /// the export gate (`StoreService.lock(forBuiltIn:)`), so "which pack
    /// unlocks this look" can never disagree with "which pack replaces it".
    static func supersedingPack(forBuiltIn name: String) -> LookPack? {
        guard let code = builtInReplacements[name] else { return nil }
        return PackCatalog.packs.first { pack in
            pack.looks.contains { $0.code == code || $0.name == code || $0.name.hasPrefix(code + " ") }
        }
    }

    /// Full library, ordered Saved → Signature → Installed(purchased) → Imported.
    var all: [LibraryLook] {
        var out: [LibraryLook] = []
        for s in persistence.savedLooks {
            var look = LibraryLook(saved: s)
            look.isFavourite = favouriteIDs.contains(look.id)
            out.append(look)
        }
        // Store-pack LUT names (not the factory seed pack) for duplicate
        // suppression — "KD2 · Morning Gold" replaces "KD2 · Golden Hour".
        let installedNames = luts.luts
            .filter { $0.packID != nil && $0.packID != LUTRepository.bundledBasicsPackID }
            .map(\.displayName)
        for p in MockData.looks {
            if let code = Self.builtInReplacements[p.name],
               installedNames.contains(where: { $0 == code || $0.hasPrefix(code + " ") }) {
                continue
            }
            var look = LibraryLook(builtIn: p)
            look.isFavourite = favouriteIDs.contains(look.id)
            out.append(look)
        }
        for f in luts.luts {
            out.append(LibraryLook(lut: f, packName: f.packID.flatMap(Self.packDisplayName)))
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
        // G3 widened membership: collections hold any library look, keyed by
        // LibraryLook.id (LUT-only indexes are lifted by memberLookIDs).
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return luts.collections.map { collection in
            (collection, luts.memberLookIDs(of: collection).compactMap { byID[$0] })
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
        // Freeze what is on screen BEFORE recording, so the tile the user
        // just tapped keeps its place (see "Stable order while picking").
        if pickingOrder == nil {
            pickingOrder = PickingOrder(strip: freshStripOrder(all: all), recents: recentIDs)
        }
        if pickingOrder?.promoted.contains(look.id) == false {
            pickingOrder?.promoted.insert(look.id, at: 0)
        }
        recentIDs.removeAll { $0 == look.id }
        recentIDs.insert(look.id, at: 0)
        if recentIDs.count > Self.recentsCap {
            recentIDs = Array(recentIDs.prefix(Self.recentsCap))
        }
        savePersisted()
    }

    /// Most-recently-used first; ids whose look no longer exists drop out.
    /// While the user is picking, the list keeps the order it had when they
    /// started: a look already listed stays put, and a look used for the
    /// first time this session joins at the top.
    var recents: [LibraryLook] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids: [String]
        if let order = pickingOrder {
            ids = Array((order.promoted.filter { !order.recents.contains($0) } + order.recents)
                .prefix(Self.recentsCap))
        } else {
            ids = recentIDs
        }
        return ids.compactMap { byID[$0] }
    }

    // MARK: - The strip, and a stable order while picking
    //
    // Every apply surface leads with the same bounded strip: the collection
    // pinned to the camera filmstrip (G3) first, then recently used, then
    // favourites, then the rest of the library, deduped and capped so
    // thumbnail rendering stays cheap. The full library lives one tap away
    // behind "All looks".
    //
    // Recently used comes second, so recording a pick used to move the tapped
    // tile to the front of its strip (and the grade room then scrolled after
    // it): the user lost their place on every tap. Now the first pick freezes
    // the order on screen. Picks still record straight away, and the strip
    // and the Recents grid catch up the next time a picking screen opens
    // (`settleOrder()`).

    private struct PickingOrder {
        /// The full strip order when picking began, pinned looks first.
        var strip: [String]
        /// The recents order when picking began.
        var recents: [String]
        /// Looks picked since, in first-pick order, newest first. Never
        /// reordered, so picking one again can never move it.
        var promoted: [String] = []
    }

    private var pickingOrder: PickingOrder?

    /// The strip, `limit` long. While picking, a look chosen somewhere else
    /// (the full browser, Home) that this strip is not showing joins just
    /// after the pinned looks, so the selection is always on screen; a look
    /// the strip already shows never moves.
    func stripLooks(limit: Int = 14) -> [LibraryLook] {
        let all = self.all
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let order = pickingOrder else {
            return freshStripOrder(all: all).prefix(limit).compactMap { byID[$0] }
        }
        // The pinned collection can change from All looks without leaving
        // the camera, so its prefix follows live membership; the rest keeps
        // the frozen order. A look unpinned meanwhile stays where it was.
        var seen = Set<String>()
        let pinned = pinnedCollectionLooks.map(\.id).filter { seen.insert($0).inserted }
        let unpinned = order.strip.filter { byID[$0] != nil && !seen.contains($0) }
        var ids = Array((pinned + unpinned).prefix(limit))
        for id in order.promoted.reversed() where !ids.contains(id) && byID[id] != nil {
            ids.insert(id, at: min(pinned.count, ids.count))
            if ids.count > limit,
               let drop = ids.lastIndex(where: { !order.promoted.contains($0) }) {
                ids.remove(at: drop)
            }
        }
        return ids.compactMap { byID[$0] }
    }

    /// Call when a screen that picks looks appears (camera, grade room,
    /// editor, Looks tab), so its strips pick up the recents recorded last
    /// time. Never call it from a sheet: the strip behind would reshuffle.
    func settleOrder() {
        guard pickingOrder != nil else { return }
        objectWillChange.send()
        pickingOrder = nil
    }

    private func freshStripOrder(all: [LibraryLook]) -> [String] {
        let known = Set(all.map(\.id))
        var seen = Set<String>()
        var ids: [String] = []
        for look in pinnedCollectionLooks where seen.insert(look.id).inserted {
            ids.append(look.id)
        }
        for id in recentIDs where known.contains(id) && seen.insert(id).inserted {
            ids.append(id)
        }
        for look in all where look.isFavourite && seen.insert(look.id).inserted {
            ids.append(look.id)
        }
        for look in all where seen.insert(look.id).inserted {
            ids.append(look.id)
        }
        return ids
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

// MARK: - Reference swatch frame

/// The frame every look thumbnail is graded through BEFORE the user loads
/// their own media. A look grid is only useful if you can pick with your eyes
/// rather than by name, and that requires a source frame that actually
/// exercises a grade: neutral midtones, skin tone, a clean specular highlight
/// and shadow detail that still holds separation. A single-hue blown-out
/// sunset (the old default) clips the blue channel flat, so twelve very
/// different grades all resolve to the same orange tile.
///
/// So the swatch is a wide-gamut photograph — sky blue, magenta cloud, green
/// midtones, neutral water highlight, deep shadow — with a reference patch
/// band composited along the bottom edge: shadow, mid grey, two skin tones and
/// a highlight. A colour cast, a lifted black, a crushed highlight or a skin
/// shift all become visible at 110pt, which is the whole point of the grid.
enum LookSwatch {
    /// Bottom band as a fraction of frame height.
    private static let bandFraction: CGFloat = 0.15

    /// sRGB reference patches, left → right.
    private static let patchValues: [(CGFloat, CGFloat, CGFloat)] = [
        (0.09, 0.09, 0.10),   // shadow — is black detail retained or crushed?
        (0.46, 0.46, 0.46),   // 18% mid grey — reads any colour cast instantly
        (0.86, 0.66, 0.55),   // light skin
        (0.45, 0.30, 0.24),   // deep skin
        (0.95, 0.95, 0.93),   // clean highlight — reads highlight rolloff
    ]

    private static func color(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CIColor {
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let c = CIColor(red: rgb.0, green: rgb.1, blue: rgb.2, colorSpace: space) {
            return c
        }
        return CIColor(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// Rendered once; safe to hand straight to `LookThumbs.render(source:)`.
    static let referenceFrame: CIImage = {
        // Coast over golden: the golden hero is a single clipped hue, the
        // coast frame spans blue → magenta → green → neutral → black.
        guard let photo = HeroPhoto.bridge.ciImage ?? HeroPhoto.golden.ciImage else {
            return CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.13))
                .cropped(to: CGRect(x: 0, y: 0, width: 440, height: 300))
        }
        let longest = max(photo.extent.width, photo.extent.height)
        let scale = longest > 440 ? 440 / longest : 1
        let scaled = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Normalise the origin so the band maths below is in frame space.
        let base = scaled.transformed(by: CGAffineTransform(
            translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        let size = base.extent.size
        guard size.width > 1, size.height > 1 else { return base }

        // CIImage is bottom-left origin, so y = 0 IS the bottom band.
        let bandHeight = (size.height * bandFraction).rounded()
        let patchWidth = size.width / CGFloat(patchValues.count)
        var out = base
        for (index, rgb) in patchValues.enumerated() {
            let rect = CGRect(x: (CGFloat(index) * patchWidth).rounded(.down),
                              y: 0,
                              width: patchWidth.rounded(.up),
                              height: bandHeight)
            out = CIImage(color: color(rgb)).cropped(to: rect).composited(over: out)
        }
        return out.cropped(to: CGRect(origin: .zero, size: size))
    }()
}

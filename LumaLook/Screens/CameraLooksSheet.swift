import SwiftUI
import CoreImage
import StoreKit

// =============================================================================
// CameraLooksSheet — every look in the app, inside the camera (camera A).
//
// Tap the look name on the camera and this slides up over the lower picture,
// which stays live above it: favourites first (the looks the picture swipes
// through), then Signature, then every pack as one sideways row, then your
// own looks and imports. Search and quick filters along the top, strength
// along the bottom. Long-press any look to add it to (or take it out of) the
// swipe.
//
// Paid looks are free to try. A pack look that is not installed is worn as a
// try-on (`AppModel.packPreview`): it grades the live picture from the pack's
// own recipe or film file, and the camera only asks when you record or take a
// still. A pack the user owns installs on first use, exactly as the Store's
// Get does, so what you shoot with is a real library look.
// =============================================================================

// MARK: - A pack look being tried on

/// A pack look the camera is wearing before its pack is in the library.
struct PackLookPreview: Equatable {
    let packID: String
    let code: String

    var pack: LookPack? { PackCatalog.pack(id: packID) }
    var look: PackLook? { pack?.looks.first { $0.code == code } }

    /// The bundled film file for a measured stock; nil for a recipe look.
    var cubeURL: URL? { look.flatMap(CameraLook.cubeURL(for:)) }

    /// A recipe as a baked cube carries it: bloom and vignette are spatial
    /// passes a cube cannot hold, so the try-on leaves them out too and the
    /// preview matches what installing the pack gives.
    static func cubeRecipe(_ recipe: LookRecipe) -> LookRecipe {
        var baked = recipe
        baked.bloom = 0
        baked.vignette = 0
        return baked
    }

    /// The free look that suits each paid pack best: a free film stock, or
    /// a free Signature look, for the "shoot with" way out of the lock.
    private static let freeCodes: [String: String] = [
        "film-neg-archive": "EK100", "film-slide-archive": "PR100",
        "film-mono-archive": "TX400", "film-instant-lab": "IN669",
        "film-mirrorless-sims": "PT160", "cine-print-set-01": "CP2383",
        "bw-set-01": "TX400", "originals-01": "KD2", "after-dark": "KD52",
    ]

    /// The closest free look to this one.
    var freeAlternative: CameraLook? {
        let code = Self.freeCodes[packID] ?? "KD2"
        if let preset = MockData.looks.first(where: { !$0.isPremium && $0.code == code }) {
            return .library(LibraryLook(builtIn: preset))
        }
        if let free = PackCatalog.packs.first(where: { $0.isFree && $0.looks.contains { $0.code == code } }) {
            return .pack(packID: free.id, code: code)
        }
        return MockData.looks.first(where: { !$0.isPremium }).map { .library(LibraryLook(builtIn: $0)) }
    }
}

// MARK: - One look the camera can wear

/// Either a library look (Signature, your saved looks, imports) or a look
/// from a pack, installed or not. Pack looks keep one identity before and
/// after their pack installs, so a favourite never goes missing.
enum CameraLook: Identifiable, Equatable {
    case library(LibraryLook)
    case pack(packID: String, code: String)

    var id: String {
        switch self {
        case .library(let look): return look.id
        case .pack(let packID, let code): return "pack:\(packID):\(code)"
        }
    }

    static func == (a: CameraLook, b: CameraLook) -> Bool { a.id == b.id }

    var pack: LookPack? {
        guard case .pack(let packID, _) = self else { return nil }
        return PackCatalog.pack(id: packID)
    }

    var packLook: PackLook? {
        guard case .pack(_, let code) = self else { return nil }
        return pack?.looks.first { $0.code == code }
    }

    /// The full name, "KD2 · Morning Gold".
    var name: String {
        switch self {
        case .library(let look): return look.name
        case .pack: return packLook?.name ?? id
        }
    }

    /// Short stock code for rings and tiles: "KD2", "LL1", "AD3".
    var code: String {
        switch self {
        case .pack(_, let code):
            return code
        case .library(let look):
            if let code = LookSignature.code(in: look.name) { return code }
            if let code = Self.signatureCodes[look.name] { return code }
            let letters = look.name.filter { $0.isLetter || $0.isNumber }
            return String(letters.prefix(3)).uppercased()
        }
    }

    /// The name without its code: "Morning Gold".
    var title: String { LookSignature.title(in: name) }

    /// The look's colour for its ring and selection glow.
    var signature: Color {
        switch self {
        case .library(let look): return look.signature
        case .pack: return packLook?.signature ?? LookSignature.neutral
        }
    }

    /// Where it sits in the sheet's filters.
    var family: CameraLookFamily {
        switch self {
        case .library(let look):
            switch look.source {
            case .builtIn(let preset):
                switch preset.category {
                case "Slide": return .slide
                case "B&W":   return .mono
                case "Cine":  return .cine
                case "Original": return .original
                default:      return .negative
                }
            case .saved, .lut:
                return .yours
            }
        case .pack(let packID, let code):
            if packID == "film-stocks-01" { return Self.filmStockFamilies[code] ?? .negative }
            return Self.packFamilies[packID] ?? .negative
        }
    }

    /// Night, neon and flash looks, for the Night filter.
    var isNight: Bool {
        if case .pack(let packID, _) = self, packID == "after-dark" { return true }
        return LibraryLook.isNightName(name)
    }

    /// The film file a measured pack look ships with.
    static func cubeURL(for look: PackLook) -> URL? {
        guard let file = look.cubeFile else { return nil }
        return Bundle.main.url(forResource: (file as NSString).deletingPathExtension,
                               withExtension: "cube")
    }

    /// Signature looks with no stock code take the code their Originals
    /// version sells under.
    private static let signatureCodes = ["Neon Nights": "LL1", "Night Drive": "LL2",
                                         "Afrobeats Glow": "LL3"]
    private static let packFamilies: [String: CameraLookFamily] = [
        "negative-set-01": .negative, "film-neg-archive": .negative,
        "film-slide-archive": .slide, "film-mono-archive": .mono,
        "film-instant-lab": .instant, "film-mirrorless-sims": .negative,
        "cine-print-set-01": .cine, "bw-set-01": .mono,
        "originals-01": .original, "after-dark": .original,
    ]
    private static let filmStockFamilies: [String: CameraLookFamily] = [
        "KC64": .slide, "VV50": .slide, "PR100": .slide, "XP200": .slide,
        "TX400": .mono, "HP400": .mono, "IN669": .instant,
        "CP2383": .cine, "CP3513": .cine,
    ]
}

enum CameraLookFamily {
    case negative, slide, mono, cine, instant, original, yours
}

/// The quick filters along the top of the sheet.
enum CameraLookFilter: String, CaseIterable, Identifiable {
    case all, favourites, free, negative, slide, mono, cine, night, yours
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        return "All"
        case .favourites: return "★ Favourites"
        case .free:       return "Free"
        case .negative:   return "Negative"
        case .slide:      return "Slide"
        case .mono:       return "Mono"
        case .cine:       return "Cine"
        case .night:      return "Night"
        case .yours:      return "Yours"
        }
    }
}

/// One row of the sheet: Signature, a pack, your looks, imports.
struct CameraLookSection: Identifiable {
    enum Tag: Equatable {
        case free, owned, pro, price(String)
    }

    let id: String
    let title: String
    let tag: Tag?
    let looks: [CameraLook]
}

// MARK: - The swipe: favourites

/// The looks the picture swipes through, in the order they were added.
/// Stored as ids; out of the box it is the Signature looks.
enum CameraFavourites {
    static let key = "lumalook.camera.favourites"

    static func decode(_ raw: String) -> [String] {
        raw.split(separator: "|").map(String.init)
    }

    static func encode(_ ids: [String]) -> String {
        ids.joined(separator: "|")
    }
}

// MARK: - Wearing a look

extension AppModel {
    /// Every look the camera can wear, row by row.
    func cameraLookSections(store: StoreService) -> [CameraLookSection] {
        let all = library.all
        var sections: [CameraLookSection] = []

        let signature = all.filter { $0.section == .builtIn }.map(CameraLook.library)
        if !signature.isEmpty {
            sections.append(CameraLookSection(id: "signature", title: "Signature", tag: nil,
                                              looks: signature))
        }
        for pack in PackCatalog.packs {
            let tag: CameraLookSection.Tag
            if pack.isFree {
                tag = .free
            } else if store.ownsPack(pack.id) {
                tag = .owned
            } else if pack.isProIncluded {
                tag = .pro
            } else {
                tag = .price(store.packProducts[pack.id]?.displayPrice ?? pack.price)
            }
            sections.append(CameraLookSection(
                id: pack.id, title: pack.name, tag: tag,
                looks: pack.looks.map { .pack(packID: pack.id, code: $0.code) }))
        }
        let saved = all.filter { $0.section == .saved }.map(CameraLook.library)
        if !saved.isEmpty {
            sections.append(CameraLookSection(id: "saved", title: "Your looks", tag: nil, looks: saved))
        }
        // Imports, the factory Basics and anything from a pack no longer in
        // the catalog. Store packs already have their own rows above.
        let imported = all.filter { look in
            guard case .lut(let file) = look.source else { return false }
            guard let packID = file.packID else { return true }
            return packID == LUTRepository.bundledBasicsPackID || PackCatalog.pack(id: packID) == nil
        }
        sections.append(CameraLookSection(id: "imported", title: "Imported", tag: nil,
                                          looks: imported.map(CameraLook.library)))
        return sections
    }

    /// The installed LUT for a pack look, once its pack is in the library.
    func installedLUT(for look: PackLook, in pack: LookPack) -> LUTFile? {
        let installed = lutRepository.luts.filter { $0.packID == pack.id }
        return installed.first { $0.displayName == look.name }
            ?? installed.first { $0.displayName.hasPrefix(look.code + " ") || $0.displayName == look.code }
    }

    /// True while this look is the one on the picture.
    func isWearing(_ look: CameraLook) -> Bool {
        switch look {
        case .library(let libraryLook):
            return packPreview == nil && isCurrent(libraryLook)
        case .pack(let packID, let code):
            if let preview = packPreview { return preview.packID == packID && preview.code == code }
            guard let lut = selectedLUT, lut.packID == packID,
                  let pack = look.pack, let packLook = look.packLook else { return false }
            return installedLUT(for: packLook, in: pack)?.id == lut.id
        }
    }

    /// Puts a look on the picture. A pack look the user owns installs its
    /// pack first (as the Store's Get does) and is then a real library look;
    /// one they do not own yet is tried on for free. Returns the name of a
    /// pack that was just installed, for a short confirmation.
    @discardableResult
    func wear(_ look: CameraLook, store: StoreService) -> String? {
        switch look {
        case .library(let libraryLook):
            select(look: libraryLook)
            return nil
        case .pack(let packID, let code):
            guard let pack = PackCatalog.pack(id: packID),
                  let packLook = pack.looks.first(where: { $0.code == code }) else { return nil }
            if let lut = installedLUT(for: packLook, in: pack) {
                select(look: LibraryLook(lut: lut, packName: pack.name))
                return nil
            }
            if store.ownsPack(pack.id) {
                let count = PackInstaller.install(pack, into: lutRepository)
                if count > 0 { packStore.markInstalled(pack) }
                if let lut = installedLUT(for: packLook, in: pack) {
                    select(look: LibraryLook(lut: lut, packName: pack.name))
                    return pack.name
                }
            }
            startPackPreview(PackLookPreview(packID: packID, code: code))
            return nil
        }
    }

    /// A try-on whose pack the user now owns (bought from the lock, Pro, a
    /// restore) becomes the real installed look before anything is shot.
    @discardableResult
    func settlePackPreview(_ store: StoreService) -> String? {
        guard let preview = packPreview, store.ownsPack(preview.packID) else { return nil }
        return wear(.pack(packID: preview.packID, code: preview.code), store: store)
    }

    /// The look on the picture, as the camera names it.
    var cameraLookName: String {
        if let preview = packPreview, let look = preview.look { return look.name }
        return selectedLUT?.displayName ?? selectedLook.name
    }

    /// The look on the picture as a camera look, when the catalog has it.
    func wornCameraLook(in looks: [CameraLook]) -> CameraLook? {
        looks.first { isWearing($0) }
    }

    /// Is this look sold rather than free for this user?
    func isLockedForCamera(_ look: CameraLook, store: StoreService) -> Bool {
        switch look {
        case .library(let libraryLook): return store.isLocked(libraryLook)
        case .pack(let packID, _): return !store.ownsPack(packID)
        }
    }

    /// A look by the id the swipe stores. Pack looks resolve whether or not
    /// their pack is installed; library looks only while they exist.
    func cameraLook(id: String) -> CameraLook? {
        if id.hasPrefix("pack:") {
            let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let pack = PackCatalog.pack(id: parts[1]),
                  pack.looks.contains(where: { $0.code == parts[2] }) else { return nil }
            return .pack(packID: parts[1], code: parts[2])
        }
        return library.all.first { $0.id == id }.map(CameraLook.library)
    }

    /// The swipe's ids: what the user starred, or the Signature looks.
    func cameraFavouriteIDs(raw: String) -> [String] {
        let stored = CameraFavourites.decode(raw)
        if !stored.isEmpty { return stored }
        return library.all.filter { $0.section == .builtIn }.map(\.id)
    }

    /// The looks the picture swipes through, resolved against what exists.
    func cameraFavourites(raw: String) -> [CameraLook] {
        let byID = Dictionary(library.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return cameraFavouriteIDs(raw: raw).compactMap { id in
            if id.hasPrefix("pack:") { return cameraLook(id: id) }
            return byID[id].map(CameraLook.library)
        }
    }

    /// The look on the picture right now, as the camera shows it. An
    /// installed pack look keeps its pack identity so the swipe and the
    /// sheet agree on which look is on.
    var cameraWornLook: CameraLook {
        if let preview = packPreview { return .pack(packID: preview.packID, code: preview.code) }
        if let lut = selectedLUT {
            if let packID = lut.packID, let pack = PackCatalog.pack(id: packID),
               let look = pack.looks.first(where: { installedLUT(for: $0, in: pack)?.id == lut.id }) {
                return .pack(packID: packID, code: look.code)
            }
            return .library(LibraryLook(lut: lut))
        }
        return .library(LibraryLook(builtIn: selectedLook))
    }

    /// What a look is graded with for a tile or the swipe's reveal.
    func cameraLookJob(for look: CameraLook, intensity: Double = 100) -> CameraLookThumbs.Job {
        var full = LookSettings()
        full.intensity = intensity
        switch look {
        case .library(let libraryLook):
            switch libraryLook.source {
            case .builtIn(let preset):
                return .init(key: look.id, recipe: preset.recipe, settings: full, lutURL: nil)
            case .lut(let file):
                return .init(key: look.id, recipe: nil, settings: full,
                             lutURL: lutRepository.fileURL(for: file))
            case .saved(let saved):
                let recipe = MockData.looks.first { $0.name == saved.baseLookName }?.recipe
                let lut = saved.lutID.flatMap { id in lutRepository.luts.first { $0.id == id } }
                return .init(key: look.id, recipe: recipe, settings: saved.settings,
                             lutURL: lut.map { lutRepository.fileURL(for: $0) })
            }
        case .pack:
            guard let packLook = look.packLook else {
                return .init(key: look.id, recipe: nil, settings: full, lutURL: nil)
            }
            if let url = CameraLook.cubeURL(for: packLook) {
                return .init(key: look.id, recipe: nil, settings: full, lutURL: url)
            }
            return .init(key: look.id, recipe: PackLookPreview.cubeRecipe(packLook.recipe),
                         settings: full, lutURL: nil)
        }
    }
}

// MARK: - Thumbnails, graded from the live picture

/// Grades a small copy of the camera's own (ungraded) frame through every
/// look, so each tile shows what that look does to the shot in front of you.
@MainActor
final class CameraLookThumbs: ObservableObject {
    struct Job {
        let key: String
        let recipe: LookRecipe?
        let settings: LookSettings
        let lutURL: URL?
    }

    @Published private(set) var images: [String: CGImage] = [:]
    private var task: Task<Void, Never>?
    private var stamp = ""

    /// `frameID` changes when a new frame should regrade every tile.
    func render(frame: CIImage, frameID: Int, looks: [CameraLook], app: AppModel) {
        let jobs = looks.map { app.cameraLookJob(for: $0) }
        let newStamp = "\(frameID)-\(jobs.map(\.key).joined(separator: ","))"
        guard newStamp != stamp else { return }
        let keepOld = stamp.hasPrefix("\(frameID)-")
        stamp = newStamp
        if !keepOld { images = [:] }
        let have = Set(images.keys)
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let pipeline = LookPipeline.shared
            for job in jobs where !have.contains(job.key) {
                if Task.isCancelled { return }
                let state = LookState()
                if let recipe = job.recipe { state.recipe = recipe }
                state.settings = job.settings
                if let url = job.lutURL {
                    guard let parsed = try? pipeline.loadLUT(at: url) else { continue }
                    state.lut = parsed
                }
                guard let cg = pipeline.gradedStill(frame, state: state, maxDimension: 200),
                      !Task.isCancelled else { continue }
                await MainActor.run {
                    guard self?.stamp == newStamp else { return }
                    self?.images[job.key] = cg
                }
            }
        }
    }

    /// One look on one frame, off the main thread: the swipe's reveal.
    nonisolated static func graded(_ frame: CIImage, job: Job, maxDimension: CGFloat) -> CGImage? {
        let pipeline = LookPipeline.shared
        let state = LookState()
        if let recipe = job.recipe { state.recipe = recipe }
        state.settings = job.settings
        if let url = job.lutURL {
            guard let parsed = try? pipeline.loadLUT(at: url) else { return nil }
            state.lut = parsed
        }
        return pipeline.gradedStill(frame, state: state, maxDimension: maxDimension)
    }

    nonisolated static func grade(_ frame: CIImage, job: Job, maxDimension: CGFloat,
                                  completion: @escaping (CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = graded(frame, job: job, maxDimension: maxDimension)
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// The live frame cropped to the tiles' 4:5, around the middle.
    static func tileFrame(from image: CIImage) -> CIImage {
        let full = image.extent
        guard full.width > 1, full.height > 1 else { return image }
        var width = full.width
        var height = width * 1.25
        if height > full.height {
            height = full.height
            width = height * 0.8
        }
        let rect = CGRect(x: full.midX - width / 2, y: full.midY - height / 2,
                          width: width, height: height)
        let cropped = image.cropped(to: rect)
        return cropped.transformed(by: CGAffineTransform(
            translationX: -cropped.extent.minX, y: -cropped.extent.minY))
    }
}

// MARK: - The sheet

struct CameraLooksSheet: View {
    /// The camera's own frame, before any look, for the tiles.
    let frame: CIImage?
    /// Bumped by the camera when a fresh frame is worth regrading.
    var frameID: Int = 0
    /// Recording or taking a still does not happen from here; this closes it.
    let onClose: () -> Void
    /// A pack installed on first use, so the camera can say so.
    var onInstalled: ((String) -> Void)? = nil

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @AppStorage(CameraFavourites.key) private var favouritesRaw = ""
    @StateObject private var thumbs = CameraLookThumbs()
    @State private var filter: CameraLookFilter = .all
    @State private var search = ""
    @State private var note: String?
    @FocusState private var searchFocused: Bool

    private var sections: [CameraLookSection] { app.cameraLookSections(store: storeService) }

    private var allLooks: [CameraLook] {
        var seen = Set<String>()
        return sections.flatMap(\.looks).filter { seen.insert($0.id).inserted }
    }

    /// The swipe, resolved against what exists now.
    private var favourites: [CameraLook] {
        let byID = Dictionary(allLooks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = favouriteIDs
        return ids.compactMap { byID[$0] }
    }

    private var favouriteIDs: [String] { app.cameraFavouriteIDs(raw: favouritesRaw) }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 16)
                .padding(.bottom, 10)
            filterChips
                .padding(.bottom, 4)
            ScrollView(showsIndicators: false) {
                content
                    .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            footer
        }
        .overlay(alignment: .top) {
            if let note {
                Text(note)
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(LumaTheme.onSignal)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(LumaTheme.signal, in: Capsule())
                    .padding(.top, 96)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: note)
        .preferredColorScheme(.dark)
        .onAppear { renderThumbs() }
        .onChange(of: frameID) { _, _ in renderThumbs() }
        .onChange(of: allLooks.count) { _, _ in renderThumbs() }
    }

    private func renderThumbs() {
        let source = frame ?? LookThumbs.portraitFrame
        thumbs.render(frame: CameraLookThumbs.tileFrame(from: source),
                      frameID: frame == nil ? -1 : frameID,
                      looks: allLooks, app: app)
    }

    // MARK: Header: search and close

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
                TextField("Search \(allLooks.count) looks", text: $search)
                    .font(.luma(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                LumaHaptics.shared.tap()
                onClose()
            } label: {
                Text("Done")
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
        .padding(.horizontal, 16)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CameraLookFilter.allCases) { item in
                    let on = item == filter && trimmedSearch.isEmpty
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            filter = item
                            search = ""
                        }
                        LumaHaptics.shared.tap()
                    } label: {
                        Text(item.title)
                            .font(.luma(size: 13, weight: .semibold))
                            .foregroundStyle(on ? LumaTheme.onSignal : Color.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(on ? LumaTheme.signal : Color.white.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.lumaPress)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !trimmedSearch.isEmpty || filter != .all {
            filteredGrid
        } else {
            VStack(alignment: .leading, spacing: 0) {
                favouritesSection
                ForEach(sections) { section in
                    if section.id != "imported" || !section.looks.isEmpty {
                        sectionRow(section)
                    } else {
                        importRow
                    }
                }
                Button {
                    openStore()
                } label: {
                    Text("Get more looks in the Store")
                        .font(.luma(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }
        }
    }

    private var favouritesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("★ Favourites", tag: nil, count: favourites.count)
            Text("Swipe the picture to step through these. Long-press any look to add or remove it.")
                .font(.luma(size: 12))
                .foregroundStyle(LumaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, -4)
            lookRow(favourites)
        }
        .padding(.top, 12)
    }

    private func sectionRow(_ section: CameraLookSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(section.title, tag: section.tag, count: section.looks.count)
            lookRow(section.looks, trailingImport: section.id == "imported")
        }
        .padding(.top, 16)
    }

    private var importRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Imported", tag: nil, count: 0)
            lookRow([], trailingImport: true)
        }
        .padding(.top, 16)
    }

    private func sectionHeader(_ title: String, tag: CameraLookSection.Tag?, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.luma(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let tag { tagPill(tag) }
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.luma(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LumaTheme.textMuted)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func tagPill(_ tag: CameraLookSection.Tag) -> some View {
        let (text, fg, bg): (String, Color, Color) = {
            switch tag {
            case .free:  return ("Free", Color(hex: 0x6EE7A8), Color(hex: 0x3DDC84).opacity(0.15))
            case .owned: return ("Yours", .white, Color.white.opacity(0.12))
            case .pro:   return ("With Pro", LumaTheme.signal, LumaTheme.signal.opacity(0.16))
            case .price(let price): return (price, Color.white.opacity(0.85), Color.white.opacity(0.09))
            }
        }()
        Text(text)
            .font(.luma(size: 11, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func lookRow(_ looks: [CameraLook], trailingImport: Bool = false) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(looks) { look in
                    card(look)
                }
                if trailingImport {
                    importCard
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var filteredGrid: some View {
        let query = trimmedSearch.lowercased()
        let favouriteSet = Set(favouriteIDs)
        let matches: [CameraLook] = {
            let base: [CameraLook]
            switch filter {
            case .all:        base = allLooks
            case .favourites: base = favourites
            case .free:       base = allLooks.filter { !app.isLockedForCamera($0, store: storeService) }
            case .negative:   base = allLooks.filter { $0.family == .negative }
            case .slide:      base = allLooks.filter { $0.family == .slide }
            case .mono:       base = allLooks.filter { $0.family == .mono }
            case .cine:       base = allLooks.filter { $0.family == .cine }
            case .night:      base = allLooks.filter(\.isNight)
            case .yours:      base = allLooks.filter { $0.family == .yours }
            }
            guard !query.isEmpty else { return base }
            return base.filter { look in
                let haystack = [look.name, look.code, look.pack?.name ?? "",
                                look.packLook?.character ?? ""].joined(separator: " ").lowercased()
                return haystack.contains(query) || (query == "favourite" && favouriteSet.contains(look.id))
            }
        }()
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(query.isEmpty ? filter.title : "Results", tag: nil, count: matches.count)
                .padding(.top, 12)
            if matches.isEmpty {
                Text(query.isEmpty ? "No looks here yet." : "No looks match “\(trimmedSearch)”.")
                    .font(.luma(size: 13))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    ForEach(matches) { look in
                        card(look)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Cards

    private func card(_ look: CameraLook) -> some View {
        let wearing = app.isWearing(look)
        let favourite = favouriteIDs.contains(look.id)
        let locked = app.isLockedForCamera(look, store: storeService)
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image = thumbs.images[look.id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [look.signature.opacity(0.55), Color(white: 0.1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: 76, height: 95)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if wearing {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(look.signature, lineWidth: 2.5)
                        .shadow(color: look.signature.opacity(0.8), radius: 6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if favourite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LumaTheme.signal)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(6)
                }
            }
            Text(look.code)
                .font(.luma(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 6)
            Text(look.title)
                .font(.luma(size: 10.5, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 76, alignment: .leading)
        .contentShape(Rectangle())
        // Tap before long-press, so the long-press never blocks scrolling.
        .onTapGesture { pick(look) }
        .onLongPressGesture(minimumDuration: 0.45) { toggleFavourite(look) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(look.name)\(locked ? ", free to try, unlock to shoot" : "")\(favourite ? ", in your swipe" : "")")
        .accessibilityAddTraits(wearing ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: favourite ? "Remove from swipe" : "Add to swipe") { toggleFavourite(look) }
    }

    private var importCard: some View {
        LUTImportButton(onImported: { imported in
            pick(.library(LibraryLook(lut: imported)))
        }) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(width: 76, height: 95)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(LumaTheme.textSecondary)
                    }
                Text("Import")
                    .font(.luma(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 6)
                Text(".cube or .zip")
                    .font(.luma(size: 10.5, weight: .medium))
                    .foregroundStyle(LumaTheme.textSecondary)
            }
            .frame(width: 76, alignment: .leading)
        }
        .accessibilityLabel("Import a LUT")
    }

    // MARK: Footer: what is on, and how strong

    private var footer: some View {
        let strength = Int(app.settings.intensity.rounded())
        return VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 10) {
                Text(app.cameraLookName)
                    .font(.luma(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Strength")
                    .font(.luma(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(strength == 0 ? "Off" : "\(strength)%")
                    .font(.luma(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            LumaStrengthRuler(value: $app.settings.intensity,
                              needle: currentSignature)
                .padding(.bottom, 6)
        }
        .background(LumaTheme.bar)
    }

    private var currentSignature: Color {
        if let worn = app.wornCameraLook(in: allLooks) { return worn.signature }
        return LookSignature.colour(name: app.cameraLookName)
    }

    // MARK: Actions

    private func pick(_ look: CameraLook) {
        searchFocused = false
        if let installed = app.wear(look, store: storeService) {
            onInstalled?(installed)
            show("\(installed) is in your library now")
        }
        LumaHaptics.shared.tap()
    }

    private func toggleFavourite(_ look: CameraLook) {
        var ids = favouriteIDs
        if let at = ids.firstIndex(of: look.id) {
            guard ids.count > 1 else {
                show("Keep at least one look in your swipe")
                return
            }
            ids.remove(at: at)
            show("\(look.code) is out of your swipe")
        } else {
            ids.append(look.id)
            show("\(look.code) is in your swipe")
        }
        favouritesRaw = CameraFavourites.encode(ids)
        LumaHaptics.shared.tap()
    }

    private func show(_ text: String) {
        note = text
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if note == text { note = nil }
        }
    }

    private func openStore() {
        LumaHaptics.shared.tap()
        onClose()
        // The push waits for the sheet to go, or the Store lands behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            app.path.append(.filterStore)
        }
    }
}

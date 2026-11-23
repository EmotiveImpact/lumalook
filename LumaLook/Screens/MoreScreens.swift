import SwiftUI
import AVFoundation
import CoreImage
import StoreKit
import UIKit

// MARK: - Store rendering support

/// Renders one representative graded frame per pack — the pack's first look
/// pushed through the real pipeline, on the user's own frame when there is
/// one. A store tile and a library tile of the same look therefore show the
/// same pixels; no stock art anywhere in the store.
@MainActor
final class PackThumbs: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var task: Task<Void, Never>?
    private var stamp = ""

    func render(packs: [LookPack], source: CIImage?, maxDimension: CGFloat = 240) {
        let key = "\(source?.extent.debugDescription ?? "pack-own-frames")-\(packs.map(\.id).joined())-\(Int(maxDimension))"
        guard key != stamp else { return }
        stamp = key

        // With real user media every tile shares one frame, so the grades are
        // directly comparable. Without it each pack previews on a frame chosen
        // by `previewPhoto` — the catalog hand-assigns the same hero to several
        // packs, which made adjacent rows render the identical sunset and read
        // as one stock photo repeated.
        // New packs lead every rail and grid, so they render first; with
        // eleven covers at 720 px the last one can take a few seconds.
        let ordered = packs.filter(\.isNew) + packs.filter { !$0.isNew }
        let jobs: [(String, PackLook, CIImage)] = ordered.compactMap { pack in
            guard let look = pack.looks.first else { return nil }
            let frame = source ?? PackThumbs.previewPhoto(for: pack).ciImage
                ?? LookThumbs.fallbackFrame
            return (pack.id, look, frame)
        }
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            for (packID, look, frame) in jobs {
                if Task.isCancelled { return }
                // Each grade runs off the shared task pool (`GradeQueue`).
                guard let cg = await GradeQueue.packs.run({
                    PackThumbs.grade(look, on: frame, maxDimension: maxDimension)
                }) else { continue }
                await MainActor.run { self?.images[packID] = cg }
            }
        }
    }

    /// Every bundled photo, in rotation order (kept for callers that walk a
    /// rotation). The pack-detail cover, the store rows and the Looks tab
    /// covers all read `previewPhoto(for:)`, so a tile and its pack page
    /// always show the same people.
    static let previewPhotos: [HeroPhoto] = [.golden, .neon, .drive, .rain, .party, .skate, .gig, .campaign, .bridge]

    static func previewPhoto(for pack: LookPack) -> HeroPhoto {
        // Night Lab: each pack has a hand-picked cover with people that suit
        // it, and catalog neighbours never share one (`LookPack.coverPhoto`).
        pack.coverPhoto
    }

    /// The single grade entry point for every store surface (tiles, detail
    /// hero, try-on panel) so all three agree. Measured stocks preview
    /// through their bundled cube; recipe looks through the baked recipe —
    /// exactly what `PackInstaller` will put in the library.
    nonisolated static func grade(_ look: PackLook, on source: CIImage,
                                  maxDimension: CGFloat) -> CGImage? {
        let state = LookState()
        if let cubeFile = look.cubeFile,
           let url = Bundle.main.url(forResource: (cubeFile as NSString).deletingPathExtension,
                                     withExtension: "cube") {
            state.lut = try? LookPipeline.shared.loadLUT(at: url)
        } else {
            state.recipe = look.recipe
        }
        var settings = LookSettings()
        settings.intensity = 100
        state.settings = settings
        return LookPipeline.shared.gradedStill(source, state: state, maxDimension: maxDimension)
    }
}

/// Store filter chips derived from metadata the catalog already carries
/// (`eraTag` + pricing) rather than an invented taxonomy — every case
/// matches a phrase that exists in `PackCatalog` today.
enum StoreCategory: String, CaseIterable, Identifiable {
    case all, film, cinema, mono, instant, camera, originals, free
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:       return "All"
        case .film:      return "Film"
        case .cinema:    return "Cinema"
        case .mono:      return "Mono"
        case .instant:   return "Instant"
        case .camera:    return "Camera"
        case .originals: return "Originals"
        case .free:      return "Free"
        }
    }

    func contains(_ pack: LookPack) -> Bool {
        let tag = pack.eraTag.lowercased()
        switch self {
        case .all:       return true
        case .film:      return tag.contains("negative") || tag.contains("slide")
                             || tag.contains("film data")
        case .cinema:    return tag.contains("release print") || tag.contains("cinema")
        case .mono:      return tag.contains("monochrome") || tag.contains("panchromatic")
        case .instant:   return tag.contains("instant")
        case .camera:    return tag.contains("mirrorless") || tag.contains("profile")
        case .originals: return tag.contains("original")
        case .free:      return pack.isFree
        }
    }
}

// MARK: - The two type voices

/// A number, in the instrument voice. Prices, counts, sizes — data only.
private func numText(_ text: String, _ size: CGFloat, _ opacity: Double) -> Text {
    Text(text)
        .font(.luma(size: size, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(opacity))
}

/// Language, in the reading voice: system face, sentence case, no tracking.
private func wordText(_ text: String, _ size: CGFloat, _ opacity: Double,
              weight: Font.Weight = .medium) -> Text {
    Text(text)
        .font(.luma(size: size, weight: weight))
        .foregroundStyle(.white.opacity(opacity))
}

/// "12 looks · Measured slide films" — the count is data and keeps the mono
/// voice; the words around it are plain type at a contrast you can actually
/// read. The era tag is left exactly as the catalog wrote it: it is a phrase,
/// not a code, and shouting it in tracked caps was the mistake.
private func packMetaLine(_ pack: LookPack) -> Text {
    numText("\(pack.looks.count)", 13, 0.72)
        + wordText(" looks · \(pack.eraTag)", 12, 0.58)
}

/// The one place the store says "owned" — and it says it WITHOUT hue, on a
/// screen whose whole job is to show colour. Four states, none of them a
/// tint: a filled white check disc plus a full-white label for owned, and
/// readouts of decreasing weight for everything you could still get. Only the
/// price is a number, so only the price stays mono.
///
/// (The teal "In Library" pill this replaces was the only colour on the store,
/// and it died in greyscale. Value, weight and a mark survive it.)
struct PackStatePill: View {
    let pack: LookPack
    let installed: Bool
    /// The formatted StoreKit price. Only rendered in the `.buy` state.
    let price: String

    var body: some View {
        if installed {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 18, height: 18)
                    .background(.white, in: Circle())
                Text("In library")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        } else if pack.isFree {
            Text("Free")
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color(white: 0.18), in: Capsule())
        } else if pack.isProIncluded {
            HStack(spacing: 5) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Pro")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color(white: 0.18), in: Capsule())
        } else {
            // A price is a number, and it is one of the two things on this
            // screen that must read instantly from across the room.
            Text(price)
                .font(.luma(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.13), in: Capsule())
        }
    }
}

// MARK: - 09 Filter Store

/// The Look Store in the shipping design language: the pack's own art on top,
/// uncovered, every control in the drawer under it, and nothing on the screen
/// tinted — ownership is said with a surface value step, a white check and a
/// full-white label instead of a teal pill.
struct FilterStoreView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = PackThumbs()
    var isRoot: Bool = false

    @State private var category: StoreCategory = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["LUMA_SEED_STORECAT"],
           let seeded = StoreCategory(rawValue: raw) { return seeded }
        #endif
        return .all
    }()

    @State private var searching = false
    @State private var query = ""
    @State private var restoring = false
    @FocusState private var searchFocused: Bool

    private var needle: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var isSearchActive: Bool { searching && !needle.isEmpty }

    /// The flagship recipe pack — looked up by id so catalog growth can't
    /// silently re-point the hero at a different pack.
    private var featured: LookPack {
        PackCatalog.pack(id: "cine-print-set-01") ?? PackCatalog.packs[0]
    }

    /// The pack the hero is currently showing: the featured pack while
    /// browsing, the first result while filtering or searching — so the image
    /// on top always belongs to what is under it.
    private var heroPack: LookPack {
        if isSearchActive || category != .all {
            return visiblePacks.first ?? featured
        }
        return featured
    }

    /// Category first, then the free-text query across everything the user
    /// could plausibly remember: the pack, its era tag, and the name or code
    /// of any look inside it — 118 looks are not findable by scrolling.
    private var visiblePacks: [LookPack] {
        let byCategory = PackCatalog.packs.filter { category.contains($0) }
        guard !needle.isEmpty else { return byCategory }
        return byCategory.filter { pack in
            pack.name.lowercased().contains(needle)
                || pack.eraTag.lowercased().contains(needle)
                || pack.looks.contains {
                    $0.name.lowercased().contains(needle)
                        || $0.code.lowercased().contains(needle)
                }
        }
    }

    /// Categories only appear when the catalog actually has something in them.
    private var activeCategories: [StoreCategory] {
        StoreCategory.allCases.filter { cat in
            cat == .all || PackCatalog.packs.contains(where: cat.contains)
        }
    }

    private var categoryIndex: Int { activeCategories.firstIndex(of: category) ?? 0 }

    private var ownedLookCount: Int {
        PackCatalog.packs.reduce(0) { $0 + (app.packStore.isInstalled($1) ? $1.looks.count : 0) }
    }

    private var ownedPackCount: Int {
        PackCatalog.packs.filter { app.packStore.isInstalled($0) }.count
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if isRoot {
                    // Opened as a tab, it wears every tab's one row.
                    LumaTopBar(title: LumaTab.store.title)
                        .padding(.top, LumaTabMetrics.top)
                        .padding(.bottom, 4)
                }
                hero
                    .frame(height: 214)
                drawer
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")") {
            thumbs.render(packs: PackCatalog.packs, source: app.previewFrame)
        }
        .onAppear {
            // A seeded category the catalog cannot fill has no place on the
            // bar, and the bar would then name a different category than the
            // list is filtered by.
            if !activeCategories.contains(category) { category = .all }
        }
    }

    // MARK: Hero — pack art, uncovered

    private var hero: some View {
        let pack = heroPack
        return Button {
            StoreNav.open(pack, installed: app.packStore.isInstalled(pack), app: app)
        } label: {
            GeometryReader { geo in
                Group {
                    if let cg = thumbs.images[pack.id] {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        HeroImage(photo: PackThumbs.previewPhoto(for: pack), radius: 0)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                // The fill overflows its frame; its invisible remainder would
                // otherwise cover the drawer below and eat those taps.
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .buttonStyle(.lumaPress)
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: Drawer

    private var drawer: some View {
        VStack(spacing: 0) {
            heroCaption
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)
            categoryBar
                .padding(.bottom, 12)
            if searching {
                searchField
                    .padding(.bottom, 12)
            }
            list
            instructionBar
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searching)
    }

    /// The hero's name lives here, under the picture, never over it.
    private var heroCaption: some View {
        let pack = heroPack
        let installed = app.packStore.isInstalled(pack)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isSearchActive || category != .all ? "First result" : "Featured pack")
                    .font(.luma(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(pack.name)
                    .font(.luma(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                packMetaLine(pack)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PackStatePill(pack: pack, installed: installed,
                          price: StoreNav.price(pack, storeService))
        }
    }

    /// Two-axis browsing: the current category centred, neighbours faded either
    /// side, swipeable. Replaces the accent chip rail wholesale. Counts stay in
    /// mono, because a count is a number.
    private var categoryBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                neighbour(at: categoryIndex - 1, alignment: .leading)
                Text(activeCategories[categoryIndex].title)
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 10)
                neighbour(at: categoryIndex + 1, alignment: .trailing)
            }
            // The collection the user grows: owned looks of the catalog total,
            // owned packs of the catalog total. Numbers in the instrument
            // voice, the words around them in plain type.
            (numText("\(ownedLookCount)", 13, 0.8)
             + wordText(" of ", 12, 0.5)
             + numText("\(PackCatalog.totalLookCount)", 13, 0.8)
             + wordText(" looks · ", 12, 0.5)
             + numText("\(ownedPackCount)/\(PackCatalog.packs.count)", 13, 0.8)
             + wordText(" packs", 12, 0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    step(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    @ViewBuilder
    private func neighbour(at index: Int, alignment: Alignment) -> some View {
        if activeCategories.indices.contains(index) {
            Button {
                step(index - categoryIndex)
            } label: {
                VStack(spacing: 1) {
                    Text(activeCategories[index].title)
                        .font(.luma(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                    // A count IS a number: it keeps the mono voice.
                    Text("\(PackCatalog.packs.filter(activeCategories[index].contains).count)")
                        .font(.luma(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: alignment)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(height: 1).frame(maxWidth: .infinity)
        }
    }

    private func step(_ delta: Int) {
        let next = categoryIndex + delta
        guard activeCategories.indices.contains(next) else { return }
        withAnimation(.snappy(duration: 0.22)) { category = activeCategories[next] }
        LumaHaptics.shared.tap()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
            TextField("Search packs and looks", text: $query)
                .font(.luma(size: 15))
                .foregroundStyle(.white)
                .tint(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: The catalog

    private var list: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(visiblePacks) { pack in
                    row(pack)
                }
                if visiblePacks.isEmpty {
                    Text(needle.isEmpty
                         ? "No packs in this category yet."
                         : "No packs or looks match “\(query)”.")
                        .font(.luma(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                }
                Text(MockData.namingDisclaimer)
                    .font(.luma(size: 11.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineSpacing(2)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
        .mask {
            VStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
            }
        }
    }

    /// The pack tile IS its own art — each pack on its OWN hero photo, never
    /// one shared sunset. Ownership separates by surface value, not by hue: an
    /// owned pack sits on a lighter plate than one you could still buy.
    private func row(_ pack: LookPack) -> some View {
        let installed = app.packStore.isInstalled(pack)
        return Button {
            StoreNav.open(pack, installed: installed, app: app)
        } label: {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: 60, height: 60)
                    .overlay {
                        if let cg = thumbs.images[pack.id] {
                            Image(decorative: cg, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            HeroImage(photo: PackThumbs.previewPhoto(for: pack), radius: 0)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    // Art overflows the 60pt frame — keep its touches inside it
                    // so it cannot swallow the state control to its right.
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(pack.name)
                        .font(.luma(size: 16, weight: .semibold))
                        .foregroundStyle(installed ? .white : .white.opacity(0.92))
                        .lineLimit(1)
                    packMetaLine(pack)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                PackStatePill(pack: pack, installed: installed,
                              price: StoreNav.price(pack, storeService))
            }
            .padding(10)
            .background(Color(white: installed ? 0.13 : 0.075),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: Instruction bar — the way back, the search, and restore

    private var instructionBar: some View {
        HStack(spacing: 8) {
            if !isRoot {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    searching.toggle()
                    if !searching { query = "" }
                }
                searchFocused = searching
                LumaHaptics.shared.tap()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                    // A live value beats a slogan. The moment the catalog is
                    // narrowed — by a query OR by the category bar — this bar
                    // counts what is actually under it, which is where the
                    // selected category's own count now lives.
                    if searching || category != .all {
                        (numText("\(visiblePacks.count)", 15, 0.8)
                         + wordText(" of ", 15, 0.7)
                         + numText("\(PackCatalog.packs.count)", 15, 0.8)
                         + wordText(" packs", 15, 0.7))
                    } else {
                        Text("Tap a pack to preview it")
                            .font(.luma(size: 15))
                    }
                }
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searching ? "Close search" : "Search the store")
            Spacer(minLength: 0)
            Button {
                guard !restoring else { return }
                restoring = true
                Task {
                    await storeService.restorePurchases()
                    restoring = false
                }
                LumaHaptics.shared.tap()
            } label: {
                Group {
                    if restoring {
                        ProgressView().tint(.white).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore purchases")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// Store → rest-of-app navigation, shared by the list, the banner and the
/// detail screen so "owned" behaves identically wherever it is tapped.
@MainActor
enum StoreNav {
    static func price(_ pack: LookPack, _ storeService: StoreService) -> String {
        if pack.isFree { return "Free" }
        if pack.isProIncluded { return "Pro" }
        return storeService.packProducts[pack.id]?.displayPrice ?? pack.price
    }

    /// Owned packs are a door into the library, not a purchase screen: land
    /// on the Looks tab pre-filtered to the pack the user just tapped.
    static func openInLibrary(_ pack: LookPack, app: AppModel) {
        app.libraryPackFilter = pack.name
        app.path = []
        app.tab = .looks
        LumaHaptics.shared.tap()
    }

    static func open(_ pack: LookPack, installed: Bool, app: AppModel) {
        if installed {
            openInLibrary(pack, app: app)
        } else {
            app.selectedPackID = pack.id
            app.path.append(.filterPack)
        }
    }
}


struct BackArrow: View {
    @Environment(\.dismiss) private var dismiss
    /// Over photography the bare glyph can land on near-white sky, so the
    /// media placements get the mockup's circular chip behind it. Chrome
    /// placements keep the naked glyph.
    var onMedia: Bool = false

    var body: some View {
        Button { dismiss() } label: {
            if onMedia {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: 1))
                    .frame(width: 40, height: 40, alignment: .leading)
            } else {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The app's legal destinations, in one place so the paywall footer and the
/// Settings ABOUT rows can never drift apart. Both point at the documents
/// hosted on lumalook.app (the `website/` folder) and stay overridable from
/// Info.plist (`LLPrivacyPolicyURL` / `LLTermsOfUseURL`).
enum LumaLegal {
    static let privacy = url(forInfoKey: "LLPrivacyPolicyURL",
                             fallback: "https://lumalook.app/privacy")
    static let terms = url(forInfoKey: "LLTermsOfUseURL",
                           fallback: "https://lumalook.app/terms")

    private static func url(forInfoKey key: String, fallback: String) -> URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let url = URL(string: configured) { return url }
        return URL(string: fallback)!
    }

    static func open(_ url: URL) { UIApplication.shared.open(url) }
}

// MARK: - 10 Filter Pack Detail

/// The pack page (Night Lab, "After Dark"): a full-bleed cover with people on
/// it, graded in the look you are previewing; the name as a light word and a
/// heavy word; then the pack's looks as a cast list, each one a face graded
/// in that look with its colour dot, code and one line. One signal-yellow
/// button at the bottom does the buying, unlocking or installing.
struct FilterPackDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    /// Row faces, keyed by look code.
    @State private var previews: [String: CGImage] = [:]
    @State private var hero: CGImage?
    @State private var installing = false
    @State private var installedFlash = 0
    @State private var showPaywall = false
    /// The look the cover and the try-on panel are currently showing.
    @State private var selectedCode: String?
    /// The user's own most recent frame, when they have one.
    @State private var tryOnSource: CIImage?
    @State private var tryOnIsUserMedia = false
    @State private var tryOnImage: CGImage?

    /// Free, individually bought, or unlocked by Pro.
    private var unlocked: Bool { storeService.ownsPack(pack.id) }

    private var pack: LookPack {
        app.selectedPackID.flatMap(PackCatalog.pack(id:)) ?? PackCatalog.packs[0]
    }

    private var installed: Bool { app.packStore.isInstalled(pack) }

    private var activeLook: PackLook {
        pack.looks.first { $0.code == selectedCode } ?? pack.looks[0]
    }

    /// The cover photo: the same one the pack's store row and Looks tab cover
    /// use, so tapping a cover never swaps the people out from under you.
    private var heroPhoto: HeroPhoto { PackThumbs.previewPhoto(for: pack) }

    private var heroSource: CIImage {
        heroPhoto.ciImage ?? LookThumbs.fallbackFrame
    }

    /// One face per row, each look on the photo that suits it, spread so
    /// neighbouring rows never show the same person.
    private func rowPhoto(for look: PackLook) -> HeroPhoto {
        let photos = rowPhotos
        guard let index = pack.looks.firstIndex(where: { $0.code == look.code }),
              index < photos.count else { return heroPhoto }
        return photos[index]
    }

    private var rowPhotos: [HeroPhoto] {
        LookPhotos.spread(names: pack.looks.map(\.name), keys: pack.looks.map(\.code))
    }

    /// The pack's family, for the glass pill on the cover.
    private var familyTitle: String {
        StoreCategory.allCases.first { $0 != .all && $0 != .free && $0.contains(pack) }?.title ?? "Pack"
    }

    /// What the pack technically is. A claim is a sentence, not a readout.
    private var techClaim: String {
        pack.looks.contains { $0.cubeFile != nil } ? "Measured film data"
                                                   : "Baked 33-point cubes"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                cover
                looksList
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                detailsBlock
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 16)
            }
        }
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .overlay(alignment: .top) { topBar }
        .background(LumaTheme.ink.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.success, trigger: installedFlash)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task(id: pack.id) {
            #if DEBUG
            // LUMA_SEED_PACKLOOK=<code> selects a look without a tap, so the
            // render path can be verified independently of hit testing.
            let seeded = ProcessInfo.processInfo.environment["LUMA_SEED_PACKLOOK"]
            selectedCode = seeded.flatMap { code in
                pack.looks.first { $0.code == code }?.code
            } ?? pack.looks.first?.code
            #else
            selectedCode = pack.looks.first?.code
            #endif
            renderPreviews()
            await loadTryOnSource()
        }
        .task(id: "\(pack.id)-\(selectedCode ?? "")") {
            renderHero()
            renderTryOn()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUMA_AUTO_INSTALL"] == "1" {
                performInstall()
            }
            #endif
        }
    }

    // MARK: Cover — people, graded in the look you are previewing

    private var cover: some View {
        Color.clear
            .frame(height: 430)
            .frame(maxWidth: .infinity)
            .overlay { coverArt }
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.4), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: LumaTheme.ink.opacity(0.45), location: 0.62),
                    .init(color: LumaTheme.ink, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                titleBlock
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
            .clipped()
            // The fill overflows its frame; keep its touches inside it.
            .contentShape(Rectangle())
    }

    private var coverArt: some View {
        GeometryReader { geo in
            Group {
                if let hero {
                    Image(decorative: hero, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    HeroImage(photo: heroPhoto, radius: 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height,
                   alignment: heroPhoto.cropAlignment)
            .clipped()
        }
        .animation(.easeOut(duration: 0.35), value: selectedCode)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(pack.packLine)
                .font(.luma(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(LumaTheme.signal)
                .lineLimit(1)
            LumaHeadline(light: pack.titleParts.light, heavy: pack.titleParts.heavy, size: 40)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(pack.familyLine)
                .font(.luma(size: 14))
                .foregroundStyle(LumaTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Back on the left, the pack's family on the right, both in glass so
    /// they hold up over any cover.
    private var topBar: some View {
        HStack {
            BackArrow(onMedia: true)
                .accessibilityLabel("Back")
            Spacer()
            Text(familyTitle)
                .font(.luma(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lumaGlassPill()
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    // MARK: Looks — the cast list

    private var looksList: some View {
        VStack(spacing: 0) {
            ForEach(pack.looks.indices, id: \.self) { index in
                lookRow(pack.looks[index],
                        isLast: index == pack.looks.count - 1)
            }
        }
    }

    private func lookRow(_ look: PackLook, isLast: Bool) -> some View {
        let active = look.code == activeLook.code
        return Button {
            selectedCode = look.code
            LumaHaptics.shared.tap()
        } label: {
            HStack(spacing: 12) {
                rowFace(look, active: active)
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.title)
                        .font(.luma(size: 15, weight: .semibold))
                        .kerning(-0.2)
                        .foregroundStyle(LumaTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(look.code) · \(look.character)")
                        .font(.luma(size: 12))
                        .foregroundStyle(LumaTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(look.signature)
                    .frame(width: 8, height: 8)
                    .shadow(color: look.signature, radius: 4)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(LumaTheme.hairline)
                        .frame(height: 1)
                }
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(look.title), \(look.code)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func rowFace(_ look: PackLook, active: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Color.clear
            .frame(width: 46, height: 46)
            .overlay {
                if let cg = previews[look.code] {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    // The person shows straight away; the grade fades in
                    // over them once it is ready (a slow phone can take a
                    // moment for five looks), so a row is never an empty box.
                    HeroImage(photo: rowPhoto(for: look), radius: 0)
                        .opacity(0.7)
                }
            }
            .animation(.easeOut(duration: 0.2), value: previews[look.code] != nil)
            .clipShape(shape)
            // clipShape clips pixels, not touches: confine the face.
            .contentShape(shape)
            .pickedRing(active, cornerRadius: 10)
    }

    // MARK: Details — your own footage, the claim, the small print

    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tryOnIsUserMedia {
                tryOnPanel
            }
            (numText("\(pack.looks.count)", 13, 0.72)
             + wordText(" looks · \(techClaim)", 12, 0.55))
                .lineLimit(1)
            Text(MockData.namingDisclaimer)
                .font(.luma(size: 11.5))
                .foregroundStyle(.white.opacity(0.42))
                .lineSpacing(2)
        }
    }

    /// Only when there is footage of the user's own: the rows already show
    /// every look on a face.
    private var tryOnPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let tryOnImage {
                        Image(decorative: tryOnImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LumaTheme.raised
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            (wordText("Your last clip · ", 13, 0.7, weight: .semibold)
             + numText(activeLook.code, 12, 0.5))
                .lineLimit(1)
        }
    }

    // MARK: Action bar — one signal button, and what it means

    private var actionBar: some View {
        VStack(spacing: 8) {
            mainButton
            Text(footnote)
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
                .lineLimit(1)
            secondaryDoor
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [
                .init(color: LumaTheme.ink.opacity(0), location: 0),
                .init(color: LumaTheme.ink.opacity(0.94), location: 0.38),
                .init(color: LumaTheme.ink, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    private var mainButton: some View {
        Button {
            if installed {
                StoreNav.openInLibrary(pack, app: app)
            } else {
                buyOrInstall()
            }
        } label: {
            HStack(spacing: 8) {
                if installing || storeService.purchaseInFlight {
                    ProgressView().tint(LumaTheme.onSignal)
                } else if installed {
                    Text("In library · Open")
                    Image(systemName: "arrow.right")
                } else if unlocked {
                    Text(pack.isFree ? "Install free" : "Install")
                } else if pack.isProIncluded {
                    Text("Unlock with Pro")
                } else {
                    Text("Buy pack · \(StoreNav.price(pack, storeService))")
                }
            }
            .font(.luma(size: 16, weight: .semibold))
            // Buying, unlocking and installing are the page's one main
            // action, so they speak signal; once installed it is a plain door.
            .foregroundStyle(installed ? LumaTheme.onLight : LumaTheme.onSignal)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(installed ? LumaTheme.textPrimary : LumaTheme.signal,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(storeService.purchaseInFlight)
    }

    /// The store logic in one line: looks always preview for free here; a
    /// pack you have not unlocked cannot be installed or exported.
    private var footnote: String {
        if installed { return "\(pack.looks.count) looks in your library" }
        if unlocked {
            return pack.isFree ? "Free · adds \(pack.looks.count) looks to your library"
                               : "Unlocked · adds \(pack.looks.count) looks to your library"
        }
        return "Preview free · unlock to export"
    }

    @ViewBuilder
    private var secondaryDoor: some View {
        if installed, !app.editor.clips.isEmpty || app.selectedVideoURL != nil || app.selectedImage != nil {
            Button {
                if !app.editor.clips.isEmpty {
                    app.path = [.editor]
                } else {
                    app.path.append(.applyLook)
                }
                LumaHaptics.shared.tap()
            } label: {
                Text("Or grade your current media now")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
        } else if !unlocked && !pack.isProIncluded {
            Button { showPaywall = true } label: {
                Text("Or get every pack with Pro")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Actions

    private func performInstall() {
        guard !app.packStore.isInstalled(pack), !installing else { return }
        installing = true
        Task {
            let count = PackInstaller.install(pack, into: app.lutRepository)
            installing = false
            if count > 0 {
                app.packStore.markInstalled(pack)
                installedFlash += 1
                // Post-install confirmation: tells the user where the looks
                // landed instead of leaving them to hunt.
                app.importToast = "\(pack.name) installed, \(count) looks in your library"
            }
        }
    }

    /// Paid packs buy through StoreKit first (C5); free/owned packs install
    /// straight away. LUMA_AUTO_INSTALL keeps bypassing purchase in DEBUG so
    /// headless verification of the bake pipeline still works.
    private func buyOrInstall() {
        if unlocked {
            performInstall()
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_AUTO_INSTALL"] == "1" {
            performInstall()
            return
        }
        #endif
        guard let product = storeService.packProducts[pack.id] else {
            // Products unavailable (offline/review): offer Pro instead.
            showPaywall = true
            return
        }
        Task {
            if await storeService.purchase(product) {
                performInstall()
            }
        }
    }

    // MARK: Rendering

    /// Each row's face: its own photo, cropped square around the person and
    /// graded through the same entry point the installed look will use.
    private func renderPreviews() {
        let looks = pack.looks
        let photos = rowPhotos
        Task.detached(priority: .userInitiated) {
            var frames: [HeroPhoto: CIImage] = [:]
            for index in looks.indices {
                let look = looks[index]
                let photo = index < photos.count ? photos[index] : HeroPhoto.golden
                if frames[photo] == nil {
                    frames[photo] = photo.posterFrame(aspect: 1, longest: 240)
                }
                guard let frame = frames[photo],
                      let cg = PackThumbs.grade(look, on: frame, maxDimension: 180) else { continue }
                await MainActor.run { previews[look.code] = cg }
            }
        }
    }

    private func renderHero() {
        let source = heroSource
        let look = activeLook
        Task.detached(priority: .userInitiated) {
            let cg = PackThumbs.grade(look, on: source, maxDimension: 1200)
            await MainActor.run { hero = cg }
        }
    }

    private func renderTryOn() {
        guard let source = tryOnSource else { return }
        let look = activeLook
        Task.detached(priority: .userInitiated) {
            let cg = PackThumbs.grade(look, on: source, maxDimension: 720)
            await MainActor.run { tryOnImage = cg }
        }
    }

    /// The user's own most recent footage: the newest project's first clip,
    /// then the newest grade session's media. Without either, the panel stays
    /// away: the rows already show every look on a face.
    private func loadTryOnSource() async {
        if let project = app.store.projects.max(by: { $0.updatedAt < $1.updatedAt }),
           let clip = project.clips.first {
            let url = app.store.clipURL(for: clip)
            if FileManager.default.fileExists(atPath: url.path),
               let cg = await EditorState.thumbnail(for: AVURLAsset(url: url),
                                                    at: clip.trimStart + 0.05) {
                tryOnSource = CIImage(cgImage: cg)
                tryOnIsUserMedia = true
                renderTryOn()
                return
            }
        }
        if let session = app.store.gradeSessions.max(by: { $0.updatedAt < $1.updatedAt }) {
            let url = app.store.sessionMediaURL(session)
            if FileManager.default.fileExists(atPath: url.path) {
                if session.isVideo {
                    if let cg = await EditorState.thumbnail(for: AVURLAsset(url: url), at: 0.1) {
                        tryOnSource = CIImage(cgImage: cg)
                        tryOnIsUserMedia = true
                        renderTryOn()
                        return
                    }
                } else if let ci = CIImage(contentsOf: url) {
                    tryOnSource = ci
                    tryOnIsUserMedia = true
                    renderTryOn()
                    return
                }
            }
        }
        tryOnSource = nil
        tryOnIsUserMedia = false
    }
}

// MARK: - 11 Looks tab — the Library

/// The bottom-bar Looks tab IS the Look Library (step 6): the same browser
/// the grade room, camera and editor sheets use, hosted full screen in its
/// Night Lab layout (shelves For you, Film, Night, Pro, Mine and Packs). The
/// Store folds in here: packs ride a rail and their own shelf, and the full
/// store is one tap from Packs. Delete and rename live in each tile's
/// context menu.
struct SavedLooksView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false

    var body: some View {
        ZStack {
            // Ink, like every Night Lab screen: the only colour on it lives
            // in the posters and the pack covers.
            LumaTheme.ink.ignoresSafeArea()
            LookBrowserSheet(context: .library,
                             showsCreateCTA: true,
                             showsBackButton: !isRoot)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}


// MARK: - 12 Custom Look Builder

struct CustomLookBuilderView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @State private var showLensPaywall = false
    @State private var tab =
        ProcessInfo.processInfo.environment["LUMA_SEED_COLORTAB"] ?? "ADJUST"
    @State private var showSaveDialog = false
    @State private var lookName = ""
    @State private var savedConfirmation = false

    var body: some View {
        LumaScreen(title: "Custom Look", trailingText: "Save",
                   trailingAction: { showSaveDialog = true }) {
            if savedConfirmation {
                Label("Look saved", systemImage: "checkmark.circle.fill")
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.teal)
            }
            LookPreviewSurface(radius: 18)
                .frame(height: 210)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["ADJUST", "CURVES", "WHEELS", "HSL", "SPLIT", "EFFECTS"], id: \.self) { segment in
                        Button { tab = segment } label: {
                            Text(segment)
                                .font(.luma(size: 12, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(tab == segment ? LumaTheme.onSignal : LumaTheme.textSecondary)
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .background(tab == segment ? LumaTheme.accent : LumaTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if tab == "ADJUST" {
                VStack(spacing: 20) {
                    GradeSlider(title: "Exposure", value: $app.settings.exposure) {
                        String(format: "%+.2f", $0 / 500)
                    }
                    GradeSlider(title: "Contrast", value: $app.settings.contrast)
                    GradeSlider(title: "Highlights", value: $app.settings.highlights)
                    GradeSlider(title: "Shadows", value: $app.settings.shadows)
                    GradeSlider(title: "Saturation", value: $app.settings.saturation)
                    GradeSlider(title: "Warmth", value: $app.settings.warmth)
                    GradeSlider(title: "Tint", value: $app.settings.tint)
                    GradeSlider(title: "Sharpness", value: Binding(
                        get: { app.settings.sharpness },
                        set: { app.settings.sharpness = max(0, $0) }))
                    GradeSlider(title: "Fade", value: Binding(
                        get: { app.settings.fade },
                        set: { app.settings.fade = max(0, $0) }))
                }
                .padding(.top, 6)
            } else if tab == "CURVES" {
                CurveEditorPanel(curves: $app.settings.curves)
                    .padding(.top, 8)
            } else if tab == "WHEELS" {
                ColorWheelsPanel(wheels: $app.settings.wheels)
                    .padding(.top, 8)
            } else if tab == "HSL" {
                HSLPanel(hsl: $app.settings.hsl)
                    .padding(.top, 8)
            } else if tab == "SPLIT" {
                SplitTonePanel(tone: $app.settings.splitTone)
                    .padding(.top, 8)
            } else if tab == "EFFECTS" {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Lens")
                        .font(.luma(.subheadline, weight: .semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(LensKind.allCases, id: \.self) { lens in
                                let selected = app.settings.lensKind == lens.rawValue
                                let locked = lens.requiresPro && !storeService.isPro
                                Button {
                                    if locked {
                                        showLensPaywall = true
                                        LumaHaptics.shared.tap()
                                        return
                                    }
                                    app.settings.lensKind = lens.rawValue
                                    LumaHaptics.shared.tap()
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: lens.icon)
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundStyle(selected ? LumaTheme.onSignal : LumaTheme.textSecondary)
                                            .frame(width: 62, height: 48)
                                            .background(selected ? LumaTheme.accent : LumaTheme.surface,
                                                        in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(alignment: .topTrailing) {
                                                if locked {
                                                    Image(systemName: "crown.fill")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(.black)
                                                        .padding(3)
                                                        .background(LumaTheme.gold, in: Circle())
                                                        .offset(x: 4, y: -4)
                                                }
                                            }
                                        Text(lens.label)
                                            .font(.luma(size: 11))
                                            .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                                            .lineLimit(1)
                                            .frame(width: 70)
                                    }
                                }
                                .buttonStyle(.lumaPress)
                            }
                        }
                    }
                    if let lens = LensKind(rawValue: app.settings.lensKind), lens != .none {
                        Text(lens.blurb)
                            .font(.luma(.footnote))
                            .foregroundStyle(LumaTheme.textMuted)
                        GradeSlider(title: "Lens Strength", value: Binding(
                            get: { app.settings.lensAmount },
                            set: { app.settings.lensAmount = max(0, $0) }))
                    }

                    Text("Film Texture")
                        .font(.luma(.subheadline, weight: .semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .padding(.top, 4)
                    GradeSlider(title: "Grain", value: Binding(
                        get: { app.settings.grain },
                        set: { app.settings.grain = max(0, $0) }))
                    GradeSlider(title: "Bloom", value: Binding(
                        get: { app.settings.bloom },
                        set: { app.settings.bloom = max(0, $0) }))
                    GradeSlider(title: "Halation", value: Binding(
                        get: { app.settings.halation },
                        set: { app.settings.halation = max(0, $0) }))
                    GradeSlider(title: "Vignette", value: Binding(
                        get: { app.settings.vignette },
                        set: { app.settings.vignette = max(0, $0) }))
                }
                .padding(.top, 6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 28))
                        .foregroundStyle(LumaTheme.textMuted)
                    Text("\(tab.capitalized) tools are coming soon")
                        .font(.luma(size: 15))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }

            Hairline()
                .padding(.top, 6)

            HStack {
                Button {
                    app.settings = LookSettings()
                } label: {
                    Text("Reset")
                        .font(.luma(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .frame(height: 52)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    app.settings = LookSettings()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(LumaTheme.cardRaised))
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showLensPaywall) { PaywallView() }
        .alert("Save Look", isPresented: $showSaveDialog) {
            TextField("Look name", text: $lookName)
            Button("Save") {
                let name = lookName.trimmingCharacters(in: .whitespaces)
                app.saveCurrentLook(named: name.isEmpty ? "My Look" : name)
                lookName = ""
                savedConfirmation = true
            }
            Button("Cancel", role: .cancel) { lookName = "" }
        } message: {
            Text("Saves the current grade so you can reuse it from Saved Looks.")
        }
    }
}

/// Custom Look slider row: label — track — signed value.
private struct GradeSlider: View {
    let title: String
    @Binding var value: Double
    var format: ((Double) -> String)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, alignment: .leading)
            Slider(value: $value, in: -100...100)
                .tint(LumaTheme.accent)
            Text(format?(value) ?? String(format: "%+d", Int(value)))
                .font(.luma(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}

// MARK: - 13 Project Library

/// Projects in the shipping design language: the newest edit's own frame on
/// top, uncovered; the record list — still a NATIVE inset-grouped List, so
/// swipe-to-delete and native separators survive — in the drawer under it.
/// Monochrome throughout; the only numbers set in mono are the counts and the
/// running times, which are numbers.
struct ProjectLibraryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var isRoot: Bool = false

    @State private var filter: ProjectFilter = .all
    @State private var showTemplates = false
    @State private var pendingDelete: StoredProject?

    /// The calm Projects page (23 Nov 2026): the newest edit over its own
    /// faded frame, quiet pills, text tabs and a two-column grid.
    enum ProjectFilter: String, CaseIterable {
        case all = "All", videos = "Videos", photos = "Photos"
    }

    /// The newest project, which is what the hero shows and what Resume
    /// opens. Nil while the library is empty.
    private var newest: StoredProject? {
        app.store.projects.max(by: { $0.updatedAt < $1.updatedAt })
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            ZStack(alignment: .top) {
                LumaTheme.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let newest {
                            heroBlock(newest, safeTop: safeTop)
                            filterTabs
                            projectSections
                        } else {
                            emptyHero(safeTop: safeTop)
                            templateGrid(Array(TemplateLibrary.shown.prefix(4)),
                                         title: "Or start from a template")
                        }
                        Color.clear.frame(height: 130)
                    }
                }
                .ignoresSafeArea(edges: .top)
                header
                    .background(alignment: .top) {
                        LinearGradient(colors: [LumaTheme.background.opacity(0.85),
                                                LumaTheme.background.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: safeTop + 70)
                            .offset(y: -safeTop)
                            .allowsHitTesting(false)
                    }
                if !isRoot { backButton }
            }
        }
        .sheet(isPresented: $showTemplates) {
            ProjectTemplatesSheet { template in
                showTemplates = false
                startTemplate(template)
            }
        }
        .confirmationDialog("Delete this project?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { project in
            Button("Delete \(project.title)", role: .destructive) {
                // If the editor still holds this edit, let it go without
                // saving, or the next save would bring it back.
                if app.editor.projectID == project.id {
                    app.editor.startNewProject(saving: false)
                }
                app.store.deleteProject(project.id)
                pendingDelete = nil
            }
        } message: { _ in
            Text("The edit goes; your clips stay in Photos.")
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: Top row

    /// The top row, in the same spot as every tab's. On the tab: Projects,
    /// then Pro and You (New video and New project live in the page).
    /// Pushed from elsewhere: the title and + for a new video.
    private var header: some View {
        Group {
            if isRoot {
                LumaTopBar(title: "Projects")
            } else {
                LumaTabHeader {
                    LumaTabTitle(text: "Projects")
                } trailing: {
                    Button {
                        app.openSelectClips(.edit)
                        LumaHaptics.shared.tap()
                    } label: {
                        LumaTabGlyph(systemName: "plus")
                    }
                    .buttonStyle(.lumaPress)
                    .accessibilityLabel("New video")
                }
            }
        }
        .padding(.top, LumaTabMetrics.top)
        .padding(.bottom, 2)
    }

    // MARK: Hero

    /// The newest edit: its first frame faded behind the top bar, with its
    /// name, length, clips and look over it, then the pills.
    private func heroBlock(_ project: StoredProject, safeTop: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MOST RECENT · \(Self.ago(project.updatedAt))")
                .font(.luma(size: 11, weight: .bold))
                .kerning(1.3)
                .foregroundStyle(.white.opacity(0.55))
            Text(project.title)
                .font(.luma(size: 31, weight: .bold))
                .kerning(-0.9)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 6)
            Text(Self.meta(project, withLook: true))
                .font(.luma(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .padding(.top, 6)
            pills([
                Pill(title: "Resume", icon: "play.fill", solid: true) { open(project) },
                Pill(title: "New video", icon: "plus") { newVideo() },
                Pill(title: "Templates", icon: "rectangle.split.2x1") { showTemplates = true },
                Pill(title: "Blank project", icon: "square.dashed") { blankProject() },
            ])
            .padding(.top, 18)
        }
        .padding(.top, safeTop + 88)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .background(alignment: .top) {
            fadedBackdrop(height: safeTop + 298) {
                ProjectThumb(project: project, store: app.store, radius: 0)
            }
            .onTapGesture { open(project) }
        }
    }

    /// A picture faded into the page: dimmed, a little less saturated, and
    /// run into ink at the bottom.
    private func fadedBackdrop<Picture: View>(height: CGFloat,
                                              @ViewBuilder picture: () -> Picture) -> some View {
        ZStack {
            picture()
                .opacity(0.62)
                .saturation(0.8)
            LinearGradient(stops: [
                .init(color: LumaTheme.background.opacity(0.55), location: 0),
                .init(color: LumaTheme.background.opacity(0.2), location: 0.26),
                .init(color: LumaTheme.background.opacity(0.5), location: 0.58),
                .init(color: LumaTheme.background.opacity(0.94), location: 0.86),
                .init(color: LumaTheme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
    }

    // MARK: Pills

    private struct Pill: Identifiable {
        var id: String { title }
        let title: String
        let icon: String
        var solid: Bool = false
        let action: () -> Void
    }

    /// Quiet glass pills; the one solid white pill is the main action.
    private func pills(_ items: [Pill]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        item.action()
                        LumaHaptics.shared.tap()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .semibold))
                            Text(item.title)
                                .font(.luma(size: 14, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(item.solid ? Color(hex: 0x0B0C0E) : .white.opacity(0.92))
                        .padding(.leading, 12)
                        .padding(.trailing, 15)
                        .frame(height: 38)
                        .background(item.solid ? AnyShapeStyle(Color(hex: 0xF4F5F6))
                                               : AnyShapeStyle(Color.white.opacity(0.11)),
                                    in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
    }

    // MARK: Tabs and the grid

    private var filterTabs: some View {
        HStack(spacing: 22) {
            ForEach(ProjectFilter.allCases, id: \.self) { item in
                let on = filter == item
                Button {
                    filter = item
                    LumaHaptics.shared.tap()
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text(item.rawValue)
                                .font(.luma(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(on ? 1 : 0.42))
                            if item == .all {
                                Text("\(app.store.projects.count)")
                                    .font(.luma(size: 14.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        Capsule()
                            .fill(on ? Color.white : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var filtered: [StoredProject] {
        let sorted = app.store.projects.sorted { $0.updatedAt > $1.updatedAt }
        switch filter {
        case .all:    return sorted
        case .videos: return sorted.filter { !Self.isPhoto($0) }
        case .photos: return sorted.filter { Self.isPhoto($0) }
        }
    }

    @ViewBuilder
    private var projectSections: some View {
        let groups = Self.sections(filtered)
        if groups.isEmpty {
            Text(filter == .photos ? "No photo edits yet." : "No video edits yet.")
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 28)
        }
        ForEach(groups, id: \.title) { group in
            Text(group.title)
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(group.items) { project in
                    ProjectGridTile(project: project, store: app.store) { open(project) }
                        .contextMenu {
                            Button { open(project) } label: { Label("Open", systemImage: "play") }
                            Button(role: .destructive) { pendingDelete = project } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Empty state

    /// No projects yet: a face faded into the page, the light and bold
    /// headline, and the pills. Templates to start from sit below.
    private func emptyHero(safeTop: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LumaHeadline(light: "No projects", heavy: "yet", size: 31)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Every edit saves here as you work.")
                .font(.luma(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 8)
            pills([
                Pill(title: "New video", icon: "plus", solid: true) { newVideo() },
                Pill(title: "Templates", icon: "rectangle.split.2x1") { showTemplates = true },
                Pill(title: "Blank project", icon: "square.dashed") { blankProject() },
            ])
            .padding(.top, 18)
        }
        .padding(.top, safeTop + 200)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .background(alignment: .top) {
            fadedBackdrop(height: safeTop + 358) {
                HomeGradedPhoto(photo: .campaign, lookName: "CN93 · Luxury Campaign", maxDimension: 1100)
            }
        }
    }

    private func templateGrid(_ templates: [VideoTemplate], title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 10)
            ProjectTemplateGrid(templates: templates) { startTemplate($0) }
                .padding(.horizontal, 12)
        }
    }

    // MARK: Doors

    private var backButton: some View {
        VStack {
            Spacer()
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func open(_ project: StoredProject) {
        app.editor.load(project: project)
        app.path.append(.editor)
    }

    /// Same door as Home's New video: Select clips for a new edit.
    private func newVideo() {
        app.openSelectClips(.edit)
    }

    private func blankProject() {
        app.editor.startNewProject()
        app.editor.opensBlank = true
        app.path.append(.editor)
    }

    private func startTemplate(_ template: VideoTemplate) {
        app.openSelectClips(.edit, templateID: template.id)
    }

    // MARK: Words

    /// "2 H AGO", "12 MIN AGO", "YESTERDAY", "12 NOV".
    static func ago(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "JUST NOW" }
        if seconds < 3600 { return "\(Int(seconds / 60)) MIN AGO" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) H AGO" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.day().month(.abbreviated)).uppercased()
    }

    /// "0:12 · 6 clips · KD2 Golden Hour" (the look when a clip carries one).
    static func meta(_ project: StoredProject, withLook: Bool) -> String {
        let seconds = Int(project.duration.rounded())
        var parts = [String(format: "%d:%02d", seconds / 60, seconds % 60),
                     "\(project.clips.count) \(project.clips.count == 1 ? "clip" : "clips")"]
        if withLook, let look = lookName(project) { parts.append(look) }
        return parts.joined(separator: " · ")
    }

    /// The first clip grade's look, "KD2 · Golden Hour" shown as "KD2 Golden Hour".
    static func lookName(_ project: StoredProject) -> String? {
        guard let name = project.clips.lazy.compactMap({ $0.grade?.baseLookName }).first,
              !name.isEmpty else { return nil }
        return name.replacingOccurrences(of: " · ", with: " ")
    }

    static func isPhoto(_ project: StoredProject) -> Bool {
        !project.clips.isEmpty && project.clips.allSatisfy { $0.isImage == true }
    }

    struct ProjectSection {
        let title: String
        let items: [StoredProject]
    }

    /// Today, Yesterday, This week, then by month.
    static func sections(_ projects: [StoredProject]) -> [ProjectSection] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [StoredProject]] = [:]
        for project in projects {
            let date = project.updatedAt
            let title: String
            if calendar.isDateInToday(date) {
                title = "Today"
            } else if calendar.isDateInYesterday(date) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
                title = "This week"
            } else {
                title = date.formatted(.dateTime.month(.wide).year())
            }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(project)
        }
        return order.map { ProjectSection(title: $0, items: buckets[$0] ?? []) }
    }
}

/// One project in the grid: its first frame, the length on a small glass
/// tag (videos), and the name and look on the picture.
private struct ProjectGridTile: View {
    let project: StoredProject
    let store: PersistenceStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProjectThumb(project: project, store: store, radius: 15)
                .frame(height: 232)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 96)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 15, bottomTrailingRadius: 15,
                                                          style: .continuous))
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title)
                            .font(.luma(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(ProjectLibraryView.lookName(project)
                             ?? "\(project.clips.count) \(project.clips.count == 1 ? "clip" : "clips")")
                            .font(.luma(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
                }
                .overlay(alignment: .topTrailing) {
                    if !ProjectLibraryView.isPhoto(project) {
                        ProjectDurationTag(seconds: project.duration, play: true)
                            .padding(9)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(project.title), \(ProjectLibraryView.meta(project, withLook: true))")
    }
}

/// "▶ 0:12" on dark glass.
private struct ProjectDurationTag: View {
    let seconds: Double
    var play: Bool = false

    var body: some View {
        let total = Int(seconds.rounded())
        HStack(spacing: 4) {
            if play {
                Image(systemName: "play.fill")
                    .font(.system(size: 7, weight: .bold))
            }
            Text(String(format: "%d:%02d", total / 60, total % 60))
                .font(.luma(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// Templates as two columns of posters: length, name and clip count.
private struct ProjectTemplateGrid: View {
    let templates: [VideoTemplate]
    let onPick: (VideoTemplate) -> Void

    private static let fallback: [HeroPhoto] = [.skate, .golden, .bridge, .gig, .party, .campaign]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                  spacing: 8) {
            ForEach(Array(templates.enumerated()), id: \.element.id) { item in
                let template = item.element
                let photo = template.poster.flatMap(HeroPhoto.init(rawValue:))
                    ?? Self.fallback[item.offset % Self.fallback.count]
                Button {
                    onPick(template)
                    LumaHaptics.shared.tap()
                } label: {
                    HeroImage(photo: photo, radius: 15)
                        .frame(height: 196)
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.66)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 96)
                                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 15,
                                                                  bottomTrailingRadius: 15,
                                                                  style: .continuous))
                        }
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.luma(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text("\(template.clipCount) \(template.clipCount == 1 ? "clip" : "clips")")
                                    .font(.luma(size: 11.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.66))
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 11)
                        }
                        .overlay(alignment: .topTrailing) {
                            ProjectDurationTag(seconds: template.totalDuration)
                                .padding(9)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Template \(template.name)")
            }
        }
    }
}

/// Every template, from the Templates pill.
private struct ProjectTemplatesSheet: View {
    let onPick: (VideoTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Templates")
                    .font(.luma(size: 22, weight: .bold))
                    .kerning(-0.5)
                    .foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 14)
            ScrollView(showsIndicators: false) {
                ProjectTemplateGrid(templates: TemplateLibrary.shown, onPick: onPick)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 30)
            }
        }
        .background(LumaTheme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

/// First-frame thumbnail of a stored project's first clip.
struct ProjectThumb: View {
    let project: StoredProject
    let store: PersistenceStore
    var fallback: MockScene = .sunsetRoad
    /// Corner radius, so the same thumbnail serves both the 44 pt list row and
    /// the full-width hero at the top of the Projects screen.
    var radius: CGFloat = 14
    @State private var thumbnail: CGImage?
    @State private var loadedID: UUID?

    var body: some View {
        Color.clear
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    SceneArt(scene: fallback)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Thumb sits inside the project row's Button — the overflowing fill
            // must not extend the row's touch target past its artwork.
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // Keyed on the project, so a reused view (the hero after the newest
        // project is deleted) loads the new first frame.
        .task(id: project.id) {
            guard loadedID != project.id else { return }
            thumbnail = nil
            loadedID = project.id
            guard let first = project.clips.first else { return }
            let url = store.clipURL(for: first)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // A photo clip has no video track to grab a frame from.
            if first.isImage == true {
                thumbnail = EditorState.imageThumbnail(at: url, maxDimension: 900)
                return
            }
            thumbnail = await EditorState.thumbnail(for: AVURLAsset(url: url),
                                                    at: first.trimStart + 0.02)
        }
    }
}

// MARK: - 14 Crop / Format

struct CropFormatView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 100.0
    @State private var format: EditorFormat = .widescreen
    @State private var canvasMode: CanvasBackgroundMode = .fill
    @State private var framePreset: FramePreset = .none

    var body: some View {
        LumaScreen(title: "Format", trailingText: "Apply", trailingAction: {
            app.editor.setFormat(format, zoom: zoom)
            app.editor.setCanvasMode(canvasMode)
            app.editor.setFramePreset(framePreset)
            dismiss()
        }) {
            // Live crop preview: the chosen aspect framed over the footage,
            // with a rule-of-thirds grid inside the crop box.
            previewSurface
                .frame(height: 340)
                .overlay(
                    GeometryReader { geo in
                        let box = cropBox(in: geo.size)
                        ZStack {
                            // Dim everything outside the crop.
                            Color.black.opacity(0.55)
                                .reverseMask {
                                    Rectangle()
                                        .frame(width: box.width, height: box.height)
                                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                }
                            Path { p in
                                for i in 1...2 {
                                    let x = box.minX + box.width * CGFloat(i) / 3
                                    let y = box.minY + box.height * CGFloat(i) / 3
                                    p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                                    p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                                }
                            }
                            .stroke(.white.opacity(0.5), lineWidth: 1)
                            Rectangle()
                                .stroke(.white.opacity(0.85), lineWidth: 1.5)
                                .frame(width: box.width, height: box.height)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

            HStack(alignment: .top, spacing: 12) {
                ForEach(EditorFormat.allCases, id: \.self) { option in
                    ToolTile(title: option.rawValue, icon: option.icon, subtitle: option.subtitle,
                             selected: format == option) { format = option }
                }
            }

            // Canvas background: how the clip sits inside the frame (fill vs
            // fit with a background painted in the bars).
            Text("Canvas")
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CanvasBackgroundMode.allCases, id: \.self) { mode in
                        Button { canvasMode = mode } label: {
                            VStack(spacing: 6) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 20, weight: .medium))
                                Text(mode.label).font(.luma(size: 12))
                            }
                            .frame(width: 72, height: 62)
                            .foregroundStyle(canvasMode == mode ? .black : .white)
                            .background(canvasMode == mode ? AnyShapeStyle(LumaTheme.accentBright)
                                                           : AnyShapeStyle(LumaTheme.surface),
                                        in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Frame: a border composited over the finished picture — drawn
            // last, so nothing upstream grades or wipes across it.
            Text("Frame")
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FramePreset.allCases, id: \.self) { preset in
                        Button { framePreset = preset } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 20, weight: .medium))
                                Text(preset.label).font(.luma(size: 12))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(width: 82, height: 62)
                            .foregroundStyle(framePreset == preset ? .black : .white)
                            .background(framePreset == preset ? AnyShapeStyle(LumaTheme.accentBright)
                                                             : AnyShapeStyle(LumaTheme.surface),
                                        in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            InlineSlider(title: "Zoom", value: $zoom, range: 100...300) { "\(Int($0))" }

            // A "Position" row used to sit here: left / centre / right buttons
            // wired to nothing. Per-clip framing already lives in the editor
            // (Crop and Motion), so the row is gone and the reset it carried
            // sits under the slider it resets.
            Button {
                withAnimation(.snappy(duration: 0.2)) { zoom = 100 }
                LumaHaptics.shared.tap()
            } label: {
                Label("Reset zoom", systemImage: "arrow.counterclockwise")
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(LumaTheme.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(zoom == 100)
            .opacity(zoom == 100 ? 0.4 : 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear {
            format = app.editor.format
            zoom = app.editor.zoom
            canvasMode = app.editor.canvasMode
            framePreset = FramePreset(rawValue: app.editor.framePreset) ?? .none
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        if let thumb = app.editor.selectedClip?.thumbnail ?? app.editor.clips.first?.thumbnail {
            Image(decorative: thumb, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            HeroImage(photo: .drive)
        }
    }

    private func cropBox(in size: CGSize) -> CGRect {
        let aspect = format.aspect
        var width = size.width - 36
        var height = width / aspect
        if height > size.height - 36 {
            height = size.height - 36
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}

private extension View {
    /// Cuts `mask` out of the receiving view (inverse mask).
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(mask().blendMode(.destinationOut))
                .compositingGroup()
        }
    }
}

// MARK: - 15 Audio

struct AudioView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var volume = 100.0
    @State private var fadeIn = 0.0
    @State private var fadeOut = 0.0
    @State private var mute = false
    @State private var showMusicImporter = false
    @State private var importError: String?

    /// The project's real music track, if it has one. The card used to assert
    /// "Chill Vibes / By Soundstripe / 02:45" over a waveform generated by
    /// `(i * 37) % 40`, and drew it even when the project had no audio at all.
    private var musicTrack: EditorState.MusicTrack? {
        app.editor.audioTracks.first { $0.kind == .music }
    }

    private var voiceTrackCount: Int {
        app.editor.audioTracks.filter { $0.kind == .voice }.count
    }

    var body: some View {
        LumaScreen(title: "Audio", trailingIcon: "checkmark", trailingAction: {
            applyToEditor()
            dismiss()
        }) {
            InlineSlider(title: "Volume", value: $volume) { "\(Int($0))%" }

            Hairline()

            // No chevron: a chevron promises a destination, and there was
            // never one behind it.
            HStack {
                Text("Music")
                    .font(.luma(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if let importError {
                    Text(importError)
                        .font(.luma(size: 13))
                        .foregroundStyle(LumaTheme.orange)
                        .lineLimit(1)
                }
            }

            musicCard

            InlineSlider(title: "Fade In", value: $fadeIn, range: 0...4) { String(format: "%.1fs", $0) }
            InlineSlider(title: "Fade Out", value: $fadeOut, range: 0...4) { String(format: "%.1fs", $0) }

            Hairline()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voiceover")
                        .font(.luma(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text(voiceoverSubtitle)
                        .font(.luma(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                Spacer()
                // Bound to the real recorder that already exists on
                // EditorState; this button used to do nothing at all.
                Button {
                    if app.editor.isRecordingVoiceover {
                        app.editor.stopVoiceover()
                    } else {
                        app.editor.startVoiceover()
                    }
                    LumaHaptics.shared.tap()
                } label: {
                    Circle()
                        .fill(app.editor.isRecordingVoiceover
                              ? AnyShapeStyle(LumaTheme.orange)
                              : AnyShapeStyle(LumaTheme.surfaceStrong))
                        .frame(width: 56, height: 56)
                        .overlay(Image(systemName: app.editor.isRecordingVoiceover ? "stop.fill" : "mic")
                            .font(.luma(size: 21, weight: .medium))
                            .foregroundStyle(.white))
                }
                .buttonStyle(.plain)
                .disabled(app.editor.totalDuration <= 0.4)
                .opacity(app.editor.totalDuration <= 0.4 ? 0.4 : 1)
            }

            Hairline()

            Toggle(isOn: $mute) {
                Text("Mute Clip Audio")
                    .font(.luma(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .tint(LumaTheme.accent)
        }
        .fileImporter(isPresented: $showMusicImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            handleMusicImport(result)
        }
        .onAppear {
            volume = app.editor.volume
            fadeIn = app.editor.fadeIn
            fadeOut = app.editor.fadeOut
            mute = app.editor.muteAudio
        }
        .onChange(of: volume) { _, _ in applyToEditor() }
        .onChange(of: mute) { _, _ in applyToEditor() }
        .onChange(of: fadeIn) { _, _ in applyToEditor() }
        .onChange(of: fadeOut) { _, _ in applyToEditor() }
    }

    private func clock(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private var voiceoverSubtitle: String {
        if app.editor.isRecordingVoiceover { return "Recording — tap to stop" }
        if app.editor.totalDuration <= 0.4 { return "Add a clip to record over" }
        if voiceTrackCount > 0 {
            return voiceTrackCount == 1 ? "1 take recorded" : "\(voiceTrackCount) takes recorded"
        }
        return "Tap to record"
    }

    /// The real project music, or an honest empty state. Title, duration and
    /// waveform all come from the actual `MusicTrack`.
    @ViewBuilder
    private var musicCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(musicTrack == nil ? LumaTheme.surfaceStrong : LumaTheme.accentDeep)
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: musicTrack == nil ? "plus" : "waveform")
                        .font(.luma(size: 18, weight: .semibold))
                        .foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(musicTrack?.title ?? "No music")
                        .font(.luma(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(musicTrack.map { clock($0.timelineDuration) }
                         ?? "Add a track to score this project")
                        .font(.luma(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                Spacer()
                Button {
                    showMusicImporter = true
                    LumaHaptics.shared.tap()
                } label: {
                    Text(musicTrack == nil ? "Add" : "Change")
                        .font(.luma(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(LumaTheme.accentDeep.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // The real RMS buckets the lane waveform uses. Drawn only when the
            // track actually has them, rather than inventing a shape.
            if let track = musicTrack, !track.waveform.isEmpty {
                GeometryReader { geo in
                    let peak = max(track.waveform.max() ?? 1, 0.0001)
                    let bars = min(track.waveform.count, 52)
                    let step = max(1, track.waveform.count / bars)
                    HStack(spacing: 2.5) {
                        ForEach(0..<bars, id: \.self) { i in
                            let v = CGFloat(track.waveform[min(i * step, track.waveform.count - 1)] / peak)
                            Capsule()
                                .fill(LumaTheme.accentBright.opacity(0.95))
                                .frame(width: 3, height: max(3, v * geo.size.height))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .frame(height: 60)
            }
        }
        .padding(16)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Same import path the editor uses (EditorScreen.handleMusicImport).
    private func handleMusicImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let imported = app.editor.importMusicFile(from: url) else {
            importError = "Couldn't import that file."
            return
        }
        importError = nil
        let title = url.deletingPathExtension().lastPathComponent
        Task {
            // "Change" replaces rather than stacks: the card shows one track.
            if let existing = musicTrack { app.editor.removeAudioTrack(id: existing.id) }
            await app.editor.addAudioTrack(importedURL: imported, title: title)
        }
    }

    /// Pushes the settings into the editor's live audio mix.
    private func applyToEditor() {
        app.editor.volume = volume
        app.editor.fadeIn = fadeIn
        app.editor.fadeOut = fadeOut
        app.editor.muteAudio = mute
        app.editor.applyAudioSettings()
    }
}

// MARK: - 16 Settings / Subscription

/// The You tab, in the calm design (calm mock v2, 04-you.jpg): your plan in
/// one card, then short groups of quiet glass rows with no outlines.
/// Preferences leads with Appearance, which shows what is picked
/// ("Colour · Ruler") and pushes You › Appearance. Get Pro lives once, in
/// the top bar; the card offers "See what Pro adds" quietly, and Restore
/// moves into the card so Purchases is no longer a group of one. Every
/// legally required row (Privacy Policy, Terms of Use) stays.
struct SettingsSubscriptionView: View {
    var isRoot: Bool = false
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @State private var showPaywall = false
    @State private var showExportQuality = false
    @State private var showAbout = false
    @State private var showPhotoCredits = false
    @State private var showManageSubscriptions = false
    @State private var showLanguageNotice = false
    @State private var showStorageDetail = false
    @State private var lutBytes: Int64 = 0
    /// Restore is a network round-trip that usually ends in "nothing to
    /// restore", so it has to say so, or the pill reads as dead.
    @State private var restoring = false
    @State private var restoreResult: String?
    /// Shown when no mail client can take the mailto:, otherwise the only
    /// support path in the app dead-ends silently.
    @State private var showSupportFallback = false
    /// "Yearly · renews 21 November 2027", read from StoreKit while Pro.
    @State private var planDetail: String?
    @State private var planIsLifetime = false
    /// Same store the export spec sheet reads on appear, so changing it here
    /// really changes the default the exporter uses.
    @AppStorage("lumalook.exportSpec") private var storedSpec = ExportSpec().rawValue
    /// The Appearance row's value follows the choices live.
    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue

    var body: some View {
        ZStack {
            // The You tab sits on the page's ink like every other tab.
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                if isRoot {
                    // The tab's one row: You, then Pro and You (lit here).
                    LumaTopBar(title: "You")
                        .padding(.top, LumaTabMetrics.top)
                        .padding(.bottom, 4)
                } else {
                    header
                }
                settingsList
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showExportQuality) {
            exportQualitySheet
                // Three rows plus the header measure more than a third of the
                // screen at larger type, so the sheet is medium and the
                // content scrolls rather than clipping the last resolution.
                .presentationDetents([.medium])
                .presentationBackground(LumaTheme.ink)
        }
        .sheet(isPresented: $showAbout) {
            aboutSheet
                .presentationDetents([.medium])
                .presentationBackground(LumaTheme.ink)
        }
        .sheet(isPresented: $showPhotoCredits) {
            PhotoCreditsSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(LumaTheme.ink)
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        // Every restore says what happened: success, nothing found, or error.
        .alert("Restore purchases", isPresented: Binding(
            get: { restoreResult != nil },
            set: { if !$0 { restoreResult = nil } })) {
            Button("OK", role: .cancel) { restoreResult = nil }
        } message: {
            Text(restoreResult ?? "")
        }
        // Fallback when no mail client can take the mailto:.
        .confirmationDialog("Help and support", isPresented: $showSupportFallback,
                            titleVisibility: .visible) {
            Button("Copy email address") {
                UIPasteboard.general.string = Self.supportAddress
            }
            Button("Done", role: .cancel) { }
        } message: {
            Text("No mail app is set up on this device. Email \(Self.supportAddress) from anywhere and we'll answer.")
        }
        // The row leaves the app, so it says so before it does.
        .confirmationDialog("App language", isPresented: $showLanguageNotice,
                            titleVisibility: .visible) {
            Button("Open iOS Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("iOS keeps per-app language under Settings › Lumalook. This will leave Lumalook.")
        }
        // Plain facts about what the LUT library costs on disk. No "clean up"
        // button, because every byte here is a look the user chose to keep and
        // deleting them belongs in LUT Manager where they can see what goes.
        .confirmationDialog("Storage", isPresented: $showStorageDetail,
                            titleVisibility: .visible) {
            Button("Manage imported LUTs") { app.path.append(.lutManager) }
            Button("Done", role: .cancel) { }
        } message: {
            Text("\(app.lutRepository.luts.count) LUTs using \(lutStorageDescription) in Lumalook's documents folder. Removing a LUT frees its space immediately.")
        }
        .task {
            lutBytes = await Self.directorySize(of: app.lutRepository.lutFolderURL)
        }
        .task(id: storeService.isPro) {
            await loadPlanDetail()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUMA_SEED_PAYWALL"] == "1" {
                showPaywall = true
            }
            #endif
        }
    }

    /// Only when You is pushed rather than shown as the tab (the root view
    /// normally turns a pushed You into a tab switch).
    private var header: some View {
        ZStack {
            Text("You")
                .font(.luma(size: 17, weight: .semibold))
                .tracking(-0.25)
                .foregroundStyle(LumaTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                SettingsBackCircle { dismiss() }
                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var lutStorageDescription: String {
        ByteCountFormatter.string(fromByteCount: lutBytes, countStyle: .file)
    }

    /// Off the main actor: enumerating the LUT folder touches the filesystem.
    private static func directorySize(of url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            guard let files = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return Int64(0) }
            var total = Int64(0)
            for case let file as URL in files {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                total += Int64(size ?? 0)
            }
            return total
        }.value
    }

    // MARK: The page

    private var settingsList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    planCard
                        .id(Self.planRowID)
                        .padding(.top, 8)
                    groupLabel("Preferences")
                    preferencesGroup
                    groupLabel("Storage")
                    storageGroup
                    groupLabel("About")
                    aboutGroup
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            // The top bar's Pro badge, tapped while already here.
            .onReceive(NotificationCenter.default.publisher(for: .lumaShowPlan)) { _ in
                withAnimation(.snappy(duration: 0.3)) {
                    proxy.scrollTo(Self.planRowID, anchor: .top)
                }
            }
        }
    }

    private static let planRowID = "plan"

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
            .padding(.leading, 16)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private var appearanceSummary: String {
        LumaAppearance.summary(names: LumaNameStyle(rawValue: namesRaw) ?? .colour,
                               slider: LumaSliderStyle(rawValue: sliderRaw) ?? .ruler)
    }

    private var languageName: String {
        Locale.current.localizedString(
            forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")
            ?? "English"
    }

    private var preferencesGroup: some View {
        SettingsRowGroup {
            settingsRow(icon: "paintpalette", title: "Appearance",
                        value: appearanceSummary) {
                app.path.append(.appearance)
            }
            SettingsRowDivider()
            settingsRow(icon: "4k.tv", title: "Export quality",
                        value: ExportSpec.from(rawValue: storedSpec).resolution.rawValue) {
                showExportQuality = true
            }
            SettingsRowDivider()
            settingsRow(icon: "globe", title: "App language",
                        value: languageName, opensExternally: true) {
                // Per-app language lives in iOS Settings: confirm first,
                // because unlike Export quality this leaves the app.
                showLanguageNotice = true
            }
        }
    }

    private var storageGroup: some View {
        SettingsRowGroup {
            settingsRow(icon: "cube", title: "Imported LUTs",
                        value: "\(app.lutRepository.luts.count)") {
                app.path.append(.lutManager)
            }
            SettingsRowDivider()
            settingsRow(icon: "internaldrive", title: "Storage used",
                        value: lutStorageDescription) {
                showStorageDetail = true
            }
        }
    }

    private var aboutGroup: some View {
        SettingsRowGroup {
            settingsRow(icon: "questionmark.circle", title: "Help and support",
                        opensExternally: true) {
                openSupportMail()
            }
            SettingsRowDivider()
            settingsRow(icon: "star", title: "Rate Lumalook",
                        opensExternally: true) {
                requestReview()
            }
            SettingsRowDivider()
            legalRows
            SettingsRowDivider()
            settingsRow(icon: "photo", title: "Photo credits") {
                showPhotoCredits = true
            }
            SettingsRowDivider()
            settingsRow(icon: "info.circle", title: "About Lumalook",
                        value: "v\(Self.appVersion)") {
                showAbout = true
            }
        }
    }

    /// Auto-renewable subscriptions must expose both of these on a reachable
    /// surface; they are also linked from the paywall.
    @ViewBuilder
    private var legalRows: some View {
        settingsRow(icon: "hand.raised", title: "Privacy Policy",
                    opensExternally: true) {
            LumaLegal.open(LumaLegal.privacy)
        }
        SettingsRowDivider()
        settingsRow(icon: "doc.text", title: "Terms of Use",
                    opensExternally: true) {
            LumaLegal.open(LumaLegal.terms)
        }
    }

    /// One quiet row: glyph, title, the value in grey, then a chevron, or the
    /// system "leaves the app" glyph when `opensExternally`, so a row that
    /// ejects to iOS Settings or Mail never wears the same affordance as one
    /// that opens something in the app.
    private func settingsRow(icon: String, title: String, value: String? = nil,
                             opensExternally: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 20)
                Text(title)
                    .font(.luma(size: 15, weight: .medium))
                    .tracking(-0.15)
                    .foregroundStyle(LumaTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.luma(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
                Image(systemName: opensExternally ? "arrow.up.forward.app" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: Plan card

    /// Your plan in one card. Free: what you can export today with a thin
    /// bar, then "See what Pro adds" and Restore. Pro: when it renews, what
    /// it includes, then Manage plan and Restore.
    private var planCard: some View {
        let pro = storeService.isPro
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if pro {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LumaTheme.signal)
                }
                Text(pro ? "Lumalook Pro" : "Lumalook Free")
                    .font(.luma(size: 19, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(LumaTheme.textPrimary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if pro {
                proDetails
            } else {
                freeDetails
            }
            planPills
                .padding(.top, 14)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Looks this person can export today: every look in a pack they can use
    /// (the free packs, plus any pack bought on its own).
    private var exportableLookCount: Int {
        PackCatalog.packs
            .filter { storeService.ownsPack($0.id) }
            .reduce(0) { $0 + $1.looks.count }
    }

    private var freeDetails: some View {
        let total = max(PackCatalog.totalLookCount, 1)
        let usable = min(exportableLookCount, total)
        let fraction = CGFloat(usable) / CGFloat(total)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Preview every look. Export with \(usable) of the \(total).")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            .padding(.top, 14)
            .accessibilityHidden(true)
        }
    }

    private var proDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(planDetail ?? "Every look and every pack")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 4)
            Text("All \(PackCatalog.totalLookCount) looks, every new pack, batch export and .cube out.")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private var planPills: some View {
        HStack(spacing: 8) {
            if storeService.isPro {
                // A Lifetime purchase has no subscription to manage.
                if !planIsLifetime {
                    planPill("Manage plan", icon: "creditcard") {
                        showManageSubscriptions = true
                    }
                }
            } else {
                planPill("See what Pro adds", icon: "sparkle", iconColour: LumaTheme.signal) {
                    showPaywall = true
                }
            }
            planPill("Restore", icon: "arrow.clockwise", busy: restoring) {
                performRestore()
            }
            .disabled(restoring)
            .accessibilityLabel("Restore purchases")
        }
    }

    /// A quiet glass pill in the plan card.
    private func planPill(_ title: String, icon: String,
                          iconColour: Color = Color.white.opacity(0.92),
                          busy: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.white.opacity(0.7))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColour)
                }
                Text(title)
                    .font(.luma(size: 14, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.trailing, 15)
            .frame(height: 38)
            .background(Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .fixedSize()
    }

    private static let planDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    /// Which Pro this is and when it renews, straight from StoreKit's current
    /// entitlements (RevenueCat purchases are StoreKit transactions too).
    /// Leaves the generic line when nothing is found, e.g. a seeded Pro.
    private func loadPlanDetail() async {
        guard storeService.isPro else {
            planDetail = nil
            planIsLifetime = false
            return
        }
        var detail: String?
        var lifetime = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            let productID = transaction.productID
            if productID == StoreService.ProductID.proLifetime {
                detail = "Lifetime · yours for good"
                lifetime = true
                break
            }
            guard productID == StoreService.ProductID.proYearly
                    || productID == StoreService.ProductID.proMonthly else { continue }
            let plan = productID == StoreService.ProductID.proYearly ? "Yearly" : "Monthly"
            guard let end = transaction.expirationDate else {
                detail = plan
                continue
            }
            var renews = true
            if let status = await transaction.subscriptionStatus,
               case .verified(let renewal) = status.renewalInfo {
                renews = renewal.willAutoRenew
            }
            let date = Self.planDateFormatter.string(from: end)
            detail = "\(plan) · \(renews ? "renews" : "ends") \(date)"
        }
        planDetail = detail
        planIsLifetime = lifetime
    }

    // MARK: Restore / support

    /// Restore always ends in a spoken result. The common case is a free user
    /// with nothing to restore, which previously produced no feedback at all.
    private func performRestore() {
        guard !restoring else { return }
        restoring = true
        storeService.lastError = nil
        Task {
            await storeService.restorePurchases()
            restoring = false
            if let error = storeService.lastError {
                restoreResult = error
                storeService.lastError = nil
            } else if storeService.isPro {
                restoreResult = "Pro restored. Every look is unlocked on this device."
            } else if !storeService.ownedPackIDs.isEmpty {
                restoreResult = "\(storeService.ownedPackIDs.count) purchased pack\(storeService.ownedPackIDs.count == 1 ? "" : "s") restored."
            } else {
                restoreResult = "No purchases to restore on this Apple Account."
            }
        }
    }

    private static let supportAddress = "emotiveimpact@gmail.com"

    /// Gated on canOpenURL and on the open callback: the simulator, and any
    /// device with Mail removed or unconfigured, silently swallowed this.
    private func openSupportMail() {
        let subject = "Lumalook Support".addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? "Lumalook%20Support"
        guard let url = URL(string: "mailto:\(Self.supportAddress)?subject=\(subject)"),
              UIApplication.shared.canOpenURL(url) else {
            showSupportFallback = true
            return
        }
        UIApplication.shared.open(url) { opened in
            if !opened { showSupportFallback = true }
        }
    }

    // MARK: Export quality

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Default export resolution. Writes into the same stored ExportSpec the
    /// export sheets load, so the choice sticks everywhere (codec/fps
    /// untouched). Same pattern as every page pushed from You: quiet rows and
    /// a white tick, no colour.
    private var exportQualitySheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Export quality")
                    .font(.luma(size: 19, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(LumaTheme.textPrimary)
                    .padding(.bottom, 4)
                Text("The default for every export. You can still change it for one export on the export sheet.")
                    .font(.luma(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                SettingsRowGroup {
                    ForEach(Self.resolutionOrder, id: \.rawValue) { res in
                        if res != Self.resolutionOrder.first {
                            SettingsRowDivider(leading: 14)
                        }
                        resolutionRow(res)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
    }

    /// Smallest first, the way the mock lists them.
    private static let resolutionOrder: [ExportSpec.Resolution] = [.hd720, .hd1080, .uhd4K]

    private func resolutionRow(_ res: ExportSpec.Resolution) -> some View {
        let chosen = ExportSpec.from(rawValue: storedSpec).resolution == res
        return Button {
            var spec = ExportSpec.from(rawValue: storedSpec)
            spec.resolution = res
            storedSpec = spec.rawValue
            showExportQuality = false
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(res.rawValue)
                        .font(.luma(size: 15, weight: .medium))
                        .foregroundStyle(LumaTheme.textPrimary)
                    Text("\(Self.resolutionDetail(res)) · \(Self.pixelDimensions(res))")
                        .font(.luma(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LumaTheme.textPrimary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private static func resolutionDetail(_ res: ExportSpec.Resolution) -> String {
        switch res {
        case .hd720: return "Smallest files, quick to send"
        case .hd1080: return "Sharp on every phone"
        case .uhd4K: return "Full detail, the largest files"
        }
    }

    /// The 720p row previously reported "1920×1080" because the label was a
    /// two-way ternary over a three-case enum.
    private static func pixelDimensions(_ res: ExportSpec.Resolution) -> String {
        switch res {
        case .uhd4K:  return "3840×2160"
        case .hd1080: return "1920×1080"
        case .hd720:  return "1280×720"
        }
    }

    // MARK: About

    private var aboutSheet: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: "camera.filters")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(LumaTheme.textPrimary))
                .padding(.top, 30)
            Text("Lumalook")
                .font(.luma(size: 24, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(LumaTheme.textPrimary)
            // A version and a build are numbers.
            (wordText("Version ", 14, 0.62, weight: .semibold)
             + numText("\(Self.appVersion) (\(Self.appBuild))", 14, 0.82))
            Text("Cinematic looks, live LUT grading and video editing.\nMade by Emotive Impact.")
                .font(.luma(size: 14))
                .foregroundStyle(Color.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Button {
                // Straight to Mail: the no-mail fallback dialog lives on the
                // page under this sheet and could not show from here.
                let subject = "Lumalook Support".addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? "Lumalook%20Support"
                if let url = URL(string: "mailto:\(Self.supportAddress)?subject=\(subject)") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Email \(Self.supportAddress)", systemImage: "envelope")
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.lumaPress)
            .padding(.horizontal, 26)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// A group of quiet rows on one glass panel, no outline.
private struct SettingsRowGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The faint line between two rows, starting under the title.
private struct SettingsRowDivider: View {
    var leading: CGFloat = 46

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.055))
            .frame(height: 1)
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

// MARK: - Photo credits

/// The photographers behind the sample photos, with a link to each original.
/// Unsplash Licence: credit is not required, but it is the right thing to do.
struct PhotoCreditsSheet: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Photo credits")
                    .font(.luma(size: 22, weight: .bold))
                    .kerning(-0.6)
                    .foregroundStyle(LumaTheme.textPrimary)
                    .padding(.top, 26)
                Text("Sample photos are from Unsplash, used under the Unsplash Licence.")
                    .font(.luma(size: 14))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                ForEach(HeroPhoto.allCases, id: \.self) { photo in
                    Button {
                        if let url = photo.sourceURL { openURL(url) }
                    } label: {
                        HStack(spacing: 12) {
                            HeroImage(photo: photo, radius: 9)
                                .frame(width: 44, height: 44)
                            Text(photo.photographer)
                                .font(.luma(size: 15, weight: .medium))
                                .foregroundStyle(LumaTheme.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LumaTheme.textMuted)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.lumaPress)
                    .accessibilityLabel("Photo by \(photo.photographer), opens Unsplash")
                    Rectangle().fill(LumaTheme.hairline).frame(height: 1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }
}

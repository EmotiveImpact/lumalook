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

/// The pack name as a light part and a coloured heavy part. A trailing set
/// number stays with the word before it, so "Cine Print Set 01" sets as
/// "Cine Print" and "Set 01", "Negative Archive" as "Negative" and "Archive".
private func storeTitleParts(_ pack: LookPack) -> (light: String, heavy: String) {
    let words = pack.name.split(separator: " ").map(String.init)
    if words.count > 2, let last = words.last, last.allSatisfy(\.isNumber) {
        return (words.dropLast(2).joined(separator: " "),
                words.suffix(2).joined(separator: " "))
    }
    return pack.titleParts
}

/// "Inspired by Hollywood release prints." → "inspired by Hollywood release
/// prints", for the tail of a "5 looks · …" line. The app's name keeps its
/// capital, and a closing full stop goes.
private func storeSentenceTail(_ text: String) -> String {
    let trimmed = text.hasSuffix(".") ? String(text.dropLast()) : text
    guard let first = trimmed.first, !trimmed.hasPrefix("Lumalook") else { return trimmed }
    return first.lowercased() + String(trimmed.dropFirst())
}

/// The one price style on every cover (calm mock v2): Free, a price or In
/// library in the same small glass tag. A paid price takes the pack's own
/// colour (or white with the pack's dot when names are set to Dot and code);
/// everything else stays white.
struct PackStatePill: View {
    let pack: LookPack
    let installed: Bool
    /// The formatted StoreKit price. Only rendered for a paid pack.
    let price: String

    var body: some View {
        content
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color(hex: 0x0A0B0D).opacity(0.5), in: Capsule())
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if installed {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                Text("In library")
                    .font(.luma(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
        } else if pack.isFree {
            Text("Free")
                .font(.luma(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        } else if pack.isProIncluded {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LumaTheme.signal)
                Text("Pro")
                    .font(.luma(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        } else {
            LookNameText(price, colour: pack.colour, size: 11.5, weight: .semibold)
        }
    }
}

/// A quiet glass pill (Preview free, Try on your clip): white at 11%, white
/// words, no outline.
private struct StoreGlassPill: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
            LumaHaptics.shared.tap()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.luma(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.leading, 12)
            .padding(.trailing, 15)
            .frame(height: 38)
            .background(Color.white.opacity(0.11), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .fixedSize()
    }
}

/// A text tab: the word, white when picked with a short white bar under it,
/// grey otherwise. An optional count sits after the word in a fainter grey.
private struct StoreTextTab: View {
    let title: String
    var count: Int? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.luma(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(isOn ? 1 : 0.42))
                    if let count {
                        Text("\(count)")
                            .font(.luma(size: 14.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                Capsule()
                    .fill(isOn ? Color.white : Color.clear)
                    .frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A picture faded into the page, the same way the Projects hero is: dimmed,
/// a little less saturated, and run into ink at the bottom.
private struct StoreFadedBackdrop<Picture: View>: View {
    let height: CGFloat
    @ViewBuilder let picture: () -> Picture

    var body: some View {
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
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
    }
}

// MARK: - 09 Filter Store

/// The Store, calm (mock v2): the featured pack as a faded hero with its Buy
/// button in the pack's own colour, text tabs for the categories, one quiet
/// progress line, then every pack as a cover in a two-column grid, its name
/// in its own colour and its price in one small glass tag.
struct FilterStoreView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @StateObject private var thumbs = PackThumbs()
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue
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

    /// Browsing something narrower than the whole catalog.
    private var isFiltered: Bool { isSearchActive || category != .all }

    /// The flagship recipe pack — looked up by id so catalog growth can't
    /// silently re-point the hero at a different pack.
    private var featured: LookPack {
        PackCatalog.pack(id: "cine-print-set-01") ?? PackCatalog.packs[0]
    }

    /// The pack the hero is currently showing: the featured pack while
    /// browsing, the first result while filtering or searching — so the image
    /// on top always belongs to what is under it.
    private var heroPack: LookPack {
        if isFiltered {
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

    private var ownedLookCount: Int {
        PackCatalog.packs.reduce(0) { $0 + (app.packStore.isInstalled($1) ? $1.looks.count : 0) }
    }

    private var ownedPackCount: Int {
        PackCatalog.packs.filter { app.packStore.isInstalled($0) }.count
    }

    /// A name's colour for the current Names choice.
    private func nameColour(_ colour: Color, quiet: Color = LumaTheme.textPrimary) -> Color {
        (LumaNameStyle(rawValue: namesRaw) ?? .colour) == .colour ? colour : quiet
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            ZStack(alignment: .top) {
                LumaTheme.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroBlock(safeTop: safeTop)
                        categoryTabs
                        progressRow
                            .padding(.top, 12)
                        if searching {
                            searchField
                                .padding(.top, 10)
                        }
                        grid
                            .padding(.top, 12)
                        disclaimer
                        Color.clear.frame(height: isRoot ? 130 : 40)
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
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searching)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")") {
            thumbs.render(packs: PackCatalog.packs, source: app.previewFrame, maxDimension: 640)
        }
        .onAppear {
            // A seeded category the catalog cannot fill has no place on the
            // tabs, and the tabs would then name a different category than
            // the grid is filtered by.
            if !activeCategories.contains(category) { category = .all }
        }
    }

    // MARK: Top row

    /// On the tab: Store, then Pro and You. Pushed from elsewhere: the way
    /// back and the title.
    private var header: some View {
        Group {
            if isRoot {
                LumaTopBar(title: LumaTab.store.title)
            } else {
                LumaTabHeader {
                    HStack(spacing: 2) {
                        BackArrow()
                            .accessibilityLabel("Back")
                        LumaTabTitle(text: LumaTab.store.title)
                    }
                } trailing: {
                    EmptyView()
                }
            }
        }
        .padding(.top, LumaTabMetrics.top)
        .padding(.bottom, 2)
    }

    // MARK: Hero — the featured pack, faded into the page

    private func heroBlock(safeTop: CGFloat) -> some View {
        let pack = heroPack
        let parts = storeTitleParts(pack)
        return VStack(alignment: .leading, spacing: 0) {
            Text(isFiltered ? "FIRST RESULT" : "FEATURED PACK")
                .font(.luma(size: 11, weight: .bold))
                .kerning(1.3)
                .foregroundStyle(nameColour(pack.colour, quiet: Color.white.opacity(0.55)))
            LumaHeadline(light: parts.light, heavy: parts.heavy, size: 31,
                         heavyColor: nameColour(pack.colour))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 6)
            Text("\(pack.looks.count) looks · \(storeSentenceTail(pack.eraTag))")
                .font(.luma(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .padding(.top, 6)
            heroPills(pack)
                .padding(.top, 18)
        }
        .padding(.top, safeTop + 88)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .background(alignment: .top) {
            StoreFadedBackdrop(height: safeTop + 298) {
                packArt(pack)
            }
            .onTapGesture {
                StoreNav.open(pack, installed: app.packStore.isInstalled(pack), app: app)
            }
        }
    }

    /// Buy in the pack's own colour, and Preview free in quiet glass.
    private func heroPills(_ pack: LookPack) -> some View {
        let installed = app.packStore.isInstalled(pack)
        return HStack(spacing: 8) {
            LumaColourButton(title: heroBuyTitle(pack, installed: installed),
                             colour: pack.colour, height: 38) {
                heroBuy(pack)
            }
            .disabled(storeService.purchaseInFlight)
            if !installed {
                StoreGlassPill(title: "Preview free", icon: "wand.and.stars") {
                    StoreNav.open(pack, installed: false, app: app)
                }
            }
        }
    }

    private func heroBuyTitle(_ pack: LookPack, installed: Bool) -> String {
        if installed { return "In library · Open" }
        if storeService.purchaseInFlight { return "Buying" }
        if storeService.ownsPack(pack.id) { return pack.isFree ? "Install free" : "Install" }
        if pack.isProIncluded { return "Unlock with Pro" }
        return "Buy · \(StoreNav.price(pack, storeService))"
    }

    /// A paid pack buys right here through StoreKit, exactly as the pack
    /// page does, and installs once the purchase goes through. A pack you
    /// already own (free, bought or with Pro) installs straight away, as its
    /// "Install" label says. Everything else (Pro only, or no product from
    /// the App Store yet) opens the pack page, where the full story is; an
    /// installed pack opens the library.
    private func heroBuy(_ pack: LookPack) {
        let installed = app.packStore.isInstalled(pack)
        if !installed, storeService.ownsPack(pack.id) {
            if StoreNav.install(pack, app: app) > 0 {
                LumaHaptics.shared.tap()
            } else {
                StoreNav.open(pack, installed: false, app: app)
            }
            return
        }
        guard !installed, !pack.isProIncluded,
              let product = storeService.packProducts[pack.id] else {
            StoreNav.open(pack, installed: installed, app: app)
            return
        }
        Task { @MainActor in
            if await storeService.purchase(product) {
                StoreNav.install(pack, app: app)
            }
        }
    }

    /// A pack's cover: its graded frame once rendered, its photo until then.
    @ViewBuilder
    private func packArt(_ pack: LookPack) -> some View {
        let photo = PackThumbs.previewPhoto(for: pack)
        if let cg = thumbs.images[pack.id] {
            GeometryReader { geo in
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height,
                           alignment: photo.cropAlignment)
                    .clipped()
            }
        } else {
            HeroImage(photo: photo, radius: 0)
        }
    }

    // MARK: Tabs and the progress line

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(activeCategories) { item in
                    StoreTextTab(title: item.title,
                                 count: item == .all ? PackCatalog.packs.count : nil,
                                 isOn: category == item) {
                        guard category != item else { return }
                        withAnimation(.snappy(duration: 0.22)) { category = item }
                        LumaHaptics.shared.tap()
                    }
                    .accessibilityLabel("\(item.title), \(PackCatalog.packs.filter(item.contains).count) packs")
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 4)
    }

    /// How many looks are yours and how many packs are free to start; while
    /// narrowed, how many packs are showing. Search and restore sit at its
    /// end as two quiet glass buttons.
    private var progressText: String {
        if searching || category != .all {
            return "\(visiblePacks.count) of \(PackCatalog.packs.count) packs"
        }
        let looks = "\(ownedLookCount) of \(PackCatalog.totalLookCount) looks yours"
        if ownedPackCount == 0 {
            let free = PackCatalog.packs.filter(\.isFree).count
            return "\(looks) · \(free) free \(free == 1 ? "pack" : "packs") to start"
        }
        return "\(looks) · \(ownedPackCount) of \(PackCatalog.packs.count) packs"
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            Text(progressText)
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    searching.toggle()
                    if !searching { query = "" }
                }
                searchFocused = searching
                LumaHaptics.shared.tap()
            } label: {
                quietCircle(searching ? "xmark" : "magnifyingglass")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searching ? "Close search" : "Search the store")
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
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.1), in: Circle())
                    } else {
                        quietCircle("arrow.clockwise")
                    }
                }
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restore purchases")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
    }

    private func quietCircle(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.1), in: Circle())
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
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
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    // MARK: The catalog — two columns of covers

    @ViewBuilder
    private var grid: some View {
        if visiblePacks.isEmpty {
            Text(needle.isEmpty
                 ? "No packs in this category yet."
                 : "No packs or looks match “\(query)”.")
                .font(.luma(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .padding(.horizontal, 20)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(visiblePacks) { pack in
                    tile(pack)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    /// The pack's cover with its name in its own colour, its count and kind
    /// under it, and the one glass price tag in the corner.
    private func tile(_ pack: LookPack) -> some View {
        let installed = app.packStore.isInstalled(pack)
        let price = StoreNav.price(pack, storeService)
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return Button {
            StoreNav.open(pack, installed: installed, app: app)
        } label: {
            packArt(pack)
                .frame(maxWidth: .infinity)
                .frame(height: 232)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                        .allowsHitTesting(false)
                }
                .background(Color(white: 0.07))
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        LookNameText(pack.name, colour: pack.colour, size: 14, weight: .semibold)
                        Text("\(pack.looks.count) looks · \(storeSentenceTail(pack.eraTag))")
                            .font(.luma(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .topTrailing) {
                    PackStatePill(pack: pack, installed: installed, price: price)
                        .padding(9)
                }
                .contentShape(shape)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(pack.name), \(pack.looks.count) looks, \(installed ? "In library" : price)")
    }

    private var disclaimer: some View {
        Text(MockData.namingDisclaimer)
            .font(.luma(size: 11.5))
            .foregroundStyle(.white.opacity(0.42))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.top, 22)
    }
}

/// Store → rest-of-app navigation, shared by the grid, the hero and the
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

    /// Bakes the pack into the library and says where the looks landed.
    /// Returns how many looks were added (0 if it was already installed).
    @discardableResult
    static func install(_ pack: LookPack, app: AppModel) -> Int {
        guard !app.packStore.isInstalled(pack) else { return 0 }
        let count = PackInstaller.install(pack, into: app.lutRepository)
        if count > 0 {
            app.packStore.markInstalled(pack)
            // Post-install confirmation: tells the user where the looks
            // landed instead of leaving them to hunt.
            app.importToast = "\(pack.name) installed, \(count) looks in your library"
        }
        return count
    }
}


struct BackArrow: View {
    @Environment(\.dismiss) private var dismiss
    /// Over photography the bare glyph can land on near-white sky, so the
    /// media placements get the mockup's circular glass chip behind it.
    /// Chrome placements keep the naked glyph.
    var onMedia: Bool = false

    var body: some View {
        Button { dismiss() } label: {
            if onMedia {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color(hex: 0x101114).opacity(0.58), in: Circle())
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

/// The pack page, calm (mock v2): the cover faded into the page and graded
/// in the look you are previewing; the kicker, the name's heavy word and the
/// Buy pack button in the pack's own colour; text tabs; then the looks nine
/// at a glance, each with its code in its own colour. The picked look keeps
/// the pale ring. Pro is one quiet line with its spark at the foot.
struct FilterPackDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue
    /// Look tile faces, keyed by look code.
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
    @State private var tab: PackTab = .looks

    private enum PackTab: String, CaseIterable {
        case looks, about, data
    }

    /// Free, individually bought, or unlocked by Pro.
    private var unlocked: Bool { storeService.ownsPack(pack.id) }

    private var pack: LookPack {
        app.selectedPackID.flatMap(PackCatalog.pack(id:)) ?? PackCatalog.packs[0]
    }

    private var installed: Bool { app.packStore.isInstalled(pack) }

    private var activeLook: PackLook {
        pack.looks.first { $0.code == selectedCode } ?? pack.looks[0]
    }

    /// The cover photo: the same one the pack's store cover and Looks tab
    /// cover use, so tapping a cover never swaps the people out from under you.
    private var heroPhoto: HeroPhoto { PackThumbs.previewPhoto(for: pack) }

    private var heroSource: CIImage {
        heroPhoto.ciImage ?? LookThumbs.fallbackFrame
    }

    /// One face per tile, each look on the photo that suits it, spread so
    /// neighbouring tiles never show the same person.
    private func rowPhoto(for look: PackLook) -> HeroPhoto {
        let photos = rowPhotos
        guard let index = pack.looks.firstIndex(where: { $0.code == look.code }),
              index < photos.count else { return heroPhoto }
        return photos[index]
    }

    private var rowPhotos: [HeroPhoto] {
        LookPhotos.spread(names: pack.looks.map(\.name), keys: pack.looks.map(\.code))
    }

    /// The pack's family, for the About tab.
    private var familyTitle: String {
        StoreCategory.allCases.first { $0 != .all && $0 != .free && $0.contains(pack) }?.title ?? "Pack"
    }

    /// Measured film stocks ship bundled film data; every other pack bakes
    /// its looks from recipes.
    private var isMeasured: Bool { pack.looks.contains { $0.cubeFile != nil } }

    /// What the pack technically is. A claim is a sentence, not a readout.
    private var techClaim: String {
        isMeasured ? "Measured film data" : "Baked 33-point cubes"
    }

    /// "PACK · MEASURED COLOUR NEGATIVE STOCKS", or "NEW PACK · …".
    private var kicker: String {
        "\(pack.isNew ? "NEW PACK" : "PACK") · \(pack.eraTag.uppercased())"
    }

    private var hasCurrentMedia: Bool {
        !app.editor.clips.isEmpty || app.selectedVideoURL != nil || app.selectedImage != nil
    }

    /// A name's colour for the current Names choice.
    private func nameColour(_ colour: Color, quiet: Color = LumaTheme.textPrimary) -> Color {
        (LumaNameStyle(rawValue: namesRaw) ?? .colour) == .colour ? colour : quiet
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        heroBlock(safeTop: safeTop, proxy: proxy)
                        tabBar
                        tabContent
                        Text(MockData.namingDisclaimer)
                            .font(.luma(size: 11.5))
                            .foregroundStyle(.white.opacity(0.42))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                            .padding(.bottom, 16)
                    }
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
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
            // LUMA_SEED_PACKTAB=looks|about|data opens a tab for screenshots.
            if let raw = ProcessInfo.processInfo.environment["LUMA_SEED_PACKTAB"],
               let seededTab = PackTab(rawValue: raw) {
                tab = seededTab
            }
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

    // MARK: Hero — the cover faded into the page, the name, the pills

    private func heroBlock(safeTop: CGFloat, proxy: ScrollViewProxy) -> some View {
        let parts = storeTitleParts(pack)
        return VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(.luma(size: 11, weight: .bold))
                .kerning(1.3)
                .foregroundStyle(nameColour(pack.colour, quiet: Color.white.opacity(0.55)))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            LumaHeadline(light: parts.light, heavy: parts.heavy, size: 31,
                         heavyColor: nameColour(pack.colour))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 6)
            Text("\(pack.looks.count) looks · \(storeSentenceTail(pack.familyLine))")
                .font(.luma(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack(spacing: 8) {
                LumaColourButton(title: primaryTitle, colour: pack.colour, height: 38) {
                    primaryAction()
                }
                .disabled(storeService.purchaseInFlight || installing)
                secondaryPill(proxy: proxy)
            }
            .padding(.top, 18)
        }
        .padding(.top, safeTop + 70)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .background(alignment: .top) {
            StoreFadedBackdrop(height: safeTop + 268) {
                coverArt
            }
        }
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

    /// Back on the left, share on the right, both round glass so they hold
    /// up over any cover.
    private var topBar: some View {
        HStack {
            BackArrow(onMedia: true)
                .accessibilityLabel("Back")
            Spacer()
            ShareLink(item: Self.siteURL,
                      subject: Text(pack.name),
                      message: Text("\(pack.name) on Lumalook: \(pack.looks.count) looks.")) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color(hex: 0x101114).opacity(0.58), in: Circle())
            }
            .accessibilityLabel("Share pack")
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private static let siteURL = URL(string: "https://lumalook.app")!

    // MARK: The pills — Buy pack in the pack's colour, and one glass pill

    private var primaryTitle: String {
        if installing { return "Installing" }
        if storeService.purchaseInFlight { return "Buying" }
        if installed { return "In library · Open" }
        if unlocked { return pack.isFree ? "Install free" : "Install" }
        if pack.isProIncluded { return "Unlock with Pro" }
        return "Buy pack · \(StoreNav.price(pack, storeService))"
    }

    private func primaryAction() {
        if installed {
            StoreNav.openInLibrary(pack, app: app)
        } else {
            buyOrInstall()
        }
    }

    /// Installed with media open: grade it now. Otherwise, with footage of
    /// your own: jump to the look previewed on it.
    @ViewBuilder
    private func secondaryPill(proxy: ScrollViewProxy) -> some View {
        if installed, hasCurrentMedia {
            StoreGlassPill(title: "Grade your media", icon: "wand.and.stars") {
                if !app.editor.clips.isEmpty {
                    app.path = [.editor]
                } else {
                    app.path.append(.applyLook)
                }
            }
        } else if tryOnIsUserMedia {
            StoreGlassPill(title: "Try on your clip", icon: "wand.and.stars") {
                tab = .looks
                // The panel lives on the Looks tab: let it appear first.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(Self.tryOnID, anchor: .center)
                    }
                }
            }
        }
    }

    private static let tryOnID = "pack-try-on"

    // MARK: Tabs

    private func tabTitle(_ item: PackTab) -> String {
        switch item {
        case .looks: return "Looks"
        case .about: return "About"
        case .data:  return isMeasured ? "Film data" : "Look notes"
        }
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(PackTab.allCases, id: \.self) { item in
                StoreTextTab(title: tabTitle(item),
                             count: item == .looks ? pack.looks.count : nil,
                             isOn: tab == item) {
                    guard tab != item else { return }
                    tab = item
                    LumaHaptics.shared.tap()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .looks: looksTab
        case .about: aboutTab
        case .data:  notesTab
        }
    }

    // MARK: Looks — nine at a glance

    private var looksTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tryOnIsUserMedia ? "Tap a look to preview it on your last clip"
                                  : "Tap a look to preview it")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if tryOnIsUserMedia {
                tryOnPanel
                    .id(Self.tryOnID)
                    .padding(.top, 12)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      alignment: .leading, spacing: 14) {
                ForEach(pack.looks) { look in
                    lookTile(look)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func lookTile(_ look: PackLook) -> some View {
        let active = look.code == activeLook.code
        return Button {
            selectedCode = look.code
            LumaHaptics.shared.tap()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                lookFace(look, active: active)
                LookNameText(look.code, colour: look.signature, size: 12.5, weight: .bold)
                    .padding(.top, 7)
                Text(look.title)
                    .font(.luma(size: 11.5, weight: .medium))
                    .foregroundStyle(active ? Color.white.opacity(0.7) : LumaTheme.textMuted)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(look.title), \(look.code)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func lookFace(_ look: PackLook, active: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Color.clear
            .aspectRatio(0.8, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let cg = previews[look.code] {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    // The person shows straight away; the grade fades in
                    // over them once it is ready (a slow phone can take a
                    // moment for twenty looks), so a tile is never an empty box.
                    HeroImage(photo: rowPhoto(for: look), radius: 0)
                        .opacity(0.7)
                }
            }
            .animation(.easeOut(duration: 0.2), value: previews[look.code] != nil)
            .clipShape(shape)
            // clipShape clips pixels, not touches: confine the face.
            .contentShape(shape)
            .pickedRing(active, cornerRadius: 13)
    }

    /// Only when there is footage of the user's own: the tiles already show
    /// every look on a face.
    private var tryOnPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(height: 150)
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
            HStack(spacing: 6) {
                Text("Your last clip ·")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                LookNameText(activeLook.code, colour: activeLook.signature, size: 13, weight: .semibold)
            }
            .lineLimit(1)
        }
    }

    // MARK: About — calm details

    private var priceWord: String {
        if installed { return "In library" }
        if unlocked { return pack.isFree ? "Free" : "Unlocked" }
        if pack.isProIncluded { return "With Pro" }
        return StoreNav.price(pack, storeService)
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pack.familyLine)
                .font(.luma(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            detailRow("Looks", "\(pack.looks.count)")
            detailRow("Family", familyTitle)
            detailRow("Made from", techClaim)
            detailRow("Price", priceWord)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.luma(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 8)
            Text(value)
                .font(.luma(size: 13.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: Film data / look notes — each look's code, name and character

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pack.looks) { look in
                Button {
                    selectedCode = look.code
                    LumaHaptics.shared.tap()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            LookNameText(look.code, colour: look.signature, size: 13, weight: .bold)
                            Text(look.title)
                                .font(.luma(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)
                        }
                        Text(look.character)
                            .font(.luma(size: 12.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(look.code == activeLook.code ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: Foot — the store logic in one line, and Pro with its spark

    private var footer: some View {
        VStack(spacing: 4) {
            Text(footnote)
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if !unlocked && !pack.isProIncluded {
                Button { showPaywall = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LumaTheme.signal)
                        Text("Or get every pack with Pro")
                            .font(.luma(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(stops: [
                .init(color: LumaTheme.ink.opacity(0), location: 0),
                .init(color: LumaTheme.ink.opacity(0.94), location: 0.5),
                .init(color: LumaTheme.ink, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
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

    // MARK: Actions

    private func performInstall() {
        guard !app.packStore.isInstalled(pack), !installing else { return }
        installing = true
        let target = pack
        Task { @MainActor in
            // Same install the Store hero uses after a purchase: bakes the
            // looks, marks the pack installed and shows where they landed.
            let count = StoreNav.install(target, app: app)
            installing = false
            if count > 0 {
                installedFlash += 1
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

    /// Each tile's face: its own photo, cropped 4:5 around the person and
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
                    frames[photo] = photo.posterFrame(aspect: 0.8, longest: 400)
                }
                guard let frame = frames[photo],
                      let cg = PackThumbs.grade(look, on: frame, maxDimension: 360) else { continue }
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

/// Settings in the shipping design language. There is no picture to lead with
/// here, so the language shows up as everything else: monochrome chrome, a
/// plain Title-Case header, sentence-case rows, and mono reserved strictly for
/// the numbers — the LUT count, the bytes on disk, the export resolution and
/// the version. Every legally-required row stays exactly where it was. The
/// subscription card leads: it is the one thing on this screen that earns.
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
    /// restore" — it has to say so, or the row reads as dead.
    @State private var restoring = false
    @State private var restoreResult: String?
    /// Shown when no mail client can take the mailto: — otherwise the only
    /// support path in the app dead-ends silently.
    @State private var showSupportFallback = false
    /// Same store the export spec sheet reads on appear — changing it here
    /// really changes the default the exporter uses.
    @AppStorage("lumalook.exportSpec") private var storedSpec = ExportSpec().rawValue

    var body: some View {
        ZStack {
            // The You tab sits on the page's ink like every other tab.
            (isRoot ? LumaTheme.background : Color.black).ignoresSafeArea()
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
                // Three 52pt rows plus the header measure ~271pt at default
                // type and more at larger sizes, so the sheet is medium and the
                // content scrolls rather than clipping the last resolution.
                .presentationDetents([.medium])
                .presentationBackground(Color.black)
        }
        .sheet(isPresented: $showAbout) {
            aboutSheet
                .presentationDetents([.medium])
                .presentationBackground(Color.black)
        }
        .sheet(isPresented: $showPhotoCredits) {
            PhotoCreditsSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(LumaTheme.ink)
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        // Every restore says what happened — success, nothing found, or error.
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreResult != nil },
            set: { if !$0 { restoreResult = nil } })) {
            Button("OK", role: .cancel) { restoreResult = nil }
        } message: {
            Text(restoreResult ?? "")
        }
        // Fallback when no mail client can take the mailto:.
        .confirmationDialog("Help & Support", isPresented: $showSupportFallback,
                            titleVisibility: .visible) {
            Button("Copy Email Address") {
                UIPasteboard.general.string = Self.supportAddress
            }
            Button("Done", role: .cancel) { }
        } message: {
            Text("No mail app is set up on this device. Email \(Self.supportAddress) from anywhere and we'll answer.")
        }
        // The row leaves the app, so it says so before it does.
        .confirmationDialog("App Language", isPresented: $showLanguageNotice,
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
        // Plain facts about what the LUT library costs on disk — no "clean up"
        // button, because every byte here is a look the user chose to keep and
        // deleting them belongs in LUT Manager where they can see what goes.
        .confirmationDialog("Storage", isPresented: $showStorageDetail,
                            titleVisibility: .visible) {
            Button("Manage Imported LUTs") { app.path.append(.lutManager) }
            Button("Done", role: .cancel) { }
        } message: {
            Text("\(app.lutRepository.luts.count) LUTs using \(lutStorageDescription) in Lumalook's documents folder. Removing a LUT frees its space immediately.")
        }
        .task {
            lutBytes = await Self.directorySize(of: app.lutRepository.lutFolderURL)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUMA_SEED_PAYWALL"] == "1" {
                showPaywall = true
            }
            #endif
        }
    }

    private var header: some View {
        ZStack {
            Text("Settings")
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            HStack {
                if !isRoot {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private var lutStorageDescription: String {
        ByteCountFormatter.string(fromByteCount: lutBytes, countStyle: .file)
    }

    /// Off the main actor — enumerating the LUT folder touches the filesystem.
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

    /// NATIVE inset-grouped List (Apple-native tranche 2).
    private var settingsList: some View {
        ScrollViewReader { proxy in
            settingsRows
                // The top bar's Pro badge, tapped while already here.
                .onReceive(NotificationCenter.default.publisher(for: .lumaShowPlan)) { _ in
                    withAnimation(.snappy(duration: 0.3)) {
                        proxy.scrollTo(Self.planRowID, anchor: .top)
                    }
                }
        }
    }

    private static let planRowID = "plan"

    private var settingsRows: some View {
        List {
            Section {
                subscriptionCard
                    .listRowBackground(LumaTheme.card)
                    .id(Self.planRowID)
            }

            Section("Purchases") {
                // Only shown when there is a subscription to manage — while
                // free, "Get Pro" in the card above is the single purchase CTA
                // and a second row to the same paywall is just a decoy.
                if storeService.isPro {
                    settingsRow(icon: "creditcard", title: "Manage Subscription",
                                value: "Pro") {
                        showManageSubscriptions = true
                    }
                }
                settingsRow(icon: "arrow.clockwise", title: "Restore Purchases",
                            busy: restoring, showsAffordance: false) {
                    performRestore()
                }
                .disabled(restoring)
            }
            .listRowBackground(LumaTheme.card)

            Section("Preferences") {
                // A resolution is a size, and a size is a number.
                settingsRow(icon: "4k.tv", title: "Export Quality",
                            value: ExportSpec.from(rawValue: storedSpec).resolution.rawValue,
                            valueIsNumber: true) {
                    showExportQuality = true
                }
                settingsRow(icon: "globe", title: "App Language",
                            value: Locale.current.localizedString(
                                forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")
                                ?? "English",
                            opensExternally: true) {
                    // Per-app language lives in iOS Settings — confirm first,
                    // because unlike Export Quality above this leaves the app.
                    showLanguageNotice = true
                }
            }
            .listRowBackground(LumaTheme.card)

            Section("Storage") {
                // LUTManagerView already exists but had no route from here.
                settingsRow(icon: "square.stack.3d.down.right",
                            title: "Imported LUTs",
                            value: "\(app.lutRepository.luts.count)",
                            valueIsNumber: true) {
                    app.path.append(.lutManager)
                }
                settingsRow(icon: "internaldrive", title: "Storage Used",
                            value: lutStorageDescription,
                            valueIsNumber: true) {
                    showStorageDetail = true
                }
            }
            .listRowBackground(LumaTheme.card)

            Section("About") {
                settingsRow(icon: "questionmark.circle", title: "Help & Support",
                            opensExternally: true) {
                    openSupportMail()
                }
                settingsRow(icon: "star", title: "Rate Lumalook",
                            opensExternally: true) {
                    requestReview()
                }
                // Auto-renewable subscriptions must expose both of these on a
                // reachable surface — they are also linked from the paywall.
                settingsRow(icon: "hand.raised", title: "Privacy Policy",
                            opensExternally: true) {
                    LumaLegal.open(LumaLegal.privacy)
                }
                settingsRow(icon: "doc.text", title: "Terms of Use",
                            opensExternally: true) {
                    LumaLegal.open(LumaLegal.terms)
                }
                settingsRow(icon: "photo.on.rectangle", title: "Photo credits") {
                    showPhotoCredits = true
                }
                settingsRow(icon: "info.circle", title: "About Lumalook",
                            value: "v\(Self.appVersion)", valueIsNumber: true) {
                    showAbout = true
                }
            }
            .listRowBackground(LumaTheme.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // insetGrouped ships with ~35pt between sections and a deep inset above
        // the first one. Stacked under the header padding that left a hand's
        // width of empty black under the title and made five short sections
        // span two screens. 18pt reads as a deliberate group gap.
        .listSectionSpacing(18)
        .contentMargins(.top, 2, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 52)
    }

    /// `opensExternally` swaps the chevron for the system "leaves the app"
    /// glyph, so a row that ejects to iOS Settings never wears the same
    /// affordance as one that opens an in-app sheet.
    /// `showsAffordance: false` is for rows that perform work in place rather
    /// than pushing or ejecting — a chevron there promises navigation that
    /// never happens. `busy` swaps the trailing slot for a spinner.
    /// `valueIsNumber` puts the trailing value in the instrument face; words
    /// like "English" or "Pro" stay in the reading face.
    private func settingsRow(icon: String, title: String, value: String? = nil,
                             valueIsNumber: Bool = false,
                             opensExternally: Bool = false,
                             busy: Bool = false,
                             showsAffordance: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 28)
                Text(title)
                    .font(.luma(size: 16))
                    .foregroundStyle(.white)
                Spacer()
                if let value {
                    Text(value)
                        .font(.luma(size: 15, weight: .medium,
                                      design: valueIsNumber ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.6))
                } else if showsAffordance {
                    Image(systemName: opensExternally ? "arrow.up.forward.app" : "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .buttonStyle(.plain)
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

    /// Default export resolution — writes into the same stored ExportSpec the
    /// export sheets load, so the choice sticks everywhere (codec/fps untouched).
    private var exportQualitySheet: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export quality")
                .font(.luma(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 2)
            Text("Default resolution for every export. You can still change it per-export on the export sheet.")
                .font(.luma(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.bottom, 10)
            ForEach(ExportSpec.Resolution.allCases, id: \.rawValue) { res in
                let chosen = ExportSpec.from(rawValue: storedSpec).resolution == res
                Button {
                    var spec = ExportSpec.from(rawValue: storedSpec)
                    spec.resolution = res
                    storedSpec = spec.rawValue
                    showExportQuality = false
                } label: {
                    HStack(spacing: 10) {
                        // A resolution and its pixel dimensions are both
                        // numbers, so both keep the instrument voice.
                        Text(res.rawValue)
                            .font(.luma(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(Self.pixelDimensions(res))
                            .font(.luma(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if chosen {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(Color(white: chosen ? 0.16 : 0.10),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 24)
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
                .fill(Color(white: 0.13))
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: "camera.filters")
                    .font(.luma(size: 34, weight: .medium))
                    .foregroundStyle(.white))
                .padding(.top, 30)
            Text("Lumalook")
                .font(.luma(size: 24, weight: .bold))
                .foregroundStyle(.white)
            // A version and a build are numbers.
            (wordText("Version ", 14, 0.62, weight: .semibold)
             + numText("\(Self.appVersion) (\(Self.appBuild))", 14, 0.82))
            Text("Cinematic looks, live LUT grading and video editing.\nMade by Emotive Impact.")
                .font(.luma(size: 14))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Button {
                let subject = "Lumalook Support".addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? "Lumalook%20Support"
                if let url = URL(string: "mailto:emotiveimpact@gmail.com?subject=\(subject)") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Contact — emotiveimpact@gmail.com", systemImage: "envelope")
                    .font(.luma(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color(white: 0.13),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 26)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var subscriptionCard: some View {
        // Profile / subscription card — live StoreKit 2 status (C5). No hue:
        // Pro reads as full white, Free as grey, and the door to the paywall
        // is a surface step rather than a filled violet button.
        HStack(spacing: 14) {
            Circle()
                .fill(Color(white: 0.16))
                .frame(width: 58, height: 58)
                .overlay(Image(systemName: storeService.isPro ? "crown.fill" : "person.fill")
                    .font(.luma(size: storeService.isPro ? 22 : 26))
                    .foregroundStyle(.white.opacity(0.85)))
            VStack(alignment: .leading, spacing: 4) {
                Text(storeService.isPro ? "Lumalook Pro" : "Lumalook Free")
                    .font(.luma(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(storeService.isPro ? "Unlimited access" : "Upgrade for every look")
                    .font(.luma(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(storeService.isPro ? 0.8 : 0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)
            Spacer()
            Button {
                showPaywall = true
            } label: {
                Text(storeService.isPro ? "Manage" : "Get Pro")
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Color(white: 0.20), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
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

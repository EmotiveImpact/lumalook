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
        let jobs: [(String, PackLook, CIImage)] = packs.compactMap { pack in
            guard let look = pack.looks.first else { return nil }
            let frame = source ?? PackThumbs.previewPhoto(for: pack).ciImage
                ?? LookThumbs.fallbackFrame
            return (pack.id, look, frame)
        }
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            for (packID, look, frame) in jobs {
                if Task.isCancelled { return }
                guard let cg = PackThumbs.grade(look, on: frame,
                                                maxDimension: maxDimension) else { continue }
                await MainActor.run { self?.images[packID] = cg }
            }
        }
    }

    /// Photos in catalog order. The catalog assigns only five `HeroPhoto`
    /// values across ten packs and repeats them non-adjacently-safely, so the
    /// store derives its own rotation from the pack's position instead: with
    /// five photos walked in sequence no two neighbouring rows can collide.
    /// The pack-detail hero calls this too, so a tile and its detail screen
    /// always show the same source frame.
    static let previewPhotos: [HeroPhoto] = [.golden, .coast, .desert, .night, .neon]

    static func previewPhoto(for pack: LookPack) -> HeroPhoto {
        guard let idx = PackCatalog.packs.firstIndex(where: { $0.id == pack.id })
        else { return pack.photo }
        return previewPhotos[idx % previewPhotos.count]
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

/// The one place the store says "owned". Four states, each visually distinct
/// so the pill is never ambiguous: teal outlined "✓ In Library", a neutral
/// "Free" chip, an accent-outlined "♛ Pro" BADGE for subscription-included
/// packs, and a solid accent capsule reserved exclusively for real money.
/// Used by the rows and the featured banner so a pack never reads two
/// different states on one screen.
struct PackStatePill: View {
    let pack: LookPack
    let installed: Bool
    /// The formatted StoreKit price. Only rendered in the `.buy` state.
    let price: String

    private enum State { case inLibrary, free, proIncluded, buy }

    private var state: State {
        if installed { return .inLibrary }
        if pack.isFree { return .free }
        if pack.isProIncluded { return .proIncluded }
        return .buy
    }

    var body: some View {
        switch state {
        case .inLibrary:
            Label("In Library", systemImage: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LumaTheme.teal)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(LumaTheme.teal.opacity(0.20), in: Capsule())
        case .free:
            Text("Free")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(LumaTheme.surfaceStrong, in: Capsule())
        case .proIncluded:
            // A badge, not a buy button: tinted rather than solid-filled, so
            // it cannot be mistaken for a price. The tint alone does that job —
            // it does not need a ring as well.
            Label("Pro", systemImage: "crown.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LumaTheme.accentBright)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(LumaTheme.accent.opacity(0.24), in: Capsule())
        case .buy:
            Text(price)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(LumaTheme.accent, in: Capsule())
        }
    }
}

// MARK: - 09 Filter Store

struct FilterStoreView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
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
    @FocusState private var searchFocused: Bool

    private var isSearchActive: Bool {
        searching && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The flagship recipe pack — looked up by id so catalog growth can't
    /// silently re-point the banner at a different pack.
    private var featured: LookPack {
        PackCatalog.pack(id: "cine-print-set-01") ?? PackCatalog.packs[0]
    }

    /// Category first, then the free-text query across everything the user
    /// could plausibly remember: the pack, its era tag, and the name or code
    /// of any look inside it — 118 looks are not findable by scrolling.
    private var visiblePacks: [LookPack] {
        let byCategory = PackCatalog.packs.filter { category.contains($0) }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
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

    /// Chips only appear when the catalog actually has something in them.
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

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if searching { searchField }
                chips
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // The banner is a browsing surface; while searching the
                        // results are the only thing that matters.
                        if category == .all && !isSearchActive {
                            SectionHeader(title: "Featured Pack")
                            featuredBanner
                        }

                        SectionHeader(title: isSearchActive
                                      ? "\(visiblePacks.count) Result\(visiblePacks.count == 1 ? "" : "s")"
                                      : category == .all ? "All Packs"
                                                         : "\(category.title) Packs")

                        VStack(spacing: 10) {
                            ForEach(visiblePacks) { pack in
                                StoreRow(pack: pack, thumbnail: thumbs.images[pack.id])
                            }
                        }

                        if visiblePacks.isEmpty {
                            Text(isSearchActive
                                 ? "No packs or looks match \"\(query)\"."
                                 : "No packs in this category yet.")
                                .font(.system(size: 14))
                                .foregroundStyle(LumaTheme.textMuted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 40)
                        }

                        Text(MockData.namingDisclaimer)
                            .font(.system(size: 11))
                            .foregroundStyle(LumaTheme.textMuted)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 36)
                }
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")") {
            thumbs.render(packs: PackCatalog.packs, source: app.previewFrame)
        }
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text("LOOK STORE")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(.white)
                // Ties the store to the collection: the count the user grows.
                TechReadout("\(ownedLookCount) OWNED OF \(PackCatalog.totalLookCount) · \(ownedPackCount)/\(PackCatalog.packs.count) PACKS",
                            size: 10, color: LumaTheme.textMuted)
            }
            HStack {
                if !isRoot {
                    BackArrow()
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        searching.toggle()
                        if !searching { query = "" }
                    }
                    searchFocused = searching
                    LumaHaptics.shared.tap()
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(searching ? LumaTheme.accentBright : .white)
                        .frame(width: 40, height: 40, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(searching ? "Close search" : "Search the store")
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LumaTheme.textMuted)
            TextField("Search packs and looks", text: $query)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(LumaTheme.accentBright)
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
                        .font(.system(size: 15))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(LumaTheme.chip, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeCategories) { cat in
                    let count = PackCatalog.packs.filter(cat.contains).count
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            category = cat
                        }
                        LumaHaptics.shared.tap()
                    } label: {
                        HStack(spacing: 6) {
                            Text(cat.title)
                                .font(.system(size: 13,
                                              weight: category == cat ? .semibold : .regular))
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(category == cat ? .white.opacity(0.85)
                                                                 : LumaTheme.textMuted)
                        }
                        .foregroundStyle(category == cat ? .white : LumaTheme.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background {
                            if category == cat {
                                Capsule().fill(LumaTheme.accent)
                            } else {
                                Capsule().fill(LumaTheme.chip)
                            }
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.horizontal, 20)
        }
        .lumaEdgeFade()
    }

    private var featuredBanner: some View {
        let installed = app.packStore.isInstalled(featured)
        return Button {
            StoreNav.open(featured, installed: installed, app: app)
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let cg = thumbs.images[featured.id] {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        HeroImage(photo: PackThumbs.previewPhoto(for: featured))
                    }
                }
                .frame(height: 158)
                .frame(maxWidth: .infinity)
                .clipped()
                // Featured card is a Button — keep its touch region on the
                // artwork rather than the overflowing scaledToFill bleed.
                .contentShape(Rectangle())
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.78)],
                                        startPoint: .center, endPoint: .bottom))

                VStack(alignment: .leading, spacing: 3) {
                    TechReadout("FEATURED PACK", size: 9, color: LumaTheme.accentBright)
                    Text(featured.name)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(.white)
                    Text("\(featured.looks.count) looks · \(featured.looks.prefix(2).map(\.code).joined(separator: " · ")) · more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .padding(.leading, 16)
                .padding(.bottom, 14)

                HStack {
                    Spacer()
                    PackStatePill(pack: featured, installed: installed,
                                  price: StoreNav.price(featured, storeService))
                }
                .padding(.trailing, 14)
                .padding(.bottom, 14)
            }
            .frame(height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.lumaPress)
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

private struct StoreRow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    let pack: LookPack
    let thumbnail: CGImage?

    var body: some View {
        let installed = app.packStore.isInstalled(pack)
        Button {
            StoreNav.open(pack, installed: installed, app: app)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let thumbnail {
                        GradedThumb(image: thumbnail,
                                    size: CGSize(width: 56, height: 56), radius: 12)
                    } else {
                        HeroImage(photo: PackThumbs.previewPhoto(for: pack), radius: 12)
                            .frame(width: 56, height: 56)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(pack.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(pack.looks.count) looks · \(pack.eraTag)")
                        .font(.system(size: 11))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                PackStatePill(pack: pack, installed: installed,
                              price: StoreNav.price(pack, storeService))
            }
            .padding(10)
            .background(LumaTheme.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.lumaPress)
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
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
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
/// Settings ABOUT rows can never drift apart. Both are overridable from
/// Info.plist (`LLPrivacyPolicyURL` / `LLTermsOfUseURL`) — set those to the
/// real hosted documents before submission; `terms` otherwise falls back to
/// Apple's standard EULA, which is the default agreement for apps that do not
/// supply their own.
enum LumaLegal {
    static let privacy = url(forInfoKey: "LLPrivacyPolicyURL",
                             fallback: "https://emotiveimpact.com/lumalook/privacy")
    static let terms = url(forInfoKey: "LLTermsOfUseURL",
                           fallback: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    private static func url(forInfoKey key: String, fallback: String) -> URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let url = URL(string: configured) { return url }
        return URL(string: fallback)!
    }

    static func open(_ url: URL) { UIApplication.shared.open(url) }
}

// MARK: - 10 Filter Pack Detail

struct FilterPackDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @State private var previews: [String: CGImage] = [:]
    @State private var hero: CGImage?
    @State private var installing = false
    @State private var installedFlash = 0
    @State private var showPaywall = false
    /// The look the hero and the try-on panel are currently showing.
    @State private var selectedCode: String?
    /// The user's own most recent frame, and whether it really is theirs.
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

    /// The frame this pack previews on — the same one its store tile used, so
    /// tapping a row never swaps the photo out from under the user.
    private var heroPhoto: HeroPhoto { PackThumbs.previewPhoto(for: pack) }

    private var heroSource: CIImage {
        heroPhoto.ciImage ?? LookThumbs.fallbackFrame
    }

    /// A bundled frame deliberately DIFFERENT from the hero, used when the
    /// user has no media of their own — otherwise the try-on panel renders a
    /// pixel-identical copy of the hero 400pt above it and adds nothing.
    private var sampleFallbackSource: CIImage {
        let alternate: HeroPhoto
        switch heroPhoto {
        case .golden: alternate = .coast
        case .coast:  alternate = .desert
        case .desert: alternate = .night
        case .night:  alternate = .neon
        case .neon:   alternate = .golden
        }
        return alternate.ciImage ?? heroSource
    }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    heroBlock

                    VStack(alignment: .leading, spacing: 14) {
                        Text(pack.familyLine)
                            .font(.system(size: 15))
                            .foregroundStyle(LumaTheme.textSecondary)
                            .lineSpacing(3)
                            .padding(.top, 16)

                        HStack {
                            SectionHeader(title: "Inside the Pack")
                            Spacer()
                            TechReadout("TAP TO PREVIEW", size: 9, color: LumaTheme.textMuted)
                        }
                        .padding(.top, 6)

                        // The pack's technical claim belongs with the looks it
                        // describes — tight to the rail, not floating midway
                        // between the rail and the sample panel.
                        VStack(alignment: .leading, spacing: 6) {
                            looksGrid
                            TechReadout(techClaim, size: 9, color: LumaTheme.textMuted)
                        }

                        tryOnPanel

                        priceBlock

                        Text(MockData.namingDisclaimer)
                            .font(.system(size: 11))
                            .foregroundStyle(LumaTheme.textMuted)
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .ignoresSafeArea(edges: .top)
            // The conversion lever is pinned, never scrolled off or drawn
            // under the home indicator.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                installButton
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .background {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(Rectangle().fill(LumaTheme.background.opacity(0.55)))
                            .overlay(alignment: .top) { Hairline() }
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        // Anchored to the ZStack, which still respects the top safe area even
        // though the scrolling hero inside it opts out — so the chevron clears
        // the status bar without any hand-computed inset.
        .overlay(alignment: .topLeading) {
            BackArrow(onMedia: true)
                .padding(.leading, 18)
                .padding(.top, 6)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
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

    // MARK: Hero — the pack's own grade, never stock art

    private var heroBlock: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let hero {
                    Image(decorative: hero, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    HeroImage(photo: heroPhoto)
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipped()
            // Hero overflows its frame; confine hit-testing so it cannot cover
            // the back control or the controls sitting under it.
            .contentShape(Rectangle())
            // Top scrim so the status bar, clock and back control stay legible
            // over bright skies (.coast / .desert); then starts high and reaches
            // full background before the hero's bottom edge, so the photo
            // dissolves into the page instead of ending in a hard full-width seam.
            .overlay(LinearGradient(stops: [
                .init(color: .black.opacity(0.38), location: 0.0),
                .init(color: .clear, location: 0.28),
                .init(color: .clear, location: 0.30),
                .init(color: LumaTheme.background.opacity(0.55), location: 0.68),
                .init(color: LumaTheme.background, location: 0.94)
            ], startPoint: .top, endPoint: .bottom))

            VStack(alignment: .leading, spacing: 4) {
                TechReadout("PACK · \(pack.looks.count) LOOKS", size: 9,
                            color: LumaTheme.accentBright)
                Text(pack.name.uppercased())
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                TechReadout(activeLook.name.uppercased(), size: 9,
                            color: .white.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
        .frame(height: 300)
    }

    // MARK: Looks — every one previewed through the real pipeline

    /// A single horizontal rail (F2), like every other look rail in the app —
    /// no orphan row for 5 looks, and a fixed vertical cost for the 17- and
    /// 22-look packs that would otherwise push the CTA screens away.
    private var looksGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(pack.looks) { look in
                    Button {
                        selectedCode = look.code
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let cg = previews[look.code] {
                                    GradedThumb(image: cg,
                                                size: CGSize(width: 78, height: 96),
                                                radius: 12,
                                                selected: look.code == activeLook.code)
                                } else {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(LumaTheme.surfaceStrong)
                                        .frame(width: 78, height: 96)
                                }
                            }
                            Text(look.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(look.code == activeLook.code
                                                 ? .white : LumaTheme.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                                .frame(width: 78, height: 26, alignment: .top)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .lumaEdgeFade()
    }

    // MARK: Try before buy

    private var tryOnPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let tryOnImage {
                        Image(decorative: tryOnImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LumaTheme.surfaceStrong
                    }
                }
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipped()
                // Try-on preview sits directly above its controls — confine
                // its touch region to the visible panel.
                .contentShape(Rectangle())
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.7)],
                                        startPoint: .center, endPoint: .bottom))

                TechReadout(tryOnIsUserMedia
                            ? "TRY ON YOUR LAST CLIP · \(activeLook.code)"
                            : "SAMPLE FRAME · \(activeLook.code)",
                            size: 9, color: LumaTheme.accentBright)
                    .padding(.leading, 12)
                    .padding(.bottom, 10)
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(tryOnIsUserMedia
                 ? "Your most recent footage, graded with \(activeLook.name) before you buy."
                 : "Import or record something and this panel grades your own footage instead.")
                .font(.system(size: 11.5))
                .foregroundStyle(LumaTheme.textMuted)
        }
        .padding(.top, 4)
    }

    // MARK: Price

    /// What the pack technically is — shown under the looks rail it describes.
    private var techClaim: String {
        pack.looks.contains { $0.cubeFile != nil } ? "MEASURED FILM DATA"
                                                   : "BAKED 33-POINT CUBES"
    }

    /// Two columns, per F2. The right slot carries a FACTUAL readout of what
    /// the pack contains rather than an invented star rating — there is no
    /// real ratings source, and fabricating social proof would be worse than
    /// the void it replaces. The left never repeats the same word at two
    /// sizes: the label names the axis, the value states it once.
    private var priceBlock: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(installed ? "Status"
                     : pack.isFree ? "Price"
                     : pack.isProIncluded ? "Subscription" : "One-time purchase")
                    .font(.system(size: 12))
                    .foregroundStyle(LumaTheme.textSecondary)
                Text(installed ? "In your library"
                     : pack.isFree ? "Free"
                     : pack.isProIncluded ? "Included with Pro"
                     : StoreNav.price(pack, storeService))
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(installed ? LumaTheme.teal : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                TechReadout("\(pack.looks.count) LOOKS", size: 11,
                            color: LumaTheme.textSecondary)
                // Deliberately NOT TechReadout: that type hardcodes
                // lineLimit(1), so the pack's only descriptive claim on this
                // screen truncated mid-word ("INSPIRED BY HOLLY…"). Same
                // instrument voice, but allowed to wrap onto a second line.
                Text(pack.eraTag.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(LumaTheme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: 195, alignment: .trailing)
            .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
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
                // Post-install confirmation — tells the user where the looks
                // landed instead of leaving them to hunt.
                app.importToast = "\(pack.name) installed — \(count) looks in your library"
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

    private var installButton: some View {
        VStack(spacing: 10) {
            Button {
                if installed {
                    StoreNav.openInLibrary(pack, app: app)
                } else {
                    buyOrInstall()
                }
            } label: {
                HStack(spacing: 10) {
                    if installing || storeService.purchaseInFlight {
                        ProgressView().tint(.white)
                    } else if installed {
                        Image(systemName: "checkmark.circle.fill")
                        Text("In Library · Open")
                        Image(systemName: "arrow.right")
                    } else if unlocked {
                        Text(pack.isFree ? "Install Free" : "Install")
                    } else if pack.isProIncluded {
                        Label("Unlock with Pro", systemImage: "crown.fill")
                    } else {
                        Text("Buy pack · \(StoreNav.price(pack, storeService))")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(installed ? LumaTheme.teal : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(installed
                            ? AnyShapeStyle(LumaTheme.teal.opacity(0.16))
                            : AnyShapeStyle(LumaTheme.accent),
                            in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.lumaPress)
            .disabled(storeService.purchaseInFlight)

            // Secondary door for installed packs: go straight to the surface
            // that can use them right now, when there is media to grade.
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
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }

            if !unlocked && !pack.isProIncluded {
                Button {
                    showPaywall = true
                } label: {
                    Text("Or get every pack with Pro")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Rendering

    /// Renders each pack look onto the pack's own hero frame, so the grid,
    /// the hero and the installed library tiles all agree.
    private func renderPreviews() {
        let source = heroSource
        let looks = pack.looks
        Task.detached(priority: .userInitiated) {
            for look in looks {
                guard let cg = PackThumbs.grade(look, on: source, maxDimension: 220) else { continue }
                await MainActor.run { previews[look.code] = cg }
            }
        }
    }

    private func renderHero() {
        let source = heroSource
        let look = activeLook
        Task.detached(priority: .userInitiated) {
            let cg = PackThumbs.grade(look, on: source, maxDimension: 1000)
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
    /// then the newest grade session's media. Falls back to the pack's
    /// bundled hero photo so the panel always renders something real.
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
        tryOnSource = sampleFallbackSource
        tryOnIsUserMedia = false
        renderTryOn()
    }
}

// MARK: - 11 Looks tab — the Library

/// The bottom-bar Looks tab IS the Look Library now (step 6): the same
/// browser used by the grade room / camera / editor sheets, hosted full
/// screen. Saved looks, signature presets, purchased packs, imports,
/// favourites, recents, collections, search and import — one screen.
/// (Replaces the old saved-looks-only list; delete/rename live in each
/// tile's context menu, so the dead "Edit" button is gone.)
struct SavedLooksView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            LookBrowserSheet(context: .library,
                             showsCreateCTA: true,
                             showsBackButton: !isRoot)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.teal)
            }
            LookPreviewSurface(radius: 18)
                .frame(height: 210)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["ADJUST", "CURVES", "WHEELS", "HSL", "SPLIT", "EFFECTS"], id: \.self) { segment in
                        Button { tab = segment } label: {
                            Text(segment)
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(tab == segment ? .white : LumaTheme.textSecondary)
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
                        .font(.subheadline.weight(.semibold))
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
                                            .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
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
                                            .font(.system(size: 11))
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
                            .font(.footnote)
                            .foregroundStyle(LumaTheme.textMuted)
                        GradeSlider(title: "Lens Strength", value: Binding(
                            get: { app.settings.lensAmount },
                            set: { app.settings.lensAmount = max(0, $0) }))
                    }

                    Text("Film Texture")
                        .font(.subheadline.weight(.semibold))
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
                        .font(.system(size: 15))
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
                        .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, alignment: .leading)
            Slider(value: $value, in: -100...100)
                .tint(LumaTheme.accent)
            Text(format?(value) ?? String(format: "%+d", Int(value)))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}

// MARK: - 13 Project Library

/// Projects as a NATIVE inset-grouped List (Apple-native tranche 2):
/// swipe to delete, native separators — records read as records.
struct ProjectLibraryView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false

    var body: some View {
        LumaScreen(title: "Projects", showBack: !isRoot, scrollable: false) {
            ProjectList(store: app.store)
                .padding(.horizontal, -22)   // the List brings its own insets
        }
    }
}

private struct ProjectList: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: PersistenceStore

    var body: some View {
        List {
            // While there are no projects the empty state owns the screen and
            // carries the only CTA — a "New Project" row here would be a second
            // identical primary action a third of a screen away from the first.
            if !store.projects.isEmpty {
                Section {
                    Button {
                        startProject()
                    } label: {
                        Label("New Project", systemImage: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(LumaTheme.accentBright)
                    }
                    .listRowBackground(LumaTheme.card)
                }
            }

            if !store.projects.isEmpty {
                Section {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        Button {
                            app.editor.load(project: project)
                            app.path.append(.editor)
                        } label: {
                            HStack(spacing: 14) {
                                ProjectThumb(project: project, store: store,
                                             fallback: MockScene.allCases[index % MockScene.allCases.count])
                                    // 92x58 + a wrapping subtitle pushed rows past
                                    // 120pt — a project list that showed four items
                                    // per screen. 72x44 with a single-line subtitle
                                    // lands the row at ~60pt.
                                    .frame(width: 72, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text({
                                        var parts = ["\(project.updatedAt.formatted(date: .abbreviated, time: .omitted))",
                                                     timeString(project.duration),
                                                     "\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s")"]
                                        let audio = project.audioTracks?.count ?? 0
                                        if audio > 0 { parts.append("\(audio) audio") }
                                        return parts.joined(separator: " · ")
                                    }())
                                        .font(.footnote)
                                        .foregroundStyle(LumaTheme.textMuted)
                                        // Metadata is a glanceable single line;
                                        // wrapping it doubled every row's height.
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(LumaTheme.textMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(LumaTheme.card)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteProject(project.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("\(store.projects.count) Project\(store.projects.count == 1 ? "" : "s")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Match Settings: tight section gaps, no cavernous inset above the
        // first section. See the note there.
        .listSectionSpacing(18)
        .contentMargins(.top, 2, for: .scrollContent)
        .scrollDisabled(store.projects.isEmpty)
        // With the row hidden the empty state simply centres in its container —
        // no magic top padding compensating for chrome that is no longer there.
        .overlay {
            if store.projects.isEmpty {
                LumaEmptyState(icon: "film.stack",
                               title: "No Projects Yet",
                               message: "Edits auto-save here as you work.",
                               actionTitle: "Start a Project") {
                    startProject()
                }
            }
        }
    }

    private func startProject() {
        app.editor.startNewProject()
        app.path.append(.editor)
    }

    private func timeString(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// First-frame thumbnail of a stored project's first clip.
struct ProjectThumb: View {
    let project: StoredProject
    let store: PersistenceStore
    var fallback: MockScene = .sunsetRoad
    @State private var thumbnail: CGImage?

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
            .clipShape(RoundedRectangle(cornerRadius: 14))
            // Thumb sits inside the project row's Button — the overflowing fill
            // must not extend the row's touch target past its artwork.
            .contentShape(RoundedRectangle(cornerRadius: 14))
        .task {
            guard thumbnail == nil, let first = project.clips.first else { return }
            let url = store.clipURL(for: first)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CanvasBackgroundMode.allCases, id: \.self) { mode in
                        Button { canvasMode = mode } label: {
                            VStack(spacing: 6) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 20, weight: .medium))
                                Text(mode.label).font(.system(size: 12))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FramePreset.allCases, id: \.self) { preset in
                        Button { framePreset = preset } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 20, weight: .medium))
                                Text(preset.label).font(.system(size: 12))
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

            HStack(spacing: 12) {
                Text("Position")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                ForEach(["align.horizontal.left", "align.horizontal.center", "align.horizontal.right"], id: \.self) { icon in
                    Button {} label: {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 62, height: 50)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                Button { zoom = 100 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(LumaTheme.cardRaised))
                }
                .buttonStyle(.plain)
            }
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
            HeroImage(photo: .coast)
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

    var body: some View {
        LumaScreen(title: "Audio", trailingIcon: "checkmark", trailingAction: {
            applyToEditor()
            dismiss()
        }) {
            InlineSlider(title: "Volume", value: $volume) { "\(Int($0))%" }

            Hairline()

            HStack {
                Text("Music")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(LumaTheme.accentDeep)
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Chill Vibes")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text("By Soundstripe")
                            .font(.system(size: 14))
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                    Spacer()
                    Button {} label: {
                        Text("Change")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(LumaTheme.accentDeep.opacity(0.55), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Waveform.
                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: 2.5) {
                        ForEach(0..<52, id: \.self) { i in
                            let h = 8 + CGFloat((i * 37) % 40)
                            Capsule()
                                .fill(LumaTheme.accentBright.opacity(i < 40 ? 0.95 : 0.35))
                                .frame(width: 3, height: h)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("02:45")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(height: 60)
            }
            .padding(16)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))

            InlineSlider(title: "Fade In", value: $fadeIn, range: 0...4) { String(format: "%.1fs", $0) }
            InlineSlider(title: "Fade Out", value: $fadeOut, range: 0...4) { String(format: "%.1fs", $0) }

            Hairline()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voiceover")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Tap to record")
                        .font(.system(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                Spacer()
                Button {} label: {
                    Circle()
                        .fill(LumaTheme.surfaceStrong)
                        .frame(width: 56, height: 56)
                        .overlay(Image(systemName: "mic")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white))
                }
                .buttonStyle(.plain)
            }

            Hairline()

            Toggle(isOn: $mute) {
                Text("Mute Clip Audio")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .tint(LumaTheme.accent)
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

struct SettingsSubscriptionView: View {
    var isRoot: Bool = false
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.requestReview) private var requestReview
    @State private var showPaywall = false
    @State private var showExportQuality = false
    @State private var showAbout = false
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
        LumaScreen(title: "Settings", showBack: !isRoot, scrollable: false) {
            settingsList
                .padding(.horizontal, -22)   // the List brings its own insets
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showExportQuality) {
            exportQualitySheet
                // Three 52pt rows plus the header measure ~271pt at default
                // type and more at larger sizes, so the sheet is medium and the
                // content scrolls rather than clipping the last resolution.
                .presentationDetents([.medium])
                .presentationBackground(LumaTheme.background)
        }
        .sheet(isPresented: $showAbout) {
            aboutSheet
                .presentationDetents([.medium])
                .presentationBackground(LumaTheme.background)
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
            Text("iOS keeps per-app language under Settings › LumaLook. This will leave LumaLook.")
        }
        // Plain facts about what the LUT library costs on disk — no "clean up"
        // button, because every byte here is a look the user chose to keep and
        // deleting them belongs in LUT Manager where they can see what goes.
        .confirmationDialog("Storage", isPresented: $showStorageDetail,
                            titleVisibility: .visible) {
            Button("Manage Imported LUTs") { app.path.append(.lutManager) }
            Button("Done", role: .cancel) { }
        } message: {
            Text("\(app.lutRepository.luts.count) LUTs using \(lutStorageDescription) in LumaLook's documents folder. Removing a LUT frees its space immediately.")
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
        List {
            Section {
                subscriptionCard
                    .listRowBackground(LumaTheme.card)
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
                settingsRow(icon: "4k.tv", title: "Export Quality",
                            value: ExportSpec.from(rawValue: storedSpec).resolution.rawValue) {
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
                            value: "\(app.lutRepository.luts.count)") {
                    app.path.append(.lutManager)
                }
                settingsRow(icon: "internaldrive", title: "Storage Used",
                            value: lutStorageDescription) {
                    showStorageDetail = true
                }
            }
            .listRowBackground(LumaTheme.card)

            Section("About") {
                settingsRow(icon: "questionmark.circle", title: "Help & Support",
                            opensExternally: true) {
                    openSupportMail()
                }
                settingsRow(icon: "star", title: "Rate LumaLook",
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
                settingsRow(icon: "info.circle", title: "About LumaLook",
                            value: "v\(Self.appVersion)") {
                    showAbout = true
                }
            }
            .listRowBackground(LumaTheme.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // insetGrouped ships with ~35pt between sections and a deep inset above
        // the first one. Stacked under LumaScreen's own header padding that left
        // a hand's width of empty black under the title and made five short
        // sections span two screens. 18pt reads as a deliberate group gap.
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
    private func settingsRow(icon: String, title: String, value: String? = nil,
                             opensExternally: Bool = false,
                             busy: Bool = false,
                             showsAffordance: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LumaTheme.accentBright)
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.white)
                Spacer()
                if let value {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LumaTheme.textSecondary)
                } else if showsAffordance {
                    Image(systemName: opensExternally ? "arrow.up.forward.app" : "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LumaTheme.textMuted)
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
        let subject = "LumaLook Support".addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? "LumaLook%20Support"
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
            Text("Export Quality")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 2)
            Text("Default resolution for every export. You can still change it per-export on the export sheet.")
                .font(.system(size: 13))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.bottom, 10)
            ForEach(ExportSpec.Resolution.allCases, id: \.rawValue) { res in
                Button {
                    var spec = ExportSpec.from(rawValue: storedSpec)
                    spec.resolution = res
                    storedSpec = spec.rawValue
                    showExportQuality = false
                } label: {
                    HStack {
                        Text(res.rawValue)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(Self.pixelDimensions(res))
                            .font(.system(size: 12))
                            .foregroundStyle(LumaTheme.textMuted)
                        Spacer()
                        if ExportSpec.from(rawValue: storedSpec).resolution == res {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(LumaTheme.accentBright)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
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
            RoundedRectangle(cornerRadius: 18)
                .fill(LumaTheme.accent)
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: "camera.filters")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white))
                .padding(.top, 30)
            Text("LumaLook")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("Version \(Self.appVersion) (\(Self.appBuild))")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LumaTheme.textSecondary)
            Text("Cinematic looks, live LUT grading and video editing.\nMade by Emotive Impact.")
                .font(.system(size: 14))
                .foregroundStyle(LumaTheme.textMuted)
                .multilineTextAlignment(.center)
            Button {
                let subject = "LumaLook Support".addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? "LumaLook%20Support"
                if let url = URL(string: "mailto:emotiveimpact@gmail.com?subject=\(subject)") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Contact — emotiveimpact@gmail.com", systemImage: "envelope")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 26)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var subscriptionCard: some View {
            // Profile / subscription card — live StoreKit 2 status (C5).
            HStack(spacing: 14) {
                Circle()
                    .fill(LumaTheme.surfaceStrong)
                    .frame(width: 58, height: 58)
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.85)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(storeService.isPro ? "LumaLook Pro" : "LumaLook Free")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(storeService.isPro ? "Unlimited Access" : "Upgrade for Every Look")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(storeService.isPro ? LumaTheme.teal : LumaTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)
                Spacer()
                Button {
                    showPaywall = true
                } label: {
                    Text(storeService.isPro ? "Manage" : "Get Pro")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(LumaTheme.accentDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
    }
}

private struct SettingsGroup: View {
    let rows: [(icon: String, title: String, value: String?, chevron: Bool)]
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 14) {
                    Circle()
                        .fill(LumaTheme.cardRaised)
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: row.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white))
                    Text(row.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let value = row.value {
                        Text(value)
                            .font(.system(size: 16))
                            .foregroundStyle(LumaTheme.textSecondary)
                    }
                    if row.chevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .onTapGesture { onTap?(index) }
                if index < rows.count - 1 {
                    Hairline().padding(.leading, 64)
                }
            }
        }
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

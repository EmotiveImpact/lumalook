import SwiftUI
import AVFoundation
import CoreImage
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
        let frame = source ?? LookThumbs.fallbackFrame
        let key = "\(frame.extent)-\(packs.map(\.id).joined())-\(Int(maxDimension))"
        guard key != stamp else { return }
        stamp = key

        let jobs: [(String, PackLook)] = packs.compactMap { pack in
            pack.looks.first.map { (pack.id, $0) }
        }
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            for (packID, look) in jobs {
                if Task.isCancelled { return }
                guard let cg = PackThumbs.grade(look, on: frame,
                                                maxDimension: maxDimension) else { continue }
                await MainActor.run { self?.images[packID] = cg }
            }
        }
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

/// The one place the store says "owned": teal "✓ In Library" once installed,
/// the real StoreKit price otherwise. Used by both the rows and the featured
/// banner so a pack never reads two different states on one screen.
struct PackStatePill: View {
    let pack: LookPack
    let installed: Bool
    let price: String

    var body: some View {
        if installed {
            Label("In Library", systemImage: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LumaTheme.teal)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(LumaTheme.teal.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(LumaTheme.teal.opacity(0.35), lineWidth: 1))
        } else {
            Text(price)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(pack.isFree ? AnyShapeStyle(LumaTheme.surfaceStrong)
                                        : AnyShapeStyle(LumaTheme.accent), in: Capsule())
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

    /// The flagship recipe pack — looked up by id so catalog growth can't
    /// silently re-point the banner at a different pack.
    private var featured: LookPack {
        PackCatalog.pack(id: "cine-print-set-01") ?? PackCatalog.packs[0]
    }

    private var visiblePacks: [LookPack] {
        PackCatalog.packs.filter { category.contains($0) }
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
                chips
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        if category == .all {
                            SectionHeader(title: "Featured Pack")
                            featuredBanner
                        }

                        SectionHeader(title: category == .all ? "All Packs"
                                                              : "\(category.title) Packs")

                        VStack(spacing: 10) {
                            ForEach(visiblePacks) { pack in
                                StoreRow(pack: pack, thumbnail: thumbs.images[pack.id])
                            }
                        }

                        if visiblePacks.isEmpty {
                            Text("No packs in this category yet.")
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
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
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
                                Capsule().fill(LumaTheme.surface)
                            }
                        }
                        .overlay(Capsule().strokeBorder(
                            .white.opacity(category == cat ? 0.18 : 0.06), lineWidth: 1))
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
                        HeroImage(photo: featured.photo)
                    }
                }
                .frame(height: 158)
                .frame(maxWidth: .infinity)
                .clipped()
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
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(LumaTheme.hairline))
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
                        HeroImage(photo: pack.photo, radius: 12)
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
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(LumaTheme.hairline))
        }
        .buttonStyle(.lumaPress)
    }
}

struct BackArrow: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
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

    /// The hero photo the pack ships with, scaled for still rendering.
    private var heroSource: CIImage {
        pack.photo.ciImage ?? LookThumbs.fallbackFrame
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

                        looksGrid

                        tryOnPanel

                        priceBlock

                        installButton

                        Text(MockData.namingDisclaimer)
                            .font(.system(size: 11))
                            .foregroundStyle(LumaTheme.textMuted)
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.success, trigger: installedFlash)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task(id: pack.id) {
            selectedCode = pack.looks.first?.code
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
                    HeroImage(photo: pack.photo)
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(LinearGradient(colors: [.clear, LumaTheme.background],
                                    startPoint: .center, endPoint: .bottom))

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

            VStack {
                HStack {
                    BackArrow()
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 62)   // hero ignores the top safe area
                Spacer()
            }
        }
        .frame(height: 300)
    }

    // MARK: Looks — every one previewed through the real pipeline

    private var looksGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                  spacing: 14) {
            ForEach(pack.looks) { look in
                Button {
                    selectedCode = look.code
                    LumaHaptics.shared.tap()
                } label: {
                    VStack(spacing: 6) {
                        Group {
                            if let cg = previews[look.code] {
                                GradedThumb(image: cg,
                                            size: CGSize(width: 74, height: 88),
                                            radius: 12,
                                            selected: look.code == activeLook.code)
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(LumaTheme.surfaceStrong)
                                    .frame(height: 88)
                            }
                        }
                        Text(look.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(look.code == activeLook.code
                                             ? .white : LumaTheme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.7)
                            .frame(height: 26, alignment: .top)
                    }
                }
                .buttonStyle(.lumaPress)
            }
        }
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
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(LumaTheme.hairline))

            Text(tryOnIsUserMedia
                 ? "Your most recent footage, graded with \(activeLook.name) before you buy."
                 : "Import or record something and this panel grades your own footage instead.")
                .font(.system(size: 11.5))
                .foregroundStyle(LumaTheme.textMuted)
        }
        .padding(.top, 4)
    }

    // MARK: Price

    private var priceBlock: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.isFree ? "Included free"
                     : pack.isProIncluded ? "Included with Pro" : "One-time purchase")
                    .font(.system(size: 12))
                    .foregroundStyle(LumaTheme.textSecondary)
                Text(installed ? "In your library" : StoreNav.price(pack, storeService))
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(installed ? LumaTheme.teal : .white)
            }
            Spacer()
            TechReadout(pack.looks.contains { $0.cubeFile != nil }
                        ? "MEASURED FILM DATA"
                        : "BAKED 33-POINT CUBES",
                        size: 9, color: LumaTheme.textMuted)
        }
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
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(installed ? LumaTheme.teal.opacity(0.4) : .clear, lineWidth: 1))
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
        tryOnSource = heroSource
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
                        .background(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))
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
            Section {
                Button {
                    app.editor.startNewProject()
                    app.path.append(.editor)
                } label: {
                    Label("New Project", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .listRowBackground(LumaTheme.surface)
            }

            if store.projects.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34))
                            .foregroundStyle(LumaTheme.textMuted)
                        Text("No Projects Yet")
                            .font(.headline)
                            .foregroundStyle(LumaTheme.textSecondary)
                        Text("Edits auto-save here as you work.")
                            .font(.subheadline)
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        Button {
                            app.editor.load(project: project)
                            app.path.append(.editor)
                        } label: {
                            HStack(spacing: 14) {
                                ProjectThumb(project: project, store: store,
                                             fallback: MockScene.allCases[index % MockScene.allCases.count])
                                    .frame(width: 92, height: 58)
                                VStack(alignment: .leading, spacing: 3) {
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
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(LumaTheme.textMuted)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(LumaTheme.surface)
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
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06)))
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
                        .background(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))
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
    @EnvironmentObject private var storeService: StoreService
    @State private var showPaywall = false
    @State private var showExportQuality = false
    @State private var showAbout = false
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
                .presentationDetents([.height(240)])
                .presentationBackground(LumaTheme.background)
        }
        .sheet(isPresented: $showAbout) {
            aboutSheet
                .presentationDetents([.medium])
                .presentationBackground(LumaTheme.background)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUMA_SEED_PAYWALL"] == "1" {
                showPaywall = true
            }
            #endif
        }
    }

    /// NATIVE inset-grouped List (Apple-native tranche 2).
    private var settingsList: some View {
        List {
            Section {
                subscriptionCard
                    .listRowBackground(LumaTheme.surface)
            }

            Section("Purchases") {
                settingsRow(icon: "creditcard", title: "Subscription",
                            value: storeService.isPro ? "Pro" : "Free") {
                    showPaywall = true
                }
                settingsRow(icon: "arrow.clockwise", title: "Restore Purchases") {
                    Task { await storeService.restorePurchases() }
                }
            }
            .listRowBackground(LumaTheme.surface)

            Section("Preferences") {
                settingsRow(icon: "4k.tv", title: "Export Quality",
                            value: ExportSpec.from(rawValue: storedSpec).resolution.rawValue) {
                    showExportQuality = true
                }
                settingsRow(icon: "globe", title: "App Language",
                            value: Locale.current.localizedString(
                                forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")
                                ?? "English") {
                    // Per-app language lives in iOS Settings — deep-link there.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .listRowBackground(LumaTheme.surface)

            Section("About") {
                settingsRow(icon: "questionmark.circle", title: "Help & Support") {
                    let subject = "LumaLook Support".addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed) ?? "LumaLook%20Support"
                    if let url = URL(string: "mailto:emotiveimpact@gmail.com?subject=\(subject)") {
                        UIApplication.shared.open(url)
                    }
                }
                settingsRow(icon: "info.circle", title: "About LumaLook",
                            value: "v\(Self.appVersion)") {
                    showAbout = true
                }
            }
            .listRowBackground(LumaTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func settingsRow(icon: String, title: String, value: String? = nil,
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
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
        .buttonStyle(.plain)
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
                        Text(res == .uhd4K ? "3840×2160" : "1920×1080")
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
        .frame(maxHeight: .infinity, alignment: .top)
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
                        .stroke(.white.opacity(0.35), lineWidth: 1.3)
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

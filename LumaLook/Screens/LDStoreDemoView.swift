import SwiftUI
import AVFoundation
import CoreImage

// =============================================================================
// LDStoreDemoView — the Look Store rebuilt in the LD (Lens Distortions)
// direction. A WORKING screen, not a mock: the real PackCatalog, real pack art
// graded through PackThumbs, real ownership from StoreService/PackStore, real
// StoreKit purchase, real restore, real PackInstaller install.
//
// No products are added and no price is changed — Pro is $49.99/yr, $9.99/mo,
// $119.99 lifetime; packs are $2.99–4.99, all from StoreKit.
//
// -----------------------------------------------------------------------------
// FEATURE INVENTORY vs FilterStoreView + FilterPackDetailView
// -----------------------------------------------------------------------------
// BROWSE
// ✓ All store categories (All / Film / Cinema / Mono / Instant / Camera /
//   Originals / Free), and only those the catalog can actually fill
// ✓ Per-category live counts (mono readout under the category name)
// ✓ Owned readout — N OWNED OF M LOOKS · P/Q PACKS
// ✓ Search across pack name, era tag, and every look's name and code
// ✓ Clear-search control
// ✓ Featured pack (cine-print-set-01, looked up by id) — now the hero itself
// ✓ Pack rows: real graded art, look count, era tag
// ✓ Pack state — In Library / Free / Pro / price — restated monochrome
// ✓ Owned pack tap → StoreNav.openInLibrary (library pre-filtered to the pack)
// ✓ Unowned pack tap → the pack detail
// ✓ Restore purchases → StoreService.restorePurchases()
// ✓ Empty states, both the "no packs in this category" and search variants
// ✓ Naming disclaimer, verbatim from MockData
//
// PACK DETAIL
// ✓ Hero — the pack's own grade on the pack's own frame, uncovered
// ✓ Pack family line
// ✓ Every look previewed through the real pipeline, tap to preview
// ✓ Selected-look readout, and the hero follows the selection
// ✓ Technical claim (MEASURED FILM DATA / BAKED 33-POINT CUBES)
// ✓ Try on your last clip — newest project clip, else newest grade session,
//   else a bundled frame deliberately different from the hero
// ✓ Price block: label + value + look count + era tag
// ✓ Install button, every state: in-flight spinner, In Library · Open,
//   Install / Install Free, Unlock with Pro, Buy pack · price
// ✓ StoreKit purchase → install on success; missing product falls back to Pro
// ✓ "Grade your current media now" secondary door for installed packs
// ✓ "Get every pack with Pro" → PaywallView
// ✓ Post-install toast and success haptic
// ✓ Naming disclaimer
//
// ✗ DEBUG environment seeds (LUMA_SEED_STORECAT, LUMA_SEED_PACKLOOK,
//   LUMA_AUTO_INSTALL) — out of scope: headless test hooks belong to the
//   shipping screen, and a Design Lab preview is judged by eye.
// ✗ Navigation via app.path.append(.filterPack) — this preview owns one route,
//   so the detail is pushed inside the screen instead. Every action it takes
//   (purchase, install, open in library, paywall) is the real one.
// -----------------------------------------------------------------------------
//
// THE MONOCHROME "OWNED" PROBLEM
// The shipping store says owned with a teal pill, which is the only colour on
// a screen whose whole job is to show colour. Here ownership is said three
// ways, none of them hue: the row's surface steps UP a value (owned packs sit
// on a lighter plate than the ones you could still buy), the readout reads
// IN LIBRARY in full white where a price reads in grey, and a filled white
// check disc sits where the price would be. Value, weight, and a mark — it
// reads instantly at a glance and survives greyscale, which teal never did.
//
// The purchase button is the one place a filled button is still correct: white
// fill, black label. Confident, and still not a colour.
// =============================================================================

struct LDStoreDemoView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = PackThumbs()

    @State private var category: StoreCategory = .all
    @State private var query = ""
    @State private var searchOpen = false
    @State private var detailPackID: String?
    @State private var restoring = false

    private var categories: [StoreCategory] {
        StoreCategory.allCases.filter { cat in
            cat == .all || PackCatalog.packs.contains(where: cat.contains)
        }
    }

    private var categoryIndex: Int { categories.firstIndex(of: category) ?? 0 }

    private var needle: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

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

    /// The flagship recipe pack, by id so catalog growth cannot silently
    /// re-point the hero at something else.
    private var featured: LookPack {
        PackCatalog.pack(id: "cine-print-set-01") ?? PackCatalog.packs[0]
    }

    /// The pack the hero is currently showing: the featured pack while
    /// browsing, the first result while filtering or searching — so the image
    /// on top always belongs to what is under it.
    private var heroPack: LookPack {
        if !needle.isEmpty || category != .all {
            return visiblePacks.first ?? featured
        }
        return featured
    }

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
                hero
                    .frame(height: 214)
                drawer
            }
            if let id = detailPackID, let pack = PackCatalog.pack(id: id) {
                LDPackDetail(pack: pack) {
                    withAnimation(.snappy(duration: 0.26)) { detailPackID = nil }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")") {
            thumbs.render(packs: PackCatalog.packs, source: app.previewFrame)
        }
    }

    // MARK: Hero — pack art, uncovered

    private var hero: some View {
        let pack = heroPack
        return Button {
            open(pack)
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
            if searchOpen {
                searchField
                    .padding(.bottom, 12)
            }
            list
            instructionBar
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searchOpen)
    }

    /// The hero's name lives here, under the picture, never over it.
    private var heroCaption: some View {
        let pack = heroPack
        let installed = app.packStore.isInstalled(pack)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                TechReadout(needle.isEmpty && category == .all ? "FEATURED PACK" : "FIRST RESULT",
                            size: 9, color: .white.opacity(0.42))
                Text(pack.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                TechReadout("\(pack.looks.count) LOOKS · \(pack.eraTag)",
                            size: 9, color: .white.opacity(0.38))
            }
            Spacer(minLength: 8)
            PackState(pack: pack, installed: installed,
                      price: StoreNav.price(pack, storeService))
        }
    }

    /// Rule 5 again: current category centred, neighbours faded either side,
    /// counts in mono underneath. Replaces the accent chip rail wholesale.
    private var categoryBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                neighbour(at: categoryIndex - 1, alignment: .leading)
                Text(categories[categoryIndex].title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 10)
                neighbour(at: categoryIndex + 1, alignment: .trailing)
            }
            TechReadout("\(ownedLookCount) OWNED OF \(PackCatalog.totalLookCount) · \(ownedPackCount)/\(PackCatalog.packs.count) PACKS",
                        size: 9, color: .white.opacity(0.34))
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in step(value.translation.width < 0 ? 1 : -1) }
        )
    }

    @ViewBuilder
    private func neighbour(at index: Int, alignment: Alignment) -> some View {
        if categories.indices.contains(index) {
            Button {
                step(index - categoryIndex)
            } label: {
                VStack(spacing: 1) {
                    Text(categories[index].title)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.3))
                    TechReadout("\(PackCatalog.packs.filter(categories[index].contains).count)",
                                size: 8, color: .white.opacity(0.22))
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
        guard categories.indices.contains(next) else { return }
        withAnimation(.snappy(duration: 0.22)) { category = categories[next] }
        LumaHaptics.shared.tap()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
            TextField("Search packs and looks", text: $query)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
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
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                }
                Text(MockData.namingDisclaimer)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.3))
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

    /// The pack tile IS its own art. Ownership separates by surface value, not
    /// by hue: an owned pack sits on a lighter plate than one you could buy.
    private func row(_ pack: LookPack) -> some View {
        let installed = app.packStore.isInstalled(pack)
        return Button {
            open(pack)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(installed ? .white : .white.opacity(0.85))
                        .lineLimit(1)
                    TechReadout("\(pack.looks.count) LOOKS · \(pack.eraTag)",
                                size: 8.5, color: .white.opacity(0.36))
                }
                Spacer(minLength: 6)
                PackState(pack: pack, installed: installed,
                          price: StoreNav.price(pack, storeService))
            }
            .padding(10)
            .background(Color(white: installed ? 0.13 : 0.075),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    /// Owned packs are a door into the library, not a purchase screen.
    private func open(_ pack: LookPack) {
        if app.packStore.isInstalled(pack) {
            StoreNav.openInLibrary(pack, app: app)
        } else {
            withAnimation(.snappy(duration: 0.26)) { detailPackID = pack.id }
            LumaHaptics.shared.tap()
        }
    }

    // MARK: Instruction bar — search and restore live at the edges

    private var instructionBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    searchOpen.toggle()
                    if !searchOpen { query = "" }
                }
                LumaHaptics.shared.tap()
            } label: {
                Text(searchOpen ? "Searching \(visiblePacks.count) of \(PackCatalog.packs.count) packs"
                                : "Tap a pack to preview it")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
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

// MARK: - Ownership, said without colour

/// Four states, no hue between them: a filled white check disc for owned, and
/// mono readouts of decreasing weight for everything you could still get.
private struct PackState: View {
    let pack: LookPack
    let installed: Bool
    let price: String

    var body: some View {
        if installed {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 18, height: 18)
                    .background(.white, in: Circle())
                TechReadout("IN LIBRARY", size: 9, color: .white)
            }
        } else if pack.isFree {
            TechReadout("FREE", size: 10, color: .white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(white: 0.18), in: Capsule())
        } else if pack.isProIncluded {
            HStack(spacing: 5) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.8))
                TechReadout("PRO", size: 10, color: .white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(white: 0.18), in: Capsule())
        } else {
            TechReadout(price, size: 11, color: .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
    }
}

// MARK: - Pack detail

/// Same grammar one level down: the pack's own grade on top, uncovered, and
/// every control — the looks rail, the try-on panel, the price, the buy —
/// in the drawer below it.
private struct LDPackDetail: View {
    let pack: LookPack
    let onClose: () -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService

    @State private var previews: [String: CGImage] = [:]
    @State private var hero: CGImage?
    @State private var installing = false
    @State private var installedFlash = 0
    @State private var showPaywall = false
    @State private var selectedCode: String?
    @State private var tryOnSource: CIImage?
    @State private var tryOnIsUserMedia = false
    @State private var tryOnImage: CGImage?

    /// Free, individually bought, or unlocked by Pro.
    private var unlocked: Bool { storeService.ownsPack(pack.id) }
    private var installed: Bool { app.packStore.isInstalled(pack) }

    private var activeLook: PackLook {
        pack.looks.first { $0.code == selectedCode } ?? pack.looks[0]
    }

    /// The same frame the pack's store art used, so opening a pack never swaps
    /// the photo out from under the user.
    private var heroPhoto: HeroPhoto { PackThumbs.previewPhoto(for: pack) }
    private var heroSource: CIImage { heroPhoto.ciImage ?? LookThumbs.fallbackFrame }

    /// Deliberately DIFFERENT from the hero: without it, a user with no media
    /// of their own gets a pixel-identical copy of the hero in the try-on
    /// panel, which teaches them nothing.
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

    /// What the pack technically is.
    private var techClaim: String {
        pack.looks.contains { $0.cubeFile != nil } ? "MEASURED FILM DATA"
                                                   : "BAKED 33-POINT CUBES"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                heroBlock
                    .frame(height: 250)
                drawer
            }
        }
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
    }

    private var heroBlock: some View {
        GeometryReader { geo in
            Group {
                if let hero {
                    Image(decorative: hero, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    HeroImage(photo: heroPhoto, radius: 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var drawer: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    titleBlock
                    Text(pack.familyLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineSpacing(3)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TechReadout("INSIDE THE PACK", size: 9, color: .white.opacity(0.42))
                            Spacer()
                            TechReadout("TAP TO PREVIEW", size: 9, color: .white.opacity(0.3))
                        }
                        looksRail
                        TechReadout(techClaim, size: 9, color: .white.opacity(0.3))
                    }

                    tryOnPanel
                    priceBlock

                    Text(MockData.namingDisclaimer)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 22)
            }
            .mask {
                VStack(spacing: 0) {
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                }
            }
            actionBar
        }
        .background(Color.black)
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                TechReadout("PACK · \(pack.looks.count) LOOKS", size: 9,
                            color: .white.opacity(0.42))
                Text(pack.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                TechReadout(activeLook.name, size: 9, color: .white.opacity(0.5))
            }
            Spacer(minLength: 8)
            PackState(pack: pack, installed: installed,
                      price: StoreNav.price(pack, storeService))
        }
    }

    /// Every look, previewed through the real pipeline on the pack's own frame.
    private var looksRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(pack.looks) { look in
                    let active = look.code == activeLook.code
                    Button {
                        selectedCode = look.code
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let cg = previews[look.code] {
                                    Image(decorative: cg, scale: 1)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Color(white: 0.12)
                                }
                            }
                            .frame(width: 74, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                if active {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(.white, lineWidth: 2)
                                }
                            }
                            Text(look.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(active ? .white : .white.opacity(0.45))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                                .frame(width: 74, height: 26, alignment: .top)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.vertical, 2)
        }
        .lumaEdgeFade()
    }

    private var tryOnPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(height: 126)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let tryOnImage {
                        Image(decorative: tryOnImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(white: 0.10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            TechReadout(tryOnIsUserMedia
                        ? "YOUR LAST CLIP · \(activeLook.code)"
                        : "SAMPLE FRAME · \(activeLook.code)",
                        size: 9, color: .white.opacity(0.5))
            Text(tryOnIsUserMedia
                 ? "Your most recent footage, graded with \(activeLook.name) before you buy."
                 : "Import or record something and this panel grades your own footage instead.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.34))
        }
    }

    /// A factual readout of what the pack contains — never an invented star
    /// rating, because there is no ratings source and fabricated social proof
    /// is worse than the void it fills.
    private var priceBlock: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                TechReadout(installed ? "STATUS"
                            : pack.isFree ? "PRICE"
                            : pack.isProIncluded ? "SUBSCRIPTION" : "ONE-TIME PURCHASE",
                            size: 9, color: .white.opacity(0.42))
                Text(installed ? "In your library"
                     : pack.isFree ? "Free"
                     : pack.isProIncluded ? "Included with Pro"
                     : StoreNav.price(pack, storeService))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                TechReadout("\(pack.looks.count) LOOKS", size: 11, color: .white.opacity(0.6))
                // Deliberately not TechReadout: that type hardcodes
                // lineLimit(1), and this is the pack's only descriptive claim
                // on the screen. Same instrument voice, allowed to wrap.
                Text(pack.eraTag.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(.white.opacity(0.34))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: 190, alignment: .trailing)
            .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Action bar — ✕ at the edge, the one filled button in the middle

    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the store")

                Button {
                    if installed {
                        StoreNav.openInLibrary(pack, app: app)
                    } else {
                        buyOrInstall()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if installing || storeService.purchaseInFlight {
                            ProgressView().tint(.black)
                        } else if installed {
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.lumaPress)
                .disabled(storeService.purchaseInFlight)
            }
            .padding(.horizontal, 12)

            // Both secondary doors from the shipping screen, kept as plain
            // sentences rather than a second competing button.
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            if !unlocked && !pack.isProIncluded {
                Button { showPaywall = true } label: {
                    Text("Or get every pack with Pro")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
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
                app.importToast = "\(pack.name) installed — \(count) looks in your library"
            }
        }
    }

    /// Paid packs buy through StoreKit first; free / already-owned packs
    /// install straight away. No product (offline or review) offers Pro.
    private func buyOrInstall() {
        if unlocked {
            performInstall()
            return
        }
        guard let product = storeService.packProducts[pack.id] else {
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

    /// The user's own most recent footage: newest project's first clip, then
    /// the newest grade session's media, then a bundled frame.
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

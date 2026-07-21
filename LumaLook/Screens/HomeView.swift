import SwiftUI
import AVFoundation
import CoreImage

/// E2 — launcher Home. Four large panels own the first screen; the discovery
/// rail underneath is deliberately cut in half by the fold so the page reads
/// as "there is more down here" without spending any vertical budget on a
/// scroll hint. Everything below the fold — recents, the rest of the shelf —
/// is real content on real routes.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @StateObject private var packThumbs = HomePackThumbs()
    @State private var showPaywall = false

    /// Wordmark alignment is an open design question (centred vs left), so both
    /// are built and switchable at launch: `LUMA_LOGO=center`. Ship default is
    /// LEFT — see the note in `header`.
    #if DEBUG
    private let logoCentred = ProcessInfo.processInfo.environment["LUMA_LOGO"] == "center"
    #else
    private let logoCentred = false
    #endif

    /// Recents are real only when the user has projects or saved grades.
    /// `LUMA_SEED_HOMEEMPTY=1` forces the invite state so the empty rail can
    /// be verified on a device that already has work in it.
    private var hasRecents: Bool {
        if ProcessInfo.processInfo.environment["LUMA_SEED_HOMEEMPTY"] == "1" { return false }
        return !app.store.projects.isEmpty || !app.store.gradeSessions.isEmpty
    }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            // The panel height is SOLVED from the live viewport rather than
            // hard-coded, because the whole point of the layout is where the
            // fold lands: the grid ends exactly high enough that the explore
            // cards are cut through their middle. See `HomeMetrics.panelHeight`.
            GeometryReader { geo in
                scroll(viewport: HomeMetrics.viewport(geo), width: geo.size.width)
            }
        }
        // STICKY header: the wordmark bar is pinned; content scrolls under it.
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .onAppear { packThumbs.render(featuredPacks + morePacks) }
        .onChange(of: app.packStore.installedPackIDs) { _, _ in
            packThumbs.render(featuredPacks + morePacks)
        }
    }

    private func scroll(viewport: CGFloat, width: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                panelGrid(height: HomeMetrics.panelHeight(viewport: viewport, width: width))
                    .padding(.horizontal, 20)
                    .padding(.top, HomeMetrics.topPad)

                Spacer(minLength: 0).frame(height: HomeMetrics.gridToRail)

                // Order is deliberate: your own work first, then what is new,
                // then the wider catalogue to browse. One card metric across
                // all three rails — differing sizes per rail is what made the
                // page read as assembled rather than designed.
                recentsSection

                if !morePacks.isEmpty {
                    Spacer(minLength: 0).frame(height: 28)
                    SectionHeader(title: "Fresh this week", actionTitle: "Store") {
                        app.tab = .store
                        LumaHaptics.shared.tap()
                    }
                    .padding(.horizontal, 20)
                    Spacer(minLength: 0).frame(height: HomeMetrics.headerToRail)
                    packRail(morePacks, badged: newBadgeIDs, size: HomeMetrics.railCard)
                }

                Spacer(minLength: 0).frame(height: 28)

                SectionHeader(title: "More to explore", actionTitle: "Store") {
                    app.tab = .store
                    LumaHaptics.shared.tap()
                }
                .padding(.horizontal, 20)
                Spacer(minLength: 0).frame(height: HomeMetrics.headerToRail)
                packRail(featuredPacks, size: HomeMetrics.railCard)
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: Header

    /// Two builds of the same bar. LEFT puts the wordmark on the same optical
    /// axis as every section header and every panel title below it, so the
    /// page has one left margin; CENTRED reads more like a brand splash but
    /// breaks that axis and shunts the crown/gear pair into a corner cluster.
    private var header: some View {
        ZStack {
            if logoCentred {
                LumaWordmark(size: 20)
            }
            HStack(spacing: 10) {
                if !logoCentred {
                    LumaWordmark(size: 21)
                }
                Spacer(minLength: 8)
                proButton
                settingsButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background {
            // Solid brand background so scrolling content passes under
            // cleanly — no material, no seam.
            LumaTheme.background.ignoresSafeArea(edges: .top)
        }
    }

    private var proButton: some View {
        Button {
            // Pro is a real state: subscribers manage it in Settings,
            // everyone else gets the paywall.
            if storeService.isPro { app.path.append(.settings) } else { showPaywall = true }
            LumaHaptics.shared.tap()
        } label: {
            if storeService.isPro {
                HStack(spacing: 5) {
                    Image(systemName: "crown.fill").font(.system(size: 12))
                    TechReadout("PRO", size: 10, color: LumaTheme.gold)
                }
                .foregroundStyle(LumaTheme.gold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(LumaTheme.gold.opacity(0.16), in: Capsule())
            } else {
                Image(systemName: "crown.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(LumaTheme.gold)
                    .frame(width: 38, height: 34)
            }
        }
        .buttonStyle(.lumaPress)
    }

    private var settingsButton: some View {
        Button { app.path.append(.settings) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: The four panels

    /// Four verbs, fixed forever: make something, shoot something, grade
    /// something, get more looks. They never reorder and never depend on
    /// state, which is what lets a 2x2 launcher build muscle memory.
    private func panelGrid(height: CGFloat) -> some View {
        VStack(spacing: HomeMetrics.gridSpacing) {
            HStack(spacing: HomeMetrics.gridSpacing) {
                HomePanel(icon: "plus", title: "New Project",
                          tint: LumaTheme.accentBright, height: height) {
                    app.editor.startNewProject()
                    app.path.append(.editor)
                }
                HomePanel(icon: "camera.fill", title: "Camera",
                          tint: Color(red: 0.93, green: 0.66, blue: 0.36), height: height) {
                    app.path.append(.camera)
                }
            }
            HStack(spacing: HomeMetrics.gridSpacing) {
                HomePanel(icon: "camera.filters", title: "Apply Look",
                          tint: LumaTheme.teal, height: height) {
                    app.path.append(.selectClip)
                }
                HomePanel(icon: "bag.fill", title: "Look Store",
                          tint: Color(red: 0.62, green: 0.68, blue: 0.95), height: height) {
                    app.tab = .store
                }
            }
        }
    }

    // MARK: Recents — below the fold, never deleted

    @ViewBuilder private var recentsSection: some View {
        if hasRecents {
            SectionHeader(title: "Jump back in", actionTitle: "See All") {
                app.path.append(.projectLibrary)
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0).frame(height: HomeMetrics.headerToRail)
            RecentsRail(store: app.store)
        } else {
            SectionHeader(title: "Jump back in")
                .padding(.horizontal, 20)
            Spacer(minLength: 0).frame(height: HomeMetrics.headerToRail)
            // Nothing saved yet. This must NOT restate the four panels sitting
            // one screen above it — so it explains the empty rail and offers
            // the one primary destination the grid does not cover: the look
            // library the user already owns.
            EmptyWorkCard {
                app.tab = .looks
                LumaHaptics.shared.tap()
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Discovery

    /// Packs the user does not already own — a rail of packs they cannot act
    /// on is not discovery.
    private var discoverablePacks: [LookPack] {
        let unowned = PackCatalog.packs.filter { !app.packStore.isInstalled($0) }
        return unowned.isEmpty ? PackCatalog.packs : unowned
    }

    /// Interleaved across pack families and rotated weekly, so the rail is
    /// never one release cohort wearing six identical badges.
    private var featuredPacks: [LookPack] {
        HomeFeatured.weeklyRail(discoverablePacks, count: 6)
    }

    /// The tail of the shelf: everything the peek rail did not surface.
    private var morePacks: [LookPack] {
        let shown = Set(featuredPacks.map(\.id))
        return Array(discoverablePacks.filter { !shown.contains($0.id) }.prefix(6))
    }

    /// NEW is capped so it still carries information.
    private var newBadgeIDs: Set<String> {
        Set(featuredPacks.prefix(HomeFeatured.newBadgeLimit)
            .filter { HomeFeatured.isNew($0) }
            .map(\.id))
    }

    private func packRail(_ packs: [LookPack], badged: Set<String> = [],
                          size: HomeMetrics.CardSize) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(packs) { pack in
                    PackTile(pack: pack, image: packThumbs.images[pack.id],
                             photo: packThumbs.photos[pack.id] ?? pack.photo,
                             isNew: badged.contains(pack.id), size: size) {
                        app.selectedPackID = pack.id
                        app.path.append(.filterPack)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - Layout solver

/// The one piece of arithmetic the whole screen depends on. The brief is that
/// the four panels get generous space AND the explore cards are visibly cut
/// through the middle by the bottom of the screen. Both cannot be hard-coded
/// across a 5.4" and a 6.9" phone, so the panel height is derived: everything
/// between the top of the grid and the top of the explore cards is a known
/// constant, therefore
///
///     2 * panel + constants + halfCard = viewport
///
/// and the panels absorb the difference.
enum HomeMetrics {
    struct CardSize {
        let width: CGFloat
        let height: CGFloat
        let radius: CGFloat
    }

    static let topPad: CGFloat = 14
    static let gridSpacing: CGFloat = 12
    static let gridToRail: CGFloat = 24
    /// SectionHeader is a footnote next to a 15pt semibold button.
    static let sectionHeaderHeight: CGFloat = 21
    static let headerToRail: CGFloat = 12

    /// The peek rail. Tall enough that a half card is still a legible image.
    static let exploreCard = CardSize(width: 124, height: 164, radius: 14)
    /// THE rail card. Every rail on Home uses this one metric.
    static let railCard = CardSize(width: 124, height: 164, radius: 14)
    /// The second shelf, fully below the fold, is a normal browsing size.
    static let shelfCard = CardSize(width: 124, height: 150, radius: 15)

    /// How much of an explore card stays visible above the bottom of the
    /// screen. 0.5 is the brief; the clamp on `panelHeight` can push the real
    /// figure a few points either way on very short devices, which is why the
    /// target sits dead centre of the acceptable 45–55% band.
    static let peekFraction: CGFloat = 0.5

    /// Height of everything above the explore cards, excluding the grid.
    private static var chrome: CGFloat {
        topPad + gridSpacing + gridToRail + sectionHeaderHeight + headerToRail
    }

    /// The visible content region between the sticky header and the tab bar.
    /// Depending on how the two `safeAreaInset` layers resolve, the proxy
    /// either reports the already-reduced height with zero insets, or the full
    /// screen with the insets attached — so both readings are computed and the
    /// plausible smaller one wins.
    static func viewport(_ geo: GeometryProxy) -> CGFloat {
        let raw = geo.size.height
        let inset = raw - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_HOME_METRICS"] == "1" {
            print("[LUMA] HOME raw=\(raw) top=\(geo.safeAreaInsets.top) bottom=\(geo.safeAreaInsets.bottom) inset=\(inset) panel=\(min(max((raw - chrome - exploreCard.height * peekFraction) / 2, 150), 300))")
        }
        #endif
        // MEASURED, not guessed: inside both safeAreaInsets the proxy already
        // reports the visible content height (660pt on a 16 Pro Max) while its
        // reported insets describe something else entirely — subtracting them
        // again yielded 365pt, which drove the panels to their floor and left
        // the explore rail fully above the fold instead of half-cut.
        _ = inset
        return raw > 320 ? raw : 660
    }

    /// Panel height is derived from the COLUMN WIDTH, not from the viewport.
    /// Solving it against the screen made four buttons eat ~70% of a phone —
    /// a launcher tile should read as a control, so it stays a shade wider
    /// than it is tall and the rails below get the room they earn.
    /// A launcher tile is a CONTROL. Stacking a glyph above a title above a
    /// subtitle forced a tall box with a void in the middle; laying it out
    /// horizontally lets the same four actions cost 172pt instead of 260.
    static func panelHeight(viewport: CGFloat, width: CGFloat = 0) -> CGFloat { 80 }
}

// MARK: - Panels

/// A primary action. Separation comes from a lifted gradient surface and a
/// soft drop shadow — no outline. (Borders are being pulled app-wide; a 1px
/// stroke on a coloured tile reads as a web button, not a control surface.)
private struct HomePanel: View {
    let icon: String
    let title: String
    /// The panel's identity colour. It tints the surface faintly and owns the
    /// glyph outright — full-bleed saturated fills read as toy, not tool.
    let tint: Color
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button {
            LumaHaptics.shared.tap()
            action()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            // Near-black surface carrying only a whisper of the identity hue.
            // The colour lives in the glyph; the panel stays cinematic.
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LumaTheme.cardRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(LinearGradient(colors: [tint.opacity(0.15), tint.opacity(0.03)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        }
        .buttonStyle(.lumaPress)
    }
}

/// Shown instead of the recents rail when there is no saved work. It routes to
/// the Looks library — deliberately the one primary destination the four
/// panels do not already cover, so the empty state adds a door rather than
/// repeating the four sitting a screen above it.
private struct EmptyWorkCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(LumaTheme.accentBright)
                    .frame(width: 46, height: 46)
                    .background(LumaTheme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing saved yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Projects and grades you save land here. Meanwhile your look library is already stocked.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Recents rail

private struct RecentsRail: View {
    @ObservedObject var store: PersistenceStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Both are valid recents; the grade poster carries a badge so
                // it never reads as a project.
                ForEach(store.gradeSessions.prefix(3)) { session in
                    GradeSessionPoster(session: session)
                }
                ForEach(Array(store.projects.prefix(6).enumerated()), id: \.element.id) { index, project in
                    ProjectPoster(project: project, store: store,
                                  fallback: MockScene.allCases[index % MockScene.allCases.count])
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// Poster geometry is shared by every recents card so the rail stays even.
private enum Poster {
    // Matches HomeMetrics.railCard exactly: every rail on Home shares one
    // card metric, so the page reads as designed rather than assembled.
    static let width: CGFloat = 124
    static let height: CGFloat = 164
    static let radius: CGFloat = 14

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Bottom scrim so white type survives a bright frame.
    static var scrim: LinearGradient {
        LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.78)],
                       startPoint: .center, endPoint: .bottom)
    }
}

private struct ProjectPoster: View {
    @EnvironmentObject private var app: AppModel
    let project: StoredProject
    let store: PersistenceStore
    var fallback: MockScene

    var body: some View {
        Button {
            app.editor.load(project: project)
            app.path.append(.editor)
            LumaHaptics.shared.tap()
        } label: {
            ZStack(alignment: .bottomLeading) {
                ProjectThumb(project: project, store: store, fallback: fallback)
                    .frame(width: Poster.width, height: Poster.height)
                Poster.scrim
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    TechReadout(Poster.duration(project.duration), size: 10,
                                color: .white.opacity(0.75))
                }
                .padding(10)
            }
            .frame(width: Poster.width, height: Poster.height)
            .clipShape(RoundedRectangle(cornerRadius: Poster.radius))
            // scaledToFill overflows its frame and keeps taking taps outside
            // it — clipShape clips pixels, not touches. This bounds the touch.
            .contentShape(RoundedRectangle(cornerRadius: Poster.radius))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        }
        .buttonStyle(.lumaPress)
    }
}

/// A saved Apply-a-Look session in Recents: real media frame + GRADE badge;
/// tap restores the exact grade.
private struct GradeSessionPoster: View {
    @EnvironmentObject private var app: AppModel
    let session: GradeSession
    @State private var thumb: CGImage?

    var body: some View {
        Button {
            app.restoreGradeSession(session)
            LumaHaptics.shared.tap()
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let thumb {
                        Color.clear.overlay {
                            Image(decorative: thumb, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                    } else {
                        LumaTheme.surfaceStrong
                    }
                }
                .frame(width: Poster.width, height: Poster.height)
                Poster.scrim
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.baseLookName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(10)
            }
            .frame(width: Poster.width, height: Poster.height)
            .clipShape(RoundedRectangle(cornerRadius: Poster.radius))
            .contentShape(RoundedRectangle(cornerRadius: Poster.radius))
            .overlay(alignment: .topLeading) {
                TechReadout("GRADE", size: 9, color: .white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LumaTheme.accent, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        }
        .buttonStyle(.lumaPress)
        .task {
            guard thumb == nil else { return }
            let url = app.store.sessionMediaURL(session)
            if session.isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 340, height: 340)
                thumb = try? await generator.image(
                    at: CMTime(seconds: 0.05, preferredTimescale: 600)).image
            } else if let ci = CIImage(contentsOf: url) {
                let scale = min(1, 340 / max(ci.extent.width, ci.extent.height))
                let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                thumb = LookPipeline.shared.renderCGImage(from: scaled)
            }
        }
    }
}

// MARK: - Pack tile

private struct PackTile: View {
    let pack: LookPack
    let image: CGImage?
    /// The frame this tile was graded on — assigned by `HomePackThumbs` so
    /// neighbouring tiles never share a base image (see its `render`).
    var photo: HeroPhoto
    var isNew: Bool = false
    let size: HomeMetrics.CardSize
    let action: () -> Void

    private var isLarge: Bool { size.width > 140 }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image {
                        Color.clear.overlay {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                    } else {
                        // Pipeline render pending — the tile's assigned hero
                        // photo holds the frame rather than an empty box.
                        HeroImage(photo: photo, radius: 0)
                    }
                }
                .frame(width: size.width, height: size.height)
                Poster.scrim
                Text(pack.name)
                    .font(.system(size: isLarge ? 14 : 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(isLarge ? 12 : 8)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: size.radius))
            // Same trap as the posters: the filled image overflows the frame
            // and would otherwise steal taps from the adjacent pack tile.
            .contentShape(RoundedRectangle(cornerRadius: size.radius))
            .overlay(alignment: .topTrailing) {
                if isNew {
                    TechReadout("NEW", size: 8, color: .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(LumaTheme.accent, in: Capsule())
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 7)
        }
        .buttonStyle(.lumaPress)
    }
}

/// Which catalog packs count as "of the week". Release dates come from the
/// shipping record (ROADMAP: the 102-stock film archive landed 2026-07-12);
/// packs with no entry predate it and never read as new. The badge expires on
/// its own after `newWindow`, so it can never go stale on the shelf.
private enum HomeFeatured {
    static let newWindow: TimeInterval = 30 * 24 * 3600

    private static let released: [String: Date] = {
        var out: [String: Date] = [:]
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 12
        guard let filmArchiveDate = Calendar(identifier: .gregorian).date(from: components) else { return out }
        for id in ["film-stocks-01", "film-neg-archive", "film-slide-archive",
                   "film-mono-archive", "film-instant-lab", "film-mirrorless-sims"] {
            out[id] = filmArchiveDate
        }
        return out
    }()

    static func isNew(_ pack: LookPack, on date: Date = Date()) -> Bool {
        guard let released = released[pack.id] else { return false }
        let age = date.timeIntervalSince(released)
        return age >= 0 && age < newWindow
    }

    /// Newest release first, catalog order preserved inside each group.
    static func newestFirst(_ packs: [LookPack]) -> [LookPack] {
        packs.filter { isNew($0) } + packs.filter { !isNew($0) }
    }

    /// How many tiles may wear the badge. A rail where every tile is NEW
    /// tells the user nothing — the badge only means something if it is rare.
    static let newBadgeLimit = 2

    /// The pack families the rail interleaves across, in shelf order. Reuses
    /// the Store's own taxonomy so Home and Store agree on what a family is.
    private static let families: [StoreCategory] =
        [.film, .cinema, .mono, .instant, .camera, .originals]

    static func family(of pack: LookPack) -> StoreCategory {
        families.first { $0.contains(pack) } ?? .all
    }

    /// Stable per-week value so the peek rail actually turns over on a weekly
    /// cadence instead of being frozen to one release cohort.
    static func weekSeed(_ date: Date = Date()) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let week = calendar.component(.weekOfYear, from: date)
        let year = calendar.component(.yearForWeekOfYear, from: date)
        return abs(year &* 53 &+ week)
    }

    /// One rail, interleaved across families and rotated weekly, so a single
    /// release cohort can never take the whole shelf.
    static func weeklyRail(_ packs: [LookPack], count: Int, on date: Date = Date()) -> [LookPack] {
        var groups: [(family: StoreCategory, packs: [LookPack])] = []
        for pack in newestFirst(packs) {
            let family = family(of: pack)
            if let index = groups.firstIndex(where: { $0.family == family }) {
                groups[index].packs.append(pack)
            } else {
                groups.append((family, [pack]))
            }
        }
        let seed = weekSeed(date)
        let rotated = groups.map { group -> [LookPack] in
            guard group.packs.count > 1 else { return group.packs }
            let offset = seed % group.packs.count
            return Array(group.packs[offset...]) + Array(group.packs[..<offset])
        }
        var out: [LookPack] = []
        var round = 0
        let deepest = rotated.map(\.count).max() ?? 0
        while out.count < count && round < deepest {
            for group in rotated where round < group.count {
                out.append(group[round])
                if out.count == count { break }
            }
            round += 1
        }
        return out
    }
}

/// Renders one representative look per featured pack through the real
/// pipeline onto the shared preview frame — the same source `LookThumbs`
/// uses, so Home shows the grade, never stock art.
@MainActor
private final class HomePackThumbs: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    /// The frame each pack was graded on, so the placeholder shown before the
    /// pipeline finishes matches the frame that replaces it.
    @Published private(set) var photos: [String: HeroPhoto] = [:]
    private var task: Task<Void, Never>?
    private var lastStamp = ""

    /// Every frame the rails may draw from. The catalog only tags packs with
    /// four of these, and reuses them, hence `assignedPhotos` below.
    private static let allPhotos: [HeroPhoto] = [.golden, .coast, .desert, .neon, .night]

    /// How many neighbours a frame must stay clear of. Roughly a screenful of
    /// tiles, so two identical base images can never be visible together.
    private static let separation = 4

    /// A pack keeps its own hero photo unless one of the last `separation`
    /// tiles already used it — then it takes the least-recently-used frame
    /// instead. Grading two near-neutral looks on the same photo produced
    /// pixel-identical tiles (Film Stocks 01 / Mirrorless Sims, Negative Set
    /// 01 / Negative Archive), which conveys nothing.
    static func assignedPhotos(for packs: [LookPack]) -> [String: HeroPhoto] {
        var out: [String: HeroPhoto] = [:]
        var recent: [HeroPhoto] = []
        for pack in packs {
            let photo: HeroPhoto
            if recent.contains(pack.photo),
               let free = allPhotos.first(where: { !recent.contains($0) }) {
                photo = free
            } else {
                photo = pack.photo
            }
            out[pack.id] = photo
            recent.append(photo)
            if recent.count > separation { recent.removeFirst() }
        }
        return out
    }

    func render(_ packs: [LookPack]) {
        let stamp = packs.map(\.id).joined(separator: ",")
        guard stamp != lastStamp else { return }
        lastStamp = stamp

        // Each pack is graded on its OWN hero photo (same rule as the Store's
        // pack detail), de-duplicated across neighbours so no two tiles on
        // screen share a base image.
        let assigned = Self.assignedPhotos(for: packs)
        photos = assigned
        let jobs: [(id: String, look: PackLook, source: CIImage)] = packs.compactMap { pack in
            guard let look = pack.looks.first else { return nil }
            return (pack.id, look, Self.source(for: assigned[pack.id] ?? pack.photo))
        }
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            for job in jobs {
                if Task.isCancelled { return }
                let state = LookState()
                if let cubeFile = job.look.cubeFile,
                   let url = Bundle.main.url(
                       forResource: (cubeFile as NSString).deletingPathExtension,
                       withExtension: "cube") {
                    state.lut = try? LookPipeline.shared.loadLUT(at: url)
                } else {
                    state.recipe = job.look.recipe
                }
                var settings = LookSettings()
                settings.intensity = 100
                state.settings = settings
                // The peek cards are 160x240 points, so the render has to be
                // considerably bigger than the old 96-wide tiles asked for.
                if let cg = LookPipeline.shared.gradedStill(job.source, state: state, maxDimension: 420) {
                    await MainActor.run { self?.images[job.id] = cg }
                }
            }
        }
    }

    /// The assigned photograph, scaled to preview size; falls back to the
    /// shared frame only when the asset is missing.
    private static func source(for photo: HeroPhoto) -> CIImage {
        guard let ci = photo.ciImage else { return LookThumbs.fallbackFrame }
        let longest = max(ci.extent.width, ci.extent.height)
        guard longest > 720 else { return ci }
        let scale = 720 / longest
        return ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

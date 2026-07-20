import SwiftUI
import AVFoundation
import CoreImage

/// E1 — create-first Home. Hierarchy is hero → two half-tiles → recents rail
/// → discovery rail; every card lands on a real destination.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @StateObject private var packThumbs = HomePackThumbs()
    @State private var showPaywall = false

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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    createBlock

                    VStack(alignment: .leading, spacing: 12) {
                        recentsHeader
                        RecentsRail(store: app.store, hasRecents: hasRecents)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Looks of the week", actionTitle: "Store") {
                            app.tab = .store
                            LumaHaptics.shared.tap()
                        }
                        .padding(.horizontal, 20)
                        looksOfTheWeek
                    }

                    // Second discovery row: without it Home ran out of content
                    // a third of the way up a Pro Max, leaving dead black.
                    if !morePacks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "More to explore", actionTitle: "Store") {
                                app.tab = .store
                                LumaHaptics.shared.tap()
                            }
                            .padding(.horizontal, 20)
                            packRail(morePacks)
                        }
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 28)
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LumaWordmark(size: 21)
            Spacer(minLength: 8)
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
                    .background(LumaTheme.gold.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(LumaTheme.gold.opacity(0.35), lineWidth: 1))
                } else {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(LumaTheme.gold)
                        .frame(width: 38, height: 34)
                }
            }
            .buttonStyle(.lumaPress)
            Button { app.path.append(.settings) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.lumaPress)
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

    // MARK: Create block — hero + two half-tiles

    private var createBlock: some View {
        VStack(spacing: 10) {
            Button {
                app.editor.startNewProject()
                app.path.append(.editor)
                LumaHaptics.shared.tap()
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New project")
                            .font(.system(size: 19, weight: .heavy))
                            .foregroundStyle(.white)
                        Text("Edit clips, music, looks")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 15))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LumaTheme.tilePurple, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(LumaTheme.accentBright.opacity(0.30), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
            }
            .buttonStyle(.lumaPress)

            HStack(spacing: 10) {
                HomeHalfTile(icon: "camera.fill", title: "Camera", subtitle: "Live looks",
                             gradient: LumaTheme.tileAmber, iconTint: .white) {
                    app.path.append(.camera)
                }
                HomeHalfTile(icon: "camera.filters", title: "Apply Look", subtitle: "Grade in 2 taps",
                             gradient: LumaTheme.tileTeal,
                             iconTint: Color(red: 0.55, green: 0.95, blue: 0.85)) {
                    app.path.append(.selectClip)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Recents

    /// "See All" only once REAL work exists — over the invite cards it landed
    /// new users on an empty Projects screen.
    @ViewBuilder private var recentsHeader: some View {
        if hasRecents {
            SectionHeader(title: "Recent projects", actionTitle: "See All") {
                app.path.append(.projectLibrary)
            }
            .padding(.horizontal, 20)
        } else {
            SectionHeader(title: "Recent projects")
                .padding(.horizontal, 20)
        }
    }

    // MARK: Looks of the week

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

    /// The tail of the shelf: everything the week's rail did not surface.
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

    private var looksOfTheWeek: some View {
        packRail(featuredPacks, badged: newBadgeIDs)
    }

    private func packRail(_ packs: [LookPack], badged: Set<String> = []) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(packs) { pack in
                    PackTile(pack: pack, image: packThumbs.images[pack.id],
                             photo: packThumbs.photos[pack.id] ?? pack.photo,
                             isNew: badged.contains(pack.id)) {
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

// MARK: - Recents rail

private struct RecentsRail: View {
    @ObservedObject var store: PersistenceStore
    let hasRecents: Bool

    var body: some View {
        if hasRecents {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Both are valid recents; the grade poster carries a badge
                    // and a violet edge so it never reads as a project.
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
        } else {
            // No work yet. The previous invite cards restated the New project
            // hero and the Camera tile verbatim, three cards higher up the
            // page — which inverts the hero → tiles → recents hierarchy. One
            // quiet line explains the empty rail without competing with them.
            Text("Projects you edit show up here.")
                .font(.system(size: 13))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.horizontal, 20)
        }
    }
}

/// Poster geometry is shared by every recents card so the rail stays even.
private enum Poster {
    static let width: CGFloat = 124
    static let height: CGFloat = 150
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
            .overlay(RoundedRectangle(cornerRadius: Poster.radius)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1))
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
            .overlay(alignment: .topLeading) {
                TechReadout("GRADE", size: 9, color: .white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LumaTheme.accent, in: Capsule())
                    .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: Poster.radius)
                .strokeBorder(LumaTheme.accent.opacity(0.55), lineWidth: 1))
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

// MARK: - Looks of the week

private struct PackTile: View {
    let pack: LookPack
    let image: CGImage?
    /// The frame this tile was graded on — assigned by `HomePackThumbs` so
    /// neighbouring tiles never share a base image (see its `render`).
    var photo: HeroPhoto
    var isNew: Bool = false
    let action: () -> Void

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
                .frame(width: 96, height: 110)
                Poster.scrim
                Text(pack.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(8)
            }
            .frame(width: 96, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(alignment: .topTrailing) {
                if isNew {
                    TechReadout("NEW", size: 8, color: .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(LumaTheme.accent, in: Capsule())
                        .padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1))
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

    /// Stable per-week value so "Looks of the week" actually turns over on a
    /// weekly cadence instead of being frozen to one release cohort.
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
    /// instead. Grading two near-neutral looks on the same photo at 96x110
    /// produced pixel-identical tiles (Film Stocks 01 / Mirrorless Sims,
    /// Negative Set 01 / Negative Archive), which conveys nothing.
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
                if let cg = LookPipeline.shared.gradedStill(job.source, state: state, maxDimension: 220) {
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
        guard longest > 440 else { return ci }
        let scale = 440 / longest
        return ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

private struct HomeHalfTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let gradient: LinearGradient
    var iconTint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(height: 30)
                    // Light that radiates FROM the glyph. The old 110x110
                    // radial was anchored to the icon at the tile's corner,
                    // so the clip turned it into an off-centre smudge.
                    .shadow(color: iconTint.opacity(0.45), radius: 10)
                Spacer(minLength: 10)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(gradient, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.lumaPress)
    }
}

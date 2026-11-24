import SwiftUI
import AVFoundation
import CoreImage

/// Home, "AF1 Viewfinder reel" in the calm coat with the colour back (calm
/// mock v2, other-screens-v2/01-home.jpg). The reel of tonight's looks runs
/// edge to edge under the top bar with thin story bars and nothing drawn over
/// the picture itself, then fades into the page. Tonight's look is the
/// headline: its name and its Try button wear that look's own colour. The
/// strip under it shows each code in its look's colour; tapping one pauses
/// the reel and regrades whoever is on screen, and the picked tile wears the
/// pale ring. Tapping the picture goes back to the reel.
///
/// Top to bottom: the reel (story bars, Tonight's look, Try this look and
/// All looks, the strip), the Resume row, four quiet tiles (Edit a clip,
/// Edit a photo, Templates, Import LUT), then calm captioned grids:
/// Templates (Cut to the beat templates when `LumaFeatures.cutToTheBeat` is
/// on, still as their rail), Looks (Looks for you | Recents), Continue
/// editing and the pack spotlight. Shooting lives on the yellow tab shutter,
/// in the same place on every tab; Try this look takes tonight's look to the
/// camera.
///
/// The top row (the wordmark, Pro and You) is pinned. At rest it sits on the
/// reel; as the page scrolls the page's ink fades in behind it, so it becomes
/// the top bar that everything scrolls under.
///
/// First run (no projects): "Welcome to Lumalook" with Edit a clip (the main
/// action), Edit a photo and Import, then "Or start from a template". No
/// Resume row and no Continue editing.
///
/// The avatar opens You; there is no crown or gear here any more. The Store
/// is folded into Looks, so Home links to the pack page and the Looks tab,
/// never to the old Store tab.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var lookTiles = HomeLookTileRender()
    @State private var looksMode: HomeLooksMode = .forYou
    /// Which of tonight's looks the reel is on.
    @State private var reelIndex = 0
    /// A look picked in the reel's strip (preset name). It pauses the reel
    /// and regrades the frame on screen; nil lets the reel cycle.
    @State private var reelPick: String? = nil
    /// "See all" on the template grid shows every template in place.
    @State private var showsAllTemplates = false
    /// How far the top row has turned into the top bar (0 at rest, 1 once
    /// the page has scrolled a little). Held in @State, not @StateObject, so
    /// HomeView doesn't observe it: only the bar and the story bars do, and
    /// scrolling never redraws the rest of the page.
    @State private var scroll = HomeScrollProgress()

    /// Scroll target for the "Templates" quick tile.
    static let beatAnchor = "home.cutToTheBeat"
    /// LUMA_SEED_HOMESCROLL (Debug): open Home scrolled down to the templates.
    private static let seedScroll: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LUMA_SEED_HOMESCROLL"] == "1"
        #else
        return false
        #endif
    }()
    private static let scrollSpace = "home.scroll"
    /// Looks in the Looks grid (two rows); All looks opens the rest.
    private static let looksShown = 4

    /// The reel's height: about 600 pt on an iPhone 17 Pro like the mock,
    /// shorter on the first run, where the copy is the welcome.
    static func reelHeight(screen: CGFloat, isFirstRun: Bool) -> CGFloat {
        if isFirstRun {
            return min(540, max(440, (screen * 0.54).rounded()))
        }
        // About 545 pt on an iPhone 17 Pro, so the quick tiles and the next
        // heading sit on the first screen.
        return min(600, max(490, (screen * 0.62).rounded()))
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let works = self.works
            let reelHeight = HomeView.reelHeight(
                screen: geo.size.height + safeTop + geo.safeAreaInsets.bottom,
                isFirstRun: works.isEmpty)
            ZStack(alignment: .top) {
                LumaTheme.background.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        page(safeTop: safeTop, reelHeight: reelHeight, works: works, scrollToTemplates: {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(HomeView.beatAnchor, anchor: .top)
                            }
                        })
                        .padding(.bottom, 40)
                        .background(alignment: .top) {
                            GeometryReader { inner in
                                Color.clear.preference(
                                    key: HomeScrollOffsetKey.self,
                                    value: inner.frame(in: .named(HomeView.scrollSpace)).minY)
                            }
                        }
                    }
                    .coordinateSpace(name: HomeView.scrollSpace)
                    // The reel runs up under the status bar.
                    .ignoresSafeArea(.container, edges: .top)
                    .modifier(HomeScrollTracker(scroll: scroll))
                    .task {
                        // Preview: scroll to the templates so a screenshot
                        // shows the collapsed top bar.
                        guard HomeView.seedScroll else { return }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        proxy.scrollTo(HomeView.beatAnchor, anchor: .top)
                    }
                }
                HomeStatusScrim(height: safeTop)
                HomeTopBar(scroll: scroll, safeTop: safeTop)
                    .accessibilitySortPriority(1)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onPreferenceChange(HomeScrollOffsetKey.self) { offset in
            // iOS 17 only: from iOS 18 the scroll view reports its own offset
            // (HomeScrollTracker), which also catches programmatic scrolls.
            if #available(iOS 18.0, *) { return }
            scroll.follow(offset)
        }
        .onAppear { renderLookTiles() }
        .onChange(of: tileStamp) { _, _ in renderLookTiles() }
    }

    // MARK: Page

    @ViewBuilder
    private func page(safeTop: CGFloat, reelHeight: CGFloat, works: [HomeWork],
                      scrollToTemplates: @escaping () -> Void) -> some View {
        let resume = works.first
        let isFirstRun = works.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            viewfinderReel(isFirstRun: isFirstRun, safeTop: safeTop, height: reelHeight)
            if let resume {
                HomeResumeRow(work: resume, store: app.store) { open(resume) }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
            }
            if !isFirstRun {
                HomeQuickTiles(onEdit: { newVideo() },
                               onPhoto: { newPhoto() },
                               onTemplates: scrollToTemplates)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    // Gives back the room the Templates heading reaches up
                    // into (see templatesSection), so the visible gap is
                    // unchanged.
                    .padding(.bottom, beatTemplates.isEmpty ? 0 : -Self.anchorReach(safeTop: safeTop))
            }
            templatesSection(safeTop: safeTop, isFirstRun: isFirstRun)
            looksSection
            continueSection(Array(works.dropFirst()))
            packSection
        }
    }

    private func viewfinderReel(isFirstRun: Bool, safeTop: CGFloat, height: CGFloat) -> some View {
        ViewfinderReel(looks: reelLooks,
                       stripLooks: TonightsLook.all,
                       index: $reelIndex,
                       pick: $reelPick,
                       packLine: { packLine(for: $0) },
                       isFirstRun: isFirstRun,
                       safeTop: safeTop,
                       height: height,
                       reduceMotion: reduceMotion,
                       scroll: scroll,
                       onTry: { shoot(with: shownLook) },
                       onAllLooks: { openLooks() },
                       onEdit: { newVideo() },
                       onPhoto: { newPhoto() })
    }

    /// Four looks, one for each story bar.
    private var reelLooks: [TonightsLook] { TonightsLook.reel(count: 4) }

    /// What the reel's frame is wearing right now: the look picked in the
    /// strip, else the reel's own. Try this look takes it to the camera.
    private var shownLook: TonightsLook {
        let looks = reelLooks
        let base = looks.isEmpty ? TonightsLook.today : looks[min(reelIndex, looks.count - 1)]
        guard let name = reelPick,
              let picked = TonightsLook.all.first(where: { $0.preset.name == name }) else { return base }
        return TonightsLook(preset: picked.preset, photo: base.photo, line: picked.line)
    }

    /// How far the Templates heading reaches up behind the top bar, so that
    /// with its 30 pt gap the words land just clear of the bar's soft edge
    /// when the Templates tile scrolls it to the top. The quick tiles give
    /// the room back (their negative bottom padding); the heading's padding
    /// is clear and takes no taps, so the Resume row and the tiles it lies
    /// over stay tappable.
    private static func anchorReach(safeTop: CGFloat) -> CGFloat {
        safeTop + LumaTabMetrics.barBottom - 14
    }

    @ViewBuilder
    private func templatesSection(safeTop: CGFloat, isFirstRun: Bool) -> some View {
        let templates = beatTemplates
        if !templates.isEmpty {
            let reach = isFirstRun ? 0 : Self.anchorReach(safeTop: safeTop)
            if LumaFeatures.cutToTheBeat {
                // Cut to the beat (switched off): its own rail, unchanged.
                HomeSectionHeader(title: "Cut to the beat")
                    .padding(.horizontal, 20)
                    .padding(.top, 30 + reach)
                    .id(HomeView.beatAnchor)
                Spacer(minLength: 0).frame(height: 12)
                BeatTemplateRail(templates: templates) { startTemplate($0) }
            } else {
                let collapsed = isFirstRun ? 4 : 3
                let canExpand = templates.count > collapsed
                let shown = showsAllTemplates ? templates : Array(templates.prefix(collapsed))
                HomeSectionHeader(title: isFirstRun ? "Or start from a template" : "Templates",
                                  quiet: isFirstRun,
                                  actionTitle: canExpand ? (showsAllTemplates ? "Show less" : "See all") : nil) {
                    withAnimation(.easeInOut(duration: 0.25)) { showsAllTemplates.toggle() }
                    LumaHaptics.shared.tap()
                }
                .padding(.horizontal, 20)
                .padding(.top, (isFirstRun ? 22 : 30) + reach)
                .id(HomeView.beatAnchor)
                Spacer(minLength: 0).frame(height: 12)
                HomeTemplateGrid(templates: shown,
                                 columns: isFirstRun ? 2 : 3,
                                 tileHeight: 196) { startTemplate($0) }
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var looksSection: some View {
        let recents = recentLooks
        let showsSwitch = !recents.isEmpty
        let mode: HomeLooksMode = showsSwitch ? looksMode : .forYou
        let looks = Array((mode == .recents ? recents : forYouLooks).prefix(Self.looksShown))
        HomeLooksHeader(mode: $looksMode, showsSwitch: showsSwitch) { openLooks() }
            .padding(.horizontal, 20)
            // Right under the quick tiles when Templates is off (Edem found
            // the old gap too big); the usual section gap otherwise.
            .padding(.top, looksHeaderGap)
            .id(LumaFeatures.templates ? "home.looks" : HomeView.beatAnchor)
        Spacer(minLength: 0).frame(height: 12)
        HomeLookGrid(looks: looks,
                     photos: lookPhotos,
                     images: lookTiles.images,
                     isPro: storeService.isPro,
                     isCurrent: { app.isCurrent($0) },
                     onPick: { tryOnLook($0) },
                     onStar: { app.library.toggleFavourite($0) })
            .padding(.horizontal, 12)
    }

    /// Space above "Looks for you": tight when it follows the quick tiles.
    private var looksHeaderGap: CGFloat {
        let followsTiles = !works.isEmpty && beatTemplates.isEmpty
        return followsTiles ? 12 : 30
    }

    @ViewBuilder
    private func continueSection(_ others: [HomeWork]) -> some View {
        // Two rows at most: saved grades (up to two) keep their place, your
        // other edits fill the rest. All opens Projects.
        let sessions = Array(app.store.gradeSessions.prefix(2))
        let shownWorks = Array(others.prefix(max(0, 4 - sessions.count)))
        if !shownWorks.isEmpty || !sessions.isEmpty {
            HomeSectionHeader(title: "Continue editing", actionTitle: "All") {
                openProjects()
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            Spacer(minLength: 0).frame(height: 12)
            HomeContinueGrid(works: shownWorks, sessions: sessions, store: app.store) { open($0) }
                .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private var packSection: some View {
        if let pack = spotlightPack {
            let tag = packTag(pack)
            HomeSectionHeader(title: pack.isNew ? "New pack" : "Look pack")
                .padding(.horizontal, 20)
                .padding(.top, 30)
            Spacer(minLength: 0).frame(height: 12)
            PackSpotlight(pack: pack,
                          detail: packDetail(pack),
                          tag: tag.text,
                          tagIsPaid: tag.paid) {
                openPack(pack)
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: Data

    /// Projects, newest first. The first one is the Resume row.
    private var works: [HomeWork] {
        #if DEBUG
        // Forces the first-run layout on a device that already has work.
        if ProcessInfo.processInfo.environment["LUMA_SEED_HOMEEMPTY"] == "1" { return [] }
        #endif
        let real = app.store.projects
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { HomeWork(project: $0) }
        #if DEBUG
        // The simulator preview has no projects; show the returning-user
        // layout with demo cards (never written to the store).
        if real.isEmpty && HomeDemo.isActive { return HomeDemo.works }
        #endif
        return real
    }

    /// The templates: the beat-cut ones while Cut to the beat is on (as
    /// their own rail), otherwise the plain ones as a grid. The Templates
    /// quick tile lands on either.
    private var beatTemplates: [VideoTemplate] {
        // Templates switched off: no row, and the quick tiles drop the tile.
        guard LumaFeatures.templates else { return [] }
        guard LumaFeatures.cutToTheBeat else { return TemplateLibrary.shown }
        let beat = TemplateLibrary.all.filter { $0.isBeatCut }
        if !beat.isEmpty { return beat }
        return TemplateLibrary.builtIn.filter { $0.isBeatCut }
    }

    /// Favourites first, then a curated spread of signature looks.
    private static let forYouOrder = [
        "CN93 · Luxury Campaign", "AG60 · London Rain", "KD52 · Cine Negative",
        "CN83 · Teal & Orange", "Neon Nights", "KD2 · Golden Hour", "Night Drive",
        "Afrobeats Glow", "KD4 · Clean Neutral", "BW32 · Documentary Grit",
    ]

    private var forYouLooks: [LibraryLook] {
        let all = app.library.all
        var picked: [LibraryLook] = []
        var seen = Set<String>()
        for look in all where look.isFavourite && !seen.contains(look.id) {
            picked.append(look)
            seen.insert(look.id)
        }
        for name in Self.forYouOrder {
            for look in all where look.name == name && !seen.contains(look.id) {
                picked.append(look)
                seen.insert(look.id)
            }
        }
        return Array(picked.prefix(10))
    }

    private var recentLooks: [LibraryLook] {
        Array(app.library.recents.prefix(10))
    }

    /// Each look on its own person. Same input, same answer, so the grid and
    /// the renderer always agree.
    private var lookPhotos: [String: HeroPhoto] {
        HomeLookPhotos.assign(forYouLooks + recentLooks)
    }

    private var tileStamp: String {
        (forYouLooks + recentLooks).map(\.id).joined(separator: ",")
    }

    private func renderLookTiles() {
        let looks = forYouLooks + recentLooks
        let luts = app.lutRepository
        lookTiles.render(looks,
                         photos: HomeLookPhotos.assign(looks),
                         luts: luts.luts,
                         fileURL: { luts.fileURL(for: $0) })
    }

    /// Packs live in Looks now. The looks-pack lane owns which pack is in
    /// the spotlight (`PackCatalog.spotlight`, After Dark); Home only draws
    /// it from the pack's own name, colour, looks and photo.
    private var spotlightPack: LookPack? {
        PackCatalog.spotlight
    }

    /// "5 looks · Flash, neon and packed rooms"
    private func packDetail(_ pack: LookPack) -> String {
        let count = pack.looks.count
        let looks = "\(count) \(count == 1 ? "look" : "looks")"
        return looks + " · " + packCopy(pack)
    }

    private func packCopy(_ pack: LookPack) -> String {
        let night = pack.looks.contains { $0.name.contains("Neon Nights") || $0.name.contains("Afrobeats Glow") }
        return night ? "Flash, neon and packed rooms" : pack.eraTag
    }

    /// The small glass tag on the cover: Free, In library, With Pro, or the
    /// price, which takes the pack's colour.
    private func packTag(_ pack: LookPack) -> (text: String, paid: Bool) {
        if pack.isFree { return ("Free", false) }
        if storeService.ownsPack(pack.id) { return ("In library", false) }
        if pack.isProIncluded { return ("With Pro", false) }
        return (pack.price, true)
    }

    /// "After Dark pack", "Free · Signature" or "Signature · Pro".
    private func packLine(for look: TonightsLook) -> String {
        if look.preset.category == "Original" {
            return "\(spotlightPack?.name ?? "After Dark") pack"
        }
        return look.preset.isPremium ? "Signature · Pro" : "Free · Signature"
    }

    // MARK: Actions

    /// Select clips for a new edit. The picker builds the editor project
    /// from the picks (`openSelectClips` comes from the select-clips lane).
    private func newVideo() {
        app.openSelectClips(.edit)
    }

    private func newPhoto() {
        // A new still starts from an empty picker, so Next cannot carry on
        // with the last clip that was graded.
        app.selectedVideoURL = nil
        app.selectedImage = nil
        app.batchItems = []
        app.openSelectClips(.photo)
    }

    private func openLooks() {
        app.tab = .looks
        LumaHaptics.shared.tap()
    }

    private func openProjects() {
        app.tab = .projects
        LumaHaptics.shared.tap()
    }

    private func openPack(_ pack: LookPack) {
        app.selectedPackID = pack.id
        app.path.append(.filterPack)
        LumaHaptics.shared.tap()
    }

    private func open(_ work: HomeWork) {
        if let project = work.project {
            app.editor.load(project: project)
            app.path.append(.editor)
        } else {
            // DEBUG demo card: there is no media behind it.
            newVideo()
        }
        LumaHaptics.shared.tap()
    }

    /// Try this look: tonight's look (or the one picked in the strip) goes
    /// on, and the camera opens wearing it.
    private func shoot(with look: TonightsLook) {
        useLook(named: look.preset.name)
        app.path.append(.camera)
        LumaHaptics.shared.tap()
    }

    private func tryOnLook(_ look: LibraryLook) {
        app.select(look: look)
        restoreStrengthIfOff()
        app.openSelectClips(.grade)
        LumaHaptics.shared.tap()
    }

    /// A template: its look goes on the grade, then Select clips opens with
    /// the template. The picker builds the project from the picks and
    /// applies the template by id through the editor's own `applyTemplate`.
    private func startTemplate(_ template: VideoTemplate) {
        if let name = template.lookName { useLook(named: name) }
        app.openSelectClips(.edit, templateID: template.id)
        LumaHaptics.shared.tap()
    }

    /// Puts a built-in look on the grade by name (or the pack look that
    /// replaced it, matched by its stock code).
    private func useLook(named name: String) {
        if let look = libraryLook(named: name) {
            app.select(look: look)
        }
        restoreStrengthIfOff()
    }

    /// Grading may have been switched off (the camera's Off tile sets
    /// strength to zero); trying a look on should show the look.
    private func restoreStrengthIfOff() {
        if app.settings.intensity == 0 {
            app.settings.intensity = app.openingStrength
        }
    }

    private func libraryLook(named name: String) -> LibraryLook? {
        let all = app.library.all
        for look in all {
            if case .builtIn(let preset) = look.source, preset.name == name { return look }
        }
        guard let code = LookSignature.code(in: name) else { return nil }
        for look in all where look.name == code || look.name.hasPrefix(code + " ") {
            return look
        }
        return nil
    }
}

// MARK: - Work (projects as Home shows them)

/// A project as Home shows it: real, or (DEBUG only) a demo card.
private struct HomeWork: Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let clipCount: Int
    let duration: Double
    /// The first clip's own look, if the edit has one.
    let lookName: String?
    /// Share of clips wearing a look: the Resume card's progress line.
    let gradedFraction: Double
    let project: StoredProject?
    let demoPhoto: HeroPhoto?

    init(project: StoredProject) {
        id = project.id
        title = project.title
        updatedAt = project.updatedAt
        clipCount = project.clips.count
        duration = project.duration
        var name: String? = nil
        for clip in project.clips {
            if let base = clip.grade?.baseLookName,
               !base.trimmingCharacters(in: .whitespaces).isEmpty {
                name = base
                break
            }
        }
        lookName = name
        let graded = project.clips.filter { $0.grade != nil }.count
        gradedFraction = project.clips.isEmpty ? 0 : Double(graded) / Double(project.clips.count)
        self.project = project
        demoPhoto = nil
    }

    init(demo title: String, photo: HeroPhoto, lookName: String,
         clips: Int, duration: Double, hoursAgo: Double) {
        id = UUID()
        self.title = title
        updatedAt = Date().addingTimeInterval(-hoursAgo * 3600)
        clipCount = clips
        self.duration = duration
        self.lookName = lookName
        gradedFraction = 0.62
        project = nil
        demoPhoto = photo
    }

    var signature: Color {
        guard let lookName else { return LumaTheme.signal }
        return LookSignature.colour(forLookNamed: lookName)
    }

    /// "KD2", or the look's title when it has no stock code.
    var lookCode: String? {
        guard let lookName else { return nil }
        return LookSignature.code(in: lookName) ?? LookSignature.title(in: lookName)
    }

    var clipsText: String { "\(clipCount) \(clipCount == 1 ? "clip" : "clips")" }

    /// "4 clips · 0:12 · KD2"
    var detail: String {
        var parts = [clipsText, Poster.duration(duration)]
        if let lookCode { parts.append(lookCode) }
        return parts.joined(separator: " · ")
    }

    /// "KD2 · 4 clips"
    var shortDetail: String {
        guard let lookCode else { return clipsText }
        return "\(lookCode) · \(clipsText)"
    }

    /// "Edited 2 h ago"
    static func editedLabel(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Edited just now" }
        if seconds < 3600 { return "Edited \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "Edited \(Int(seconds / 3600)) h ago" }
        if Calendar.current.isDateInYesterday(date) { return "Edited yesterday" }
        if seconds < 7 * 86_400 { return "Edited \(Int(seconds / 86_400)) days ago" }
        return "Edited " + date.formatted(.dateTime.day().month(.abbreviated))
    }
}

#if DEBUG
/// Demo cards for the simulator preview (LUMA_TAB=Home or
/// LUMA_SEED_HOMEDEMO=1) when the store is empty. In memory only: nothing is
/// written, so the Projects tab still shows its empty state.
private enum HomeDemo {
    static var isActive: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["LUMA_SEED_HOMEDEMO"] == "1" || env["LUMA_TAB"] == "Home"
    }

    static let works: [HomeWork] = [
        HomeWork(demo: "Friday night", photo: .golden, lookName: "KD2 · Golden Hour",
                 clips: 4, duration: 12, hoursAgo: 2),
        HomeWork(demo: "Bus home", photo: .rain, lookName: "AG60 · London Rain",
                 clips: 7, duration: 31, hoursAgo: 26),
        HomeWork(demo: "Bowl session", photo: .skate, lookName: "CN83 · Teal & Orange",
                 clips: 5, duration: 18, hoursAgo: 75),
    ]
}
#endif

// MARK: - Header

/// The scroll position, kept apart from HomeView so that only the views
/// that change as you scroll (the top bar and the story bars) redraw.
private final class HomeScrollProgress: ObservableObject {
    /// 0 at rest, 1 once the page has scrolled `HomeTopBar.collapseDistance`.
    @Published private(set) var collapse: CGFloat = 0

    /// `offset` is the page's top edge in the scroll view (negative once
    /// scrolled). Steps of 1/40 keep it smooth without publishing every point.
    func follow(_ offset: CGFloat) {
        // The pull first: while you pull down the bar's collapse stays at 0,
        // so the early return below would otherwise skip it every time.
        pull.follow(offset)
        let raw = min(1, max(0, -offset / HomeTopBar.collapseDistance))
        let stepped = (raw * 40).rounded() / 40
        guard stepped != collapse else { return }
        #if DEBUG
        if stepped == 1 || stepped == 0 { print("[LUMA] HOMEBAR collapse=\(stepped) offset=\(offset)") }
        #endif
        collapse = stepped
    }

    /// How far the page is pulled down past its top. Kept in its own object
    /// so that only the reel's picture redraws while you pull.
    let pull = HomePullAmount()
}

/// The distance the page is pulled down past its top (0 at rest).
private final class HomePullAmount: ObservableObject {
    @Published private(set) var amount: CGFloat = 0

    func follow(_ offset: CGFloat) {
        let next = (max(0, offset) * 2).rounded() / 2
        guard next != amount else { return }
        amount = next
    }
}

/// Pull down at the top of Home and the reel's picture grows to fill the
/// space, its top edge held at the top of the screen, so no empty band
/// opens above it. It scales from its bottom edge, which moves down with
/// the page.
private struct HomeReelStretch<Content: View>: View {
    @ObservedObject var pull: HomePullAmount
    let height: CGFloat
    @ViewBuilder let content: Content

    private var scale: CGFloat {
        guard height > 0 else { return 1 }
        return 1 + pull.amount / height
    }

    var body: some View {
        content.scaleEffect(scale, anchor: .bottom)
    }
}

/// Feeds the scroll position to the top bar. From iOS 18 it comes straight
/// from the scroll view; iOS 17 falls back to the page's frame preference
/// (HomeScrollOffsetKey).
private struct HomeScrollTracker: ViewModifier {
    let scroll: HomeScrollProgress

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, scrolled in
                scroll.follow(-scrolled)
            }
        } else {
            content
        }
    }
}

/// The wordmark, Pro and You, pinned above the page in the same spot as
/// every tab's bar (LumaTopBar). At rest it sits on the reel's picture, which
/// runs to the top of the screen, above the story bars. As the page scrolls the row stays
/// put and the page's ink fades in behind it, so it becomes the top bar and
/// everything scrolls underneath.
private struct HomeTopBar: View {
    @ObservedObject var scroll: HomeScrollProgress
    /// The top safe area inset.
    let safeTop: CGFloat

    /// Scroll distance over which the ink fades in behind the row.
    static let collapseDistance: CGFloat = 56

    var body: some View {
        let p = scroll.collapse
        ZStack(alignment: .top) {
            backing(height: safeTop + LumaTabMetrics.barBottom)
                .opacity(p)
                .allowsHitTesting(p > 0.6)
            LumaTabHeader {
                HomeWordmark()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Lumalook")
                    .accessibilityAddTraits(.isHeader)
            } trailing: {
                // White on the photo, the other tabs' grey once the bar is
                // solid.
                LumaTopBarButtons(onPhoto: 1 - p)
            }
            // A soft shadow keeps the row legible on the photo; it goes with
            // the photo.
            .shadow(color: .black.opacity(0.35 * (1 - p)), radius: 8, y: 1)
            .padding(.top, safeTop + LumaTabMetrics.top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    /// The page's ink from the top of the screen to the bar's bottom, then a
    /// short fade, so what scrolls under it dissolves rather than meeting a
    /// line.
    private func backing(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            LumaTheme.background
                .frame(height: height)
            LinearGradient(colors: [LumaTheme.background, LumaTheme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }
}

/// Fades its content out over the first part of the scroll, faster than the
/// bar fades in, so nothing on the reel shows through the bar.
private struct HomeScrollFade<Content: View>: View {
    @ObservedObject var scroll: HomeScrollProgress
    var rate: CGFloat = 1.4
    @ViewBuilder let content: Content

    var body: some View {
        content.opacity(max(0, 1 - scroll.collapse * rate))
    }
}

/// The reel runs under the status bar. At the top a soft shade keeps the
/// clock legible on the photo. Once the page scrolls, the top bar's backing
/// covers the status bar too (see HomeTopBar).
private struct HomeStatusScrim: View {
    /// The top safe area inset.
    let height: CGFloat

    var body: some View {
        LinearGradient(colors: [Color.black.opacity(0.5), Color.black.opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: height + 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}

/// The page's top edge in the scroll view's space (0 at rest, negative once
/// scrolled).
private struct HomeScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Shared chrome

/// Home's wordmark in the shared top row: Lumalook with a capital L at the
/// tabs' title size, the small mark a white frame so the yellow stays with
/// the shutter.
private struct HomeWordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.92), lineWidth: 2.4)
                .frame(width: 14, height: 14)
            Text("Lumalook")
                .font(.luma(size: 26, weight: .bold))
                .kerning(-1)
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
        }
    }
}

/// Home's section heading: sentence case at near-full white (or the quiet
/// grey line "Or start from a template"), the action a grey word.
private struct HomeSectionHeader: View {
    let title: String
    var quiet: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.luma(size: quiet ? 13 : 17, weight: quiet ? .medium : .semibold))
                .kerning(quiet ? 0 : -0.2)
                .foregroundStyle(quiet ? Color.white.opacity(0.48) : LumaTheme.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let actionTitle {
                Button { action?() } label: {
                    Text(actionTitle)
                        .font(.luma(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
        }
    }
}

/// Small helpers for frames and badges.
private enum Poster {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The small dark value badge in a frame's corner (0:12), used by the
    /// Cut to the beat posters.
    static func badge(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A captioned picture tile, the calm grid's one card: the picture fills
/// it, a soft shade at the bottom carries the caption, and a small glass tag
/// may sit in the top corner. No outline.
private struct HomeCaptionTile<Picture: View, Caption: View>: View {
    let height: CGFloat
    let badge: String?
    let badgePlay: Bool
    let badgeColour: Color
    let picture: Picture
    let caption: Caption

    static var radius: CGFloat { 15 }

    init(height: CGFloat, badge: String? = nil, badgePlay: Bool = true,
         badgeColour: Color = LumaTheme.textPrimary,
         @ViewBuilder picture: () -> Picture,
         @ViewBuilder caption: () -> Caption) {
        self.height = height
        self.badge = badge
        self.badgePlay = badgePlay
        self.badgeColour = badgeColour
        self.picture = picture()
        self.caption = caption()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            caption
                .padding(.horizontal, 12)
                .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(LumaTheme.panel)
        .overlay(alignment: .topTrailing) {
            if let badge {
                HomeBadge(text: badge, play: badgePlay, colour: badgeColour)
                    .padding(9)
            }
        }
        .clipShape(shape)
        .contentShape(shape)
    }
}

/// The small glass tag in a tile's corner: "▶ 0:12", "Video", a price.
private struct HomeBadge: View {
    let text: String
    var play: Bool = true
    var colour: Color = LumaTheme.textPrimary

    var body: some View {
        HStack(spacing: 4) {
            if play {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.luma(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.black.opacity(0.48)))
        .allowsHitTesting(false)
    }
}

/// A tile's caption: the name in white and a grey line under it.
private struct HomeTileCaption: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.luma(size: 14, weight: .semibold))
                .kerning(-0.15)
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.luma(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.66))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet glass pill (All looks, Edit a photo, Import): white at 10% with
/// white words.
private struct HomeGlassPill: View {
    let icon: String
    let title: String
    var showsIcon: Bool = true
    /// The one solid white pill on a page (first run's Edit a clip).
    var solid: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            LumaHaptics.shared.tap()
            action()
        } label: {
            HomeGlassPillLabel(icon: showsIcon ? icon : nil, title: title, solid: solid)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(title)
    }
}

private struct HomeGlassPillLabel: View {
    let icon: String?
    let title: String
    var solid: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(title)
                .font(.luma(size: 14, weight: .semibold))
                .tracking(-0.1)
                .lineLimit(1)
        }
        .foregroundStyle(solid ? Color(hex: 0x0B0C0E) : Color.white.opacity(0.92))
        .padding(.leading, icon == nil ? 15 : 12)
        .padding(.trailing, 15)
        .frame(height: 38)
        .background(Capsule().fill(solid ? Color(hex: 0xF4F5F6) : Color.white.opacity(0.1)))
        .contentShape(Capsule())
        .fixedSize()
    }
}

// MARK: - Photos

/// A bundled sample photo, optionally graded with a built-in look, cropped
/// around the subject's face (`HeroPhoto.focus`) rather than a coarse
/// alignment, so a wide box never ends up on the top of a head. Renders are
/// cached for the session, so Home does not regrade on every visit.
struct HomeGradedPhoto: View {
    let photo: HeroPhoto
    var lookName: String? = nil
    var maxDimension: CGFloat = 900
    @State private var graded: CGImage? = nil

    init(photo: HeroPhoto, lookName: String? = nil, maxDimension: CGFloat = 900) {
        self.photo = photo
        self.lookName = lookName
        self.maxDimension = maxDimension
    }

    private var cacheKey: String {
        "\(photo.rawValue)|\(lookName ?? "")|\(Int(maxDimension))"
    }

    var body: some View {
        content
            .task(id: cacheKey) { await render() }
    }

    @ViewBuilder
    private var content: some View {
        if let graded {
            HomeFocusCropImage(image: Image(decorative: graded, scale: 1),
                               pixelSize: CGSize(width: graded.width, height: graded.height),
                               focus: photo.focus)
        } else if let ui = photo.uiImage {
            HomeFocusCropImage(image: Image(uiImage: ui), pixelSize: ui.size, focus: photo.focus)
        } else {
            LumaTheme.raised
        }
    }

    private func render() async {
        let key = cacheKey
        if let hit = HomeGradeCache.images[key] {
            graded = hit
            return
        }
        guard let name = lookName,
              let recipe = MockData.looks.first(where: { $0.name == name })?.recipe else {
            graded = nil
            return
        }
        let source = photo
        let size = maxDimension
        // One grade at a time, off the shared task pool (`GradeQueue`).
        let image = await GradeQueue.home.run { () -> CGImage? in
            guard let ci = source.ciImage else { return nil }
            let state = LookState()
            state.recipe = recipe
            var settings = LookSettings()
            settings.intensity = 100
            state.settings = settings
            return LookPipeline.shared.gradedStill(ci, state: state, maxDimension: size)
        }
        guard let image else { return }
        HomeGradeCache.images[key] = image
        // A newer look may have been asked for while this one rendered (a
        // quick tap in the reel's strip): only the latest may land, or a
        // slow earlier grade would paint over it.
        if !Task.isCancelled { graded = image }
        #if DEBUG
        if size >= 1000 {
            print("[LUMA] HOMEGRADE \(key) \(Task.isCancelled ? "dropped" : "landed")")
        }
        #endif
    }
}

/// Session cache for `HomeGradedPhoto` renders. Only touched from views.
enum HomeGradeCache {
    static var images: [String: CGImage] = [:]
}

/// Fills its box with an image, keeping `focus` (unit point, from the top
/// left) as close to the centre as the edges allow.
struct HomeFocusCropImage: View {
    let image: Image
    let pixelSize: CGSize
    let focus: UnitPoint

    var body: some View {
        GeometryReader { geo in
            placed(in: geo.size)
        }
        .clipped()
        .contentShape(Rectangle())
    }

    private func placed(in box: CGSize) -> some View {
        let rect = HomeFocusCropImage.rect(pixel: pixelSize, focus: focus, box: box)
        return image
            .resizable()
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    static func rect(pixel: CGSize, focus: UnitPoint, box: CGSize) -> CGRect {
        guard pixel.width > 0, pixel.height > 0, box.width > 0, box.height > 0 else {
            return CGRect(origin: .zero, size: box)
        }
        let scale = max(box.width / pixel.width, box.height / pixel.height)
        let width = pixel.width * scale
        let height = pixel.height * scale
        let x = min(0, max(box.width - width, box.width / 2 - focus.x * width))
        let y = min(0, max(box.height - height, box.height / 2 - focus.y * height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A project's poster: its first frame, graded in its look when the look is
/// a built-in; a graded sample photo for DEBUG demo cards.
private struct HomeWorkPoster: View {
    let work: HomeWork
    let store: PersistenceStore
    var maxPixel: CGFloat = 640
    @State private var frame: CGImage?

    var body: some View {
        content
            .task(id: work.id) { await loadFrame() }
    }

    @ViewBuilder
    private var content: some View {
        if let photo = work.demoPhoto {
            HomeGradedPhoto(photo: photo, lookName: work.lookName, maxDimension: maxPixel)
        } else if let frame {
            Color.clear
                .overlay {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .contentShape(Rectangle())
        } else {
            ZStack {
                LumaTheme.raised
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
    }

    private func loadFrame() async {
        guard frame == nil, let project = work.project, let first = project.clips.first else { return }
        let url = store.clipURL(for: first)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let isImage = first.isImage ?? false
        let seconds = first.trimStart + 0.05
        let size = maxPixel
        let recipe = work.lookName.flatMap { name in
            MockData.looks.first(where: { $0.name == name })?.recipe
        }
        let settings = first.grade?.settings
        let image = await Task.detached(priority: .userInitiated) { () async -> CGImage? in
            await HomePosterFrame.render(url: url, isImage: isImage, at: seconds,
                                         maxPixel: size, recipe: recipe, settings: settings)
        }.value
        if let image { frame = image }
    }
}

/// Reads a clip's first frame (video or still) and grades it.
private enum HomePosterFrame {
    static func render(url: URL, isImage: Bool, at seconds: Double, maxPixel: CGFloat,
                       recipe: LookRecipe?, settings: LookSettings?) async -> CGImage? {
        var source: CIImage?
        if isImage {
            source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let time = CMTime(seconds: max(seconds, 0.1), preferredTimescale: 600)
            if let cg = try? await generator.image(at: time).image {
                source = CIImage(cgImage: cg)
            }
        }
        guard let source else { return nil }
        let state = LookState()
        if let recipe {
            state.recipe = recipe
            var grade = settings ?? LookSettings()
            if settings == nil { grade.intensity = 100 }
            state.settings = grade
        } else {
            var neutral = LookSettings()
            neutral.intensity = 0
            state.settings = neutral
        }
        return LookPipeline.shared.gradedStill(source, state: state, maxDimension: maxPixel)
    }
}

// MARK: - Resume row

/// The last edit as one quiet row where the reel meets the page: its poster,
/// when it was edited, and a white play button.
private struct HomeResumeRow: View {
    let work: HomeWork
    let store: PersistenceStore
    let action: () -> Void

    static let height: CGFloat = 64

    /// "Edited 2 h ago · 0:12 · 6 clips"
    private var detail: String {
        "\(HomeWork.editedLabel(work.updatedAt)) · \(Poster.duration(work.duration)) · \(work.clipsText)"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                HomeWorkPoster(work: work, store: store, maxPixel: 200)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(work.title)
                        .font(.luma(size: 15, weight: .semibold))
                        .kerning(-0.15)
                        .foregroundStyle(LumaTheme.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.luma(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.onLight)
                    .offset(x: 1)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(LumaTheme.textPrimary))
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            // Quiet glass over solid ink, so the reel never shows through.
            .background(shape.fill(Color.white.opacity(0.06)))
            .background(shape.fill(LumaTheme.background))
            .contentShape(shape)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Resume \(work.title). \(work.detail)")
    }
}

// MARK: - Quick tiles

/// Edit a clip, Edit a photo, Templates and Import LUT as four quiet tiles.
/// Shooting is the tab shutter's job, in the same place on every tab.
private struct HomeQuickTiles: View {
    let onEdit: () -> Void
    let onPhoto: () -> Void
    let onTemplates: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tile(icon: "film", title: "Edit a clip", action: onEdit)
            tile(icon: "photo", title: "Edit a photo", action: onPhoto)
            if LumaFeatures.templates {
                tile(icon: "square.on.square", title: "Templates", action: onTemplates)
            }
            LUTImportButton(onImported: nil, label: {
                HomeQuickTileLabel(icon: "cube", title: "Import LUT")
            })
            .accessibilityLabel("Import a LUT")
        }
    }

    private func tile(icon: String, title: String,
                      action: @escaping () -> Void) -> some View {
        Button {
            LumaHaptics.shared.tap()
            action()
        } label: {
            HomeQuickTileLabel(icon: icon, title: title)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(title)
    }
}

private struct HomeQuickTileLabel: View {
    let icon: String
    let title: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(height: 20)
            Text(title)
                .font(.luma(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(shape.fill(Color.white.opacity(0.055)))
        .contentShape(shape)
    }
}

// MARK: - Tonight's look

/// One signature look on the sample photo it suits best. Home's reel shows
/// four, starting from today's; the set turns over at midnight.
struct TonightsLook {
    let preset: LookPreset
    let photo: HeroPhoto
    let line: String

    /// "Neon" of "Neon Nights": every word but the last, set light.
    var light: String {
        let words = preset.title.split(separator: " ").map(String.init)
        return words.dropLast().joined(separator: " ")
    }

    /// "Nights" of "Neon Nights": the last word, set heavy.
    var heavy: String {
        let words = preset.title.split(separator: " ").map(String.init)
        return words.last ?? preset.title
    }

    private static let rotation: [(String, HeroPhoto, String)] = [
        ("Neon Nights", .neon, "Practical neon on skin"),
        ("KD2 · Golden Hour", .golden, "Warm skin, soft bokeh. Free forever"),
        ("Afrobeats Glow", .party, "Flash, braids and a packed room"),
        ("Night Drive", .drive, "Red tail-lights, deep blacks"),
        ("AG60 · London Rain", .rain, "Cool, quiet and a little faded"),
        ("CN83 · Teal & Orange", .skate, "The blockbuster split"),
        ("CN93 · Luxury Campaign", .campaign, "Rich blacks, gold highlights"),
        ("BW32 · Documentary Grit", .gig, "Hard, honest black and white"),
    ]

    /// Every look in the rotation: the reel's strip offers all of them.
    static var all: [TonightsLook] { options }

    /// The strip tile's label: the stock code, else the first word ("Neon").
    var tileCode: String {
        if let code = LookSignature.code(in: preset.name) { return code }
        return light.isEmpty ? heavy : (light.split(separator: " ").first.map(String.init) ?? light)
    }

    private static var options: [TonightsLook] {
        rotation.compactMap { entry -> TonightsLook? in
            guard let preset = MockData.looks.first(where: { $0.name == entry.0 }) else { return nil }
            return TonightsLook(preset: preset, photo: entry.1, line: entry.2)
        }
    }

    private static var fallback: TonightsLook {
        TonightsLook(preset: MockData.defaultLook, photo: .golden, line: "Tonight's look")
    }

    /// `count` looks in a row from today's place in the rotation.
    static func reel(count: Int = 3, on date: Date = Date()) -> [TonightsLook] {
        let options = self.options
        guard !options.isEmpty else { return [fallback] }
        let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .era, for: date) ?? 0
        let start = previewStart(in: options) ?? day
        let n = max(1, min(count, options.count))
        return (0..<n).map { options[(start + $0) % options.count] }
    }

    /// DEBUG: LUMA_SEED_REELHOLD=<look> ("Neon", "CN93" or a full name) starts
    /// the reel on that look, so a screenshot can pick its person.
    private static func previewStart(in options: [TonightsLook]) -> Int? {
        #if DEBUG
        guard let wanted = ProcessInfo.processInfo.environment["LUMA_SEED_REELHOLD"],
              wanted != "1", !wanted.isEmpty else { return nil }
        return options.firstIndex { $0.preset.name == wanted || $0.tileCode == wanted }
        #else
        return nil
        #endif
    }

    /// Changes at midnight; the same all day on every screen.
    static var today: TonightsLook {
        reel(count: 1).first ?? fallback
    }
}

/// AF1: tonight's looks on real people, edge to edge, with thin story bars
/// under the top bar and nothing drawn over the picture itself; the picture
/// fades into the page, where Tonight's look, its Try button and the strip
/// sit. The strip regrades the frame on screen: picking a look pauses the
/// reel, and tapping the picture (or the picked look again) lets it cycle
/// on. With Reduce Motion on it neither cycles nor zooms; taps still move
/// between looks.
private struct ViewfinderReel: View {
    let looks: [TonightsLook]
    let stripLooks: [TonightsLook]
    @Binding var index: Int
    @Binding var pick: String?
    let packLine: (TonightsLook) -> String
    let isFirstRun: Bool
    let safeTop: CGFloat
    let height: CGFloat
    let reduceMotion: Bool
    /// Fades the story bars as they scroll up under the pinned top bar.
    let scroll: HomeScrollProgress
    /// Try this look: the shown look, in the camera.
    let onTry: () -> Void
    let onAllLooks: () -> Void
    /// First run: Edit a clip and Edit a photo.
    let onEdit: () -> Void
    let onPhoto: () -> Void

    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue
    @State private var started = Date()

    static let dwell: Double = 4.2

    private var safeIndex: Int {
        looks.isEmpty ? 0 : min(index, looks.count - 1)
    }

    private var base: TonightsLook? {
        looks.isEmpty ? nil : looks[safeIndex]
    }

    private var picked: TonightsLook? {
        guard let pick else { return nil }
        return stripLooks.first { $0.preset.name == pick }
    }

    /// The reel's photo in the picked look, else the reel's own look.
    private var shown: TonightsLook? {
        guard let base else { return nil }
        guard let picked else { return base }
        return TonightsLook(preset: picked.preset, photo: base.photo, line: picked.line)
    }

    /// Names in colour (the default), or white with a dot.
    private var namesInColour: Bool {
        (LumaNameStyle(rawValue: namesRaw) ?? .colour) == .colour
    }

    private var isPaused: Bool { reduceMotion || pick != nil || Self.heldForPreview }

    /// LUMA_SEED_REELHOLD holds the reel on its first look, so a simulator
    /// screenshot never lands mid-crossfade between two slides. "1" keeps
    /// today's first look; a look name or code starts on that look.
    private static let heldForPreview: Bool = {
        #if DEBUG
        return !(ProcessInfo.processInfo.environment["LUMA_SEED_REELHOLD"] ?? "").isEmpty
        #else
        return false
        #endif
    }()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Clipped before it stretches, so a pull grows the picture
            // upwards into the space above the page.
            HomeReelStretch(pull: scroll.pull, height: height) {
                ZStack {
                    photos
                    scrim
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
            }
            copy
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay(alignment: .top) { bars }
        .task(id: "\(reduceMotion)-\(pick ?? "")") { await cycle() }
        .onAppear { seedPick() }
        .accessibilityElement(children: .contain)
    }

    // MARK: Picture

    private var photos: some View {
        ZStack {
            ForEach(Array(looks.enumerated()), id: \.offset) { item in
                reelPhoto(item.element, at: item.offset)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tapPicture() }
        .accessibilityHidden(true)
    }

    private func reelPhoto(_ look: TonightsLook, at position: Int) -> some View {
        let isOn = position == safeIndex
        let lookName = (isOn ? picked?.preset.name : nil) ?? look.preset.name
        return HomeGradedPhoto(photo: look.photo, lookName: lookName, maxDimension: 1100)
            .scaleEffect(isOn || reduceMotion ? 1 : 1.07)
            .animation(reduceMotion ? nil : .easeOut(duration: 3.4), value: safeIndex)
            .opacity(isOn ? 0.9 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: safeIndex)
    }

    /// The mock's fade: ink under the status bar, clear across the face,
    /// then down into the page's ink, so the reel fades into the page with
    /// no edge.
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: LumaTheme.ink.opacity(0.5), location: 0),
            .init(color: LumaTheme.ink.opacity(0), location: 0.22),
            .init(color: LumaTheme.ink.opacity(0), location: 0.40),
            .init(color: LumaTheme.ink.opacity(0.7), location: 0.66),
            .init(color: LumaTheme.ink, location: 0.92),
            .init(color: LumaTheme.ink, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }

    // MARK: Story bars

    /// Thin story bars just under the pinned top row (HomeView draws the row
    /// above the page). They fade as the page scrolls up under the bar.
    private var bars: some View {
        HomeScrollFade(scroll: scroll, rate: 3) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
                ReelBars(count: looks.count, index: safeIndex, progress: progress(at: context.date))
            }
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
        .padding(.horizontal, 20)
        .padding(.top, safeTop + LumaTabMetrics.barBottom)
    }

    // MARK: Copy

    @ViewBuilder
    private var copy: some View {
        if let look = shown {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    kicker(look)
                    headline(look)
                        .padding(.top, 8)
                    Text(meta(look))
                        .font(.luma(size: isFirstRun ? 14 : 13.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.top, isFirstRun ? 8 : 6)
                }
                .padding(.horizontal, 20)
                .id("\(safeIndex)-\(pick ?? "")")
                .transition(.opacity)
                .allowsHitTesting(false)
                pills(look)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                if !isFirstRun {
                    strip
                        .padding(.top, 20)
                }
            }
            .padding(.bottom, isFirstRun ? 18 : 12)
        }
    }

    /// "• TONIGHT'S LOOK", the dot in the look's colour. Once a look is
    /// picked, how to get back to the reel.
    private func kicker(_ look: TonightsLook) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(look.preset.signature)
                .frame(width: 7, height: 7)
            Text(kickerText(look))
                .font(.luma(size: 11, weight: .bold))
                .tracking(1.3)
                .textCase(.uppercase)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func kickerText(_ look: TonightsLook) -> String {
        if pick != nil { return "Your pick · tap the picture to go back" }
        if isFirstRun {
            return "Tonight's look · " + look.preset.name.replacingOccurrences(of: " · ", with: " ")
        }
        return "Tonight's look"
    }

    /// The look's name as the headline, a light word and a bold word, the
    /// bold one in the look's colour. The first run welcomes instead.
    @ViewBuilder
    private func headline(_ look: TonightsLook) -> some View {
        if isFirstRun {
            VStack(alignment: .leading, spacing: -4) {
                Text("Welcome to")
                    .font(.luma(size: 40, weight: .light))
                Text("Lumalook")
                    .font(.luma(size: 40, weight: .bold))
            }
            .tracking(LumaType.tracking(for: 40))
            .foregroundStyle(LumaTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } else {
            lookTitle(look)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func lookTitle(_ look: TonightsLook) -> Text {
        let colour = namesInColour ? look.preset.signature : LumaTheme.textPrimary
        let heavy = Text(verbatim: look.heavy)
            .font(.luma(size: 40, weight: .bold))
            .foregroundColor(colour)
        let line: Text
        if look.light.isEmpty {
            line = heavy
        } else {
            let light = Text(verbatim: look.light + " ")
                .font(.luma(size: 40, weight: .light))
                .foregroundColor(LumaTheme.textPrimary)
            // Interpolation, not `+`, which the iOS 26 SDK deprecates.
            line = Text("\(light)\(heavy)")
        }
        return line.tracking(LumaType.tracking(for: 40))
    }

    /// "KD2 · Free · Signature · warm skin, soft bokeh", or the first run's
    /// one line on what to do.
    private func meta(_ look: TonightsLook) -> String {
        if isFirstRun { return "Shoot with a look, or grade a clip you already have." }
        var parts: [String] = []
        if let code = LookSignature.code(in: look.preset.name) { parts.append(code) }
        parts.append(packLine(look))
        let line = look.line
        if let first = line.first {
            parts.append(first.lowercased() + String(line.dropFirst()))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Try this look in the look's own colour and a quiet All looks; on the
    /// first run, Edit a clip (the page's main action), Edit a photo and
    /// Import.
    @ViewBuilder
    private func pills(_ look: TonightsLook) -> some View {
        if isFirstRun {
            ViewThatFits(in: .horizontal) {
                firstRunPills(icons: true)
                firstRunPills(icons: false)
            }
        } else {
            HStack(spacing: 8) {
                LumaColourButton(title: "Try this look",
                                 colour: look.preset.signature,
                                 icon: "wand.and.stars",
                                 height: 38,
                                 action: onTry)
                    .fixedSize()
                    .accessibilityLabel("Try \(look.preset.title) in the camera")
                HomeGlassPill(icon: "square.grid.2x2", title: "All looks", action: onAllLooks)
            }
        }
    }

    private func firstRunPills(icons: Bool) -> some View {
        HStack(spacing: 8) {
            // The one solid white pill, as in the mock and on Projects: the
            // yellow stays with the tab shutter.
            HomeGlassPill(icon: "plus", title: "Edit a clip", showsIcon: icons, solid: true, action: onEdit)
            HomeGlassPill(icon: "photo", title: "Edit a photo", showsIcon: icons, action: onPhoto)
            LUTImportButton(onImported: nil, label: {
                HomeGlassPillLabel(icon: icons ? "cube" : nil, title: "Import")
            })
            .accessibilityLabel("Import a LUT")
        }
    }

    // MARK: Strip

    /// The strip's swatches all grade one close face, so each look reads on
    /// the same skin and the strip renders once rather than on every turn of
    /// the reel. Tapping one regrades the picture above.
    private static let swatchPhoto: HeroPhoto = .golden

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(stripLooks, id: \.preset.name) { entry in
                    tile(entry)
                }
            }
            .padding(.horizontal, 20)
            // Room for the picked ring's glow.
            .padding(.vertical, 4)
        }
    }

    /// A swatch, its code under it in the look's colour; the picked one
    /// wears the pale ring, same as the camera.
    private func tile(_ entry: TonightsLook) -> some View {
        let isOn = (pick ?? base?.preset.name) == entry.preset.name
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { choose(entry) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HomeGradedPhoto(photo: Self.swatchPhoto, lookName: entry.preset.name, maxDimension: 240)
                    .frame(width: 54, height: 67.5)
                    .clipShape(shape)
                    .pickedRing(isOn, cornerRadius: 12)
                LookNameText(entry.tileCode, colour: entry.preset.signature, size: 10.5)
                    .minimumScaleFactor(0.7)
                    .frame(width: 54, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Try \(entry.preset.title) on this picture")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Behaviour

    /// Picks a look, or lets the reel go on when it is tapped again.
    private func choose(_ entry: TonightsLook) {
        LumaHaptics.shared.tap()
        withAnimation(.easeOut(duration: 0.2)) {
            pick = pick == entry.preset.name ? nil : entry.preset.name
        }
    }

    /// With a look picked, back to the reel; otherwise the next look.
    private func tapPicture() {
        LumaHaptics.shared.tap()
        if pick != nil {
            withAnimation(.easeOut(duration: 0.2)) { pick = nil }
        } else {
            advance()
        }
    }

    private func progress(at date: Date) -> Double {
        if isPaused { return 1 }
        return min(1, max(0, date.timeIntervalSince(started) / Self.dwell))
    }

    private func advance() {
        guard looks.count > 1 else { return }
        let next = (safeIndex + 1) % looks.count
        if reduceMotion {
            index = next
        } else {
            withAnimation(.easeInOut(duration: 0.5)) { index = next }
        }
        started = Date()
    }

    /// Advances every `dwell` seconds while Home is on screen and nothing is
    /// picked. A tap resets the clock, so the loop re-reads `started` after
    /// every sleep.
    private func cycle() async {
        started = Date()
        guard !isPaused, looks.count > 1 else { return }
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= Self.dwell {
                advance()
                continue
            }
            let wait = max(0.05, Self.dwell - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// LUMA_SEED_HOMEPICK=<look name or code> shows a picked look in the
    /// simulator preview.
    private func seedPick() {
        #if DEBUG
        guard pick == nil,
              let seed = ProcessInfo.processInfo.environment["LUMA_SEED_HOMEPICK"],
              let entry = stripLooks.first(where: { $0.preset.name == seed || $0.tileCode == seed })
        else { return }
        pick = entry.preset.name
        #endif
    }
}

/// Story-style progress: thin lines, done ones full, the current one filling,
/// the rest dim.
private struct ReelBars: View {
    let count: Int
    let index: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(count, 1), id: \.self) { position in
                Capsule()
                    .fill(Color.white.opacity(0.26))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .scaleEffect(x: CGFloat(max(fill(position), 0.0001)), y: 1, anchor: .leading)
                    }
                    .frame(height: 2.5)
            }
        }
    }

    private func fill(_ position: Int) -> Double {
        if position < index { return 1 }
        if position == index { return progress }
        return 0
    }
}

// MARK: - Cut to the beat

private struct BeatTemplateRail: View {
    let templates: [VideoTemplate]
    let onPick: (VideoTemplate) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(templates.enumerated()), id: \.element.id) { item in
                    BeatTemplateCard(template: item.element,
                                     photo: BeatTemplateCard.posterPhoto(for: item.element, index: item.offset),
                                     seed: item.offset) {
                        onPick(item.element)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Poster, duration badge, play glyph, beat bars in the look's colour, then
/// the name and "6 clips · 112 BPM".
private struct BeatTemplateCard: View {
    let template: VideoTemplate
    let photo: HeroPhoto
    let seed: Int
    let action: () -> Void

    private static let width: CGFloat = 132
    private static let height: CGFloat = 226
    private static let radius: CGFloat = 15
    private static let fallbackPhotos: [HeroPhoto] = [.party, .gig, .skate, .rain]

    static func posterPhoto(for template: VideoTemplate, index: Int) -> HeroPhoto {
        if let raw = template.poster, let photo = HeroPhoto(rawValue: raw) { return photo }
        return fallbackPhotos[index % fallbackPhotos.count]
    }

    private var colour: Color {
        LookSignature.colour(forLookNamed: template.lookName ?? "")
    }

    private var detail: String {
        let clips = "\(template.clipCount) \(template.clipCount == 1 ? "clip" : "clips")"
        guard let bpm = template.bpm else { return clips }
        return "\(clips) · \(bpm) BPM"
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                poster
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.luma(size: 14, weight: .semibold))
                        .kerning(-0.2)
                        .foregroundStyle(LumaTheme.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.luma(size: 12))
                        .foregroundStyle(LumaTheme.textMuted)
                        .lineLimit(1)
                }
                .frame(width: Self.width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(template.name), \(detail). Pick clips")
    }

    private var poster: some View {
        ZStack {
            HomeGradedPhoto(photo: photo, lookName: template.lookName, maxDimension: 560)
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: UnitPoint(x: 0.5, y: 0.55), endPoint: .bottom)
            playGlyph
        }
        .frame(width: Self.width, height: Self.height)
        .overlay(alignment: .topLeading) {
            Poster.badge(Poster.duration(template.totalDuration)).padding(8)
        }
        .overlay(alignment: .bottom) {
            if template.isBeatCut {
                BeatBars(levels: BeatPattern.levels(for: template, seed: seed), colour: colour)
                    .frame(height: 20)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(LumaTheme.edge, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    }

    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .offset(x: 1)
            .frame(width: 38, height: 38)
            .background(Color.black.opacity(0.5), in: Circle())
            .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: 1))
    }
}

private struct BeatBars: View {
    let levels: [CGFloat]
    let colour: Color

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(levels.enumerated()), id: \.offset) { item in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(colour.opacity(0.92))
                        .frame(height: max(2, geo.size.height * item.element))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// Little beat bars: a lively pattern, with full-height bars where the
/// template cuts, so each poster shows its own rhythm.
private enum BeatPattern {
    static func levels(for template: VideoTemplate, seed: Int, count: Int = 16) -> [CGFloat] {
        var out: [CGFloat] = []
        for bar in 0..<count {
            let wave = abs(sin(Double(bar) * 1.7 + Double(seed)))
            out.append(CGFloat(0.25 + 0.7 * wave))
        }
        let total = template.totalDuration
        guard total > 0 else { return out }
        var elapsed = 0.0
        for slot in template.slots.dropLast() {
            elapsed += slot.duration
            let bar = Int((elapsed / total * Double(count)).rounded())
            if bar >= 0 && bar < count { out[bar] = 1 }
        }
        return out
    }
}

// MARK: - Templates

/// The plain templates as a captioned grid: three across on a returning
/// Home, two across on the first run.
private struct HomeTemplateGrid: View {
    let templates: [VideoTemplate]
    let columns: Int
    let tileHeight: CGFloat
    let onPick: (VideoTemplate) -> Void

    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, columns))
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 8) {
            ForEach(Array(templates.enumerated()), id: \.element.id) { item in
                HomeTemplateTile(template: item.element, index: item.offset, height: tileHeight) {
                    onPick(item.element)
                }
            }
        }
    }
}

/// A template's poster in its look, its runtime in the corner, then its name
/// and "6 clips".
private struct HomeTemplateTile: View {
    let template: VideoTemplate
    let index: Int
    let height: CGFloat
    let action: () -> Void

    private var clipsText: String {
        "\(template.clipCount) \(template.clipCount == 1 ? "clip" : "clips")"
    }

    var body: some View {
        Button(action: action) {
            HomeCaptionTile(height: height, badge: Poster.duration(template.totalDuration)) {
                HomeGradedPhoto(photo: BeatTemplateCard.posterPhoto(for: template, index: index),
                                lookName: template.lookName, maxDimension: 480)
            } caption: {
                HomeTileCaption(title: template.name, detail: clipsText)
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(template.name), \(clipsText). Pick clips")
    }
}

// MARK: - Looks

private enum HomeLooksMode: String, CaseIterable {
    case forYou = "For you"
    case recents = "Recents"

    /// The text tab's word.
    var title: String {
        switch self {
        case .forYou: return "Looks for you"
        case .recents: return "Recents"
        }
    }
}

/// "Looks for you" | "Recents" as text tabs (the picked one white, the
/// other grey) and "All looks". Before any look has been used there is
/// nothing recent, so it is just "Looks for you".
private struct HomeLooksHeader: View {
    @Binding var mode: HomeLooksMode
    let showsSwitch: Bool
    let onAll: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if showsSwitch {
                ForEach(HomeLooksMode.allCases, id: \.self) { option in
                    tab(option)
                }
            } else {
                Text(HomeLooksMode.forYou.title)
                    .font(.luma(size: 17, weight: .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(LumaTheme.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            Button(action: onAll) {
                Text("All looks")
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
    }

    private func tab(_ option: HomeLooksMode) -> some View {
        let isOn = mode == option
        return Button {
            mode = option
            LumaHaptics.shared.tap()
        } label: {
            Text(option.title)
                .font(.luma(size: 17, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(isOn ? LumaTheme.textPrimary : LumaTheme.textMuted)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Looks as a two-column captioned grid, each on its own person.
private struct HomeLookGrid: View {
    let looks: [LibraryLook]
    let photos: [String: HeroPhoto]
    let images: [String: CGImage]
    let isPro: Bool
    let isCurrent: (LibraryLook) -> Bool
    let onPick: (LibraryLook) -> Void
    let onStar: (LibraryLook) -> Void

    private var gridItems: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 8) {
            ForEach(looks) { look in
                HomeLookTile(look: look,
                             photo: photos[look.id] ?? .golden,
                             image: images[look.id],
                             isPro: isPro,
                             isOn: isCurrent(look),
                             onStar: { onStar(look) },
                             action: { onPick(look) })
            }
        }
    }
}

/// A look on its person: the name in the look's colour, then its code in
/// that colour and where it comes from. A quiet star favourites it; the
/// look on the grade wears the pale ring.
private struct HomeLookTile: View {
    let look: LibraryLook
    let photo: HeroPhoto
    let image: CGImage?
    let isPro: Bool
    let isOn: Bool
    let onStar: () -> Void
    let action: () -> Void

    private static let height: CGFloat = 210

    private var code: String? { LookSignature.code(in: look.name) }

    private var title: String {
        let title = LookSignature.title(in: look.name)
        return title.isEmpty ? look.name : title
    }

    private var isLocked: Bool {
        if case .builtIn(let preset) = look.source { return preset.isPremium && !isPro }
        return false
    }

    /// "Pro", "Free", the pack's name, "Imported" or "Your look".
    private var origin: String {
        switch look.source {
        case .builtIn(let preset): return preset.isPremium ? "Pro" : "Free"
        case .lut: return look.packName ?? "Imported"
        case .saved: return "Your look"
        }
    }

    var body: some View {
        Button(action: action) {
            HomeCaptionTile(height: Self.height) {
                picture
            } caption: {
                caption
            }
            .pickedRing(isOn, cornerRadius: 15)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(look.name). Try on a clip")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            starButton.padding(9)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            LookNameText(title, colour: look.signature, size: 14)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8.5, weight: .bold))
                }
                if let code {
                    LookNameText(code, colour: look.signature, size: 11.5)
                }
                Text(code == nil ? origin : "· " + origin)
                    .font(.luma(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.66))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var starButton: some View {
        Button {
            onStar()
            LumaHaptics.shared.tap()
        } label: {
            Image(systemName: look.isFavourite ? "star.fill" : "star")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(0.42)))
                .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(look.isFavourite ? "Remove \(title) from favourites" : "Add \(title) to favourites")
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            HomeFocusCropImage(image: Image(decorative: image, scale: 1),
                               pixelSize: CGSize(width: image.width, height: image.height),
                               focus: photo.focus)
        } else {
            // The plain photo holds the frame until the grade lands.
            HomeGradedPhoto(photo: photo)
        }
    }
}

/// Which person each look is shown on: a look's own photo when its name says
/// which (Golden Hour on the golden portrait, London Rain on the bus), else
/// the next photo none of the last three tiles used.
private enum HomeLookPhotos {
    private static let keywords: [(String, HeroPhoto)] = [
        ("golden", .golden), ("neon", .neon), ("night drive", .drive), ("drive", .drive),
        ("london rain", .rain), ("afrobeats", .party), ("teal", .skate),
        ("cine negative", .gig), ("luxury", .campaign), ("clean neutral", .bridge),
        ("documentary", .rain), ("grit", .rain),
    ]

    static func assign(_ looks: [LibraryLook]) -> [String: HeroPhoto] {
        let all = HeroPhoto.allCases
        var out: [String: HeroPhoto] = [:]
        var recent: [HeroPhoto] = []
        var cursor = 0
        for look in looks where out[look.id] == nil {
            let lower = look.name.lowercased()
            var chosen: HeroPhoto? = nil
            for (word, photo) in keywords where lower.contains(word) {
                chosen = photo
                break
            }
            if chosen == nil {
                for _ in 0..<all.count {
                    let candidate = all[cursor % all.count]
                    cursor += 1
                    if !recent.contains(candidate) {
                        chosen = candidate
                        break
                    }
                }
            }
            let photo = chosen ?? .golden
            out[look.id] = photo
            recent.append(photo)
            if recent.count > 3 { recent.removeFirst() }
        }
        return out
    }
}

private func homeScaled(_ image: CIImage, longest: CGFloat) -> CIImage {
    let current = max(image.extent.width, image.extent.height)
    guard current > longest, current > 0 else { return image }
    let scale = longest / current
    return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
}

/// Grades every look tile on its own photo through the real pipeline:
/// built-ins by recipe, LUTs by cube, saved looks by recipe, settings and
/// cube. Finished tiles are cached for the session.
@MainActor
private final class HomeLookTileRender: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var task: Task<Void, Never>?
    private static var cache: [String: CGImage] = [:]

    private struct Job {
        let id: String
        let key: String
        let photo: HeroPhoto
        let recipe: LookRecipe?
        let settings: LookSettings
        let lutURL: URL?
    }

    func render(_ looks: [LibraryLook], photos: [String: HeroPhoto],
                luts: [LUTFile], fileURL: (LUTFile) -> URL) {
        var full = LookSettings()
        full.intensity = 100
        var ready: [String: CGImage] = [:]
        var jobs: [Job] = []
        var queued = Set<String>()
        for look in looks {
            let photo = photos[look.id] ?? .golden
            let key = look.id + "|" + photo.rawValue
            if let hit = HomeLookTileRender.cache[key] {
                ready[look.id] = hit
                continue
            }
            if queued.contains(key) { continue }
            queued.insert(key)
            switch look.source {
            case .builtIn(let preset):
                jobs.append(Job(id: look.id, key: key, photo: photo,
                                recipe: preset.recipe, settings: full, lutURL: nil))
            case .lut(let file):
                jobs.append(Job(id: look.id, key: key, photo: photo,
                                recipe: nil, settings: full, lutURL: fileURL(file)))
            case .saved(let saved):
                let recipe = MockData.looks.first(where: { $0.name == saved.baseLookName })?.recipe
                var url: URL? = nil
                if let lutID = saved.lutID, let file = luts.first(where: { $0.id == lutID }) {
                    url = fileURL(file)
                }
                jobs.append(Job(id: look.id, key: key, photo: photo,
                                recipe: recipe, settings: saved.settings, lutURL: url))
            }
        }
        images = ready
        task?.cancel()
        guard !jobs.isEmpty else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            for job in jobs {
                if Task.isCancelled { return }
                // Each grade runs off the shared task pool (`GradeQueue`).
                let graded = await GradeQueue.tiles.run { () -> CGImage? in
                    guard let photo = job.photo.ciImage else { return nil }
                    let source = homeScaled(photo, longest: 720)
                    let state = LookState()
                    if let recipe = job.recipe { state.recipe = recipe }
                    state.settings = job.settings
                    if let url = job.lutURL {
                        guard let lut = try? LookPipeline.shared.loadLUT(at: url) else { return nil }
                        state.lut = lut
                    }
                    return LookPipeline.shared.gradedStill(source, state: state, maxDimension: 420)
                }
                guard let cg = graded else { continue }
                await MainActor.run {
                    HomeLookTileRender.cache[job.key] = cg
                    self?.images[job.id] = cg
                }
            }
        }
    }
}

// MARK: - Continue editing

/// Your other edits and saved grades as a two-column captioned grid.
private struct HomeContinueGrid: View {
    let works: [HomeWork]
    let sessions: [GradeSession]
    let store: PersistenceStore
    let onOpen: (HomeWork) -> Void

    private var gridItems: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 8) {
            ForEach(works) { work in
                HomeWorkTile(work: work, store: store) { onOpen(work) }
            }
            // Saved grades are recents too; the Video or Photo tag keeps
            // them from reading as projects.
            ForEach(sessions) { session in
                GradeSessionTile(session: session)
            }
        }
    }
}

/// An edit: its first frame, its runtime in the corner, its title, then
/// "4 clips · KD2 Golden Hour" with the look in its colour.
private struct HomeWorkTile: View {
    let work: HomeWork
    let store: PersistenceStore
    let action: () -> Void

    static let height: CGFloat = 220

    var body: some View {
        Button(action: action) {
            HomeCaptionTile(height: Self.height, badge: Poster.duration(work.duration)) {
                HomeWorkPoster(work: work, store: store, maxPixel: 480)
            } caption: {
                caption
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(work.title). \(work.shortDetail)")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(work.title)
                .font(.luma(size: 14, weight: .semibold))
                .kerning(-0.15)
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(work.lookName == nil ? work.clipsText : work.clipsText + " ·")
                    .font(.luma(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let name = work.lookName {
                    LookNameText(name.replacingOccurrences(of: " · ", with: " "),
                                 colour: work.signature, size: 11.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A saved Apply-a-Look session: its real media frame and a Video or Photo
/// tag; a tap restores the exact grade.
private struct GradeSessionTile: View {
    @EnvironmentObject private var app: AppModel
    let session: GradeSession
    @State private var thumb: CGImage?

    private var title: String {
        let title = LookSignature.title(in: session.baseLookName)
        return title.isEmpty ? "Your grade" : title
    }

    private var detail: String {
        "Grade · " + session.updatedAt.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        Button {
            app.restoreGradeSession(session)
            LumaHaptics.shared.tap()
        } label: {
            HomeCaptionTile(height: HomeWorkTile.height,
                            badge: session.isVideo ? "Video" : "Photo",
                            badgePlay: false) {
                picture
            } caption: {
                VStack(alignment: .leading, spacing: 2) {
                    LookNameText(title, colour: LookSignature.colour(forLookNamed: session.baseLookName), size: 14)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .font(.luma(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.66))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(title). \(detail)")
        .task {
            guard thumb == nil else { return }
            let url = app.store.sessionMediaURL(session)
            if session.isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 420, height: 420)
                thumb = try? await generator.image(
                    at: CMTime(seconds: 0.05, preferredTimescale: 600)).image
            } else if let ci = CIImage(contentsOf: url) {
                let scale = min(1, 420 / max(ci.extent.width, ci.extent.height))
                let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                thumb = LookPipeline.shared.renderCGImage(from: scaled)
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let thumb {
            Color.clear
                .overlay {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else {
            LumaTheme.surfaceStrong
        }
    }
}

// MARK: - Pack spotlight

/// The spotlight pack as one wide captioned tile: its cover in one of its
/// looks, the pack's name in the pack's own colour, its looks and character,
/// and the small glass tag (a paid price takes the pack's colour). The whole
/// tile opens the pack page; packs live in Looks now.
private struct PackSpotlight: View {
    let pack: LookPack
    let detail: String
    let tag: String?
    /// A paid price takes the pack's colour (white with Names set to Dot).
    let tagIsPaid: Bool
    let action: () -> Void
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue

    private static let height: CGFloat = 232

    private var tagColour: Color {
        let inColour = (LumaNameStyle(rawValue: namesRaw) ?? .colour) == .colour
        return tagIsPaid && inColour ? pack.colour : LumaTheme.textPrimary
    }

    private var hasNightLooks: Bool {
        pack.looks.contains { $0.name.contains("Afrobeats Glow") }
    }

    private var coverPhoto: HeroPhoto { hasNightLooks ? .party : pack.photo }

    private var coverLook: String? {
        hasNightLooks ? "Afrobeats Glow" : pack.looks.first?.name
    }

    var body: some View {
        Button(action: action) {
            HomeCaptionTile(height: Self.height, badge: tag, badgePlay: false, badgeColour: tagColour) {
                HomeGradedPhoto(photo: coverPhoto, lookName: coverLook, maxDimension: 900)
            } caption: {
                caption
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(pack.name). \(detail). See the pack")
    }

    private var caption: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                LookNameText(pack.name, colour: pack.colour, size: 24, weight: .bold)
                    .minimumScaleFactor(0.7)
                Text(detail)
                    .font(.luma(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            HomeGlassPillLabel(icon: nil, title: "See the pack")
        }
    }
}

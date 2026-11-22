import SwiftUI
import AVFoundation
import CoreImage

/// Night Lab Home, "AF1 Viewfinder reel": direction A's edge-to-edge reel of
/// tonight's looks wearing direction F's viewfinder (corner brackets, a
/// thirds grid and a look strip). Tapping a look in the strip pauses the reel
/// and regrades whoever is on screen; tapping the picture goes back to the
/// reel.
///
/// Top to bottom: the reel (story bars, greeting, search and avatar on it),
/// the Resume pill straddling its bottom edge, Shoot and Edit a clip with the
/// quick starts, Cut to the beat templates, Looks (For you | Recents),
/// Continue editing, and the pack spotlight.
///
/// First run (no projects): "Welcome to lumalook" on the reel, no Resume pill
/// and no Continue editing.
///
/// The avatar opens You; there is no crown or gear here any more. The Store
/// is folded into Looks, so Home links to the pack page and the Looks tab,
/// never to the old Store tab.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var lookTiles = HomeLookTileRender()
    @State private var looksMode: HomeLooksMode = .forYou
    /// Which of tonight's three looks the reel is on.
    @State private var reelIndex = 0
    /// A look picked in the reel's strip (preset name). It pauses the reel
    /// and regrades the frame on screen; nil lets the reel cycle.
    @State private var reelPick: String? = nil
    /// Scrolled off the top: the status bar backing turns solid.
    @State private var scrolled = false

    /// Scroll target for the "Templates" quick start.
    static let beatAnchor = "home.cutToTheBeat"
    private static let scrollSpace = "home.scroll"

    /// About three quarters of the screen, like the mock.
    static func reelHeight(screen: CGFloat) -> CGFloat {
        min(720, max(560, (screen * 0.74).rounded()))
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let reelHeight = HomeView.reelHeight(
                screen: geo.size.height + safeTop + geo.safeAreaInsets.bottom)
            ZStack(alignment: .top) {
                LumaTheme.background.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        page(safeTop: safeTop, reelHeight: reelHeight, scrollToBeat: {
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
                }
                HomeStatusScrim(solid: scrolled, height: safeTop)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onPreferenceChange(HomeScrollOffsetKey.self) { offset in
            let past = offset < -12
            if past != scrolled { scrolled = past }
        }
        .onAppear { renderLookTiles() }
        .onChange(of: tileStamp) { _, _ in renderLookTiles() }
    }

    // MARK: Page

    @ViewBuilder
    private func page(safeTop: CGFloat, reelHeight: CGFloat,
                      scrollToBeat: @escaping () -> Void) -> some View {
        let works = self.works
        let resume = works.first
        VStack(alignment: .leading, spacing: 0) {
            viewfinderReel(isFirstRun: works.isEmpty, safeTop: safeTop, height: reelHeight,
                           pillRoom: resume == nil ? 0 : HomeResumePill.overlap)
            if let resume {
                // Straddles the reel's bottom edge (later siblings draw on top).
                HomeResumePill(work: resume, store: app.store) { open(resume) }
                    .padding(.horizontal, 12)
                    .padding(.top, -HomeResumePill.overlap)
            }
            HomeShootRow(onShoot: { shoot(with: shownLook) },
                         onEdit: { newVideo() },
                         onPhoto: { newPhoto() },
                         onTemplates: scrollToBeat)
                .padding(.horizontal, 12)
                .padding(.top, resume == nil ? 4 : 12)

            beatSection
            looksSection
            continueSection(Array(works.dropFirst().prefix(8)))
            packSection
        }
    }

    private func viewfinderReel(isFirstRun: Bool, safeTop: CGFloat, height: CGFloat,
                                pillRoom: CGFloat) -> some View {
        ViewfinderReel(looks: reelLooks,
                       stripLooks: TonightsLook.all,
                       index: $reelIndex,
                       pick: $reelPick,
                       packLine: { packLine(for: $0) },
                       isFirstRun: isFirstRun,
                       safeTop: safeTop,
                       height: height,
                       pillRoom: pillRoom,
                       reduceMotion: reduceMotion,
                       onSearch: { openLooks() },
                       onAvatar: { openYou() })
    }

    private var reelLooks: [TonightsLook] { TonightsLook.reel() }

    /// What the reel's frame is wearing right now: the look picked in the
    /// strip, else the reel's own. Shoot takes this look to the camera.
    private var shownLook: TonightsLook {
        let looks = reelLooks
        let base = looks.isEmpty ? TonightsLook.today : looks[min(reelIndex, looks.count - 1)]
        guard let name = reelPick,
              let picked = TonightsLook.all.first(where: { $0.preset.name == name }) else { return base }
        return TonightsLook(preset: picked.preset, photo: base.photo, line: picked.line)
    }

    @ViewBuilder
    private var beatSection: some View {
        let templates = beatTemplates
        if !templates.isEmpty {
            HomeSectionHeader(title: "Cut to the beat")
                .padding(.horizontal, 16)
                .padding(.top, 30)
                .id(HomeView.beatAnchor)
            Spacer(minLength: 0).frame(height: 12)
            BeatTemplateRail(templates: templates) { startTemplate($0) }
        }
    }

    @ViewBuilder
    private var looksSection: some View {
        let recents = recentLooks
        let showsSwitch = !recents.isEmpty
        let mode: HomeLooksMode = showsSwitch ? looksMode : .forYou
        let looks = mode == .recents ? recents : forYouLooks
        HomeLooksHeader(mode: $looksMode, showsSwitch: showsSwitch) { openLooks() }
            .padding(.horizontal, 16)
            .padding(.top, 30)
        Spacer(minLength: 0).frame(height: 12)
        HomeLookRail(looks: looks,
                     photos: lookPhotos,
                     images: lookTiles.images,
                     isCurrent: { app.isCurrent($0) },
                     onPick: { tryOnLook($0) })
    }

    @ViewBuilder
    private func continueSection(_ others: [HomeWork]) -> some View {
        let sessions = Array(app.store.gradeSessions.prefix(3))
        if !others.isEmpty || !sessions.isEmpty {
            HomeSectionHeader(title: "Continue editing", actionTitle: "All") {
                openProjects()
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)
            Spacer(minLength: 0).frame(height: 12)
            ContinueRail(works: others, sessions: sessions, store: app.store) { open($0) }
        }
    }

    @ViewBuilder
    private var packSection: some View {
        if let pack = spotlightPack {
            PackSpotlight(pack: pack,
                          kicker: packKicker(pack),
                          line: packCopy(pack)) { openPack(pack) }
                .padding(.horizontal, 12)
                .padding(.top, 30)
        }
    }

    // MARK: Data

    /// Projects, newest first. The first one is the Resume card.
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

    private var beatTemplates: [VideoTemplate] {
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

    /// Each look on its own person. Same input, same answer, so the rail and
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
    /// it from the pack's own name, looks and photo.
    private var spotlightPack: LookPack? {
        PackCatalog.spotlight
    }

    private func packKicker(_ pack: LookPack) -> String {
        let count = pack.looks.count
        let looks = "\(count) \(count == 1 ? "look" : "looks")"
        let isNew = pack.id == "after-dark" || pack.name.lowercased() == "after dark"
        return (isNew ? "New pack · " : "Look pack · ") + looks
    }

    private func packCopy(_ pack: LookPack) -> String {
        let night = pack.looks.contains { $0.name.contains("Neon Nights") || $0.name.contains("Afrobeats Glow") }
        return night ? "Flash, neon and packed rooms" : pack.eraTag
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

    private func openYou() {
        app.tab = .profile
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

    /// Cut to the beat: the template's look goes on the grade, then Select
    /// clips opens with the template. The picker builds the project from the
    /// picks and applies the template by id through the editor's own
    /// `applyTemplate`.
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
            app.settings.intensity = LookSettings().intensity
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

private enum HomeClock {
    /// "Friday · 21:40" (the time follows the device's 12/24 hour setting).
    static func dayLine(_ date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.wide))
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(time)"
    }

    static func partOfDay(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<12: return "morning"
        case 12..<18: return "afternoon"
        default: return "evening"
        }
    }
}

/// Day and time, the greeting, search and the avatar (which opens You).
private struct HomeHeader: View {
    let isFirstRun: Bool
    let onSearch: () -> Void
    let onAvatar: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TimelineView(.everyMinute) { context in
                greeting(at: context.date)
            }
            Spacer(minLength: 8)
            searchButton
            avatarButton
        }
    }

    @ViewBuilder
    private func greeting(at date: Date) -> some View {
        if isFirstRun {
            VStack(alignment: .leading, spacing: 5) {
                LumaHeadline(light: "Welcome to", heavy: "lumalook", size: 30)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Shoot or edit your first clip")
                    .font(.luma(size: 14))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(HomeClock.dayLine(date))
                    .font(.luma(size: 13.5, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
                    .lineLimit(1)
                LumaHeadline(light: "Good", heavy: HomeClock.partOfDay(date), size: 34)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Search looks")
    }

    private var avatarButton: some View {
        Button(action: onAvatar) {
            HomeGradedPhoto(photo: .bridge)
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(LumaTheme.border, lineWidth: 1))
                .contentShape(Circle())
                .padding(.bottom, 1)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("You")
    }
}

/// The reel runs under the status bar. At the top a soft shade keeps the
/// clock legible on the photo; once the page scrolls, the backing turns solid
/// like a navigation bar, so text never slides under the clock.
private struct HomeStatusScrim: View {
    let solid: Bool
    /// The top safe area inset.
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color.black.opacity(0.5), Color.black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height + 26)
            LumaTheme.background
                .frame(height: height)
                .opacity(solid ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: solid)
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

/// Home's rail heading: sentence case at near-full white, the action a quiet
/// grey word.
private struct HomeSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.luma(size: 17, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let actionTitle {
                Button { action?() } label: {
                    Text(actionTitle)
                        .font(.luma(size: 13.5, weight: .medium))
                        .foregroundStyle(LumaTheme.textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
        }
    }
}

/// Poster geometry shared by the Continue editing cards.
private enum Poster {
    static let width: CGFloat = 114
    static let height: CGFloat = 176
    static let radius: CGFloat = 13

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The small dark value badge in a frame's corner (0:12).
    static func badge(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// The look's signature dot, glowing, in a frame's top corner.
    static func dot(_ colour: Color) -> some View {
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .shadow(color: colour, radius: 5)
    }

    static func caption(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.luma(size: 14, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
            Text(detail)
                .font(.luma(size: 12))
                .foregroundStyle(LumaTheme.textMuted)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
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
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let ci = source.ciImage else { return nil }
            let state = LookState()
            state.recipe = recipe
            var settings = LookSettings()
            settings.intensity = 100
            state.settings = settings
            return LookPipeline.shared.gradedStill(ci, state: state, maxDimension: size)
        }.value
        if let image {
            HomeGradeCache.images[key] = image
            graded = image
        }
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

// MARK: - Resume pill

/// The last edit as a pill that straddles the reel's bottom edge: its poster
/// in a ring of its look's colour, when it was edited, and a white play
/// button.
private struct HomeResumePill: View {
    let work: HomeWork
    let store: PersistenceStore
    let action: () -> Void

    static let height: CGFloat = 66
    /// How far the pill rises into the reel.
    static let overlap: CGFloat = 33

    private var editedLine: String {
        let label = HomeWork.editedLabel(work.updatedAt)
        let rest = String(label.dropFirst())
        return "Resume · " + label.prefix(1).lowercased() + rest
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HomeWorkPoster(work: work, store: store, maxPixel: 240)
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(work.signature, lineWidth: 2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(editedLine)
                        .font(.luma(size: 12.5))
                        .foregroundStyle(LumaTheme.textMuted)
                        .lineLimit(1)
                    Text("\(work.title) · \(Poster.duration(work.duration))")
                        .font(.luma(size: 17, weight: .semibold))
                        .kerning(-0.3)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LumaTheme.onLight)
                    .frame(width: 44, height: 44)
                    .background(LumaTheme.textPrimary, in: Circle())
            }
            .padding(.leading, 8)
            .padding(.trailing, 11)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            // Panel tone on solid ink, so the reel never shows through.
            .background(Capsule().fill(LumaTheme.panel))
            .background(Capsule().fill(LumaTheme.background))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Resume \(work.title). \(work.detail)")
    }
}

// MARK: - Make row

/// Shoot (the one signal-yellow action, in the look on the reel) and Edit a
/// clip, then the quick starts: Edit a photo, Templates and Import LUT.
private struct HomeShootRow: View {
    let onShoot: () -> Void
    let onEdit: () -> Void
    let onPhoto: () -> Void
    let onTemplates: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                makeButton(icon: "camera", title: "Shoot", primary: true, action: onShoot)
                makeButton(icon: "film", title: "Edit a clip", primary: false, action: onEdit)
            }
            HStack(spacing: 8) {
                quickButton(icon: "photo", title: "Edit a photo", action: onPhoto)
                quickButton(icon: "wand.and.stars", title: "Templates", action: onTemplates)
                LUTImportButton(onImported: nil, label: {
                    HomeQuickLabel(icon: "square.and.arrow.down", title: "Import LUT")
                })
                .accessibilityLabel("Import a LUT")
            }
        }
    }

    private func makeButton(icon: String, title: String, primary: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            LumaHaptics.shared.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(primary ? LumaTheme.onSignal : LumaTheme.signal)
                Text(title)
                    .font(.luma(size: 16, weight: .semibold))
                    .kerning(-0.3)
                    .foregroundStyle(primary ? LumaTheme.onSignal : LumaTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(primary ? LumaTheme.signal : LumaTheme.panel,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(primary ? Color.clear : LumaTheme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(title)
    }

    private func quickButton(icon: String, title: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            LumaHaptics.shared.tap()
            action()
        } label: {
            HomeQuickLabel(icon: icon, title: title)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(title)
    }
}

private struct HomeQuickLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LumaTheme.signal)
            Text(title)
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(LumaTheme.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(LumaTheme.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - Tonight's look

/// One signature look on the sample photo it suits best. The reel shows
/// three, starting from today's; the trio turns over at midnight.
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
        let n = max(1, min(count, options.count))
        return (0..<n).map { options[(day + $0) % options.count] }
    }

    /// Changes at midnight; the same all day on every screen.
    static var today: TonightsLook {
        reel(count: 1).first ?? fallback
    }
}

/// AF1: tonight's three looks on real people, edge to edge, with story bars,
/// the greeting on top and a viewfinder over the frame (corner brackets and a
/// thirds grid). The strip under the title regrades the frame on screen:
/// picking a look pauses the reel, and tapping the picture (or the picked
/// look again) lets it cycle on. With Reduce Motion on it neither cycles nor
/// zooms; taps still move between looks.
private struct ViewfinderReel: View {
    let looks: [TonightsLook]
    let stripLooks: [TonightsLook]
    @Binding var index: Int
    @Binding var pick: String?
    let packLine: (TonightsLook) -> String
    let isFirstRun: Bool
    let safeTop: CGFloat
    let height: CGFloat
    /// Room at the bottom for the Resume pill that rises into the reel.
    let pillRoom: CGFloat
    let reduceMotion: Bool
    let onSearch: () -> Void
    let onAvatar: () -> Void

    @State private var started = Date()

    static let dwell: Double = 4.2
    /// Where the brackets start below the safe area (under the greeting),
    /// and what the copy and strip need beneath them.
    private static let bracketTop: CGFloat = 118
    private static let copyRoom: CGFloat = 312

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

    private var signature: Color {
        shown?.preset.signature ?? LumaTheme.signal
    }

    private var isPaused: Bool { reduceMotion || pick != nil }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            photos
            scrim
            thirds
            copy
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay(alignment: .top) { brackets }
        .overlay(alignment: .top) { top }
        .overlay(alignment: .bottom) { sigline }
        .clipped()
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
            .opacity(isOn ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: safeIndex)
    }

    /// Dark under the status bar, clear across the face, then down into the
    /// page's ink so the copy, the strip and the Resume pill read.
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.5), location: 0),
            .init(color: .clear, location: 0.24),
            .init(color: .clear, location: 0.42),
            .init(color: .black.opacity(0.62), location: 0.66),
            .init(color: LumaTheme.background, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }

    private var thirds: some View {
        GeometryReader { geo in
            Path { path in
                for step in 1...2 {
                    let x = geo.size.width * CGFloat(step) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    let y = geo.size.height * CGFloat(step) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.08), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var brackets: some View {
        GeometryReader { geo in
            let boxHeight = max(90, height - safeTop - Self.bracketTop - Self.copyRoom)
            ViewfinderBrackets()
                .stroke(Color.white.opacity(0.88),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: geo.size.width * 0.6, height: boxHeight)
                .position(x: geo.size.width / 2, y: safeTop + Self.bracketTop + boxHeight / 2)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Chrome

    private var top: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
                ReelBars(count: looks.count, index: safeIndex, progress: progress(at: context.date))
            }
            .frame(height: 3)
            .allowsHitTesting(false)
            HomeHeader(isFirstRun: isFirstRun, onSearch: onSearch, onAvatar: onAvatar)
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 6)
    }

    @ViewBuilder
    private var copy: some View {
        if let look = shown {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    stateChip
                    Text(packLine(look))
                        .font(.luma(size: 13, weight: .semibold))
                        .foregroundStyle(look.preset.signature)
                        .lineLimit(1)
                        .padding(.top, 14)
                    LumaHeadline(light: look.light, heavy: look.heavy, size: 40)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 4)
                    Text(look.line)
                        .font(.luma(size: 14))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .id("\(safeIndex)-\(pick ?? "")")
                .transition(.opacity)
                .allowsHitTesting(false)
                strip
                    .padding(.top, 16)
            }
            .padding(.bottom, pillRoom + 16)
        }
    }

    /// "Tonight's look" while the reel runs; once a look is picked, how to
    /// get back to it.
    private var stateChip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(signature)
                .frame(width: 7, height: 7)
                .shadow(color: signature, radius: 4)
            Text(pick == nil ? "Tonight's look" : "Your pick · tap the picture to go back")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    /// The strip's swatches all grade one close face, so each look reads on
    /// the same skin and the strip renders once rather than on every turn of
    /// the reel. Tapping one regrades the picture above.
    private static let swatchPhoto: HeroPhoto = .golden

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stripLooks, id: \.preset.name) { entry in
                    tile(entry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func tile(_ entry: TonightsLook) -> some View {
        let isOn = (pick ?? base?.preset.name) == entry.preset.name
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { choose(entry) } label: {
            HomeGradedPhoto(photo: Self.swatchPhoto, lookName: entry.preset.name, maxDimension: 240)
                .frame(width: 64, height: 80)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottom) {
                    Text(entry.tileCode)
                        .font(.luma(size: 12, weight: .bold))
                        .foregroundStyle(entry.preset.signature)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 6)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .pickedRing(isOn, cornerRadius: 12)
                .contentShape(shape)
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Try \(entry.preset.title) on this picture")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var sigline: some View {
        Rectangle()
            .fill(signature)
            .frame(height: 2.5)
            .shadow(color: signature.opacity(0.9), radius: 9)
            .animation(.easeInOut(duration: 0.6), value: signature)
            .allowsHitTesting(false)
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

/// Four rounded corner brackets, like a camera's focus frame.
private struct ViewfinderBrackets: Shape {
    var arm: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let a = min(arm, rect.width / 3, rect.height / 3)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + a))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + a, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - a, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + a))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - a))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - a, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + a, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - a))
        return path
    }
}

/// Story-style progress: done bars full, the current one filling, the rest
/// dim.
private struct ReelBars: View {
    let count: Int
    let index: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(count, 1), id: \.self) { position in
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.white)
                            .scaleEffect(x: CGFloat(max(fill(position), 0.0001)), y: 1, anchor: .leading)
                    }
                    .frame(height: 3)
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
            BeatBars(levels: BeatPattern.levels(for: template, seed: seed), colour: colour)
                .frame(height: 20)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(LumaTheme.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    }

    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .offset(x: 1)
            .frame(width: 38, height: 38)
            .background(Color.black.opacity(0.5), in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
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

// MARK: - Looks

private enum HomeLooksMode: String, CaseIterable {
    case forYou = "For you"
    case recents = "Recents"
}

/// "Looks" with the For you | Recents switch and "All looks". Before any
/// look has been used there is nothing recent, so it reads "Looks for you".
private struct HomeLooksHeader: View {
    @Binding var mode: HomeLooksMode
    let showsSwitch: Bool
    let onAll: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(showsSwitch ? "Looks" : "Looks for you")
                .font(.luma(size: 17, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
            if showsSwitch { switcher }
            Spacer(minLength: 8)
            Button(action: onAll) {
                Text("All looks")
                    .font(.luma(size: 13.5, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
    }

    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(HomeLooksMode.allCases, id: \.self) { option in
                Button {
                    mode = option
                    LumaHaptics.shared.tap()
                } label: {
                    Text(option.rawValue)
                        .font(.luma(size: 12.5, weight: .semibold))
                        .foregroundStyle(mode == option ? LumaTheme.textPrimary : LumaTheme.textMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(mode == option ? LumaTheme.control : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(mode == option ? LumaTheme.border : Color.clear,
                                                        lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(LumaTheme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(LumaTheme.hairline, lineWidth: 1))
    }
}

private struct HomeLookRail: View {
    let looks: [LibraryLook]
    let photos: [String: HeroPhoto]
    let images: [String: CGImage]
    let isCurrent: (LibraryLook) -> Bool
    let onPick: (LibraryLook) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(looks) { look in
                    HomeLookTile(look: look,
                                 photo: photos[look.id] ?? .golden,
                                 image: images[look.id],
                                 isOn: isCurrent(look)) {
                        onPick(look)
                    }
                }
            }
            .padding(.horizontal, 16)
            // Room for the picked ring's glow.
            .padding(.vertical, 4)
        }
    }
}

/// Each look on its own person, its code large in the look's colour.
private struct HomeLookTile: View {
    let look: LibraryLook
    let photo: HeroPhoto
    let image: CGImage?
    let isOn: Bool
    let action: () -> Void

    private static let width: CGFloat = 118
    private static let height: CGFloat = 158
    private static let radius: CGFloat = 14

    /// "CN93", or the first word of a name without a stock code.
    private var code: String {
        if let code = LookSignature.code(in: look.name) { return code }
        let title = LookSignature.title(in: look.name)
        return title.split(separator: " ").first.map(String.init) ?? title
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                picture
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.25), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.8), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                Text(code)
                    .font(.luma(size: 22, weight: .heavy))
                    .kerning(-1)
                    .foregroundStyle(look.signature)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 9)
                    .padding(.top, 8)
            }
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .bottomLeading) {
                Text(LookSignature.title(in: look.name))
                    .font(.luma(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 9)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(LumaTheme.hairline, lineWidth: 1))
            .pickedRing(isOn, cornerRadius: Self.radius)
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(look.name). Try on a clip")
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
                guard let photo = job.photo.ciImage else { continue }
                let source = homeScaled(photo, longest: 720)
                let state = LookState()
                if let recipe = job.recipe { state.recipe = recipe }
                state.settings = job.settings
                if let url = job.lutURL {
                    guard let lut = try? LookPipeline.shared.loadLUT(at: url) else { continue }
                    state.lut = lut
                }
                guard let cg = LookPipeline.shared.gradedStill(source, state: state, maxDimension: 420) else {
                    continue
                }
                await MainActor.run {
                    HomeLookTileRender.cache[job.key] = cg
                    self?.images[job.id] = cg
                }
            }
        }
    }
}

// MARK: - Continue editing

private struct ContinueRail: View {
    let works: [HomeWork]
    let sessions: [GradeSession]
    let store: PersistenceStore
    let onOpen: (HomeWork) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(works) { work in
                    WorkPosterCard(work: work, store: store) { onOpen(work) }
                }
                // Saved grades are recents too; the badge keeps them from
                // reading as projects.
                ForEach(sessions) { session in
                    GradeSessionPoster(session: session)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct WorkPosterCard: View {
    let work: HomeWork
    let store: PersistenceStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HomeWorkPoster(work: work, store: store, maxPixel: 420)
                    .frame(width: Poster.width, height: Poster.height)
                    .clipShape(RoundedRectangle(cornerRadius: Poster.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Poster.radius, style: .continuous)
                        .strokeBorder(LumaTheme.hairline, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if work.lookName != nil {
                            Poster.dot(work.signature).padding(9)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        Poster.badge(Poster.duration(work.duration)).padding(7)
                    }
                Poster.caption(title: work.title, detail: work.shortDetail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(work.title). \(work.shortDetail)")
    }
}

/// A saved Apply-a-Look session: real media frame + Video/Photo badge; tap
/// restores the exact grade.
private struct GradeSessionPoster: View {
    @EnvironmentObject private var app: AppModel
    let session: GradeSession
    @State private var thumb: CGImage?

    var body: some View {
        Button {
            app.restoreGradeSession(session)
            LumaHaptics.shared.tap()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .overlay {
                        if let thumb {
                            Image(decorative: thumb, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            LumaTheme.surfaceStrong
                        }
                    }
                    .frame(width: Poster.width, height: Poster.height)
                    .clipShape(RoundedRectangle(cornerRadius: Poster.radius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Poster.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Poster.radius, style: .continuous)
                        .strokeBorder(LumaTheme.hairline, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        Poster.dot(LookSignature.colour(forLookNamed: session.baseLookName)).padding(9)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Poster.badge(session.isVideo ? "Video" : "Photo").padding(7)
                    }
                Poster.caption(title: LookSignature.title(in: session.baseLookName),
                               detail: "Grade · " + session.updatedAt.formatted(.dateTime.day().month(.abbreviated)))
            }
            .contentShape(Rectangle())
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

// MARK: - Pack spotlight

/// The pack cover with three faces, its look count and one white button.
/// Packs live in Looks now; this opens the pack page.
private struct PackSpotlight: View {
    let pack: LookPack
    let kicker: String
    let line: String
    let action: () -> Void

    private static let radius: CGFloat = 20
    private static let faces: [HeroPhoto] = [.neon, .drive, .gig]

    private var hasNightLooks: Bool {
        pack.looks.contains { $0.name.contains("Afrobeats Glow") }
    }

    private var coverPhoto: HeroPhoto { hasNightLooks ? .party : pack.photo }

    private var coverLook: String? {
        hasNightLooks ? "Afrobeats Glow" : pack.looks.first?.name
    }

    private var lightWord: String {
        let words = pack.name.split(separator: " ").map(String.init)
        return words.dropLast().joined(separator: " ")
    }

    private var heavyWord: String {
        let words = pack.name.split(separator: " ").map(String.init)
        return words.last ?? pack.name
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                HomeGradedPhoto(photo: coverPhoto, lookName: coverLook, maxDimension: 900)
                LinearGradient(colors: [.black.opacity(0.86), .black.opacity(0.15)],
                               startPoint: .leading, endPoint: UnitPoint(x: 0.78, y: 0.5))
                copy
            }
            .frame(maxWidth: .infinity)
            .frame(height: 196)
            .overlay(alignment: .bottomTrailing) { facesRow.padding(16) }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(LumaTheme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(pack.name). \(kicker). See the pack")
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(LumaTheme.signal)
                .lineLimit(1)
            title
                .padding(.top, 3)
            Text(line)
                .font(.luma(size: 13))
                .foregroundStyle(LumaTheme.textSecondary)
                .lineLimit(1)
                .padding(.top, 3)
            Spacer(minLength: 10)
            Text("See the pack")
                .font(.luma(size: 14, weight: .semibold))
                .foregroundStyle(LumaTheme.onLight)
                .padding(.horizontal, 16)
                .frame(height: 42)
                .background(LumaTheme.textPrimary,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var title: some View {
        if lightWord.isEmpty {
            Text(heavyWord)
                .font(.luma(size: 34, weight: .heavy))
                .tracking(LumaType.tracking(for: 34))
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            LumaHeadline(light: lightWord, heavy: heavyWord, size: 34)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var facesRow: some View {
        HStack(spacing: -10) {
            ForEach(Self.faces, id: \.self) { photo in
                HomeGradedPhoto(photo: photo)
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 2))
            }
        }
        .allowsHitTesting(false)
    }
}

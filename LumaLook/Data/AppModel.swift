import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import CoreImage
import Combine

@MainActor
final class AppModel: ObservableObject {
    // Navigation
    @Published var path: [LumaRoute] = []
    @Published var tab: LumaTab = .home

    // Apply a Look flow — video OR still image (SPEC_ADDENDUM §5)
    @Published var selectedVideoURL: URL? {
        didSet {
            autoDetectLogTask?.cancel()
            rebuildPlayer()
            updatePreviewFrame()
            if !isRestoringSession {
                detachGradeSession()
                clearSourceConversion()
                autoDetectLogProfile()
            }
        }
    }

    private var autoDetectLogTask: Task<Void, Never>?

    private func clearSourceConversion() {
        conversionProfile = nil
        conversionLUT = nil
        conversionOpacity = 100
    }

    /// T2.8 — auto-detect the source's log/HDR profile from the video track's
    /// format description. HLG + Apple Log are reliably tagged; S-Log/V-Log/
    /// D-Log containers are generic → manual picker only.
    private func autoDetectLogProfile() {
        guard let url = selectedVideoURL else { return }
        autoDetectLogTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let descs = try? await track.load(.formatDescriptions),
                  let desc = descs.first,
                  !Task.isCancelled else { return }
            let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
            let transfer = ext?[kCVImageBufferTransferFunctionKey as String] as? String
            var detected: LogProfile?
            if let transfer {
                if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                    detected = .hlg
                } else if transfer.localizedCaseInsensitiveContains("apple") &&
                          transfer.localizedCaseInsensitiveContains("log") {
                    detected = .appleLog
                }
            }
            guard let detected else { return }
            guard !Task.isCancelled,
                  let self,
                  self.selectedVideoURL == url,
                  self.selectedImage == nil,
                  self.conversionProfile == nil,
                      self.conversionLUT == nil else { return }
            self.conversionProfile = detected
            self.importToast = "Auto: \(detected.label) → Rec.709"
            print("[LUMA] LOGDETECT \(detected.rawValue)")
        }
    }
    @Published var selectedImage: CIImage? {
        didSet {
            if selectedImage != nil { selectedVideoURL = nil }
            updatePreviewFrame()
            if !isRestoringSession {
                detachGradeSession()
                clearSourceConversion()
            }
        }
    }

    // MARK: Batch grading (queue #10)

    /// Extra picked items queued behind the previewed one — the whole set
    /// exports with the SAME grade.
    @Published var batchItems: [PhotosPickerItem] = []
    @Published var batchStatus: String?
    /// The batch item previewed in the grade room. Its working pixels may
    /// carry a crop or mask, so batch export keeps them rather than
    /// reloading the library original.
    var batchPreviewItemID: String?

    /// Select clips hand-off (see `openSelectClips(_:templateID:)` in
    /// SelectClipsLibrary.swift): what the picker was opened for, and a template
    /// picked before it. The picker reads both once, then resets them.
    var selectClipIntent: SelectClipIntent = .grade
    var pendingTemplateID: String?

    /// Applies the current grade to every batch item sequentially, saving
    /// each to Photos. Returns how many succeeded.
    func runBatchExport(spec: ExportSpec) async -> Int {
        let items = batchItems
        guard !items.isEmpty else { return 0 }
        let previewID = batchPreviewItemID
        var succeeded = 0
        for (index, item) in items.enumerated() {
            batchStatus = "PROCESSING \(index + 1) OF \(items.count)"
            if index == 0, let previewID, item.itemIdentifier == previewID {
                // Already loaded, with any photo edit applied.
            } else if let video = try? await item.loadTransferable(type: PickedVideo.self) {
                selectedVideoURL = video.url
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                selectedImage = image
            } else {
                continue
            }
            if await exportCurrentVideo(spec: spec) { succeeded += 1 }
        }
        batchStatus = nil
        batchItems = []
        batchPreviewItemID = nil
        return succeeded
    }

    // MARK: Grade sessions (queue #13)

    private var currentSessionID: UUID?
    private var sessionMediaFileName: String?
    private var isRestoringSession = false

    private func detachGradeSession() {
        currentSessionID = nil
        sessionMediaFileName = nil
    }

    /// Autosaves the current Apply-a-Look session (media copied durable +
    /// the exact grade) so it reappears in Recent Projects.
    func saveGradeSession() {
        guard selectedVideoURL != nil || selectedImage != nil else { return }
        if sessionMediaFileName == nil {
            if let url = selectedVideoURL {
                let durable = url.path.hasPrefix(store.clipsFolder.path)
                    ? url : store.importClipFile(from: url)
                guard let durable else { return }
                sessionMediaFileName = durable.lastPathComponent
            } else if let image = selectedImage {
                let name = "\(UUID().uuidString).jpg"
                let dest = store.clipsFolder.appendingPathComponent(name)
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      (try? LookPipeline.shared.context.writeJPEGRepresentation(
                          of: image, to: dest, colorSpace: space)) != nil else { return }
                sessionMediaFileName = name
            }
        }
        guard let fileName = sessionMediaFileName else { return }
        let id = currentSessionID ?? UUID()
        currentSessionID = id
        let existing = store.gradeSessions.first { $0.id == id }
        store.upsert(session: GradeSession(
            id: id,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            mediaFileName: fileName,
            isVideo: selectedVideoURL != nil,
            baseLookName: selectedLook.name,
            settings: settings,
            lutID: selectedLUT?.id,
            conversionLUTID: conversionLUT?.id,
            conversionOpacity: conversionOpacity,
            creativeOpacity: creativeOpacity,
            creativeBlend: creativeBlend.rawValue,
            conversionProfile: conversionProfile?.rawValue))
    }

    /// Reopens a saved grade session exactly where it was left.
    func restoreGradeSession(_ session: GradeSession) {
        let url = store.sessionMediaURL(session)
        guard FileManager.default.fileExists(atPath: url.path) else {
            store.deleteSession(session.id)
            return
        }
        isRestoringSession = true
        if let base = MockData.looks.first(where: { $0.name == session.baseLookName }) {
            selectedLook = base
        }
        selectedLUT = session.lutID.flatMap { id in lutRepository.luts.first { $0.id == id } }
        conversionLUT = session.conversionLUTID.flatMap { id in lutRepository.luts.first { $0.id == id } }
        conversionOpacity = session.conversionOpacity ?? 100
        conversionProfile = session.conversionProfile.flatMap(LogProfile.init)
        creativeOpacity = session.creativeOpacity ?? 100
        creativeBlend = session.creativeBlend.flatMap(LUTBlendMode.init) ?? .normal
        settings = session.settings
        // Picking a Skin first preset clears the film look, so the two are
        // only ever saved together by the old fault that left a preset on
        // under the looks picked after it. Such a project opens as its look.
        if selectedLUT != nil { settings = SkinFirstPreset.takenOff(settings) }
        if session.isVideo {
            selectedVideoURL = url
        } else {
            selectedImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        currentSessionID = session.id
        sessionMediaFileName = session.mediaFileName
        isRestoringSession = false
        path = [.selectClip, .applyLook]
    }

    /// A small real frame from the selected media, used to render the look
    /// strip thumbnails through the actual grading pipeline.
    @Published private(set) var previewFrame: CIImage?
    private var frameTask: Task<Void, Never>?

    private func updatePreviewFrame() {
        frameTask?.cancel()
        if let image = selectedImage {
            let longest = max(image.extent.width, image.extent.height)
            let scale = longest > 480 ? 480 / longest : 1
            previewFrame = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return
        }
        guard let url = selectedVideoURL else {
            previewFrame = nil
            return
        }
        frameTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            guard let result = try? await generator.image(
                at: CMTime(seconds: 0.05, preferredTimescale: 600)) else { return }
            guard !Task.isCancelled else { return }
            self?.previewFrame = CIImage(cgImage: result.image)
        }
    }
    @Published var selectedLook: LookPreset = MockData.defaultLook {
        didSet {
            // Any real pick ends a pack try-on (see `packPreview`).
            if packPreview != nil { packPreview = nil }
            syncLookState()
        }
    }
    @Published var selectedLUT: LUTFile? {
        didSet {
            if packPreview != nil { packPreview = nil }
            syncLookState()
            applyRememberedStrength()
        }
    }
    /// A pack look the camera is trying on before its pack is in the
    /// library: it grades the live picture from the pack's own recipe or
    /// film file, without installing anything. Paid packs preview free and
    /// `lockedLookInGrade` asks only when a file leaves the app. Any real
    /// pick (`selectedLook` / `selectedLUT`) ends it.
    @Published private(set) var packPreview: PackLookPreview? {
        didSet { if packPreview != oldValue { syncLookState() } }
    }

    /// Starts trying on a pack look (`CameraLooks` decides when).
    func startPackPreview(_ preview: PackLookPreview) {
        takeOffWornGrade()
        packPreview = preview
    }
    /// Guards the per-LUT-strength write-back while we're APPLYING a remembered
    /// value (so restoring 62% doesn't immediately re-save 62%).
    private var isApplyingRemembered = false
    private var strengthSaveTask: Task<Void, Never>?

    /// When a LUT is picked, restore its remembered opacity/blend (unless a
    /// GradeSession restore is driving, which sets its own values).
    private func applyRememberedStrength() {
        guard !isRestoringSession, let lut = selectedLUT else { return }
        isApplyingRemembered = true
        creativeOpacity = lut.defaultOpacity ?? 100
        creativeBlend = lut.defaultBlend.flatMap(LUTBlendMode.init) ?? .normal
        isApplyingRemembered = false
    }

    /// Debounced write-back of the current opacity/blend onto the selected LUT.
    private func rememberStrength() {
        guard !isApplyingRemembered, !isRestoringSession, let lut = selectedLUT else { return }
        strengthSaveTask?.cancel()
        let id = lut.id, op = creativeOpacity, bl = creativeBlend.rawValue
        strengthSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.lutRepository.setDefaults(for: id, opacity: op, blend: bl)
        }
    }
    /// Slot 1 — conversion/log-normalisation LUT applied before the look.
    /// T2.8 — built-in log profile (mutually exclusive with conversionLUT).
    @Published var conversionProfile: LogProfile? {
        didSet {
            if conversionProfile != nil { conversionLUT = nil }
            syncLookState()
        }
    }
    @Published var conversionLUT: LUTFile? {
        didSet {
            if conversionLUT != nil { conversionProfile = nil }
            syncLookState()
        }
    }
    @Published var conversionOpacity: Double = 100 {
        didSet { syncLookState() }
    }
    /// Slot 2 opacity — creative LUT blended against its input.
    @Published var creativeOpacity: Double = 100 {
        didSet { syncLookState(); rememberStrength() }
    }
    /// Slot 2 blend mode (Normal/Soft Light/Overlay/Screen).
    @Published var creativeBlend: LUTBlendMode = .normal {
        didSet { syncLookState(); rememberStrength() }
    }
    @Published var settings = LookSettings() {
        didSet { syncLookState() }
    }

    // Export results — one of the two
    /// False when the export finished but Photos access was denied — the
    /// success screen shows the Settings banner instead of a scary error.
    @Published var lastExportSavedToPhotos = true
    @Published var lastExportURL: URL?
    /// F5 — the GIF alongside the last export, when "Also save GIF" was on.
    @Published var lastExportGIFURL: URL?
    @Published var lastExportImage: CGImage?
    @Published var exportError: String?
    /// Transient confirmation banner for open-in-place imports (#117).
    @Published var importToast: String?

    let lutRepository = LUTRepository()
    let exporter = VideoExporter()
    let store = PersistenceStore()
    let packStore = PackStore()
    /// Unified Look Library — aggregates saved looks, built-ins, and LUTs with
    /// cross-source favourites/recents/search. Constructed in init (after the
    /// three stores above have their default values).
    let library: LookLibraryStore

    /// Pack the Store is currently showing in Pack Detail.
    @Published var selectedPackID: String?

    /// Live grade state read by preview and export frame handlers.
    let lookState = LookState()

    /// Phase 5 editor: multi-clip composition timeline sharing the same look state.
    private(set) lazy var editor = EditorState(
        lookState: lookState, store: store,
        lutFileURL: { [lutRepository] id in
            lutRepository.luts.first { $0.id == id }.map { lutRepository.fileURL(for: $0) }
        })

    /// Player for the selected clip with the look applied in real time.
    @Published private(set) var player: AVPlayer?

    /// Re-publish `app` when a nested store mutates, so `libraryLooks` (which
    /// reads lutRepository/store/packStore) stays live in every pick surface —
    /// installing a pack or importing a LUT now refreshes strips immediately.
    private var storeCancellables = Set<AnyCancellable>()

    init() {
        library = LookLibraryStore(persistence: store, luts: lutRepository, packs: packStore)
        // Without an explicit .playback category, iOS mutes ALL app audio
        // whenever the ring/silent switch is on silent — the classic
        // "imported video has no sound" bug. Every media app sets this.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        syncLookState()
        applyDebugRoute()
        rebakeRecipeLooksIfNeeded()

        for publisher in [lutRepository.objectWillChange,
                          store.objectWillChange,
                          packStore.objectWillChange,
                          library.objectWillChange,      // favourites/recents changes
                          exporter.objectWillChange] {   // export ring froze at 0% without this
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &storeCancellables)
        }
    }

    /// Debug-only: launch straight into a screen for UI verification,
    /// e.g. SIMCTL_CHILD_LUMA_ROUTE=applyLook.
    // MARK: - Open-in-place imports (#117)

    /// Handles files handed to the app: a .cube imports straight into the
    /// LUT library; a .zip pack extracts and imports every cube inside.
    func handleIncomingFile(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "cube":
            if let lut = try? lutRepository.importLUT(from: url) {
                importToast = "Imported \(lut.displayName)"
                if path.last != .lutManager { path.append(.lutManager) }
            } else {
                importToast = "Couldn't read that .cube file."
            }
        case "zip":
            let cubes = ZipReader.entries(in: url)
                .filter { $0.fileName.lowercased().hasSuffix(".cube") }
            guard !cubes.isEmpty else {
                importToast = "No .cube files in that archive."
                return
            }
            var imported = 0
            // Stage under the ORIGINAL filename (in a unique folder) — the
            // repository derives the display name from it.
            let stagingDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaLook_Unzip_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            for entry in cubes {
                let name = (entry.fileName as NSString).lastPathComponent
                let staging = stagingDir.appendingPathComponent(name)
                guard (try? entry.data.write(to: staging)) != nil else { continue }
                if (try? lutRepository.importLUT(from: staging)) != nil { imported += 1 }
            }
            try? FileManager.default.removeItem(at: stagingDir)
            importToast = imported > 0
                ? "Imported \(imported) LUT\(imported == 1 ? "" : "s") from the pack"
                : "Couldn't import that pack."
            if imported > 0, path.last != .lutManager { path.append(.lutManager) }
        default:
            break
        }
    }

    private func applyDebugRoute() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        // Appearance cell: LUMA_APPEARANCE=dial,dot,white sets You › Appearance.
        LumaAppearance.applyLaunchOverride()
        // Auto-grade cell: load a cast image, run autoGrade, print result.
        if let path = env["LUMA_SEED_AUTOGRADE"], FileManager.default.fileExists(atPath: path) {
            selectedImage = CIImage(contentsOf: URL(fileURLWithPath: path))
            Task {
                await autoGrade()
                print("[LUMA] autograde warmth=\(Int(settings.warmth)) tint=\(Int(settings.tint)) exp=\(Int(settings.exposure))")
            }
        }
        // Still cell: load a photo as it is, without the auto grade, for
        // screens that only need a picture to work on (the export lock).
        if let path = env["LUMA_SEED_STILL"], FileManager.default.fileExists(atPath: path) {
            selectedImage = CIImage(contentsOf: URL(fileURLWithPath: path))
        }
        // Per-LUT strength round-trip: set 62%, wait debounce, read back.
        if env["LUMA_SEED_LUTSTRENGTH"] == "1", let lut = lutRepository.luts.first {
            selectedLUT = lut
            creativeOpacity = 62   // debounced write-back onto the LUT
        }
        // Blend-mode cell: select a LUT + blend for export verification.
        if let bl = env["LUMA_SEED_BLEND"], let mode = LUTBlendMode(rawValue: bl) {
            if let first = lutRepository.luts.first { selectedLUT = first }
            creativeBlend = mode
            syncLookState()
        }
        // Skin-preset cell: apply a Skin First preset for verification.
        if let name = env["LUMA_SEED_SKINPRESET"],
           let preset = SkinFirstPreset(rawValue: name) {
            settings = preset.settings
            syncLookState()
        }
        // Pick cell: LUMA_SEED_PICKLOOK=<part of a look's name> picks that
        // library look the way a tap does. After LUMA_SEED_SKINPRESET it shows
        // that the next look takes the preset's place.
        if let wanted = env["LUMA_SEED_PICKLOOK"] {
            func find() -> LibraryLook? {
                library.all.first { $0.name.localizedCaseInsensitiveContains(wanted) }
            }
            // A film look lives in a pack; a free one is installed first, as
            // the Store's "Install free" does.
            if find() == nil,
               let pack = PackCatalog.packs.first(where: { pack in
                   pack.isFree && pack.looks.contains { $0.name.localizedCaseInsensitiveContains(wanted) }
               }),
               PackInstaller.install(pack, into: lutRepository) > 0 {
                packStore.markInstalled(pack)
            }
            if let look = find() {
                select(look: look)
                syncLookState()
            }
        }
        // Scope cells: LUMA_SEED_SCOPE=waveform|parade|vectorscope|histogram.
        if let sm = env["LUMA_SEED_SCOPE"] {
            UserDefaults.standard.set(true, forKey: "lumalook.showScope")
            UserDefaults.standard.set(sm, forKey: "lumalook.scopeMode")
        }
        // Pro-colour cells (verify the cube math headlessly).
        if env["LUMA_SEED_CURVE"] == "1" {
            // Strong contrast S-curve on master: lift blacks down, push whites.
            settings.curves = CurveSet(master: [
                CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.12),
                CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.75, y: 0.88),
                CurvePoint(x: 1, y: 1)])
        }
        if env["LUMA_SEED_WHEEL"] == "1" {
            // Teal shadows, warm highlights (the cinematic move).
            settings.wheels = ColorWheels(liftR: -0.06, liftG: 0.02, liftB: 0.10,
                                          gammaR: 1, gammaG: 1, gammaB: 1,
                                          gainR: 1.10, gainG: 1.0, gainB: 0.90)
        }
        if env["LUMA_SEED_SPLIT"] == "1" {
            settings.splitTone = SplitTone(shadowHue: 200, shadowSat: 0.6,
                                           highlightHue: 40, highlightSat: 0.5, balance: 0)
        }
        if env["LUMA_SEED_HSL"] == "1" {
            // Push blues toward cyan and desaturate greens.
            var b = HSLBands()
            b.hue[5] = -0.6; b.sat[5] = 0.5; b.sat[3] = -0.8
            settings.hsl = b
        }
        if env["LUMA_SEED_CURVE"]=="1" || env["LUMA_SEED_WHEEL"]=="1" || env["LUMA_SEED_HSL"]=="1" || env["LUMA_SEED_SPLIT"]=="1" { syncLookState() }
        // Lens cells: LUMA_SEED_LENS=anamorphic|vintage|diffusion|fisheye|tiltShift.
        // Explicit sync: property observers don't fire during init, so the
        // shared LookState would otherwise miss the seeded value.
        if let lens = env["LUMA_SEED_LENS"], LensKind(rawValue: lens) != nil {
            settings.lensKind = lens
            syncLookState()
        }
        // Pack cells: LUMA_SEED_PACK=<pack id> selects the Store detail pack.
        if let packID = env["LUMA_SEED_PACK"], PackCatalog.pack(id: packID) != nil {
            selectedPackID = packID
        }
        // Collections cell (G3): two populated collections, the second pinned
        // to the camera filmstrip, so the strip ordering is verifiable headlessly.
        if env["LUMA_SEED_COLLECTIONS"] == "1", lutRepository.collections.isEmpty {
            let ids = library.all.map(\.id)
            let sunset = lutRepository.createCollection(name: "Sunset Sessions", symbol: "sun.max")
            let night = lutRepository.createCollection(name: "Night Shoots", symbol: "moon.stars")
            for id in ids.prefix(4) { lutRepository.addLook(id: id, to: sunset.id) }
            for id in ids.dropFirst(4).prefix(5) { lutRepository.addLook(id: id, to: night.id) }
            lutRepository.setPinnedCollection(night.id)
        }
        // Projects cell: LUMA_SEED_PROJECTS=1 adds five photo projects from the
        // bundled hero photos (once), so the populated Projects page (hero,
        // tabs, grid) can be screenshotted headlessly with some variety.
        if env["LUMA_SEED_PROJECTS"] == "1",
           !store.projects.contains(where: { $0.title == "Golden hour walk" }) {
            let seeds: [(String, String, String, Double, Int)] = [
                ("hero_golden", "Golden hour walk", "CN44 · Anamorphic Dusk", -2 * 3600, 6),
                ("hero_neon", "Neon after party", "AD2 · Neon Nights", -5 * 3600, 9),
                ("hero_campaign", "Spring campaign", "CN93 · Luxury Campaign", -26 * 3600, 4),
                ("hero_rain", "London rain", "AD5 · London Rain", -28 * 3600, 3),
                ("hero_gig", "Friday gig", "BW32 · Documentary Grit", -3 * 86_400, 7)
            ]
            for (resource, title, look, offset, count) in seeds {
                guard let source = Bundle.main.url(forResource: resource, withExtension: "jpg"),
                      let copied = store.importClipFile(from: source) else { continue }
                let date = Date().addingTimeInterval(offset)
                let clips = (0..<count).map { _ in
                    StoredClip(id: UUID(), fileName: copied.lastPathComponent, assetDuration: 3,
                               trimStart: 0, trimEnd: 3, speed: 1, isImage: true,
                               grade: ClipGrade(baseLookName: look, lutID: nil, settings: LookSettings()))
                }
                store.upsert(project: StoredProject(
                    id: UUID(), title: title, createdAt: date, updatedAt: date, clips: clips,
                    format: "9:16", zoom: 1, volume: 1, fadeIn: 0, fadeOut: 0, muteAudio: false,
                    duration: Double(count) * 3))
            }
        }
        // Headless open-in-place check: LUMA_OPEN_FILE=<host path>.
        if let openPath = env["LUMA_OPEN_FILE"], FileManager.default.fileExists(atPath: openPath) {
            handleIncomingFile(url: URL(fileURLWithPath: openPath))
        }
        #endif
        #if DEBUG
        // LUMA_TAB selects a ROOT tab. Distinct from LUMA_ROUTE, which pushes a
        // screen and hides the tab bar: the tab-hosted variant of a screen has
        // a tab bar eating its bottom safe area, so only this path can catch
        // content hiding behind it.
        if let tabName = ProcessInfo.processInfo.environment["LUMA_TAB"],
           let seeded = LumaTab(rawValue: tabName) {
            tab = seeded
        }
        guard let route = ProcessInfo.processInfo.environment["LUMA_ROUTE"] else { return }
        // LUMA_ROUTE=launch shows the launch animation held at 1.2 s for a
        // screenshot; =launchLive plays it. LaunchGate (LaunchView.swift)
        // reads both. Nothing to push: Home sits underneath.
        if route == "launch" || route == "launchLive" { return }
        let map: [String: [LumaRoute]] = [
            "selectClip": [.selectClip],
            "applyLook": [.selectClip, .applyLook],
            "beforeAfter": [.selectClip, .applyLook, .beforeAfter],
            "lutManager": [.lutManager],
            "camera": [.camera],
            "editor": [.editor],
            "exportComplete": [.exportComplete],
            "filterStore": [.filterStore],
            "filterPack": [.filterStore, .filterPack],
            "savedLooks": [.savedLooks],
            "projectLibrary": [.projectLibrary],
            "settings": [.settings],
            "customLook": [.selectClip, .applyLook, .customLook],
            "collections": [.collections],
            "appearance": [.settings, .appearance]
        ]
        if let target = map[route] {
            path = target
        }
        #endif
    }

    /// Installed recipe looks live as cubes baked at install time. When the
    /// engine that baked them (or the True Colour switch) has changed, bake
    /// them again, off the main thread, so they match the live looks. Runs at
    /// launch and whenever the switch flips.
    ///
    /// The books are kept by `TrueColour.Rebake`. The saved stamp is cleared
    /// before the first cube is overwritten and saved again only once every
    /// cube is back on disk, so closing the app half way through, or moving
    /// the switch back, never leaves some looks baked one way under a stamp
    /// that says the other. One bake runs at a time and bakes every cube
    /// with the switch as it stood at the start; if the switch moved while
    /// it ran, it runs once more for the new setting.
    func rebakeRecipeLooksIfNeeded() {
        guard TrueColour.Rebake.isNeeded else { return }
        guard !rebakeInFlight else { return }
        let jobs = PackInstaller.recipeBakeJobs(in: lutRepository)
        guard !jobs.isEmpty else {
            TrueColour.Rebake.finish(bakedOn: TrueColour.Rebake.begin(), complete: true)
            // Nothing installed to bake, but every live look just changed.
            objectWillChange.send()
            return
        }
        rebakeInFlight = true
        let trueColour = TrueColour.Rebake.begin()
        Task.detached(priority: .utility) { [weak self] in
            var allWritten = true
            for job in jobs {
                guard let text = PackInstaller.cubeText(for: job.recipe, title: job.title,
                                                        trueColour: trueColour) else {
                    allWritten = false
                    continue
                }
                do {
                    try text.write(to: job.url, atomically: true, encoding: .utf8)
                } catch {
                    allWritten = false
                }
            }
            let finished = allWritten
            await MainActor.run {
                guard let self else { return }
                self.rebakeInFlight = false
                let switchMoved = TrueColour.Rebake.finish(bakedOn: trueColour, complete: finished)
                LookPipeline.shared.clearLUTCache()
                self.syncLookState()
                self.objectWillChange.send()
                if switchMoved { self.rebakeRecipeLooksIfNeeded() }
            }
        }
    }
    private var rebakeInFlight = false

    private func syncLookState() {
        lookState.recipe = selectedLook.recipe
        lookState.settings = settings
        if let preview = packPreview, let look = preview.look {
            // A pack try-on wears exactly what installing the pack would
            // give: its film file, or its recipe without the spatial passes
            // a baked cube cannot carry (`PackInstaller.cubeText`).
            if let url = preview.cubeURL {
                lookState.lut = try? LookPipeline.shared.loadLUT(at: url)
            } else {
                lookState.recipe = PackLookPreview.cubeRecipe(look.recipe)
                lookState.lut = nil
            }
        } else if let lut = selectedLUT {
            lookState.lut = try? LookPipeline.shared.loadLUT(at: lutRepository.fileURL(for: lut))
        } else {
            lookState.lut = nil
        }
        if let conversion = conversionLUT {
            lookState.conversionLUT = try? LookPipeline.shared.loadLUT(at: lutRepository.fileURL(for: conversion))
        } else {
            lookState.conversionLUT = nil
        }
        lookState.conversionOpacity = conversionOpacity / 100.0
        lookState.conversionProfile = conversionProfile
        // A try-on has no remembered LUT strength of its own: full, normal.
        lookState.lutOpacity = packPreview == nil ? creativeOpacity / 100.0 : 1
        lookState.lutBlend = packPreview == nil ? creativeBlend : .normal
        refreshPausedFrame()
    }

    /// A paused AVPlayer won't re-run the composition handler, so nudge it
    /// with a zero-tolerance seek to re-render the current frame.
    private func refreshPausedFrame() {
        guard let player, player.timeControlStatus != .playing else { return }
        let time = player.currentTime()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Public variant used by the Before/After wipe.
    func refreshPreviewFrame() {
        refreshPausedFrame()
    }

    // MARK: - AI Auto-Grade (one-tap correction)

    @Published var isAutoGrading = false

    /// Gray-world auto white-balance + auto-exposure: analyses the current
    /// frame (UNGRADED) and dials exposure/warmth/tint to neutralise a colour
    /// cast and centre the midtones. The "magic button".
    func autoGrade() async {
        guard !isAutoGrading else { return }
        isAutoGrading = true
        defer { isAutoGrading = false }
        guard let frame = previewFrame else { return }
        guard let m = await Self.meanRGB(of: frame) else { return }
        let luma = 0.2126 * m.r + 0.7152 * m.g + 0.0722 * m.b
        var s = settings
        // Centre midtones near 0.45.
        s.exposure = (max(-0.6, min(0.6, (0.45 - luma) * 2.2))) * 100
        // Neutralise cast: warm image (R>B) → cool it; green cast → magenta.
        s.warmth = max(-70, min(70, (m.b - m.r) * 320))
        s.tint = max(-70, min(70, ((m.r + m.b) / 2 - m.g) * 320))
        // A touch of contrast if the frame is flat (mean far from extremes).
        s.contrast = max(s.contrast, 14)
        settings = s
    }

    /// White-balance eyedropper: sample a point the user says is neutral and
    /// set warmth/tint so it becomes grey. `point` is normalised (0…1, y down).
    func whiteBalance(atNormalized point: CGPoint) async {
        guard let frame = previewFrame else { return }
        let ext = frame.extent
        let px = point.x * ext.width
        let py = (1 - point.y) * ext.height   // CIImage y is bottom-up
        let region = CGRect(x: px - 6, y: py - 6, width: 12, height: 12).intersection(ext)
        let sampleImage = region.isNull || region.isEmpty ? frame : frame.cropped(to: region)
        guard let m = await Self.meanRGB(of: sampleImage) else { return }
        var s = settings
        s.warmth = max(-80, min(80, (m.b - m.r) * 340))
        s.tint = max(-80, min(80, ((m.r + m.b) / 2 - m.g) * 340))
        settings = s
        LumaHaptics.shared.tap()
    }

    /// Mean RGB (0…1) of an image via CIAreaAverage.
    static func meanRGB(of image: CIImage) async -> (r: Double, g: Double, b: Double)? {
        await Task.detached {
            let avg = CIFilter.areaAverage()
            avg.inputImage = image
            avg.extent = image.extent
            guard let out = avg.outputImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            LookPipeline.shared.context.render(
                out, toBitmap: &px, rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
        }.value
    }

    private var loopObserver: NSObjectProtocol?

    private func rebuildPlayer() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        guard let url = selectedVideoURL else {
            player = nil
            return
        }
        if selectedImage != nil { selectedImage = nil }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let pipeline = LookPipeline.shared
        let state = lookState
        // The handler reads `state` live, so slider/look changes apply
        // to the running preview without rebuilding the composition.
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent()
            let filtered = pipeline.apply(state: state, to: source)
            request.finish(with: filtered.cropped(to: request.sourceImage.extent), context: pipeline.context)
        }
        composition.applySDRColorPolicy()
        item.videoComposition = composition
        let player = AVPlayer(playerItem: item)
        player.isMuted = false
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        self.player = player
    }

    // MARK: - Saved looks

    func saveCurrentLook(named name: String) {
        let look = SavedLook(id: UUID(), name: name, createdAt: Date(),
                             baseLookName: selectedLook.name,
                             settings: settings, lutID: selectedLUT?.id)
        store.saveLook(look)
    }

    // MARK: - Look selection (the ONE apply entry point)

    /// THE apply entry point. Sets the global grade state (grade room +
    /// camera preview) for any library look and records it as recently used.
    /// Every surface routes here — do not set `selectedLook`/`selectedLUT`
    /// directly from views.
    func select(look: LibraryLook) {
        switch look.source {
        case .builtIn(let p): takeOffWornGrade(); selectedLUT = nil; selectedLook = p
        case .lut(let f):     takeOffWornGrade(); selectedLUT = f   // remembered strength fires
        case .saved(let s):   applySavedLook(s)
        }
        library.noteUsed(look)
    }

    /// A Skin first preset, or a look saved under Mine, replaces the whole
    /// grade and is picked like a look, so the look picked next takes its
    /// place: it comes off whole, with anything that was adjusted on top of
    /// it (`LookSettings.takingOff`). Both used to stay on underneath every
    /// look picked after them.
    private func takeOffWornGrade() {
        guard let whole = wornGrade else { return }
        let plain = settings.takingOff(whole)
        if plain != settings { settings = plain }
    }

    /// The grade a look picked now would be shown with: the settings as they
    /// stand, with a worn preset or saved look taken off. The Compare grid
    /// draws its LUT cells with it, so a cell is what tapping it gives.
    var settingsAfterPick: LookSettings {
        wornGrade.map { settings.takingOff($0) } ?? settings
    }

    /// The whole grade the settings are wearing, if any: a Skin first
    /// preset's, or a saved look's.
    private var wornGrade: LookSettings? {
        if let preset = SkinFirstPreset.worn(by: settings) { return preset.settings }
        return store.savedLooks.first { settings.wears($0.settings) }?.settings
    }

    // MARK: - What is switched on (the look screen's tiles)

    /// True when the white balance is not the one the look or preset gives:
    /// the picker, Auto or the Warmth and Tint sliders moved it. The White
    /// bal. tile lights up for it, so it is never on unseen.
    var whiteBalanceIsOn: Bool {
        let base = wornGrade ?? LookSettings()
        return settings.warmth != base.warmth || settings.tint != base.tint
    }

    /// Puts the white balance back to the one the look or preset gives.
    func clearWhiteBalance() {
        let base = wornGrade ?? LookSettings()
        var s = settings
        s.warmth = base.warmth
        s.tint = base.tint
        settings = s
    }

    /// True when a colour slider, a curve, the wheels, the bands or the
    /// split tone is off what the look or preset gives: the More tile lights
    /// up for it.
    var gradeIsAdjusted: Bool {
        settings.isAdjusted(from: wornGrade ?? LookSettings())
    }

    /// True when the film look in the chain is not at full strength in the
    /// normal blend (a strength or blend remembered for that look included):
    /// the Chain tile lights up for it.
    var chainIsAdjusted: Bool {
        selectedLUT != nil && (creativeOpacity < 99.5 || creativeBlend != .normal)
    }

    /// Editor routing: nil clipID = timeline grade via `select(look:)`;
    /// set = per-clip ClipGrade via the one `clipGrade()` converter.
    func select(look: LibraryLook, forClip clipID: UUID?) {
        if let clipID {
            editor.setClipGrade(id: clipID, look.clipGrade())
            library.noteUsed(look)
        } else {
            select(look: look)
        }
    }

    /// Saved-branch implementation of `select(look:)` — views should call
    /// `select(look:)` instead so recents record.
    func applySavedLook(_ saved: SavedLook) {
        if let base = MockData.looks.first(where: { $0.name == saved.baseLookName }) {
            selectedLook = base
        }
        if let lutID = saved.lutID,
           let lut = lutRepository.luts.first(where: { $0.id == lutID }) {
            selectedLUT = lut
        } else {
            selectedLUT = nil
        }
        settings = saved.settings
    }

    /// True when the grade-room grade changes the picture at all. Strength 0
    /// dissolves the look and the user adjustments back to the original; a
    /// lens sits outside that blend, so it counts on its own.
    var gradeIsApplied: Bool {
        let lens = LensKind(rawValue: settings.lensKind) ?? .none
        return settings.intensity > 0 || lens != .none
    }

    // MARK: - Grade stash (editor ✕)

    /// The whole global grade as one value, so a tool that changes it (the
    /// editor's whole-edit Looks) can put it back exactly when cancelled.
    struct GradeStash {
        let look: LookPreset
        let lut: LUTFile?
        let settings: LookSettings
        let creativeOpacity: Double
        let creativeBlend: LUTBlendMode
    }

    func stashGrade() -> GradeStash {
        GradeStash(look: selectedLook, lut: selectedLUT, settings: settings,
                   creativeOpacity: creativeOpacity, creativeBlend: creativeBlend)
    }

    /// Restores a stash without the side effects of a fresh pick: no
    /// remembered-strength load and no per-LUT strength write-back.
    func restoreGrade(_ stash: GradeStash) {
        isRestoringSession = true
        selectedLook = stash.look
        selectedLUT = stash.lut
        creativeOpacity = stash.creativeOpacity
        creativeBlend = stash.creativeBlend
        settings = stash.settings
        isRestoringSession = false
    }

    // MARK: - Premium gate

    /// The locked look in the grade-room grade (video, still, camera), or nil.
    /// A LUT in the creative slot replaces the recipe entirely, and LUTs are
    /// files the user already owns, so only a recipe grade can be locked.
    func lockedLookInGrade(_ store: StoreService) -> LookLock? {
        // Strength 0 is the Original/OFF tile: the look renders nothing.
        guard settings.intensity > 0 else { return nil }
        // A pack look being tried on is free to frame with, and asks here.
        if let preview = packPreview, let pack = preview.pack, let look = preview.look {
            guard !store.ownsPack(pack.id) else { return nil }
            return LookLock(lookName: look.name,
                            pack: pack.isProIncluded ? nil : pack,
                            previewPackID: pack.id,
                            freeLookName: preview.freeAlternative?.name)
        }
        guard selectedLUT == nil else { return nil }
        return store.lock(forBuiltIn: selectedLook)
    }

    /// The first locked look anywhere in the editor project: any clip that
    /// follows the timeline grade, every per-clip grade and every adjustment
    /// layer. Checked at export so a premium look cannot ride out on a clip.
    func lockedLookInProject(_ store: StoreService) -> LookLock? {
        if editor.clips.contains(where: { $0.grade == nil }),
           let lock = lockedLookInGrade(store) {
            return lock
        }
        for grade in editor.clips.compactMap(\.grade) + editor.adjustmentLayers.map(\.grade) {
            if let lock = store.lock(for: grade) { return lock }
        }
        return nil
    }

    /// The free way out of the lock: the grade-room look becomes its closest
    /// free look (`MockData.freeAlternative`). Strength and every adjustment
    /// stay as they were, so only the base look changes.
    func useFreeLookInGrade(_ store: StoreService) {
        guard lockedLookInGrade(store) != nil else { return }
        if let preview = packPreview {
            if let free = preview.freeAlternative {
                wear(free, store: store)
            } else {
                selectedLook = MockData.defaultLook
            }
            return
        }
        selectedLook = MockData.freeAlternative(to: selectedLook)
    }

    /// The same for a whole editor project: the timeline grade, every
    /// per-clip grade and every adjustment layer wearing a locked look moves
    /// to its closest free look, in one undo step.
    func useFreeLooksInProject(_ store: StoreService) {
        if editor.clips.contains(where: { $0.grade == nil }) {
            useFreeLookInGrade(store)
        }
        editor.replaceGrades { grade in
            guard store.lock(for: grade) != nil,
                  let preset = MockData.looks.first(where: { $0.name == grade.baseLookName })
            else { return nil }
            var free = grade
            free.baseLookName = MockData.freeAlternative(to: preset).name
            return free
        }
    }

    // MARK: - Export

    func exportCurrentVideo(spec: ExportSpec = ExportSpec()) async -> Bool {
        if let image = selectedImage {
            return await exportStill(image)
        }
        guard let url = selectedVideoURL else {
            exportError = VideoExportError.noVideoSelected.localizedDescription
            return false
        }
        exportError = nil
        lastExportGIFURL = nil
        lookState.splitFraction = nil
        do {
            // Audio-only has to branch HERE. `exporter.export(videoURL:...)`
            // always builds a video composition and returns a video, so the
            // grade flow was handing back an ordinary graded movie while the
            // sheet promised "AAC · M4A". The editor flow already had this
            // branch (EditorScreen.swift, startExport) — the grade flow never
            // called the M4A path at all.
            if spec.audioOnly {
                let output = try await exporter.exportAudioOnly(
                    asset: AVURLAsset(url: url), audioMix: nil)
                // Photos rejects bare audio, so this is share-only.
                lastExportSavedToPhotos = false
                lastExportImage = nil
                lastExportURL = output
                return true
            }
            // Belt and braces for the sheet's own check: an HLG tag is only
            // honest on an ungraded frame (HDRDelivery).
            var spec = spec
            if spec.hdr && gradeIsApplied { spec.hdr = false }
            let output = try await exporter.export(videoURL: url, lookState: lookState, spec: spec)
            lastExportSavedToPhotos = await exporter.saveToPhotos(url: output)
            lastExportImage = nil
            lastExportURL = output
            return true
        } catch is CancellationError {
            return false
        } catch {
            exportError = error.localizedDescription
            return false
        }
    }

    /// Grades and saves a still image to the photo library.
    private func exportStill(_ image: CIImage) async -> Bool {
        exportError = nil
        lastExportGIFURL = nil
        guard let cg = LookPipeline.shared.gradedStill(image, state: lookState) else {
            exportError = "Could not render the graded photo."
            return false
        }
        let ui = UIImage(cgImage: cg)
        // The graded photo ALWAYS succeeds — Photos access only decides
        // whether it auto-saves. Denied? The success screen offers the
        // share sheet and a Settings link instead of a dead end.
        let jpegURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Photo_\(UUID().uuidString).jpg")
        guard let jpegData = ui.jpegData(compressionQuality: 0.92) else {
            exportError = "Could not encode the graded photo."
            return false
        }
        do {
            try jpegData.write(to: jpegURL, options: .atomic)
        } catch {
            exportError = error.localizedDescription
            return false
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            lastExportSavedToPhotos = false
            lastExportURL = jpegURL
            lastExportImage = cg
            return true
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: ui)
            }
            lastExportSavedToPhotos = true
            lastExportURL = jpegURL
            lastExportImage = cg
            return true
        } catch {
            exportError = error.localizedDescription
            return false
        }
    }

    func resetToHome() {
        path = []
        tab = .home
        selectedVideoURL = nil
        selectedImage = nil
        selectedLUT = nil
        settings = LookSettings()
    }

    /// Store → Library hand-off (F1): the pack name the Looks tab should open
    /// pre-filtered to. Set by the store when an owned pack is tapped, and
    /// consumed + cleared by the look browser the first time it appears.
    @Published var libraryPackFilter: String?
}

// MARK: - SDR colour policy (SPEC_ADDENDUM §3)

extension AVMutableVideoComposition {
    /// Forces BT.709 so HDR (Dolby Vision) sources are tone-mapped before
    /// Core Image filtering — looks render identically in preview and export.
    func applySDRColorPolicy() {
        colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }
}

// MARK: - Photo edit (crop and mask)

extension AppModel {
    /// Photo edit: swaps the still for an edited copy (crop, mask) without
    /// detaching the grade session or clearing the source conversion. The
    /// next autosave writes the edited pixels into the same Recent project.
    func replaceSelectedStill(with image: CIImage) {
        isRestoringSession = true
        selectedImage = image
        isRestoringSession = false
        sessionMediaFileName = nil
    }
}

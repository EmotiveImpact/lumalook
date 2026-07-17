import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import CoreImage

@MainActor
final class AppModel: ObservableObject {
    // Navigation
    @Published var path: [LumaRoute] = []
    @Published var tab: LumaTab = .home

    // Apply a Look flow — video OR still image (SPEC_ADDENDUM §5)
    @Published var selectedVideoURL: URL? {
        didSet {
            rebuildPlayer()
            updatePreviewFrame()
            if !isRestoringSession { detachGradeSession() }
        }
    }
    @Published var selectedImage: CIImage? {
        didSet {
            if selectedImage != nil { selectedVideoURL = nil }
            updatePreviewFrame()
            if !isRestoringSession { detachGradeSession() }
        }
    }

    // MARK: Batch grading (queue #10)

    /// Extra picked items queued behind the previewed one — the whole set
    /// exports with the SAME grade.
    @Published var batchItems: [PhotosPickerItem] = []
    @Published var batchStatus: String?

    /// Applies the current grade to every batch item sequentially, saving
    /// each to Photos. Returns how many succeeded.
    func runBatchExport(spec: ExportSpec) async -> Int {
        let items = batchItems
        guard !items.isEmpty else { return 0 }
        var succeeded = 0
        for (index, item) in items.enumerated() {
            batchStatus = "PROCESSING \(index + 1) OF \(items.count)"
            if let video = try? await item.loadTransferable(type: PickedVideo.self) {
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
            creativeBlend: creativeBlend.rawValue))
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
        creativeOpacity = session.creativeOpacity ?? 100
        creativeBlend = session.creativeBlend.flatMap(LUTBlendMode.init) ?? .normal
        settings = session.settings
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
    @Published var selectedLook: LookPreset = MockData.looks[2] {
        didSet { syncLookState() }
    }
    @Published var selectedLUT: LUTFile? {
        didSet {
            syncLookState()
            applyRememberedStrength()
        }
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
    @Published var conversionLUT: LUTFile? {
        didSet { syncLookState() }
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

    init() {
        // Without an explicit .playback category, iOS mutes ALL app audio
        // whenever the ring/silent switch is on silent — the classic
        // "imported video has no sound" bug. Every media app sets this.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        syncLookState()
        applyDebugRoute()
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
        // Auto-grade cell: load a cast image, run autoGrade, print result.
        if let path = env["LUMA_SEED_AUTOGRADE"], FileManager.default.fileExists(atPath: path) {
            selectedImage = CIImage(contentsOf: URL(fileURLWithPath: path))
            Task {
                await autoGrade()
                print("[LUMA] autograde warmth=\(Int(settings.warmth)) tint=\(Int(settings.tint)) exp=\(Int(settings.exposure))")
            }
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
        // Headless open-in-place check: LUMA_OPEN_FILE=<host path>.
        if let openPath = env["LUMA_OPEN_FILE"], FileManager.default.fileExists(atPath: openPath) {
            handleIncomingFile(url: URL(fileURLWithPath: openPath))
        }
        #endif
        #if DEBUG
        guard let route = ProcessInfo.processInfo.environment["LUMA_ROUTE"] else { return }
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
            "customLook": [.selectClip, .applyLook, .customLook]
        ]
        if let target = map[route] {
            path = target
        }
        #endif
    }

    private func syncLookState() {
        lookState.recipe = selectedLook.recipe
        lookState.settings = settings
        if let lut = selectedLUT {
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
        lookState.lutOpacity = creativeOpacity / 100.0
        lookState.lutBlend = creativeBlend
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
        lookState.splitFraction = nil
        do {
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
        try? ui.jpegData(compressionQuality: 0.92)?.write(to: jpegURL)
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

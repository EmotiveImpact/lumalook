import SwiftUI
import AVFoundation
import Photos
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
        }
    }
    @Published var selectedImage: CIImage? {
        didSet {
            if selectedImage != nil { selectedVideoURL = nil }
            updatePreviewFrame()
        }
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
        didSet { syncLookState() }
    }
    @Published var settings = LookSettings() {
        didSet { syncLookState() }
    }

    // Export results — one of the two
    @Published var lastExportURL: URL?
    @Published var lastExportImage: CGImage?
    @Published var exportError: String?

    let lutRepository = LUTRepository()
    let exporter = VideoExporter()
    let store = PersistenceStore()
    let packStore = PackStore()

    /// Pack the Store is currently showing in Pack Detail.
    @Published var selectedPackID: String?

    /// Live grade state read by preview and export frame handlers.
    let lookState = LookState()

    /// Phase 5 editor: multi-clip composition timeline sharing the same look state.
    private(set) lazy var editor = EditorState(lookState: lookState, store: store)

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
    private func applyDebugRoute() {
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
            "settings": [.settings]
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

    func exportCurrentVideo() async -> Bool {
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
            let output = try await exporter.export(videoURL: url, lookState: lookState)
            try await exporter.saveToPhotos(url: output)
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
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            exportError = "Allow photo library access to save your photo."
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: ui)
            }
            // Also write a JPEG so the share sheet has a file to offer.
            let jpegURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LumaLook_Photo_\(UUID().uuidString).jpg")
            try? ui.jpegData(compressionQuality: 0.92)?.write(to: jpegURL)
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

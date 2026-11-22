import SwiftUI
import UIKit
import Photos
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Select clips: hand-off

/// What the Select clips screen was opened for. Set it through
/// `AppModel.openSelectClips(_:templateID:)` before the screen is pushed; a
/// plain push of `.selectClip` is the grade flow, as it always was.
enum SelectClipIntent: Equatable {
    /// Apply a look: the first pick previews in the grade room, extra picks
    /// are batch-graded with the same grade on export.
    case grade
    /// New photo: same hand-off as `.grade`, opens on Photos.
    case photo
    /// New video: the picks become the clips of a new editor project.
    case edit

    var defaultFilter: RollFilter {
        switch self {
        case .grade: return .all
        case .photo: return .photos
        case .edit: return .videos
        }
    }

    /// The batch grader has always taken up to 10 items; a cut can take more.
    var maxPicks: Int { self == .edit ? 30 : 10 }
}

extension AppModel {
    /// Opens Select clips for a purpose. A template id (Home's beat-cut rail)
    /// always means editing: the picked clips land in a new editor project
    /// with that template applied.
    func openSelectClips(_ intent: SelectClipIntent, templateID: String? = nil) {
        selectClipIntent = templateID == nil ? intent : .edit
        pendingTemplateID = templateID
        path.append(.selectClip)
    }
}

// MARK: - Grid model

enum RollFilter: String, CaseIterable {
    case videos = "Videos"
    case photos = "Photos"
    case all = "All"
}

enum RollAccess: Equatable {
    /// Waiting on the system prompt (or not asked yet).
    case asking
    case full
    case limited
    case denied
    /// DEBUG only: the bundled hero photos stand in for the library.
    case samples
}

struct RollAlbum: Identifiable {
    let id: String
    let title: String
    /// Nil is Recents: the whole library.
    let collection: PHAssetCollection?

    static var recents: RollAlbum { RollAlbum(id: "recents", title: "Recents", collection: nil) }
}

/// One cell of the grid: a library asset, or a bundled sample in DEBUG.
struct RollTile: Identifiable, Equatable {
    let id: String
    let isVideo: Bool
    /// Seconds; zero for photos.
    let duration: Double
    let asset: PHAsset?
    let sample: HeroPhoto?

    init(id: String, isVideo: Bool, duration: Double, asset: PHAsset?, sample: HeroPhoto?) {
        self.id = id
        self.isVideo = isVideo
        self.duration = duration
        self.asset = asset
        self.sample = sample
    }

    init(asset: PHAsset) {
        self.init(id: asset.localIdentifier,
                  isVideo: asset.mediaType == .video,
                  duration: asset.mediaType == .video ? asset.duration : 0,
                  asset: asset,
                  sample: nil)
    }

    /// Stands in for an index that has just gone out of range mid-refresh.
    static func placeholder(_ index: Int) -> RollTile {
        RollTile(id: "missing-\(index)", isVideo: false, duration: 0, asset: nil, sample: nil)
    }

    var isPickable: Bool { asset != nil || sample != nil }

    static func == (lhs: RollTile, rhs: RollTile) -> Bool { lhs.id == rhs.id }
}

/// The app's own photo library grid: authorisation, the newest-first fetch
/// for the current album and filter, and thumbnail caching.
@MainActor
final class RollLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var access: RollAccess = .asking
    @Published private(set) var albums: [RollAlbum] = [RollAlbum.recents]
    @Published private(set) var album: RollAlbum = RollAlbum.recents
    @Published private(set) var filter: RollFilter = .all
    @Published private(set) var fetchResult: PHFetchResult<PHAsset>?
    @Published private(set) var sampleTiles: [RollTile] = []
    /// Download progress (0...1) of the item being prepared, while Photos
    /// fetches it from iCloud. Zero when the item is already on the phone.
    @Published var downloadProgress: Double = 0
    @Published private(set) var debugLimitedRow = false

    private var allSamples: [RollTile] = []
    /// DEBUG samples are showing (or a DEBUG state is forced), so the real
    /// library's permission must not take over.
    private var isSeeded = false
    /// Read in deinit, which is nonisolated.
    nonisolated(unsafe) private var isObserving = false
    private var refreshTask: Task<Void, Never>?
    private var cachedRange: Range<Int> = 0..<0
    private var cachedSide: CGFloat = 0
    private lazy var cachingManager = PHCachingImageManager()

    var usesSamples: Bool { access == .samples }
    var isBrowsable: Bool { access == .full || access == .limited || access == .samples }
    var showsLimitedRow: Bool { access == .limited || debugLimitedRow }
    /// Nil until the library is readable, so nothing touches PhotoKit early.
    var thumbnailManager: PHCachingImageManager? {
        (access == .full || access == .limited) ? cachingManager : nil
    }

    var count: Int {
        if usesSamples { return sampleTiles.count }
        return fetchResult?.count ?? 0
    }

    func tile(at index: Int) -> RollTile {
        if usesSamples {
            return index < sampleTiles.count ? sampleTiles[index] : RollTile.placeholder(index)
        }
        guard let result = fetchResult, index >= 0, index < result.count else {
            return RollTile.placeholder(index)
        }
        return RollTile(asset: result.object(at: index))
    }

    /// The first two samples, pre-picked so the DEBUG screenshot shows the
    /// numbered badges and the tray.
    var seedPicks: [RollTile] { Array(allSamples.prefix(2)) }

    deinit {
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // MARK: Access

    func start(filter startFilter: RollFilter) async {
        filter = startFilter
        #if DEBUG
        if SelectClipDebug.usesSamples {
            loadSamples()
            return
        }
        #endif
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            access = .asking
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        apply(status)
    }

    /// Back from Settings: pick up a changed permission.
    func recheckAccess() {
        guard !isSeeded else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status != .notDetermined, Self.accessLevel(for: status) != access else { return }
        apply(status)
    }

    private static func accessLevel(for status: PHAuthorizationStatus) -> RollAccess {
        switch status {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined: return .asking
        default: return .denied
        }
    }

    private func apply(_ status: PHAuthorizationStatus) {
        access = Self.accessLevel(for: status)
        guard access == .full || access == .limited else {
            fetchResult = nil
            return
        }
        // Registering before authorisation can raise the prompt itself, so
        // the observer only goes on once access is settled.
        if !isObserving {
            PHPhotoLibrary.shared().register(self)
            isObserving = true
        }
        loadAlbums()
        refetch()
    }

    /// Limited access: lets the person add more photos to what LumaLook sees.
    func presentLimitedPicker() {
        #if DEBUG
        if usesSamples { return }
        #endif
        guard let presenter = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: Fetching

    func setFilter(_ newFilter: RollFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        reload()
    }

    func select(_ newAlbum: RollAlbum) {
        guard newAlbum.id != album.id else { return }
        album = newAlbum
        reload()
    }

    private func reload() {
        if usesSamples {
            applySampleFilter()
        } else if access == .full || access == .limited {
            refetch()
        }
    }

    private func refetch() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let image = PHAssetMediaType.image.rawValue
        let video = PHAssetMediaType.video.rawValue
        switch filter {
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", video)
        case .photos:
            options.predicate = NSPredicate(format: "mediaType == %d", image)
        case .all:
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", image, video)
        }
        cachingManager.stopCachingImagesForAllAssets()
        cachedRange = 0..<0
        if let collection = album.collection {
            fetchResult = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            fetchResult = PHAsset.fetchAssets(with: options)
        }
    }

    private func loadAlbums() {
        var list: [RollAlbum] = [RollAlbum.recents]
        let favourites = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        if let favourite = favourites.firstObject {
            list.append(RollAlbum(id: favourite.localIdentifier, title: "Favourites",
                                  collection: favourite))
        }
        let mine = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        let shown = min(mine.count, 40)
        if shown > 0 {
            for index in 0..<shown {
                let collection = mine.object(at: index)
                list.append(RollAlbum(id: collection.localIdentifier,
                                      title: collection.localizedTitle ?? "Album",
                                      collection: collection))
            }
        }
        albums = list
        if !list.contains(where: { $0.id == album.id }) {
            album = RollAlbum.recents
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.scheduleRefresh()
        }
    }

    /// Library changes arrive in bursts (iCloud sync, the limited picker), so
    /// they coalesce into one refetch.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.apply(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
    }

    // MARK: Thumbnails

    /// Keeps a window of thumbnails around the visible cell warm.
    func prefetch(around index: Int, pixelSide: CGFloat) {
        guard access == .full || access == .limited,
              let result = fetchResult, result.count > 0 else { return }
        let lower = max(0, index - 24)
        let upper = min(result.count, index + 36)
        guard lower < upper else { return }
        if pixelSide == cachedSide, !cachedRange.isEmpty,
           abs(lower - cachedRange.lowerBound) < 9,
           abs(upper - cachedRange.upperBound) < 9 {
            return
        }
        let options = RollThumbnails.options()
        let oldIndices = Set(cachedRange.filter { $0 < result.count })
        let newIndices = Set(lower..<upper)
        let removed = oldIndices.subtracting(newIndices).sorted().map { result.object(at: $0) }
        let added = newIndices.subtracting(oldIndices).sorted().map { result.object(at: $0) }
        if !removed.isEmpty, cachedSide > 0 {
            cachingManager.stopCachingImages(for: removed,
                                             targetSize: CGSize(width: cachedSide, height: cachedSide),
                                             contentMode: .aspectFill, options: options)
        }
        if !added.isEmpty {
            cachingManager.startCachingImages(for: added,
                                              targetSize: CGSize(width: pixelSide, height: pixelSide),
                                              contentMode: .aspectFill, options: options)
        }
        cachedRange = lower..<upper
        cachedSide = pixelSide
    }

    // MARK: DEBUG samples

    private func loadSamples() {
        isSeeded = true
        access = .samples
        // Durations as in the approved mock; zero is a photo.
        let plan: [(HeroPhoto, Double)] = [
            (.golden, 8), (.neon, 5), (.drive, 11),
            (.party, 6), (.rain, 0), (.gig, 14),
            (.skate, 9), (.campaign, 0), (.bridge, 4)
        ]
        var tiles: [RollTile] = []
        for round in 0..<3 {
            for (offset, entry) in plan.enumerated() {
                // Later rounds rotate the order and vary the durations so the
                // grid doesn't read as a repeat.
                let pick = plan[(offset + round * 4) % plan.count]
                let item = round == 0 ? entry : pick
                let seconds = item.1 > 0 ? item.1 + Double(round * 3) : 0
                tiles.append(RollTile(id: "sample-\(round)-\(offset)-\(item.0.rawValue)",
                                      isVideo: seconds > 0,
                                      duration: seconds,
                                      asset: nil,
                                      sample: item.0))
            }
        }
        allSamples = tiles
        #if DEBUG
        switch SelectClipDebug.forcedState ?? "" {
        case "denied":
            access = .denied
        case "limited":
            debugLimitedRow = true
        case "empty":
            allSamples = []
        default:
            break
        }
        #endif
        applySampleFilter()
    }

    private func applySampleFilter() {
        switch filter {
        case .all: sampleTiles = allSamples
        case .videos: sampleTiles = allSamples.filter { $0.isVideo }
        case .photos: sampleTiles = allSamples.filter { !$0.isVideo }
        }
    }
}

#if DEBUG
/// The CI simulator's library may be empty or unauthorised, so the
/// `LUMA_ROUTE=selectClip` screenshot shows a seeded grid of the bundled hero
/// photos instead. `LUMA_PICKER_REAL=1` opts back into the real library;
/// `LUMA_PICKER_STATE=denied|limited|empty` previews the other states.
enum SelectClipDebug {
    static var usesSamples: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["LUMA_ROUTE"] == "selectClip" && env["LUMA_PICKER_REAL"] != "1"
    }

    static var forcedState: String? {
        ProcessInfo.processInfo.environment["LUMA_PICKER_STATE"]
    }
}
#endif

// MARK: - Thumbnails

/// Thumbnail requests, kept off the main actor so PhotoKit's callbacks never
/// run inside main-actor-isolated closures.
enum RollThumbnails {
    static func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    static func request(_ asset: PHAsset, pixelSide: CGFloat, manager: PHImageManager,
                        completion: @escaping (UIImage) -> Void) -> PHImageRequestID {
        let side = max(120, pixelSide)
        return manager.requestImage(for: asset,
                                    targetSize: CGSize(width: side, height: side),
                                    contentMode: .aspectFill,
                                    options: options()) { image, _ in
            guard let image else { return }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
}

// MARK: - Turning picks into files

/// Why a pick couldn't be prepared, in words the person can act on.
enum SelectClipFailure: Equatable {
    case videoTransfer
    case videoUnreadable
    case photo
    case nothingLoaded

    var title: String {
        switch self {
        case .videoTransfer: return "Couldn't load that video"
        case .videoUnreadable: return "Can't play that video"
        case .photo: return "Couldn't load that photo"
        case .nothingLoaded: return "Couldn't load those clips"
        }
    }

    var detail: String {
        switch self {
        case .videoTransfer, .photo, .nothingLoaded:
            return "If it's stored in iCloud, check you're online and try again."
        case .videoUnreadable:
            return "This file has no video iOS can decode, so it can't be graded. Pick another clip."
        }
    }
}

/// A pick as the rest of the app wants it: a file in our temp folder (or a
/// bundled sample's file), the same thing the system picker used to hand over.
enum RollPick {
    case video(URL)
    case photo(URL)
    case failed(SelectClipFailure)
}

/// Copies picked library assets into temp files we own. iCloud originals
/// download on the way (network access is allowed) and report progress.
enum RollResolver {
    static func resolve(_ asset: PHAsset,
                        progress: @escaping @Sendable (Double) -> Void) async -> RollPick {
        if asset.mediaType == .video {
            return await video(for: asset, progress: progress)
        }
        return await photo(for: asset, progress: progress)
    }

    private static func video(for asset: PHAsset,
                              progress: @escaping @Sendable (Double) -> Void) async -> RollPick {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { value, _, _, _ in
            progress(value)
        }
        let once = RollResumeOnce()
        let loaded: AVAsset? = await withCheckedContinuation { (continuation: CheckedContinuation<AVAsset?, Never>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { result, _, _ in
                guard once.claim() else { return }
                continuation.resume(returning: result)
            }
        }
        guard let loaded else { return .failed(.videoTransfer) }

        var copied: URL?
        if let urlAsset = loaded as? AVURLAsset {
            let ext = urlAsset.url.pathExtension.isEmpty ? "mov" : urlAsset.url.pathExtension
            let destination = temporaryURL(ext)
            if (try? FileManager.default.copyItem(at: urlAsset.url, to: destination)) != nil {
                copied = destination
            }
        }
        if copied == nil {
            // Slo-mo and some edited videos arrive as a composition with no
            // single file behind them; render one out.
            copied = await exportCopy(of: loaded)
        }
        guard let copied else { return .failed(.videoTransfer) }
        guard await isGradeableVideo(copied) else {
            try? FileManager.default.removeItem(at: copied)
            return .failed(.videoUnreadable)
        }
        return .video(copied)
    }

    private static func exportCopy(of asset: AVAsset) async -> URL? {
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        let destination = temporaryURL("mov")
        session.outputURL = destination
        session.outputFileType = .mov
        await session.export()
        if session.status == .completed {
            return destination
        }
        try? FileManager.default.removeItem(at: destination)
        return nil
    }

    private struct PhotoPayload {
        let data: Data?
        let uti: String?
    }

    private static func photo(for asset: PHAsset,
                              progress: @escaping @Sendable (Double) -> Void) async -> RollPick {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        options.progressHandler = { value, _, _, _ in
            progress(value)
        }
        let once = RollResumeOnce()
        let payload: PhotoPayload = await withCheckedContinuation { (continuation: CheckedContinuation<PhotoPayload, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                guard once.claim() else { return }
                continuation.resume(returning: PhotoPayload(data: data, uti: uti))
            }
        }
        guard let data = payload.data, !data.isEmpty else { return .failed(.photo) }
        var ext = "jpg"
        if let uti = payload.uti, let type = UTType(uti), let preferred = type.preferredFilenameExtension {
            ext = preferred
        }
        let destination = temporaryURL(ext)
        guard (try? data.write(to: destination)) != nil else { return .failed(.photo) }
        return .photo(destination)
    }

    private static func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Picked_\(UUID().uuidString).\(ext)")
    }

    /// A file can copy out of Photos and still be useless to us: no video
    /// track at all, or a codec this device can't decode. Catch that here
    /// rather than on a black preview two screens later.
    static func isGradeableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds > 0
    }
}

/// PhotoKit calls these result handlers once; this makes sure a stray second
/// call can never resume a checked continuation twice.
private final class RollResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - Formatting

enum RollClock {
    /// "0:08", "12:40", "1:02:03".
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = max(1, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

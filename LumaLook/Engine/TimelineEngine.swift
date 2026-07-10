import Foundation
import AVFoundation
import CoreImage
import SwiftUI

// MARK: - Editor formats

enum EditorFormat: String, CaseIterable {
    case widescreen = "16:9"
    case vertical = "9:16"
    case square = "1:1"
    case portrait = "4:5"

    var renderSize: CGSize {
        switch self {
        case .widescreen: return CGSize(width: 1920, height: 1080)
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .portrait: return CGSize(width: 1080, height: 1350)
        }
    }

    var subtitle: String {
        switch self {
        case .widescreen: return "Widescreen"
        case .vertical: return "Vertical"
        case .square: return "Instagram"
        case .portrait: return "Portrait"
        }
    }

    var icon: String {
        switch self {
        case .widescreen: return "rectangle"
        case .vertical: return "rectangle.portrait"
        case .square: return "square"
        case .portrait: return "rectangle.portrait.on.rectangle.portrait"
        }
    }

    var aspect: CGFloat { renderSize.width / renderSize.height }
}

// MARK: - Editor state & composition engine

@MainActor
final class EditorState: ObservableObject {

    struct Clip: Identifiable {
        let id: UUID
        let url: URL
        var assetDuration: Double
        var trimStart: Double
        var trimEnd: Double
        var speed: Double = 1.0
        var thumbnail: CGImage?

        /// Duration this clip occupies on the timeline after trim + speed.
        var timelineDuration: Double { max(0, (trimEnd - trimStart) / speed) }
    }

    private struct Snapshot {
        var clips: [Clip]
        var format: EditorFormat
        var zoom: Double
    }

    /// Per-clip data the frame handler needs, precomputed on rebuild.
    private struct FrameMeta {
        let start: Double
        let end: Double
        let transform: CGAffineTransform
    }

    // Timeline
    @Published private(set) var clips: [Clip] = []
    @Published var selectedClipID: UUID?

    // Canvas
    @Published var format: EditorFormat = .widescreen
    @Published var zoom: Double = 100

    // Audio
    @Published var volume: Double = 100
    @Published var fadeIn: Double = 0
    @Published var fadeOut: Double = 0
    @Published var muteAudio = false

    // Playback
    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var totalDuration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isRebuilding = false

    // History
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let lookState: LookState
    private let store: PersistenceStore
    private(set) var projectID = UUID()
    private var projectCreatedAt = Date()
    @Published var projectTitle = "New Project"
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(lookState: LookState, store: PersistenceStore) {
        self.lookState = lookState
        self.store = store
    }

    var selectedClip: Clip? {
        clips.first { $0.id == selectedClipID }
    }

    var isEmpty: Bool { clips.isEmpty }

    /// Timeline start offsets per clip, in seconds.
    var clipStartTimes: [UUID: Double] {
        var result: [UUID: Double] = [:]
        var cursor = 0.0
        for clip in clips {
            result[clip.id] = cursor
            cursor += clip.timelineDuration
        }
        return result
    }

    // MARK: - Persistence (SPEC_ADDENDUM §2)

    /// Debounced auto-save after every timeline mutation.
    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveProject()
        }
    }

    func saveProject() {
        guard !clips.isEmpty else { return }
        let stored = StoredProject(
            id: projectID, title: projectTitle,
            createdAt: projectCreatedAt, updatedAt: Date(),
            clips: clips.map {
                StoredClip(id: $0.id, fileName: $0.url.lastPathComponent,
                           assetDuration: $0.assetDuration,
                           trimStart: $0.trimStart, trimEnd: $0.trimEnd, speed: $0.speed)
            },
            format: format.rawValue, zoom: zoom,
            volume: volume, fadeIn: fadeIn, fadeOut: fadeOut, muteAudio: muteAudio,
            duration: clips.reduce(0) { $0 + $1.timelineDuration }
        )
        store.upsert(project: stored)
    }

    func load(project: StoredProject) {
        projectID = project.id
        projectCreatedAt = project.createdAt
        projectTitle = project.title
        format = EditorFormat(rawValue: project.format) ?? .widescreen
        zoom = project.zoom
        volume = project.volume
        fadeIn = project.fadeIn
        fadeOut = project.fadeOut
        muteAudio = project.muteAudio
        undoStack.removeAll()
        redoStack.removeAll()
        updateHistoryFlags()
        clips = project.clips.compactMap { stored in
            let url = store.clipURL(for: stored)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Clip(id: stored.id, url: url, assetDuration: stored.assetDuration,
                        trimStart: stored.trimStart, trimEnd: stored.trimEnd, speed: stored.speed)
        }
        selectedClipID = clips.last?.id
        rebuild(keepPosition: false)
        // Restore thumbnails asynchronously.
        for clip in clips {
            Task { [id = clip.id, url = clip.url, at = clip.trimStart] in
                let thumb = await Self.thumbnail(for: AVURLAsset(url: url), at: at + 0.02)
                if let i = self.clips.firstIndex(where: { $0.id == id }) {
                    self.clips[i].thumbnail = thumb
                }
            }
        }
    }

    func startNewProject() {
        saveProject()
        projectID = UUID()
        projectCreatedAt = Date()
        projectTitle = "New Project"
        clips = []
        selectedClipID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        updateHistoryFlags()
        rebuild(keepPosition: false)
    }

    // MARK: - Mutations

    func addClip(from url: URL) async {
        // Copy into the durable clip library so projects survive temp cleanup.
        let durableURL = url.path.hasPrefix(store.clipsFolder.path)
            ? url
            : (store.importClipFile(from: url) ?? url)
        let asset = AVURLAsset(url: durableURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.05 else { return }
        pushUndoSnapshot()
        var clip = Clip(id: UUID(), url: durableURL, assetDuration: duration,
                        trimStart: 0, trimEnd: duration)
        clip.thumbnail = await Self.thumbnail(for: asset, at: 0.03)
        clips.append(clip)
        selectedClipID = clip.id
        rebuild()
    }

    /// Moves the selected clip one position left or right.
    func moveSelected(by offset: Int) {
        guard let id = selectedClipID,
              let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard clips.indices.contains(target) else { return }
        pushUndoSnapshot()
        clips.swapAt(index, target)
        rebuild()
    }

    func deleteSelected() {
        guard let id = selectedClipID, clips.contains(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        clips.removeAll { $0.id == id }
        selectedClipID = clips.last?.id
        rebuild()
    }

    /// Splits the clip under the playhead at the current time.
    func splitAtPlayhead() {
        let starts = clipStartTimes
        guard let index = clips.firstIndex(where: { clip in
            guard let start = starts[clip.id] else { return false }
            return currentTime > start + 0.15 && currentTime < start + clip.timelineDuration - 0.15
        }) else { return }

        let clip = clips[index]
        let localOffset = (currentTime - (starts[clip.id] ?? 0)) * clip.speed
        let splitPoint = clip.trimStart + localOffset

        pushUndoSnapshot()
        var first = clip
        first.trimEnd = splitPoint
        let second = Clip(id: UUID(), url: clip.url, assetDuration: clip.assetDuration,
                          trimStart: splitPoint, trimEnd: clip.trimEnd,
                          speed: clip.speed, thumbnail: clip.thumbnail)
        clips[index] = first
        clips.insert(second, at: index + 1)
        selectedClipID = second.id

        // Refresh the second half's thumbnail to its new first frame.
        Task { [id = second.id, url = clip.url] in
            let thumb = await Self.thumbnail(for: AVURLAsset(url: url), at: splitPoint + 0.02)
            if let i = self.clips.firstIndex(where: { $0.id == id }) {
                self.clips[i].thumbnail = thumb
            }
        }
        rebuild()
    }

    func applyTrim(start: Double, end: Double) {
        guard let id = selectedClipID,
              let index = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        clips[index].trimStart = max(0, min(start, end - 0.2))
        clips[index].trimEnd = min(clips[index].assetDuration, max(end, start + 0.2))
        let clip = clips[index]
        Task { [id = clip.id, url = clip.url, at = clip.trimStart] in
            let thumb = await Self.thumbnail(for: AVURLAsset(url: url), at: at + 0.02)
            if let i = self.clips.firstIndex(where: { $0.id == id }) {
                self.clips[i].thumbnail = thumb
            }
        }
        rebuild()
    }

    func setSpeed(_ speed: Double) {
        guard let id = selectedClipID,
              let index = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        clips[index].speed = speed
        rebuild()
    }

    func setFormat(_ newFormat: EditorFormat, zoom newZoom: Double) {
        pushUndoSnapshot()
        format = newFormat
        zoom = newZoom
        rebuild()
    }

    /// Audio settings only need a new mix, not a full composition rebuild.
    func applyAudioSettings() {
        guard let item = player?.currentItem else { return }
        item.audioMix = makeAudioMix(for: item.asset)
    }

    // MARK: - Undo / redo

    private func pushUndoSnapshot() {
        undoStack.append(Snapshot(clips: clips, format: format, zoom: zoom))
        redoStack.removeAll()
        updateHistoryFlags()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(clips: clips, format: format, zoom: zoom))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(clips: clips, format: format, zoom: zoom))
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        clips = snapshot.clips
        format = snapshot.format
        zoom = snapshot.zoom
        if let id = selectedClipID, !clips.contains(where: { $0.id == id }) {
            selectedClipID = clips.last?.id
        }
        updateHistoryFlags()
        rebuild()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Playback control

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if totalDuration > 0, currentTime >= totalDuration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), totalDuration)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func seekToBoundary(forward: Bool) {
        var boundaries: [Double] = [0]
        var cursor = 0.0
        for clip in clips {
            cursor += clip.timelineDuration
            boundaries.append(cursor)
        }
        if forward {
            if let next = boundaries.first(where: { $0 > currentTime + 0.05 }) {
                seek(to: min(next, totalDuration - 0.01))
            }
        } else {
            if let previous = boundaries.last(where: { $0 < currentTime - 0.05 }) {
                seek(to: previous)
            }
        }
    }

    // MARK: - Composition building

    func rebuild(keepPosition: Bool = true) {
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuildAsync(keepPosition: keepPosition) }
        scheduleAutosave()
    }

    private func rebuildAsync(keepPosition: Bool) async {
        isRebuilding = true
        defer { isRebuilding = false }

        let resumeAt = keepPosition ? currentTime : 0
        detachObservers()

        guard let built = try? await buildComposition() else {
            player?.pause()
            player = nil
            totalDuration = 0
            currentTime = 0
            isPlaying = false
            return
        }

        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = makeAudioMix(for: built.composition)
        item.audioTimePitchAlgorithm = .spectral

        let player = self.player ?? AVPlayer()
        player.replaceCurrentItem(with: item)
        self.player = player
        totalDuration = built.duration
        attachObservers(to: item)

        let target = min(resumeAt, max(0, totalDuration - 0.01))
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        if isPlaying { player.play() }
    }

    /// Builds the composition + video composition for preview or export.
    func buildComposition() async throws -> (composition: AVMutableComposition,
                                             videoComposition: AVMutableVideoComposition,
                                             duration: Double) {
        guard !clips.isEmpty else { throw VideoExportError.noVideoSelected }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoExportError.exportSessionCreationFailed
        }
        // Created lazily: an empty audio track makes AVAssetExportSession
        // fail with "Operation Stopped" when no clip carries audio.
        var audioTrack: AVMutableCompositionTrack?

        var cursor = CMTime.zero
        var metas: [FrameMeta] = []

        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first
            let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity

            let timescale = CMTimeScale(600)
            let range = CMTimeRange(
                start: CMTime(seconds: clip.trimStart, preferredTimescale: timescale),
                duration: CMTime(seconds: clip.trimEnd - clip.trimStart, preferredTimescale: timescale)
            )

            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            var insertedAudio = false
            if let sourceAudio {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let audioTrack {
                    try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                    insertedAudio = true
                }
            }

            var insertedDuration = range.duration
            if clip.speed != 1.0 {
                let scaled = CMTime(seconds: (clip.trimEnd - clip.trimStart) / clip.speed,
                                    preferredTimescale: timescale)
                let insertedRange = CMTimeRange(start: cursor, duration: range.duration)
                videoTrack.scaleTimeRange(insertedRange, toDuration: scaled)
                if insertedAudio {
                    audioTrack?.scaleTimeRange(insertedRange, toDuration: scaled)
                }
                insertedDuration = scaled
            }

            metas.append(FrameMeta(start: cursor.seconds,
                                   end: (cursor + insertedDuration).seconds,
                                   transform: transform))
            cursor = cursor + insertedDuration
        }

        guard !metas.isEmpty else { throw VideoExportError.noVideoSelected }

        // One CI handler does orientation, aspect-fill crop into the chosen
        // format, and the active look — for preview and export alike.
        let pipeline = LookPipeline.shared
        let state = lookState
        let renderSize = format.renderSize
        let zoomFactor = max(1.0, zoom / 100.0)
        let frameMetas = metas

        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            let seconds = request.compositionTime.seconds
            let meta = frameMetas.last(where: { seconds >= $0.start - 0.001 && seconds < $0.end + 0.001 })
                ?? frameMetas[0]

            var image = request.sourceImage
            if !meta.transform.isIdentity {
                image = image.transformed(by: meta.transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                                y: -image.extent.minY))
            }

            // Aspect-fill into the render canvas, honouring zoom.
            let sx = renderSize.width / image.extent.width
            let sy = renderSize.height / image.extent.height
            let scale = max(sx, sy) * zoomFactor
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = (renderSize.width - image.extent.width) / 2 - image.extent.minX
            let dy = (renderSize.height - image.extent.height) / 2 - image.extent.minY
            image = image.transformed(by: CGAffineTransform(translationX: dx, y: dy))

            let graded = pipeline.apply(state: state, to: image.clampedToExtent(), includeSplit: false)
            request.finish(with: graded.cropped(to: CGRect(origin: .zero, size: renderSize)),
                           context: pipeline.context)
        }
        videoComposition.renderSize = renderSize
        videoComposition.applySDRColorPolicy()

        return (composition, videoComposition, cursor.seconds)
    }

    func makeAudioMix(for asset: AVAsset) -> AVAudioMix? {
        guard let track = asset.tracks(withMediaType: .audio).first,
              !track.segments.isEmpty else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let base = Float(muteAudio ? 0 : volume / 100.0)
        let total = totalDuration > 0 ? totalDuration : asset.duration.seconds

        parameters.setVolume(base, at: .zero)
        if !muteAudio, fadeIn > 0.05, total > fadeIn {
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: base,
                                     timeRange: CMTimeRange(start: .zero,
                                                            duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
        }
        if !muteAudio, fadeOut > 0.05, total > fadeOut {
            let start = CMTime(seconds: total - fadeOut, preferredTimescale: 600)
            parameters.setVolumeRamp(fromStartVolume: base, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: start,
                                                            duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    // MARK: - Observers

    private func attachObservers(to item: AVPlayerItem) {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    private func detachObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    // MARK: - Thumbnails

    nonisolated static func thumbnail(for asset: AVAsset, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

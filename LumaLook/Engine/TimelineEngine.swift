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
        var hasAudio: Bool = false
        var thumbnail: CGImage?
        /// Per-second frames across the trimmed range for the timeline
        /// filmstrip (capped; regenerated on trim/split).
        var filmstrip: [CGImage] = []

        /// Duration this clip occupies on the timeline after trim + speed.
        var timelineDuration: Double { max(0, (trimEnd - trimStart) / speed) }
    }

    /// A single background-music track laid under the video clips.
    struct MusicTrack: Identifiable {
        let id: UUID
        let url: URL                  // in PersistenceStore audio folder
        var title: String             // display name (original filename stem)
        var assetDuration: Double
        var trimStart: Double         // seconds into the audio file
        var trimEnd: Double
        var timelineOffset: Double    // where the music starts on the timeline
        var volume: Double = 100      // 0…100, independent of clip-audio volume
        var isMuted: Bool = false
        /// Whole-file RMS buckets for the lane waveform (regenerated, not persisted).
        var waveform: [Float] = []

        var timelineDuration: Double { max(0, trimEnd - trimStart) }
    }

    /// Everything one `buildComposition()` pass produces — shared between
    /// the preview player and the exporter so both hear the same mix.
    struct BuiltTimeline {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVAudioMix?
        let clipAudioTrack: AVMutableCompositionTrack?
        let musicAudioTracks: [(id: UUID, track: AVMutableCompositionTrack)]
        let duration: Double
    }

    private struct Snapshot {
        var clips: [Clip]
        var format: EditorFormat
        var zoom: Double
        var audioTracks: [MusicTrack]
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
    @Published private(set) var audioTracks: [MusicTrack] = []

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
    /// Composition tracks from the last preview rebuild, kept so
    /// `applyAudioSettings()` can regenerate the mix without a rebuild.
    /// (`AVAudioMixInputParameters(track:)` only reads the trackID.)
    private var lastBuiltTracks: (clip: AVMutableCompositionTrack?, music: [(id: UUID, track: AVMutableCompositionTrack)]) = (nil, [])

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
            duration: clips.reduce(0) { $0 + $1.timelineDuration },
            music: nil,
            audioTracks: audioTracks.map {
                StoredMusic(id: $0.id, fileName: $0.url.lastPathComponent, title: $0.title,
                            assetDuration: $0.assetDuration,
                            trimStart: $0.trimStart, trimEnd: $0.trimEnd,
                            timelineOffset: $0.timelineOffset,
                            volume: $0.volume, isMuted: $0.isMuted)
            }
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
        let storedAudio = project.audioTracks ?? project.music.map { [$0] } ?? []
        audioTracks = storedAudio.compactMap { stored in
            let url = store.audioURL(for: stored)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return MusicTrack(id: stored.id, url: url, title: stored.title,
                              assetDuration: stored.assetDuration,
                              trimStart: stored.trimStart, trimEnd: stored.trimEnd,
                              timelineOffset: stored.timelineOffset,
                              volume: stored.volume, isMuted: stored.isMuted)
        }
        rebuild(keepPosition: false)
        refreshAllWaveforms()
        // Restore thumbnails + audio flags asynchronously.
        for clip in clips {
            Task { [id = clip.id, url = clip.url, at = clip.trimStart] in
                let asset = AVURLAsset(url: url)
                let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
                let thumb = await Self.thumbnail(for: asset, at: at + 0.02)
                if let i = self.clips.firstIndex(where: { $0.id == id }) {
                    self.clips[i].thumbnail = thumb
                    self.clips[i].hasAudio = hasAudio
                }
            }
            refreshFilmstrip(clipID: clip.id)
        }
    }

    func startNewProject() {
        saveProject()
        projectID = UUID()
        projectCreatedAt = Date()
        projectTitle = "New Project"
        clips = []
        selectedClipID = nil
        audioTracks = []
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
        clip.hasAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
        clip.thumbnail = await Self.thumbnail(for: asset, at: 0.03)
        clips.append(clip)
        selectedClipID = clip.id
        rebuild()
        refreshFilmstrip(clipID: clip.id)
    }

    /// Regenerates a clip's filmstrip (one frame per second across the
    /// trimmed range, capped) off the main thread and publishes it.
    func refreshFilmstrip(clipID: UUID) {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        let url = clip.url
        let start = clip.trimStart
        let end = clip.trimEnd
        Task {
            let frames = await Self.filmstripFrames(for: AVURLAsset(url: url),
                                                    start: start, end: end)
            guard !frames.isEmpty,
                  let i = self.clips.firstIndex(where: { $0.id == clipID }),
                  // Trim may have changed while we rendered; stale strips lie.
                  self.clips[i].trimStart == start, self.clips[i].trimEnd == end
            else { return }
            self.clips[i].filmstrip = frames
        }
    }

    nonisolated static func filmstripFrames(for asset: AVAsset,
                                            start: Double, end: Double,
                                            maxFrames: Int = 12) async -> [CGImage] {
        let span = max(0.1, end - start)
        let count = min(maxFrames, max(2, Int(span.rounded())))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 140, height: 140)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var frames: [CGImage] = []
        for i in 0..<count {
            let t = start + span * (Double(i) + 0.5) / Double(count)
            if let result = try? await generator.image(
                at: CMTime(seconds: min(t, end - 0.05), preferredTimescale: 600)) {
                frames.append(result.image)
            }
        }
        return frames
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

    /// Drag-to-reorder commit: move a clip to an arbitrary slot in one undo
    /// step. `slot` is the insertion index in the array *after* the clip has
    /// been lifted out.
    func moveClip(id: UUID, toSlot slot: Int) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(0, slot), clips.count - 1)
        guard clamped != index else { return }
        pushUndoSnapshot()
        let clip = clips.remove(at: index)
        clips.insert(clip, at: clamped)
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
                          speed: clip.speed, hasAudio: clip.hasAudio, thumbnail: clip.thumbnail)
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
        refreshFilmstrip(clipID: first.id)
        refreshFilmstrip(clipID: second.id)
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
        refreshFilmstrip(clipID: clip.id)
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
        item.audioMix = makeAudioMix(clipTrack: lastBuiltTracks.clip,
                                     musicTracks: lastBuiltTracks.music,
                                     duration: totalDuration)
    }

    // MARK: - Music track

    /// Synchronous copy into the durable audio library. Call while any
    /// security scope on `url` is still open, before any `await`.
    func importMusicFile(from url: URL) -> URL? {
        store.importAudioFile(from: url)
    }

    /// Attaches an already-imported audio file as the project's music track.
    /// Adds ANOTHER audio track (music, voiceover, sound) — CapCut-style
    /// stacking. New tracks start at the playhead so layering feels direct.
    func addAudioTrack(importedURL: URL, title: String) async {
        let asset = AVURLAsset(url: importedURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.05 else { return }
        pushUndoSnapshot()
        let offset = audioTracks.isEmpty ? 0 : min(currentTime, max(0, totalDuration - 0.2))
        audioTracks.append(MusicTrack(id: UUID(), url: importedURL, title: title,
                                      assetDuration: duration,
                                      trimStart: 0, trimEnd: duration, timelineOffset: offset))
        rebuild()
        refreshAllWaveforms()
    }

    /// Combined head-trim used by the lane's leading handle: content trims
    /// AND the bar's timeline position advances, so the tail stays anchored
    /// (standard NLE behaviour). One undo entry.
    func trimMusicHead(id: UUID, deltaSeconds: Double) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        let track = audioTracks[i]
        let newStart = min(max(0, track.trimStart + deltaSeconds), track.trimEnd - 0.2)
        let applied = newStart - track.trimStart
        guard abs(applied) > 0.01 else { return }
        pushUndoSnapshot()
        audioTracks[i].trimStart = newStart
        audioTracks[i].timelineOffset = min(max(0, track.timelineOffset + applied),
                                            max(0, totalDuration - 0.2))
        rebuild()
    }

    func trimMusicTail(id: UUID, deltaSeconds: Double) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        let track = audioTracks[i]
        let newEnd = max(min(track.assetDuration, track.trimEnd + deltaSeconds),
                         track.trimStart + 0.2)
        guard abs(newEnd - track.trimEnd) > 0.01 else { return }
        pushUndoSnapshot()
        audioTracks[i].trimEnd = newEnd
        rebuild()
    }

    /// Extracts RMS buckets from the audio files for the lane waveforms.
    func refreshAllWaveforms() {
        for track in audioTracks where track.waveform.isEmpty {
            let url = track.url
            let id = track.id
            Task.detached(priority: .utility) {
                let samples = Self.waveformSamples(url: url)
                await MainActor.run { [weak self] in
                    guard let self,
                          let i = self.audioTracks.firstIndex(where: { $0.id == id }) else { return }
                    self.audioTracks[i].waveform = samples
                }
            }
        }
    }

    nonisolated static func waveformSamples(url: URL, buckets: Int = 140) -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { return [] }

        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        let totalSeconds = asset.duration.seconds
        guard totalSeconds > 0 else { return [] }

        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: raw.baseAddress!)
            }
            let sampleCount = data.count
            guard sampleCount > 0 else { continue }
            let bufferSeconds = CMSampleBufferGetDuration(buffer).seconds
            for (i, value) in data.enumerated() {
                let t = pts + bufferSeconds * Double(i) / Double(sampleCount)
                let bucket = min(buckets - 1, max(0, Int(t / totalSeconds * Double(buckets))))
                let v = Double(value) / 32768.0
                sums[bucket] += v * v
                counts[bucket] += 1
            }
        }
        let rms = zip(sums, counts).map { sum, count -> Float in
            count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
        }
        let peak = max(rms.max() ?? 1, 0.001)
        return rms.map { min(1, $0 / peak) }
    }

    func removeAudioTrack(id: UUID) {
        guard audioTracks.contains(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        audioTracks.removeAll { $0.id == id }
        rebuild()
    }

    /// Volume is a mix-only change — no rebuild, no undo entry (live slider).
    func setMusicVolume(id: UUID, _ volume: Double) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        audioTracks[i].volume = min(max(0, volume), 100)
        applyAudioSettings()
        scheduleAutosave()
    }

    /// Mute keeps the track in the composition and zeroes the mix volume,
    /// so toggling never flashes a rebuild.
    func setMusicMuted(id: UUID, _ muted: Bool) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        audioTracks[i].isMuted = muted
        applyAudioSettings()
        scheduleAutosave()
    }

    func setMusicOffset(id: UUID, _ offset: Double) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(0, offset), max(0, totalDuration - 0.2))
        guard abs(clamped - audioTracks[i].timelineOffset) > 0.01 else { return }
        pushUndoSnapshot()
        audioTracks[i].timelineOffset = clamped
        rebuild()
    }

    // MARK: - Undo / redo

    private func pushUndoSnapshot() {
        undoStack.append(Snapshot(clips: clips, format: format, zoom: zoom, audioTracks: audioTracks))
        redoStack.removeAll()
        updateHistoryFlags()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(clips: clips, format: format, zoom: zoom, audioTracks: audioTracks))
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(clips: clips, format: format, zoom: zoom, audioTracks: audioTracks))
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        clips = snapshot.clips
        format = snapshot.format
        zoom = snapshot.zoom
        audioTracks = snapshot.audioTracks
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
            lastBuiltTracks = (nil, [])
            return
        }

        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        lastBuiltTracks = (built.clipAudioTrack, built.musicAudioTracks)

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

    /// Builds the composition + video composition + audio mix for preview or export.
    func buildComposition() async throws -> BuiltTimeline {
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

        // Every audio track rides on its own composition track, inserted
        // after the clip loop so clip speed changes (scaleTimeRange) can
        // never touch them. Tracks stay lazy: only added when real audio
        // actually inserts — an empty audio track makes AVAssetExportSession
        // fail with "Operation Stopped".
        var musicTracks: [(id: UUID, track: AVMutableCompositionTrack)] = []
        for music in audioTracks
        where music.timelineDuration > 0.05 && music.timelineOffset < cursor.seconds - 0.01 {
            let musicAsset = AVURLAsset(url: music.url)
            if let sourceAudio = try? await musicAsset.loadTracks(withMediaType: .audio).first {
                // v1 policy: audio is hard-clipped at the video's end.
                let playable = min(music.timelineDuration, cursor.seconds - music.timelineOffset)
                if playable > 0.05,
                   let track = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let range = CMTimeRange(
                        start: CMTime(seconds: music.trimStart, preferredTimescale: 600),
                        duration: CMTime(seconds: playable, preferredTimescale: 600)
                    )
                    do {
                        try track.insertTimeRange(range, of: sourceAudio,
                                                  at: CMTime(seconds: music.timelineOffset, preferredTimescale: 600))
                        musicTracks.append((music.id, track))
                    } catch {
                        composition.removeTrack(track)   // never leave an empty track behind
                    }
                }
            }
        }

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

        let duration = cursor.seconds
        return BuiltTimeline(composition: composition,
                             videoComposition: videoComposition,
                             audioMix: makeAudioMix(clipTrack: audioTrack,
                                                    musicTracks: musicTracks,
                                                    duration: duration),
                             clipAudioTrack: audioTrack,
                             musicAudioTracks: musicTracks,
                             duration: duration)
    }

    /// Multi-input mix: clip audio gets volume + fades, music gets its own
    /// independent volume. Track references keyed by ID, so a mix built from
    /// the last rebuild's tracks stays valid for the live player item.
    private func makeAudioMix(clipTrack: AVMutableCompositionTrack?,
                              musicTracks: [(id: UUID, track: AVMutableCompositionTrack)],
                              duration: Double) -> AVAudioMix? {
        var inputs: [AVMutableAudioMixInputParameters] = []

        if let clipTrack, !clipTrack.segments.isEmpty {
            let parameters = AVMutableAudioMixInputParameters(track: clipTrack)
            let base = Float(muteAudio ? 0 : volume / 100.0)
            parameters.setVolume(base, at: .zero)
            if !muteAudio, fadeIn > 0.05, duration > fadeIn {
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: base,
                                         timeRange: CMTimeRange(start: .zero,
                                                                duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
            }
            if !muteAudio, fadeOut > 0.05, duration > fadeOut {
                let start = CMTime(seconds: duration - fadeOut, preferredTimescale: 600)
                parameters.setVolumeRamp(fromStartVolume: base, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: start,
                                                                duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
            }
            inputs.append(parameters)
        }

        for entry in musicTracks {
            guard let music = audioTracks.first(where: { $0.id == entry.id }) else { continue }
            let parameters = AVMutableAudioMixInputParameters(track: entry.track)
            parameters.setVolume(Float(music.isMuted ? 0 : music.volume / 100.0), at: .zero)
            inputs.append(parameters)
        }

        guard !inputs.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs
        return mix
    }

    // MARK: - Observers

    private func attachObservers(to item: AVPlayerItem) {
        guard let player else { return }
        // 1/30 s keeps the centre-playhead timeline scrolling smoothly.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
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

import Foundation
import AVFoundation
import CoreImage
import ImageIO
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

// MARK: - Transitions

/// Phase-A transitions: single-source effects rendered in the CI handler
/// around a cut (no second frame needed). Real cross-dissolves arrive with
/// the custom compositor (T1).
enum TransitionStyle: String, Codable, CaseIterable {
    case none
    case fadeBlack
    case fadeWhite
    case flash

    var label: String {
        switch self {
        case .none: return "Cut"
        case .fadeBlack: return "Fade Black"
        case .fadeWhite: return "Fade White"
        case .flash: return "Flash"
        }
    }

    var icon: String {
        switch self {
        case .none: return "squares.leading.rectangle"
        case .fadeBlack: return "circle.lefthalf.filled"
        case .fadeWhite: return "circle.righthalf.filled"
        case .flash: return "bolt.fill"
        }
    }

    var duration: Double {
        switch self {
        case .none: return 0
        case .flash: return 0.3
        default: return 0.6
        }
    }
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
        /// Photo clip on the main track (T7): renders a still through the
        /// same grade pipeline; `assetDuration` acts as the max duration cap
        /// and trim edits the display duration.
        var isImage: Bool = false
        var hasAudio: Bool = false
        /// Per-clip audio mix (multiplied with the global track volume).
        var volume: Double = 100
        var isMuted: Bool = false
        /// Transition INTO the next clip (rendered at this clip's out-point).
        var transitionAfter: TransitionStyle = .none
        /// Per-clip grade override; nil follows the timeline's global grade.
        var grade: ClipGrade? = nil
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

    /// A picture-in-picture layer over the main track (T1): a video or a
    /// still image, free-placed on the timeline, sized/positioned in unit
    /// canvas coordinates. One overlay lane in v1; the array is the future.
    struct OverlayItem: Identifiable {
        let id: UUID
        let url: URL                  // in PersistenceStore clips folder
        var isImage: Bool
        var timelineOffset: Double    // where the overlay starts on the timeline
        var duration: Double          // seconds on screen
        var sizeFraction: Double = 0.45   // overlay width / canvas width (0.25…1)
        var center: CGPoint = CGPoint(x: 0.72, y: 0.25)  // unit coords, y down
        var opacity: Double = 1.0
        var title: String = ""
        var thumbnail: CGImage?       // lane bar art (regenerated, not persisted)

        var timelineEnd: Double { timelineOffset + duration }
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
        var overlays: [OverlayItem]
    }

    // Timeline
    @Published private(set) var clips: [Clip] = []
    @Published var selectedClipID: UUID?
    @Published private(set) var audioTracks: [MusicTrack] = []
    @Published private(set) var overlays: [OverlayItem] = []

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
    /// Live overlay size/position/opacity read by the compositor per frame —
    /// sliders update it without composition rebuilds (the LookState trick).
    let overlayLayout = OverlayLayout()
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

    /// Resolves an imported LUT's file URL for per-clip grades (injected so
    /// the engine never owns the LUT repository).
    private let lutFileURL: (UUID) -> URL?

    init(lookState: LookState, store: PersistenceStore,
         lutFileURL: @escaping (UUID) -> URL? = { _ in nil }) {
        self.lookState = lookState
        self.store = store
        self.lutFileURL = lutFileURL
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
                           trimStart: $0.trimStart, trimEnd: $0.trimEnd, speed: $0.speed,
                           volume: $0.volume, isMuted: $0.isMuted,
                           transitionAfter: $0.transitionAfter.rawValue,
                           isImage: $0.isImage,
                           grade: $0.grade)
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
            },
            overlays: overlays.map {
                StoredOverlay(id: $0.id, fileName: $0.url.lastPathComponent,
                              isImage: $0.isImage, title: $0.title,
                              timelineOffset: $0.timelineOffset, duration: $0.duration,
                              sizeFraction: $0.sizeFraction,
                              centerX: $0.center.x, centerY: $0.center.y,
                              opacity: $0.opacity)
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
                        trimStart: stored.trimStart, trimEnd: stored.trimEnd, speed: stored.speed,
                        isImage: stored.isImage ?? false,
                        volume: stored.volume ?? 100, isMuted: stored.isMuted ?? false,
                        transitionAfter: stored.transitionAfter.flatMap(TransitionStyle.init) ?? .none,
                        grade: stored.grade)
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
        overlays = (project.overlays ?? []).compactMap { stored in
            let url = store.clipsFolder.appendingPathComponent(stored.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return OverlayItem(id: stored.id, url: url, isImage: stored.isImage,
                               timelineOffset: stored.timelineOffset, duration: stored.duration,
                               sizeFraction: stored.sizeFraction,
                               center: CGPoint(x: stored.centerX, y: stored.centerY),
                               opacity: stored.opacity,
                               title: stored.title ?? "Overlay")
        }
        rebuild(keepPosition: false)
        refreshAllWaveforms()
        // Restore thumbnails + audio flags asynchronously.
        for clip in clips {
            if clip.isImage {
                Task.detached { [id = clip.id, url = clip.url] in
                    let thumb = Self.imageThumbnail(at: url)
                    await MainActor.run { [weak self] in
                        guard let self, let i = self.clips.firstIndex(where: { $0.id == id }) else { return }
                        self.clips[i].thumbnail = thumb
                        if let thumb { self.clips[i].filmstrip = [thumb] }
                    }
                }
                continue
            }
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
        refreshOverlayThumbnails()
    }

    func startNewProject() {
        saveProject()
        projectID = UUID()
        projectCreatedAt = Date()
        projectTitle = "New Project"
        clips = []
        selectedClipID = nil
        audioTracks = []
        overlays = []
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

    /// Default and maximum display durations for photo clips (T7). Trim
    /// edits the display duration; `assetDuration` carries the cap.
    static let photoDefaultDuration = 3.0
    static let photoMaxDuration = 30.0

    /// Adds a still image to the MAIN track (T7): occupies timeline like a
    /// clip, renders through the same grade pipeline, no source video track.
    func addPhotoClip(from url: URL) async {
        let durableURL = url.path.hasPrefix(store.clipsFolder.path)
            ? url
            : (store.importClipFile(from: url) ?? url)
        let thumb = await Task.detached { Self.imageThumbnail(at: durableURL) }.value
        guard thumb != nil else { return }   // unreadable image: don't add a dead clip
        pushUndoSnapshot()
        var clip = Clip(id: UUID(), url: durableURL,
                        assetDuration: Self.photoMaxDuration,
                        trimStart: 0, trimEnd: Self.photoDefaultDuration,
                        isImage: true)
        clip.thumbnail = thumb
        clip.filmstrip = thumb.map { [$0] } ?? []
        clips.append(clip)
        selectedClipID = clip.id
        rebuild()
    }

    /// Downscaled still for photo-clip/overlay thumbnails, EXIF-oriented.
    nonisolated static func imageThumbnail(at url: URL, maxDimension: CGFloat = 320) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Regenerates a clip's filmstrip (one frame per second across the
    /// trimmed range, capped) off the main thread and publishes it.
    func refreshFilmstrip(clipID: UUID) {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        guard !clip.isImage else { return }   // stills: filmstrip is the frame itself
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
        first.transitionAfter = .none
        let second = Clip(id: UUID(), url: clip.url, assetDuration: clip.assetDuration,
                          trimStart: splitPoint, trimEnd: clip.trimEnd,
                          speed: clip.speed, isImage: clip.isImage, hasAudio: clip.hasAudio,
                          volume: clip.volume, isMuted: clip.isMuted,
                          transitionAfter: clip.transitionAfter,
                          grade: clip.grade,
                          thumbnail: clip.thumbnail, filmstrip: clip.isImage ? clip.filmstrip : [])
        clips[index] = first
        clips.insert(second, at: index + 1)
        selectedClipID = second.id

        // Refresh the second half's thumbnail to its new first frame
        // (stills keep theirs — every frame is the same frame).
        if !clip.isImage {
            Task { [id = second.id, url = clip.url] in
                let thumb = await Self.thumbnail(for: AVURLAsset(url: url), at: splitPoint + 0.02)
                if let i = self.clips.firstIndex(where: { $0.id == id }) {
                    self.clips[i].thumbnail = thumb
                }
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
        if !clip.isImage {
            Task { [id = clip.id, url = clip.url, at = clip.trimStart] in
                let thumb = await Self.thumbnail(for: AVURLAsset(url: url), at: at + 0.02)
                if let i = self.clips.firstIndex(where: { $0.id == id }) {
                    self.clips[i].thumbnail = thumb
                }
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

    /// Sets the transition rendered at this clip's cut into the next one.
    func setTransition(afterClipID id: UUID, style: TransitionStyle) {
        guard let i = clips.firstIndex(where: { $0.id == id }), i < clips.count - 1 else { return }
        guard clips[i].transitionAfter != style else { return }
        pushUndoSnapshot()
        clips[i].transitionAfter = style
        rebuild()
    }

    // MARK: - Per-clip looks (Next-10 #1)

    /// Gives one clip its own grade (nil returns it to the global grade).
    func setClipGrade(id: UUID, _ grade: ClipGrade?) {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              clips[i].grade != grade else { return }
        pushUndoSnapshot()
        clips[i].grade = grade
        rebuild()
    }

    /// Copy-grade-to-all: every clip wears the same override in one undo step.
    func applyGradeToAllClips(_ grade: ClipGrade?) {
        guard clips.contains(where: { $0.grade != grade }) else { return }
        pushUndoSnapshot()
        for i in clips.indices { clips[i].grade = grade }
        rebuild()
    }

    /// Materialises a clip's grade override into the LookState the
    /// compositor reads. LUT parsing is cached in LookPipeline, so building
    /// fresh states per rebuild stays cheap.
    private func makeLookState(from grade: ClipGrade) -> LookState {
        let state = LookState()
        let preset = MockData.looks.first { $0.name == grade.baseLookName }
        #if DEBUG
        print("[LUMA] clip grade '\(grade.baseLookName)' preset=\(preset?.name ?? "MISS")")
        #endif
        state.recipe = preset?.recipe
            ?? LookRecipe()
        state.settings = grade.settings
        if let lutID = grade.lutID, let url = lutFileURL(lutID) {
            state.lut = try? LookPipeline.shared.loadLUT(at: url)
        }
        return state
    }

    /// Per-clip audio: mix-only changes, live, no rebuild.
    func setClipVolume(id: UUID, _ volume: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].volume = min(max(0, volume), 100)
        applyAudioSettings()
        scheduleAutosave()
    }

    func setClipMuted(id: UUID, _ muted: Bool) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].isMuted = muted
        applyAudioSettings()
        scheduleAutosave()
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

    // MARK: - Overlay lane (T1)

    /// Adds a PIP overlay (video or still) starting at the playhead. One
    /// lane in v1: the new item lands in the first free gap at/after the
    /// playhead; videos run their full length, images default to 3 s — both
    /// clamped to the free space and the timeline end.
    func addOverlay(from url: URL, isImage: Bool) async {
        guard totalDuration > 0.4 else { return }   // needs a base timeline
        let durableURL = url.path.hasPrefix(store.clipsFolder.path)
            ? url
            : (store.importClipFile(from: url) ?? url)
        var mediaDuration = Self.photoDefaultDuration
        if !isImage {
            let asset = AVURLAsset(url: durableURL)
            guard let duration = try? await asset.load(.duration).seconds,
                  duration.isFinite, duration > 0.05 else { return }
            mediaDuration = duration
        } else {
            guard Self.imageThumbnail(at: durableURL, maxDimension: 32) != nil else { return }
        }

        // First free slot at/after the playhead on the single lane.
        var offset = min(max(0, currentTime), max(0, totalDuration - 0.4))
        for existing in overlays.sorted(by: { $0.timelineOffset < $1.timelineOffset }) {
            if offset < existing.timelineOffset - 0.05 { break }
            if offset < existing.timelineEnd { offset = existing.timelineEnd }
        }
        guard offset < totalDuration - 0.2 else { return }
        var maxEnd = totalDuration
        if let next = overlays
            .filter({ $0.timelineOffset > offset + 0.05 })
            .min(by: { $0.timelineOffset < $1.timelineOffset }) {
            maxEnd = min(maxEnd, next.timelineOffset)
        }
        let duration = min(mediaDuration, maxEnd - offset)
        guard duration > 0.2 else { return }

        pushUndoSnapshot()
        let item = OverlayItem(id: UUID(), url: durableURL, isImage: isImage,
                               timelineOffset: offset, duration: duration,
                               title: url.deletingPathExtension().lastPathComponent)
        overlays.append(item)
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
        refreshOverlayThumbnails()
    }

    func removeOverlay(id: UUID) {
        guard overlays.contains(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        overlays.removeAll { $0.id == id }
        rebuild()
    }

    /// Repositions an overlay on the timeline, clamped against its lane
    /// neighbours and the timeline end. Rebuild (track inserts move).
    func setOverlayOffset(id: UUID, _ offset: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let item = overlays[i]
        var clamped = min(max(0, offset), max(0, totalDuration - 0.2))
        for other in overlays where other.id != id {
            if other.timelineEnd <= item.timelineOffset + 0.001 {
                clamped = max(clamped, other.timelineEnd)
            } else if other.timelineOffset >= item.timelineEnd - 0.001 {
                clamped = min(clamped, max(0, other.timelineOffset - item.duration))
            }
        }
        guard abs(clamped - item.timelineOffset) > 0.01 else { return }
        pushUndoSnapshot()
        overlays[i].timelineOffset = clamped
        overlays[i].duration = min(item.duration, max(0.2, totalDuration - clamped))
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
    }

    /// Size/position/opacity are LIVE: the compositor reads `overlayLayout`
    /// per frame, so sliders never trigger a rebuild (the LookState trick).
    func setOverlayOpacity(id: UUID, _ opacity: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].opacity = min(max(0, opacity), 1)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    func setOverlaySize(id: UUID, _ fraction: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].sizeFraction = min(max(0.25, fraction), 1.0)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    func setOverlayCenter(id: UUID, _ center: CGPoint) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].center = CGPoint(x: min(max(0, center.x), 1),
                                     y: min(max(0, center.y), 1))
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// Mirrors the overlays' placement values into the live layout box the
    /// compositor reads, and re-renders the paused frame so edits show
    /// immediately (a paused player never re-runs the compositor on its own).
    private func syncOverlayLayout(refreshFrame: Bool = false) {
        var map: [UUID: OverlayLayout.Placement] = [:]
        for overlay in overlays {
            map[overlay.id] = OverlayLayout.Placement(sizeFraction: overlay.sizeFraction,
                                                      center: overlay.center,
                                                      opacity: overlay.opacity)
        }
        overlayLayout.replaceAll(map)
        if refreshFrame, let player, player.timeControlStatus != .playing {
            let time = player.currentTime()
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func refreshOverlayThumbnails() {
        for overlay in overlays where overlay.thumbnail == nil {
            let id = overlay.id
            let url = overlay.url
            if overlay.isImage {
                Task.detached(priority: .utility) {
                    let thumb = Self.imageThumbnail(at: url, maxDimension: 120)
                    await MainActor.run { [weak self] in
                        guard let self,
                              let i = self.overlays.firstIndex(where: { $0.id == id }) else { return }
                        self.overlays[i].thumbnail = thumb
                    }
                }
            } else {
                Task { [weak self] in
                    let thumb = await Self.thumbnail(for: AVURLAsset(url: url), at: 0.03)
                    guard let self,
                          let i = self.overlays.firstIndex(where: { $0.id == id }) else { return }
                    self.overlays[i].thumbnail = thumb
                }
            }
        }
    }

    // MARK: - Undo / redo

    private func currentSnapshot() -> Snapshot {
        Snapshot(clips: clips, format: format, zoom: zoom,
                 audioTracks: audioTracks, overlays: overlays)
    }

    private func pushUndoSnapshot() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        updateHistoryFlags()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        clips = snapshot.clips
        format = snapshot.format
        zoom = snapshot.zoom
        audioTracks = snapshot.audioTracks
        overlays = snapshot.overlays
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

        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_SEED_DEBUG"] == "1" {
            let tracks = built.composition.tracks(withMediaType: .video).map { track in
                "video#\(track.trackID): " + track.segments.map {
                    "\($0.isEmpty ? "empty" : "media") \($0.timeMapping.target.start.seconds)-\($0.timeMapping.target.end.seconds)"
                }.joined(separator: ", ")
            }
            print("[LUMA] rebuilt duration=\(built.duration) composition=\(built.composition.duration.seconds) instructions=\(built.videoComposition.instructions.map { "\($0.timeRange.start.seconds)-\($0.timeRange.end.seconds) req=\(($0.requiredSourceTrackIDs ?? []).count)" }) tracks=\(tracks)")
        }
        #endif
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

    /// Tiny bundled black video whose only job is anchoring photo-clip time
    /// ranges on the main track (trailing empty ranges get dropped by
    /// AVFoundation). Loaded once, cached for the app's lifetime. The asset
    /// itself MUST stay referenced: an AVAssetTrack whose parent asset has
    /// been deallocated makes insertTimeRange throw (observed in-app).
    private static var blankAnchor: (asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)?
    private static func loadBlankAnchor() async -> (asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)? {
        if let cached = blankAnchor { return cached }
        guard let url = Bundle.main.url(forResource: "CompositorBlank", withExtension: "mp4") else {
            return nil
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              duration.seconds > 0 else { return nil }
        blankAnchor = (asset, track, duration)
        return blankAnchor
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
            // Photo clip (T7): the still renders through the compositor's
            // CIImage cache via a no-source instruction — never from track
            // frames. The main track still needs the RANGE to exist, and
            // AVFoundation silently DROPS trailing empty ranges (probed:
            // photo-at-end would truncate the timeline), so a tiny bundled
            // black video anchors the duration. Its segment is never decoded:
            // photo segments' instructions don't list the main track.
            if clip.isImage {
                let stillDuration = CMTime(seconds: clip.timelineDuration,
                                           preferredTimescale: 600)
                guard stillDuration.seconds > 0.05 else { continue }
                var anchored = false
                if let blank = await Self.loadBlankAnchor() {
                    let sourceRange = CMTimeRange(start: .zero, duration: blank.duration)
                    do {
                        try videoTrack.insertTimeRange(sourceRange, of: blank.track, at: cursor)
                        videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: blank.duration),
                                                  toDuration: stillDuration)
                        anchored = true
                    } catch {
                        videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor,
                                                                    duration: stillDuration))
                    }
                } else {
                    // Missing resource: mid-timeline photos still work via
                    // an explicit empty range (trailing ones would clip).
                    videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor,
                                                                duration: stillDuration))
                }
                metas.append(FrameMeta(start: cursor.seconds,
                                       end: (cursor + stillDuration).seconds,
                                       transform: .identity,
                                       imageURL: clip.url,
                                       hasAnchorFrames: anchored,
                                       clipLookState: clip.grade.map(makeLookState)))
                cursor = cursor + stillDuration
                continue
            }

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
                                   transform: transform,
                                   clipLookState: clip.grade.map(makeLookState)))
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

        // Overlay (PIP) items: videos ride a SECOND composition video track
        // (one lane, so items never overlap); images render straight from
        // the compositor's still cache — no source track at all. Lazy like
        // the audio tracks: only created when a video overlay actually
        // inserts. Gaps between items are explicit empty ranges so segment
        // targeting stays exact.
        var overlaySpecs: [OverlaySpec] = []
        var overlayTrack: AVMutableCompositionTrack?
        var overlayCursor = CMTime.zero
        for overlay in overlays.sorted(by: { $0.timelineOffset < $1.timelineOffset }) {
            let start = min(max(0, overlay.timelineOffset), cursor.seconds)
            let playable = min(overlay.duration, cursor.seconds - start)
            guard playable > 0.05 else { continue }

            if overlay.isImage {
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: kCMPersistentTrackID_Invalid,
                                                imageURL: overlay.url,
                                                transform: .identity,
                                                start: start, end: start + playable))
                continue
            }

            let overlayAsset = AVURLAsset(url: overlay.url)
            guard let sourceVideo = try? await overlayAsset.loadTracks(withMediaType: .video).first
            else { continue }
            let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            if overlayTrack == nil {
                overlayTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track = overlayTrack else { continue }
            let at = CMTime(seconds: start, preferredTimescale: 600)
            if at > overlayCursor {
                track.insertEmptyTimeRange(CMTimeRange(start: overlayCursor, end: at))
            }
            let range = CMTimeRange(start: .zero,
                                    duration: CMTime(seconds: playable, preferredTimescale: 600))
            do {
                try track.insertTimeRange(range, of: sourceVideo, at: at)
                overlayCursor = at + range.duration
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: track.trackID,
                                                imageURL: nil,
                                                transform: transform,
                                                start: start, end: start + playable))
            } catch {
                // Failed insert with no real media on the track yet: drop
                // it so no media-less video track breaks the export session.
                if track.segments.allSatisfy({ $0.isEmpty }) {
                    composition.removeTrack(track)
                    overlayTrack = nil
                    overlayCursor = .zero
                }
            }
        }
        syncOverlayLayout()

        // Transition boundaries: cut time + style, sampled by the compositor.
        var spans: [TransitionSpanSpec] = []
        for (index, clip) in clips.enumerated() where index < clips.count - 1 {
            guard clip.transitionAfter != .none, index < metas.count else { continue }
            spans.append(TransitionSpanSpec(center: metas[index].end,
                                            style: clip.transitionAfter,
                                            half: clip.transitionAfter.duration / 2))
        }

        // The custom compositor does orientation, aspect-fill crop into the
        // chosen format, the active look, overlays, and transition veils —
        // for preview and export alike (the D1 parity guarantee).
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = LumaVideoCompositor.self
        videoComposition.renderSize = format.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = makeInstructions(
            totalDuration: cursor,
            mainTrackID: videoTrack.trackID,
            frameMetas: metas,
            transitionSpans: spans,
            overlaySpecs: overlaySpecs)
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

    /// Segments the timeline into `LumaCompositionInstruction`s. Boundaries
    /// fall at photo-clip edges and overlay in/out points so each segment's
    /// `requiredSourceTrackIDs` lists exactly the tracks it reads: photo
    /// segments require NO tracks (the main track holds an empty range
    /// there), overlay-video segments add the overlay track. Ranges tile
    /// [0, duration] contiguously from shared CMTime values — export
    /// validation rejects gaps or overlaps.
    private func makeInstructions(totalDuration: CMTime,
                                  mainTrackID: CMPersistentTrackID,
                                  frameMetas: [FrameMeta],
                                  transitionSpans: [TransitionSpanSpec],
                                  overlaySpecs: [OverlaySpec]) -> [LumaCompositionInstruction] {
        let total = totalDuration.seconds
        var cuts: Set<Double> = [0, total]
        for meta in frameMetas where meta.imageURL != nil {
            cuts.insert(min(max(0, meta.start), total))
            cuts.insert(min(max(0, meta.end), total))
        }
        for spec in overlaySpecs {
            cuts.insert(min(max(0, spec.start), total))
            cuts.insert(min(max(0, spec.end), total))
        }
        // Dedupe within a frame's tolerance, then walk consecutive pairs.
        var times = cuts.sorted().reduce(into: [Double]()) { result, t in
            if result.last.map({ t - $0 > 0.001 }) ?? true { result.append(t) }
        }
        if times.count < 2 { times = [0, max(total, 0.1)] }
        let timescale = CMTimeScale(600)
        let cmTimes = times.enumerated().map { index, t in
            index == times.count - 1 ? totalDuration
                                     : CMTime(seconds: t, preferredTimescale: timescale)
        }

        var instructions: [LumaCompositionInstruction] = []
        for i in 0..<(cmTimes.count - 1) {
            let range = CMTimeRange(start: cmTimes[i], end: cmTimes[i + 1])
            guard range.duration.seconds > 0 else { continue }
            let mid = (times[i] + times[i + 1]) / 2

            var trackIDs: [NSValue] = []
            let meta = frameMetas.last(where: { mid >= $0.start - 0.001 && mid < $0.end + 0.001 })
            // Photo segments still REQUIRE the main track when anchor frames
            // exist there: source-less instructions stall AVPlayer, so the
            // anchor paces playback while the compositor ignores its frames.
            if meta?.imageURL == nil || meta?.hasAnchorFrames == true {
                trackIDs.append(NSNumber(value: mainTrackID))
            }
            for spec in overlaySpecs
            where spec.trackID != kCMPersistentTrackID_Invalid
                && mid >= spec.start - 0.001 && mid < spec.end + 0.001 {
                trackIDs.append(NSNumber(value: spec.trackID))
            }

            instructions.append(LumaCompositionInstruction(
                timeRange: range,
                requiredSourceTrackIDs: trackIDs,
                mainTrackID: mainTrackID,
                frameMetas: frameMetas,
                transitionSpans: transitionSpans,
                overlays: overlaySpecs,
                overlayLayout: overlayLayout,
                lookState: lookState,
                renderSize: format.renderSize,
                zoomFactor: max(1.0, zoom / 100.0)))
        }
        return instructions
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
            // Per-clip volume/mute: stepped volumes at each clip's start on
            // the shared clip-audio track (multiplied with the global level).
            var clipCursor = 0.0
            for clip in clips {
                let clipLevel = base * Float(clip.isMuted ? 0 : clip.volume / 100.0)
                parameters.setVolume(clipLevel,
                                     at: CMTime(seconds: clipCursor, preferredTimescale: 600))
                clipCursor += clip.timelineDuration
            }
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

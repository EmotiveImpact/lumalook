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
/// The role of an audio lane, driving its timeline colour + icon.
enum AudioLaneKind: String, Codable, CaseIterable {
    case music, voice, sfx, extracted

    var label: String {
        switch self {
        case .music: return "Music"
        case .voice: return "Voice"
        case .sfx: return "SFX"
        case .extracted: return "Detached"
        }
    }
    var icon: String {
        switch self {
        case .music: return "music.note"
        case .voice: return "mic.fill"
        case .sfx: return "sparkles"
        case .extracted: return "waveform.badge.plus"
        }
    }
    var tint: Color {
        switch self {
        case .music: return LumaTheme.accentDeep
        case .voice: return LumaTheme.teal
        case .sfx: return LumaTheme.orange
        case .extracted: return Color(red: 0.62, green: 0.45, blue: 0.9)
        }
    }
}

enum TransitionStyle: String, Codable, CaseIterable {
    case none
    case dissolve
    case wipe
    case fadeBlack
    case fadeWhite
    case flash
    // Motion (push) — incoming slides in, outgoing pushed out.
    case slideLeft, slideRight, slideUp, slideDown
    case zoomIn, zoomOut
    case spin
    // FX
    case glitch
    case lumaWipe

    var label: String {
        switch self {
        case .none: return "Cut"
        case .dissolve: return "Dissolve"
        case .wipe: return "Wipe"
        case .fadeBlack: return "Fade Black"
        case .fadeWhite: return "Fade White"
        case .flash: return "Flash"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .spin: return "Spin"
        case .glitch: return "Glitch"
        case .lumaWipe: return "Luma Wipe"
        }
    }

    var icon: String {
        switch self {
        case .none: return "squares.leading.rectangle"
        case .dissolve: return "square.on.square.intersection.dashed"
        case .wipe: return "arrow.forward.square"
        case .fadeBlack: return "circle.lefthalf.filled"
        case .fadeWhite: return "circle.righthalf.filled"
        case .flash: return "bolt.fill"
        case .slideLeft: return "arrow.left.square"
        case .slideRight: return "arrow.right.square"
        case .slideUp: return "arrow.up.square"
        case .slideDown: return "arrow.down.square"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .spin: return "arrow.triangle.2.circlepath"
        case .glitch: return "waveform.path.ecg"
        case .lumaWipe: return "circle.dotted.circle"
        }
    }

    var duration: Double {
        switch self {
        case .none: return 0
        case .flash: return 0.3
        case .slideLeft, .slideRight, .slideUp, .slideDown: return 0.5
        case .zoomIn, .zoomOut: return 0.6
        case .spin: return 0.7
        case .glitch: return 0.4
        case .lumaWipe: return 0.8
        default: return 0.6
        }
    }

    /// Grouping for the picker.
    var category: String {
        switch self {
        case .none, .dissolve, .wipe, .fadeBlack, .fadeWhite, .flash: return "Basic"
        case .slideLeft, .slideRight, .slideUp, .slideDown, .zoomIn, .zoomOut, .spin: return "Motion"
        case .glitch, .lumaWipe: return "FX"
        }
    }

    /// Veils tint ONE frame (no A/B roll needed).
    var isVeil: Bool { self == .fadeBlack || self == .fadeWhite || self == .flash }

    /// True cross-transitions blend TWO frames (A/B roll). Everything that
    /// isn't a cut or a veil needs real incoming+outgoing frames.
    /// NOTE: `StoredClip.transitionAfter` stores the rawValue; an old app
    /// build opening a project with a new style decodes it to `.none` via the
    /// `flatMap(TransitionStyle.init)` fallback in `load` — graceful degrade.
    var isCrossTransition: Bool { self != .none && !isVeil }
}

// MARK: - Editor state & composition engine

@MainActor
final class EditorState: ObservableObject {

    /// Speed-ramp shapes over the clip's normalised progress. Each returns a
    /// speed multiplier at t∈[0,1]; the build slices the clip and time-scales
    /// each slice so playback smoothly accelerates/decelerates.
    enum SpeedRamp: String, CaseIterable {
        case none, slowFast, fastSlow, slowFastSlow, fastSlowFast

        var label: String {
            switch self {
            case .none: return "None"
            case .slowFast: return "Slow → Fast"
            case .fastSlow: return "Fast → Slow"
            case .slowFastSlow: return "Slow-Fast-Slow"
            case .fastSlowFast: return "Fast-Slow-Fast"
            }
        }

        /// Speed multiplier at normalised progress t (0…1).
        func speed(at t: Double) -> Double {
            let slow = 0.4, fast = 2.2
            switch self {
            case .none: return 1
            case .slowFast: return slow + (fast - slow) * t
            case .fastSlow: return fast + (slow - fast) * t
            case .slowFastSlow: return slow + (fast - slow) * (1 - abs(2 * t - 1))
            case .fastSlowFast: return fast + (slow - fast) * (1 - abs(2 * t - 1))
            }
        }
    }

    struct Clip: Identifiable {
        var id: UUID
        var url: URL                // var so Replace/Reverse can swap the media
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
        /// Custom duration for `transitionAfter` (nil = the style's default).
        var transitionDuration: Double? = nil
        var thumbnail: CGImage?
        /// Per-second frames across the trimmed range for the timeline
        /// filmstrip (capped; regenerated on trim/split).
        var filmstrip: [CGImage] = []
        /// User display transforms applied over the source orientation.
        var rotationQuarterTurns: Int = 0   // 90° steps, mod 4
        var isMirrored: Bool = false        // horizontal flip
        /// Free crop in unit space (y-down); straighten in degrees.
        var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var straightenDegrees: Double = 0
        /// Ken Burns pan/zoom keyframes (offsets within the clip's run);
        /// empty = static.
        var transformKeyframes: [ClipTransformKeyframe] = []
        /// Speed ramp preset (rawValue); "none" = constant `speed`.
        var speedRamp: String = SpeedRamp.none.rawValue

        /// Duration this clip occupies on the timeline after trim + speed.
        var timelineDuration: Double { max(0, (trimEnd - trimStart) / speed) }

        /// Bundle for the compositor's FrameMeta.display.
        var displayOps: ClipDisplayOps {
            ClipDisplayOps(rotationQuarterTurns: rotationQuarterTurns, isMirrored: isMirrored,
                           cropRect: cropRect, straightenDegrees: straightenDegrees)
        }
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
        /// Lane kind (music/voice/sfx/extracted) — drives the lane colour+icon.
        var kind: AudioLaneKind = .music
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
        /// Trim window into the overlay's own media (video overlays).
        var mediaStart: Double = 0
        var mediaDuration: Double = .greatestFiniteMagnitude
        var sizeFraction: Double = 0.45   // overlay width / canvas width (0.25…1)
        var center: CGPoint = CGPoint(x: 0.72, y: 0.25)  // unit coords, y down
        var opacity: Double = 1.0
        /// Text layer (T6): when set, the compositor renders this string
        /// instead of media — same lane, same placement, same keyframes.
        var text: String? = nil
        var textStyle: TextLayerStyle = .title
        var textColorHex: String = "#FFFFFF"
        var rotationDegrees: Double = 0
        /// Keyframed placement (T5): offsets within the overlay's run.
        /// Empty = static placement from the fields above.
        var keyframes: [OverlayKeyframe] = []
        /// Overlay-audio mix (video overlays only; was silently dropped in v1).
        var volume: Double = 100
        var isMuted: Bool = false
        var title: String = ""
        var thumbnail: CGImage?       // lane bar art (regenerated, not persisted)
        /// Stacking lane (z-order): higher lanes render on top.
        var lane: Int = 0
        /// Non-placement effect stack (blend/chroma/mask/adjust/border).
        var effects: OverlayEffects = OverlayEffects()

        var timelineEnd: Double { timelineOffset + duration }
    }

    /// Text-layer typography presets (T6).
    enum TextLayerStyle: String, Codable, CaseIterable {
        case title
        case subtitle
        case mono

        var label: String {
            switch self {
            case .title: return "Title"
            case .subtitle: return "Subtitle"
            case .mono: return "Mono"
            }
        }

        var fontName: String {
            switch self {
            case .title: return "HelveticaNeue-Bold"
            case .subtitle: return "HelveticaNeue-Medium"
            case .mono: return "Menlo-Bold"
            }
        }
    }

    /// Everything one `buildComposition()` pass produces — shared between
    /// the preview player and the exporter so both hear the same mix.
    struct BuiltTimeline {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVAudioMix?
        let clipAudioTrack: AVMutableCompositionTrack?
        let musicAudioTracks: [(id: UUID, track: AVMutableCompositionTrack)]
        let overlayAudioTracks: [(id: UUID, track: AVMutableCompositionTrack)]
        let duration: Double
    }

    private struct Snapshot {
        var clips: [Clip]
        var format: EditorFormat
        var zoom: Double
        var audioTracks: [MusicTrack]
        var overlays: [OverlayItem]
        var adjustmentLayers: [AdjustmentLayer]
        var canvasMode: CanvasBackgroundMode
        var canvasSolidHex: String
        var canvasGradientTopHex: String
        var canvasGradientBottomHex: String
    }

    // Timeline
    @Published private(set) var clips: [Clip] = []
    @Published var selectedClipID: UUID?
    @Published private(set) var audioTracks: [MusicTrack] = []
    @Published private(set) var overlays: [OverlayItem] = []
    /// Full-frame adjustment grades floating over the clips (adjustment layers).
    @Published private(set) var adjustmentLayers: [AdjustmentLayer] = []

    // Canvas
    @Published var format: EditorFormat = .widescreen
    @Published var zoom: Double = 100
    /// Background fill behind the framed clip (fill/fit/blur/solid/gradient).
    @Published var canvasMode: CanvasBackgroundMode = .fill
    @Published var canvasSolidHex: String = "#101014"
    @Published var canvasGradientTopHex: String = "#2A2A38"
    @Published var canvasGradientBottomHex: String = "#050507"

    /// The compositor payload assembled from the canvas fields.
    var canvasSpec: CanvasSpec {
        CanvasSpec(mode: canvasMode, solidHex: canvasSolidHex,
                   gradientTopHex: canvasGradientTopHex,
                   gradientBottomHex: canvasGradientBottomHex)
    }

    /// Sets the canvas background mode (with undo).
    func setCanvasMode(_ mode: CanvasBackgroundMode) {
        guard canvasMode != mode else { return }
        pushUndoSnapshot()
        canvasMode = mode
        rebuild()
    }

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
    /// Live per-overlay effects (blend/chroma/mask/adjust/border) the
    /// compositor reads per frame — same live-reference trick as overlayLayout.
    let overlayEffects = OverlayEffectsBox()
    /// Live per-clip Ken Burns pan/zoom, same live-reference trick.
    let clipTransformLayout = ClipTransformLayout()
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
    private var lastBuiltTracks: (clip: AVMutableCompositionTrack?,
                                  music: [(id: UUID, track: AVMutableCompositionTrack)],
                                  overlay: [(id: UUID, track: AVMutableCompositionTrack)]) = (nil, [], [])

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
                           grade: $0.grade,
                           transitionDuration: $0.transitionDuration,
                           rotationQuarterTurns: $0.rotationQuarterTurns,
                           isMirrored: $0.isMirrored,
                           cropX: $0.cropRect.minX, cropY: $0.cropRect.minY,
                           cropW: $0.cropRect.width, cropH: $0.cropRect.height,
                           straightenDegrees: $0.straightenDegrees,
                           transformKeyframes: $0.transformKeyframes.isEmpty ? nil : $0.transformKeyframes,
                           speedRamp: $0.speedRamp == SpeedRamp.none.rawValue ? nil : $0.speedRamp)
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
                            volume: $0.volume, isMuted: $0.isMuted,
                            kind: $0.kind == .music ? nil : $0.kind.rawValue)
            },
            overlays: overlays.map {
                StoredOverlay(id: $0.id, fileName: $0.url.lastPathComponent,
                              isImage: $0.isImage, title: $0.title,
                              timelineOffset: $0.timelineOffset, duration: $0.duration,
                              sizeFraction: $0.sizeFraction,
                              centerX: $0.center.x, centerY: $0.center.y,
                              opacity: $0.opacity,
                              volume: $0.volume, isMuted: $0.isMuted,
                              rotationDegrees: $0.rotationDegrees,
                              keyframes: $0.keyframes.isEmpty ? nil : $0.keyframes,
                              mediaStart: $0.mediaStart,
                              mediaDuration: $0.mediaDuration.isFinite ? $0.mediaDuration : nil,
                              text: $0.text,
                              textStyle: $0.text == nil ? nil : $0.textStyle.rawValue,
                              textColorHex: $0.text == nil ? nil : $0.textColorHex,
                              lane: $0.lane == 0 ? nil : $0.lane,
                              effects: $0.effects.isIdentity ? nil : $0.effects)
            },
            canvasMode: canvasMode == .fill ? nil : canvasMode.rawValue,
            canvasSolidHex: canvasSolidHex,
            canvasGradientTopHex: canvasGradientTopHex,
            canvasGradientBottomHex: canvasGradientBottomHex,
            adjustmentLayers: adjustmentLayers.isEmpty ? nil : adjustmentLayers
        )
        store.upsert(project: stored)
    }

    func load(project: StoredProject) {
        projectID = project.id
        projectCreatedAt = project.createdAt
        projectTitle = project.title
        format = EditorFormat(rawValue: project.format) ?? .widescreen
        zoom = project.zoom
        adjustmentLayers = project.adjustmentLayers ?? []
        canvasMode = project.canvasMode.flatMap(CanvasBackgroundMode.init) ?? .fill
        canvasSolidHex = project.canvasSolidHex ?? "#101014"
        canvasGradientTopHex = project.canvasGradientTopHex ?? "#2A2A38"
        canvasGradientBottomHex = project.canvasGradientBottomHex ?? "#050507"
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
                        grade: stored.grade,
                        transitionDuration: stored.transitionDuration,
                        rotationQuarterTurns: stored.rotationQuarterTurns ?? 0,
                        isMirrored: stored.isMirrored ?? false,
                        cropRect: CGRect(x: stored.cropX ?? 0, y: stored.cropY ?? 0,
                                         width: stored.cropW ?? 1, height: stored.cropH ?? 1),
                        straightenDegrees: stored.straightenDegrees ?? 0,
                        transformKeyframes: stored.transformKeyframes ?? [],
                        speedRamp: stored.speedRamp ?? SpeedRamp.none.rawValue)
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
                              volume: stored.volume, isMuted: stored.isMuted,
                              kind: stored.kind.flatMap(AudioLaneKind.init) ?? .music)
        }
        overlays = (project.overlays ?? []).compactMap { stored in
            let url = store.clipsFolder.appendingPathComponent(stored.fileName)
            // Text layers carry no media file; everything else must exist.
            guard stored.text != nil || FileManager.default.fileExists(atPath: url.path) else { return nil }
            var item = OverlayItem(id: stored.id, url: url, isImage: stored.isImage,
                                   timelineOffset: stored.timelineOffset, duration: stored.duration,
                                   mediaStart: stored.mediaStart ?? 0,
                                   mediaDuration: stored.mediaDuration ?? .greatestFiniteMagnitude,
                                   sizeFraction: stored.sizeFraction,
                                   center: CGPoint(x: stored.centerX, y: stored.centerY),
                                   opacity: stored.opacity,
                                   rotationDegrees: stored.rotationDegrees ?? 0,
                                   keyframes: stored.keyframes ?? [],
                                   volume: stored.volume ?? 100,
                                   isMuted: stored.isMuted ?? false,
                                   title: stored.title ?? "Overlay")
            item.text = stored.text
            item.textStyle = stored.textStyle.flatMap(TextLayerStyle.init) ?? .title
            item.textColorHex = stored.textColorHex ?? "#FFFFFF"
            item.lane = stored.lane ?? 0
            item.effects = stored.effects ?? OverlayEffects()
            return item
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
        // Phone footage first: the FIRST clip decides the canvas. A portrait
        // clip gets a 9:16 canvas instead of being letterboxed into 16:9.
        if clips.isEmpty,
           let track = try? await asset.loadTracks(withMediaType: .video).first {
            let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let display = naturalSize.applying(transform)
            let aspect = abs(display.width) / max(abs(display.height), 1)
            format = aspect < 0.85 ? .vertical : (aspect < 1.15 ? .square : .widescreen)
        }
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

    /// Replaces the clip's media in place, keeping the edit decision list:
    /// trim window (clamped to the new duration), speed, grade, transition,
    /// volume, and display transforms are all preserved — only the footage
    /// swaps. Handles video→video; image sources fall back to a trim reset.
    func replaceClip(id: UUID, with url: URL) async {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let durableURL = url.path.hasPrefix(store.clipsFolder.path)
            ? url
            : (store.importClipFile(from: url) ?? url)
        let ext = durableURL.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff"]
        let isImage = imageExtensions.contains(ext)

        var newDuration: Double
        var hasAudio = false
        if isImage {
            guard Self.imageThumbnail(at: durableURL) != nil else { return }
            newDuration = Self.photoMaxDuration
        } else {
            let asset = AVURLAsset(url: durableURL)
            guard let d = try? await asset.load(.duration).seconds,
                  d.isFinite, d > 0.05 else { return }
            newDuration = d
            hasAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
        }

        pushUndoSnapshot()
        clips[i].url = durableURL
        clips[i].assetDuration = newDuration
        clips[i].isImage = isImage
        clips[i].hasAudio = hasAudio
        // Keep the trim window where it fits; clamp into the new media.
        if clips[i].trimEnd > newDuration || clips[i].trimStart >= newDuration - 0.05 {
            clips[i].trimStart = min(clips[i].trimStart, max(0, newDuration - 0.2))
            clips[i].trimEnd = newDuration
        }
        clips[i].thumbnail = nil
        clips[i].filmstrip = []
        let replacedID = clips[i].id
        rebuild()

        // Refresh thumbnail + filmstrip off the swapped media.
        if isImage {
            let thumb = await Task.detached { Self.imageThumbnail(at: durableURL) }.value
            if let j = clips.firstIndex(where: { $0.id == replacedID }), let thumb {
                clips[j].thumbnail = thumb
                clips[j].filmstrip = [thumb]
            }
        } else {
            let asset = AVURLAsset(url: durableURL)
            let thumb = await Self.thumbnail(for: asset, at: 0.03)
            if let j = clips.firstIndex(where: { $0.id == replacedID }) {
                clips[j].thumbnail = thumb
            }
            refreshFilmstrip(clipID: replacedID)
        }
    }

    /// True while a clip is being reversed (offline bake) — drives a spinner.
    @Published private(set) var isBaking = false

    /// Reverses the selected clip's trimmed range offline, then swaps the
    /// clip's media to the baked reversed file. Speed/grade/transition/display
    /// carry over; the baked file IS the reversed window, so trim resets to
    /// full. Photo clips have nothing to reverse and are skipped.
    func reverseSelectedClip() async {
        guard let id = selectedClipID,
              let clip = clips.first(where: { $0.id == id }),
              !clip.isImage else { return }
        let sourceURL = clip.url
        let trimStart = clip.trimStart
        let trimEnd = clip.trimEnd
        let outputURL = store.clipsFolder
            .appendingPathComponent("reversed_\(UUID().uuidString).mov")

        isBaking = true
        let baked: URL? = await Task.detached(priority: .userInitiated) {
            try? await ClipBaker.reverse(url: sourceURL, trimStart: trimStart,
                                         trimEnd: trimEnd, outputURL: outputURL)
        }.value
        isBaking = false

        guard let baked else { return }
        let asset = AVURLAsset(url: baked)
        guard let duration = try? await asset.load(.duration).seconds,
              duration > 0.05,
              let i = clips.firstIndex(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: baked)
            return
        }
        pushUndoSnapshot()
        clips[i].url = baked
        clips[i].assetDuration = duration
        clips[i].trimStart = 0
        clips[i].trimEnd = duration
        clips[i].hasAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
        clips[i].thumbnail = await Self.thumbnail(for: asset, at: 0.03)
        clips[i].filmstrip = []
        rebuild()
        refreshFilmstrip(clipID: id)
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
        guard let thumb else { return }   // unreadable image: don't add a dead clip
        // First media decides the canvas (photos too).
        if clips.isEmpty {
            let aspect = CGFloat(thumb.width) / max(CGFloat(thumb.height), 1)
            format = aspect < 0.85 ? .vertical : (aspect < 1.15 ? .square : .widescreen)
        }
        pushUndoSnapshot()
        var clip = Clip(id: UUID(), url: durableURL,
                        assetDuration: Self.photoMaxDuration,
                        trimStart: 0, trimEnd: Self.photoDefaultDuration,
                        isImage: true)
        clip.thumbnail = thumb
        clip.filmstrip = [thumb]
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

    /// Deletes the selected clip. When `ripple` (the NLE default), every
    /// overlay/music item that started after the removed clip slides earlier
    /// by the clip's timeline length so nothing drifts out of sync; a non-
    /// ripple delete leaves the other lanes pinned to the clock.
    func deleteSelected(ripple: Bool = true) {
        guard let id = selectedClipID,
              let clip = clips.first(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        let start = clipStartTimes[id] ?? 0
        let length = clip.timelineDuration
        clips.removeAll { $0.id == id }
        if ripple, length > 0 {
            for i in overlays.indices where overlays[i].timelineOffset > start + 0.01 {
                overlays[i].timelineOffset = max(0, overlays[i].timelineOffset - length)
            }
            for i in audioTracks.indices where audioTracks[i].timelineOffset > start + 0.01 {
                audioTracks[i].timelineOffset = max(0, audioTracks[i].timelineOffset - length)
            }
        }
        selectedClipID = clips.last?.id
        rebuild()
    }

    /// In-session clipboard: survives across projects so a clip copied in one
    /// project can be pasted into another.
    static var clipboardClip: Clip?

    /// Duplicates the selected clip (all trim/speed/grade/transition state)
    /// as a new clip inserted right after it.
    func duplicateSelected() {
        guard let id = selectedClipID,
              let index = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        var copy = clips[index]
        copy.id = UUID()
        copy.transitionAfter = .none   // don't duplicate the cut into the original's neighbour
        clips.insert(copy, at: index + 1)
        selectedClipID = copy.id
        rebuild()
        refreshFilmstrip(clipID: copy.id)
    }

    /// Copies the selected clip to the in-session clipboard.
    func copySelected() {
        guard let id = selectedClipID,
              let clip = clips.first(where: { $0.id == id }) else { return }
        Self.clipboardClip = clip
    }

    /// Pastes the clipboard clip (fresh UUID) after the selection, or appends
    /// it if nothing is selected. The media file is shared by URL — the
    /// PersistenceStore reference-counting already handles shared fileNames.
    func pasteClip() {
        guard var copy = Self.clipboardClip else { return }
        pushUndoSnapshot()
        copy.id = UUID()
        copy.transitionAfter = .none
        let insertAt = selectedClipID
            .flatMap { sel in clips.firstIndex(where: { $0.id == sel }) }
            .map { $0 + 1 } ?? clips.count
        clips.insert(copy, at: insertAt)
        selectedClipID = copy.id
        rebuild()
        refreshFilmstrip(clipID: copy.id)
    }

    /// Continuous per-clip speed (0.1×…4×). `setSpeed` already accepts any
    /// Double; this just clamps for the slider.
    func setClipSpeed(_ speed: Double) {
        setSpeed(min(4, max(0.1, speed)))
    }

    /// Sets a speed-ramp preset on the selected clip (rebuilds the timing).
    func setSpeedRamp(_ ramp: SpeedRamp) {
        guard let id = selectedClipID,
              let i = clips.firstIndex(where: { $0.id == id }) else { return }
        guard clips[i].speedRamp != ramp.rawValue else { return }
        pushUndoSnapshot()
        clips[i].speedRamp = ramp.rawValue
        rebuild()
    }

    /// Applies a free crop (unit rect) + straighten to the selected clip.
    func setCropStraighten(id: UUID, cropRect: CGRect, straightenDegrees: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        clips[i].cropRect = cropRect
        clips[i].straightenDegrees = max(-15, min(15, straightenDegrees))
        rebuild()
        refreshFilmstrip(clipID: id)
    }

    /// Rotates the selected clip 90° clockwise (wraps at 4).
    func rotateSelectedClip() {
        guard let id = selectedClipID,
              let i = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        clips[i].rotationQuarterTurns = (clips[i].rotationQuarterTurns + 1) % 4
        rebuild()
    }

    /// Toggles a horizontal mirror on the selected clip.
    func mirrorSelectedClip() {
        guard let id = selectedClipID,
              let i = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        clips[i].isMirrored.toggle()
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

    /// Default freeze-frame hold duration (seconds).
    static let freezeDuration = 2.0

    /// Freeze frame: grabs the frame under the playhead as a still, splits the
    /// clip there, and drops the frozen still (a photo clip) into the gap so
    /// the action holds before resuming. Uses the existing T7 photo-clip path.
    func freezeAtPlayhead() async {
        let starts = clipStartTimes
        guard let index = clips.firstIndex(where: { clip in
            guard let start = starts[clip.id] else { return false }
            return currentTime >= start - 0.01 && currentTime < start + clip.timelineDuration + 0.01
        }), !clips[index].isImage else { return }

        let clip = clips[index]
        let localOffset = (currentTime - (starts[clip.id] ?? 0)) * clip.speed
        let sourceTime = min(max(clip.trimStart, clip.trimStart + localOffset), clip.trimEnd)

        // Render the frame at full source resolution.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let cg = try? await generator.image(
            at: CMTime(seconds: sourceTime, preferredTimescale: 600)).image else { return }

        let stillURL = store.clipsFolder.appendingPathComponent("freeze_\(UUID().uuidString).jpg")
        guard Self.writeJPEG(cg, to: stillURL) else { return }

        pushUndoSnapshot()
        var freeze = Clip(id: UUID(), url: stillURL, assetDuration: Self.photoMaxDuration,
                          trimStart: 0, trimEnd: Self.freezeDuration, isImage: true)
        let thumb = Self.imageThumbnail(at: stillURL)
        freeze.thumbnail = thumb
        freeze.filmstrip = thumb.map { [$0] } ?? []

        // Split only when both halves survive; otherwise butt the freeze up
        // against the clip edge.
        if sourceTime > clip.trimStart + 0.1 && sourceTime < clip.trimEnd - 0.1 {
            var first = clip
            first.trimEnd = sourceTime
            first.transitionAfter = .none
            var second = clip
            second.id = UUID()
            second.trimStart = sourceTime
            second.thumbnail = nil
            clips[index] = first
            clips.insert(freeze, at: index + 1)
            clips.insert(second, at: index + 2)
            refreshFilmstrip(clipID: first.id)
            refreshFilmstrip(clipID: second.id)
        } else {
            clips.insert(freeze, at: index + 1)
        }
        selectedClipID = freeze.id
        rebuild()
    }

    /// Writes a CGImage to `url` as JPEG. Returns false on failure.
    nonisolated static func writeJPEG(_ image: CGImage, to url: URL, quality: CGFloat = 0.9) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
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
                                     overlayTracks: lastBuiltTracks.overlay,
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
    func addAudioTrack(importedURL: URL, title: String, at explicitOffset: Double? = nil,
                       kind: AudioLaneKind = .music) async {
        let asset = AVURLAsset(url: importedURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.05 else { return }
        pushUndoSnapshot()
        let offset = explicitOffset.map { min(max(0, $0), max(0, totalDuration - 0.2)) }
            ?? (audioTracks.isEmpty ? 0 : min(currentTime, max(0, totalDuration - 0.2)))
        audioTracks.append(MusicTrack(id: UUID(), url: importedURL, title: title,
                                      assetDuration: duration,
                                      trimStart: 0, trimEnd: duration, timelineOffset: offset,
                                      kind: kind))
        rebuild()
        refreshAllWaveforms()
    }

    /// Changes an audio lane's kind (colour/icon only — mix-only, no rebuild).
    func setAudioKind(id: UUID, _ kind: AudioLaneKind) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }),
              audioTracks[i].kind != kind else { return }
        audioTracks[i].kind = kind
        scheduleAutosave()
    }

    // MARK: - Voiceover (Next-10 #8)

    /// Records narration to picture: playback rolls MUTED (no mic echo)
    /// from the playhead while the mic captures; stop drops the take on its
    /// own audio lane exactly where recording started.
    @Published private(set) var isRecordingVoiceover = false
    private var voiceoverRecorder: AVAudioRecorder?
    private var voiceoverStartOffset: Double = 0

    func startVoiceover() {
        guard !isRecordingVoiceover, totalDuration > 0.4 else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .videoRecording,
                                 options: [.defaultToSpeaker])
        try? session.setActive(true)

        let url = store.audioFolder.appendingPathComponent("Voiceover_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings),
              recorder.record() else {
            try? session.setCategory(.playback, mode: .moviePlayback)
            return
        }
        voiceoverRecorder = recorder
        voiceoverStartOffset = min(currentTime, max(0, totalDuration - 0.4))
        isRecordingVoiceover = true
        player?.isMuted = true
        if !isPlaying { togglePlayback() }
    }

    func stopVoiceover() {
        guard isRecordingVoiceover, let recorder = voiceoverRecorder else { return }
        recorder.stop()
        voiceoverRecorder = nil
        isRecordingVoiceover = false
        if isPlaying { togglePlayback() }
        player?.isMuted = false
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let url = recorder.url
        let start = voiceoverStartOffset
        let count = audioTracks.filter { $0.title.hasPrefix("Voiceover") }.count
        Task {
            await addAudioTrack(importedURL: url,
                                title: count == 0 ? "Voiceover" : "Voiceover \(count + 1)",
                                at: start, kind: .voice)
            seek(to: start)
        }
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
    func setTransition(afterClipID id: UUID, style: TransitionStyle, duration: Double? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }), i < clips.count - 1 else { return }
        guard clips[i].transitionAfter != style
                || clips[i].transitionDuration != duration else { return }
        pushUndoSnapshot()
        clips[i].transitionAfter = style
        clips[i].transitionDuration = duration
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

    /// Sets the same transition at EVERY cut (all clips except the last). One
    /// undo snapshot + one rebuild, mirroring applyGradeToAllClips.
    func setTransitionForAllCuts(style: TransitionStyle, duration: Double? = nil) {
        guard clips.count > 1 else { return }
        let cutIndices = 0..<(clips.count - 1)
        guard cutIndices.contains(where: {
            clips[$0].transitionAfter != style || clips[$0].transitionDuration != duration
        }) else { return }
        pushUndoSnapshot()
        for i in cutIndices {
            clips[i].transitionAfter = style
            clips[i].transitionDuration = duration
        }
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
        var item = OverlayItem(id: UUID(), url: durableURL, isImage: isImage,
                               timelineOffset: offset, duration: duration,
                               title: url.deletingPathExtension().lastPathComponent)
        if !isImage { item.mediaDuration = mediaDuration }
        overlays.append(item)
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
        refreshOverlayThumbnails()
    }

    /// Adds a TEXT layer (T6) on the overlay lane at the playhead. Rides the
    /// whole overlay machinery: placement, keyframes, opacity, trim.
    func addTextOverlay() {
        guard totalDuration > 0.4 else { return }
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
        let duration = min(3.0, maxEnd - offset)
        guard duration > 0.2 else { return }

        pushUndoSnapshot()
        var item = OverlayItem(id: UUID(),
                               url: URL(fileURLWithPath: "/dev/null"),
                               isImage: true,
                               timelineOffset: offset, duration: duration,
                               title: "Text")
        item.text = "Your Title"
        item.sizeFraction = 0.6
        item.center = CGPoint(x: 0.5, y: 0.5)
        overlays.append(item)
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
    }

    /// Text content/style edits are live (the compositor's text cache keys
    /// on the content) — but the SPECS carry the string, so rebuild.
    func setOverlayText(id: UUID, _ text: String) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              overlays[i].text != nil, overlays[i].text != text else { return }
        overlays[i].text = text
        rebuild()
    }

    func setOverlayTextStyle(id: UUID, _ style: TextLayerStyle) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              overlays[i].text != nil, overlays[i].textStyle != style else { return }
        overlays[i].textStyle = style
        rebuild()
    }

    func setOverlayTextColor(id: UUID, _ hex: String) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              overlays[i].text != nil, overlays[i].textColorHex != hex else { return }
        overlays[i].textColorHex = hex
        rebuild()
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
        // Only overlays on the SAME lane collide; different lanes may overlap.
        for other in overlays where other.id != id && other.lane == item.lane {
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

    func setOverlayRotation(id: UUID, _ degrees: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].rotationDegrees = min(max(-180, degrees), 180)
        overlayKeyframeAutoUpsert(index: i)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    // MARK: Overlay keyframes (T5)

    /// Pins the overlay's CURRENT placement at the playhead. Sliders after
    /// this auto-update the keyframe under the playhead (CapCut model).
    func addOverlayKeyframe(id: UUID) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let overlay = overlays[i]
        let offset = min(max(0, currentTime - overlay.timelineOffset), overlay.duration)
        pushUndoSnapshot()
        upsertKeyframe(index: i, at: offset)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    func clearOverlayKeyframes(id: UUID) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              !overlays[i].keyframes.isEmpty else { return }
        pushUndoSnapshot()
        overlays[i].keyframes = []
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// While an overlay HAS keyframes, placement sliders write to the
    /// keyframe at the playhead (creating it if needed) instead of the base.
    private func overlayKeyframeAutoUpsert(index: Int) {
        guard !overlays[index].keyframes.isEmpty else { return }
        let overlay = overlays[index]
        let offset = min(max(0, currentTime - overlay.timelineOffset), overlay.duration)
        upsertKeyframe(index: index, at: offset)
    }

    private func upsertKeyframe(index: Int, at offset: Double) {
        let overlay = overlays[index]
        let frame = OverlayKeyframe(time: offset,
                                    sizeFraction: overlay.sizeFraction,
                                    centerX: overlay.center.x,
                                    centerY: overlay.center.y,
                                    opacity: overlay.opacity,
                                    rotationDegrees: overlay.rotationDegrees)
        var frames = overlay.keyframes.filter { abs($0.time - offset) > 0.15 }
        frames.append(frame)
        overlays[index].keyframes = frames.sorted { $0.time < $1.time }
    }

    /// Overlay trim (gap fix): the lane bar's leading handle trims content
    /// AND advances the bar so the out-point stays anchored; the trailing
    /// handle adjusts duration. One undo entry per drag.
    func trimOverlayHead(id: UUID, deltaSeconds: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let item = overlays[i]
        var applied = min(deltaSeconds, item.duration - 0.2)
        if !item.isImage && item.text == nil {
            applied = max(applied, -item.mediaStart)   // no material before 0
        }
        applied = max(applied, -item.timelineOffset)   // can't start before 0
        guard abs(applied) > 0.01 else { return }
        pushUndoSnapshot()
        if !item.isImage && item.text == nil {
            overlays[i].mediaStart = item.mediaStart + applied
        }
        overlays[i].timelineOffset = item.timelineOffset + applied
        overlays[i].duration = item.duration - applied
        rebuild()
    }

    func trimOverlayTail(id: UUID, deltaSeconds: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let item = overlays[i]
        var maxDuration = max(0.2, totalDuration - item.timelineOffset)
        if !item.isImage && item.text == nil {
            maxDuration = min(maxDuration, item.mediaDuration - item.mediaStart)
        }
        if let next = overlays
            .filter({ $0.id != id && $0.timelineOffset > item.timelineOffset + 0.05 })
            .min(by: { $0.timelineOffset < $1.timelineOffset }) {
            maxDuration = min(maxDuration, next.timelineOffset - item.timelineOffset)
        }
        let newDuration = min(max(0.2, item.duration + deltaSeconds), maxDuration)
        guard abs(newDuration - item.duration) > 0.01 else { return }
        pushUndoSnapshot()
        overlays[i].duration = newDuration
        rebuild()
    }

    /// Overlay audio: mix-only, live, no rebuild.
    func setOverlayVolume(id: UUID, _ volume: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].volume = min(max(0, volume), 100)
        applyAudioSettings()
        scheduleAutosave()
    }

    func setOverlayMuted(id: UUID, _ muted: Bool) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].isMuted = muted
        applyAudioSettings()
        scheduleAutosave()
    }

    /// Size/position/opacity are LIVE: the compositor reads `overlayLayout`
    /// per frame, so sliders never trigger a rebuild (the LookState trick).
    func setOverlayOpacity(id: UUID, _ opacity: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].opacity = min(max(0, opacity), 1)
        overlayKeyframeAutoUpsert(index: i)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    func setOverlaySize(id: UUID, _ fraction: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].sizeFraction = min(max(0.25, fraction), 1.0)
        overlayKeyframeAutoUpsert(index: i)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    func setOverlayCenter(id: UUID, _ center: CGPoint) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].center = CGPoint(x: min(max(0, center.x), 1),
                                     y: min(max(0, center.y), 1))
        overlayKeyframeAutoUpsert(index: i)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    // MARK: - Overlay effects (blend / chroma / mask / adjust / border)

    /// Discrete change → snapshot; all live (no rebuild) via overlayEffects box.
    func setOverlayBlendMode(id: UUID, _ mode: OverlayBlendMode) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              overlays[i].effects.blendMode != mode else { return }
        pushUndoSnapshot()
        overlays[i].effects.blendMode = mode
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// Toggling on/off snapshots; slider drags (passing snapshot:false) don't.
    func setOverlayChroma(id: UUID, _ chroma: ChromaKeySettings?, snapshot: Bool = true) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        if snapshot { pushUndoSnapshot() }
        overlays[i].effects.chroma = chroma
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    func setOverlayMask(id: UUID, _ mask: OverlayMaskSettings?, snapshot: Bool = true) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        if snapshot { pushUndoSnapshot() }
        overlays[i].effects.mask = mask
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    func setOverlayBorder(id: UUID, _ border: OverlayBorderSettings?, snapshot: Bool = true) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        if snapshot { pushUndoSnapshot() }
        overlays[i].effects.border = border
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// Applies a PIP preset (placement + mask/border) in one undo step. A
    /// preset defines a static layout, so any placement keyframes are cleared.
    func applyPipPreset(id: UUID, _ preset: PipPreset) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        overlays[i].sizeFraction = min(max(0.05, preset.sizeFraction), 1.0)
        overlays[i].center = preset.center
        overlays[i].effects.mask = preset.mask
        overlays[i].effects.border = preset.border
        overlays[i].keyframes = []
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// Live tone sliders — no snapshot.
    func setOverlayAdjustments(id: UUID, _ adjust: OverlayAdjustments?) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].effects.adjust = (adjust?.isIdentity ?? true) ? nil : adjust
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// Highest lane currently in use (for placing new overlays / UI bounds).
    var maxOverlayLane: Int { overlays.map(\.lane).max() ?? 0 }

    /// Nudges an overlay's z-order lane up (forward) or down (back). A lane
    /// change moves the overlay to a different composition video track, so it
    /// needs a rebuild (unlike the live size/position setters).
    func nudgeOverlayLane(id: UUID, by delta: Int) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let newLane = max(0, min(4, overlays[i].lane + delta))
        guard newLane != overlays[i].lane else { return }
        pushUndoSnapshot()
        overlays[i].lane = newLane
        rebuild()
    }

    // MARK: - Adjustment layers

    static let adjustmentDefaultDuration = 3.0

    /// Adds a full-frame adjustment layer at the playhead. Returns its id so
    /// the UI can open it for editing.
    @discardableResult
    func addAdjustmentLayer(grade: ClipGrade) -> UUID {
        pushUndoSnapshot()
        let start = min(max(0, currentTime), max(0, totalDuration - 0.4))
        let duration = min(Self.adjustmentDefaultDuration, max(0.5, totalDuration - start))
        let layer = AdjustmentLayer(timelineOffset: start, duration: duration, grade: grade)
        adjustmentLayers.append(layer)
        rebuild()
        return layer.id
    }

    func removeAdjustmentLayer(id: UUID) {
        guard adjustmentLayers.contains(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        adjustmentLayers.removeAll { $0.id == id }
        rebuild()
    }

    func setAdjustmentGrade(id: UUID, grade: ClipGrade) {
        guard let i = adjustmentLayers.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        adjustmentLayers[i].grade = grade
        rebuild()
    }

    func setAdjustmentSpan(id: UUID, offset: Double, duration: Double) {
        guard let i = adjustmentLayers.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        adjustmentLayers[i].timelineOffset = max(0, min(offset, max(0, totalDuration - 0.2)))
        adjustmentLayers[i].duration = max(0.2, min(duration, totalDuration - adjustmentLayers[i].timelineOffset))
        rebuild()
    }

    // MARK: - Ken Burns (per-clip pan/zoom)

    /// Ken Burns direction presets — each lays down a start + end keyframe
    /// spanning the clip's trimmed duration.
    enum KenBurnsPreset: String, CaseIterable {
        case none, zoomIn, zoomOut, panLeft, panRight, panUp, panDown

        var label: String {
            switch self {
            case .none: return "None"
            case .zoomIn: return "Zoom In"
            case .zoomOut: return "Zoom Out"
            case .panLeft: return "Pan Left"
            case .panRight: return "Pan Right"
            case .panUp: return "Pan Up"
            case .panDown: return "Pan Down"
            }
        }
    }

    /// Applies a Ken Burns preset to the selected clip (2 keyframes across its
    /// trimmed run). Live: only the layout + paused frame refresh, no rebuild.
    /// `easing` shapes the motion (default Smooth for a natural ease-in-out).
    func setKenBurns(id: UUID, preset: KenBurnsPreset, easing: KeyframeEasing = .easeInOut) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        let dur = clips[i].timelineDuration
        let z = 1.3
        let lo = 0.28, hi = 0.72   // pan extremes (keep the window in-frame)
        let c = 0.5
        func kf(_ t: Double, _ zoom: Double, _ x: Double, _ y: Double) -> ClipTransformKeyframe {
            ClipTransformKeyframe(time: t, zoom: zoom, centerX: x, centerY: y,
                                  easing: t == 0 ? easing.rawValue : nil)
        }
        switch preset {
        case .none:     clips[i].transformKeyframes = []
        case .zoomIn:   clips[i].transformKeyframes = [kf(0, 1, c, c), kf(dur, z, c, c)]
        case .zoomOut:  clips[i].transformKeyframes = [kf(0, z, c, c), kf(dur, 1.001, c, c)]
        case .panLeft:  clips[i].transformKeyframes = [kf(0, z, hi, c), kf(dur, z, lo, c)]
        case .panRight: clips[i].transformKeyframes = [kf(0, z, lo, c), kf(dur, z, hi, c)]
        case .panUp:    clips[i].transformKeyframes = [kf(0, z, c, hi), kf(dur, z, c, lo)]
        case .panDown:  clips[i].transformKeyframes = [kf(0, z, c, lo), kf(dur, z, c, hi)]
        }
        syncClipTransformLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// Re-eases the selected clip's existing Ken Burns motion (updates the
    /// easing on its first keyframe, which drives the whole segment).
    func setKenBurnsEasing(id: UUID, easing: KeyframeEasing) {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              !clips[i].transformKeyframes.isEmpty else { return }
        pushUndoSnapshot()
        clips[i].transformKeyframes[0].easing = easing.rawValue
        syncClipTransformLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// Mirrors clips' Ken Burns keyframes into the live layout the compositor
    /// reads. Times are stored as offsets within each clip's run.
    func syncClipTransformLayout(refreshFrame: Bool = false) {
        var map: [UUID: [ClipTransformLayout.Keyframe]] = [:]
        for clip in clips where !clip.transformKeyframes.isEmpty {
            map[clip.id] = clip.transformKeyframes.map {
                ClipTransformLayout.Keyframe(
                    time: $0.time,
                    transform: ClipTransformLayout.Transform(
                        zoom: $0.zoom, center: CGPoint(x: $0.centerX, y: $0.centerY)),
                    easing: $0.easing.flatMap { KeyframeEasing(rawValue: $0) } ?? .linear)
            }
        }
        clipTransformLayout.replaceAll(map)
        if refreshFrame, let player, player.timeControlStatus != .playing {
            let time = player.currentTime()
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Mirrors the overlays' placement values into the live layout box the
    /// compositor reads, and re-renders the paused frame so edits show
    /// immediately (a paused player never re-runs the compositor on its own).
    private func syncOverlayLayout(refreshFrame: Bool = false) {
        var map: [UUID: (OverlayLayout.Placement, [OverlayLayout.Keyframe])] = [:]
        for overlay in overlays {
            let base = OverlayLayout.Placement(sizeFraction: overlay.sizeFraction,
                                               center: overlay.center,
                                               opacity: overlay.opacity,
                                               rotationDegrees: overlay.rotationDegrees)
            let frames = overlay.keyframes.map {
                OverlayLayout.Keyframe(time: $0.time, placement: OverlayLayout.Placement(
                    sizeFraction: $0.sizeFraction,
                    center: CGPoint(x: $0.centerX, y: $0.centerY),
                    opacity: $0.opacity,
                    rotationDegrees: $0.rotationDegrees),
                    easing: $0.easing.flatMap { KeyframeEasing(rawValue: $0) } ?? .linear)
            }
            map[overlay.id] = (base, frames)
        }
        overlayLayout.replaceAll(map)
        overlayEffects.replaceAll(Dictionary(uniqueKeysWithValues:
            overlays.map { ($0.id, $0.effects) }))
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
                 audioTracks: audioTracks, overlays: overlays,
                 adjustmentLayers: adjustmentLayers,
                 canvasMode: canvasMode, canvasSolidHex: canvasSolidHex,
                 canvasGradientTopHex: canvasGradientTopHex,
                 canvasGradientBottomHex: canvasGradientBottomHex)
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
        adjustmentLayers = snapshot.adjustmentLayers
        canvasMode = snapshot.canvasMode
        canvasSolidHex = snapshot.canvasSolidHex
        canvasGradientTopHex = snapshot.canvasGradientTopHex
        canvasGradientBottomHex = snapshot.canvasGradientBottomHex
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

    /// Frame duration matching the export video composition (1/30). Used by
    /// the frame-nudge transport and the MM:SS:FF timecode readout.
    var frameDuration: Double { 1.0 / 30.0 }

    /// Frame-exact nudge: pauses, steps the current item by ±N frames (no seek
    /// tolerance games), and re-syncs the published clock.
    func stepFrame(_ count: Int) {
        guard let item = player?.currentItem else { return }
        if isPlaying { togglePlayback() }
        item.step(byCount: count)
        currentTime = min(max(0, item.currentTime().seconds), totalDuration)
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
            lastBuiltTracks = (nil, [], [])
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
        lastBuiltTracks = (built.clipAudioTrack, built.musicAudioTracks, built.overlayAudioTracks)

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

    /// Inserts `assetLength` seconds of a clip's video into the aux A/B-roll
    /// track at composition time `at`, occupying `timelineLength` seconds
    /// (speed-scaled). Tries candidate asset starts in order; the first that
    /// fits inside the asset wins.
    private static func insertAux(track: AVMutableCompositionTrack,
                                  clip: Clip,
                                  candidateStarts: [Double],
                                  assetLength: Double,
                                  timelineLength: Double,
                                  at: CMTime,
                                  cursor: CMTime)
        async -> (inserted: Bool, transform: CGAffineTransform, cursor: CMTime) {
        let asset = AVURLAsset(url: clip.url)
        guard let source = try? await asset.loadTracks(withMediaType: .video).first,
              let assetDuration = try? await asset.load(.duration).seconds else {
            return (false, .identity, cursor)
        }
        let transform = (try? await source.load(.preferredTransform)) ?? .identity
        guard let start = candidateStarts
            .map({ min(max(0, $0), max(0, assetDuration - assetLength)) })
            .first(where: { $0 + assetLength <= assetDuration + 0.001 }),
              assetLength > 0.02, at >= cursor else {
            return (false, transform, cursor)
        }
        if at > cursor {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor, end: at))
        }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: assetLength, preferredTimescale: 600))
        do {
            try track.insertTimeRange(range, of: source, at: at)
        } catch {
            return (false, transform, cursor)
        }
        let target = CMTime(seconds: timelineLength, preferredTimescale: 600)
        if abs(assetLength - timelineLength) > 0.001 {
            track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration),
                                 toDuration: target)
        }
        return (true, transform, at + target)
    }

    /// Builds the composition + video composition + audio mix for preview or export.
    /// `renderScale` multiplies the format's canvas for high-res exports —
    /// the #93 matrix caught 4K exports silently capped at the preview's
    /// 1080p renderSize (the preset can't exceed the composition canvas).
    func buildComposition(renderScale: CGFloat = 1) async throws -> BuiltTimeline {
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
                                       clipLookState: clip.grade.map(makeLookState),
                                       display: clip.displayOps,
                                       clipID: clip.id))
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
            let ramp = SpeedRamp(rawValue: clip.speedRamp) ?? SpeedRamp.none
            if ramp != .none {
                // Piecewise ramp: slice the inserted range and time-scale each
                // slice by its curve speed. Scale slices LAST→FIRST so earlier
                // slices keep their track positions until their turn.
                let slices = 12
                let srcDur = clip.trimEnd - clip.trimStart
                let sliceSrc = srcDur / Double(slices)
                var total = 0.0
                for k in stride(from: slices - 1, through: 0, by: -1) {
                    let s = ramp.speed(at: (Double(k) + 0.5) / Double(slices))
                    let sliceRange = CMTimeRange(
                        start: cursor + CMTime(seconds: Double(k) * sliceSrc, preferredTimescale: timescale),
                        duration: CMTime(seconds: sliceSrc, preferredTimescale: timescale))
                    let scaled = CMTime(seconds: sliceSrc / s, preferredTimescale: timescale)
                    videoTrack.scaleTimeRange(sliceRange, toDuration: scaled)
                    if insertedAudio { audioTrack?.scaleTimeRange(sliceRange, toDuration: scaled) }
                    total += sliceSrc / s
                }
                insertedDuration = CMTime(seconds: total, preferredTimescale: timescale)
            } else if clip.speed != 1.0 {
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
                                   clipLookState: clip.grade.map(makeLookState),
                                   display: clip.displayOps,
                                   clipID: clip.id))
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
        // Video overlays ride per-lane composition tracks so overlapping
        // overlays on different lanes never collide on one sequential track.
        var overlayLaneTracks: [Int: (track: AVMutableCompositionTrack, cursor: CMTime)] = [:]
        var overlayAudioTracks: [(id: UUID, track: AVMutableCompositionTrack)] = []
        for overlay in overlays.sorted(by: { $0.timelineOffset < $1.timelineOffset }) {
            let start = min(max(0, overlay.timelineOffset), cursor.seconds)
            var playable = min(overlay.duration, cursor.seconds - start)
            if !overlay.isImage, overlay.text == nil {
                playable = min(playable, max(0, overlay.mediaDuration - overlay.mediaStart))
            }
            guard playable > 0.05 else { continue }

            if let text = overlay.text {
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: kCMPersistentTrackID_Invalid,
                                                imageURL: nil,
                                                transform: .identity,
                                                start: start, end: start + playable,
                                                text: text,
                                                textFontName: overlay.textStyle.fontName,
                                                textColorHex: overlay.textColorHex,
                                                lane: overlay.lane))
                continue
            }
            if overlay.isImage {
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: kCMPersistentTrackID_Invalid,
                                                imageURL: overlay.url,
                                                transform: .identity,
                                                start: start, end: start + playable,
                                                lane: overlay.lane))
                continue
            }

            let overlayAsset = AVURLAsset(url: overlay.url)
            guard let sourceVideo = try? await overlayAsset.loadTracks(withMediaType: .video).first
            else { continue }
            let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            if overlayLaneTracks[overlay.lane] == nil,
               let t = composition.addMutableTrack(withMediaType: .video,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                overlayLaneTracks[overlay.lane] = (t, .zero)
            }
            guard let laneEntry = overlayLaneTracks[overlay.lane] else { continue }
            let track = laneEntry.track
            let at = CMTime(seconds: start, preferredTimescale: 600)
            if at > laneEntry.cursor {
                track.insertEmptyTimeRange(CMTimeRange(start: laneEntry.cursor, end: at))
            }
            let range = CMTimeRange(start: CMTime(seconds: overlay.mediaStart, preferredTimescale: 600),
                                    duration: CMTime(seconds: playable, preferredTimescale: 600))
            do {
                try track.insertTimeRange(range, of: sourceVideo, at: at)
                overlayLaneTracks[overlay.lane] = (track, at + range.duration)
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: track.trackID,
                                                imageURL: nil,
                                                transform: transform,
                                                start: start, end: start + playable,
                                                lane: overlay.lane))
                // Overlay AUDIO rides its own lazy track (was silently
                // dropped in v1). Same rule as everywhere: never leave an
                // empty audio track behind — export dies on it.
                if let sourceAudio = try? await overlayAsset.loadTracks(withMediaType: .audio).first,
                   let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
                    do {
                        try audioTrack.insertTimeRange(range, of: sourceAudio, at: at)
                        overlayAudioTracks.append((overlay.id, audioTrack))
                    } catch {
                        composition.removeTrack(audioTrack)
                    }
                }
            } catch {
                // Failed insert with no real media on the track yet: drop
                // it so no media-less video track breaks the export session.
                if track.segments.allSatisfy({ $0.isEmpty }) {
                    composition.removeTrack(track)
                    overlayLaneTracks[overlay.lane] = nil
                }
            }
        }
        syncOverlayLayout()
        syncClipTransformLayout()

        // Transition boundaries: cut time + style, sampled by the compositor.
        // Cross-transitions (dissolve/wipe) get REAL second frames via an aux
        // A/B-roll track carrying pre/post-roll material around each cut —
        // cut times never move, so no timeline math ripples.
        var spans: [TransitionSpanSpec] = []
        var auxTrack: AVMutableCompositionTrack?
        var auxCursor = CMTime.zero
        for (index, clip) in clips.enumerated() where index < clips.count - 1 {
            guard clip.transitionAfter != .none, index < metas.count else { continue }
            let next = clips[index + 1]
            let cut = metas[index].end
            var half = (clip.transitionDuration ?? clip.transitionAfter.duration) / 2
            // A transition can't outlast either neighbour.
            half = min(half, clip.timelineDuration / 2, next.timelineDuration / 2)
            guard half > 0.03 else { continue }
            var span = TransitionSpanSpec(center: cut, style: clip.transitionAfter, half: half)

            if clip.transitionAfter.isCrossTransition {
                // Photo sides blend from the still cache — no track material.
                if next.isImage { span.headImageURL = next.url }
                if clip.isImage { span.tailImageURL = clip.url }
                span.headLookState = next.grade.map(makeLookState)
                span.tailLookState = clip.grade.map(makeLookState)
                span.headDisplay = next.displayOps   // incoming clip (first half)
                span.tailDisplay = clip.displayOps   // outgoing clip (second half)

                if !next.isImage || !clip.isImage {
                    if auxTrack == nil {
                        auxTrack = composition.addMutableTrack(
                            withMediaType: .video,
                            preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                }
                if let track = auxTrack {
                    // First half [cut−half, cut): the INCOMING clip's frames.
                    // Prefer untrimmed pre-roll so motion continues through
                    // the blend; fall back to the clip's own head material.
                    if !next.isImage {
                        let result = await Self.insertAux(
                            track: track, clip: next,
                            candidateStarts: [next.trimStart - half * next.speed,
                                              next.trimStart],
                            assetLength: half * next.speed,
                            timelineLength: half,
                            at: CMTime(seconds: cut - half, preferredTimescale: 600),
                            cursor: auxCursor)
                        if result.inserted {
                            span.headTransform = result.transform
                            auxCursor = result.cursor
                        }
                    }
                    // Second half [cut, cut+half): the OUTGOING clip's frames.
                    if !clip.isImage {
                        let result = await Self.insertAux(
                            track: track, clip: clip,
                            candidateStarts: [clip.trimEnd,
                                              clip.trimEnd - half * clip.speed],
                            assetLength: half * clip.speed,
                            timelineLength: half,
                            at: CMTime(seconds: cut, preferredTimescale: 600),
                            cursor: auxCursor)
                        if result.inserted {
                            span.tailTransform = result.transform
                            auxCursor = result.cursor
                        }
                    }
                    span.auxTrackID = track.trackID
                }
            }
            spans.append(span)
        }
        // An aux track with no real media would sink the export session.
        if let track = auxTrack, track.segments.allSatisfy({ $0.isEmpty }) {
            composition.removeTrack(track)
            for i in spans.indices { spans[i].auxTrackID = kCMPersistentTrackID_Invalid }
        }

        // The custom compositor does orientation, aspect-fill crop into the
        // chosen format, the active look, overlays, and transition veils —
        // for preview and export alike (the D1 parity guarantee).
        let renderSize = CGSize(width: format.renderSize.width * renderScale,
                                height: format.renderSize.height * renderScale)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = LumaVideoCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let adjustmentSpans = adjustmentLayers
            .filter { $0.duration > 0.05 && $0.timelineOffset < cursor.seconds }
            .map { AdjustmentSpan(start: max(0, $0.timelineOffset),
                                  end: min($0.timelineEnd, cursor.seconds),
                                  state: makeLookState(from: $0.grade)) }
        videoComposition.instructions = makeInstructions(
            totalDuration: cursor,
            mainTrackID: videoTrack.trackID,
            frameMetas: metas,
            transitionSpans: spans,
            overlaySpecs: overlaySpecs,
            adjustmentSpans: adjustmentSpans,
            renderSize: renderSize)
        videoComposition.applySDRColorPolicy()

        let duration = cursor.seconds
        return BuiltTimeline(composition: composition,
                             videoComposition: videoComposition,
                             audioMix: makeAudioMix(clipTrack: audioTrack,
                                                    musicTracks: musicTracks,
                                                    overlayTracks: overlayAudioTracks,
                                                    duration: duration),
                             clipAudioTrack: audioTrack,
                             musicAudioTracks: musicTracks,
                             overlayAudioTracks: overlayAudioTracks,
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
                                  overlaySpecs: [OverlaySpec],
                                  adjustmentSpans: [AdjustmentSpan] = [],
                                  renderSize: CGSize) -> [LumaCompositionInstruction] {
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
        // Adjustment-layer edges bound their own segments.
        for adj in adjustmentSpans {
            cuts.insert(min(max(0, adj.start), total))
            cuts.insert(min(max(0, adj.end), total))
        }
        // Cross-transition windows need their own segments: the aux track is
        // only required (and only exists) inside them.
        for span in transitionSpans where span.style.isCrossTransition {
            cuts.insert(min(max(0, span.center - span.half), total))
            cuts.insert(min(max(0, span.center + span.half), total))
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
            for span in transitionSpans
            where span.auxTrackID != kCMPersistentTrackID_Invalid
                && mid >= span.center - span.half - 0.001
                && mid < span.center + span.half + 0.001 {
                trackIDs.append(NSNumber(value: span.auxTrackID))
            }

            instructions.append(LumaCompositionInstruction(
                timeRange: range,
                requiredSourceTrackIDs: trackIDs,
                mainTrackID: mainTrackID,
                frameMetas: frameMetas,
                transitionSpans: transitionSpans,
                overlays: overlaySpecs,
                overlayLayout: overlayLayout,
                overlayEffects: overlayEffects,
                lookState: lookState,
                renderSize: renderSize,
                zoomFactor: max(1.0, zoom / 100.0),
                canvas: canvasSpec,
                transformLayout: clipTransformLayout,
                adjustments: adjustmentSpans.filter {
                    mid >= $0.start - 0.001 && mid < $0.end + 0.001
                }))
        }
        return instructions
    }

    /// Multi-input mix: clip audio gets volume + fades, music gets its own
    /// independent volume. Track references keyed by ID, so a mix built from
    /// the last rebuild's tracks stays valid for the live player item.
    private func makeAudioMix(clipTrack: AVMutableCompositionTrack?,
                              musicTracks: [(id: UUID, track: AVMutableCompositionTrack)],
                              overlayTracks: [(id: UUID, track: AVMutableCompositionTrack)] = [],
                              duration: Double) -> AVAudioMix? {
        var inputs: [AVMutableAudioMixInputParameters] = []

        if let clipTrack, !clipTrack.segments.isEmpty {
            let parameters = AVMutableAudioMixInputParameters(track: clipTrack)
            // Pitch-preserve on speed change (no chipmunk): high-quality
            // spectral time-stretch, set explicitly so it never depends on the
            // export session's default.
            parameters.audioTimePitchAlgorithm = .spectral
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

        for entry in overlayTracks {
            guard let overlay = overlays.first(where: { $0.id == entry.id }) else { continue }
            let parameters = AVMutableAudioMixInputParameters(track: entry.track)
            parameters.setVolume(Float(overlay.isMuted ? 0 : overlay.volume / 100.0), at: .zero)
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

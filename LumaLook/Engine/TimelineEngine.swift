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
/// Fade shape sampled into piecewise volume ramps.
enum FadeCurve: String, Codable, CaseIterable {
    case linear, easeIn, easeOut, sCurve
    var label: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .sCurve: return "S-Curve"
        }
    }
    /// Maps normalised fade progress 0…1 to a gain multiplier 0…1.
    func value(_ t: Double) -> Double {
        let x = min(max(0, t), 1)
        switch self {
        case .linear: return x
        case .easeIn: return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        case .sCurve: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
    }
}

/// A volume automation point on an audio lane: `time` seconds into the lane's
/// timeline span, `volume` a 0…1 gain multiplier.
struct AudioVolumePoint: Codable, Equatable {
    var time: Double
    var volume: Double
}

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
        /// Per-clip audio fade in/out (seconds) + shape (A3).
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        var fadeCurve: FadeCurve = .linear
        /// F8 — spot tool. Flat fields so StoredClip needs no Codable on
        /// ClipMaskSpec (that type lives in the renderer, which stays pure).
        var maskShape: String? = nil        // ClipMaskShape rawValue; nil = no mask
        var maskEffect: String = ClipMaskEffect.blur.rawValue
        var maskCenterX: Double = 0.5
        var maskCenterY: Double = 0.5
        var maskWidth: Double = 0.3
        var maskHeight: Double = 0.3
        var maskFeather: Double = 0.05
        var maskAmount: Double = 0.6
        var maskFillHex: String = "#000000"
        var maskInverted: Bool = false

        /// The renderer payload, or nil when this clip has no spot tool.
        var maskSpec: ClipMaskSpec? {
            guard let shape = maskShape.flatMap({ ClipMaskShape(rawValue: $0) }) else { return nil }
            return ClipMaskSpec(shape: shape,
                                effect: ClipMaskEffect(rawValue: maskEffect) ?? .blur,
                                center: CGPoint(x: maskCenterX, y: maskCenterY),
                                size: CGSize(width: maskWidth, height: maskHeight),
                                feather: maskFeather,
                                amount: maskAmount,
                                fillHex: maskFillHex,
                                inverted: maskInverted)
        }

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
        /// Fade in/out (seconds) + shape (A3).
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        var fadeCurve: FadeCurve = .linear
        /// Volume automation envelope (A4); empty = flat at `volume`.
        var volumePoints: [AudioVolumePoint] = []
        /// Auto-duck under voice lanes (A5).
        var duckingEnabled: Bool = false
        /// Loop to fill the timeline (A6).
        var isLooping: Bool = false
        /// Audio effect stack (EQ/pitch/voice/reverb/gain) — baked offline (C1-C5).
        var effects: AudioEffectSettings = AudioEffectSettings()
        /// Cached rendered file (transient; nil = use `url` directly).
        var renderedFileURL: URL? = nil
        /// Detected beat times (seconds into the source), transient (C6).
        var beatMarkers: [Double] = []
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
        /// F2 — custom font (PostScript name). nil = the preset's own font.
        var textFontName: String? = nil
        /// F2 — outline. nil hex = no stroke.
        var textStrokeHex: String? = nil
        var textStrokeWidth: Double = 0
        /// F2 — background box behind the glyphs. nil hex = no box.
        var textBoxHex: String? = nil
        /// F2 — "left" | "center" | "right".
        var textAlignment: String = "center"
        /// F3 — animated-text preset (TextAnimation rawValue).
        var textAnimation: String = TextAnimation.none.rawValue
        /// F4 — vector shape layer (ShapeKind rawValue). nil = not a shape.
        var shapeKind: String? = nil
        var shapeFillHex: String? = "#FFFFFF"
        var shapeStrokeHex: String? = nil
        var shapeStrokeWidth: Double = 0
        var shapeRotation: Double = 0

        /// The shape payload, or nil when this layer isn't a shape.
        var shapeSpec: ShapeSpec? {
            guard let kind = shapeKind.flatMap({ ShapeKind(rawValue: $0) }) else { return nil }
            return ShapeSpec(kind: kind,
                             fillHex: shapeFillHex,
                             strokeHex: shapeStrokeHex,
                             strokeWidth: CGFloat(shapeStrokeWidth),
                             rotationDegrees: shapeRotation)
        }

        /// The rasteriser payload for this layer.
        ///
        /// 240pt matches the old CITextImageGenerator's effective size
        /// (fontSize 120 x scaleFactor 2) — the compositor normalises width to
        /// `sizeFraction` afterwards, so this only buys glyph crispness at 4K.
        var textSpec: TextStyleSpec {
            TextStyleSpec(fontName: textFontName ?? textStyle.fontName,
                          pointSize: 240,
                          colorHex: textColorHex,
                          strokeColorHex: textStrokeHex,
                          strokeWidth: CGFloat(textStrokeWidth),
                          boxColorHex: textBoxHex,
                          alignment: textAlignment)
        }
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
        /// Content kind ("sticker" | "shape" | "caption" | nil).
        var kind: String? = nil
        /// Loops its media to fill the overlay's duration (particles/GIF).
        var loopsMedia: Bool = false
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
        /// Exact source rasters used by `OverlayRenderGeometry`. Published only
        /// with the player item built from the same overlay specs.
        let overlaySourceExtents: [UUID: CGRect]
        let duration: Double
        /// The project frame rate this composition was built at.
        let frameRate: Double
    }

    private struct Snapshot {
        var clips: [Clip]
        var format: EditorFormat
        var zoom: Double
        var audioTracks: [MusicTrack]
        var overlays: [OverlayItem]
        var adjustmentLayers: [AdjustmentLayer]
        var effectLayers: [EffectLayer]
        var particleLayers: [ParticleLayer]
        var canvasMode: CanvasBackgroundMode
        var canvasSolidHex: String
        var canvasGradientTopHex: String
        var canvasGradientBottomHex: String
        var framePreset: String
        /// `setAudioReactive` pushes an undo snapshot and the compositor reads
        /// this every rebuild — but it was missing here, so Undo rolled back
        /// everything EXCEPT the reactive effect you were trying to undo.
        var audioReactive: AudioReactiveConfig?
    }

    // Timeline
    @Published private(set) var clips: [Clip] = []
    @Published var selectedClipID: UUID?
    @Published private(set) var audioTracks: [MusicTrack] = []
    @Published private(set) var overlays: [OverlayItem] = []
    /// Geometry metadata from the currently published video composition.
    /// The preview never guesses from thumbnails while a rebuild is in flight.
    @Published private(set) var overlaySourceExtents: [UUID: CGRect] = [:]
    /// F6 — timed full-frame effects (glitch/VHS/light leak/...).
    @Published private(set) var effectLayers: [EffectLayer] = []
    /// F7 — timed particle layers (dust/rain/snow/sparkle/confetti).
    @Published private(set) var particleLayers: [ParticleLayer] = []
    /// Full-frame adjustment grades floating over the clips (adjustment layers).
    @Published private(set) var adjustmentLayers: [AdjustmentLayer] = []
    /// Audio-reactive visual config (D1); nil = off.
    @Published var audioReactive: AudioReactiveConfig?

    struct AudioReactiveConfig: Equatable {
        var style: AudioReactiveStyle
        var strength: Double
        var sourceTrackID: UUID?
    }

    /// Sets/clears the audio-reactive config (needs a rebuild — levels are
    /// precomputed into the instruction payload).
    func setAudioReactive(_ config: AudioReactiveConfig?) {
        pushUndoSnapshot()
        audioReactive = config
        rebuild()
    }

    // Canvas
    @Published var format: EditorFormat = .widescreen
    @Published var zoom: Double = 100
    /// Background fill behind the framed clip (fill/fit/blur/solid/gradient).
    @Published var canvasMode: CanvasBackgroundMode = .fill
    @Published var canvasSolidHex: String = "#101014"
    @Published var canvasGradientTopHex: String = "#2A2A38"
    @Published var canvasGradientBottomHex: String = "#050507"
    /// Project-level frame/border preset (`FramePreset` rawValue).
    @Published var framePreset: String = FramePreset.none.rawValue

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

    /// Sets the project-level frame/border preset (with undo).
    func setFramePreset(_ preset: FramePreset) {
        guard framePreset != preset.rawValue else { return }
        pushUndoSnapshot()
        framePreset = preset.rawValue
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
        mutationCount &+= 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveProject()
        }
    }

    func saveProject() {
        guard !clips.isEmpty else { return }
        // First save mints a unique name — three cards all called
        // "New Project" with identical thumbnails read as data corruption.
        if projectTitle == "New Project" {
            let existing = store.projects.count
            projectTitle = "Project \(existing + 1)"
        }
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
                           speedRamp: $0.speedRamp == SpeedRamp.none.rawValue ? nil : $0.speedRamp,
                           fadeIn: $0.fadeIn == 0 ? nil : $0.fadeIn,
                           fadeOut: $0.fadeOut == 0 ? nil : $0.fadeOut,
                           fadeCurve: $0.fadeCurve == .linear ? nil : $0.fadeCurve.rawValue,
                           maskShape: $0.maskShape,
                           maskEffect: $0.maskShape == nil ? nil : $0.maskEffect,
                           maskCenterX: $0.maskShape == nil ? nil : $0.maskCenterX,
                           maskCenterY: $0.maskShape == nil ? nil : $0.maskCenterY,
                           maskWidth: $0.maskShape == nil ? nil : $0.maskWidth,
                           maskHeight: $0.maskShape == nil ? nil : $0.maskHeight,
                           maskFeather: $0.maskShape == nil ? nil : $0.maskFeather,
                           maskAmount: $0.maskShape == nil ? nil : $0.maskAmount,
                           maskFillHex: $0.maskShape == nil ? nil : $0.maskFillHex,
                           maskInverted: $0.maskInverted ? true : nil)
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
                            kind: $0.kind == .music ? nil : $0.kind.rawValue,
                            fadeIn: $0.fadeIn == 0 ? nil : $0.fadeIn,
                            fadeOut: $0.fadeOut == 0 ? nil : $0.fadeOut,
                            fadeCurve: $0.fadeCurve == .linear ? nil : $0.fadeCurve.rawValue,
                            volumePoints: $0.volumePoints.isEmpty ? nil : $0.volumePoints,
                            duckingEnabled: $0.duckingEnabled ? true : nil,
                            isLooping: $0.isLooping ? true : nil,
                            effects: $0.effects.isNeutral ? nil : $0.effects)
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
                              effects: $0.effects.isIdentity ? nil : $0.effects,
                              kind: $0.kind,
                              loopsMedia: $0.loopsMedia ? true : nil,
                              textFontName: $0.textFontName,
                              textStrokeHex: $0.textStrokeHex,
                              textStrokeWidth: $0.textStrokeWidth == 0 ? nil : $0.textStrokeWidth,
                              textBoxHex: $0.textBoxHex,
                              textAlignment: $0.textAlignment == "center" ? nil : $0.textAlignment,
                              textAnimation: $0.textAnimation == TextAnimation.none.rawValue ? nil : $0.textAnimation,
                              shapeKind: $0.shapeKind,
                              shapeFillHex: $0.shapeFillHex,
                              shapeStrokeHex: $0.shapeStrokeHex,
                              shapeStrokeWidth: $0.shapeStrokeWidth == 0 ? nil : $0.shapeStrokeWidth,
                              shapeRotation: $0.shapeRotation == 0 ? nil : $0.shapeRotation)
            },
            canvasMode: canvasMode == .fill ? nil : canvasMode.rawValue,
            canvasSolidHex: canvasSolidHex,
            canvasGradientTopHex: canvasGradientTopHex,
            canvasGradientBottomHex: canvasGradientBottomHex,
            adjustmentLayers: adjustmentLayers.isEmpty ? nil : adjustmentLayers,
            audioReactive: audioReactive.map {
                StoredAudioReactive(style: $0.style.rawValue, strength: $0.strength,
                                    sourceTrackID: $0.sourceTrackID)
            },
            framePreset: framePreset == FramePreset.none.rawValue ? nil : framePreset,
            effectLayers: effectLayers.isEmpty ? nil : effectLayers,
            particleLayers: particleLayers.isEmpty ? nil : particleLayers
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
        effectLayers = project.effectLayers ?? []
        particleLayers = project.particleLayers ?? []
        audioReactive = project.audioReactive.flatMap { s in
            AudioReactiveStyle(rawValue: s.style).map {
                AudioReactiveConfig(style: $0, strength: s.strength, sourceTrackID: s.sourceTrackID)
            }
        }
        framePreset = project.framePreset ?? FramePreset.none.rawValue
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
        toolSession = nil
        pendingToolOrigin = nil
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
                        speedRamp: stored.speedRamp ?? SpeedRamp.none.rawValue,
                        fadeIn: stored.fadeIn ?? 0, fadeOut: stored.fadeOut ?? 0,
                        fadeCurve: stored.fadeCurve.flatMap(FadeCurve.init) ?? .linear)
        }
        for i in clips.indices {
            guard let stored = project.clips.first(where: { $0.id == clips[i].id }) else { continue }
            clips[i].maskShape = stored.maskShape
            clips[i].maskEffect = stored.maskEffect ?? ClipMaskEffect.blur.rawValue
            clips[i].maskCenterX = stored.maskCenterX ?? 0.5
            clips[i].maskCenterY = stored.maskCenterY ?? 0.5
            clips[i].maskWidth = stored.maskWidth ?? 0.3
            clips[i].maskHeight = stored.maskHeight ?? 0.3
            clips[i].maskFeather = stored.maskFeather ?? 0.05
            clips[i].maskAmount = stored.maskAmount ?? 0.6
            clips[i].maskFillHex = stored.maskFillHex ?? "#000000"
            clips[i].maskInverted = stored.maskInverted ?? false
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
                              kind: stored.kind.flatMap(AudioLaneKind.init) ?? .music,
                              fadeIn: stored.fadeIn ?? 0, fadeOut: stored.fadeOut ?? 0,
                              fadeCurve: stored.fadeCurve.flatMap(FadeCurve.init) ?? .linear,
                              volumePoints: stored.volumePoints ?? [],
                              duckingEnabled: stored.duckingEnabled ?? false,
                              isLooping: stored.isLooping ?? false,
                              effects: stored.effects ?? AudioEffectSettings())
        }
        overlays = (project.overlays ?? []).compactMap { stored in
            let url = store.clipsFolder.appendingPathComponent(stored.fileName)
            // Text layers carry no media file; everything else must exist.
            // Synthetic layers (text F2, shapes F4) have no media on disk —
            // only file-backed overlays are dropped when their media is gone.
            guard stored.text != nil || stored.shapeKind != nil
                    || FileManager.default.fileExists(atPath: url.path) else { return nil }
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
            item.textFontName = stored.textFontName
            item.textStrokeHex = stored.textStrokeHex
            item.textStrokeWidth = stored.textStrokeWidth ?? 0
            item.textBoxHex = stored.textBoxHex
            item.textAlignment = stored.textAlignment ?? "center"
            item.textAnimation = stored.textAnimation ?? TextAnimation.none.rawValue
            item.shapeKind = stored.shapeKind
            item.shapeFillHex = stored.shapeFillHex
            item.shapeStrokeHex = stored.shapeStrokeHex
            item.shapeStrokeWidth = stored.shapeStrokeWidth ?? 0
            item.shapeRotation = stored.shapeRotation ?? 0
            item.lane = stored.lane ?? 0
            item.effects = stored.effects ?? OverlayEffects()
            item.kind = stored.kind
            item.loopsMedia = stored.loopsMedia ?? false
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
        overlaySourceExtents = [:]
        resetProjectDefaults()
        undoStack.removeAll()
        redoStack.removeAll()
        toolSession = nil
        pendingToolOrigin = nil
        updateHistoryFlags()
        rebuild(keepPosition: false)
    }

    /// Every project-owned field that is NOT media, restored to its declared
    /// default.
    ///
    /// `startNewProject()` used to clear only clips, audio, overlays and
    /// history — so a "new" project silently inherited the previous one's
    /// adjustment/effect/particle layers, audio-reactive config, canvas mode
    /// and colours, frame preset, zoom, format, and the whole volume/fade/mute
    /// mix. All of it is persisted per project by `saveProject()` and consumed
    /// by the next `rebuild()`, so the first clip you dropped into a blank
    /// project came out wearing the last project's grade and mix.
    ///
    /// `load(project:)` never had this bug — it assigns every one of these
    /// fields with a `?? default`, which is why only the new-project path was
    /// affected. This method is the same defaults in one place; the list must
    /// stay in step with what `saveProject()` serializes.
    private func resetProjectDefaults() {
        adjustmentLayers = []
        effectLayers = []
        particleLayers = []
        audioReactive = nil
        format = .widescreen
        zoom = 100
        canvasMode = .fill
        canvasSolidHex = "#101014"
        canvasGradientTopHex = "#2A2A38"
        canvasGradientBottomHex = "#050507"
        framePreset = FramePreset.none.rawValue
        volume = 100
        fadeIn = 0
        fadeOut = 0
        muteAudio = false
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
        pushUndoSnapshot()
        if performSplit(at: currentTime) { rebuild() }
    }

    /// Splits the clip containing `time` (timeline seconds) in place, without
    /// pushing undo or rebuilding — the caller batches those. Returns whether
    /// a split happened.
    @discardableResult
    private func performSplit(at time: Double) -> Bool {
        let starts = clipStartTimes
        guard let index = clips.firstIndex(where: { clip in
            guard let start = starts[clip.id] else { return false }
            return time > start + 0.15 && time < start + clip.timelineDuration - 0.15
        }) else { return false }

        let clip = clips[index]
        let localOffset = (time - (starts[clip.id] ?? 0)) * clip.speed
        let splitPoint = clip.trimStart + localOffset

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

        if !clip.isImage {
            Task { [id = second.id, url = clip.url] in
                let thumb = await Self.thumbnail(for: AVURLAsset(url: url), at: splitPoint + 0.02)
                if let i = self.clips.firstIndex(where: { $0.id == id }) {
                    self.clips[i].thumbnail = thumb
                }
            }
        }
        refreshFilmstrip(clipID: first.id)
        refreshFilmstrip(clipID: second.id)
        return true
    }

    /// True while beats are being detected.
    @Published private(set) var isDetectingBeats = false

    /// Runs beat detection on a lane and stores the markers (C6).
    func detectBeats(trackID: UUID) async {
        guard let track = audioTracks.first(where: { $0.id == trackID }) else { return }
        isDetectingBeats = true
        let analysis = await BeatDetector.analyze(url: track.renderedFileURL ?? track.url)
        isDetectingBeats = false
        guard let i = audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
        audioTracks[i].beatMarkers = analysis.beats
    }

    /// Auto-cuts the video at the lane's beats (detecting first if needed).
    /// One undo covers all splits; enforces a 0.4 s minimum gap.
    func autoCutToBeats(trackID: UUID) async {
        if audioTracks.first(where: { $0.id == trackID })?.beatMarkers.isEmpty ?? true {
            await detectBeats(trackID: trackID)
        }
        guard let track = audioTracks.first(where: { $0.id == trackID }) else { return }
        // Beat times are relative to the lane's media; shift to timeline coords.
        let beats = track.beatMarkers
            .map { $0 - track.trimStart + track.timelineOffset }
            .filter { $0 > 0.4 && $0 < totalDuration - 0.4 }
        guard !beats.isEmpty else { return }
        pushUndoSnapshot()
        var lastCut = -1.0
        for beat in beats.sorted() where beat - lastCut >= 0.4 {
            if performSplit(at: beat) { lastCut = beat }
        }
        rebuild()
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

    /// True while extracting a clip's audio into a lane.
    @Published private(set) var isDetaching = false

    /// Extracts the selected clip's audio into a new `.extracted` lane and
    /// mutes the clip — CapCut-style detach. One undo covers both mutations.
    func detachAudio(clipID: UUID) async {
        guard let clip = clips.first(where: { $0.id == clipID }),
              clip.hasAudio, !clip.isImage, !isDetaching else { return }
        isDetaching = true
        defer { isDetaching = false }
        let start = clipStartTimes[clipID] ?? 0
        let extracted = try? await AudioExtractor.extract(
            from: clip.url, trimStart: clip.trimStart, trimEnd: clip.trimEnd,
            speed: clip.speed, into: store.audioFolder)
        guard let extracted else { return }
        let asset = AVURLAsset(url: extracted)
        let duration = (try? await asset.load(.duration).seconds) ?? clip.timelineDuration
        guard let i = clips.firstIndex(where: { $0.id == clipID }) else { return }
        pushUndoSnapshot()
        let clipNumber = (clips.firstIndex(where: { $0.id == clipID }) ?? 0) + 1
        audioTracks.append(MusicTrack(id: UUID(), url: extracted,
                                      title: "Clip \(clipNumber) audio",
                                      assetDuration: duration,
                                      trimStart: 0, trimEnd: duration,
                                      timelineOffset: start, kind: .extracted))
        clips[i].isMuted = true
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
    /// Live mic input level 0…1 (B2), published at ~30 Hz while recording.
    @Published private(set) var inputLevel: Double = 0
    private var voiceoverRecorder: AVAudioRecorder?
    private var voiceoverStartOffset: Double = 0
    private var meterTask: Task<Void, Never>?

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
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            try? session.setCategory(.playback, mode: .moviePlayback)
            return
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? session.setCategory(.playback, mode: .moviePlayback)
            return
        }
        voiceoverRecorder = recorder
        voiceoverStartOffset = min(currentTime, max(0, totalDuration - 0.4))
        isRecordingVoiceover = true
        player?.isMuted = true
        if !isPlaying { togglePlayback() }
        // B2: 30 Hz input-level meter.
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let rec = self.voiceoverRecorder else { break }
                rec.updateMeters()
                let power = rec.averagePower(forChannel: 0)   // dBFS, −160…0
                self.inputLevel = Double(pow(10, power / 20))
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    func stopVoiceover() {
        guard isRecordingVoiceover, let recorder = voiceoverRecorder else { return }
        recorder.stop()
        voiceoverRecorder = nil
        isRecordingVoiceover = false
        meterTask?.cancel(); meterTask = nil
        inputLevel = 0
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
    /// How far `trimMusicHead` would move the in-point and the bar for this
    /// drag, so the lane can preview the trim live.
    func musicHeadTrim(id: UUID, deltaSeconds: Double) -> (trimShift: Double, offsetShift: Double) {
        guard let track = audioTracks.first(where: { $0.id == id }) else { return (0, 0) }
        let newStart = min(max(0, track.trimStart + deltaSeconds), track.trimEnd - 0.2)
        let applied = newStart - track.trimStart
        let newOffset = min(max(0, track.timelineOffset + applied), max(0, totalDuration - 0.2))
        return (applied, newOffset - track.timelineOffset)
    }

    func trimMusicHead(id: UUID, deltaSeconds: Double) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        let track = audioTracks[i]
        let shift = musicHeadTrim(id: id, deltaSeconds: deltaSeconds)
        guard abs(shift.trimShift) > 0.01 else { return }
        pushUndoSnapshot()
        audioTracks[i].trimStart = track.trimStart + shift.trimShift
        audioTracks[i].timelineOffset = track.timelineOffset + shift.offsetShift
        rebuild()
    }

    /// How far `trimMusicTail` would move the out-point for this drag.
    func musicTailTrim(id: UUID, deltaSeconds: Double) -> Double {
        guard let track = audioTracks.first(where: { $0.id == id }) else { return 0 }
        let newEnd = max(min(track.assetDuration, track.trimEnd + deltaSeconds),
                         track.trimStart + 0.2)
        return newEnd - track.trimEnd
    }

    func trimMusicTail(id: UUID, deltaSeconds: Double) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        let change = musicTailTrim(id: id, deltaSeconds: deltaSeconds)
        guard abs(change) > 0.01 else { return }
        pushUndoSnapshot()
        audioTracks[i].trimEnd = audioTracks[i].trimEnd + change
        rebuild()
    }

    /// Extracts RMS buckets from the audio files for the lane waveforms.
    func refreshAllWaveforms() {
        for track in audioTracks where track.waveform.isEmpty {
            let url = track.url
            let id = track.id
            Task.detached(priority: .utility) {
                let samples = await Self.waveformSamples(url: url)
                await MainActor.run { [weak self] in
                    guard let self,
                          let i = self.audioTracks.firstIndex(where: { $0.id == id }) else { return }
                    self.audioTracks[i].waveform = samples
                }
            }
        }
    }

    /// Async so the track and duration load the iOS 16 way; being
    /// nonisolated, the decode itself also runs off the main actor.
    nonisolated static func waveformSamples(url: URL, buckets: Int = 140) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let totalSeconds = try? await asset.load(.duration).seconds,
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
        state.conversionProfile = grade.conversionProfile.flatMap(LogProfile.init)
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

    /// Fade in/out (seconds) — mix-only, live, no rebuild (A3).
    func setMusicFade(id: UUID, fadeIn: Double? = nil, fadeOut: Double? = nil, curve: FadeCurve? = nil) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        let maxFade = audioTracks[i].timelineDuration
        if let fadeIn { audioTracks[i].fadeIn = min(max(0, fadeIn), maxFade) }
        if let fadeOut { audioTracks[i].fadeOut = min(max(0, fadeOut), maxFade) }
        if let curve { audioTracks[i].fadeCurve = curve }
        applyAudioSettings()
        scheduleAutosave()
    }

    /// Volume automation envelope (A4) — mix-only, live.
    func setMusicEnvelope(id: UUID, _ points: [AudioVolumePoint]) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        audioTracks[i].volumePoints = points
        applyAudioSettings()
        scheduleAutosave()
    }

    /// Auto-duck toggle (A5) — mix-only, live.
    func setMusicDucking(id: UUID, _ enabled: Bool) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        audioTracks[i].duckingEnabled = enabled
        applyAudioSettings()
        scheduleAutosave()
    }

    /// True while an audio effect bake is running.
    @Published private(set) var isRenderingEffects = false

    /// Applies the effect stack to a lane: bakes the source offline (B1) and
    /// swaps the composition to the rendered file. One undo covers the change.
    func applyTrackEffects(id: UUID, _ settings: AudioEffectSettings) async {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        audioTracks[i].effects = settings
        if settings.isNeutral {
            audioTracks[i].renderedFileURL = nil
            rebuild()
            return
        }
        isRenderingEffects = true
        let sourceURL = audioTracks[i].url
        let rendered = await Task.detached(priority: .userInitiated) {
            try? await AudioEffectsRenderer.shared.renderedURL(source: sourceURL, settings: settings)
        }.value
        isRenderingEffects = false
        guard let j = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        audioTracks[j].renderedFileURL = rendered
        rebuild()
    }

    /// Normalizes a lane to `targetLUFS` by measuring its loudness and setting
    /// the bake gain (C5).
    func normalizeTrack(id: UUID, targetLUFS: Double = -14) async {
        guard let track = audioTracks.first(where: { $0.id == id }) else { return }
        isRenderingEffects = true
        let measured = await LoudnessAnalyzer.integratedLUFS(url: track.url)
        isRenderingEffects = false
        guard let measured, measured > -70 else { return }
        var settings = track.effects
        settings.gainDB = min(20, max(-20, targetLUFS - measured))
        await applyTrackEffects(id: id, settings)
    }

    /// Loop-to-fill toggle (A6) — needs a rebuild (re-inserts audio).
    func setMusicLooping(id: UUID, _ looping: Bool) {
        guard let i = audioTracks.firstIndex(where: { $0.id == id }),
              audioTracks[i].isLooping != looping else { return }
        pushUndoSnapshot()
        audioTracks[i].isLooping = looping
        rebuild()
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

        // F0: land at the playhead and auto-stack onto the first free LANE
        // (captions + a sticker + a title can share a moment).
        let offset = min(max(0, currentTime), max(0, totalDuration - 0.4))
        guard offset < totalDuration - 0.2 else { return }
        let duration = min(mediaDuration, totalDuration - offset)
        guard duration > 0.2 else { return }
        let lane = firstFreeLane(at: offset, duration: duration)

        pushUndoSnapshot()
        var item = OverlayItem(id: UUID(), url: durableURL, isImage: isImage,
                               timelineOffset: offset, duration: duration,
                               title: url.deletingPathExtension().lastPathComponent)
        if !isImage { item.mediaDuration = mediaDuration }
        item.lane = lane
        overlays.append(item)
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
        refreshOverlayThumbnails()
    }

    /// F1: bakes an emoji to a transparent PNG and lands it as an image
    /// overlay — stickers ride the whole existing overlay machinery
    /// (placement, keyframes, opacity, blend, trim) for free.
    ///
    /// Bakes straight into `clipsFolder` so `addOverlay` adopts the file
    /// as-is and `cleanUpMedia` reference-counts it.
    @discardableResult
    func addSticker(emoji: String) async -> Bool {
        guard let url = StickerBaker.bakePNG(emoji: emoji, into: store.clipsFolder)
        else { return false }
        let before = overlays.count
        await addOverlay(from: url, isImage: true)
        guard overlays.count > before, let added = overlays.last(where: { $0.url == url })
        else { return false }
        markOverlay(id: added.id, kind: "sticker")
        // Lane label: the emoji itself, not the baked file's generated name.
        if let i = overlays.firstIndex(where: { $0.id == added.id }) {
            overlays[i].title = emoji
        }
        return true
    }

    /// Adds a TEXT layer (T6) on the overlay lane at the playhead. Rides the
    /// whole overlay machinery: placement, keyframes, opacity, trim.
    func addTextOverlay() {
        guard totalDuration > 0.4 else { return }
        // F0: land at the playhead, auto-stack onto the first free lane.
        let offset = min(max(0, currentTime), max(0, totalDuration - 0.4))
        guard offset < totalDuration - 0.2 else { return }
        let duration = min(3.0, totalDuration - offset)
        guard duration > 0.2 else { return }
        let lane = firstFreeLane(at: offset, duration: duration)

        pushUndoSnapshot()
        var item = OverlayItem(id: UUID(),
                               url: URL(fileURLWithPath: "/dev/null"),
                               isImage: true,
                               timelineOffset: offset, duration: duration,
                               title: "Text")
        item.text = "Your Title"
        item.sizeFraction = 0.6
        item.center = CGPoint(x: 0.5, y: 0.5)
        item.lane = lane
        overlays.append(item)
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
    }

    /// F8 — sets (or clears, with shape nil) the clip's spot tool.
    func setClipMask(id: UUID,
                     shape: ClipMaskShape?,
                     effect: ClipMaskEffect? = nil,
                     center: CGPoint? = nil,
                     size: CGSize? = nil,
                     feather: Double? = nil,
                     amount: Double? = nil,
                     inverted: Bool? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        clips[i].maskShape = shape?.rawValue
        if let effect { clips[i].maskEffect = effect.rawValue }
        if let center { clips[i].maskCenterX = center.x; clips[i].maskCenterY = center.y }
        if let size { clips[i].maskWidth = size.width; clips[i].maskHeight = size.height }
        if let feather { clips[i].maskFeather = feather }
        if let amount { clips[i].maskAmount = amount }
        if let inverted { clips[i].maskInverted = inverted }
        rebuild()
    }

    /// F7 — drops a particle layer at the playhead.
    @discardableResult
    func addParticleLayer(kind: ParticleKind, duration: Double = 3.0) -> UUID? {
        guard totalDuration > 0.2 else { return nil }
        let offset = min(max(0, currentTime), max(0, totalDuration - 0.2))
        let span = min(duration, totalDuration - offset)
        guard span > 0.1 else { return nil }
        pushUndoSnapshot()
        let layer = ParticleLayer(timelineOffset: offset, duration: span, kind: kind.rawValue)
        particleLayers.append(layer)
        particleLayers.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
        return layer.id
    }

    func setParticleIntensity(id: UUID, _ value: Double) {
        guard let i = particleLayers.firstIndex(where: { $0.id == id }),
              particleLayers[i].intensity != value else { return }
        pushUndoSnapshot()
        particleLayers[i].intensity = min(max(value, 0), 1)
        rebuild()
    }

    func removeParticleLayer(id: UUID) {
        guard particleLayers.contains(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        particleLayers.removeAll { $0.id == id }
        rebuild()
    }

    /// F6 — drops an effect layer at the playhead.
    @discardableResult
    func addEffectLayer(kind: EffectKind, duration: Double = 2.0) -> UUID? {
        guard totalDuration > 0.2 else { return nil }
        let offset = min(max(0, currentTime), max(0, totalDuration - 0.2))
        let span = min(duration, totalDuration - offset)
        guard span > 0.1 else { return nil }
        pushUndoSnapshot()
        let layer = EffectLayer(timelineOffset: offset, duration: span, kind: kind.rawValue)
        effectLayers.append(layer)
        effectLayers.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
        return layer.id
    }

    func setEffectIntensity(id: UUID, _ value: Double) {
        guard let i = effectLayers.firstIndex(where: { $0.id == id }),
              effectLayers[i].intensity != value else { return }
        pushUndoSnapshot()
        effectLayers[i].intensity = min(max(value, 0), 1)
        rebuild()
    }

    func setEffectSpan(id: UUID, offset: Double, duration: Double) {
        guard let i = effectLayers.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        effectLayers[i].timelineOffset = max(0, offset)
        effectLayers[i].duration = max(0.1, duration)
        effectLayers.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
    }

    func removeEffectLayer(id: UUID) {
        guard effectLayers.contains(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        effectLayers.removeAll { $0.id == id }
        rebuild()
    }

    /// F11 — applies a trending template to the timeline.
    ///
    /// Slots map onto the clips in order and CYCLE if the template has fewer
    /// slots than clips, so a 6-slot template still shapes an 11-clip edit.
    /// One undo entry and one rebuild for the whole thing: a template is a
    /// single creative act, not twenty separate ones.
    ///
    /// Trimming is non-destructive — a slot shortens the clip's OUT point but
    /// never lengthens it past the media it actually has.
    @discardableResult
    func applyTemplate(_ template: VideoTemplate) -> Bool {
        guard !clips.isEmpty, !template.slots.isEmpty else { return false }
        pushUndoSnapshot()

        // Canvas first: aspect + background frame the whole edit.
        if let fmt = EditorFormat(rawValue: template.aspect) { format = fmt }
        if let mode = template.canvasMode.flatMap(CanvasBackgroundMode.init) { canvasMode = mode }

        for (i, clip) in clips.enumerated() {
            let slot = template.slots[i % template.slots.count]

            if let speed = slot.speed, speed > 0.05 { clips[i].speed = speed }

            // Fit the slot: honour the requested on-screen duration, but only
            // as far as the source media allows (speed scales the timeline).
            let wanted = slot.duration * clips[i].speed
            let available = clip.assetDuration - clips[i].trimStart
            if wanted > 0.05, available > 0.05 {
                clips[i].trimEnd = clips[i].trimStart + min(wanted, available)
            }

            if let raw = slot.transitionAfter, let style = TransitionStyle(rawValue: raw) {
                clips[i].transitionAfter = style
                clips[i].transitionDuration = slot.transitionDuration
            }
            if let kb = slot.kenBurns, let preset = KenBurnsPreset(rawValue: kb) {
                clips[i].transformKeyframes =
                    preset.keyframes(duration: clips[i].timelineDuration)
            }
        }

        if let style = template.audioReactive.flatMap(AudioReactiveStyle.init) {
            audioReactive = AudioReactiveConfig(style: style, strength: 0.6,
                                                sourceTrackID: audioTracks.first?.id)
        }

        syncClipTransformLayout()
        rebuild()
        return true
    }

    /// F10 — turns transcript segments into caption text layers.
    ///
    /// Split from `generateCaptions` deliberately: this half is a pure
    /// timeline mutation with no speech dependency, so it is testable without
    /// microphone/speech authorisation.
    @discardableResult
    func addCaptions(_ segments: [CaptionSegment]) -> Int {
        let usable = segments.filter { $0.duration > 0.05 && $0.start < totalDuration }
        guard !usable.isEmpty else { return 0 }
        pushUndoSnapshot()
        for seg in usable {
            let offset = min(max(0, seg.start), max(0, totalDuration - 0.1))
            let duration = min(seg.duration, totalDuration - offset)
            guard duration > 0.05 else { continue }
            var item = OverlayItem(id: UUID(), url: URL(fileURLWithPath: "/dev/null"),
                                   isImage: true, timelineOffset: offset,
                                   duration: duration, title: "Caption")
            item.text = seg.text
            item.textStyle = .subtitle
            // Captions read against any footage: white on a black box, low.
            item.textBoxHex = "#000000"
            item.textColorHex = "#FFFFFF"
            item.center = CGPoint(x: 0.5, y: 0.82)
            item.sizeFraction = 0.8
            item.kind = "caption"
            item.lane = firstFreeLane(at: offset, duration: duration)
            overlays.append(item)
        }
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
        return usable.count
    }

    /// F10 — transcribes the timeline's audio and lays the captions in.
    /// Returns the number of caption layers added (0 = unauthorised/no speech).
    @discardableResult
    func generateCaptions(locale: Locale = .current) async -> Int {
        guard totalDuration > 0.2 else { return 0 }
        guard await CaptionEngine.requestAuthorization() else { return 0 }
        do {
            let built = try await buildComposition(renderScale: 1)
            let audioURL = try await VideoExporter().exportAudioOnly(asset: built.composition,
                                                                     audioMix: built.audioMix)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let segments = try await CaptionEngine.transcribe(url: audioURL, locale: locale)
            return addCaptions(segments)
        } catch {
            return 0
        }
    }

    /// F10 — SRT for the caption layers currently on the timeline.
    func captionsSRT() -> String {
        let segs = overlays
            .filter { $0.kind == "caption" && $0.text != nil }
            .sorted { $0.timelineOffset < $1.timelineOffset }
            .map { CaptionSegment(text: $0.text ?? "", start: $0.timelineOffset, duration: $0.duration) }
        return CaptionEngine.srt(from: segs)
    }

    /// F3 — sets the animated-text preset (with undo).
    func setTextAnimation(id: UUID, _ preset: TextAnimation) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              overlays[i].text != nil, overlays[i].textAnimation != preset.rawValue else { return }
        pushUndoSnapshot()
        overlays[i].textAnimation = preset.rawValue
        rebuild()
    }

    /// F4 — adds a vector shape layer at the playhead. Shapes ride the same
    /// synthetic path as text: rendered live by the compositor (so fill and
    /// stroke stay editable), ungraded, on the first free lane.
    @discardableResult
    func addShapeOverlay(kind: ShapeKind) -> UUID? {
        guard totalDuration > 0.4 else { return nil }
        let offset = min(max(0, currentTime), max(0, totalDuration - 0.4))
        guard offset < totalDuration - 0.2 else { return nil }
        let duration = min(Self.photoDefaultDuration, totalDuration - offset)
        guard duration > 0.2 else { return nil }
        let lane = firstFreeLane(at: offset, duration: duration)

        pushUndoSnapshot()
        var item = OverlayItem(id: UUID(), url: URL(fileURLWithPath: "/dev/null"),
                               isImage: true, timelineOffset: offset,
                               duration: duration, title: kind.label)
        item.shapeKind = kind.rawValue
        item.center = CGPoint(x: 0.5, y: 0.5)
        item.sizeFraction = 0.35
        item.lane = lane
        item.kind = "shape"
        overlays.append(item)
        overlays.sort { $0.timelineOffset < $1.timelineOffset }
        rebuild()
        return item.id
    }

    /// F4 — shape fill / stroke / rotation edits.
    func setShapeDecor(id: UUID,
                       fillHex: String?? = nil,
                       strokeHex: String?? = nil,
                       strokeWidth: Double? = nil,
                       rotation: Double? = nil) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              overlays[i].shapeKind != nil else { return }
        pushUndoSnapshot()
        if let fillHex { overlays[i].shapeFillHex = fillHex }
        if let strokeHex { overlays[i].shapeStrokeHex = strokeHex }
        if let strokeWidth { overlays[i].shapeStrokeWidth = strokeWidth }
        if let rotation { overlays[i].shapeRotation = rotation }
        rebuild()
    }

    /// F2 — text decoration: font / stroke / box / alignment. One setter so
    /// the panel's five controls share a single undo entry shape; every field
    /// is optional, nil meaning "leave it alone".
    func setTextDecor(id: UUID,
                      fontName: String?? = nil,
                      strokeHex: String?? = nil,
                      strokeWidth: Double? = nil,
                      boxHex: String?? = nil,
                      alignment: String? = nil) {
        guard let i = overlays.firstIndex(where: { $0.id == id }),
              overlays[i].text != nil else { return }
        pushUndoSnapshot()
        if let fontName { overlays[i].textFontName = fontName }
        if let strokeHex { overlays[i].textStrokeHex = strokeHex }
        if let strokeWidth { overlays[i].textStrokeWidth = strokeWidth }
        if let boxHex { overlays[i].textBoxHex = boxHex }
        if let alignment { overlays[i].textAlignment = alignment }
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
    /// The shift `trimOverlayHead` would apply for this drag, so the bar can
    /// preview exactly where its edge will land before anything commits.
    func overlayHeadTrim(id: UUID, deltaSeconds: Double) -> Double {
        guard let item = overlays.first(where: { $0.id == id }) else { return 0 }
        var applied = min(deltaSeconds, item.duration - 0.2)
        if !item.isImage && item.text == nil {
            applied = max(applied, -item.mediaStart)   // no material before 0
        }
        return max(applied, -item.timelineOffset)      // can't start before 0
    }

    func trimOverlayHead(id: UUID, deltaSeconds: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let item = overlays[i]
        let applied = overlayHeadTrim(id: id, deltaSeconds: deltaSeconds)
        guard abs(applied) > 0.01 else { return }
        pushUndoSnapshot()
        if !item.isImage && item.text == nil {
            overlays[i].mediaStart = item.mediaStart + applied
        }
        overlays[i].timelineOffset = item.timelineOffset + applied
        overlays[i].duration = item.duration - applied
        rebuild()
    }

    /// The change in length `trimOverlayTail` would apply for this drag.
    func overlayTailTrim(id: UUID, deltaSeconds: Double) -> Double {
        guard let item = overlays.first(where: { $0.id == id }) else { return 0 }
        var maxDuration = max(0.2, totalDuration - item.timelineOffset)
        if !item.isImage && item.text == nil {
            maxDuration = min(maxDuration, item.mediaDuration - item.mediaStart)
        }
        if let next = overlays
            .filter({ $0.id != id && $0.timelineOffset > item.timelineOffset + 0.05 })
            .min(by: { $0.timelineOffset < $1.timelineOffset }) {
            maxDuration = min(maxDuration, next.timelineOffset - item.timelineOffset)
        }
        return min(max(0.2, item.duration + deltaSeconds), maxDuration) - item.duration
    }

    func trimOverlayTail(id: UUID, deltaSeconds: Double) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let change = overlayTailTrim(id: id, deltaSeconds: deltaSeconds)
        guard abs(change) > 0.01 else { return }
        pushUndoSnapshot()
        overlays[i].duration = overlays[i].duration + change
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

    /// Atomic direct-manipulation update. A keyframe stores the whole
    /// placement, so drag/pinch/rotate must write the interpolated opacity and
    /// untouched transform components together; calling the three scalar
    /// setters independently would make a drag snap size/rotation back to the
    /// overlay's base fields and would seek the paused player three times.
    func setOverlayTransform(id: UUID, _ placement: OverlayLayout.Placement) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].center = CGPoint(x: min(max(0, placement.center.x), 1),
                                     y: min(max(0, placement.center.y), 1))
        overlays[i].sizeFraction = min(max(0.25, placement.sizeFraction), 1)
        overlays[i].rotationDegrees = min(max(-180, placement.rotationDegrees), 180)
        overlays[i].opacity = min(max(0, placement.opacity), 1)
        overlayKeyframeAutoUpsert(index: i)
        syncOverlayLayout(refreshFrame: true)
        scheduleAutosave()
    }

    /// ONE undo entry for a whole direct-manipulation gesture on the preview.
    ///
    /// Dragging, pinching and twisting a layer write through the atomic setter,
    /// which deliberately do NOT snapshot — they run per frame and would bury
    /// the undo stack. `before` is the overlay as it stood when the finger went
    /// down: it is put back just long enough for the snapshot to capture it,
    /// then the gesture's result is restored. Both writes land in the same
    /// runloop turn, so nothing renders in between.
    func commitOverlayGesture(id: UUID, before: OverlayItem) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        let after = overlays[i]
        guard after.center != before.center
                || after.sizeFraction != before.sizeFraction
                || after.rotationDegrees != before.rotationDegrees
                || after.keyframes != before.keyframes else { return }
        overlays[i] = before
        pushUndoSnapshot()
        overlays[i] = after
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

    /// Lowest lane with no overlay overlapping [offset, offset+duration] — new
    /// items auto-stack instead of being refused.
    func firstFreeLane(at offset: Double, duration: Double) -> Int {
        let end = offset + duration
        var lane = 0
        while overlays.contains(where: { $0.lane == lane
            && $0.timelineOffset < end - 0.01 && $0.timelineEnd > offset + 0.01 }) {
            lane += 1
            if lane > 8 { break }
        }
        return lane
    }

    /// Tags an overlay's content kind (sticker/shape/caption) — no rebuild.
    func markOverlay(id: UUID, kind: String?) {
        guard let i = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[i].kind = kind
        scheduleAutosave()
    }

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

        /// The pan/zoom keyframes for a clip of `duration`. Lives on the preset
        /// so the panel (setKenBurns) and templates (applyTemplate) can never
        /// drift apart.
        func keyframes(duration dur: Double,
                       easing: KeyframeEasing = .easeInOut) -> [ClipTransformKeyframe] {
            let z = 1.3
            let lo = 0.28, hi = 0.72   // pan extremes (keep the window in-frame)
            let c = 0.5
            func kf(_ t: Double, _ zoom: Double, _ x: Double, _ y: Double) -> ClipTransformKeyframe {
                ClipTransformKeyframe(time: t, zoom: zoom, centerX: x, centerY: y,
                                      easing: t == 0 ? easing.rawValue : nil)
            }
            switch self {
            case .none:     return []
            case .zoomIn:   return [kf(0, 1, c, c), kf(dur, z, c, c)]
            case .zoomOut:  return [kf(0, z, c, c), kf(dur, 1.001, c, c)]
            case .panLeft:  return [kf(0, z, hi, c), kf(dur, z, lo, c)]
            case .panRight: return [kf(0, z, lo, c), kf(dur, z, hi, c)]
            case .panUp:    return [kf(0, z, c, hi), kf(dur, z, c, lo)]
            case .panDown:  return [kf(0, z, c, lo), kf(dur, z, c, hi)]
            }
        }

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
        clips[i].transformKeyframes = preset.keyframes(duration: clips[i].timelineDuration,
                                                       easing: easing)
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
                 effectLayers: effectLayers,
                 particleLayers: particleLayers,
                 canvasMode: canvasMode, canvasSolidHex: canvasSolidHex,
                 canvasGradientTopHex: canvasGradientTopHex,
                 canvasGradientBottomHex: canvasGradientBottomHex,
                 framePreset: framePreset,
                 audioReactive: audioReactive)
    }

    /// How many steps Undo remembers. Every snapshot carries each clip's
    /// thumbnail and filmstrip, so an unbounded history grew with every edit
    /// until iOS killed a long session. Forty steps is well past what anyone
    /// walks back through, and the images are shared, not copied, so the cap
    /// is what bounds the memory.
    private static let undoLimit = 40

    private func pushUndoSnapshot() {
        undoStack.append(currentSnapshot())
        trimUndoHistory()
        redoStack.removeAll()
        mutationCount &+= 1
        updateHistoryFlags()
    }

    /// Drops the oldest steps past `undoLimit`. An open tool session's
    /// recorded depth moves with them, so ✕ still trims exactly the entries
    /// the tool pushed.
    private func trimUndoHistory() {
        let overflow = undoStack.count - Self.undoLimit
        guard overflow > 0 else { return }
        undoStack.removeFirst(overflow)
        if let session = toolSession {
            toolSession = ToolSession(start: session.start,
                                      undoDepth: max(0, session.undoDepth - overflow),
                                      mutationMark: session.mutationMark)
        }
        if let origin = pendingToolOrigin {
            pendingToolOrigin = ToolSession(start: origin.start,
                                            undoDepth: max(0, origin.undoDepth - overflow),
                                            mutationMark: origin.mutationMark)
        }
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        trimUndoHistory()
        restore(snapshot)
    }

    // MARK: - Tool sessions (✕ means "put it back")

    /// The project as it stood when an editor tool opened. Most tools commit
    /// live (sliders write straight to the model so the frame updates), which
    /// made ✕ identical to ✓. Snapshotting on open and restoring on ✕ makes
    /// Cancel honest for every tool at once, whatever mutations it made.
    private struct ToolSession {
        let start: Snapshot
        let undoDepth: Int
        let mutationMark: Int
    }
    private var toolSession: ToolSession?
    /// Captured just before an "add, then open its tool" action (Text, a
    /// sticker, overlay media), so ✕ takes away the thing that was added,
    /// not only the edits made to it afterwards.
    private var pendingToolOrigin: ToolSession?
    /// Bumped by every undoable push and every autosave-worthy change, so
    /// ✕ on a tool that changed nothing skips the restore and its rebuild.
    private var mutationCount = 0

    /// Call immediately before an action that adds an element and then opens
    /// its tool. Used only if exactly one undo step lands before the tool
    /// opens (the add itself); anything else falls back to a fresh snapshot.
    func prepareToolSessionForAdd() {
        pendingToolOrigin = ToolSession(start: currentSnapshot(),
                                        undoDepth: undoStack.count,
                                        mutationMark: mutationCount)
    }

    func beginToolSession() {
        defer { pendingToolOrigin = nil }
        if let origin = pendingToolOrigin, undoStack.count == origin.undoDepth + 1 {
            toolSession = origin
        } else {
            toolSession = ToolSession(start: currentSnapshot(),
                                      undoDepth: undoStack.count,
                                      mutationMark: mutationCount)
        }
    }

    /// ✓, or the tool closing itself: keep everything, history as made.
    func commitToolSession() {
        toolSession = nil
    }

    /// ✕: put the project back exactly as the tool found it. The steps the
    /// tool pushed leave Undo (so Undo cannot replay a cancelled change), and
    /// the cancelled state waits on Redo, so a mistaken ✕ is one tap from
    /// coming back.
    func cancelToolSession() {
        guard let session = toolSession else { return }
        toolSession = nil
        guard mutationCount != session.mutationMark else { return }
        let cancelled = currentSnapshot()
        if undoStack.count > session.undoDepth {
            undoStack.removeSubrange(session.undoDepth...)
        }
        redoStack = [cancelled]
        restore(session.start)
    }

    /// Re-renders the paused frame. A paused AVPlayer never re-runs the
    /// compositor on its own, so changes the composition reads live (the
    /// shared timeline grade) need a nudge to show.
    func refreshPausedFrame() {
        guard let player, player.timeControlStatus != .playing else { return }
        let time = player.currentTime()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func restore(_ snapshot: Snapshot) {
        clips = snapshot.clips
        format = snapshot.format
        zoom = snapshot.zoom
        audioReactive = snapshot.audioReactive
        audioTracks = snapshot.audioTracks
        overlays = snapshot.overlays
        adjustmentLayers = snapshot.adjustmentLayers
        effectLayers = snapshot.effectLayers
        particleLayers = snapshot.particleLayers
        canvasMode = snapshot.canvasMode
        canvasSolidHex = snapshot.canvasSolidHex
        canvasGradientTopHex = snapshot.canvasGradientTopHex
        canvasGradientBottomHex = snapshot.canvasGradientBottomHex
        framePreset = snapshot.framePreset
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

    /// `precise: false` is for CONTINUOUS scrubbing. A zero-tolerance seek
    /// forces the decoder to land on an exact frame, which means decoding from
    /// the nearest keyframe every time — and the timeline scrubber fires this
    /// on every scroll tick, ~60 times a second. Those requests queue and the
    /// drag visibly stutters, which is most of what "the editor doesn't feel
    /// solid" actually is. A half-frame tolerance lets AVFoundation serve the
    /// nearest decoded frame instead, and `finalizeScrub()` lands the exact
    /// frame once the finger lifts (TimelineV2's own `finalizeScrub`, which
    /// already existed), so nothing is lost but the jank.
    func seek(to seconds: Double, precise: Bool = true) {
        let clamped = min(max(0, seconds), totalDuration)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        if precise {
            player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let slack = CMTime(seconds: frameDuration / 2, preferredTimescale: 600)
            player?.seek(to: time, toleranceBefore: slack, toleranceAfter: slack)
        }
        currentTime = clamped
    }


    /// The project frame rate, published by each rebuild from the first video
    /// clip (photo-only projects stay at 30). Drives the preview composition,
    /// the frame-nudge transport and the MM:SS:FF timecode readout.
    @Published private(set) var frameRate: Double = 30

    /// One frame at the project rate, in seconds.
    var frameDuration: Double { 1.0 / frameRate }

    /// Snaps a track's nominal rate to the standard rate it was shot at
    /// (23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60). Capped at 60: a
    /// 240 fps slow-motion clip should not turn the preview into a 240 fps
    /// composition. Missing or nonsense rates fall back to 30.
    static func standardFrameRate(_ nominal: Float) -> Double {
        let rate = Double(nominal)
        guard rate.isFinite, rate >= 1 else { return 30 }
        let standards: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30,
                                   48, 50, 60000.0 / 1001, 60]
        if rate > 60.5 { return 60 }
        if let match = standards.min(by: { abs($0 - rate) < abs($1 - rate) }),
           abs(match - rate) < 0.6 {
            return match
        }
        return min(60, max(1, rate.rounded()))
    }

    /// Exact frame duration for a rate, using the 1001 timescales for the
    /// NTSC rates so 23.976 / 29.97 / 59.94 never drift.
    static func frameDurationTime(for rate: Double) -> CMTime {
        for base in [24.0, 30.0, 60.0] where abs(rate - base * 1000 / 1001) < 0.001 {
            return CMTime(value: 1001, timescale: CMTimeScale(base * 1000))
        }
        return CMTime(value: 1, timescale: CMTimeScale(max(1, rate.rounded())))
    }

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

        let outcome = try? await buildComposition()
        // A rebuild superseded by a newer one must NOT publish: `buildComposition`
        // does not observe cancellation, so a slow build that finished after the
        // rebuild that replaced it used to overwrite the fresh state — leaving a
        // live `player` and a non-zero `totalDuration` beside empty `clips`. That
        // contradictory state is what stranded a loaded project behind the empty
        // timeline placeholder with Export disabled. The newer task owns the
        // state; leave it alone.
        if Task.isCancelled { return }
        // `clips` is the source of truth: a composition can only be valid while
        // clips exist, so reconcile unconditionally rather than trusting a build
        // that may have raced a mutation.
        guard let built = outcome, !clips.isEmpty else {
            player?.pause()
            player = nil
            totalDuration = 0
            currentTime = 0
            isPlaying = false
            lastBuiltTracks = (nil, [], [])
            overlaySourceExtents = [:]
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
        overlaySourceExtents = built.overlaySourceExtents
        if frameRate != built.frameRate { frameRate = built.frameRate }

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
        /// Taken from the first video clip, the usual NLE convention, so 24 fps
        /// footage previews, steps and reads its timecode at 24, not 30.
        var projectRate: Double?

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
                                       clipID: clip.id,
                                       mask: clip.maskSpec))
                cursor = cursor + stillDuration
                continue
            }

            let asset = AVURLAsset(url: clip.url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first
            let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            if projectRate == nil, let nominal = try? await sourceVideo.load(.nominalFrameRate) {
                projectRate = Self.standardFrameRate(nominal)
            }

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
                                   clipID: clip.id,
                                   mask: clip.maskSpec))
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
            let musicAsset = AVURLAsset(url: music.renderedFileURL ?? music.url)
            if let sourceAudio = try? await musicAsset.loadTracks(withMediaType: .audio).first,
               let track = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
                // Loop-to-fill (A6): repeat the trimmed clip from its offset up
                // to the video end; otherwise a single hard-clipped copy.
                let loopLen = music.timelineDuration
                var at = music.timelineOffset
                var insertedAny = false
                repeat {
                    let playable = min(loopLen, cursor.seconds - at)
                    guard playable > 0.05 else { break }
                    let range = CMTimeRange(
                        start: CMTime(seconds: music.trimStart, preferredTimescale: 600),
                        duration: CMTime(seconds: playable, preferredTimescale: 600))
                    do {
                        try track.insertTimeRange(range, of: sourceAudio,
                                                  at: CMTime(seconds: at, preferredTimescale: 600))
                        insertedAny = true
                    } catch { break }
                    at += loopLen
                } while music.isLooping && at < cursor.seconds - 0.05
                if insertedAny {
                    musicTracks.append((music.id, track))
                } else {
                    composition.removeTrack(track)   // never leave an empty track behind
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
            // A looping overlay repeats its media, so the media length never
            // caps its on-screen duration (particles / GIF loops).
            if !overlay.isImage, overlay.text == nil, !overlay.loopsMedia {
                playable = min(playable, max(0, overlay.mediaDuration - overlay.mediaStart))
            }
            guard playable > 0.05 else { continue }

            if let shape = overlay.shapeSpec {
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: kCMPersistentTrackID_Invalid,
                                                imageURL: nil,
                                                transform: .identity,
                                                sourceExtent: OverlayRenderGeometry.shapeSourceExtent,
                                                start: start, end: start + playable,
                                                shape: shape,
                                                lane: overlay.lane))
                continue
            }
            if let text = overlay.text {
                guard let raster = TextRasterizer.image(text, style: overlay.textSpec),
                      let extent = OverlayRenderGeometry.sourceExtent(raster.extent) else { continue }
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: kCMPersistentTrackID_Invalid,
                                                imageURL: nil,
                                                transform: .identity,
                                                sourceExtent: extent,
                                                start: start, end: start + playable,
                                                text: text,
                                                textSpec: overlay.textSpec,
                                                textAnimation: overlay.textAnimation,
                                                lane: overlay.lane))
                continue
            }
            if overlay.isImage {
                guard let raster = CIImage(contentsOf: overlay.url,
                                           options: [.applyOrientationProperty: true]),
                      let extent = OverlayRenderGeometry.sourceExtent(raster.extent) else { continue }
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: kCMPersistentTrackID_Invalid,
                                                imageURL: overlay.url,
                                                transform: .identity,
                                                sourceExtent: extent,
                                                start: start, end: start + playable,
                                                lane: overlay.lane))
                continue
            }

            let overlayAsset = AVURLAsset(url: overlay.url)
            guard let sourceVideo = try? await overlayAsset.loadTracks(withMediaType: .video).first
            else { continue }
            let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? .zero
            guard let sourceExtent = OverlayRenderGeometry.sourceExtent(
                CGRect(origin: .zero, size: naturalSize), applying: transform) else { continue }
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
            // Looping overlays repeat their media to fill `playable`; the last
            // insert is truncated. Non-looping insert once (F0).
            let mediaLen = overlay.loopsMedia
                ? max(0.05, min(overlay.mediaDuration - overlay.mediaStart,
                                (try? await overlayAsset.load(.duration).seconds) ?? playable))
                : playable
            do {
                var filled = 0.0
                var insertAt = at
                repeat {
                    let chunk = min(mediaLen, playable - filled)
                    guard chunk > 0.02 else { break }
                    let range = CMTimeRange(
                        start: CMTime(seconds: overlay.mediaStart, preferredTimescale: 600),
                        duration: CMTime(seconds: chunk, preferredTimescale: 600))
                    try track.insertTimeRange(range, of: sourceVideo, at: insertAt)
                    filled += chunk
                    insertAt = insertAt + range.duration
                } while overlay.loopsMedia && filled < playable - 0.02
                overlayLaneTracks[overlay.lane] = (track, insertAt)
                overlaySpecs.append(OverlaySpec(id: overlay.id,
                                                trackID: track.trackID,
                                                imageURL: nil,
                                                transform: transform,
                                                sourceExtent: sourceExtent,
                                                start: start, end: start + playable,
                                                lane: overlay.lane))
                // Overlay AUDIO rides its own lazy track (was silently
                // dropped in v1). Same rule as everywhere: never leave an
                // empty audio track behind — export dies on it.
                if let sourceAudio = try? await overlayAsset.loadTracks(withMediaType: .audio).first,
                   let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
                    // Mirror the (possibly looped) video fill for the audio.
                    do {
                        var aFilled = 0.0
                        var aAt = at
                        repeat {
                            let chunk = min(mediaLen, playable - aFilled)
                            guard chunk > 0.02 else { break }
                            let aRange = CMTimeRange(
                                start: CMTime(seconds: overlay.mediaStart, preferredTimescale: 600),
                                duration: CMTime(seconds: chunk, preferredTimescale: 600))
                            try audioTrack.insertTimeRange(aRange, of: sourceAudio, at: aAt)
                            aFilled += chunk
                            aAt = aAt + aRange.duration
                        } while overlay.loopsMedia && aFilled < playable - 0.02
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
        videoComposition.frameDuration = Self.frameDurationTime(for: projectRate ?? 30)
        let adjustmentSpans = adjustmentLayers
            .filter { $0.duration > 0.05 && $0.timelineOffset < cursor.seconds }
            .map { AdjustmentSpan(start: max(0, $0.timelineOffset),
                                  end: min($0.timelineEnd, cursor.seconds),
                                  state: makeLookState(from: $0.grade)) }

        let effectSpans = effectLayers
            .filter { $0.duration > 0.05 && $0.timelineOffset < cursor.seconds }
            .compactMap { layer -> EffectSpan? in
                guard let kind = EffectKind(rawValue: layer.kind) else { return nil }
                return EffectSpan(start: max(0, layer.timelineOffset),
                                  end: min(layer.timelineEnd, cursor.seconds),
                                  kind: kind, intensity: layer.intensity)
            }

        let particleSpans = particleLayers
            .filter { $0.duration > 0.05 && $0.timelineOffset < cursor.seconds }
            .compactMap { layer -> ParticleSpan? in
                guard let kind = ParticleKind(rawValue: layer.kind) else { return nil }
                return ParticleSpan(start: max(0, layer.timelineOffset),
                                    end: min(layer.timelineEnd, cursor.seconds),
                                    kind: kind, intensity: layer.intensity)
            }

        // Audio-reactive level envelope (D1): 30 Hz loudness of the source lane.
        var reactiveSpec: AudioReactiveSpec?
        if let cfg = audioReactive,
           let src = audioTracks.first(where: { $0.id == cfg.sourceTrackID }) ?? audioTracks.first {
            let frames = max(1, Int(cursor.seconds * 30) + 1)
            var levels = [Float](repeating: 0, count: frames)
            let srcBuckets = await Self.waveformSamples(url: src.renderedFileURL ?? src.url,
                                                  buckets: max(2, Int(src.timelineDuration * 30)))
            let maxV = srcBuckets.max() ?? 1
            let startFrame = Int(src.timelineOffset * 30)
            for (i, v) in srcBuckets.enumerated() {
                let f = startFrame + i
                if f >= 0, f < frames { levels[f] = maxV > 0 ? v / maxV : 0 }
            }
            reactiveSpec = AudioReactiveSpec(style: cfg.style, strength: cfg.strength,
                                             levels: levels, sampleRate: 30)
        }
        videoComposition.instructions = makeInstructions(
            totalDuration: cursor,
            mainTrackID: videoTrack.trackID,
            frameMetas: metas,
            transitionSpans: spans,
            overlaySpecs: overlaySpecs,
            adjustmentSpans: adjustmentSpans,
            effectSpans: effectSpans,
            particleSpans: particleSpans,
            audioReactive: reactiveSpec,
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
                             overlaySourceExtents: Dictionary(uniqueKeysWithValues:
                                overlaySpecs.map { ($0.id, $0.sourceExtent) }),
                             duration: duration,
                             frameRate: projectRate ?? 30)
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
                                  effectSpans: [EffectSpan] = [],
                                  particleSpans: [ParticleSpan] = [],
                                  audioReactive: AudioReactiveSpec? = nil,
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
                },
                effects: effectSpans.filter {
                    mid >= $0.start - 0.001 && mid < $0.end + 0.001
                },
                particles: particleSpans.filter {
                    mid >= $0.start - 0.001 && mid < $0.end + 0.001
                },
                audioReactive: audioReactive,
                framePreset: framePreset))
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

        // Voice-lane spans (A5): music tracks that opt into ducking dip under
        // these. Computed once, live.
        let voiceSpans: [ClosedRange<Double>] = audioTracks
            .filter { $0.kind == .voice && !$0.isMuted && $0.timelineDuration > 0.05 }
            .map { $0.timelineOffset...($0.timelineOffset + $0.timelineDuration) }

        for entry in musicTracks {
            guard let music = audioTracks.first(where: { $0.id == entry.id }) else { continue }
            let parameters = AVMutableAudioMixInputParameters(track: entry.track)
            let base = Float(music.isMuted ? 0 : music.volume / 100.0)
            let laneLen = music.isLooping ? (duration - music.timelineOffset) : music.timelineDuration
            let end = min(music.timelineOffset + laneLen, duration)
            applyVolumeAutomation(parameters, base: base,
                                  span: music.timelineOffset...max(music.timelineOffset + 0.05, end),
                                  fadeIn: music.fadeIn, fadeOut: music.fadeOut, curve: music.fadeCurve,
                                  envelope: music.volumePoints,
                                  duckSpans: music.duckingEnabled ? voiceSpans : [])
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

    /// Emits a piecewise gain envelope for one lane: base × automation points ×
    /// fade shape × ducking, sampled at ~0.1 s and written as setVolume/ramps.
    /// Shared by fades (A3), volume envelope (A4) and auto-ducking (A5).
    private func applyVolumeAutomation(_ p: AVMutableAudioMixInputParameters,
                                       base: Float, span: ClosedRange<Double>,
                                       fadeIn: Double, fadeOut: Double, curve: FadeCurve,
                                       envelope: [AudioVolumePoint], duckSpans: [ClosedRange<Double>]) {
        let start = span.lowerBound
        let dur = max(0.001, span.upperBound - start)
        let duckGain = 0.25   // −12 dB
        let duckRamp = 0.3

        func gain(atLocal lt: Double) -> Float {
            var g = Double(base)
            if !envelope.isEmpty { g *= Self.envelopeValue(envelope, at: lt, duration: dur) }
            if fadeIn > 0.01, lt < fadeIn { g *= curve.value(lt / fadeIn) }
            if fadeOut > 0.01, lt > dur - fadeOut { g *= curve.value(max(0, dur - lt) / fadeOut) }
            // Duck: full inside a voice span, ramped 0.3 s at the edges.
            let abs = start + lt
            for d in duckSpans {
                let inner = (d.lowerBound - 0.001)...(d.upperBound + 0.001)
                if inner.contains(abs) {
                    g *= duckGain
                } else if abs > d.lowerBound - duckRamp, abs < d.lowerBound {
                    g *= 1 - (1 - duckGain) * ((abs - (d.lowerBound - duckRamp)) / duckRamp)
                } else if abs > d.upperBound, abs < d.upperBound + duckRamp {
                    g *= duckGain + (1 - duckGain) * ((abs - d.upperBound) / duckRamp)
                }
            }
            return Float(min(max(g, 0), 1))
        }

        let steps = min(200, max(12, Int(dur / 0.1)))
        var lastT = 0.0
        var lastG = gain(atLocal: 0)
        p.setVolume(lastG, at: CMTime(seconds: start, preferredTimescale: 600))
        for i in 1...steps {
            let lt = dur * Double(i) / Double(steps)
            let g = gain(atLocal: lt)
            p.setVolumeRamp(fromStartVolume: lastG, toEndVolume: g,
                            timeRange: CMTimeRange(
                                start: CMTime(seconds: start + lastT, preferredTimescale: 600),
                                duration: CMTime(seconds: lt - lastT, preferredTimescale: 600)))
            lastT = lt; lastG = g
        }
    }

    /// Piecewise-linear envelope value at local time `lt` (0…dur). Points are
    /// sorted by time; endpoints hold. Empty envelope → 1.
    private static func envelopeValue(_ points: [AudioVolumePoint], at lt: Double, duration: Double) -> Double {
        guard !points.isEmpty else { return 1 }
        let sorted = points.sorted { $0.time < $1.time }
        if lt <= sorted[0].time { return sorted[0].volume }
        if let last = sorted.last, lt >= last.time { return last.volume }
        for i in 0..<(sorted.count - 1) where lt >= sorted[i].time && lt < sorted[i + 1].time {
            let a = sorted[i], b = sorted[i + 1]
            let f = (lt - a.time) / max(0.001, b.time - a.time)
            return a.volume + (b.volume - a.volume) * f
        }
        return sorted.last?.volume ?? 1
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
        // A loose tolerance lets the generator land on a fully-decoded frame —
        // zero tolerance at ~0s intermittently returned half-decoded green
        // rectangles for project thumbs (same fix as filmstripFrames).
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let time = CMTime(seconds: max(seconds, 0.1), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

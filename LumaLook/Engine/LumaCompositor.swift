import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Frame payload types
//
// The custom compositor (T1) is instantiated BY AVFoundation via
// `customVideoCompositorClass`, so everything a frame needs must ride on the
// instructions — never on compositor init parameters.

/// Per-clip data the compositor needs, precomputed on rebuild.
/// `start`/`end` are composition seconds (post speed-scaling).
/// Per-clip display transforms the *user* applied (distinct from the source
/// `preferredTransform` orientation normalisation). One struct so waves 2.1
/// (rotate/mirror) → 2.2 (crop/straighten) → 3.1 (Ken Burns) extend a single
/// field on FrameMeta instead of piling on parameters. Identity default keeps
/// every existing call site unchanged.
struct ClipDisplayOps: Equatable {
    var rotationQuarterTurns: Int = 0   // user 90° steps, mod 4
    var isMirrored: Bool = false        // horizontal flip
    /// Free crop in unit space (y-down UI convention); full frame = identity.
    var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Fine straighten in degrees (−15…15); auto-fills to hide empty corners.
    var straightenDegrees: Double = 0

    static let identity = ClipDisplayOps()
    var isCropIdentity: Bool {
        abs(cropRect.minX) < 0.001 && abs(cropRect.minY) < 0.001 &&
        abs(cropRect.width - 1) < 0.001 && abs(cropRect.height - 1) < 0.001
    }
    var isIdentity: Bool {
        rotationQuarterTurns % 4 == 0 && !isMirrored &&
        isCropIdentity && abs(straightenDegrees) < 0.01
    }
}

struct FrameMeta {
    let start: Double
    let end: Double
    /// Source preferredTransform (orientation normalisation).
    let transform: CGAffineTransform
    /// User display transforms (rotate/mirror; crop/Ken Burns later).
    var display: ClipDisplayOps = .identity
    /// Photo clips on the main track (T7): the compositor renders this still
    /// instead of pulling a source frame.
    let imageURL: URL?
    /// True when the still's range is anchored by real (ignored) frames on
    /// the main track. Instructions then REQUIRE the main track: AVPlayer
    /// stalls on instructions with no source tracks at all (verified on the
    /// sim — playback froze at the photo boundary), so the tiny anchor
    /// frames pace the player while the compositor renders the still.
    let hasAnchorFrames: Bool
    /// Per-clip grade (queue: per-clip looks). Live reference like the global
    /// LookState; nil = the clip follows the timeline's global grade.
    let clipLookState: LookState?
    /// Clip identity, so the compositor can look up live Ken Burns keyframes.
    var clipID: UUID? = nil
    /// F8 — spot tool (blur/mosaic/fill) over a shaped region of this clip.
    var mask: ClipMaskSpec? = nil

    init(start: Double, end: Double, transform: CGAffineTransform,
         imageURL: URL? = nil, hasAnchorFrames: Bool = false,
         clipLookState: LookState? = nil, display: ClipDisplayOps = .identity,
         clipID: UUID? = nil, mask: ClipMaskSpec? = nil) {
        self.start = start
        self.end = end
        self.transform = transform
        self.imageURL = imageURL
        self.hasAnchorFrames = hasAnchorFrames
        self.clipLookState = clipLookState
        self.display = display
        self.clipID = clipID
        self.mask = mask
    }
}

/// Transition boundaries: cut time + style, sampled per frame. Veil styles
/// need only the timing; cross-transitions (dissolve/wipe) also carry where
/// the OTHER clip's frames live during each half of the span — an aux track
/// with pre/post-roll material, or a still when that side is a photo clip.
struct TransitionSpanSpec {
    let center: Double
    let style: TransitionStyle
    let half: Double
    /// Aux track carrying the incoming clip's pre-roll (first half) and the
    /// outgoing clip's post-roll (second half). Invalid for veil styles.
    var auxTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    /// Orientation for the aux frames in each half (different source assets).
    var headTransform: CGAffineTransform = .identity   // incoming clip (first half)
    var tailTransform: CGAffineTransform = .identity   // outgoing clip (second half)
    /// Stills when a photo clip sits on that side of the cut.
    var headImageURL: URL? = nil
    var tailImageURL: URL? = nil
    /// Per-clip grades for the aux side (nil = global).
    var headLookState: LookState? = nil
    var tailLookState: LookState? = nil
    /// User display transforms for the aux side (rotate/mirror) so a rotated
    /// clip stays rotated through a dissolve/wipe.
    var headDisplay: ClipDisplayOps = .identity
    var tailDisplay: ClipDisplayOps = .identity
}

/// Live overlay placement values (size/position/opacity). Reference type for
/// the same reason as `LookState`: sliders mutate it and the running
/// compositor reads the latest values without a composition rebuild.
final class OverlayLayout: @unchecked Sendable {
    struct Placement {
        var sizeFraction: Double
        var center: CGPoint     // unit canvas coords, y down (UI convention)
        var opacity: Double
        var rotationDegrees: Double = 0
    }

    /// A placement pinned to an offset (seconds) within the overlay's run.
    struct Keyframe {
        let time: Double
        var placement: Placement
        var easing: KeyframeEasing = .linear
    }

    private struct Entry {
        var base: Placement
        var keyframes: [Keyframe]   // sorted by time; empty = static overlay
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func set(_ placement: Placement, keyframes: [Keyframe] = [], for id: UUID) {
        lock.lock()
        entries[id] = Entry(base: placement, keyframes: keyframes.sorted { $0.time < $1.time })
        lock.unlock()
    }

    /// Placement at `offset` seconds into the overlay: linear interpolation
    /// between surrounding keyframes; the base placement when none exist.
    func placement(for id: UUID, at offset: Double = 0) -> Placement? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id] else { return nil }
        let frames = entry.keyframes
        guard !frames.isEmpty else { return entry.base }
        if offset <= frames[0].time { return frames[0].placement }
        guard let last = frames.last, offset < last.time else { return frames.last?.placement }
        for i in 0..<(frames.count - 1) where offset >= frames[i].time && offset < frames[i + 1].time {
            let a = frames[i], b = frames[i + 1]
            let span = max(b.time - a.time, 0.001)
            let t = a.easing.ease((offset - a.time) / span)
            return Placement(
                sizeFraction: a.placement.sizeFraction
                    + (b.placement.sizeFraction - a.placement.sizeFraction) * t,
                center: CGPoint(
                    x: a.placement.center.x + (b.placement.center.x - a.placement.center.x) * t,
                    y: a.placement.center.y + (b.placement.center.y - a.placement.center.y) * t),
                opacity: a.placement.opacity + (b.placement.opacity - a.placement.opacity) * t,
                rotationDegrees: a.placement.rotationDegrees
                    + (b.placement.rotationDegrees - a.placement.rotationDegrees) * t)
        }
        return entry.base
    }

    func replaceAll(_ new: [UUID: (Placement, [Keyframe])]) {
        lock.lock()
        entries = new.mapValues { Entry(base: $0.0, keyframes: $0.1.sorted { $0.time < $1.time }) }
        lock.unlock()
    }
}

/// Audio-reactive visual style modulated by a per-frame level envelope.
enum AudioReactiveStyle: String, Codable, CaseIterable {
    case pulse, glow, shake
    var label: String {
        switch self {
        case .pulse: return "Pulse"
        case .glow: return "Glow"
        case .shake: return "Shake"
        }
    }
}

/// Precomputed 30 Hz loudness envelope + style — deterministic so preview and
/// export match.
struct AudioReactiveSpec {
    let style: AudioReactiveStyle
    let strength: Double
    let levels: [Float]      // 0…1, one per 1/30 s
    let sampleRate: Double   // 30

    func level(at seconds: Double) -> Double {
        guard !levels.isEmpty else { return 0 }
        let idx = min(levels.count - 1, max(0, Int(seconds * sampleRate)))
        return Double(levels[idx])
    }
}

/// A full-frame adjustment grade active over a time span (adjustment layer).
struct AdjustmentSpan {
    let start: Double
    let end: Double
    let state: LookState
}

/// F6 — a timed effect over the whole frame. `localTime` inside the span
/// drives every animation, so preview and export match frame for frame.
struct EffectSpan {
    let start: Double
    let end: Double
    let kind: EffectKind
    let intensity: Double
}

/// Live per-clip pan/zoom (Ken Burns). Same live-reference trick as
/// `OverlayLayout`: the editor mutates it and the running compositor reads the
/// latest keyframes without a composition rebuild. Applied to the base frame
/// (videos AND stills) as an animated crop before canvas placement.
final class ClipTransformLayout: @unchecked Sendable {
    struct Transform: Equatable {
        var zoom: Double = 1              // ≥1; the visible window is 1/zoom
        var center = CGPoint(x: 0.5, y: 0.5)   // unit, y-down (UI)
    }
    struct Keyframe { let time: Double; var transform: Transform; var easing: KeyframeEasing = .linear }

    private let lock = NSLock()
    private var entries: [UUID: [Keyframe]] = [:]

    func replaceAll(_ new: [UUID: [Keyframe]]) {
        lock.lock()
        entries = new.mapValues { $0.sorted { $0.time < $1.time } }
        lock.unlock()
    }

    /// Interpolated transform `offset` seconds into the clip; nil = static.
    func transform(for id: UUID, at offset: Double) -> Transform? {
        lock.lock(); defer { lock.unlock() }
        guard let frames = entries[id], !frames.isEmpty else { return nil }
        if offset <= frames[0].time { return frames[0].transform }
        guard let last = frames.last, offset < last.time else { return frames.last?.transform }
        for i in 0..<(frames.count - 1) where offset >= frames[i].time && offset < frames[i + 1].time {
            let a = frames[i], b = frames[i + 1]
            let span = max(b.time - a.time, 0.001)
            let t = a.easing.ease((offset - a.time) / span)
            return Transform(
                zoom: a.transform.zoom + (b.transform.zoom - a.transform.zoom) * t,
                center: CGPoint(
                    x: a.transform.center.x + (b.transform.center.x - a.transform.center.x) * t,
                    y: a.transform.center.y + (b.transform.center.y - a.transform.center.y) * t))
        }
        return frames.last?.transform
    }
}

/// One overlay item as the compositor sees it: where its frames come from
/// (a second source track, or a still image) and when it is on screen.
struct OverlaySpec {
    let id: UUID
    /// Source track carrying the overlay's video frames;
    /// `kCMPersistentTrackID_Invalid` for image overlays.
    let trackID: CMPersistentTrackID
    /// Still source for image overlays (rendered via the compositor's cache).
    let imageURL: URL?
    /// Orientation normalisation for video overlays.
    let transform: CGAffineTransform
    let start: Double
    let end: Double
    /// Text layer (T6): rendered by the compositor's text cache; never graded.
    var text: String? = nil
    /// F2 — the full rasteriser payload (font/colour/stroke/box/align).
    var textSpec = TextStyleSpec()
    /// F4 — vector shape layer; nil unless this overlay is a shape.
    var shape: ShapeSpec? = nil
    /// Stacking lane: higher lanes composite last (on top).
    var lane: Int = 0
}

// MARK: - Instruction

/// Carries everything `LumaVideoCompositor` needs for one time segment.
/// Segments are cut at photo-clip and overlay boundaries so
/// `requiredSourceTrackIDs` always matches what the segment actually reads.
/// Background fill behind the framed clip. `.fill` aspect-fills the canvas
/// (edges cropped, no background). The rest aspect-FIT the clip and paint a
/// background in the letterbox/pillar bars — the img.ly / CapCut "canvas" tool.
enum CanvasBackgroundMode: String, Codable, CaseIterable {
    case fill, fit, blur, solid, gradient

    var label: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .blur: return "Blur"
        case .solid: return "Colour"
        case .gradient: return "Gradient"
        }
    }
    var icon: String {
        switch self {
        case .fill: return "rectangle.fill"
        case .fit: return "rectangle.inset.filled"
        case .blur: return "drop.fill"
        case .solid: return "paintpalette.fill"
        case .gradient: return "square.righthalf.filled"
        }
    }
}

/// Canvas background settings. Pure values → bakes identically in preview and
/// export.
struct CanvasSpec: Equatable {
    var mode: CanvasBackgroundMode = .fill
    var solidHex: String = "#101014"
    var gradientTopHex: String = "#2A2A38"
    var gradientBottomHex: String = "#050507"
    static let fill = CanvasSpec()
}

final class LumaCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    // Payload (shared across the timeline's instructions).
    let mainTrackID: CMPersistentTrackID
    let frameMetas: [FrameMeta]
    let transitionSpans: [TransitionSpanSpec]
    let overlays: [OverlaySpec]
    let overlayLayout: OverlayLayout
    /// Live per-overlay effect stack (blend/chroma/mask/adjust/border).
    let overlayEffects: OverlayEffectsBox
    /// Reference type — live-updates the running preview, same trick as the
    /// old CI-handler closure capturing it.
    let lookState: LookState
    let renderSize: CGSize
    let zoomFactor: CGFloat
    let canvas: CanvasSpec
    /// Live per-clip Ken Burns keyframes (nil = no clip animates).
    let transformLayout: ClipTransformLayout?
    /// Full-frame adjustment grades active in this segment.
    let adjustments: [AdjustmentSpan]
    /// F6 full-frame effects active in this segment.
    let effects: [EffectSpan]
    /// Audio-reactive modulation (pulse/glow/shake), nil = off.
    let audioReactive: AudioReactiveSpec?
    /// Project-level frame/border, composited last. `FramePreset` rawValue.
    let framePreset: String

    init(timeRange: CMTimeRange,
         requiredSourceTrackIDs: [NSValue],
         mainTrackID: CMPersistentTrackID,
         frameMetas: [FrameMeta],
         transitionSpans: [TransitionSpanSpec],
         overlays: [OverlaySpec],
         overlayLayout: OverlayLayout,
         overlayEffects: OverlayEffectsBox,
         lookState: LookState,
         renderSize: CGSize,
         zoomFactor: CGFloat,
         canvas: CanvasSpec = .fill,
         transformLayout: ClipTransformLayout? = nil,
         adjustments: [AdjustmentSpan] = [],
         effects: [EffectSpan] = [],
         audioReactive: AudioReactiveSpec? = nil,
         framePreset: String = FramePreset.none.rawValue) {
        self.timeRange = timeRange
        // An empty ID list means "call the compositor with no source frames"
        // (photo-clip segments) — exactly what T7 needs.
        self.requiredSourceTrackIDs = requiredSourceTrackIDs
        self.mainTrackID = mainTrackID
        self.frameMetas = frameMetas
        self.transitionSpans = transitionSpans
        self.overlays = overlays
        self.overlayLayout = overlayLayout
        self.overlayEffects = overlayEffects
        self.lookState = lookState
        self.renderSize = renderSize
        self.zoomFactor = zoomFactor
        self.canvas = canvas
        self.transformLayout = transformLayout
        self.adjustments = adjustments
        self.effects = effects
        self.audioReactive = audioReactive
        self.framePreset = framePreset
        super.init()
    }
}

// MARK: - Compositor

/// Custom `AVVideoCompositing` replacing the single-track
/// `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)`
/// convenience. Reproduces the old handler exactly — orientation
/// normalisation, aspect-fill + zoom into the render canvas, the shared
/// look pipeline, phase-A transition veils — and adds what the convenience
/// could never do: a second video track (PIP overlays) and trackless
/// still-image segments. One compositor feeds preview and export alike.
final class LumaVideoCompositor: NSObject, AVVideoCompositing {

    // BGRA in and out: the CI-friendly format the old convenience used.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    private let renderQueue = DispatchQueue(label: "com.emotiveimpact.lumalook.compositor",
                                            qos: .userInteractive)
    private let stateLock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var shouldCancelAll = false

    /// Still-image cache (photo clips + image overlays), keyed by URL.
    /// Loaded once per file, oriented via EXIF on load.
    private var stillCache: [URL: CIImage] = [:]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateLock.lock()
        renderContext = newRenderContext
        stateLock.unlock()
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Pending requests already queued see the flag and finish cancelled;
        // the async reset runs after the queue drains, re-arming for the
        // next burst (the AVCustomEdit pattern).
        stateLock.lock()
        shouldCancelAll = true
        stateLock.unlock()
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.shouldCancelAll = false
            self.stateLock.unlock()
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                request.finish(with: LumaCompositorError.internalState)
                return
            }
            self.stateLock.lock()
            let cancelled = self.shouldCancelAll
            let context = self.renderContext
            self.stateLock.unlock()

            if cancelled {
                request.finishCancelledRequest()
                return
            }
            guard let context else {
                request.finish(with: LumaCompositorError.missingRenderContext)
                return
            }
            self.render(request, in: context)
        }
    }

    private enum LumaCompositorError: Error {
        case missingRenderContext
        case missingInstruction
        case bufferAllocationFailed
        case internalState
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest,
                        in context: AVVideoCompositionRenderContext) {
        guard let instruction = request.videoCompositionInstruction as? LumaCompositionInstruction else {
            request.finish(with: LumaCompositorError.missingInstruction)
            return
        }
        guard let outputBuffer = context.newPixelBuffer() else {
            request.finish(with: LumaCompositorError.bufferAllocationFailed)
            return
        }

        let seconds = request.compositionTime.seconds
        let renderSize = instruction.renderSize
        let renderRect = CGRect(origin: .zero, size: renderSize)
        let pipeline = LookPipeline.shared

        // --- Base frame: main video track or a photo clip's still ---------
        // Meta lookup verbatim from the old CI handler.
        let meta = instruction.frameMetas.last(where: {
            seconds >= $0.start - 0.001 && seconds < $0.end + 0.001
        }) ?? instruction.frameMetas.first

        // Live Ken Burns transform for this clip at this instant, if any.
        func kenBurns(_ img: CIImage) -> CIImage {
            guard let meta, let id = meta.clipID,
                  let kb = instruction.transformLayout?.transform(for: id, at: seconds - meta.start)
            else { return img }
            return applyKenBurns(img, zoom: CGFloat(kb.zoom), center: kb.center)
        }

        var canvas: CIImage
        if let meta, let imageURL = meta.imageURL, let still = stillImage(at: imageURL) {
            let oriented = kenBurns(applyUserOrientation(still, meta.display))
            canvas = composeCanvas(oriented, into: renderSize, zoom: instruction.zoomFactor,
                                   spec: instruction.canvas)
        } else if let sourceBuffer = request.sourceFrame(byTrackID: instruction.mainTrackID) {
            var image = CIImage(cvPixelBuffer: sourceBuffer)
            if let meta, !meta.transform.isIdentity {
                image = image.transformed(by: meta.transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                                y: -image.extent.minY))
            }
            if let meta { image = applyUserOrientation(image, meta.display) }
            image = kenBurns(image)
            canvas = composeCanvas(image, into: renderSize, zoom: instruction.zoomFactor,
                                   spec: instruction.canvas)
        } else {
            // No source and no still (e.g. race right at a boundary): black.
            canvas = CIImage(color: .black)
        }

        // --- F8 spot tool: blur/mosaic/fill a shaped region of the clip.
        // On the composed canvas and BEFORE the grade, so the look treats the
        // masked pixels like any others (a graded blur, not a blurred grade).
        if let mask = meta?.mask {
            canvas = MaskRenderer.apply(mask, to: canvas.cropped(to: renderRect), rect: renderRect)
        }

        // --- Grade (same pipeline, split-wipe never baked in) --------------
        // Per-clip look wins over the timeline's global grade.
        let activeState = meta?.clipLookState ?? instruction.lookState
        // Finite extent in, finite out: spatial ops (lens, halation, bloom)
        // need real frame bounds; they clamp internally where blurs sample
        // past the edge.
        var graded = pipeline.apply(state: activeState,
                                    to: canvas.cropped(to: renderRect),
                                    includeSplit: false)
            .cropped(to: renderRect)

        // --- Adjustment layers: full-frame grades over the base video, below
        // the overlays (overlays composite on top, unaffected). ------------
        for adj in instruction.adjustments
        where seconds >= adj.start - 0.001 && seconds < adj.end + 0.001 {
            graded = pipeline.apply(state: adj.state,
                                    to: graded.cropped(to: renderRect),
                                    includeSplit: false)
                .cropped(to: renderRect)
        }

        // --- F6 effect layers: full-frame, below the overlays so titles and
        // stickers stay clean on top of a glitching picture. ----------------
        for fx in instruction.effects
        where seconds >= fx.start - 0.001 && seconds < fx.end + 0.001 {
            graded = EffectRenderer.apply(fx.kind,
                                          to: graded.cropped(to: renderRect),
                                          localTime: seconds - fx.start,
                                          intensity: fx.intensity,
                                          rect: renderRect)
        }

        // --- Audio-reactive modulation (D1): pulse/glow/shake by loudness ----
        if let reactive = instruction.audioReactive {
            let level = reactive.level(at: seconds)
            if level > 0.001 {
                let s = reactive.strength
                switch reactive.style {
                case .pulse:
                    let zoom = 1 + level * 0.10 * s
                    graded = graded
                        .transformed(by: CGAffineTransform(translationX: -renderRect.midX, y: -renderRect.midY)
                            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                            .concatenating(CGAffineTransform(translationX: renderRect.midX, y: renderRect.midY)))
                        .cropped(to: renderRect)
                case .glow:
                    let bloom = CIFilter.bloom()
                    bloom.inputImage = graded.clampedToExtent()
                    bloom.intensity = Float(level * s)
                    bloom.radius = Float(10 + level * s * 25)
                    graded = (bloom.outputImage ?? graded).cropped(to: renderRect)
                case .shake:
                    let amt = level * 14 * s
                    let dx = CGFloat(sin(seconds * 73)) * amt
                    let dy = CGFloat(cos(seconds * 61)) * amt
                    graded = graded.clampedToExtent()
                        .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                        .cropped(to: renderRect)
                }
            }
        }

        // --- Overlays: graded PIP layers composited over the base ----------
        // Lane order = z-order: lower lanes first, higher lanes composited last
        // (on top). Stable within a lane by insertion order.
        let orderedOverlays = instruction.overlays
            .enumerated()
            .sorted { ($0.element.lane, $0.offset) < ($1.element.lane, $1.offset) }
            .map(\.element)
        for spec in orderedOverlays
        where seconds >= spec.start - 0.001 && seconds < spec.end + 0.001 {
            guard let placement = instruction.overlayLayout.placement(
                for: spec.id, at: seconds - spec.start) else { continue }

            // Live effect stack for this overlay (blend/chroma/mask/adjust/border).
            let fx = instruction.overlayEffects.effects(for: spec.id) ?? OverlayEffects()

            var overlayImage: CIImage?
            // Synthetic layers (text + shapes) hold their exact authored
            // colour: no grade, no chroma/mask/border passes.
            var isVector = false
            if let text = spec.text {
                overlayImage = TextRasterizer.image(text, style: spec.textSpec)
                isVector = true
            } else if let shape = spec.shape {
                // Square authoring canvas; sizeFraction normalises width below.
                overlayImage = ShapeRenderer.image(shape, size: CGSize(width: 512, height: 512))
                isVector = true
            } else if let imageURL = spec.imageURL {
                // F5: animated sources (GIF/APNG) advance with time; ordinary
                // stills fall through unchanged.
                overlayImage = animatedStill(at: imageURL, localTime: seconds - spec.start)
                    ?? stillImage(at: imageURL)
            } else if spec.trackID != kCMPersistentTrackID_Invalid,
                      let buffer = request.sourceFrame(byTrackID: spec.trackID) {
                var frame = CIImage(cvPixelBuffer: buffer)
                if !spec.transform.isIdentity {
                    frame = frame.transformed(by: spec.transform)
                    frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX,
                                                                    y: -frame.extent.minY))
                }
                overlayImage = frame
            }
            guard var overlay = overlayImage, overlay.extent.width > 0 else { continue }

            // ---- Overlay effect hook chain ----
            // Order: chroma (raw) → grade → adjust → scale → mask → border →
            //        rotate/position/opacity → blend composite.

            // F4 chroma key: operate on the RAW frame before grading — grading
            // shifts the green and would break the key. Text never keys.
            if !isVector, let chroma = fx.chroma {
                overlay = ChromaKeyFilter.apply(to: overlay, settings: chroma)
                    .cropped(to: overlay.extent)
            }

            // Same look on the PIP as the base — one grade across the frame.
            // Text/shapes stay ungraded: they must hold their exact colour.
            if !isVector {
                overlay = pipeline.apply(state: activeState,
                                         to: overlay,
                                         includeSplit: false)
                    .cropped(to: overlay.extent)
            }

            // F6 per-overlay tone adjustment, layered on top of the grade.
            if !isVector, let adjust = fx.adjust, !adjust.isIdentity {
                overlay = pipeline.applyOverlayAdjustments(adjust, to: overlay)
            }

            // Scale so the overlay's width is `sizeFraction` of the canvas.
            let fraction = min(max(placement.sizeFraction, 0.05), 1.0)
            let targetWidth = renderSize.width * CGFloat(fraction)
            let scale = targetWidth / overlay.extent.width
            overlay = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // F5 mask: generated for the SCALED extent so feather widths are in
            // render pixels. Applied before rotation so the alpha rotates with it.
            if !isVector, let maskSettings = fx.mask {
                let m = OverlayMaskRenderer.mask(maskSettings, extent: overlay.extent)
                overlay = overlay.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: m,
                ]).cropped(to: overlay.extent)
            }

            // F7 border ring: composited UNDER the overlay so the frame hugs
            // the edge; drawn pre-rotation so it rotates with the overlay.
            if !isVector, let border = fx.border {
                let ring = OverlayMaskRenderer.borderRing(border, extent: overlay.extent)
                overlay = ring.composited(over: overlay).cropped(to: overlay.extent)
            }

            // Rotation (keyframes): about the overlay's own centre. UI is
            // clockwise-positive; CI rotates counter-clockwise, so negate.
            if abs(placement.rotationDegrees) > 0.01 {
                let radians = -CGFloat(placement.rotationDegrees) * .pi / 180
                let mid = CGPoint(x: overlay.extent.midX, y: overlay.extent.midY)
                overlay = overlay
                    .transformed(by: CGAffineTransform(translationX: -mid.x, y: -mid.y)
                        .concatenating(CGAffineTransform(rotationAngle: radians))
                        .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
            }

            // Position: unit center, UI y-down -> CI y-up.
            let ciCenterX = CGFloat(placement.center.x) * renderSize.width
            let ciCenterY = (1 - CGFloat(placement.center.y)) * renderSize.height
            let dx = ciCenterX - overlay.extent.midX
            let dy = ciCenterY - overlay.extent.midY
            overlay = overlay.transformed(by: CGAffineTransform(translationX: dx, y: dy))

            // Opacity: dim premultiplied RGBA together so source-over fades
            // cleanly instead of blowing out.
            let opacity = min(max(placement.opacity, 0), 1)
            if opacity < 0.999 {
                let matrix = CIFilter.colorMatrix()
                matrix.inputImage = overlay
                matrix.rVector = CIVector(x: opacity, y: 0, z: 0, w: 0)
                matrix.gVector = CIVector(x: 0, y: opacity, z: 0, w: 0)
                matrix.bVector = CIVector(x: 0, y: 0, z: opacity, w: 0)
                matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
                overlay = matrix.outputImage ?? overlay
            }

            // Blend-mode composite (F3): Blend(overlay, base) then source-over.
            // Text overlays always use normal so titles hold their colour.
            if !isVector, let filterName = fx.blendMode.ciFilterName {
                let blended = overlay.applyingFilter(
                    filterName, parameters: [kCIInputBackgroundImageKey: graded])
                    .cropped(to: overlay.extent.intersection(renderRect))
                graded = blended.composited(over: graded).cropped(to: renderRect)
            } else {
                graded = overlay.composited(over: graded).cropped(to: renderRect)
            }
        }

        // --- Transitions, applied last so they take the PIP with them ------
        if let span = instruction.transitionSpans.first(where: { abs(seconds - $0.center) < $0.half }) {
            if span.style.isCrossTransition {
                // True dissolve/wipe: blend the main frame with the OTHER
                // clip's frame (aux A/B-roll track, or a photo clip's still).
                let firstHalf = seconds < span.center
                var aux: CIImage?
                let auxDisplay = firstHalf ? span.headDisplay : span.tailDisplay
                if let url = firstHalf ? span.headImageURL : span.tailImageURL,
                   let still = stillImage(at: url) {
                    aux = aspectFill(applyUserOrientation(still, auxDisplay),
                                     into: renderSize, zoom: instruction.zoomFactor)
                } else if span.auxTrackID != kCMPersistentTrackID_Invalid,
                          let buffer = request.sourceFrame(byTrackID: span.auxTrackID) {
                    var frame = CIImage(cvPixelBuffer: buffer)
                    let transform = firstHalf ? span.headTransform : span.tailTransform
                    if !transform.isIdentity {
                        frame = frame.transformed(by: transform)
                        frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX,
                                                                        y: -frame.extent.minY))
                    }
                    frame = applyUserOrientation(frame, auxDisplay)
                    aux = aspectFill(frame, into: renderSize, zoom: instruction.zoomFactor)
                }
                if var auxImage = aux {
                    // The aux side wears ITS clip's grade (per-clip looks).
                    let auxState = (firstHalf ? span.headLookState : span.tailLookState)
                        ?? instruction.lookState
                    auxImage = pipeline.apply(state: auxState,
                                              to: auxImage.cropped(to: renderRect),
                                              includeSplit: false)
                        .cropped(to: renderRect)
                    let progress = CGFloat((seconds - (span.center - span.half)) / (span.half * 2))
                    let incoming = firstHalf ? auxImage : graded
                    let outgoing = firstHalf ? graded : auxImage
                    graded = Self.crossBlend(outgoing: outgoing, incoming: incoming,
                                             progress: progress, style: span.style,
                                             rect: renderRect)
                }
                // Missing aux (failed insert): keep the base — a hard cut.
            } else {
                // Phase-A veils: triangle envelope, fully veiled at the cut.
                let strength = 1 - abs(seconds - span.center) / span.half
                let veilColor: CIColor = span.style == .fadeBlack
                    ? CIColor(red: 0, green: 0, blue: 0, alpha: strength)
                    : CIColor(red: 1, green: 1, blue: 1,
                              alpha: span.style == .flash ? strength * 0.9 : strength)
                let veil = CIImage(color: veilColor).cropped(to: renderRect)
                graded = veil.composited(over: graded)
            }
        }

        // --- Frame / border ------------------------------------------------
        // Last, deliberately: a wipe or veil must never run across the border.
        if let preset = FramePreset(rawValue: instruction.framePreset), preset != .none {
            graded = FrameRenderer.apply(preset, to: graded, rect: renderRect)
        }

        // --- Render into the pool buffer and hand it back -------------------
        // Propagate colour attachments so the output stays tagged like its
        // source (the BT.709 policy set on the composition).
        if let sourceBuffer = request.sourceFrame(byTrackID: instruction.mainTrackID) {
            CVBufferPropagateAttachments(sourceBuffer, outputBuffer)
        }
        pipeline.context.render(graded, to: outputBuffer, bounds: renderRect,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    /// Cross-transition blends — delegates to `TransitionRenderer` (dissolve,
    /// wipe, slides, zooms, spin, glitch, luma-wipe). Kept as a thin shim so
    /// the render-loop call site is untouched.
    private static func crossBlend(outgoing: CIImage, incoming: CIImage,
                                   progress: CGFloat, style: TransitionStyle,
                                   rect: CGRect) -> CIImage {
        TransitionRenderer.render(outgoing: outgoing, incoming: incoming,
                                  progress: progress, style: style, rect: rect)
    }

    /// User display transforms (mirror then rotate), applied after source
    /// orientation and before canvas placement. Re-normalises the extent
    /// origin to (0,0) so `aspectFill` reframes the swapped dimensions. Both
    /// operands are pure geometry, so preview and export match exactly.
    private func applyUserOrientation(_ image: CIImage, _ ops: ClipDisplayOps) -> CIImage {
        guard !ops.isIdentity else { return image }
        var img = image
        if ops.isMirrored {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        }
        let turns = ((ops.rotationQuarterTurns % 4) + 4) % 4
        if turns != 0 {
            img = img.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        }
        // Re-origin before crop/straighten so unit maths use a clean extent.
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX,
                                                    y: -img.extent.minY))

        // Straighten: rotate a small angle about the centre and over-scale so
        // the empty corners never show, then crop back to the original frame.
        if abs(ops.straightenDegrees) > 0.01 {
            let box = img.extent
            let a = CGFloat(ops.straightenDegrees) * .pi / 180
            let cx = box.midX, cy = box.midY
            let r = box.width / max(box.height, 1)
            let fill = cos(abs(a)) + sin(abs(a)) * max(r, 1 / r)
            let t = CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: -a))
                .concatenating(CGAffineTransform(scaleX: fill, y: fill))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
            img = img.transformed(by: t).cropped(to: box)
        }

        // Free crop (unit rect, y measured from the TOP in UI space).
        if !ops.isCropIdentity {
            let e = img.extent
            let c = ops.cropRect
            let rect = CGRect(x: e.minX + c.minX * e.width,
                              y: e.minY + (1 - c.maxY) * e.height,
                              width: c.width * e.width,
                              height: c.height * e.height)
            img = img.cropped(to: rect)
        }

        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX,
                                                     y: -img.extent.minY))
    }

    /// Ken Burns: crops a `1/zoom` window centred on the unit point `center`
    /// (clamped to stay in frame), re-origined to (0,0). composeCanvas then
    /// fills the canvas with it — a smaller window reads as a zoom-in, moving
    /// the centre pans. `zoom == 1` is a no-op.
    private func applyKenBurns(_ image: CIImage, zoom: CGFloat, center: CGPoint) -> CIImage {
        guard zoom > 1.001 else { return image }
        let e = image.extent
        let w = e.width / zoom, h = e.height / zoom
        // Clamp the window centre so the crop rect stays inside the frame.
        let halfWFrac = (w / e.width) / 2, halfHFrac = (h / e.height) / 2
        let cxUnit = min(max(center.x, halfWFrac), 1 - halfWFrac)
        let cyUnit = min(max(center.y, halfHFrac), 1 - halfHFrac)   // y-down UI
        let cx = e.minX + cxUnit * e.width
        let cyTopDown = cyUnit * e.height
        let originY = e.minY + (e.height - cyTopDown - h / 2)         // flip to y-up
        let rect = CGRect(x: cx - w / 2, y: originY, width: w, height: h)
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Places the framed clip on the chosen canvas background. `.fill` is the
    /// legacy aspect-fill (no background); the rest aspect-FIT the clip and
    /// paint the letterbox bars.
    private func composeCanvas(_ image: CIImage, into renderSize: CGSize,
                               zoom: CGFloat, spec: CanvasSpec) -> CIImage {
        let renderRect = CGRect(origin: .zero, size: renderSize)
        if spec.mode == .fill {
            return aspectFill(image, into: renderSize, zoom: zoom)
        }
        let foreground = aspectFit(image, into: renderSize, zoom: zoom)
        let background: CIImage
        switch spec.mode {
        case .fill:
            return foreground   // unreachable
        case .fit:
            background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: renderRect)
        case .solid:
            background = CIImage(color: ciColor(hex: spec.solidHex)).cropped(to: renderRect)
        case .gradient:
            background = gradientImage(top: spec.gradientTopHex, bottom: spec.gradientBottomHex,
                                       size: renderSize)
        case .blur:
            // A blurred, over-scaled copy of the same frame fills the bars.
            let filled = aspectFill(image, into: renderSize, zoom: zoom * 1.15)
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = filled.clampedToExtent()
            blur.radius = Float(min(renderSize.width, renderSize.height) * 0.05)
            let darken = CIFilter.colorControls()
            darken.inputImage = (blur.outputImage ?? filled).cropped(to: renderRect)
            darken.brightness = -0.1
            darken.saturation = 1.05
            background = (darken.outputImage ?? filled).cropped(to: renderRect)
        }
        return foreground.composited(over: background).cropped(to: renderRect)
    }

    /// Aspect-FIT into the render canvas honouring zoom (letterbox/pillar).
    private func aspectFit(_ image: CIImage, into renderSize: CGSize, zoom: CGFloat) -> CIImage {
        var image = image
        let sx = renderSize.width / image.extent.width
        let sy = renderSize.height / image.extent.height
        let scale = min(sx, sy) * zoom
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (renderSize.width - image.extent.width) / 2 - image.extent.minX
        let dy = (renderSize.height - image.extent.height) / 2 - image.extent.minY
        return image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    /// Vertical two-stop gradient sized to the canvas.
    private func gradientImage(top: String, bottom: String, size: CGSize) -> CIImage {
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: size.width / 2, y: size.height)   // top (y-up)
        gradient.point1 = CGPoint(x: size.width / 2, y: 0)             // bottom
        gradient.color0 = ciColor(hex: top)
        gradient.color1 = ciColor(hex: bottom)
        return (gradient.outputImage ?? CIImage(color: ciColor(hex: bottom)))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Parses "#RRGGBB" into a CIColor (falls back to black).
    private func ciColor(hex: String) -> CIColor {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return CIColor(red: 0, green: 0, blue: 0) }
        return CIColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255)
    }

    /// Aspect-fill into the render canvas honouring zoom — verbatim port of
    /// the old handler's math.
    private func aspectFill(_ image: CIImage, into renderSize: CGSize, zoom: CGFloat) -> CIImage {
        var image = image
        let sx = renderSize.width / image.extent.width
        let sy = renderSize.height / image.extent.height
        let scale = max(sx, sy) * zoom
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (renderSize.width - image.extent.width) / 2 - image.extent.minX
        let dy = (renderSize.height - image.extent.height) / 2 - image.extent.minY
        return image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    /// CIImage cache for photo clips + image overlays. EXIF orientation is
    /// applied on load so stills behave like `appliesPreferredTrackTransform`.
    /// Animated-still cache (F5): GIF / APNG / animated WebP decoded once into
    /// frames + cumulative times. The frame is picked by a pure function of
    /// time, so preview and export agree and looping is intrinsic.
    private var animatedCache: [URL: (frames: [CIImage], cumTimes: [Double], total: Double)?] = [:]

    /// Frame of an animated source at `localTime` seconds into the overlay's
    /// run. Returns nil for ordinary single-frame stills (the caller falls back
    /// to `stillImage`). A nil ENTRY is cached too, so a still is probed once.
    private func animatedStill(at url: URL, localTime: Double) -> CIImage? {
        stateLock.lock()
        let hit = animatedCache[url]
        stateLock.unlock()

        let entry: (frames: [CIImage], cumTimes: [Double], total: Double)?
        if let hit {
            entry = hit
        } else {
            entry = decodeAnimated(url)
            stateLock.lock()
            animatedCache[url] = entry
            stateLock.unlock()
        }
        guard let entry, entry.total > 0.001, !entry.frames.isEmpty else { return nil }

        // Wrap: the sticker loops for as long as the overlay lives.
        var t = localTime.truncatingRemainder(dividingBy: entry.total)
        if t < 0 { t += entry.total }
        let i = entry.cumTimes.firstIndex(where: { t < $0 }) ?? (entry.frames.count - 1)
        return entry.frames[min(i, entry.frames.count - 1)]
    }

    private func decodeAnimated(_ url: URL) -> (frames: [CIImage], cumTimes: [Double], total: Double)? {
        guard let decoded = GIFExporter.decodeFrames(at: url), decoded.frames.count > 1 else { return nil }
        var frames: [CIImage] = []
        var cum: [Double] = []
        var running = 0.0
        // Cap the cache: a long GIF must not pin hundreds of full frames.
        for (i, cg) in decoded.frames.prefix(60).enumerated() {
            let img = CIImage(cgImage: cg)
            frames.append(img.transformed(by: CGAffineTransform(translationX: -img.extent.minX,
                                                                y: -img.extent.minY)))
            running += max(decoded.delays[safeIndex: i] ?? 0.05, 0.02)
            cum.append(running)
        }
        guard !frames.isEmpty else { return nil }
        return (frames, cum, running)
    }

    private func stillImage(at url: URL) -> CIImage? {
        stateLock.lock()
        if let cached = stillCache[url] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        // Normalise the origin so downstream transforms can assume (0, 0).
        let normalised = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                                 y: -image.extent.minY))
        stateLock.lock()
        stillCache[url] = normalised
        stateLock.unlock()
        return normalised
    }
}


private extension Array {
    /// Bounds-safe read: a malformed GIF can report fewer delays than frames.
    subscript(safeIndex i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

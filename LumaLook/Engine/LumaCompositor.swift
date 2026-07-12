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
struct FrameMeta {
    let start: Double
    let end: Double
    /// Source preferredTransform (orientation normalisation).
    let transform: CGAffineTransform
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

    init(start: Double, end: Double, transform: CGAffineTransform,
         imageURL: URL? = nil, hasAnchorFrames: Bool = false,
         clipLookState: LookState? = nil) {
        self.start = start
        self.end = end
        self.transform = transform
        self.imageURL = imageURL
        self.hasAnchorFrames = hasAnchorFrames
        self.clipLookState = clipLookState
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
            let t = (offset - a.time) / span
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
}

// MARK: - Instruction

/// Carries everything `LumaVideoCompositor` needs for one time segment.
/// Segments are cut at photo-clip and overlay boundaries so
/// `requiredSourceTrackIDs` always matches what the segment actually reads.
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
    /// Reference type — live-updates the running preview, same trick as the
    /// old CI-handler closure capturing it.
    let lookState: LookState
    let renderSize: CGSize
    let zoomFactor: CGFloat

    init(timeRange: CMTimeRange,
         requiredSourceTrackIDs: [NSValue],
         mainTrackID: CMPersistentTrackID,
         frameMetas: [FrameMeta],
         transitionSpans: [TransitionSpanSpec],
         overlays: [OverlaySpec],
         overlayLayout: OverlayLayout,
         lookState: LookState,
         renderSize: CGSize,
         zoomFactor: CGFloat) {
        self.timeRange = timeRange
        // An empty ID list means "call the compositor with no source frames"
        // (photo-clip segments) — exactly what T7 needs.
        self.requiredSourceTrackIDs = requiredSourceTrackIDs
        self.mainTrackID = mainTrackID
        self.frameMetas = frameMetas
        self.transitionSpans = transitionSpans
        self.overlays = overlays
        self.overlayLayout = overlayLayout
        self.lookState = lookState
        self.renderSize = renderSize
        self.zoomFactor = zoomFactor
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

        var canvas: CIImage
        if let meta, let imageURL = meta.imageURL, let still = stillImage(at: imageURL) {
            canvas = aspectFill(still, into: renderSize, zoom: instruction.zoomFactor)
        } else if let sourceBuffer = request.sourceFrame(byTrackID: instruction.mainTrackID) {
            var image = CIImage(cvPixelBuffer: sourceBuffer)
            if let meta, !meta.transform.isIdentity {
                image = image.transformed(by: meta.transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                                y: -image.extent.minY))
            }
            canvas = aspectFill(image, into: renderSize, zoom: instruction.zoomFactor)
        } else {
            // No source and no still (e.g. race right at a boundary): black.
            canvas = CIImage(color: .black)
        }

        // --- Grade (same pipeline, split-wipe never baked in) --------------
        // Per-clip look wins over the timeline's global grade.
        let activeState = meta?.clipLookState ?? instruction.lookState
        var graded = pipeline.apply(state: activeState,
                                    to: canvas.clampedToExtent(),
                                    includeSplit: false)
            .cropped(to: renderRect)

        // --- Overlays: graded PIP layers composited over the base ----------
        for spec in instruction.overlays
        where seconds >= spec.start - 0.001 && seconds < spec.end + 0.001 {
            guard let placement = instruction.overlayLayout.placement(
                for: spec.id, at: seconds - spec.start) else { continue }

            var overlayImage: CIImage?
            if let imageURL = spec.imageURL {
                overlayImage = stillImage(at: imageURL)
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

            // Same look on the PIP as the base — one grade across the frame.
            overlay = pipeline.apply(state: activeState,
                                     to: overlay.clampedToExtent(),
                                     includeSplit: false)
                .cropped(to: overlay.extent)

            // Scale so the overlay's width is `sizeFraction` of the canvas.
            let fraction = min(max(placement.sizeFraction, 0.05), 1.0)
            let targetWidth = renderSize.width * CGFloat(fraction)
            let scale = targetWidth / overlay.extent.width
            overlay = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

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

            graded = overlay.composited(over: graded).cropped(to: renderRect)
        }

        // --- Transitions, applied last so they take the PIP with them ------
        if let span = instruction.transitionSpans.first(where: { abs(seconds - $0.center) < $0.half }) {
            if span.style.isCrossTransition {
                // True dissolve/wipe: blend the main frame with the OTHER
                // clip's frame (aux A/B-roll track, or a photo clip's still).
                let firstHalf = seconds < span.center
                var aux: CIImage?
                if let url = firstHalf ? span.headImageURL : span.tailImageURL,
                   let still = stillImage(at: url) {
                    aux = aspectFill(still, into: renderSize, zoom: instruction.zoomFactor)
                } else if span.auxTrackID != kCMPersistentTrackID_Invalid,
                          let buffer = request.sourceFrame(byTrackID: span.auxTrackID) {
                    var frame = CIImage(cvPixelBuffer: buffer)
                    let transform = firstHalf ? span.headTransform : span.tailTransform
                    if !transform.isIdentity {
                        frame = frame.transformed(by: transform)
                        frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX,
                                                                        y: -frame.extent.minY))
                    }
                    aux = aspectFill(frame, into: renderSize, zoom: instruction.zoomFactor)
                }
                if var auxImage = aux {
                    // The aux side wears ITS clip's grade (per-clip looks).
                    let auxState = (firstHalf ? span.headLookState : span.tailLookState)
                        ?? instruction.lookState
                    auxImage = pipeline.apply(state: auxState,
                                              to: auxImage.clampedToExtent(),
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

    /// Cross-transition blends. Dissolve: linear opacity mix. Wipe: a
    /// soft-edged left-to-right reveal of the incoming frame.
    private static func crossBlend(outgoing: CIImage, incoming: CIImage,
                                   progress: CGFloat, style: TransitionStyle,
                                   rect: CGRect) -> CIImage {
        let p = min(max(progress, 0), 1)
        switch style {
        case .wipe:
            let feather = rect.width * 0.05
            let edge = (rect.width + feather) * p - feather / 2
            let gradient = CIFilter.smoothLinearGradient()
            gradient.point0 = CGPoint(x: edge + feather / 2, y: 0)
            gradient.point1 = CGPoint(x: edge - feather / 2, y: 0)
            gradient.color0 = CIColor.black
            gradient.color1 = CIColor.white
            let mask = (gradient.outputImage ?? CIImage(color: .white)).cropped(to: rect)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = incoming
            blend.backgroundImage = outgoing
            blend.maskImage = mask
            return (blend.outputImage ?? incoming).cropped(to: rect)
        default:
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = outgoing
            dissolve.targetImage = incoming
            dissolve.time = Float(p)
            return (dissolve.outputImage ?? incoming).cropped(to: rect)
        }
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

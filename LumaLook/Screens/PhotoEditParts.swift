import SwiftUI
import CoreImage

// =============================================================================
// Parts for the photo editor (BeforeAfterView): the Original | Edited split
// stage, slim sliders, the bottom tool tabs, and crop and mask for stills.
//
// Crop and mask run on the photo itself, not in the grade: an edit replaces
// `AppModel.selectedImage` with an edited copy, so preview, export and the
// saved session all see it with no engine change. `PhotoEditSession` keeps
// the untouched photo, so either edit can be changed or undone.
// =============================================================================

// MARK: - Tools

/// The photo editor's bottom bar.
enum PhotoTool: String, CaseIterable, Identifiable {
    case looks, adjust, crop, mask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .looks:  return "Looks"
        case .adjust: return "Adjust"
        case .crop:   return "Crop"
        case .mask:   return "Mask"
        }
    }

    var icon: String {
        switch self {
        case .looks:  return "camera.filters"
        case .adjust: return "slider.horizontal.3"
        case .crop:   return "crop"
        case .mask:   return "circle.lefthalf.filled"
        }
    }

    /// DEBUG and preview seeding: LUMA_SEED_PHOTOTOOL=looks|adjust|crop|mask.
    static var seeded: PhotoTool {
        PhotoTool(rawValue: ProcessInfo.processInfo.environment["LUMA_SEED_PHOTOTOOL"] ?? "") ?? .adjust
    }
}

/// The colour panels from ColorGradingViews, opened from Adjust.
enum PhotoProPanel: String, CaseIterable, Identifiable {
    case curves, wheels, hsl, split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curves: return "Curves"
        case .wheels: return "Wheels"
        case .hsl:    return "HSL"
        case .split:  return "Split tone"
        }
    }
}

/// Crop shapes for a still, width over height.
enum PhotoCropRatio: String, CaseIterable, Identifiable {
    case original, square, portrait, story, classic, wide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .square:   return "1:1"
        case .portrait: return "4:5"
        case .story:    return "9:16"
        case .classic:  return "3:2"
        case .wide:     return "16:9"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square:   return 1
        case .portrait: return 4.0 / 5.0
        case .story:    return 9.0 / 16.0
        case .classic:  return 3.0 / 2.0
        case .wide:     return 16.0 / 9.0
        }
    }
}

// MARK: - Maths

enum PhotoEditMath {
    /// The largest centred crop of `image` at `ratio` (width / height), moved
    /// so its extent starts at zero. nil ratio returns the image itself.
    static func crop(_ image: CIImage, to ratio: CGFloat?) -> CIImage {
        let extent = image.extent
        guard let ratio, ratio > 0, !extent.isInfinite,
              extent.width > 1, extent.height > 1 else { return image }
        var w = extent.width
        var h = extent.height
        if w / h > ratio {
            w = (h * ratio).rounded(.down)
        } else {
            h = (w / ratio).rounded(.down)
        }
        let x = (extent.minX + (extent.width - w) / 2).rounded(.down)
        let y = (extent.minY + (extent.height - h) / 2).rounded(.down)
        let cropped = image.cropped(to: CGRect(x: x, y: y, width: w, height: h))
        return cropped.transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }

    /// Renders a lazy edit once, so a masked blur is not recomputed at full
    /// size on every preview frame.
    static func materialise(_ image: CIImage) -> CGImage? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return nil }
        return LookPipeline.shared.context.createCGImage(
            image, from: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Mask blur and mosaic sizes are in pixels. A preview drawn at `scale`
    /// of full size gets a smaller amount, so it matches what will be saved.
    static func previewSpec(_ spec: ClipMaskSpec, scale: CGFloat) -> ClipMaskSpec {
        guard scale > 0, scale < 0.999 else { return spec }
        var out = spec
        let s = Double(scale)
        switch spec.effect {
        case .blur:
            out.amount = max(0, (s * (4 + spec.amount * 40) - 4) / 40)
        case .mosaic:
            out.amount = max(0, (s * (4 + spec.amount * 60) - 4) / 60)
        case .fill:
            break
        }
        return out
    }

    /// A round blur in the middle of a frame of `aspect` (width / height).
    static func defaultMask(aspect: CGFloat) -> ClipMaskSpec {
        var spec = ClipMaskSpec()
        spec.shape = .ellipse
        spec.effect = .blur
        spec.center = CGPoint(x: 0.5, y: 0.5)
        spec.size = CGSize(width: 0.4, height: min(1, 0.4 * max(aspect, 0.1)))
        spec.feather = 0.05
        spec.amount = 0.6
        return spec
    }

    static func aspect(of image: CIImage?) -> CGFloat? {
        guard let extent = image?.extent, !extent.isInfinite,
              extent.width > 1, extent.height > 1 else { return nil }
        return extent.width / extent.height
    }

    /// "+0.4" for an exposure of 40. Zero reads as "0".
    static func exposureLabel(_ value: Double) -> String {
        let stops = (value / 10).rounded() / 10
        if stops == 0 { return "0" }
        return String(format: "%+.1f", stops)
    }

    /// "+12", "-6", "0".
    static func signedLabel(_ value: Double) -> String {
        let n = Int(value.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
}

// MARK: - Edit session

/// Crop and mask replace `AppModel.selectedImage` with an edited copy. This
/// keeps the untouched photo behind it, and starts over when a different
/// photo is picked.
@MainActor
final class PhotoEditSession {
    static let shared = PhotoEditSession()

    private(set) var pristine: CIImage?
    private var edited: CIImage?
    private(set) var ratio: PhotoCropRatio = .original
    private(set) var mask: ClipMaskSpec?

    /// Starts a new session unless `current` is the photo this session holds
    /// or made.
    func adopt(_ current: CIImage) {
        if let edited, edited === current { return }
        if let pristine, pristine === current { return }
        pristine = current
        edited = nil
        ratio = .original
        mask = nil
    }

    /// The untouched photo with `ratio` and `mask` applied, still lazy.
    /// Returns the untouched photo itself when there is nothing to apply.
    func edit(ratio: PhotoCropRatio, mask: ClipMaskSpec?) -> CIImage? {
        guard let pristine else { return nil }
        self.ratio = ratio
        self.mask = mask
        var out = PhotoEditMath.crop(pristine, to: ratio.ratio)
        if let mask {
            out = MaskRenderer.apply(mask, to: out, rect: out.extent)
        }
        return out
    }

    /// Records the image that went on stage, so `adopt` knows it.
    func commit(_ image: CIImage) {
        edited = (image === pristine) ? nil : image
    }

    /// The untouched photo cropped as it stands, for placing a mask.
    var croppedBase: CIImage? {
        guard let pristine else { return nil }
        return PhotoEditMath.crop(pristine, to: ratio.ratio)
    }
}

// MARK: - Slim slider

/// Name and value on one line, a 3 pt track beneath. Two-sided sliders fill
/// from the centre tick, like the photo edit mock.
struct SlimSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var bipolar: Bool = true
    var format: (Double) -> String = { PhotoEditMath.signedLabel($0) }

    private var span: Double { max(range.upperBound - range.lowerBound, 0.0001) }

    private var fraction: CGFloat {
        CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private var zero: CGFloat {
        CGFloat(min(max((0 - range.lowerBound) / span, 0), 1))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(LumaTheme.textSecondary)
                Spacer(minLength: 8)
                Text(format(value))
                    .font(.luma(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LumaTheme.textPrimary)
            }
            track
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let origin = bipolar ? zero : 0
            let low = min(fraction, origin)
            let high = max(fraction, origin)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LumaTheme.control)
                    .frame(height: 3)
                Capsule()
                    .fill(LumaTheme.textPrimary)
                    .frame(width: max(0, (high - low) * width), height: 3)
                    .offset(x: low * width)
                if bipolar {
                    Rectangle()
                        .fill(LumaTheme.textMuted)
                        .frame(width: 1, height: 11)
                        .offset(x: origin * width - 0.5)
                }
                Circle()
                    .fill(LumaTheme.textPrimary)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: fraction * width - 6)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let t = min(max(drag.location.x / max(width, 1), 0), 1)
                        value = range.lowerBound + Double(t) * span
                    }
            )
        }
        .frame(height: 20)
        .sensoryFeedback(.selection, trigger: Int((value / 10).rounded()))
    }
}

// MARK: - Split stage

/// The photo editor's picture: Original on the left of a draggable vertical
/// divider, Edited on the right, cut to the photo's own shape.
struct PhotoSplitStage: View {
    @EnvironmentObject private var app: AppModel

    let aspect: CGFloat
    /// The still on stage at full size. nil while a video plays.
    let still: CIImage?
    @Binding var split: CGFloat
    /// The untouched photo on its own (the Original segment, or a hold).
    var originalOnly: Bool = false
    /// Crop and mask show the whole edited frame, no divider.
    var fullFrame: Bool = false
    /// A mask being placed: previewed live and outlined.
    var mask: ClipMaskSpec? = nil
    /// Preview pixels per full-size pixel.
    var maskScale: CGFloat = 1
    let code: String
    let signature: Color
    let onHold: (Bool) -> Void
    /// Dragging while a mask is out moves it; called with a unit point.
    var onMaskMove: ((CGPoint) -> Void)? = nil

    @State private var previewSource: CIImage?
    @State private var original: CGImage?

    private var stillKey: String {
        guard let still else { return "video" }
        return "still-\(ObjectIdentifier(still))"
    }

    private var showsDivider: Bool { !originalOnly && !fullFrame && mask == nil }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.black
                layers(size: size)
                if showsDivider {
                    WipeHandle()
                        .frame(height: size.height)
                        .position(x: size.width * min(max(split, 0), 1), y: size.height / 2)
                        .allowsHitTesting(false)
                }
                if let mask, !originalOnly {
                    maskOutline(mask, size: size)
                }
                labels(size: size)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .holdOrDrag(dragEnabled: showsDivider || mask != nil,
                        onDrag: { point in drag(to: point, size: size) },
                        onHold: onHold)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .onAppear { syncStill() }
        .onChange(of: stillKey) { _, _ in syncStill() }
        .task(id: stillKey) { await renderOriginal() }
    }

    @ViewBuilder
    private func layers(size: CGSize) -> some View {
        if app.player == nil, let previewSource {
            originalLayer
                .frame(width: size.width, height: size.height)
            if !originalOnly {
                LiveGradedStill(source: previewSource, mask: mask, maskScale: maskScale)
                    .frame(width: size.width, height: size.height)
                    .clipShape(SplitRevealShape(fraction: showsDivider ? split : 0))
            }
        } else {
            // Video: the engine draws its own wipe from `splitFraction`.
            LookPreviewSurface(radius: 0, showsEmptyHint: false)
                .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder
    private var originalLayer: some View {
        if let original {
            Image(decorative: original, scale: 1)
                .resizable()
        } else {
            Color.black
        }
    }

    private func labels(size: CGSize) -> some View {
        HStack(alignment: .top) {
            stageLabel("Original", colour: LumaTheme.textPrimary)
                .opacity(showsDivider || originalOnly ? 1 : 0)
            Spacer(minLength: 0)
            if !originalOnly {
                stageLabel(code, colour: signature)
            }
        }
        .padding(10)
        .frame(width: size.width)
        .allowsHitTesting(false)
    }

    private func stageLabel(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.luma(size: 12, weight: .semibold))
            .foregroundStyle(colour)
            .lineLimit(1)
            .lumaGlassPill()
    }

    private func maskOutline(_ mask: ClipMaskSpec, size: CGSize) -> some View {
        let dash = StrokeStyle(lineWidth: 1.5, dash: [5, 4])
        return Group {
            if mask.shape == .ellipse {
                Ellipse().stroke(style: dash)
            } else {
                Rectangle().stroke(style: dash)
            }
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .frame(width: max(mask.size.width * size.width, 1),
               height: max(mask.size.height * size.height, 1))
        .position(x: mask.center.x * size.width, y: mask.center.y * size.height)
        .allowsHitTesting(false)
    }

    private func drag(to point: CGPoint, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        if mask != nil {
            onMaskMove?(CGPoint(x: min(max(point.x / size.width, 0), 1),
                                y: min(max(point.y / size.height, 0), 1)))
        } else {
            split = min(max(point.x / size.width, 0), 1)
        }
    }

    private func syncStill() {
        previewSource = still.map { StillCompare.downscaled($0) }
    }

    private func renderOriginal() async {
        guard let still else {
            original = nil
            return
        }
        let image = await Task.detached(priority: .userInitiated) {
            StillCompare.renderOriginal(still)
        }.value
        guard !Task.isCancelled else { return }
        original = image
    }
}

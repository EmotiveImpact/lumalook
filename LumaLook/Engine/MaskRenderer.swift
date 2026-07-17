import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Clip-level spot tools (F8): blur / mosaic / solid-fill confined to a shaped
/// region — privacy blurs, face mosaics, censor bars. Pure function of the spec
/// + rect, so preview and export match exactly; masks are cached because the
/// region only changes when the user drags it.
enum ClipMaskShape: String, Codable, CaseIterable {
    case rectangle, ellipse

    var label: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse:   return "Ellipse"
        }
    }
}

enum ClipMaskEffect: String, Codable, CaseIterable {
    case blur, mosaic, fill

    var label: String {
        switch self {
        case .blur:   return "Blur"
        case .mosaic: return "Mosaic"
        case .fill:   return "Fill"
        }
    }
    var icon: String {
        switch self {
        case .blur:   return "drop.fill"
        case .mosaic: return "squareshape.split.3x3"
        case .fill:   return "paintpalette.fill"
        }
    }
}

/// A spot region on a clip, in UNIT coordinates (y-down, UI convention).
struct ClipMaskSpec: Equatable {
    var shape: ClipMaskShape = .ellipse
    var effect: ClipMaskEffect = .blur
    var center = CGPoint(x: 0.5, y: 0.5)
    var size = CGSize(width: 0.3, height: 0.3)   // unit fractions
    var feather: Double = 0.05
    var amount: Double = 0.6      // blur radius / mosaic scale / fill alpha
    var fillHex: String = "#000000"
    var inverted: Bool = false    // apply OUTSIDE the region instead
}

enum MaskRenderer {
    private static let lock = NSLock()
    private static var maskCache: [String: CIImage] = [:]
    private static let maxEntries = 40
    /// Ceiling on the mask bitmap we'll allocate — and, critically, it keeps the
    /// `Int(_:)` rounding in `mask` well below its trapping threshold.
    /// Comfortably above any real frame (8K is 7680px wide).
    private static let maxDimension: CGFloat = 32768

    // MARK: - Entry point

    /// Applies the spot effect to `image` (extent == rect). Pure; cached masks.
    static func apply(_ spec: ClipMaskSpec, to image: CIImage, rect: CGRect) -> CIImage {
        // Sub-pixel rects would round to a zero-sized bitmap — nothing to mask.
        // Non-finite/absurd extents MUST bail here, before `mask` rounds them
        // through `Int(_:)`: `CGRect.infinite` reports a width of 1.79e308,
        // which sails past a bare `>= 1` test and then TRAPS (SIGTRAP) in the
        // Int conversion. Both `CIImage(color:)` and `.clampedToExtent()` report
        // an infinite extent, so a caller doing the natural
        // `apply(spec, to: img, rect: img.extent)` would hard-crash.
        // A non-finite origin would also poison `originShift`.
        guard rect.width.isFinite, rect.height.isFinite,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width >= 1, rect.height >= 1,
              rect.width <= maxDimension, rect.height <= maxDimension
        else { return image }
        // A failed mask must be a NO-OP, never a full-frame blur.
        guard let mask = mask(spec, rect: rect) else { return image }

        let affected = affectedCopy(spec, image: image, rect: rect)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = affected
        blend.backgroundImage = image
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: rect)
    }

    // MARK: - Affected copy

    /// The fully-processed frame; the mask decides where it actually lands.
    private static func affectedCopy(_ spec: ClipMaskSpec, image: CIImage, rect: CGRect) -> CIImage {
        let amount = min(max(spec.amount, 0), 1)
        switch spec.effect {
        case .blur:
            let blur = CIFilter.gaussianBlur()
            // Clamp first, else the blur drags transparency in from the edges.
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(4 + amount * 40)
            return (blur.outputImage ?? image).cropped(to: rect)

        case .mosaic:
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = image.clampedToExtent()
            pixellate.scale = Float(4 + amount * 60)
            // Anchor the block grid to the rect centre so blocks don't crawl.
            pixellate.center = CGPoint(x: rect.midX, y: rect.midY)
            return (pixellate.outputImage ?? image).cropped(to: rect)

        case .fill:
            let (r, g, b) = rgb(from: spec.fillHex)
            let colour = CIImage(color: CIColor(red: r, green: g, blue: b, alpha: amount))
                .cropped(to: rect)
            // Composite over the footage rather than handing blendWithMask a
            // semi-transparent input — that would punch a translucent hole in
            // the frame instead of tinting it.
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = colour
            over.backgroundImage = image
            return (over.outputImage ?? colour).cropped(to: rect)
        }
    }

    // MARK: - Mask

    /// Opaque black→white grayscale in rect-local space, shifted onto `rect`.
    /// `CIBlendWithMask` reads the mask's PREMULTIPLIED GREEN, so the canvas is
    /// opaque black rather than clear: a white-on-clear mask would still key
    /// correctly, but `CIColorInvert` leaves alpha at 0 and the inverted mask
    /// would silently no-op. Opaque keeps both paths honest.
    private static func mask(_ spec: ClipMaskSpec, rect: CGRect) -> CIImage? {
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let key = "\(spec.shape.rawValue)|\(spec.center.x)|\(spec.center.y)|"
            + "\(spec.size.width)|\(spec.size.height)|\(spec.feather)|\(spec.inverted)|\(w)x\(h)"

        lock.lock()
        if let cached = maskCache[key] { lock.unlock(); return cached.transformed(by: originShift(rect)) }
        lock.unlock()

        guard var image = buildMask(spec, w: w, h: h) else { return nil }
        if spec.inverted { image = image.applyingFilter("CIColorInvert") }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))

        lock.lock()
        if maskCache.count > maxEntries { maskCache.removeAll() }
        maskCache[key] = image
        lock.unlock()
        return image.transformed(by: originShift(rect))
    }

    private static func buildMask(_ spec: ClipMaskSpec, w: Int, h: Int) -> CIImage? {
        let fw = CGFloat(w), fh = CGFloat(h)
        // Unit y-down (UI) → CI y-up.
        let cx = spec.center.x * fw
        let cy = fh * (1 - spec.center.y)
        let sw = max(1, spec.size.width * fw)
        let sh = max(1, spec.size.height * fh)
        let shapeRect = CGRect(x: cx - sw / 2, y: cy - sh / 2, width: sw, height: sh)

        let full = CGRect(x: 0, y: 0, width: fw, height: fh)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(full)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        switch spec.shape {
        case .ellipse:   ctx.addEllipse(in: shapeRect); ctx.fillPath()
        case .rectangle: ctx.fill(shapeRect)
        }
        guard let cg = ctx.makeImage() else { return nil }

        var image = CIImage(cgImage: cg)
        let feather = max(0, spec.feather) * min(fw, fh)
        if feather > 0.5 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(feather)
            image = (blur.outputImage ?? image).cropped(to: full)
        }
        return image
    }

    // MARK: - Helpers

    private static func originShift(_ rect: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.minX, y: rect.minY)
    }

    private static func rgb(from hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (CGFloat((v >> 16) & 0xFF) / 255,
                CGFloat((v >> 8) & 0xFF) / 255,
                CGFloat(v & 0xFF) / 255)
    }
}

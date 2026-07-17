import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Generates cached alpha masks + border rings in an overlay's local extent.
/// Masks are drawn opaque-white-on-clear so `CIBlendWithAlphaMask` keeps the
/// shape and drops the rest — the same structure the text colorizer uses.
enum OverlayMaskRenderer {
    private static let lock = NSLock()
    private static var maskCache: [String: CIImage] = [:]
    private static var borderCache: [String: CIImage] = [:]
    private static let maxEntries = 40

    // MARK: - Mask

    static func mask(_ settings: OverlayMaskSettings, extent: CGRect) -> CIImage {
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        let key = "\(settings.shape)|\(settings.feather)|\(settings.cornerRadius)|\(settings.invert)|\(w)x\(h)"
        lock.lock()
        if let cached = maskCache[key] { lock.unlock(); return cached.transformed(by: originShift(extent)) }
        lock.unlock()

        var image = buildMask(settings, w: w, h: h)
        if settings.invert { image = image.applyingFilter("CIColorInvert") }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))

        lock.lock()
        if maskCache.count > maxEntries { maskCache.removeAll() }
        maskCache[key] = image
        lock.unlock()
        return image.transformed(by: originShift(extent))
    }

    private static func buildMask(_ s: OverlayMaskSettings, w: Int, h: Int) -> CIImage {
        let minDim = CGFloat(min(w, h))
        let feather = max(0, s.feather) * minDim / 2
        switch s.shape {
        case "linear":
            let g = CIFilter.smoothLinearGradient()
            g.point0 = CGPoint(x: 0, y: 0)
            g.point1 = CGPoint(x: CGFloat(w), y: 0)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            return (g.outputImage ?? CIImage.empty())
        case "ellipse":
            return featheredShape(w: w, h: h, feather: feather) { ctx, rect in
                ctx.addEllipse(in: rect); ctx.fillPath()
            }
        case "rect":
            return featheredShape(w: w, h: h, feather: feather) { ctx, rect in
                ctx.fill(rect)
            }
        default: // roundedRect
            let radius = max(0, s.cornerRadius) * minDim
            return featheredShape(w: w, h: h, feather: feather) { ctx, rect in
                let path = CGPath(roundedRect: rect, cornerWidth: radius,
                                  cornerHeight: radius, transform: nil)
                ctx.addPath(path); ctx.fillPath()
            }
        }
    }

    /// Draws an opaque white shape (inset by feather) on a clear canvas, then
    /// Gaussian-blurs the alpha edge by `feather` and re-crops.
    private static func featheredShape(w: Int, h: Int, feather: CGFloat,
                                       draw: (CGContext, CGRect) -> Void) -> CIImage {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let inset = feather
        draw(ctx, CGRect(x: inset, y: inset,
                         width: CGFloat(w) - 2 * inset, height: CGFloat(h) - 2 * inset))
        guard let cg = ctx.makeImage() else {
            return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var img = CIImage(cgImage: cg)
        if feather > 0.5 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = img.clampedToExtent()
            blur.radius = Float(feather)
            img = (blur.outputImage ?? img).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return img
    }

    // MARK: - Border ring (F7)

    /// A solid ring hugging the overlay edge, hole-punched so only the frame
    /// shows. Composited UNDER the overlay so the overlay sits inside it.
    static func borderRing(_ settings: OverlayBorderSettings, extent: CGRect) -> CIImage {
        let w = Int(extent.width.rounded()), h = Int(extent.height.rounded())
        let key = "\(settings.widthFraction)|\(settings.colorHex)|\(settings.cornerRadiusFraction)|\(w)x\(h)"
        lock.lock()
        if let cached = borderCache[key] { lock.unlock(); return cached.transformed(by: originShift(extent)) }
        lock.unlock()

        let minDim = CGFloat(min(w, h))
        let ringWidth = max(1, settings.widthFraction * minDim)
        let radius = max(0, settings.cornerRadiusFraction) * minDim
        let (r, g, b) = rgb(from: settings.colorHex)

        let space = CGColorSpaceCreateDeviceRGB()
        var image = CIImage.empty()
        if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            // Outer filled shape.
            let outer = CGRect(x: 0, y: 0, width: w, height: h)
            let outerPath = radius > 0
                ? CGPath(roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: outer, transform: nil)
            ctx.addPath(outerPath); ctx.fillPath()
            // Punch the hole (clear).
            let innerRect = outer.insetBy(dx: ringWidth, dy: ringWidth)
            let innerRadius = max(0, radius - ringWidth)
            let innerPath = innerRadius > 0
                ? CGPath(roundedRect: innerRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
                : CGPath(rect: innerRect, transform: nil)
            ctx.setBlendMode(.clear)
            ctx.addPath(innerPath); ctx.fillPath()
            if let cg = ctx.makeImage() { image = CIImage(cgImage: cg) }
        }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))

        lock.lock()
        if borderCache.count > maxEntries { borderCache.removeAll() }
        borderCache[key] = image
        lock.unlock()
        return image.transformed(by: originShift(extent))
    }

    // MARK: - Helpers

    private static func originShift(_ extent: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: extent.minX, y: extent.minY)
    }

    private static func rgb(from hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (1, 1, 1) }
        return (CGFloat((v >> 16) & 0xFF) / 255,
                CGFloat((v >> 8) & 0xFF) / 255,
                CGFloat(v & 0xFF) / 255)
    }
}

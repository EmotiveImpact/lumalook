import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// C9 — zebras: diagonal stripes over pixels brighter than the clip
/// threshold, the standard "you are blowing highlights" warning when
/// exposing flat/Log where clipping isn't obvious by eye.
///
/// Preview-only; deterministic (fixed stripe phase, no time input).
enum ZebraRenderer {

    private static let lock = NSLock()
    private static var stripeCache: [String: CIImage] = [:]

    /// Overlay `image` with zebra stripes wherever luma ≥ `ire` (0…1,
    /// e.g. 0.95 for 95 IRE).
    static func apply(to image: CIImage, ire: Double = 0.95) -> CIImage {
        let rect = image.extent
        guard rect.width > 1, rect.height > 1, rect.isFinite else { return image }

        // Luma ≥ threshold → alpha mask with a steep step.
        let t = min(max(ire, 0.5), 0.99)
        let mask = image.applyingFilter("CIColorMatrix", parameters: [
            // Alpha := luma(RGB); RGB := 0 — see FocusPeakingRenderer for the
            // row-semantics trap this fixes.
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        ]).applyingFilter("CIColorPolynomial", parameters: [
            "inputAlphaCoefficients": CIVector(x: -t * 40, y: 40, z: 0, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        // Diagonal stripe sheet, cached per size.
        let stripeSheet = stripes(for: rect.size).transformed(
            by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

        let zebra = stripeSheet.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask.cropped(to: rect),
        ])
        return zebra.composited(over: image).cropped(to: rect)
    }

    /// White 45° stripes on transparent, ~8pt pitch. CoreGraphics-drawn once
    /// per size; the render queue only ever composites the cached sheet.
    private static func stripes(for size: CGSize) -> CIImage {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let key = "\(w)x\(h)"
        lock.lock()
        if let hit = stripeCache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage.empty() }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.7))
        ctx.setLineWidth(3)
        let pitch = 8
        var x = -h
        while x < w + h {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x + h, y: h))
            ctx.strokePath()
            x += pitch
        }
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let image = CIImage(cgImage: cg)
        lock.lock()
        if stripeCache.count > 6 { stripeCache.removeAll() }
        stripeCache[key] = image
        lock.unlock()
        return image
    }
}

private extension CGRect {
    var isFinite: Bool { width.isFinite && height.isFinite && minX.isFinite && minY.isFinite }
}

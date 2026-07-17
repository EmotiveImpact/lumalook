import CoreImage
import CoreGraphics
import UIKit

/// Project-level frame / border presets.
///
/// Composited LAST in the render loop — after grading, overlays and
/// transitions — so a wipe or a veil can never run across the border itself.
enum FramePreset: String, CaseIterable, Codable {
    case none, thinWhite, thinBlack, matte, polaroid, film16, letterbox

    var label: String {
        switch self {
        case .none:      return "None"
        case .thinWhite: return "Thin White"
        case .thinBlack: return "Thin Black"
        case .matte:     return "Matte"
        case .polaroid:  return "Polaroid"
        case .film16:    return "16mm"
        case .letterbox: return "Letterbox"
        }
    }

    var icon: String {
        switch self {
        case .none:      return "slash.circle"
        case .thinWhite: return "square"
        case .thinBlack: return "square.fill"
        case .matte:     return "square.inset.filled"
        case .polaroid:  return "photo"
        case .film16:    return "film"
        case .letterbox: return "rectangle.compress.vertical"
        }
    }
}

/// Draws the frame presets. Everything is derived fractionally from `rect`, so
/// a 4K export inherits the exact preview geometry for free.
enum FrameRenderer {

    /// Composites `preset` over `image` (whose extent is `rect`).
    static func apply(_ preset: FramePreset, to image: CIImage, rect: CGRect) -> CIImage {
        guard preset != .none, rect.width > 1, rect.height > 1 else { return image }
        let d = min(rect.width, rect.height)

        switch preset {
        case .none:
            return image
        case .thinWhite:
            return matted(image, rect: rect, inset: d * 0.02, ground: .white)
        case .thinBlack:
            return matted(image, rect: rect, inset: d * 0.02, ground: .black)
        case .matte:
            // Warm gallery white — pure #FFF reads clinical against footage.
            return matted(image, rect: rect, inset: d * 0.06,
                          ground: CIColor(red: 0.957, green: 0.945, blue: 0.918))
        case .polaroid:
            return polaroid(image, rect: rect)
        case .film16:
            return film16(image, rect: rect)
        case .letterbox:
            return letterboxed(image, rect: rect)
        }
    }

    // MARK: - Presets

    /// Uniform border: scale to fit the inset box, centre it on a solid ground.
    private static func matted(_ image: CIImage, rect: CGRect,
                               inset: CGFloat, ground: CIColor) -> CIImage {
        let box = rect.insetBy(dx: inset, dy: inset)
        return fit(image, from: rect, into: box)
            .composited(over: CIImage(color: ground).cropped(to: rect))
            .cropped(to: rect)
    }

    /// Classic polaroid: even margin on three sides, a deep chin at the bottom.
    /// CI is y-up, so the chin lives at `minY`.
    private static func polaroid(_ image: CIImage, rect: CGRect) -> CIImage {
        let d = min(rect.width, rect.height)
        let side = d * 0.06
        let chin = d * 0.20
        let box = CGRect(x: rect.minX + side,
                         y: rect.minY + chin,
                         width: rect.width - side * 2,
                         height: rect.height - side - chin)
        guard box.width > 1, box.height > 1 else { return image }
        let ground = CIImage(color: CIColor(red: 0.98, green: 0.98, blue: 0.965))
            .cropped(to: rect)
        return fit(image, from: rect, into: box)
            .composited(over: ground)
            .cropped(to: rect)
    }

    /// 16mm: black stock with sprocket strips down both edges.
    private static func film16(_ image: CIImage, rect: CGRect) -> CIImage {
        let strip = rect.width * 0.09
        let box = CGRect(x: rect.minX + strip, y: rect.minY,
                         width: rect.width - strip * 2, height: rect.height)
        guard box.width > 1 else { return image }
        let ground = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.045))
            .cropped(to: rect)
        var out = fit(image, from: rect, into: box)
            .composited(over: ground)
            .cropped(to: rect)
        if let holes = sprockets(rect: rect, strip: strip) {
            out = CIImage(cgImage: holes)
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                .composited(over: out)
                .cropped(to: rect)
        }
        return out
    }

    /// Cinematic bars — drawn OVER the footage (no rescale), the way a
    /// 2.39:1 crop actually reads.
    private static func letterboxed(_ image: CIImage, rect: CGRect) -> CIImage {
        let bar = rect.height * 0.12
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        let top = black.cropped(to: CGRect(x: rect.minX, y: rect.maxY - bar,
                                           width: rect.width, height: bar))
        let bottom = black.cropped(to: CGRect(x: rect.minX, y: rect.minY,
                                              width: rect.width, height: bar))
        return top.composited(over: bottom.composited(over: image)).cropped(to: rect)
    }

    // MARK: - Geometry

    /// Aspect-fit `image` (extent `from`) centred inside `box`.
    private static func fit(_ image: CIImage, from: CGRect, into box: CGRect) -> CIImage {
        guard from.width > 0, from.height > 0 else { return image }
        let s = min(box.width / from.width, box.height / from.height)
        let w = from.width * s, h = from.height * s
        let tx = box.midX - (from.minX * s + w / 2)
        let ty = box.midY - (from.minY * s + h / 2)
        return image
            .transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: tx, y: ty)))
            .cropped(to: box)
    }

    // MARK: - Sprocket cache

    private static let lock = NSLock()
    private static var cache: [String: CGImage] = [:]

    /// Transparent layer carrying just the perforations, cached per size —
    /// this is called every frame on the render queue.
    private static func sprockets(rect: CGRect, strip: CGFloat) -> CGImage? {
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let key = "\(w)x\(h)"

        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

        // Perf geometry: ~5% of height per hole, evenly pitched down both edges.
        let holeH = rect.height * 0.045
        let holeW = strip * 0.5
        let pitch = holeH * 2.0
        let count = max(1, Int(rect.height / pitch))
        let radius = holeW * 0.22
        ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.9, alpha: 1))

        for i in 0..<count {
            let cy = (CGFloat(i) + 0.5) * pitch
            guard cy + holeH / 2 <= rect.height else { break }
            for cx in [strip / 2, rect.width - strip / 2] {
                let r = CGRect(x: cx - holeW / 2, y: cy - holeH / 2,
                               width: holeW, height: holeH)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
        }

        guard let img = ctx.makeImage() else { return nil }
        lock.lock()
        if cache.count > 8 { cache.removeAll() }   // only ever a couple of sizes
        cache[key] = img
        lock.unlock()
        return img
    }
}

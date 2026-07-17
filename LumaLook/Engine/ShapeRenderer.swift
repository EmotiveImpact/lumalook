import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// The vector primitives a shape overlay can be. Raw values are persisted, so
/// they are contract — rename the `label`, never the `case`.
enum ShapeKind: String, Codable, CaseIterable {
    case rectangle, roundedRect, ellipse, triangle, star, arrow, speechBubble, line

    var label: String {
        switch self {
        case .rectangle:    return "Rectangle"
        case .roundedRect:  return "Rounded"
        case .ellipse:      return "Ellipse"
        case .triangle:     return "Triangle"
        case .star:         return "Star"
        case .arrow:        return "Arrow"
        case .speechBubble: return "Callout"
        case .line:         return "Line"
        }
    }

    /// SF Symbol for the picker row.
    var icon: String {
        switch self {
        case .rectangle:    return "rectangle"
        case .roundedRect:  return "app"
        case .ellipse:      return "oval"
        case .triangle:     return "triangle"
        case .star:         return "star"
        case .arrow:        return "arrow.right"
        case .speechBubble: return "bubble.left"
        case .line:         return "minus"
        }
    }
}

/// Everything that determines a shape's pixels. Fractions (not points) so a
/// spec survives being resized — the renderer scales them against `size`.
struct ShapeSpec: Equatable {
    var kind: ShapeKind = .rectangle
    var fillHex: String? = "#FFFFFF"    // nil = no fill
    var strokeHex: String? = nil
    var strokeWidth: CGFloat = 0
    var cornerRadius: CGFloat = 0.12    // fraction of min dimension
    var rotationDegrees: Double = 0
}

/// Rasterises shape/callout/arrow overlays into transparent CIImages.
/// Pure function of (spec, size) → cacheable, and identical in preview and
/// export. Called from the compositor render queue, so the cache is NSLock'd.
///
/// Output sits at origin (0, 0) in CI coordinates (y-up, matching the CGContext
/// it was drawn in); the caller transforms it into the overlay's extent.
enum ShapeRenderer {
    private static let lock = NSLock()
    private static var cache: [String: CIImage] = [:]
    private static let maxEntries = 40
    /// Guards against a rogue extent asking for a gigabyte of bitmap.
    private static let maxDimension = 4096

    // MARK: - Entry point

    /// Renders the shape into a transparent CIImage of `size` (origin 0,0).
    /// Returns nil when there is nothing to paint (no fill AND no stroke) or
    /// the size/context is unusable — the caller then simply skips the overlay.
    static func image(_ spec: ShapeSpec, size: CGSize) -> CIImage? {
        // Vet the size BEFORE narrowing to Int: `Int(_:)` traps on NaN, on
        // ±infinity, and on anything past Int.max, so the dimension guard below
        // can't be the first line of defence. A degenerate overlay extent
        // (0-height divide) hands us NaN, and that must be a nil, not a crash.
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0,
              size.width <= CGFloat(maxDimension) + 1,
              size.height <= CGFloat(maxDimension) + 1 else { return nil }
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, w <= maxDimension, h <= maxDimension else { return nil }

        let fill = spec.fillHex.flatMap(cgColor(from:))
        // Clamp the stroke to a third of the short side: a fat stroke on a small
        // render (thumbnails) would otherwise inset the path out of existence.
        let strokeWidth = min(max(0, spec.strokeWidth), CGFloat(min(w, h)) / 3)
        let stroke = strokeWidth > 0 ? spec.strokeHex.flatMap(cgColor(from:)) : nil
        guard fill != nil || stroke != nil else { return nil }

        let key = cacheKey(spec, w: w, h: h)
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        guard let image = render(spec, w: w, h: h,
                                 fill: fill, stroke: stroke, strokeWidth: strokeWidth) else {
            return nil
        }

        lock.lock()
        if cache.count > maxEntries { cache.removeAll() }
        cache[key] = image
        lock.unlock()
        return image
    }

    // MARK: - Drawing

    private static func render(_ spec: ShapeSpec, w: Int, h: Int,
                               fill: CGColor?, stroke: CGColor?,
                               strokeWidth: CGFloat) -> CIImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        ctx.clear(canvas)
        ctx.setShouldAntialias(true)

        // A stroke straddles the path, so inset by half of it to keep the ink
        // inside the canvas rather than clipped at the edge.
        let inset = (stroke != nil) ? strokeWidth / 2 : 0
        let rect = canvas.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return nil }

        // Rotate about the centre. Corners of a rotated shape can fall outside
        // the canvas and clip — that is the caller's extent to size, not ours.
        ctx.saveGState()
        if spec.rotationDegrees != 0 {
            ctx.translateBy(x: canvas.midX, y: canvas.midY)
            ctx.rotate(by: CGFloat(spec.rotationDegrees) * .pi / 180)
            ctx.translateBy(x: -canvas.midX, y: -canvas.midY)
        }

        let path = buildPath(spec, in: rect)
        ctx.addPath(path)
        if let fill { ctx.setFillColor(fill) }
        if let stroke {
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(strokeWidth)
            ctx.setLineJoin(.round)
        }
        let mode: CGPathDrawingMode
        switch (fill != nil, stroke != nil) {
        case (true, true):  mode = .fillStroke
        case (true, false): mode = .fill
        default:            mode = .stroke
        }
        ctx.drawPath(using: mode)
        ctx.restoreGState()

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    // MARK: - Paths

    private static func buildPath(_ spec: ShapeSpec, in rect: CGRect) -> CGPath {
        switch spec.kind {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)

        case .roundedRect:
            let r = cornerRadius(spec.cornerRadius, in: rect)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)

        case .triangle:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))   // apex, y-up
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
            return p

        case .star:
            return starPath(in: rect)

        case .arrow:
            return arrowPath(in: rect)

        case .speechBubble:
            return speechBubblePath(in: rect, cornerFraction: spec.cornerRadius)

        case .line:
            // A thin centred bar. Thickness is a fraction of the height — NOT
            // strokeWidth, which stays "outline width" for every kind, else
            // dragging the stroke slider would make the line thinner.
            // Users set line weight by sizing the overlay.
            let thickness = min(rect.height, max(1, rect.height * 0.14))
            let bar = CGRect(x: rect.minX, y: rect.midY - thickness / 2,
                             width: rect.width, height: thickness)
            return CGPath(rect: bar, transform: nil)
        }
    }

    /// Classic 5-point star: 10 vertices alternating outer/inner radius every
    /// 36°, starting at 12 o'clock. Radii are per-axis so it fills a non-square.
    private static func starPath(in rect: CGRect) -> CGPath {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let innerRatio: CGFloat = 0.382    // golden-ish; the shape everyone reads as "star"
        let p = CGMutablePath()
        for i in 0..<10 {
            let angle = CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
            let ix = (i % 2 == 0) ? rx : rx * innerRatio
            let iy = (i % 2 == 0) ? ry : ry * innerRatio
            let pt = CGPoint(x: cx + ix * cos(angle), y: cy + iy * sin(angle))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    /// Shaft + head as one 7-point polygon (single outline → strokes cleanly).
    /// Points right at 0°; rotation does the rest.
    private static func arrowPath(in rect: CGRect) -> CGPath {
        let cy = rect.midY
        let headHalf = rect.height / 2
        let shaftHalf = max(0.5, rect.height * 0.18)
        let headLen = min(rect.width, min(rect.width * 0.42, rect.height))
        let neckX = rect.maxX - headLen
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX, y: cy + shaftHalf))
        p.addLine(to: CGPoint(x: neckX, y: cy + shaftHalf))
        p.addLine(to: CGPoint(x: neckX, y: cy + headHalf))
        p.addLine(to: CGPoint(x: rect.maxX, y: cy))          // tip
        p.addLine(to: CGPoint(x: neckX, y: cy - headHalf))
        p.addLine(to: CGPoint(x: neckX, y: cy - shaftHalf))
        p.addLine(to: CGPoint(x: rect.minX, y: cy - shaftHalf))
        p.closeSubpath()
        return p
    }

    /// Rounded body + a tail at the bottom-left, built as ONE continuous path.
    /// (Union-ing two subpaths would fill fine but stroke a seam across the
    /// tail's mouth, so the outline is walked by hand.)
    private static func speechBubblePath(in rect: CGRect, cornerFraction: CGFloat) -> CGPath {
        let tailH = rect.height * 0.22
        let body = CGRect(x: rect.minX, y: rect.minY + tailH,
                          width: rect.width, height: rect.height - tailH)
        guard body.height > 0 else { return CGPath(rect: rect, transform: nil) }
        let r = cornerRadius(cornerFraction, in: body)

        // Keep the tail clear of the bottom-left corner arc, and inside the
        // bottom-right one — on a very narrow bubble it simply gets squeezed.
        let mouthW = min(body.width * 0.22, max(0, body.width - 2 * r))
        let tailLeft = min(max(body.minX + r, body.minX + body.width * 0.18),
                           max(body.minX + r, body.maxX - r - mouthW))
        let tailRight = tailLeft + mouthW
        let tipX = max(body.minX, tailLeft - body.width * 0.06)

        let p = CGMutablePath()
        p.move(to: CGPoint(x: body.minX, y: body.minY + r))
        // Left edge up, then clockwise round the top.
        p.addLine(to: CGPoint(x: body.minX, y: body.maxY - r))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                 tangent2End: CGPoint(x: body.minX + r, y: body.maxY), radius: r)
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                 tangent2End: CGPoint(x: body.maxX, y: body.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: body.maxX, y: body.minY + r))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                 tangent2End: CGPoint(x: body.maxX - r, y: body.minY), radius: r)
        // Bottom edge leftwards, detouring down through the tail.
        if mouthW > 0 {
            p.addLine(to: CGPoint(x: tailRight, y: body.minY))
            p.addLine(to: CGPoint(x: tipX, y: rect.minY))
            p.addLine(to: CGPoint(x: tailLeft, y: body.minY))
        }
        p.addLine(to: CGPoint(x: body.minX + r, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                 tangent2End: CGPoint(x: body.minX, y: body.minY + r), radius: r)
        p.closeSubpath()
        return p
    }

    // MARK: - Helpers

    /// `fraction` of the min dimension, clamped so CGPath never gets a radius
    /// larger than half the side (which it rejects).
    private static func cornerRadius(_ fraction: CGFloat, in rect: CGRect) -> CGFloat {
        let minDim = min(rect.width, rect.height)
        return min(max(0, fraction) * minDim, minDim / 2)
    }

    private static func cacheKey(_ spec: ShapeSpec, w: Int, h: Int) -> String {
        "\(spec.kind.rawValue)|\(spec.fillHex ?? "-")|\(spec.strokeHex ?? "-")|"
        + "\(spec.strokeWidth)|\(spec.cornerRadius)|\(spec.rotationDegrees)|\(w)x\(h)"
    }

    /// #RGB / #RRGGBB / #RRGGBBAA → CGColor. nil on anything unparseable, which
    /// the caller reads as "don't paint this".
    private static func cgColor(from hex: String) -> CGColor? {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 8 {
            return CGColor(red: CGFloat((v >> 24) & 0xFF) / 255,
                           green: CGFloat((v >> 16) & 0xFF) / 255,
                           blue: CGFloat((v >> 8) & 0xFF) / 255,
                           alpha: CGFloat(v & 0xFF) / 255)
        }
        return CGColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255,
                       alpha: 1)
    }
}

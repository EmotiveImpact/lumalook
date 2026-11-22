import Foundation
import CoreImage
import CoreGraphics
import CoreText
import UIKit

/// What the export's edge strip prints: the look's code and name in its
/// signature colour, and a frame counter at the export's frame rate.
struct EdgeStripSpec: Equatable {
    /// Stock code, "KD2" from "KD2 · Golden Hour"; "LL" when the look has none.
    var code: String
    /// Look name, printed in capitals.
    var title: String
    /// Signature colour, sRGB 0…1.
    var red: Double = 1
    var green: Double = 0.773
    var blue: Double = 0.239
    /// Frames per second the counter counts in.
    var fps: Int = 30
}

/// Burns a thin film-rebate strip along one edge of each exported frame:
/// sprocket marks, "LUMALOOK" with the look's code and name, and a running
/// frame counter. Landscape frames get it along the bottom, portrait and
/// square frames down the left. Drawn over the picture, last, so nothing is
/// rescaled. Runs on the compositor's render queue: the fixed part of the
/// strip is drawn once per size and cached; only the counter is drawn per
/// frame.
enum EdgeStripRenderer {

    /// Composites the strip over `image` (whose extent is `rect`) for the
    /// frame at `seconds`.
    static func apply(_ spec: EdgeStripSpec, to image: CIImage, rect: CGRect,
                      seconds: Double) -> CIImage {
        guard rect.width > 32, rect.height > 32 else { return image }
        let landscape = rect.width > rect.height
        let length = Int((landscape ? rect.width : rect.height).rounded())
        let thickness = max(14, Int((min(rect.width, rect.height) * 0.045).rounded()))
        guard let base = baseStrip(spec, length: length, thickness: thickness) else { return image }

        var strip = CIImage(cgImage: base)
        let fps = max(1, spec.fps)
        let frame = max(0, Int(seconds * Double(fps) + 0.001))
        if let counter = counterImage(frame, spec: spec, thickness: thickness) {
            // Right-hand end of the strip, on the text line.
            let x = CGFloat(length) - CGFloat(counter.width) - CGFloat(thickness) * 0.5
            strip = CIImage(cgImage: counter)
                .transformed(by: CGAffineTransform(translationX: max(0, x), y: 0))
                .composited(over: strip)
        }

        // The strip is drawn lying flat, outer edge at y = 0. Landscape uses
        // it as is along the bottom; portrait turns it a quarter clockwise so
        // the outer edge sits on the left and the print runs down the frame.
        let placed: CIImage
        if landscape {
            placed = strip.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        } else {
            let turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
            placed = strip
                .transformed(by: turn)
                .transformed(by: CGAffineTransform(translationX: rect.minX,
                                                   y: rect.minY + CGFloat(length)))
        }
        return placed.composited(over: image).cropped(to: rect)
    }

    // MARK: - Fixed part

    private static let lock = NSLock()
    private static var baseCache: [String: CGImage] = [:]

    /// Ink ground, sprocket marks and the label, cached per size and look.
    private static func baseStrip(_ spec: EdgeStripSpec, length: Int, thickness: Int) -> CGImage? {
        let key = "\(length)x\(thickness)|\(spec.code)|\(spec.title)|\(spec.red),\(spec.green),\(spec.blue)"
        lock.lock()
        if let hit = baseCache[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let ctx = context(width: length, height: thickness) else { return nil }
        let w = CGFloat(length), s = CGFloat(thickness)

        // Ground: Night Lab ink, a touch see-through so the strip reads as
        // printed on the frame rather than pasted over it.
        ctx.setFillColor(CGColor(red: 0.031, green: 0.035, blue: 0.039, alpha: 0.94))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: s))
        // Hairline where the strip meets the picture.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
        ctx.fill(CGRect(x: 0, y: s - max(1, s * 0.03), width: w, height: max(1, s * 0.03)))

        // Sprocket marks along the outer half.
        let holeW = s * 0.42
        let holeH = s * 0.3
        let pitch = s * 0.95
        let holeY = s * 0.1
        let radius = holeH * 0.28
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.2))
        var x = s * 0.4
        while x + holeW <= w - s * 0.2 {
            let hole = CGRect(x: x, y: holeY, width: holeW, height: holeH)
            ctx.addPath(CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            x += pitch
        }

        // Label on the inner half: LUMALOOK, then code and name in the
        // look's colour, with a small triangle as the film's edge mark.
        let fontSize = s * 0.3
        let baseline = s * 0.56
        let signature = CGColor(red: spec.red, green: spec.green, blue: spec.blue, alpha: 1)
        let muted = CGColor(red: 0.64, green: 0.65, blue: 0.68, alpha: 1)
        var pen = s * 0.5
        pen += drawText("▸", at: CGPoint(x: pen, y: baseline), size: fontSize, colour: signature, in: ctx)
        pen += s * 0.25
        pen += drawText("LUMALOOK", at: CGPoint(x: pen, y: baseline), size: fontSize,
                        colour: muted, in: ctx, weight: .semibold)
        pen += s * 0.45
        let look = spec.title.isEmpty ? spec.code : "\(spec.code)  \(spec.title.uppercased())"
        _ = drawText(look, at: CGPoint(x: pen, y: baseline), size: fontSize,
                     colour: signature, in: ctx, weight: .semibold)

        guard let image = ctx.makeImage() else { return nil }
        lock.lock()
        if baseCache.count > 6 { baseCache.removeAll() }
        baseCache[key] = image
        lock.unlock()
        return image
    }

    // MARK: - Counter

    /// The frame number, six digits, on its own patch of ground so a long
    /// look name never runs underneath it.
    private static func counterImage(_ frame: Int, spec: EdgeStripSpec, thickness: Int) -> CGImage? {
        let s = CGFloat(thickness)
        let text = String(format: "%06d", frame % 1_000_000)
        let fontSize = s * 0.3
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let textWidth = width(of: text, font: font)
        let w = Int((textWidth + s * 0.5).rounded(.up))
        guard w > 0, let ctx = context(width: w, height: thickness) else { return nil }
        ctx.setFillColor(CGColor(red: 0.031, green: 0.035, blue: 0.039, alpha: 0.94))
        ctx.fill(CGRect(x: 0, y: s * 0.46, width: CGFloat(w), height: s * 0.48))
        let white = CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 0.92)
        _ = drawText(text, at: CGPoint(x: s * 0.25, y: s * 0.56), size: fontSize,
                     colour: white, in: ctx, font: font)
        return ctx.makeImage()
    }

    // MARK: - Drawing helpers

    private static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    private static func attributed(_ text: String, font: UIFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .kern: font.pointSize * 0.08,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
    }

    private static func width(of text: String, font: UIFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Draws one line of text with its baseline at `point` (y up) and
    /// returns its width.
    @discardableResult
    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat,
                                 colour: CGColor, in ctx: CGContext,
                                 weight: UIFont.Weight = .regular,
                                 font: UIFont? = nil) -> CGFloat {
        let face = font ?? UIFont.systemFont(ofSize: size, weight: weight)
        let line = CTLineCreateWithAttributedString(attributed(text, font: face))
        ctx.saveGState()
        ctx.setFillColor(colour)
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

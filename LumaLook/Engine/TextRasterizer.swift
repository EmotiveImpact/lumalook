import CoreGraphics
import CoreImage
import UIKit

/// Everything that changes how a text layer looks. Value type so it doubles as
/// the cache identity — two specs that compare equal must rasterise identically.
struct TextStyleSpec: Equatable {
    var fontName: String = "HelveticaNeue-Bold"
    var pointSize: CGFloat = 96
    var colorHex: String = "#FFFFFF"
    var strokeColorHex: String? = nil     // nil = no stroke
    var strokeWidth: CGFloat = 0          // points
    var boxColorHex: String? = nil        // nil = no background box
    var boxCornerRadius: CGFloat = 12
    var boxPadding: CGFloat = 18
    var alignment: String = "center"      // left | center | right
    var lineSpacing: CGFloat = 1.1
}

/// Core Text/UIKit string rasteriser for title + caption layers. Replaces
/// `CITextImageGenerator`, which can't do stroke, background boxes, multi-line
/// alignment, or arbitrary registered fonts. String drawing is thread-safe and
/// needs no main actor, so this runs on the compositor's render queue exactly
/// like the CI path it supersedes. Pure function of (text, style) → cacheable.
enum TextRasterizer {
    private static let lock = NSLock()
    private static var cache: [String: CIImage] = [:]
    private static let cacheLimit = 40
    /// Hard ceiling on any dimension — a runaway point size must not try to
    /// allocate a gigabyte on the render queue.
    private static let maxCanvas: CGFloat = 4096

    /// Rasterises `text` to a transparent CIImage (origin at 0,0). Cached by (text|style).
    static func image(_ text: String, style: TextStyleSpec) -> CIImage? {
        guard !text.isEmpty, style.pointSize > 0 else { return nil }

        let key = cacheKey(text, style)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let rendered = render(text, style) else { return nil }

        lock.lock()
        // Text edits churn keys; keep the cache bounded.
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = rendered
        lock.unlock()
        return rendered
    }

    // MARK: - Rendering

    private static func render(_ text: String, _ style: TextStyleSpec) -> CIImage? {
        let attributed = attributedString(text, style)
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxCanvas, height: maxCanvas),
            options: options,
            context: nil)

        // boundingRect returns fractional sizes; ceil or the last column clips.
        let textSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        guard textSize.width >= 1, textSize.height >= 1 else { return nil }

        // The stroke straddles the glyph outline, so reserve half of it beyond
        // the measured box (round up to full width — cheap, and safe for the
        // stroke joins on sharp glyph corners, which overshoot the half-width).
        let pad = max(0, style.boxPadding) + max(0, style.strokeWidth)
        let canvas = CGSize(
            width: min(textSize.width + pad * 2, maxCanvas),
            height: min(textSize.height + pad * 2, maxCanvas))
        let pixelWidth = Int(canvas.width.rounded())
        let pixelHeight = Int(canvas.height.rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,                       // 0 = let CG pick an aligned stride
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Box first, under the glyphs. Drawn on the unflipped context: it's a
        // full-canvas symmetric rect, so orientation is moot.
        if let boxHex = style.boxColorHex, let boxColor = color(from: boxHex) {
            let radius = min(max(0, style.boxCornerRadius), min(canvas.width, canvas.height) / 2)
            let path = CGPath(
                roundedRect: CGRect(origin: .zero, size: canvas),
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(boxColor.cgColor)
            ctx.fillPath()
        }

        // A raw CGContext is bottom-left origin; UIKit string drawing assumes
        // top-left. Without this flip the text renders upside down.
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(ctx)
        attributed.draw(
            with: CGRect(x: pad, y: pad, width: textSize.width, height: textSize.height),
            options: options,                     // must match the measure pass
            context: nil)
        UIGraphicsPopContext()

        guard let cgImage = ctx.makeImage() else { return nil }
        // CIImage(cgImage:) preserves orientation and lands the extent at 0,0.
        return CIImage(cgImage: cgImage)
    }

    private static func attributedString(_ text: String, _ style: TextStyleSpec) -> NSAttributedString {
        // Unregistered/typo'd font names must not take the render queue down.
        let font = UIFont(name: style.fontName, size: style.pointSize)
            ?? UIFont.systemFont(ofSize: style.pointSize, weight: .bold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(style.alignment)
        // `lineSpacing` arrives as a MULTIPLE (1.1 = 110% leading), not points,
        // hence lineHeightMultiple rather than .lineSpacing. Only applied when
        // there is more than one line: on a single line lineHeightMultiple
        // shifts the baseline and clips tall ascenders for no benefit.
        if style.lineSpacing > 0, text.contains("\n") {
            paragraph.lineHeightMultiple = style.lineSpacing
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color(from: style.colorHex) ?? UIColor.white,
            .paragraphStyle: paragraph,
        ]

        if style.strokeWidth > 0, let hex = style.strokeColorHex, let strokeColor = color(from: hex) {
            attrs[.strokeColor] = strokeColor
            // UIKit takes .strokeWidth as a PERCENTAGE of the font point size,
            // and NEGATIVE means stroke *and* fill — positive gives hollow
            // glyphs, which is never what a caption wants.
            attrs[.strokeWidth] = -(style.strokeWidth / style.pointSize) * 100
        }

        return NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - Helpers

    private static func textAlignment(_ raw: String) -> NSTextAlignment {
        switch raw.lowercased() {
        case "left", "leading":   return .left
        case "right", "trailing": return .right
        default:                  return .center
        }
    }

    /// #RGB and #RRGGBB. Returns nil on anything malformed so callers can fall
    /// back rather than silently painting black.
    private static func color(from hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }

    private static func cacheKey(_ text: String, _ style: TextStyleSpec) -> String {
        [
            text,
            style.fontName,
            "\(style.pointSize)",
            style.colorHex,
            style.strokeColorHex ?? "-",
            "\(style.strokeWidth)",
            style.boxColorHex ?? "-",
            "\(style.boxCornerRadius)",
            "\(style.boxPadding)",
            style.alignment,
            "\(style.lineSpacing)",
        ].joined(separator: "|")
    }
}

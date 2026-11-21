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
        // Settle the canvas in WHOLE PIXELS here, and use that one value for the
        // allocation, the box rect and the y-flip alike. `pad` is caller-supplied
        // and routinely fractional, so `textSize + pad * 2` usually isn't integral:
        // rounding it only at the allocation left the bitmap up to a pixel taller
        // and wider than the geometry everything else was drawn in, and the box
        // rect — sized from the fractional canvas — fell short of the bitmap it was
        // painted into. That left a partially-transparent seam along the top and
        // right edges of the background box (measured: alpha 127 instead of 255 at
        // boxPadding 20.25). Ceil rather than round so the canvas can only ever
        // grow into padding, never crop a glyph.
        let canvas = CGSize(
            width: min((textSize.width + pad * 2).rounded(.up), maxCanvas),
            height: min((textSize.height + pad * 2).rounded(.up), maxCanvas))
        let pixelWidth = Int(canvas.width)
        let pixelHeight = Int(canvas.height)
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

// MARK: - Captions (karaoke)

/// A laid-out caption: TextKit 1 objects built and used on one thread only
/// (the compositor's render queue, or the main actor while the timeline
/// builds), never shared, so TextKit's threading rule is kept.
private struct CaptionTextStack {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer
    let tokens: [NSRange]
    let canvas: CGSize
}

extension TextRasterizer {
    private static let captionLock = NSLock()
    private static var captionCache: [String: CIImage] = [:]
    private static var captionSizes: [String: CGSize] = [:]
    /// Caption rasters are about 1314 px wide; 24 of them is roughly 50 MB at
    /// worst, and a playing line only needs one raster per word.
    private static let captionCacheLimit = 24

    /// Whitespace-separated words of `text`, as UTF-16 ranges. The karaoke
    /// highlight counts words exactly as they are drawn, so an edited line
    /// lights the words the viewer can see.
    static func captionTokens(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var start = -1
        for i in 0..<ns.length {
            if isCaptionSpace(ns.character(at: i)) {
                if start >= 0 {
                    out.append(NSRange(location: start, length: i - start))
                    start = -1
                }
            } else if start < 0 {
                start = i
            }
        }
        if start >= 0 { out.append(NSRange(location: start, length: ns.length - start)) }
        return out
    }

    /// The raster extent every frame of this caption line will have. Layout
    /// only, no pixels, so the timeline build can measure every line cheaply.
    static func captionExtent(_ text: String, style: CaptionStyle) -> CGRect? {
        let key = style.rawValue + "|" + text
        captionLock.lock()
        if let size = captionSizes[key] {
            captionLock.unlock()
            return CGRect(origin: .zero, size: size)
        }
        captionLock.unlock()

        guard let stack = captionStack(text, style: style, state: CaptionWordState()) else { return nil }
        captionLock.lock()
        if captionSizes.count >= 256 { captionSizes.removeAll() }
        captionSizes[key] = stack.canvas
        captionLock.unlock()
        return CGRect(origin: .zero, size: stack.canvas)
    }

    /// This caption line's raster at `localTime` seconds into its layer, or nil
    /// when the spec is not a styled caption (the caller then draws plain text).
    static func captionFrame(_ text: String, spec: OverlaySpec, localTime: Double) -> CIImage? {
        guard let raw = spec.captionStyle, let style = CaptionStyle(rawValue: raw) else { return nil }
        let state = TextAnimator.captionState(style: style,
                                              words: spec.captionWords,
                                              tokenCount: captionTokens(text).count,
                                              localTime: localTime,
                                              duration: spec.end - spec.start)
        return captionImage(text, style: style, state: state)
    }

    /// Rasterises a caption line in one word state. The canvas depends only on
    /// (text, style), never on the state, so the highlight can move from word
    /// to word without the layer changing size. Settled states are cached;
    /// the few in-between frames of a pop are not.
    static func captionImage(_ text: String, style: CaptionStyle, state: CaptionWordState) -> CIImage? {
        guard !text.isEmpty else { return nil }
        let settled = state.popStep >= TextAnimator.captionPopSteps
        let key = [style.rawValue, "\(state.active)", "\(state.visible)", "\(state.popStep)", text]
            .joined(separator: "|")
        if settled {
            captionLock.lock()
            if let cached = captionCache[key] {
                captionLock.unlock()
                return cached
            }
            captionLock.unlock()
        }

        guard let rendered = renderCaption(text, style: style, state: state) else { return nil }

        if settled {
            captionLock.lock()
            if captionCache.count >= captionCacheLimit { captionCache.removeAll() }
            captionCache[key] = rendered
            captionLock.unlock()
        }
        return rendered
    }

    // MARK: Caption layout

    private static func isCaptionSpace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 0xA0 || unit == 0x2028
    }

    private static func captionStack(_ text: String, style: CaptionStyle,
                                     state: CaptionWordState) -> CaptionTextStack? {
        let tokens = captionTokens(text)
        guard !tokens.isEmpty else { return nil }
        let storage = NSTextStorage(attributedString: captionAttributed(text, style: style,
                                                                        tokens: tokens, state: state))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CaptionMetrics.wrapWidth, height: 100_000))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        guard used.height >= 1 else { return nil }
        let height = min((ceil(used.height) + CaptionMetrics.padding * 2).rounded(.up), maxCanvas)
        return CaptionTextStack(storage: storage, layoutManager: layoutManager, container: container,
                                tokens: tokens,
                                canvas: CGSize(width: CaptionMetrics.canvasWidth, height: height))
    }

    /// Attributes that change only colour, shadow and outline per word, never
    /// metrics: every state of a line lays out identically.
    private static func captionAttributed(_ text: String, style: CaptionStyle,
                                          tokens: [NSRange], state: CaptionWordState) -> NSAttributedString {
        let size = CaptionMetrics.pointSize
        let font = UIFont(name: style.fontName, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .heavy)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // Tight leading, like the Night Lab mock (line-height 1.1).
        paragraph.lineHeightMultiple = 0.92

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
            .kern: -0.02 * size,
        ]
        if style.hasShadow {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            // Zero offset on purpose: a raw flipped CGContext would push an
            // offset shadow the wrong way. A soft glow reads the same anyway.
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = size * 0.12
            attrs[.shadow] = shadow
        }
        if style.isOutlined {
            attrs[.strokeColor] = UIColor.black
            // Negative = stroke AND fill, as a percentage of the point size.
            attrs[.strokeWidth] = -9.0
        }

        let out = NSMutableAttributedString(string: text, attributes: attrs)
        let signal = color(from: CaptionMetrics.signalHex) ?? UIColor.yellow
        let onSignal = color(from: CaptionMetrics.onSignalHex) ?? UIColor.black
        for (i, range) in tokens.enumerated() {
            if i >= state.visible {
                // Not spoken yet: keeps its place in the layout, draws nothing.
                out.addAttribute(.foregroundColor, value: UIColor.clear, range: range)
                if style.isOutlined { out.addAttribute(.strokeColor, value: UIColor.clear, range: range) }
                out.removeAttribute(.shadow, range: range)
            } else if i == state.active {
                switch style.highlight {
                case .colour:
                    out.addAttribute(.foregroundColor, value: signal, range: range)
                case .box:
                    out.addAttribute(.foregroundColor, value: onSignal, range: range)
                    out.removeAttribute(.shadow, range: range)
                case .none:
                    break
                }
            }
        }
        return out
    }

    // MARK: Caption drawing

    private static func renderCaption(_ text: String, style: CaptionStyle,
                                      state: CaptionWordState) -> CIImage? {
        guard let stack = captionStack(text, style: style, state: state) else { return nil }
        let canvas = stack.canvas
        let pixelWidth = Int(canvas.width)
        let pixelHeight = Int(canvas.height)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Same flip as `render`: TextKit draws in UIKit's top-left space.
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)

        let origin = CGPoint(x: CaptionMetrics.padding, y: CaptionMetrics.padding)
        let layoutManager = stack.layoutManager
        let allGlyphs = layoutManager.glyphRange(for: stack.container)

        if style.hasLineBoxes {
            drawCaptionLineBoxes(stack, origin: origin, in: ctx)
        }

        let hasActive = state.active >= 0 && state.active < stack.tokens.count && state.active < state.visible
        if style.highlight == .box, hasActive {
            let glyphs = layoutManager.glyphRange(forCharacterRange: stack.tokens[state.active],
                                                  actualCharacterRange: nil)
            let word = layoutManager.boundingRect(forGlyphRange: glyphs, in: stack.container)
                .offsetBy(dx: origin.x, dy: origin.y)
            let size = CaptionMetrics.pointSize
            let box = word.insetBy(dx: -size * 0.12, dy: size * 0.03)
            let path = UIBezierPath(roundedRect: box, cornerRadius: size * 0.16)
            let fill = color(from: CaptionMetrics.signalHex) ?? UIColor.yellow
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        }

        let popping = style.popsIn && hasActive && state.popStep < TextAnimator.captionPopSteps
        if popping {
            let word = layoutManager.glyphRange(forCharacterRange: stack.tokens[state.active],
                                                actualCharacterRange: nil)
            // Everything but the popping word, at rest.
            let beforeLength = max(0, word.location - allGlyphs.location)
            if beforeLength > 0 {
                layoutManager.drawGlyphs(forGlyphRange: NSRange(location: allGlyphs.location, length: beforeLength),
                                         at: origin)
            }
            let afterStart = NSMaxRange(word)
            let afterLength = max(0, NSMaxRange(allGlyphs) - afterStart)
            if afterLength > 0 {
                layoutManager.drawGlyphs(forGlyphRange: NSRange(location: afterStart, length: afterLength),
                                         at: origin)
            }
            // The popping word, scaled about its own centre (never above 1,
            // so it stays inside the canvas) and faded in.
            let p = Double(state.popStep) / Double(TextAnimator.captionPopSteps)
            let scale = CGFloat(TextAnimator.captionPopScale(p))
            let rect = layoutManager.boundingRect(forGlyphRange: word, in: stack.container)
                .offsetBy(dx: origin.x, dy: origin.y)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(min(1, 0.3 + p)))
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
            layoutManager.drawGlyphs(forGlyphRange: word, at: origin)
            ctx.restoreGState()
        } else {
            layoutManager.drawGlyphs(forGlyphRange: allGlyphs, at: origin)
        }

        UIGraphicsPopContext()
        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Boxed: one dark rounded box per line, hugging that line's words. All
    /// boxes go into one path and fill once, so where two lines' boxes touch
    /// the overlap is not darkened twice.
    private static func drawCaptionLineBoxes(_ stack: CaptionTextStack, origin: CGPoint, in ctx: CGContext) {
        let layoutManager = stack.layoutManager
        let ns = stack.storage.string as NSString
        let allGlyphs = layoutManager.glyphRange(for: stack.container)
        var lines: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: allGlyphs) { _, _, container, glyphRange, _ in
            var chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            while chars.length > 0, TextRasterizer.isCaptionSpace(ns.character(at: NSMaxRange(chars) - 1)) {
                chars.length -= 1
            }
            while chars.length > 0, TextRasterizer.isCaptionSpace(ns.character(at: chars.location)) {
                chars.location += 1
                chars.length -= 1
            }
            guard chars.length > 0 else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            lines.append(layoutManager.boundingRect(forGlyphRange: glyphs, in: container))
        }
        guard !lines.isEmpty else { return }
        let size = CaptionMetrics.pointSize
        let path = UIBezierPath()
        for line in lines {
            let box = line.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -size * 0.2, dy: 0)
            path.append(UIBezierPath(roundedRect: box, cornerRadius: size * 0.18))
        }
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.78).cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
    }
}

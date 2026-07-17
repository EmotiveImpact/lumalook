import UIKit

/// Rasterizes emoji and bundled sticker art to transparent PNGs on disk so they
/// can ride the EXISTING image-overlay path — the compositor already treats an
/// image overlay as a still, so a baked sticker inherits placement, keyframes,
/// rotation, opacity, trim, persistence and export parity for free. Baking once
/// at insert beats re-rasterizing per frame: stickers are never restyled after
/// the fact (unlike text/shapes), so there is nothing to cache and no render-
/// queue re-entrancy to guard.
///
/// `@MainActor` because `UIGraphicsImageRenderer` and the trait-resolving parts
/// of `UIImage` are main-thread affine. Callers bake on insert, not per frame.
enum StickerBaker {

    // MARK: - Baking

    /// Renders `emoji` centred in a transparent square PNG inside `folder`.
    /// Returns the written file URL, or nil if rendering or the write failed.
    /// Write to the project's clips folder so `PersistenceStore.cleanUpMedia`
    /// reference-counting sees it as ordinary overlay media.
    @MainActor
    static func bakePNG(emoji: String, pointSize: CGFloat = 512, into folder: URL) -> URL? {
        let glyph = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !glyph.isEmpty else { return nil }
        let size = max(8, pointSize)

        // Colour emoji ignore foreground colour — the font supplies the glyph
        // bitmaps — so no tint pass here.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size)
        ]
        let string = NSAttributedString(string: glyph, attributes: attributes)
        let textSize = string.size()

        // Square canvas with a little breathing room: `.size()` reports the
        // typographic box, and some glyphs overshoot it slightly.
        let padding = size * 0.08
        let side = ceil(max(textSize.width, textSize.height, size) + padding * 2)
        guard side.isFinite, side > 0 else { return nil }
        let canvas = CGSize(width: side, height: side)

        let image = renderer(for: canvas).image { _ in
            let origin = CGPoint(x: (side - textSize.width) / 2,
                                 y: (side - textSize.height) / 2)
            string.draw(at: origin)
        }
        return write(image, into: folder)
    }

    /// Renders a bundled asset-catalog image — falling back to an SF Symbol of
    /// the same name, tinted white — centred and aspect-fit in a transparent
    /// square PNG inside `folder`. Returns nil if the name resolves to nothing.
    @MainActor
    static func bakePNG(assetName: String, pointSize: CGFloat = 512, into folder: URL) -> URL? {
        let name = assetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // `max(8, .nan)` already clamps to 8, but +inf propagates and would ask
        // CoreGraphics for an infinite bitmap; the emoji path guards this via
        // `side.isFinite`, so mirror it here.
        let size = max(8, pointSize)
        guard size.isFinite else { return nil }

        let source: UIImage
        if let asset = UIImage(named: name) {
            source = asset
        } else {
            // SF Symbols are template art: render at a large point size and bake
            // white in, since the compositor composites the PNG as-is.
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
            guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return nil }
            source = symbol.withTintColor(.white, renderingMode: .alwaysOriginal)
        }

        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let canvas = CGSize(width: size, height: size)
        // Aspect-fit into the square so wide/tall art isn't stretched — the
        // overlay's own sizeFraction handles final scale.
        let scale = min(size / sourceSize.width, size / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = CGRect(x: (size - drawSize.width) / 2,
                              y: (size - drawSize.height) / 2,
                              width: drawSize.width,
                              height: drawSize.height)

        let image = renderer(for: canvas).image { _ in
            source.draw(in: drawRect)
        }
        return write(image, into: folder)
    }

    // MARK: - Helpers

    /// Transparent, unscaled (1 px per point) renderer — the PNG is a source
    /// asset, not a screen-resolution image, so a @2x/@3x device scale would
    /// only inflate it.
    ///
    /// `preferred()` seeds from the current trait collection, so every
    /// device-dependent property is pinned explicitly: `.standard` range keeps
    /// the bake an ordinary 8-bit sRGB PNG instead of the extended-range 16-bit
    /// one `.automatic` selects on wide-gamut screens. The compositor renders
    /// overlays into sRGB anyway, so extended range only doubles file size and
    /// makes the bytes vary by device.
    @MainActor
    private static func renderer(for size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// Writes `image` as `Sticker_<uuid>.png`, creating `folder` if needed.
    @MainActor
    private static func write(_ image: UIImage, into folder: URL) -> URL? {
        guard let data = image.pngData() else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Sticker_\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Picker content

    /// Curated emoji for the library sheet. Plain strings — the picker bakes on
    /// tap, so nothing here needs to exist as an asset.
    static let emojiCategories: [(name: String, emojis: [String])] = [
        (name: "Smileys", emojis: [
            "😀", "😂", "🥹", "😍", "🤩", "😎", "🥳", "🤔",
            "😴", "🤯", "😭", "😱", "🙄", "😇", "🤪", "🫠"
        ]),
        (name: "Gestures", emojis: [
            "👋", "👍", "👎", "👏", "🙌", "🤝", "✌️", "🤞",
            "🤙", "👌", "🫶", "💪", "🙏", "👀", "🫵", "🤌"
        ]),
        (name: "Hearts", emojis: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
            "💔", "❣️", "💕", "💖", "💗", "💘", "💝", "♥️"
        ]),
        (name: "Fire & Sparkle", emojis: [
            "🔥", "✨", "⭐️", "🌟", "💫", "⚡️", "💥", "🎉",
            "🎊", "🌈", "☀️", "🌙", "💧", "❄️", "🌊", "🪩"
        ]),
        (name: "Objects", emojis: [
            "🎬", "🎥", "📷", "🎧", "🎤", "🎸", "🕹️", "📺",
            "💿", "📼", "🖥️", "📱", "☕️", "🍕", "🍿", "🏆"
        ]),
        (name: "Symbols", emojis: [
            "✅", "❌", "❗️", "❓", "💯", "🔞", "⏰", "🔔",
            "🎯", "🚀", "👑", "💎", "🧿", "☮️", "♻️", "🆒"
        ])
    ]
}

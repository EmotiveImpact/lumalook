import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// The eight effects the FX library ships. Raw values persist (`StoredEffect.kind`),
/// so never rename a case — add.
enum EffectKind: String, Codable, CaseIterable {
    case glitch, vhs, rgbSplit, prism, lightLeak, bokeh, shake, zoomPunch

    var label: String {
        switch self {
        case .glitch:    return "Glitch"
        case .vhs:       return "VHS"
        case .rgbSplit:  return "RGB Split"
        case .prism:     return "Prism"
        case .lightLeak: return "Light Leak"
        case .bokeh:     return "Bokeh"
        case .shake:     return "Shake"
        case .zoomPunch: return "Zoom Punch"
        }
    }

    /// SF Symbol for the library sheet + lane chips.
    var icon: String {
        switch self {
        case .glitch:    return "bolt.horizontal.fill"
        case .vhs:       return "recordingtape"
        case .rgbSplit:  return "camera.filters"
        case .prism:     return "triangle.righthalf.filled"
        case .lightLeak: return "sun.max.fill"
        case .bokeh:     return "camera.aperture"
        case .shake:     return "waveform.path"
        case .zoomPunch: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// The effect library's visual chains, factored out of the compositor so the
/// render loop just calls `apply(...)`. Every effect is a PURE function of
/// (image, localTime, intensity) — there is NO randomness anywhere. Jitter is
/// derived from sin/cos of `localTime`, which means a scrub preview and the
/// exported frame at the same timestamp resolve to the same maths, and 30 vs
/// 60 fps sampling agrees because they sample one continuous curve rather than
/// stepping a seeded sequence.
enum EffectRenderer {
    private static let lock = NSLock()
    private static var scanlineCache: [String: CIImage] = [:]
    private static let maxEntries = 40

    /// Applies `kind` to `image` at `localTime` seconds into the effect's span.
    /// `intensity` 0…1. Always returns an image cropped to `rect`.
    static func apply(_ kind: EffectKind, to image: CIImage, localTime: Double,
                      intensity: Double, rect: CGRect) -> CIImage {
        guard !rect.isEmpty, isSane(rect) else { return image }
        let i = min(max(intensity, 0), 1)
        guard i > 0.001 else { return image.cropped(to: rect) }
        let t = max(localTime, 0)

        switch kind {
        case .rgbSplit:  return rgbSplit(image, t: t, i: i, rect: rect)
        case .glitch:    return glitch(image, t: t, i: i, rect: rect)
        case .vhs:       return vhs(image, t: t, i: i, rect: rect)
        case .prism:     return prism(image, i: i, rect: rect)
        case .lightLeak: return lightLeak(image, t: t, i: i, rect: rect)
        case .bokeh:     return bokeh(image, i: i, rect: rect)
        case .shake:     return shake(image, t: t, i: i, rect: rect)
        case .zoomPunch: return zoomPunch(image, t: t, i: i, rect: rect)
        }
    }

    // MARK: - Channel displacement

    /// R pushed one way, B the other, G held. The wobble keeps a 2 s region
    /// alive without ever touching an RNG. `amount` is the px throw at i = 1.
    private static func rgbSplit(_ image: CIImage, t: Double, i: Double,
                                 rect: CGRect, amount: Double = 18) -> CIImage {
        let shift = CGFloat(amount * i + sin(t * 8) * 2 * i)
        guard abs(shift) > 0.01 else { return image.cropped(to: rect) }
        // Clamp first: translated channels would otherwise leave a hard black
        // bar at the frame edge instead of the smeared fringe you actually want.
        let src = image.clampedToExtent()
        let r = channel(src, keep: .r, alpha: false)
            .transformed(by: CGAffineTransform(translationX: shift, y: 0))
        let g = channel(src, keep: .g, alpha: true)
        let b = channel(src, keep: .b, alpha: false)
            .transformed(by: CGAffineTransform(translationX: -shift, y: 0))
        return add(add(r, g), b).cropped(to: rect)
    }

    /// rgbSplit plus a few torn horizontal bands. Band positions ride
    /// sin(t·37 + k) so they march deterministically instead of flickering.
    private static func glitch(_ image: CIImage, t: Double, i: Double, rect: CGRect) -> CIImage {
        var img = rgbSplit(image, t: t, i: i, rect: rect)
        for k in 0..<3 {
            let yFrac = sin(t * 37 + Double(k) * 2.1) * 0.5 + 0.5
            let bandH = rect.height * 0.08
            let y = rect.minY + CGFloat(yFrac) * (rect.height - bandH)
            let bandRect = CGRect(x: rect.minX, y: y, width: rect.width, height: bandH)
            let offset = CGFloat(k % 2 == 0 ? 1 : -1) * CGFloat(30 * i)
            let band = img.cropped(to: bandRect)
                .transformed(by: CGAffineTransform(translationX: offset, y: 0))
            img = band.composited(over: img).cropped(to: rect)
        }
        return img
    }

    /// Chromatic-aberration bloom: each channel sampled at a slightly different
    /// scale about the centre, so the fringe grows towards the frame edges.
    private static func prism(_ image: CIImage, i: Double, rect: CGRect) -> CIImage {
        let src = image.clampedToExtent()
        let r = channel(src, keep: .r, alpha: false)
        let g = channel(scaleAboutCentre(src, scale: 1 + 0.01 * CGFloat(i), rect: rect),
                        keep: .g, alpha: true)
        let b = channel(scaleAboutCentre(src, scale: 1 + 0.02 * CGFloat(i), rect: rect),
                        keep: .b, alpha: false)
        return add(add(r, g), b).cropped(to: rect)
    }

    // MARK: - Tape

    /// Desaturate → soften → small channel split → scanlines → vignette. Tape
    /// degrades gently; piling the split on hard reads as glitch, not VHS.
    private static func vhs(_ image: CIImage, t: Double, i: Double, rect: CGRect) -> CIImage {
        var img = image.cropped(to: rect)

        let cc = CIFilter.colorControls()
        cc.inputImage = img
        cc.saturation = Float(1 - 0.2 * i)
        img = (cc.outputImage ?? img).cropped(to: rect)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = img.clampedToExtent()
        blur.radius = Float(0.8 * i)
        img = (blur.outputImage ?? img).cropped(to: rect)

        img = rgbSplit(img, t: t, i: i, rect: rect, amount: 4)

        // Multiply, not screen: only the dark lines should bite.
        let m = CIFilter.multiplyCompositing()
        m.inputImage = scanlines(rect: rect, darken: CGFloat(0.35 * i))
        m.backgroundImage = img
        img = (m.outputImage ?? img).cropped(to: rect)

        let v = CIFilter.vignette()
        v.inputImage = img
        v.intensity = Float(1.2 * i)
        v.radius = 1.6
        return (v.outputImage ?? img).cropped(to: rect)
    }

    /// Horizontal scanline multiplier sized to `rect`. Cached: the compositor
    /// asks every frame and the geometry never changes mid-region. Keyed on
    /// pixel size + quantised darkness, built at the origin and shifted out —
    /// same shape as OverlayMaskRenderer's mask cache.
    private static func scanlines(rect: CGRect, darken: CGFloat) -> CIImage {
        // Validate BEFORE converting: `Int(x)` traps on NaN, on ±infinity, and
        // on any finite value past `Int.max` (see `isSane`). White is the
        // identity for the multiply this feeds, so a bad rect degrades to a
        // no-op instead of a SIGTRAP.
        let fw = rect.width.rounded(), fh = rect.height.rounded()
        guard fw.isFinite, fh.isFinite, fw >= 1, fh >= 1,
              fw <= maxEdge, fh <= maxEdge else {
            return CIImage(color: .white).cropped(to: rect)
        }
        let w = Int(fw), h = Int(fh)
        // Quantise BEFORE keying so the key and the pixels can never disagree;
        // 20 steps keeps the cache well under `maxEntries` across two sizes.
        let q = (darken * 20).rounded() / 20
        let key = "\(w)x\(h)|\(q)"

        lock.lock()
        if let cached = scanlineCache[key] {
            lock.unlock()
            return cached.transformed(by: originShift(rect))
        }
        lock.unlock()

        let base = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let g = CIFilter.stripesGenerator()
        g.center = .zero
        g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        g.color1 = CIColor(red: 1 - q, green: 1 - q, blue: 1 - q, alpha: 1)
        // Pitch scales with the frame so 1080p preview and 4K export match.
        g.width = Float(max(CGFloat(h) / 240, 1))
        g.sharpness = 0.6

        // Stripes vary along x. Rotate a circumscribing SQUARE 90° about the
        // centre rather than transforming the generator's infinite extent —
        // a square of side max(w,h) rotated about its own centre is itself, so
        // it still covers `base` afterwards.
        let side = max(base.width, base.height)
        let square = CGRect(x: base.midX - side / 2, y: base.midY - side / 2,
                            width: side, height: side)
        guard let stripes = g.outputImage?.cropped(to: square) else {
            return CIImage(color: .white).cropped(to: rect)
        }
        let image = rotateAboutCentre(stripes, radians: .pi / 2, rect: base).cropped(to: base)

        lock.lock()
        if scanlineCache.count > maxEntries { scanlineCache.removeAll() }
        scanlineCache[key] = image
        lock.unlock()
        return image.transformed(by: originShift(rect))
    }

    // MARK: - Light

    /// Warm gradient drifting on two slow, mutually-prime-ish frequencies so the
    /// centre never retraces the same path within a sane region length.
    private static func lightLeak(_ image: CIImage, t: Double, i: Double, rect: CGRect) -> CIImage {
        let cx = rect.midX + CGFloat(sin(t * 0.7)) * rect.width * 0.35
        let cy = rect.midY + CGFloat(cos(t * 0.5)) * rect.height * 0.35
        let k = CGFloat(i)

        let g = CIFilter.radialGradient()
        g.center = CGPoint(x: cx, y: cy)
        g.radius0 = 0
        g.radius1 = Float(max(rect.width, rect.height) * 0.55)
        // Amber core pre-scaled by intensity — screen-blending a dimmer colour
        // is the dial, so no second pass is needed to pull it back.
        g.color0 = CIColor(red: 1.0 * k, green: 0.72 * k, blue: 0.32 * k, alpha: 1)
        g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let leak = g.outputImage?.cropped(to: rect) else { return image.cropped(to: rect) }

        let s = CIFilter.screenBlendMode()
        s.inputImage = leak
        s.backgroundImage = image
        return (s.outputImage ?? image).cropped(to: rect)
    }

    /// Highlight bloom: isolate the top of the luma range, blur it wide, screen
    /// it back. Screen over black is a no-op, so the shadows stay untouched.
    private static func bokeh(_ image: CIImage, i: Double, rect: CGRect) -> CIImage {
        let cropped = image.cropped(to: rect)
        let threshold = 0.85 - 0.25 * i          // more intensity → more of the frame blooms

        let clamp = CIFilter.colorClamp()
        clamp.inputImage = cropped
        clamp.minComponents = CIVector(x: CGFloat(threshold), y: CGFloat(threshold),
                                       z: CGFloat(threshold), w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let clamped = clamp.outputImage else { return cropped }

        // Clamping only raises the floor; stretch [threshold…1] back to [0…1]
        // so everything below the threshold lands on black.
        let span = max(1 - threshold, 0.05)
        let scale = CGFloat(1 / span)
        let bias = CGFloat(-threshold / span)
        let stretch = CIFilter.colorMatrix()
        stretch.inputImage = clamped
        stretch.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        stretch.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        stretch.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        stretch.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        stretch.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        guard var highlights = stretch.outputImage else { return cropped }

        let bloom = CIFilter.bloom()
        bloom.inputImage = highlights
        bloom.intensity = Float(i)
        bloom.radius = Float(8 + 12 * i)
        highlights = bloom.outputImage ?? highlights

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = highlights.clampedToExtent()
        blur.radius = Float(6 + 16 * i)
        highlights = (blur.outputImage ?? highlights).cropped(to: rect)

        let s = CIFilter.screenBlendMode()
        s.inputImage = highlights
        s.backgroundImage = cropped
        return (s.outputImage ?? cropped).cropped(to: rect)
    }

    // MARK: - Motion

    /// Two fast, unrelated frequencies read as handheld rather than as a pendulum.
    private static func shake(_ image: CIImage, t: Double, i: Double, rect: CGRect) -> CIImage {
        let dx = CGFloat(sin(t * 73) * 14 * i)
        let dy = CGFloat(cos(t * 61) * 14 * i)
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: rect)
    }

    /// A punch on the beat: full kick at the region start, spent by t ≈ 1/3 s.
    private static func zoomPunch(_ image: CIImage, t: Double, i: Double, rect: CGRect) -> CIImage {
        let decay = max(0, 1 - t * 3)
        guard decay > 0 else { return image.cropped(to: rect) }
        let scale = 1 + 0.12 * CGFloat(i) * CGFloat(decay)
        return scaleAboutCentre(image.clampedToExtent(), scale: scale, rect: rect).cropped(to: rect)
    }

    // MARK: - Helpers

    /// Largest edge we build pixel geometry for. 65_536 is far past any canvas
    /// (8K is 7_680) and keeps the `Int(...)` conversions in `scanlines` in range.
    private static let maxEdge: CGFloat = 65_536

    /// Whether `rect` can safely be turned into integer pixel dimensions.
    ///
    /// `!rect.isEmpty` is NOT sufficient on its own: `CGRect.infinite` is not
    /// empty, and — the trap — its `width.isFinite` is `true`, because CGRect
    /// stores ~1.8e308 rather than a literal infinity. It therefore sails past
    /// both an `isEmpty` and an `isFinite` check and reaches
    /// `Int(rect.width.rounded())` in `scanlines`, which traps (SIGTRAP: the
    /// value is far beyond `Int.max`). NaN dimensions trap the same way. This
    /// matters because `someImage.extent` is infinite for any generator or
    /// `clampedToExtent()` result, which is a very easy rect for a caller to
    /// hand us.
    private static func isSane(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width <= maxEdge && rect.height <= maxEdge
    }

    private static func originShift(_ rect: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.minX, y: rect.minY)
    }

    private static func scaleAboutCentre(_ image: CIImage, scale: CGFloat, rect: CGRect) -> CIImage {
        guard abs(scale - 1) > 0.001 else { return image }
        let cx = rect.midX, cy = rect.midY
        let t = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        return image.transformed(by: t)
    }

    private static func rotateAboutCentre(_ image: CIImage, radians: CGFloat, rect: CGRect) -> CIImage {
        guard abs(radians) > 0.001 else { return image }
        let cx = rect.midX, cy = rect.midY
        let t = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        return image.transformed(by: t)
    }

    private enum Chan { case r, g, b }

    /// Isolates one channel. Only ONE of the three copies in a split should
    /// carry alpha — additionCompositing sums it, and three opaque layers would
    /// hand downstream filters a 3× premultiplied alpha to unpremultiply by.
    private static func channel(_ image: CIImage, keep: Chan, alpha: Bool) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: keep == .r ? 1 : 0, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: keep == .g ? 1 : 0, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: keep == .b ? 1 : 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha ? 1 : 0)
        return m.outputImage ?? image
    }

    private static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.additionCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return f.outputImage ?? a
    }
}

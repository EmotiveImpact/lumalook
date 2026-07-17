import CoreImage
import CoreGraphics
import Foundation

/// The five particle overlays the FX library ships. Raw values are what get
/// persisted — the F6 precedent stores `EffectKind.rawValue` into
/// `EffectLayer.kind: String` — so never rename a case, only add.
enum ParticleKind: String, Codable, CaseIterable {
    case dust, rain, snow, sparkle, confetti

    var label: String {
        switch self {
        case .dust:     return "Dust"
        case .rain:     return "Rain"
        case .snow:     return "Snow"
        case .sparkle:  return "Sparkle"
        case .confetti: return "Confetti"
        }
    }

    /// SF Symbol for the library sheet + lane chips.
    var icon: String {
        switch self {
        case .dust:     return "aqi.low"
        case .rain:     return "cloud.rain.fill"
        case .snow:     return "snowflake"
        case .sparkle:  return "sparkles"
        case .confetti: return "party.popper.fill"
        }
    }
}

/// Deterministic particle overlays composited over the frame.
///
/// There is deliberately NO CAEmitterLayer here. An emitter integrates its
/// particles forward in wall-clock time from whenever the layer happened to
/// start, so it can only ever be *watched* — you cannot ask it for "the frame at
/// t = 4.25 s" and get the same answer twice. An export renders frames out of
/// order, at a different cadence than the preview, and often faster than
/// real time; an emitter would produce a different sky every run.
///
/// Instead every particle's position is a CLOSED-FORM function of its index and
/// `localTime`: seed = `rnd(i, salt)`, position = seed + drift(t). Any frame can
/// therefore be rendered independently, in any order, on any thread, and resolve
/// to identical pixels — which is the whole point of the file. Nothing here
/// touches an RNG, `Date`, or any stored state. (`rnd` leans on `sin`, so it is
/// reproducible for a given libm; preview and export share one device, so that
/// is the only guarantee we need.)
///
/// All particles for a frame land in ONE CGContext. Building a CIImage per
/// particle would mean 200+ composites per frame, which is a different feature
/// (a slideshow) than the one requested.
enum ParticleRenderer {
    private static let lock = NSLock()
    private static var dotCache: [Int: CGImage] = [:]
    private static let maxEntries = 40

    /// Hard ceiling on particles per frame. The draw is linear in this, and past
    /// ~220 soft dots the frame reads as fog rather than as weather anyway.
    private static let maxParticles = 220

    /// Draws `kind` at `localTime` seconds over `image` (extent == `rect`).
    /// `intensity` 0…1 scales count and opacity. Pure + deterministic: same
    /// arguments in, same pixels out, forever.
    static func apply(_ kind: ParticleKind, to image: CIImage, localTime: Double,
                      intensity: Double, rect: CGRect) -> CIImage {
        guard !rect.isEmpty, isSane(rect) else { return image }
        let i = min(max(intensity, 0), 1)
        guard i > 0.001 else { return image.cropped(to: rect) }
        // max(NaN, 0) returns NaN in Swift, so test before clamping: a NaN t
        // would silently poison every coordinate below.
        guard localTime.isFinite else { return image.cropped(to: rect) }
        let t = max(localTime, 0)

        guard let layer = layer(kind, t: t, i: i, rect: rect) else {
            return image.cropped(to: rect)
        }
        return layer.composited(over: image).cropped(to: rect)
    }

    // MARK: - Layer

    /// Renders every particle for one frame into a single bitmap and hands it
    /// back as a CIImage positioned over `rect`.
    ///
    /// The context is allocated per call and never cached: the pixels are a
    /// function of `localTime`, so every frame differs and a time-keyed cache
    /// would be pure overhead with an unbounded key space.
    private static func layer(_ kind: ParticleKind, t: Double, i: Double, rect: CGRect) -> CIImage? {
        // `isSane` already bounded these, so the Int conversions cannot trap.
        let fw = rect.width.rounded(), fh = rect.height.rounded()
        guard fw >= 1, fh >= 1 else { return nil }
        let w = Int(fw), h = Int(fh)

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .default

        let size = CGSize(width: fw, height: fh)
        let count = particleCount(kind, i: i)
        guard count > 0 else { return nil }

        switch kind {
        case .dust:     drawDust(ctx, count: count, t: t, i: i, size: size)
        case .rain:     drawRain(ctx, count: count, t: t, i: i, size: size)
        case .snow:     drawSnow(ctx, count: count, t: t, i: i, size: size)
        case .sparkle:  drawSparkle(ctx, count: count, t: t, i: i, size: size)
        case .confetti: drawConfetti(ctx, count: count, t: t, i: i, size: size)
        }

        guard let cg = ctx.makeImage() else { return nil }
        // CIImage(cgImage:) lands at the origin with a FINITE extent; move it
        // onto the caller's rect. A bitmap context draws y-up and stores its
        // y = height row first, which is exactly how CI reads a CGImage back —
        // so the two agree and no flip is needed.
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    // MARK: - Kinds

    /// Slow drift on both axes. Two unrelated frequencies per mote (one from the
    /// index, one from a salt) so the field never settles into a visible grid.
    private static func drawDust(_ ctx: CGContext, count: Int, t: Double, i: Double, size: CGSize) {
        guard let dot = softDot() else { return }
        let s = unit(size)
        for k in 0..<count {
            let fall = wrap(rnd(k, 3) + t * (0.010 + rnd(k, 2) * 0.022))
            let x = rnd(k, 1) * size.width
                + CGFloat(sin(t * 0.31 + Double(k) * 1.7)) * size.width * 0.02
            let y = fallY(fall, size: size)
            let r = (0.9 + rnd(k, 4) * 2.0) * s
            let a = (0.14 + rnd(k, 5) * 0.34) * i
            blit(ctx, dot, x: x, y: y, halfW: r, halfH: r, alpha: a)
        }
    }

    /// Fast, straight, slightly slanted. The streak is the same soft dot stretched
    /// along the fall and rotated onto the trajectory, so a drop leans the way it
    /// actually travels instead of hanging vertical while sliding sideways.
    private static func drawRain(_ ctx: CGContext, count: Int, t: Double, i: Double, size: CGSize) {
        guard let dot = softDot() else { return }
        let s = unit(size)
        let slant: CGFloat = 0.18                 // px sideways per px of fall
        let angle = -atan(slant)                  // long axis onto (slant, 1)
        let travel = size.height + 2 * margin(size)
        for k in 0..<count {
            let fall = wrap(rnd(k, 3) + t * (0.85 + rnd(k, 2) * 0.55))
            let x = rnd(k, 1) * size.width - CGFloat(fall) * travel * slant
            let y = fallY(fall, size: size)
            let r = (0.7 + rnd(k, 4) * 0.5) * s
            let len = r * (7 + CGFloat(rnd(k, 6)) * 6)
            let a = (0.22 + rnd(k, 5) * 0.38) * i
            blit(ctx, dot, x: x, y: y, halfW: r, halfH: len, alpha: a, rotation: angle)
        }
    }

    /// Slow fall plus a per-flake horizontal sway. The sway rides
    /// sin(t + index): the index is the phase offset, so no two flakes swing
    /// together and the whole field stays a pure function of t.
    private static func drawSnow(_ ctx: CGContext, count: Int, t: Double, i: Double, size: CGSize) {
        guard let dot = softDot() else { return }
        let s = unit(size)
        for k in 0..<count {
            let fall = wrap(rnd(k, 3) + t * (0.055 + rnd(k, 2) * 0.085))
            let sway = CGFloat(sin(t * 0.85 + Double(k))) * size.width * (0.012 + CGFloat(rnd(k, 7)) * 0.022)
            let x = rnd(k, 1) * size.width + sway
            let y = fallY(fall, size: size)
            let r = (1.2 + rnd(k, 4) * 2.2) * s
            let a = (0.35 + rnd(k, 5) * 0.5) * i
            blit(ctx, dot, x: x, y: y, halfW: r, halfH: r, alpha: a)
        }
    }

    /// Fixed positions, twinkling alpha. Nothing moves — the only time term is
    /// the 0…1 brightness swing, offset per index so the field shimmers rather
    /// than pulsing as one lamp.
    private static func drawSparkle(_ ctx: CGContext, count: Int, t: Double, i: Double, size: CGSize) {
        guard let dot = softDot() else { return }
        let s = unit(size)
        for k in 0..<count {
            let x = rnd(k, 1) * size.width
            let y = rnd(k, 3) * size.height
            let r = (1.4 + rnd(k, 4) * 3.6) * s
            let twinkle = 0.5 + 0.5 * sin(t * 6 + Double(k))
            let a = twinkle * (0.35 + rnd(k, 5) * 0.5) * i
            blit(ctx, dot, x: x, y: y, halfW: r, halfH: r, alpha: a)
        }
    }

    /// Falls, sways, and tumbles. The spin drives both a rotation and a
    /// horizontal squash (|cos| of the spin), which fakes the card turning
    /// edge-on far more cheaply than an actual 3-D transform.
    private static func drawConfetti(_ ctx: CGContext, count: Int, t: Double, i: Double, size: CGSize) {
        let s = unit(size)
        for k in 0..<count {
            let fall = wrap(rnd(k, 3) + t * (0.14 + rnd(k, 2) * 0.22))
            let sway = CGFloat(sin(t * 1.3 + Double(k) * 0.9)) * size.width * 0.03
            let x = rnd(k, 1) * size.width + sway
            let y = fallY(fall, size: size)
            let spin = t * (1.2 + rnd(k, 6) * 3.4) + rnd(k, 7) * .pi * 2
            let squash = max(abs(CGFloat(cos(spin))), 0.15)
            let w = (4.5 + CGFloat(rnd(k, 4)) * 3.5) * s
            let h = w * (1.4 + CGFloat(rnd(k, 8)) * 0.9)
            let hue = confettiHues[Int(rnd(k, 9) * Double(confettiHues.count)) % confettiHues.count]
            let a = (0.72 + rnd(k, 5) * 0.28) * i

            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: CGFloat(spin) * 0.55)
            ctx.scaleBy(x: squash, y: 1)
            ctx.setAlpha(CGFloat(a))
            ctx.setFillColor(red: hue.0, green: hue.1, blue: hue.2, alpha: 1)
            ctx.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            ctx.restoreGState()
        }
    }

    private static let confettiHues: [(CGFloat, CGFloat, CGFloat)] = [
        (0.98, 0.30, 0.38), (0.99, 0.76, 0.24), (0.36, 0.80, 0.55),
        (0.33, 0.62, 0.97), (0.75, 0.45, 0.95), (0.99, 0.55, 0.30)
    ]

    // MARK: - Determinism

    /// Stable pseudo-random value in 0..<1 from an index and a salt.
    ///
    /// The classic `fract(sin(x) * bigNumber)` hash. It carries NO state, so
    /// particle `k`'s seed is the same whether the frame is the first one
    /// rendered or the ten-thousandth, and whether it is rendered alone or as
    /// part of a full pass. `salt` picks which property is being seeded (x, speed,
    /// phase, radius…), which keeps those properties uncorrelated with each other.
    private static func rnd(_ i: Int, _ salt: Double) -> Double {
        let x = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    /// Fractional part, used to loop a falling particle seamlessly: the particle
    /// leaves below the frame at 1 and re-enters above it at 0, at the same x, so
    /// the wrap is invisible.
    private static func wrap(_ x: Double) -> Double {
        let f = x.truncatingRemainder(dividingBy: 1)
        return f < 0 ? f + 1 : f
    }

    /// How far outside the frame particles are born and retired, so nothing ever
    /// pops into existence on-screen.
    private static func margin(_ size: CGSize) -> CGFloat { size.height * 0.08 + 8 }

    /// Maps fall progress 0…1 onto a y that starts above the top edge and ends
    /// below the bottom one. Context coords are y-up, so falling means decreasing y.
    private static func fallY(_ fall: Double, size: CGSize) -> CGFloat {
        let m = margin(size)
        return size.height + m - CGFloat(fall) * (size.height + 2 * m)
    }

    /// Per-frame scale for particle sizes, normalised to 1080p. Without this a
    /// 4K export would render the same motes at a quarter of their apparent
    /// size and the overlay would not match the preview.
    private static func unit(_ size: CGSize) -> CGFloat {
        max(min(size.width, size.height) / 1080, 0.15)
    }

    private static func particleCount(_ kind: ParticleKind, i: Double) -> Int {
        let base: Double
        switch kind {
        case .dust:     base = 90
        case .rain:     base = 220
        case .snow:     base = 150
        case .sparkle:  base = 70
        case .confetti: base = 110
        }
        let n = (base * i).rounded()
        guard n.isFinite else { return 0 }
        return min(max(Int(n), 1), maxParticles)
    }

    // MARK: - Drawing helpers

    /// Draws the soft-dot sprite centred on (x, y), optionally stretched and
    /// rotated. `alpha` goes through the context's global alpha rather than a
    /// tinted sprite, so one cached sprite serves every particle.
    private static func blit(_ ctx: CGContext, _ dot: CGImage,
                             x: CGFloat, y: CGFloat, halfW: CGFloat, halfH: CGFloat,
                             alpha: Double, rotation: CGFloat = 0) {
        guard x.isFinite, y.isFinite, halfW > 0, halfH > 0 else { return }
        let a = min(max(alpha, 0), 1)
        guard a > 0.004 else { return }

        ctx.saveGState()
        ctx.setAlpha(CGFloat(a))
        if rotation != 0 {
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: rotation)
            ctx.draw(dot, in: CGRect(x: -halfW, y: -halfH, width: halfW * 2, height: halfH * 2))
        } else {
            ctx.draw(dot, in: CGRect(x: x - halfW, y: y - halfH,
                                     width: halfW * 2, height: halfH * 2))
        }
        ctx.restoreGState()
    }

    /// A white dot with a radial alpha falloff, built once and reused for every
    /// particle of every kind. Cached because — unlike the frame layer — it does
    /// NOT depend on time; only on its own pixel side, of which there is one.
    ///
    /// The falloff lives in ALPHA over a constant white, which is the only shape
    /// that survives premultiplication: the rim is transparent *white*, i.e. the
    /// premultiplied zero, so scaling and compositing it can never bleed a colour
    /// fringe the way an alpha-0 tinted rim would.
    private static func softDot(side: Int = 64) -> CGImage? {
        lock.lock()
        if let cached = dotCache[side] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard side >= 2 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let comps: [CGFloat] = [1, 1, 1, 1,
                                1, 1, 1, 0.55,
                                1, 1, 1, 0]
        let locs: [CGFloat] = [0, 0.42, 1]
        guard let grad = CGGradient(colorSpace: space, colorComponents: comps,
                                    locations: locs, count: 3) else { return nil }
        let c = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                               endCenter: c, endRadius: CGFloat(side) / 2, options: [])
        guard let image = ctx.makeImage() else { return nil }

        lock.lock()
        if dotCache.count > maxEntries { dotCache.removeAll() }
        dotCache[side] = image
        lock.unlock()
        return image
    }

    // MARK: - Guards

    /// Largest edge we build pixel geometry for. 65_536 is far past any canvas
    /// (8K is 7_680) and keeps the `Int(...)` conversions in `layer` in range.
    private static let maxEdge: CGFloat = 65_536

    /// Whether `rect` can safely be turned into integer pixel dimensions.
    ///
    /// `!rect.isEmpty` is NOT sufficient on its own: `CGRect.infinite` is not
    /// empty, and its `width.isFinite` is `true`, because CGRect stores ~1.8e308
    /// rather than a literal infinity. It sails past both an `isEmpty` and an
    /// `isFinite` check and reaches `Int(rect.width.rounded())`, which traps —
    /// the value is far beyond `Int.max`. NaN dimensions trap the same way. Any
    /// generator or `clampedToExtent()` result has exactly that extent, so it is
    /// a very easy rect for a caller to hand us.
    private static func isSane(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width <= maxEdge && rect.height <= maxEdge
    }
}

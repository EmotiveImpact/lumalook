import Foundation
import CoreImage

/// Pro colour maths for the Grade Room: turns curves, colour wheels and the
/// 8-band HSL into `CIColorCube` filters. Everything here is PURE COLOUR
/// (no spatial ops), so it bakes correctly into exported .cube LUTs and adds
/// nothing when the user hasn't touched a control (identity → nil filter).
enum ColorMath {

    // Caches keyed by a cheap content hash so scrubbing a slider doesn't
    // rebuild the cube every frame.
    private static let lock = NSLock()
    private static var transferCache: [Int: CIFilter] = [:]
    private static var hslCache: [Int: CIFilter] = [:]

    // MARK: Curves + wheels → one separable per-channel cube

    /// Combined curves + wheels as a single 33³ separable colour cube, or nil
    /// when both are identity.
    static func transferCube(curves: CurveSet?, wheels: ColorWheels?) -> CIFilter? {
        let curvesActive = curves.map { !$0.isIdentity } ?? false
        let wheelsActive = wheels.map { !$0.isIdentity } ?? false
        guard curvesActive || wheelsActive else { return nil }

        let key = hash(curves: curves, wheels: wheels)
        lock.lock()
        if let cached = transferCache[key] { lock.unlock(); return cached }
        lock.unlock()

        // Per-channel 1-D transfer sampled at 256 points.
        let samples = 256
        let (fr, fg, fb) = channelTransfers(curves: curves, wheels: wheels, samples: samples)

        let n = 33
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            let bv = fb[sampleIndex(b, n, samples)]
            for g in 0..<n {
                let gv = fg[sampleIndex(g, n, samples)]
                for r in 0..<n {
                    data[i + 0] = fr[sampleIndex(r, n, samples)]
                    data[i + 1] = gv
                    data[i + 2] = bv
                    data[i + 3] = 1
                    i += 4
                }
            }
        }
        let filter = cubeFilter(data: data, dimension: n)
        lock.lock(); transferCache[key] = filter
        if transferCache.count > 24 { transferCache.removeAll() }
        lock.unlock()
        return filter
    }

    private static func sampleIndex(_ cubeIndex: Int, _ n: Int, _ samples: Int) -> Int {
        min(samples - 1, Int((Double(cubeIndex) / Double(n - 1)) * Double(samples - 1)))
    }

    /// The three per-channel transfer functions: wheels (lift/gamma/gain)
    /// then the master curve then the channel curve.
    private static func channelTransfers(curves: CurveSet?, wheels: ColorWheels?,
                                         samples: Int) -> ([Float], [Float], [Float]) {
        let master = spline(curves?.master)
        let cr = spline(curves?.red), cg = spline(curves?.green), cb = spline(curves?.blue)
        let w = wheels ?? ColorWheels()

        func transfer(_ channelCurve: [Double]?,
                      lift: Double, gamma: Double, gain: Double) -> [Float] {
            (0..<samples).map { idx in
                var v = Double(idx) / Double(samples - 1)
                // Wheels: gain (highlights) → lift (shadows) → gamma (mids).
                v = clamp01(v * gain)
                v = v + lift * (1 - v)
                v = pow(clamp01(v), 1.0 / max(0.05, gamma))
                // Curves: master then channel.
                v = sampleCurve(master, v)
                v = sampleCurve(channelCurve, v)
                return Float(clamp01(v))
            }
        }
        return (transfer(cr, lift: w.liftR, gamma: w.gammaR, gain: w.gainR),
                transfer(cg, lift: w.liftG, gamma: w.gammaG, gain: w.gainG),
                transfer(cb, lift: w.liftB, gamma: w.gammaB, gain: w.gainB))
    }

    // MARK: HSL → hue-dependent 3-D cube

    static func hslCube(_ bands: HSLBands?) -> CIFilter? {
        guard let bands, !bands.isIdentity else { return nil }
        let key = hash(hsl: bands)
        lock.lock()
        if let cached = hslCache[key] { lock.unlock(); return cached }
        lock.unlock()

        let n = 24
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            let bv = Double(bi) / Double(n - 1)
            for gi in 0..<n {
                let gv = Double(gi) / Double(n - 1)
                for ri in 0..<n {
                    let rv = Double(ri) / Double(n - 1)
                    let (nr, ng, nb) = applyHSL(r: rv, g: gv, b: bv, bands: bands)
                    data[i + 0] = Float(nr)
                    data[i + 1] = Float(ng)
                    data[i + 2] = Float(nb)
                    data[i + 3] = 1
                    i += 4
                }
            }
        }
        let filter = cubeFilter(data: data, dimension: n)
        lock.lock(); hslCache[key] = filter
        if hslCache.count > 16 { hslCache.removeAll() }
        lock.unlock()
        return filter
    }

    /// One RGB sample through the 8-band HSL, with triangular feather between
    /// neighbouring band centres so shifts blend instead of banding.
    private static func applyHSL(r: Double, g: Double, b: Double,
                                 bands: HSLBands) -> (Double, Double, Double) {
        var (h, s, l) = rgbToHSL(r, g, b)
        guard s > 0.001 else { return (r, g, b) }   // greys carry no hue

        let deg = h * 360
        var hueShift = 0.0, satMul = 0.0, lumMul = 0.0
        for band in 0..<8 {
            let w = bandWeight(deg, band: band)
            guard w > 0 else { continue }
            hueShift += w * bands.hue[band] * 30      // ±30° per band
            satMul += w * bands.sat[band]
            lumMul += w * bands.lum[band]
        }
        h = (h + hueShift / 360).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        s = clamp01(s * (1 + satMul))
        l = clamp01(l * (1 + lumMul))
        return hslToRGB(h, s, l)
    }

    /// Triangular membership of `deg` in band `band`, wrapping at 360°.
    private static func bandWeight(_ deg: Double, band: Int) -> Double {
        let centers = HSLBands.centers
        let c = centers[band]
        let prev = centers[(band + centers.count - 1) % centers.count]
        let next = centers[(band + 1) % centers.count]
        func wrapped(_ a: Double, _ b: Double) -> Double {
            var d = abs(a - b).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return d
        }
        let dCenter = wrapped(deg, c)
        let spanPrev = wrapped(c, prev)
        let spanNext = wrapped(c, next)
        // Inside the half-span toward the nearest neighbour → linear falloff.
        let span = (angleIsBefore(deg, c) ? spanPrev : spanNext) * 0.5 + 0.0001
        let half = max(spanPrev, spanNext)
        _ = half
        return max(0, 1 - dCenter / max(span, 15))
    }

    private static func angleIsBefore(_ deg: Double, _ center: Double) -> Bool {
        var d = (deg - center).truncatingRemainder(dividingBy: 360)
        if d < -180 { d += 360 }; if d > 180 { d -= 360 }
        return d < 0
    }

    // MARK: Spline (monotone cubic, Fritsch–Carlson — no overshoot)

    /// Returns a 256-sample identity-or-curve LUT for later sampling, or nil
    /// for an identity (empty) curve.
    private static func spline(_ points: [CurvePoint]?) -> [Double]? {
        guard let points, points.count >= 2 else { return nil }
        let pts = points.sorted { $0.x < $1.x }
        let xs = pts.map { clamp01($0.x) }, ys = pts.map { clamp01($0.y) }
        let n = xs.count
        // Secant slopes.
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = max(1e-6, xs[i + 1] - xs[i])
            d[i] = (ys[i + 1] - ys[i]) / dx
        }
        // Tangents.
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 { m[i] = 0 }
            else { m[i] = (d[i - 1] + d[i]) / 2 }
        }
        // Fritsch–Carlson monotonicity clamp.
        for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let h = hypot(a, b)
            if h > 3 { let t = 3 / h; m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        let samples = 256
        var lut = [Double](repeating: 0, count: samples)
        for s in 0..<samples {
            let x = Double(s) / Double(samples - 1)
            lut[s] = clamp01(hermite(x, xs: xs, ys: ys, m: m))
        }
        return lut
    }

    private static func hermite(_ x: Double, xs: [Double], ys: [Double], m: [Double]) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var i = 0
        while i < xs.count - 1 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        let t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]
    }

    private static func sampleCurve(_ lut: [Double]?, _ v: Double) -> Double {
        guard let lut else { return v }
        let idx = clamp01(v) * Double(lut.count - 1)
        let lo = Int(idx), hi = min(lut.count - 1, lo + 1)
        let f = idx - Double(lo)
        return lut[lo] * (1 - f) + lut[hi] * f
    }

    // MARK: Helpers

    private static func cubeFilter(data: [Float], dimension: Int) -> CIFilter {
        let filter = CIFilter(name: "CIColorCube")!
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        return filter
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    private static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h / 6, s, l)
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s != 0 else { return (l, l, l) }
        func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (hue2rgb(p, q, h + 1.0 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1.0 / 3))
    }

    // Cheap deterministic hashes for the caches.
    private static func hash(curves: CurveSet?, wheels: ColorWheels?) -> Int {
        var h = Hasher()
        if let c = curves {
            for p in c.master + c.red + c.green + c.blue { h.combine(Int(p.x * 1000)); h.combine(Int(p.y * 1000)) }
            h.combine(c.master.count); h.combine(c.red.count); h.combine(c.green.count); h.combine(c.blue.count)
        }
        if let w = wheels {
            for v in [w.liftR, w.liftG, w.liftB, w.gammaR, w.gammaG, w.gammaB, w.gainR, w.gainG, w.gainB] {
                h.combine(Int(v * 1000))
            }
        }
        return h.finalize()
    }

    private static func hash(hsl: HSLBands) -> Int {
        var h = Hasher()
        for v in hsl.hue + hsl.sat + hsl.lum { h.combine(Int(v * 1000)) }
        return h.finalize()
    }
}

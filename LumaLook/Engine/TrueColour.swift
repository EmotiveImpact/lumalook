import CoreImage
import Foundation

// MARK: - True Colour
//
// Keeps skin rich and true under every look. Two parts:
//
// 1. Tone (always fixed). Contrast and brightness used to run through
//    CIColorControls in Core Image's LINEAR working space, where contrast
//    pivots at linear 0.5 (sRGB 0.735, a light grey). Contrast 1.2 there
//    clipped everything below sRGB 0.32 to black, which is most of a deep
//    brown face, and brightness added in linear light lifted blacks into a
//    grey veil. Now contrast pivots at mid grey on gamma-encoded values,
//    brightness is added there too, and a soft toe and shoulder land black
//    on black and white on white, so nothing clips. This part stays on
//    whatever the switch says: turning it off would crush dark skin again.
//
// 2. Skin protection (the True Colour switch, on by default, You > Preferences).
//    On: contrast and brightness change LIGHTNESS only (Oklab L), so skin
//    keeps its hue and chroma as it gets lighter or darker, saturation scales
//    Oklab chroma, and film and imported LUTs get a skin guard that holds
//    skin hue, chroma and shadow depth close to the photo where the LUT
//    strays too far, smoothly, so a face never breaks into patches. Off:
//    classic per-channel contrast (which adds a little saturation, like
//    print film) and every LUT exactly as authored.
//
// Everything here is pure colour, built into small cubes on the CPU once per
// setting and cached, then applied with the stock `colorCubeWithColorSpace`
// filter. No Metal kernels, no build changes, and it bakes cleanly into
// exported LUTs. Measured on Black and brown skin with tools/skin-test.
enum TrueColour {

    static let key = "lumalook.trueColour"

    /// The switch. On unless the person turned it off.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Installed recipe looks are baked into cubes at install time. This
    /// stamp says which engine and switch position baked them; when it
    /// differs from `bakeStamp`, AppModel bakes them again.
    static let bakedKey = "lumalook.trueColour.bakedWith"
    static var bakeStamp: String { "tone2-" + (isOn ? "on" : "off") }

    // MARK: Tone

    /// Saturation, contrast and brightness as one colour cube, or nil when
    /// they do nothing. `contrast` 1 and `brightness` 0 are neutral, as in
    /// CIColorControls, so recipes and sliders keep their numbers.
    static func toneFilter(contrast: Float, saturation: Float, brightness: Float,
                           protectSkin: Bool = TrueColour.isOn) -> CIFilter? {
        let c = Double(contrast), s = Double(saturation), b = Double(brightness)
        if abs(c - 1) < 1e-4 && abs(s - 1) < 1e-4 && abs(b) < 1e-4 { return nil }
        let key = ToneKey(c: Int((c * 10_000).rounded()), s: Int((s * 10_000).rounded()),
                          b: Int((b * 10_000).rounded()), skin: protectSkin)
        lock.lock()
        if let data = toneCache[key] { lock.unlock(); return cubeFilter(data, toneSize) }
        lock.unlock()

        let data = buildTone(contrast: c, saturation: s, brightness: b, protectSkin: protectSkin)
        lock.lock()
        if toneCache.count >= 32 { toneCache.removeAll() }
        toneCache[key] = data
        lock.unlock()
        return cubeFilter(data, toneSize)
    }

    /// The tone curve on gamma-encoded values: contrast about mid grey,
    /// brightness added after it, then a soft toe that lands black on black
    /// and keeps at least half the slope (shadow texture survives), and the
    /// same shoulder at the top for white.
    static func curve(_ e: Double, contrast c: Double, brightness b: Double) -> Double {
        var y = c * (e - 0.5) + 0.5 + b
        let lo = 0.5 - 0.5 * c + b          // where black would land
        if lo < 0 { y = bend(y, lo) }
        let hi = 0.5 + 0.5 * c + b          // where white would land
        if hi > 1 { y = 1 - bend(1 - y, 1 - hi) }
        return min(max(y, 0), 1)
    }

    /// Below `t` the straight line bends into a parabola that meets the line
    /// smoothly at `t` and lands `lo` on 0. t = max(0.2, 3|lo|) keeps it
    /// monotonic with half the slope at the bottom.
    private static func bend(_ y: Double, _ lo: Double) -> Double {
        let t = max(0.2, -3 * lo)
        guard y < t else { return y }
        if y < lo { return 0 }
        let k = -lo / ((lo - t) * (lo - t))
        return y + k * (y - t) * (y - t)
    }

    private struct ToneKey: Hashable { let c: Int, s: Int, b: Int, skin: Bool }
    private static let toneSize = 33
    private static let lock = NSLock()
    private static var toneCache: [ToneKey: Data] = [:]

    private static func buildTone(contrast c: Double, saturation s: Double,
                                  brightness b: Double, protectSkin: Bool) -> Data {
        let n = toneSize
        var out = [Float](repeating: 1, count: n * n * n * 4)
        // Lightness map, tabulated: grey L -> encoded -> curve -> back to L.
        let tableSize = 1024
        let lightness: [Double] = (0..<tableSize).map { i in
            let L = Double(i) / Double(tableSize - 1)
            let e = encode(L * L * L)
            return cbrt(decode(curve(e, contrast: c, brightness: b)))
        }
        func mapL(_ L: Double) -> Double {
            let x = min(max(L, 0), 1) * Double(tableSize - 1)
            let i = min(Int(x), tableSize - 2)
            let f = x - Double(i)
            return lightness[i] * (1 - f) + lightness[i + 1] * f
        }
        var idx = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let er = Double(ri) / Double(n - 1)
                    let eg = Double(gi) / Double(n - 1)
                    let eb = Double(bi) / Double(n - 1)
                    let rgb: (Double, Double, Double)
                    if protectSkin {
                        rgb = lightnessTone(er, eg, eb, saturation: s, mapL: mapL)
                    } else {
                        // Classic: CIColorControls' saturation, then the
                        // curve per channel, all on encoded values.
                        let w = 0.2125 * er + 0.7154 * eg + 0.0721 * eb
                        rgb = (curve(w + s * (er - w), contrast: c, brightness: b),
                               curve(w + s * (eg - w), contrast: c, brightness: b),
                               curve(w + s * (eb - w), contrast: c, brightness: b))
                    }
                    // Clamped: rounding left a few lightness-only values a
                    // hair above 1 (1.0000005).
                    out[idx] = Float(min(max(rgb.0, 0), 1))
                    out[idx + 1] = Float(min(max(rgb.1, 0), 1))
                    out[idx + 2] = Float(min(max(rgb.2, 0), 1))
                    idx += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Lightness-only tone: Oklab L through the curve, a and b scaled by
    /// saturation and otherwise kept, so hue and chroma hold. A colour that
    /// would leave the sRGB gamut gives up chroma, never lightness.
    private static func lightnessTone(_ er: Double, _ eg: Double, _ eb: Double,
                                      saturation s: Double,
                                      mapL: (Double) -> Double) -> (Double, Double, Double) {
        let lab = oklab(decode(er), decode(eg), decode(eb))
        let L = mapL(lab.0)
        let a = lab.1 * s, b = lab.2 * s
        var lin = linear(L, a, b)
        if !inGamut(lin) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                if inGamut(linear(L, a * mid, b * mid)) { lo = mid } else { hi = mid }
            }
            lin = linear(L, a * lo, b * lo)
        }
        return (encode(lin.0), encode(lin.1), encode(lin.2))
    }

    private static func inGamut(_ v: (Double, Double, Double)) -> Bool {
        let e = 1e-6
        return v.0 >= -e && v.1 >= -e && v.2 >= -e && v.0 <= 1 + e && v.1 <= 1 + e && v.2 <= 1 + e
    }

    // MARK: Skin guard for LUTs

    /// The cube data to use for a creative LUT: guarded when True Colour is
    /// on, exactly as authored when it is off. Colour LUTs get the skin
    /// guard; black-and-white LUTs get a shadow floor instead (the deepest
    /// tones keep their separation), since there is no skin colour to hold.
    ///
    /// Two kinds of cube are always left as authored: one this app made
    /// itself (its tone already went through True Colour), and one with its
    /// own input range (DOMAIN_MIN/MAX), where a point of the cube is not a
    /// plain sRGB colour, so there is no "skin" to recognise by position.
    static func lutData(for lut: ParsedLUT) -> Data {
        guard isOn, !lut.bakedByLumalook, !lut.hasCustomDomain else { return lut.rgbaFloatData }
        let key = contentKey(lut)
        guardLock.lock()
        if let cached = guardCache[key] { guardLock.unlock(); return cached }
        guardLock.unlock()
        let data = guarded(lut)
        guardLock.lock()
        if guardCache.count >= 8 { guardCache.removeAll() }
        guardCache[key] = data
        guardLock.unlock()
        return data
    }

    private static let guardLock = NSLock()
    private static var guardCache: [Int: Data] = [:]

    /// Skin is chosen by the INPUT colour: CIELAB hue 20 to 85 degrees
    /// (feathered 5 to 100), chroma 4 to 70, lightness under 88. For those
    /// colours the guard works out the nearest colour that is still fair to
    /// the skin tone that went in:
    ///   hue    within 6 degrees of it
    ///   chroma between 0.85x and 1.2x of it
    ///   depth  no darker than 0.8x its lightness in the shadows (L* < 45)
    /// and moves the LUT's output 80% of the way there. Where the LUT is
    /// already inside that tolerance the nearest fair colour is its own
    /// output, so nothing moves and the look keeps its character.
    ///
    /// Three things keep the result smooth, so a face does not break into
    /// patches (found by tools/skin-test/check_truecolour.swift):
    /// 1. The move is a straight blend of colours (CIELAB a and b), not a turn
    ///    of the hue angle. A turn has to pick a direction, and where a look
    ///    sends skin to its opposite colour (a cold look turning warm shadows
    ///    teal) the direction flipped between two neighbouring colours, one
    ///    going green and the next red.
    /// 2. The edge of the skin range is never sharper than 8 CIELAB units
    ///    (`skinHue`).
    /// 3. The correction is then spread a little over neighbouring colours
    ///    (`smoothCorrection`).
    /// What is left is a limit of judging skin by colour alone: the deepest
    /// skin tones sit a few steps from neutral grey, so "protect this, leave
    /// that" has to turn within those few steps. A guard that knows where the
    /// people are in the picture would not have that limit.
    private static func guarded(_ lut: ParsedLUT) -> Data {
        let n = lut.size
        guard n >= 2, lut.rgbaFloatData.count >= n * n * n * 16 else { return lut.rgbaFloatData }
        var values = [Float](repeating: 0, count: n * n * n * 4)
        _ = values.withUnsafeMutableBytes { lut.rgbaFloatData.copyBytes(to: $0) }
        let authored = values
        let strength = 0.8
        let mono = isMonochrome(values, n)
        var idx = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    defer { idx += 4 }
                    let x = lab(Double(ri) / Double(n - 1), Double(gi) / Double(n - 1),
                                Double(bi) / Double(n - 1))
                    if mono {
                        // Shadow floor: only the deepest tones, tone only.
                        let shadow = 1 - smoothstep(30, 50, x.0)
                        guard shadow > 0 else { continue }
                        let y = lab(Double(values[idx]), Double(values[idx + 1]), Double(values[idx + 2]))
                        let floor = x.0 * 0.8
                        guard y.0 < floor else { continue }
                        let L = y.0 + (floor - y.0) * strength * shadow
                        write(srgb(L, y.1, y.2), into: &values, at: idx)
                        continue
                    }
                    let Cx = (x.1 * x.1 + x.2 * x.2).squareRoot()
                    let hx = atan2(x.2, x.1) * 180 / .pi
                    let w = skinHue(hx, Cx)
                        * smoothstep(3, 8, Cx) * (1 - smoothstep(60, 75, Cx))
                        * (1 - smoothstep(85, 92, x.0)) * strength
                    guard w > 0 else { continue }       // so Cx is above 3 from here on
                    let y = lab(Double(values[idx]), Double(values[idx + 1]), Double(values[idx + 2]))
                    let Cy = (y.1 * y.1 + y.2 * y.2).squareRoot()
                    let hy = atan2(y.2, y.1) * 180 / .pi
                    var dh = (hy - hx + 180).truncatingRemainder(dividingBy: 360)
                    if dh < 0 { dh += 360 }
                    dh -= 180
                    // The nearest fair colour. It may keep up to 6 degrees of
                    // the LUT's hue shift, but that allowance fades out where
                    // the LUT's hue says nothing reliable: when it lands
                    // opposite the skin tone (the +6 or -6 choice would flip
                    // there), and when the output is nearly grey (a grey has
                    // no hue to keep).
                    let ratio = Cy / Cx
                    let kept = min(max(dh, -6), 6) * (1 - smoothstep(90, 180, abs(dh)))
                        * smoothstep(0.1, 0.4, ratio)
                    let hFair = (hx + kept) * .pi / 180
                    let cFair = Cx * min(max(ratio, 0.85), 1.2)
                    let a = y.1 + w * (cFair * cos(hFair) - y.1)
                    let b = y.2 + w * (cFair * sin(hFair) - y.2)
                    // depth: in the shadows skin keeps 0.8x its lightness
                    var L = y.0
                    let floor = x.0 * 0.8
                    if L < floor { L += (floor - L) * w * (1 - smoothstep(35, 50, x.0)) }
                    write(srgb(L, a, b), into: &values, at: idx)
                }
            }
        }
        if !mono && guardSmoothing > 0 { smoothCorrection(&values, authored: authored, n) }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// How much a colour's hue says "skin", 0 to 1. Fully inside 20 to 85
    /// degrees. Outside, it fades over 15 degrees or over 8 CIELAB units of
    /// colour distance from that range, whichever is gentler. The second
    /// rule matters in dark, barely coloured tones, where 15 degrees is less
    /// than one step of an 8-bit picture: with the angle alone the guard was
    /// fully on for one colour and fully off for its neighbour.
    private static func skinHue(_ hue: Double, _ chroma: Double) -> Double {
        let byAngle = smoothstep(5, 20, hue) * (1 - smoothstep(85, 100, hue))
        var off = abs(hue - 52.5)                   // degrees from the middle of the range
        if off > 180 { off = 360 - off }
        let outside = max(0, off - 32.5)            // degrees outside it
        let distance = outside >= 90 ? chroma : chroma * sin(outside * .pi / 180)
        return max(byAngle, 1 - smoothstep(0, 8, distance))
    }

    /// How far each correction is spread, as a share of the colour range
    /// (0.012 is about 3 steps of 255). Chosen with the skin test on every
    /// film look (tools/skin-test/gate.py): at 0.02 and above the spread
    /// thins the correction at the edge of the skin range and four looks go
    /// ashy on deep skin; at 0.012 none is worse than with no spread at all,
    /// and the rough steps between neighbouring colours fall by about 85%.
    /// Change it only with the gate.
    static let guardSmoothing = 0.012

    /// Spreads the guard's correction (guarded minus authored) over
    /// neighbouring colours with a Gaussian along red, green and blue, then
    /// adds it back. A colour whose whole neighbourhood needed no correction
    /// is left exactly as authored, bit for bit.
    ///
    /// Some film cubes store values a little outside 0...1 (a blue of -0.07
    /// in a deep orange). The guard writes colours a screen can show, so on
    /// skin it has already brought those into range. That is not a
    /// correction, and it is measured out here (`shown`) so it is never
    /// passed on to the colours next door.
    private static func smoothCorrection(_ values: inout [Float], authored: [Float], _ n: Int) {
        func shown(_ x: Float) -> Float { min(max(x, 0), 1) }
        let sigma = guardSmoothing * Double(n - 1)
        let radius = max(1, Int(3 * sigma + 0.5))
        var kernel = (-radius...radius).map { Float(exp(-0.5 * Double($0 * $0) / (sigma * sigma))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }

        let count = n * n * n
        var delta = [Float](repeating: 0, count: count * 3)
        for i in 0..<count {
            delta[i * 3] = values[i * 4] - shown(authored[i * 4])
            delta[i * 3 + 1] = values[i * 4 + 1] - shown(authored[i * 4 + 1])
            delta[i * 3 + 2] = values[i * 4 + 2] - shown(authored[i * 4 + 2])
        }

        var line = [Float](repeating: 0, count: n * 3)
        let strides = [1, n, n * n]                 // red, green, blue
        for axis in 0..<3 {
            let step = strides[axis]
            let outer = strides[(axis + 1) % 3], inner = strides[(axis + 2) % 3]
            for u in 0..<n {
                for v in 0..<n {
                    let start = u * outer + v * inner
                    var busy = false
                    for k in 0..<n {
                        let p = (start + k * step) * 3
                        line[k * 3] = delta[p]
                        line[k * 3 + 1] = delta[p + 1]
                        line[k * 3 + 2] = delta[p + 2]
                        if delta[p] != 0 || delta[p + 1] != 0 || delta[p + 2] != 0 { busy = true }
                    }
                    guard busy else { continue }        // most of the cube is not skin
                    for k in 0..<n {
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        for t in -radius...radius {
                            let j = min(max(k + t, 0), n - 1) * 3
                            let weight = kernel[t + radius]
                            r += weight * line[j]
                            g += weight * line[j + 1]
                            b += weight * line[j + 2]
                        }
                        let p = (start + k * step) * 3
                        delta[p] = r
                        delta[p + 1] = g
                        delta[p + 2] = b
                    }
                }
            }
        }

        for i in 0..<count {
            let d = (delta[i * 3], delta[i * 3 + 1], delta[i * 3 + 2])
            guard d.0 != 0 || d.1 != 0 || d.2 != 0 else {
                values[i * 4] = authored[i * 4]
                values[i * 4 + 1] = authored[i * 4 + 1]
                values[i * 4 + 2] = authored[i * 4 + 2]
                continue
            }
            values[i * 4] = shown(shown(authored[i * 4]) + d.0)
            values[i * 4 + 1] = shown(shown(authored[i * 4 + 1]) + d.1)
            values[i * 4 + 2] = shown(shown(authored[i * 4 + 2]) + d.2)
        }
    }

    /// Black and white, or toned close to it: colourful inputs keep under
    /// 15% of their chroma (median over a sample of the cube). The film cubes
    /// split cleanly: mono and toned mono sit at 0 to 8%, the most muted
    /// colour look (MS15) at 28%, everything else above 50%.
    private static func isMonochrome(_ values: [Float], _ n: Int) -> Bool {
        var ratios: [Double] = []
        let step = max(1, n / 9)
        for bi in stride(from: 0, to: n, by: step) {
            for gi in stride(from: 0, to: n, by: step) {
                for ri in stride(from: 0, to: n, by: step) {
                    let x = lab(Double(ri) / Double(n - 1), Double(gi) / Double(n - 1),
                                Double(bi) / Double(n - 1))
                    let Cx = (x.1 * x.1 + x.2 * x.2).squareRoot()
                    guard Cx > 20 else { continue }
                    let i = ((bi * n + gi) * n + ri) * 4
                    let y = lab(Double(values[i]), Double(values[i + 1]), Double(values[i + 2]))
                    ratios.append((y.1 * y.1 + y.2 * y.2).squareRoot() / Cx)
                }
            }
        }
        guard !ratios.isEmpty else { return false }
        ratios.sort()
        return ratios[ratios.count / 2] < 0.15
    }

    private static func write(_ rgb: (Double, Double, Double), into values: inout [Float], at i: Int) {
        values[i] = Float(min(max(rgb.0, 0), 1))
        values[i + 1] = Float(min(max(rgb.1, 0), 1))
        values[i + 2] = Float(min(max(rgb.2, 0), 1))
    }

    /// A cheap fingerprint of a LUT: size, length and about 8,000 of its
    /// values. The step is ODD on purpose. A cube holds four floats a colour
    /// and its sides are usually a power of two (64), so an even step such as
    /// 256 kept landing on the same channel of the same column: only red,
    /// only where red-in is 0. Two LUTs that agreed there (any pair of plain
    /// per-channel curves with the same black) shared one fingerprint, and
    /// one look would have been shown with the other's guarded colours. An
    /// odd step walks through every channel and across the whole cube.
    static func contentKey(_ lut: ParsedLUT) -> Int {
        var hasher = Hasher()
        hasher.combine(lut.size)
        hasher.combine(lut.rgbaFloatData.count)
        lut.rgbaFloatData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            let step = (floats.count / 8192) | 1
            var i = 0
            while i < floats.count { hasher.combine(floats[i].bitPattern); i += step }
        }
        return hasher.finalize()
    }

    // MARK: Colour maths

    private static func cubeFilter(_ data: Data, _ size: Int) -> CIFilter {
        let filter = CIFilter(name: "CIColorCubeWithColorSpace")!
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return filter
    }

    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func decode(_ e: Double) -> Double {
        e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4)
    }

    static func encode(_ v: Double) -> Double {
        let x = max(v, 0)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// Linear sRGB -> Oklab (Björn Ottosson, 2020).
    private static func oklab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Oklab -> linear sRGB.
    private static func linear(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let l = L + 0.3963377774 * a + 0.2158037573 * b
        let m = L - 0.1055613458 * a - 0.0638541728 * b
        let s = L - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    /// Encoded sRGB -> CIELAB (D65), the space the skin test judges in.
    private static func lab(_ er: Double, _ eg: Double, _ eb: Double) -> (Double, Double, Double) {
        let r = decode(min(max(er, 0), 1)), g = decode(min(max(eg, 0), 1)), b = decode(min(max(eb, 0), 1))
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIELAB (D65) -> encoded sRGB, unclamped.
    private static func srgb(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        let e = 216.0 / 24389.0, k = 24389.0 / 27.0
        func inv(_ f: Double) -> Double { let f3 = f * f * f; return f3 > e ? f3 : (116 * f - 16) / k }
        let x = inv(fx) * 0.95047
        let y = (L > k * e ? fy * fy * fy : L / k)
        let z = inv(fz) * 1.08883
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return (encode(r), encode(g), encode(bl))
    }
}

// Checks the True Colour engine itself: the app's own TrueColour.swift,
// LUTParser.swift and LUTDensifier.swift, compiled in, not a copy. The skin
// test (verify.py) asks "does every look we ship keep skin true?". This asks
// the question underneath it: "does the engine keep its promises on ANY look,
// including ones nobody has made yet?" It builds awkward and hostile looks on
// purpose and checks what comes out.
//
//   cp tools/skin-test/check_truecolour.swift /tmp/tc/main.swift
//   swiftc -O -o /tmp/tc/check /tmp/tc/main.swift LumaLook/Engine/TrueColour.swift \
//       LumaLook/Engine/LUTParser.swift LumaLook/Engine/LUTDensifier.swift
//   /tmp/tc/check
//
// Exits 1 if any check fails, so the Mac runner stops before it bakes.
// Run it whenever TrueColour.swift, the LUT parser or the densifier change.
import Foundation
import CoreImage
#if os(macOS)
import CoreImage.CIFilterBuiltins
#endif

// MARK: - Reporting

var checks = 0
var failed: [String] = []

func section(_ title: String) { print("\n" + title) }

func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    checks += 1
    let note = detail.isEmpty ? "" : "   [" + detail + "]"
    if ok {
        print("  ok    " + name + note)
    } else {
        failed.append(name)
        print("  FAIL  " + name + note)
    }
}

func f3(_ x: Double) -> String { String(format: "%.3f", x) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }

// MARK: - Colour maths, written again here on purpose
//
// The engine has its own copies of these. Checking it against a second,
// separate copy means a slip in either one shows up as a disagreement.

typealias RGB = (Double, Double, Double)

func dec(_ e: Double) -> Double {
    e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4)
}

func enc(_ v: Double) -> Double {
    let x = max(v, 0)
    return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
}

func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

/// Encoded sRGB -> Oklab.
func oklab(_ c: RGB) -> RGB {
    let r = dec(clamp01(c.0)), g = dec(clamp01(c.1)), b = dec(clamp01(c.2))
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

/// Encoded sRGB -> CIELAB (D65).
func cielab(_ c: RGB) -> RGB {
    let r = dec(clamp01(c.0)), g = dec(clamp01(c.1)), b = dec(clamp01(c.2))
    let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
}

/// CIELAB (D65) -> encoded sRGB, or nil when no screen can show that colour.
func screenColour(_ lab: RGB) -> RGB? {
    let fy = (lab.0 + 16) / 116, fx = fy + lab.1 / 500, fz = fy - lab.2 / 200
    func inv(_ t: Double) -> Double {
        let cube = t * t * t
        return cube > 216.0 / 24389.0 ? cube : (116 * t - 16) * 27.0 / 24389.0
    }
    let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
    let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
    let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
    let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
    guard min(r, g, b) >= 0, max(r, g, b) <= 1 else { return nil }
    return (enc(r), enc(g), enc(b))
}

func chroma(_ lab: RGB) -> Double { (lab.1 * lab.1 + lab.2 * lab.2).squareRoot() }
func hue(_ lab: RGB) -> Double { atan2(lab.2, lab.1) * 180 / .pi }

/// Signed hue difference a - b, in -180...180.
func hueDiff(_ a: Double, _ b: Double) -> Double {
    var d = (a - b + 180).truncatingRemainder(dividingBy: 360)
    if d < 0 { d += 360 }
    return d - 180
}

func hex(_ s: String) -> RGB {
    let v = Int(s.dropFirst(), radix: 16) ?? 0
    return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
}

/// The same colour with less light on it (stops are photographic stops).
func darker(_ c: RGB, stops: Double) -> RGB {
    let k = pow(2, -stops)
    return (enc(dec(c.0) * k), enc(dec(c.1) * k), enc(dec(c.2) * k))
}

// MARK: - Cubes

struct Cube {
    let n: Int
    let v: [Float]

    init(_ data: Data, _ n: Int) {
        self.n = n
        v = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func index(_ r: Int, _ g: Int, _ b: Int) -> Int { ((b * n + g) * n + r) * 4 }

    func at(_ r: Int, _ g: Int, _ b: Int) -> RGB {
        let i = index(r, g, b)
        return (Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
    }

    /// Trilinear lookup, as Core Image does it.
    func sample(_ c: RGB) -> RGB {
        func split(_ x: Double) -> (Int, Double) {
            let p = clamp01(x) * Double(n - 1)
            let i = min(Int(p), n - 2)
            return (i, p - Double(i))
        }
        let (r0, fr) = split(c.0), (g0, fg) = split(c.1), (b0, fb) = split(c.2)
        var out = (0.0, 0.0, 0.0)
        for db in 0...1 { for dg in 0...1 { for dr in 0...1 {
            let w = (dr == 1 ? fr : 1 - fr) * (dg == 1 ? fg : 1 - fg) * (db == 1 ? fb : 1 - fb)
            let p = at(r0 + dr, g0 + dg, b0 + db)
            out = (out.0 + w * p.0, out.1 + w * p.1, out.2 + w * p.2)
        }}}
        return out
    }

    var allFiniteInRange: Bool {
        for x in v where !(x.isFinite && x >= 0 && x <= 1) { return false }
        return true
    }
}

/// A LUT made from a rule, red fastest, as .cube files and the app store them.
func makeLUT(_ n: Int, baked: Bool = false, domainMax: Float = 1, _ rule: (RGB) -> RGB) -> ParsedLUT {
    var values = [Float](repeating: 1, count: n * n * n * 4)
    var i = 0
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
        let out = rule((Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1)))
        values[i] = Float(out.0)
        values[i + 1] = Float(out.1)
        values[i + 2] = Float(out.2)
        i += 4
    }}}
    return ParsedLUT(size: n, rgbaFloatData: values.withUnsafeBufferPointer { Data(buffer: $0) },
                     domainMin: (0, 0, 0), domainMax: (domainMax, domainMax, domainMax),
                     bakedByLumalook: baked)
}

func toneCube(_ c: Double, _ s: Double, _ b: Double, skin: Bool) -> Cube? {
    guard let filter = TrueColour.toneFilter(contrast: Float(c), saturation: Float(s),
                                             brightness: Float(b), protectSkin: skin),
          let data = filter.value(forKey: "inputCubeData") as? Data,
          data.count == 33 * 33 * 33 * 16 else { return nil }
    return Cube(data, 33)
}

UserDefaults.standard.set(true, forKey: TrueColour.key)
let started = Date()

// MARK: - 1. The tone curve

section("1. The tone curve, at every position of the Contrast and Exposure sliders")
do {
    // The sliders reach contrast 0.45...1.45 and brightness -0.33...0.33.
    var reverses = 0, outOfRange = 0, settings = 0
    var worstClip = 0.0, worstClipAt = ""
    var lookRangeClips = 0
    for ci in 0...20 {
        let c = 0.45 + Double(ci) * 0.05
        for bi in 0...34 {
            let b = -0.34 + Double(bi) * 0.02
            settings += 1
            var last = -1.0, black = 0, white = 0
            for i in 0...1000 {
                let y = TrueColour.curve(Double(i) / 1000, contrast: c, brightness: b)
                if !(y.isFinite && y >= 0 && y <= 1) { outOfRange += 1 }
                if y < last - 1e-12 { reverses += 1 }
                last = y
                if i > 0 && y <= 0 { black += 1 }
                if i < 1000 && y >= 1 { white += 1 }
            }
            let clip = Double(max(black, white)) / 1000
            if clip > worstClip { worstClip = clip; worstClipAt = "contrast \(f3(c)), brightness \(f3(b))" }
            // The range looks are written in (see the rulebook).
            if c <= 1.3001 && abs(b) <= 0.1001 && clip > 0 { lookRangeClips += 1 }
        }
    }
    check(outOfRange == 0, "every output is a real number between 0 and 1", "\(settings) settings x 1001 tones")
    check(reverses == 0, "a brighter tone never comes out darker than a dimmer one")
    check(lookRangeClips == 0, "inside the range looks are written in, no tone is clipped to black or white")
    check(worstClip <= 0.015, "at the far ends of both sliders at once, at most 1.5% of tones clip",
          "worst \(f1(worstClip * 100))% at \(worstClipAt)")

    var ends = true, mid = true
    for ci in 0...17 {
        let c = 0.45 + Double(ci) * 0.05
        for b in [-0.1, -0.03, 0.0, 0.03, 0.1] {
            let lo = 0.5 - 0.5 * c + b, hi = 0.5 + 0.5 * c + b
            if abs(TrueColour.curve(0, contrast: c, brightness: b) - max(lo, 0)) > 1e-9 { ends = false }
            if abs(TrueColour.curve(1, contrast: c, brightness: b) - min(hi, 1)) > 1e-9 { ends = false }
        }
        if abs(TrueColour.curve(0.5, contrast: c, brightness: 0) - 0.5) > 1e-9 { mid = false }
    }
    check(ends, "black lands on black and white on white whenever a look adds contrast")
    check(mid, "mid grey stays mid grey when only contrast changes")
    check(TrueColour.toneFilter(contrast: 1, saturation: 1, brightness: 0) == nil,
          "a look that changes nothing costs nothing (no filter is made)")
}

// MARK: - 1b. The Shadows and Highlights curve

section("1b. The Shadows and Highlights curve, at every position of both sliders")
do {
    var smallestSlope = 10.0, pinned = true, turnedBack: [String] = []
    for si in -10...10 {
        for hi in -10...10 {
            let s = Double(si) / 10, h = Double(hi) / 10
            var prev = TrueColour.shadowHighlightCurve(0, shadows: s, highlights: h)
            if abs(prev) > 1e-9 || abs(TrueColour.shadowHighlightCurve(1, shadows: s, highlights: h) - 1) > 1e-9 {
                pinned = false
            }
            for i in 1...1000 {
                let y = TrueColour.shadowHighlightCurve(Double(i) / 1000, shadows: s, highlights: h)
                smallestSlope = min(smallestSlope, (y - prev) * 1000)
                if y < prev - 1e-12, turnedBack.count < 4 { turnedBack.append("shadows \(s), highlights \(h)") }
                prev = y
            }
        }
    }
    check(pinned, "black stays black and white stays white at all 441 settings")
    check(turnedBack.isEmpty && smallestSlope > 0.05,
          "the curve never turns back or goes flat (tones never swap places or merge)",
          turnedBack.isEmpty ? "smallest slope \(f3(smallestSlope))" : turnedBack.joined(separator: "; "))

    func grey(_ v: Double, _ s: Double, _ h: Double) -> Double {
        TrueColour.shadowHighlightCurve(v / 255, shadows: s, highlights: h) * 255
    }
    // What CIHighlightShadowAdjust gave greys at Shadows +50, measured on a
    // Mac before it was replaced: the slider keeps its feel.
    let was: [(Double, Double)] = [(26, 45), (64, 97), (128, 157), (191, 202)]
    let off = was.map { abs(grey($0.0, 0.5, 0) - $0.1) }.max() ?? 0
    check(off < 1.5, "Shadows at +50 puts greys where the slider always put them, to within 1.5 of 255",
          "largest difference \(f1(off))")
    let lowerHalf = [grey(127.5, 0, 0.5) - 127.5, grey(127.5, 0, -0.5) - 127.5, grey(64, 0, 1) - 64,
                     grey(100, 0, -1) - 100].map { abs($0) }.max() ?? 0
    check(lowerHalf < 1e-6, "Highlights leaves mid grey and everything below it alone",
          "largest change \(f3(lowerHalf))")
    let up = grey(191.25, 0, 0.5) - 191.25, down = grey(191.25, 0, -0.5) - 191.25
    check(abs(up + down) < 0.01 && up > 12 && up < 20,
          "Highlights moves 75% grey by the same amount up and down", "up \(f1(up)), down \(f1(down)) of 255")
    check(grey(26, -0.5, 0) < 26 && grey(26, -0.5, 0) > 12 && grey(26, -1, 0) > 6,
          "Shadows pulled down deepens the darks without flattening them",
          "10% grey 26 goes to \(f1(grey(26, -0.5, 0))) at -50 and \(f1(grey(26, -1, 0))) at -100")
}

// MARK: - 2. The tone cube

section("2. The colour cube the tone curve is baked into, True Colour on and off")
let toneSettings: [(Double, Double, Double)] = [
    (1.2, 1.0, 0), (1.3, 1.15, 0.02), (0.8, 0.9, -0.03), (1.0, 1.4, 0), (1.1, 0.6, 0.05),
    (1.45, 2.0, 0.33), (0.45, 0.0, -0.33), (1.45, 1.0, -0.33),
]
do {
    var built = 0, finite = true, greyStays = true, greyRises = true, greyAgrees = true
    var worstHue = 0.0, worstChromaGain = 0.0, engineGap = 0.0
    for (c, s, b) in toneSettings {
        for skin in [true, false] {
            guard let cube = toneCube(c, s, b, skin: skin) else { continue }
            built += 1
            if !cube.allFiniteInRange { finite = false }
            var last = -1.0
            for i in 0..<33 {
                let p = cube.at(i, i, i)
                if max(abs(p.0 - p.1), abs(p.1 - p.2)) > 1e-4 { greyStays = false }
                if p.1 < last - 1e-6 { greyRises = false }
                last = p.1
            }
        }
        guard let on = toneCube(c, s, b, skin: true), let off = toneCube(c, s, b, skin: false) else { continue }
        for i in 0..<33 where abs(on.at(i, i, i).1 - off.at(i, i, i).1) > 2e-3 { greyAgrees = false }
        for bi in 0..<33 { for gi in 0..<33 { for ri in 0..<33 {
            let x: RGB = (Double(ri) / 32, Double(gi) / 32, Double(bi) / 32)
            let a = on.at(ri, gi, bi), o = off.at(ri, gi, bi)
            engineGap = max(engineGap, abs(a.0 - o.0), abs(a.1 - o.1), abs(a.2 - o.2))
            let lx = oklab(x), ly = oklab(a)
            let cx = chroma(lx), cy = chroma(ly)
            // Hue is only meaningful where there is colour going in and coming out.
            if cx > 0.03 && cy > 0.03 { worstHue = max(worstHue, abs(hueDiff(hue(ly), hue(lx)))) }
            if cx > 0.03 { worstChromaGain = max(worstChromaGain, cy - cx * s) }
        }}}
    }
    check(built == toneSettings.count * 2, "a cube is built for every setting", "\(built) cubes")
    check(finite, "no value is missing or outside 0 to 1")
    check(greyStays, "greys stay grey: no colour cast creeps into neutral tones")
    check(greyRises, "the grey scale never reverses")
    check(greyAgrees, "on and off give the same tone to greys (they differ only in how colour is handled)")
    check(worstHue < 1.0, "True Colour on: contrast and brightness never shift a colour's hue",
          "worst shift \(f3(worstHue)) degrees, over every colour in the cube")
    check(worstChromaGain < 0.004, "True Colour on: contrast never adds colourfulness of its own",
          "largest gain \(f3(worstChromaGain)) Oklab chroma")
    check(engineGap > 0.02, "the switch really changes the picture", "largest difference \(f3(engineGap))")
}

// MARK: - 3. Deep skin through contrast (the bug True Colour fixed)

section("3. Deep skin under added contrast: the bug this engine was built to fix")
let monk: [(String, RGB)] = [
    ("Monk 6", hex("#a07e56")), ("Monk 7", hex("#825c43")), ("Monk 8", hex("#604134")),
    ("Monk 9", hex("#3a312a")), ("Monk 10", hex("#292420")),
]
do {
    var oldBlack = 0, newBlack = 0, tested = 0
    var worstKeep = 9.0, worstKeepAt = ""
    for c in [1.1, 1.2, 1.3] {
        guard let on = toneCube(c, 1, 0, skin: true), let off = toneCube(c, 1, 0, skin: false) else { continue }
        for (name, tone) in monk {
            for stops in [0.0, 1.0, 2.0] {
                let x = darker(tone, stops: stops)
                let before = cielab(x).0
                tested += 1
                // What the old engine did: contrast about 0.5 in LINEAR light, hard clip.
                let old: RGB = (enc((dec(x.0) - 0.5) * c + 0.5), enc((dec(x.1) - 0.5) * c + 0.5),
                                enc((dec(x.2) - 0.5) * c + 0.5))
                if cielab(old).0 < 2.5 { oldBlack += 1 }
                for cube in [on, off] {
                    let after = cielab(cube.sample(x)).0
                    if after < 2.5 { newBlack += 1 }
                    let keep = after / before
                    if keep < worstKeep {
                        worstKeep = keep
                        worstKeepAt = "\(name), \(Int(stops)) stops down, contrast \(c)"
                    }
                }
            }
        }
    }
    check(oldBlack >= 20, "the old maths is reproduced here and does crush these skin tones to black",
          "\(oldBlack) of \(tested) tone and light combinations went black")
    check(newBlack == 0, "with the engine, on or off, none of them goes black", "\(newBlack) of \(tested * 2)")
    check(worstKeep >= 0.5, "deep skin keeps at least half its lightness under the strongest look contrast",
          "worst keeps \(f1(worstKeep * 100))%: \(worstKeepAt)")
}

// MARK: - 4. The skin guard

/// This file's own smooth ramp from 0 at `a` to 1 at `b`.
func ramp(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// How far the guard spreads a correction, in steps of a 64-point cube.
let reach: Int = {
    let sigma = TrueColour.guardSmoothing * 63
    return sigma > 0 ? max(1, Int(3 * sigma + 0.5)) : 0
}()

/// Marks every point within `r` steps (along red, green and blue) of a marked point.
func grown(_ mask: [Bool], _ n: Int, by r: Int) -> [Bool] {
    guard r > 0 else { return mask }
    var m = mask
    for stride in [1, n, n * n] {
        let before = m
        for i in 0..<m.count where !before[i] {
            let k = (i / stride) % n
            for t in max(-r, -k)...min(r, n - 1 - k) where before[i + t * stride] { m[i] = true; break }
        }
    }
    return m
}

/// Which colours of a 64-point cube are which, by this file's own maths.
/// `core`: the heart of the skin range, with the guard at full strength there
/// and on every neighbour its spreading can reach. `clear`: not skin, and out
/// of reach of any skin colour, so the guard has no business touching it.
let (coreSkin, clearOfSkin): ([Bool], [Bool]) = {
    let n = 64
    var core = [Bool](repeating: false, count: n * n * n)
    var maybe = core
    var i = 0
    for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
        let x = cielab((Double(ri) / 63, Double(gi) / 63, Double(bi) / 63))
        let cx = chroma(x), hx = hue(x)
        core[i] = hx >= 20 && hx <= 85 && cx >= 8 && cx <= 60 && x.0 <= 85
        // Skin fades out past 5 and 100 degrees, or 8 units of colour away
        // from the 20-to-85 range, whichever reaches further.
        var off = abs(hx - 52.5)
        if off > 180 { off = 360 - off }
        let outside = max(0, off - 32.5)
        let away = outside >= 90 ? cx : cx * sin(outside * .pi / 180)
        let hueSaysSkin = (hx > 4 && hx < 101) || away < 8.5
        maybe[i] = hueSaysSkin && cx > 2.5 && cx < 76 && x.0 < 93
        i += 1
    }}}
    let notCore = grown(core.map { !$0 }, n, by: reach)
    let nearSkin = grown(maybe, n, by: reach)
    return (notCore.map { !$0 }, nearSkin.map { !$0 })
}()

/// How one LUT treats skin, before and after the guard, judged with this
/// file's own colour maths on every point of the cube.
struct GuardReport {
    var skin = 0                 // points in the heart of the skin range
    var rawBroken = 0            // of those, how many the LUT took outside the tolerance
    var guardedBroken = 0        // how many did not land where the guard promises
    var keptAsAuthored = 0       // inside tolerance already: must come back as they were
    var keptChanged = 0
    var keptDrift = 0.0          // the most any of those moved, in steps of 255
    var notSkin = 0              // clearly not skin: must come back bit for bit
    var notSkinChanged = 0
    var errorBefore = 0.0, errorAfter = 0.0  // summed distance from the fair colour
    var worstMiss = 0.0          // furthest any colour landed from its promised place
    var roughSteps = 0           // neighbouring colours pulled apart by the guard
    var worstStep = 0.0
    var worst = ""

    var cut: Double { errorBefore > 0 ? 1 - errorAfter / errorBefore : 1 }
}

func guardReport(_ lut: ParsedLUT, _ data: Data) -> GuardReport {
    let n = lut.size
    precondition(n == 64, "the guard checks are written for 64-point cubes")
    let raw = Cube(lut.rgbaFloatData, n), out = Cube(data, n)
    var rep = GuardReport()
    var p = 0
    for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
        defer { p += 1 }
        let y = raw.at(ri, gi, bi), z = out.at(ri, gi, bi)
        // Smoothness: one step along red, green and blue. A step counts as
        // rough when the guarded look jumps more than 12 of 255 and more than
        // three times what the look itself does there.
        for (dr, dg, db) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] where ri + dr < n && gi + dg < n && bi + db < n {
            let y2 = raw.at(ri + dr, gi + dg, bi + db), z2 = out.at(ri + dr, gi + dg, bi + db)
            let own = max(abs(y2.0 - y.0), abs(y2.1 - y.1), abs(y2.2 - y.2)) * 255
            let got = max(abs(z2.0 - z.0), abs(z2.1 - z.1), abs(z2.2 - z.2)) * 255
            if got > 12 && got > 3 * own + 4 {
                rep.roughSteps += 1
                rep.worstStep = max(rep.worstStep, got)
            }
        }
        if clearOfSkin[p] {
            rep.notSkin += 1
            let i = raw.index(ri, gi, bi)
            if raw.v[i] != out.v[i] || raw.v[i + 1] != out.v[i + 1] || raw.v[i + 2] != out.v[i + 2] {
                rep.notSkinChanged += 1
            }
            continue
        }
        guard coreSkin[p] else { continue }
        rep.skin += 1
        let x = cielab((Double(ri) / 63, Double(gi) / 63, Double(bi) / 63))
        let cx = chroma(x), hx = hue(x)
        let ly = cielab(y), lz = cielab(z)
        let turn = hueDiff(hue(ly), hx), ratio = chroma(ly) / cx
        let floor = 0.8 * x.0
        let shadow = 1 - ramp(35, 50, x.0)
        // The fair colour, from the guard's description: the skin tone's own
        // hue, plus as much of the look's turn as fits in 6 degrees (none of
        // it when the look lands opposite the skin tone, or on grey), at the
        // skin tone's chroma times the look's change held to 0.85x...1.2x.
        let keep = min(max(turn, -6), 6) * (1 - ramp(90, 180, abs(turn))) * ramp(0.1, 0.4, ratio)
        let fairHue = (hx + keep) * .pi / 180
        let fairChroma = cx * min(max(ratio, 0.85), 1.2)
        let fa = fairChroma * cos(fairHue), fb = fairChroma * sin(fairHue)
        let lift = ly.0 < floor ? (floor - ly.0) * shadow : 0
        let asked = ((ly.1 - fa) * (ly.1 - fa) + (ly.2 - fb) * (ly.2 - fb) + lift * lift).squareRoot()
        if abs(turn) <= 6 && ratio >= 0.85 && ratio <= 1.2 && lift == 0 {
            rep.keptAsAuthored += 1
            let drift = max(abs(y.0 - z.0), abs(y.1 - z.1), abs(y.2 - z.2)) * 255
            rep.keptDrift = max(rep.keptDrift, drift)
            if drift > keptAllowance { rep.keptChanged += 1 }
            continue
        }
        rep.rawBroken += 1
        // A colour pushed to the edge of what a screen can show is clipped
        // there, which bends hue and chroma; the promise is about the rest.
        if min(z.0, z.1, z.2) <= 0.001 || max(z.0, z.1, z.2) >= 0.999 { continue }
        // The promise: the look's output moved 80% of the way to the fair colour.
        let ta = ly.1 + 0.8 * (fa - ly.1), tb = ly.2 + 0.8 * (fb - ly.2), tL = ly.0 + 0.8 * lift
        let miss = ((lz.0 - tL) * (lz.0 - tL) + (lz.1 - ta) * (lz.1 - ta) + (lz.2 - tb) * (lz.2 - tb)).squareRoot()
        let left = ((lz.1 - fa) * (lz.1 - fa) + (lz.2 - fb) * (lz.2 - fb)
            + (lift > 0 ? (floor - lz.0) * (floor - lz.0) * shadow * shadow : 0)).squareRoot()
        rep.errorBefore += asked
        rep.errorAfter += left
        rep.worstMiss = max(rep.worstMiss, miss)
        if miss > missAllowance + missShare * asked {
            rep.guardedBroken += 1
            if rep.worst.isEmpty {
                rep.worst = "at \(ri),\(gi),\(bi): look is \(f1(asked)) from fair, landed \(f1(miss)) from the promised colour"
            }
        }
    }}}
    return rep
}

/// With no spreading the guard lands exactly on its promise and leaves
/// in-tolerance skin exactly alone. Spreading the correction over a few
/// neighbouring colours trades a little of that exactness for smoothness;
/// these are the limits it has to stay inside.

/// A rough step: two neighbouring colours that the guarded look puts more
/// than 12 of 255 apart and more than three times as far apart as the look
/// itself does. The first version of the guard left 186 to 3,105 of them on
/// the test looks below, up to 72 of 255 wide, which showed as green and red
/// speckle in dark skin. A guard that judges skin by colour alone cannot get
/// to none on every look (see TrueColour.guarded), so the limit is "few and
/// small": at most 200, none wider than 18.
let roughAllowance = 200
let roughLimit = 18.0
let missAllowance = reach > 0 ? 1.5 : 0.35      // CIELAB units
let missShare = reach > 0 ? 0.06 : 0.0          // plus this share of the look's own error
let keptAllowance = reach > 0 ? 2.5 : 0.77      // steps of 255

func luma(_ c: RGB) -> Double { 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2 }

let identityLUT = makeLUT(64) { $0 }
let hostile: [(String, ParsedLUT)] = [
    ("green cast with crushed shadows", makeLUT(64) { c in
        (clamp01(pow(c.0, 1.5) * 0.8), clamp01(pow(c.1, 1.2)), clamp01(pow(c.2, 1.2) * 1.05)) }),
    ("washed out and magenta", makeLUT(64) { c in
        let y = luma(c)
        return (clamp01((y + 0.4 * (c.0 - y)) * 1.08), clamp01((y + 0.4 * (c.1 - y)) * 0.92),
                clamp01((y + 0.4 * (c.2 - y)) * 1.1)) }),
    ("heavy teal and orange", makeLUT(64) { c in
        let y = luma(c)
        return (clamp01(y + 1.9 * (c.0 - y) + 0.04), clamp01(y + 1.5 * (c.1 - y)),
                clamp01(y + 1.9 * (c.2 - y) - 0.03)) }),
    ("deep shadow crush", makeLUT(64) { c in (pow(c.0, 2.2), pow(c.1, 2.2), pow(c.2, 2.2)) }),
    ("cold blue wash", makeLUT(64) { c in
        (clamp01(c.0 * 0.78), clamp01(c.1 * 0.95), clamp01(c.2 * 1.15 + 0.05)) }),
    // The kind of look that broke the first version of the guard: an instant
    // film that turns warm shadows teal, so deep skin comes out as its
    // opposite colour.
    ("cold instant film, warm shadows turned teal", makeLUT(64) { c in
        let s = 1 - luma(c)
        return (clamp01(c.0 * (1 - 0.6 * s)), clamp01(c.1 * (1 - 0.1 * s) + 0.05 * s),
                clamp01(c.2 * (1 - 0.1 * s) + 0.2 * s)) }),
]

section("4. The skin guard, on looks built to be hard on skin (64 x 64 x 64 colours each)")
do {
    let t0 = Date()
    let same = TrueColour.lutData(for: identityLUT)
    let ms = Date().timeIntervalSince(t0) * 1000
    let rep = guardReport(identityLUT, same)
    let a = Cube(identityLUT.rgbaFloatData, 64), b = Cube(same, 64)
    var gap: Float = 0
    for i in 0..<a.v.count { gap = max(gap, abs(a.v[i] - b.v[i])) }
    check(gap < 2e-3 && rep.rawBroken == 0, "a look that changes nothing comes back unchanged",
          "largest difference \(f3(Double(gap) * 255)) of 255; guard took \(Int(ms)) ms")

    for (name, lut) in hostile {
        let data = TrueColour.lutData(for: lut)
        let rep = guardReport(lut, data)
        let cube = Cube(data, 64)
        check(cube.allFiniteInRange, "\(name): every value is a real colour")
        check(rep.rawBroken > 2000, "\(name): the test look really does damage skin",
              "\(rep.rawBroken) of \(rep.skin) skin colours outside the tolerance")
        check(rep.guardedBroken == 0 && rep.cut > 0.7,
              "\(name): every skin colour lands where the guard promises",
              rep.guardedBroken == 0
                ? "distance from a fair skin colour cut by \(Int(rep.cut * 100 + 0.5))%; furthest miss \(f1(rep.worstMiss)) Lab"
                : "\(rep.guardedBroken) missed; first \(rep.worst)")
        check(rep.notSkinChanged == 0 && rep.notSkin > 50_000,
              "\(name): nothing that is not skin is touched, bit for bit", "\(rep.notSkin) colours")
        check(rep.roughSteps <= roughAllowance && rep.worstStep <= roughLimit,
              "\(name): neighbouring colours stay together, so skin does not break into patches",
              rep.roughSteps == 0 ? "no rough steps in 774,144 pairs of neighbours"
                : "\(rep.roughSteps) rough steps in 774,144 pairs of neighbours, largest \(f1(rep.worstStep)) of 255")
    }
}

// A look that sends skin to its opposite colour, made twice: once turning the
// hue 178 degrees one way, once 178 degrees the other. The two looks are
// almost the same look, so the guard must treat them almost the same. The
// first version of the guard turned hue back by the shortest way round, which
// flips at exactly 180 degrees: of two neighbouring colours one went green and
// the other red.
do {
    func turned(_ degrees: Double) -> (lut: ParsedLUT, shown: [Bool]) {
        var shown: [Bool] = []
        shown.reserveCapacity(64 * 64 * 64)
        let t = degrees * .pi / 180
        let lut = makeLUT(64) { c in
            let x = cielab(c)
            let opposite = screenColour((x.0, x.1 * cos(t) - x.2 * sin(t), x.1 * sin(t) + x.2 * cos(t)))
            shown.append(opposite != nil)
            return opposite ?? c
        }
        return (lut, shown)
    }
    let one = turned(178), other = turned(-178)
    let a = Cube(TrueColour.lutData(for: one.lut), 64), b = Cube(TrueColour.lutData(for: other.lut), 64)
    // Only where both looks could show the opposite colour, on the point and all round it.
    let unsure = grown(zip(one.shown, other.shown).map { !($0 && $1) }, 64, by: max(reach, 1))
    var compared = 0, apart = 0, widest = 0.0
    var p = 0
    for bi in 0..<64 { for gi in 0..<64 { for ri in 0..<64 {
        defer { p += 1 }
        guard coreSkin[p], !unsure[p] else { continue }
        let x = cielab((Double(ri) / 63, Double(gi) / 63, Double(bi) / 63))
        let za = cielab(a.at(ri, gi, bi)), zb = cielab(b.at(ri, gi, bi))
        let gap = ((za.0 - zb.0) * (za.0 - zb.0) + (za.1 - zb.1) * (za.1 - zb.1)
            + (za.2 - zb.2) * (za.2 - zb.2)).squareRoot()
        compared += 1
        widest = max(widest, gap / chroma(x))
        if gap > 0.5 + 0.03 * chroma(x) { apart += 1 }
    }}}
    check(compared > 300 && apart == 0,
          "skin sent to its opposite colour: which way round the look turned it makes no difference",
          "\(compared) skin colours compared; widest gap \(f1(widest * 100))% of the skin tone's colour")
}

section("5. Black-and-white looks, muted looks, and the looks the guard must leave alone")
do {
    // A gentle, well-behaved look: a touch of warmth and a little contrast.
    // The guard is there for looks that hurt skin; this one must pass through.
    let gentle = makeLUT(64) { c in
        func curve(_ x: Double) -> Double { clamp01(0.5 + 1.06 * (x - 0.5)) }
        return (curve(c.0 * 1.02), curve(c.1), curve(c.2 * 0.98)) }
    let gentleRep = guardReport(gentle, TrueColour.lutData(for: gentle))
    check(gentleRep.keptAsAuthored > 5_000 && gentleRep.keptChanged == 0,
          "a gentle look keeps its character: skin it already treats well is left alone",
          "\(gentleRep.keptAsAuthored) of \(gentleRep.skin) skin colours; the most any moved is \(f1(gentleRep.keptDrift)) of 255")
    check(gentleRep.guardedBroken == 0 && gentleRep.notSkinChanged == 0 && gentleRep.roughSteps == 0,
          "and the few it pushes too far are eased back, with nothing else touched",
          "\(gentleRep.rawBroken) eased back")

    // A hard black-and-white: everything grey, shadows crushed.
    let mono = makeLUT(64) { c in let y = pow(luma(c), 1.8); return (y, y, y) }
    let raw = Cube(mono.rgbaFloatData, 64), out = Cube(TrueColour.lutData(for: mono), 64)
    var tinted = 0, lifted = 0, shouldLift = 0, brightChanged = 0, darkerThanRaw = 0
    for bi in 0..<64 { for gi in 0..<64 { for ri in 0..<64 {
        let x = cielab((Double(ri) / 63, Double(gi) / 63, Double(bi) / 63))
        let y = cielab(raw.at(ri, gi, bi)), zc = out.at(ri, gi, bi), z = cielab(zc)
        if max(abs(zc.0 - zc.1), abs(zc.1 - zc.2)) > 2e-3 { tinted += 1 }
        if z.0 < y.0 - 0.3 { darkerThanRaw += 1 }
        if x.0 >= 51 {
            let i = raw.index(ri, gi, bi)
            if raw.v[i] != out.v[i] || raw.v[i + 1] != out.v[i + 1] || raw.v[i + 2] != out.v[i + 2] { brightChanged += 1 }
        }
        if x.0 > 4 && x.0 <= 30 && y.0 < 0.8 * x.0 - 1 {
            shouldLift += 1
            if z.0 >= y.0 + 0.8 * (0.8 * x.0 - y.0) - 0.7 { lifted += 1 }
        }
    }}}
    check(tinted == 0, "black-and-white stays black-and-white: the guard adds no colour")
    check(shouldLift > 5000 && lifted == shouldLift, "black-and-white: crushed shadows get their depth back",
          "\(lifted) of \(shouldLift) deep tones lifted")
    check(brightChanged == 0 && darkerThanRaw == 0, "black-and-white: mid tones and highlights are left alone")

    // A muted colour look must still be treated as colour, so skin keeps its warmth.
    let muted = makeLUT(64) { c in
        let y = luma(c)
        return (y + 0.5 * (c.0 - y), y + 0.5 * (c.1 - y), y + 0.5 * (c.2 - y)) }
    let rep = guardReport(muted, TrueColour.lutData(for: muted))
    check(rep.rawBroken > 2000 && rep.guardedBroken == 0,
          "a muted colour look is not mistaken for black-and-white: skin gets its colour back",
          "\(rep.rawBroken) skin colours restored")

    let worstLook = hostile[0].1
    let ours = makeLUT(64, baked: true) { c in
        (clamp01(pow(c.0, 1.5) * 0.8), clamp01(pow(c.1, 1.2)), clamp01(pow(c.2, 1.2) * 1.05)) }
    check(TrueColour.lutData(for: ours) == ours.rgbaFloatData,
          "a cube the app made itself is never guarded a second time")
    let wide = makeLUT(64, domainMax: 2) { c in
        (clamp01(pow(c.0, 1.5) * 0.8), clamp01(pow(c.1, 1.2)), clamp01(pow(c.2, 1.2) * 1.05)) }
    check(wide.hasCustomDomain && TrueColour.lutData(for: wide) == wide.rgbaFloatData,
          "a LUT with its own input range is left as authored (its points are not plain screen colours)")

    UserDefaults.standard.set(false, forKey: TrueColour.key)
    let off = TrueColour.lutData(for: worstLook)
    let offStamp = TrueColour.bakeStamp
    UserDefaults.standard.set(true, forKey: TrueColour.key)
    check(off == worstLook.rgbaFloatData, "True Colour off: every LUT exactly as its author made it")
    check(TrueColour.lutData(for: worstLook) != worstLook.rgbaFloatData,
          "True Colour back on: the guard is back straight away")
    check(offStamp != TrueColour.bakeStamp, "flipping the switch changes the stamp that re-bakes installed looks",
          "\(offStamp) / \(TrueColour.bakeStamp)")
}

// MARK: - 6. Fingerprints and caches

section("6. Telling looks apart, and remembering them")
do {
    // Plain per-channel curves that share the same black and the same white:
    // the kind of LUT the old fingerprint could not tell apart.
    var curves: [ParsedLUT] = []
    for i in 0..<24 {
        let gr = 0.7 + 0.025 * Double(i), gg = 1.3 - 0.02 * Double(i), gb = 0.8 + 0.015 * Double(i % 7)
        curves.append(makeLUT(64) { c in (pow(c.0, gr), pow(c.1, gg), pow(c.2, gb)) })
    }
    let keys = Set(curves.map { TrueColour.contentKey($0) })
    check(keys.count == curves.count, "24 similar curve looks get 24 different fingerprints",
          "\(keys.count) distinct")
    // The old fingerprint, kept here so this check proves it would have caught the bug.
    func oldKey(_ lut: ParsedLUT) -> Int {
        var hasher = Hasher()
        hasher.combine(lut.size)
        hasher.combine(lut.rgbaFloatData.count)
        lut.rgbaFloatData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            let step = max(1, floats.count / 4096)
            var i = 0
            while i < floats.count { hasher.combine(floats[i].bitPattern); i += step }
        }
        return hasher.finalize()
    }
    let oldKeys = Set(curves.map { oldKey($0) })
    check(oldKeys.count == 1, "the old fingerprint is reproduced here and could not tell them apart",
          "\(oldKeys.count) distinct of 24")
    // The same red in every one; only green or only blue differs. A
    // fingerprint that reads one channel cannot tell these apart.
    var cousins: [ParsedLUT] = []
    for i in 0..<12 {
        let k = 0.8 + 0.015 * Double(i)
        cousins.append(makeLUT(64) { c in (c.0, i % 2 == 0 ? c.1 * k : c.1, i % 2 == 0 ? c.2 : c.2 * k) })
    }
    let cousinKeys = Set(cousins.map { TrueColour.contentKey($0) })
    check(cousinKeys.count == cousins.count, "looks that differ only in green or only in blue are told apart too",
          "\(cousinKeys.count) distinct of \(cousins.count)")

    // Each look must get its own guarded colours, in any order, however full the memory is.
    let first = curves.map { TrueColour.lutData(for: $0) }
    var mixedUp = 0
    for round in 0..<3 {
        for i in stride(from: curves.count - 1, through: 0, by: -1 - round) where TrueColour.lutData(for: curves[i]) != first[i] {
            mixedUp += 1
        }
    }
    check(Set(first).count == curves.count && mixedUp == 0,
          "every look always gets its own guarded colours, never another look's")

    let base = toneCube(1.2, 1.1, 0.01, skin: true)
    for i in 0..<40 { _ = toneCube(1.0 + Double(i) * 0.011, 1.05, 0.0, skin: i % 2 == 0) }
    let again = toneCube(1.2, 1.1, 0.01, skin: true)
    check(base != nil && base?.v == again?.v, "a tone setting gives the same cube before and after the memory fills")

    // Many threads at once: export, thumbnails and the preview all grade together.
    let serialTone = toneSettings.map { toneCube($0.0, $0.1, $0.2, skin: true)?.v ?? [] }
    let lock = NSLock()
    var wrong = 0
    DispatchQueue.concurrentPerform(iterations: 64) { i in
        let lutIndex = i % curves.count
        let guarded = TrueColour.lutData(for: curves[lutIndex])
        let s = toneSettings[i % toneSettings.count]
        let tone = toneCube(s.0, s.1, s.2, skin: true)?.v ?? []
        if guarded != first[lutIndex] || tone != serialTone[i % toneSettings.count] {
            lock.lock(); wrong += 1; lock.unlock()
        }
    }
    check(wrong == 0, "64 grades at once on many threads all get the right answer")
}

// MARK: - 7. Cube files

section("7. Cube files: knowing which ones the app made itself")
do {
    func cubeText(_ comment: String, domainMax: String = "1.0 1.0 1.0") -> String {
        var lines = ["TITLE \"Test\"", comment, "LUT_3D_SIZE 2", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX " + domainMax, ""]
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lines.append("\(r).0 \(g).0 \(b).0") } } }
        return lines.joined(separator: "\n")
    }
    func baked(_ comment: String) -> Bool { (try? LUTParser.parseCube(text: cubeText(comment)))?.bakedByLumalook ?? false }

    check(baked(LUTParser.bakedHeader), "an installed pack look is recognised as the app's own")
    check(baked(LUTParser.exportedHeader), "a grade exported from the app is recognised when it is imported again")
    check(baked("# Generated by Lumalook") && baked("# exported from LUMALOOK 1.0"),
          "older spellings of the app's name still count")
    check(!baked("# Created by DaVinci Resolve") && !baked("# A look I like in Lumalook") && !baked("# plain"),
          "other apps' cubes are not mistaken for ours")

    let wide = try? LUTParser.parseCube(text: cubeText("# plain", domainMax: "2.0 2.0 2.0"))
    check(wide?.hasCustomDomain == true, "a LUT with its own input range is recognised")

    if let small = try? LUTParser.parseCube(text: cubeText(LUTParser.bakedHeader)) {
        let dense = small.densifiedTetrahedral(to: 64)
        let cube = Cube(dense.rgbaFloatData, 64)
        var gap = 0.0
        for bi in 0..<64 { for gi in 0..<64 { for ri in 0..<64 {
            let p = cube.at(ri, gi, bi)
            gap = max(gap, abs(p.0 - Double(ri) / 63), abs(p.1 - Double(gi) / 63), abs(p.2 - Double(bi) / 63))
        }}}
        check(dense.size == 64 && dense.bakedByLumalook && gap < 1e-5,
              "smoothing a small cube up to 64 keeps its colours and its made-by-the-app mark")
        check(TrueColour.lutData(for: dense) == dense.rgbaFloatData, "and the guard still leaves it alone")
    } else {
        check(false, "the test cube parses")
    }
}

// MARK: - 8. Smoothing a small cube up to 64 points

section("8. Small cubes smoothed up to 64 points a side (every film look in the app is 13)")
do {
    // Tetrahedral interpolation written the general way, not as six cases:
    // start at the cell's low corner and step along the axes one at a time,
    // largest fraction first.
    func tetra(_ small: Cube, _ c: RGB) -> RGB {
        let n = small.n
        var cell = [0, 0, 0], frac = [0.0, 0.0, 0.0]
        for (k, v) in [c.0, c.1, c.2].enumerated() {
            let p = clamp01(v) * Double(n - 1)
            cell[k] = min(Int(p), n - 2)
            frac[k] = p - Double(cell[k])
        }
        let order = [0, 1, 2].sorted { frac[$0] > frac[$1] }
        let f = order.map { frac[$0] }
        let weights = [1 - f[0], f[0] - f[1], f[1] - f[2], f[2]]
        var corner = cell
        var out = (0.0, 0.0, 0.0)
        for step in 0..<4 {
            if step > 0 { corner[order[step - 1]] += 1 }
            let v = small.at(corner[0], corner[1], corner[2])
            out = (out.0 + weights[step] * v.0, out.1 + weights[step] * v.1, out.2 + weights[step] * v.2)
        }
        return out
    }

    // A look whose channels lean on each other, as film does. A plain
    // per-channel curve cannot show the fault this section is here for.
    func filmLike(_ c: RGB) -> RGB {
        let y = luma(c)
        return (clamp01(pow(c.0, 0.8) * (1 - 0.35 * c.2) + 0.25 * c.1 * c.2),
                clamp01(pow(c.1, 1.2) * (0.7 + 0.3 * c.0) + 0.1 * (1 - c.2) * c.0),
                clamp01(c.2 * (0.55 + 0.45 * y) + 0.3 * c.0 * (1 - c.1)))
    }

    for size in [13, 17, 33] {
        let small = makeLUT(size, filmLike)
        let dense = small.densifiedTetrahedral(to: 64)
        let from = Cube(small.rgbaFloatData, size), cube = Cube(dense.rgbaFloatData, 64)
        var gap = 0.0, outside = 0, worstCase = ""
        var perCase = [String: Double]()
        for bi in 0..<64 { for gi in 0..<64 { for ri in 0..<64 {
            let c = (Double(ri) / 63, Double(gi) / 63, Double(bi) / 63)
            let got = cube.at(ri, gi, bi), want = tetra(from, c)
            let d = max(abs(got.0 - want.0), abs(got.1 - want.1), abs(got.2 - want.2))
            // which of the six cases this colour falls in, by its fractions
            func frac(_ v: Double) -> Double { let p = v * Double(size - 1); return p - Double(min(Int(p), size - 2)) }
            let fr = frac(c.0), fg = frac(c.1), fb = frac(c.2)
            let name = [("r", fr), ("g", fg), ("b", fb)].sorted { $0.1 > $1.1 }.map { $0.0 }.joined(separator: ">")
            perCase[name] = max(perCase[name] ?? 0, d)
            if d > gap { gap = d; worstCase = name }
            // Interpolation can never leave the range of its cell's corners.
            let r0 = min(Int(c.0 * Double(size - 1)), size - 2), g0 = min(Int(c.1 * Double(size - 1)), size - 2)
            let b0 = min(Int(c.2 * Double(size - 1)), size - 2)
            var lo = (1.0, 1.0, 1.0), hi = (0.0, 0.0, 0.0)
            for k in 0..<8 {
                let v = from.at(r0 + (k & 1), g0 + ((k >> 1) & 1), b0 + ((k >> 2) & 1))
                lo = (min(lo.0, v.0), min(lo.1, v.1), min(lo.2, v.2))
                hi = (max(hi.0, v.0), max(hi.1, v.1), max(hi.2, v.2))
            }
            // (a colour on a cell wall may be worked out from the cell next door: allow a hair)
            if got.0 < lo.0 - 2e-3 || got.0 > hi.0 + 2e-3 || got.1 < lo.1 - 2e-3 || got.1 > hi.1 + 2e-3
                || got.2 < lo.2 - 2e-3 || got.2 > hi.2 + 2e-3 { outside += 1 }
        }}}
        check(perCase.count == 6 && gap < 2e-5,
              "\(size) points up to 64: every colour is where tetrahedral interpolation puts it, in all six cases",
              gap < 2e-5 ? "largest gap \(f3(gap * 255)) of 255"
                         : "largest gap \(f1(gap * 255)) of 255, in the case \(worstCase)")
        check(outside == 0 && cube.allFiniteInRange,
              "\(size) points up to 64: no colour is pushed past the corners of its own cell",
              outside == 0 ? "" : "\(outside) colours outside")
    }
    let big = makeLUT(64, filmLike)
    check(big.densifiedTetrahedral(to: 64).rgbaFloatData == big.rgbaFloatData,
          "a cube that is already 64 points is passed through untouched")
}

// MARK: - 9. Baking installed looks again

section("9. Installed pack looks baked again when the switch moves: the books stay honest")
do {
    // Pack looks are saved as cube files and overwritten one by one, in the
    // background, when the True Colour switch moves. The saved stamp has to
    // mean "every cube on disk was baked this way", whatever the person does
    // with the switch, or with the app, while a batch runs.
    let d = UserDefaults.standard
    func saved() -> String { d.string(forKey: TrueColour.bakedKey) ?? "none" }
    func flip(_ on: Bool) { d.set(on, forKey: TrueColour.key) }

    flip(true)
    d.removeObject(forKey: TrueColour.bakedKey)
    let first = TrueColour.Rebake.isNeeded
    var mode = TrueColour.Rebake.begin()
    var again = TrueColour.Rebake.finish(bakedOn: mode, complete: true)
    check(first && mode && !again && saved() == TrueColour.stamp(on: true) && !TrueColour.Rebake.isNeeded,
          "a first launch bakes once, with the switch as it stands, and is then settled", "stamp \(saved())")

    // The switch goes off. The batch starts and overwrites the first cubes...
    flip(false)
    let wanted = TrueColour.Rebake.isNeeded
    mode = TrueColour.Rebake.begin()
    check(wanted && !mode && saved() == "none",
          "the stamp is cleared before the first cube is overwritten (closing the app half way bakes again next launch)",
          "stamp \(saved())")

    // ...and the person switches it straight back on while the batch runs.
    flip(true)
    check(TrueColour.Rebake.isNeeded,
          "off, then back on before the batch ends: the looks are still known to need baking",
          "stamp \(saved()), switch on")
    again = TrueColour.Rebake.finish(bakedOn: mode, complete: true)
    check(again && saved() == "none",
          "a batch baked for a switch position that has since changed is not signed off, and another is due",
          "stamp \(saved())")
    mode = TrueColour.Rebake.begin()
    again = TrueColour.Rebake.finish(bakedOn: mode, complete: true)
    check(mode && !again && saved() == TrueColour.stamp(on: true) && !TrueColour.Rebake.isNeeded,
          "the follow-up batch bakes for the switch as it now stands and settles it", "stamp \(saved())")

    flip(false)
    mode = TrueColour.Rebake.begin()
    again = TrueColour.Rebake.finish(bakedOn: mode, complete: false)
    check(!again && saved() == "none" && TrueColour.Rebake.isNeeded,
          "a batch that could not write every cube is not signed off (the next launch tries again)",
          "stamp \(saved())")

    // One batch, one mode: a look told to bake with True Colour off does so
    // even though the switch has gone back on.
    flip(true)
    let live = toneCube(1.2, 1.1, 0.02, skin: TrueColour.isOn)
    let held = toneCube(1.2, 1.1, 0.02, skin: false)
    flip(false)
    let classic = TrueColour.toneFilter(contrast: 1.2, saturation: 1.1, brightness: 0.02)
        .flatMap { $0.value(forKey: "inputCubeData") as? Data }.map { Cube($0, 33) }
    flip(true)
    var same = false, differs = false
    if let live, let held, let classic {
        same = held.v == classic.v
        differs = zip(held.v, live.v).contains { abs($0 - $1) > 0.01 }
    }
    check(same && differs,
          "a batch holds one switch position for every cube, whatever the switch does meanwhile")

    d.removeObject(forKey: TrueColour.bakedKey)
}

// MARK: - 10. Real Core Image

#if os(macOS)
section("10. On real Core Image: the picture matches the cube, and the old filter still shows the bug")
do {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CIContext(options: [.useSoftwareRenderer: false])   // as LookPipeline.shared.context
    var colours: [RGB] = []
    for (_, tone) in monk { for stops in [0.0, 1.0, 2.0] { colours.append(darker(tone, stops: stops)) } }
    colours += [(0.5, 0.5, 0.5), (0.9, 0.2, 0.2), (0.1, 0.4, 0.8), (0.2, 0.7, 0.3), (1, 1, 1), (0, 0, 0)]
    let width = colours.count
    var px = [Float](repeating: 1, count: width * 4)
    for (i, c) in colours.enumerated() {
        px[i * 4] = Float(c.0)
        px[i * 4 + 1] = Float(c.1)
        px[i * 4 + 2] = Float(c.2)
    }
    let strip = CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) },
                        bytesPerRow: width * 16, size: CGSize(width: width, height: 1),
                        format: .RGBAf, colorSpace: srgb)

    func render(_ image: CIImage) -> [RGB] {
        var buf = [Float](repeating: 0, count: width * 4)
        buf.withUnsafeMutableBytes { raw in
            ctx.render(image.cropped(to: strip.extent), toBitmap: raw.baseAddress!, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: 1), format: .RGBAf, colorSpace: srgb)
        }
        return (0..<width).map { (Double(buf[$0 * 4]), Double(buf[$0 * 4 + 1]), Double(buf[$0 * 4 + 2])) }
    }

    var worst = 0.0
    for (c, s, b) in [(1.2, 1.0, 0.0), (1.3, 1.15, 0.02), (0.8, 0.9, -0.03)] {
        for skin in [true, false] {
            guard let filter = TrueColour.toneFilter(contrast: Float(c), saturation: Float(s),
                                                     brightness: Float(b), protectSkin: skin),
                  let cube = toneCube(c, s, b, skin: skin) else { continue }
            filter.setValue(strip, forKey: kCIInputImageKey)
            guard let image = filter.outputImage else { continue }
            let shown = render(image)
            for (i, colour) in colours.enumerated() {
                let want = cube.sample(colour)
                worst = max(worst, abs(shown[i].0 - want.0), abs(shown[i].1 - want.1), abs(shown[i].2 - want.2))
            }
        }
    }
    check(worst * 255 < 1.5, "what Core Image shows is what the cube says, to within 1.5 of 255",
          "largest gap \(f3(worst * 255)) of 255")

    let controls = CIFilter.colorControls()
    controls.inputImage = strip
    controls.contrast = 1.2
    controls.saturation = 1
    controls.brightness = 0
    let old = render(controls.outputImage ?? strip)
    var oldBlack = 0
    for i in 0..<(monk.count * 3) where cielab(old[i]).0 < 2.5 { oldBlack += 1 }
    print("  note  Apple's CIColorControls at contrast 1.2 turns \(oldBlack) of \(monk.count * 3) "
          + "of these skin tones black. That is the filter the app no longer uses.")
}
#endif

// MARK: - 11. Auto balance

section("11. Auto reads a colour cast from neutrals only, and never takes warmth out")
do {
    // Made-up pictures, the same on every run.
    var seed: UInt64 = 88172645463325252
    func rnd() -> Double {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Double(seed >> 11) / Double(UInt64(1) << 53)
    }
    let side = 48
    typealias Maker = () -> RGB

    /// A picture made of parts: each part is a share of the picture and what
    /// colours it is made of.
    func picture(_ parts: [(Double, Maker)]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            var pick = rnd(), make = parts[parts.count - 1].1
            for (share, m) in parts {
                if pick < share { make = m; break }
                pick -= share
            }
            let c = make()
            out[i * 4] = UInt8((clamp01(c.0) * 255).rounded())
            out[i * 4 + 1] = UInt8((clamp01(c.1) * 255).rounded())
            out[i * 4 + 2] = UInt8((clamp01(c.2) * 255).rounded())
        }
        return out
    }

    /// A colour with a light of another colour on it: `cast` is what that
    /// light does to a grey, as CIELAB a and b.
    func lit(_ c: RGB, _ cast: (Double, Double)) -> RGB {
        let x = cielab(c)
        return screenColour((x.0, x.1 + cast.0, x.2 + cast.1)) ?? c
    }
    let tones: [RGB] = monk.map { $0.1 } + [hex("#f3e7db"), hex("#eadaba"), hex("#d7bd96")]
    /// Skin of every depth, in light and in shade.
    func skin(_ cast: (Double, Double) = (0, 0)) -> Maker {
        { lit(darker(tones[Int(rnd() * Double(tones.count)) % tones.count], stops: rnd() * 1.5), cast) }
    }
    /// A grey wall, lit unevenly, with a little noise in its colour.
    func wall(_ cast: (Double, Double) = (0, 0), noise: Double = 0.8) -> Maker {
        { screenColour((35 + rnd() * 50, cast.0 + (rnd() - 0.5) * 2 * noise, cast.1 + (rnd() - 0.5) * 2 * noise))
            ?? (0.5, 0.5, 0.5) }
    }
    /// Leaves, sky, neon: strong colours of every hue.
    let colourful: Maker = {
        let h = rnd() * 2 * Double.pi, c = 30 + rnd() * 20
        return screenColour((45 + rnd() * 25, c * cos(h), c * sin(h))) ?? (0.2, 0.6, 0.3)
    }

    func read(_ rgba: [UInt8]) -> TrueColour.Balance { TrueColour.readBalance(rgba: rgba, width: side, height: side) }
    func says(_ b: TrueColour.Balance) -> String {
        switch b {
        case .unreadable: return "nothing to go by"
        case .balanced: return "balanced"
        case .cast(let r, let g, let bl):
            let x = cielab((r, g, bl))
            return "cast a \(f1(x.1)), b \(f1(x.2))"
        }
    }
    /// The cast Auto read, as CIELAB a and b, or nil when it read none.
    func castOf(_ b: TrueColour.Balance) -> (Double, Double)? {
        if case .cast(let r, let g, let bl) = b { let x = cielab((r, g, bl)); return (x.1, x.2) }
        return nil
    }

    // A portrait against a grey wall, as shot.
    let plain = read(picture([(0.55, skin()), (0.45, wall())]))
    check(plain == .balanced, "a portrait against a grey wall is balanced: the skin does not read as a cast", says(plain))
    let close = read(picture([(0.85, skin()), (0.15, wall())]))
    check(close == .balanced, "so is a close portrait that is 85% skin", says(close))

    // The same portrait under a light that is not warm: the cast is found, in
    // the right direction, and no more of it is taken off than is there.
    for (name, cast) in [("blue", (-1.0, -8.0)), ("green", (-7.0, 0.0)), ("magenta", (7.0, -3.0)),
                         ("blue-green", (-6.0, -5.0))] {
        let got = read(picture([(0.55, skin(cast)), (0.45, wall(cast))]))
        let size = (cast.0 * cast.0 + cast.1 * cast.1).squareRoot()
        var ok = false, detail = says(got)
        if let c = castOf(got) {
            let read = (c.0 * c.0 + c.1 * c.1).squareRoot()
            let along = (c.0 * cast.0 + c.1 * cast.1) / (read * size)
            let want = min(size - 1.5, TrueColour.balanceMost)
            ok = along > 0.97 && abs(read - want) < 0.6 && read <= size
            detail += ", \(f1(read)) of the \(f1(size)) put on"
        }
        check(ok, "a \(name) light on that portrait is read as a \(name) cast, and only part of it is taken off", detail)
    }

    // A cast too slight to matter.
    let slight = read(picture([(0.55, skin((-0.6, -0.9))), (0.45, wall((-0.6, -0.9)))]))
    check(slight == .balanced, "a cast of about 1 unit is no cast", says(slight))

    // The most it ever takes.
    var most = 0.0
    for cast in [(-3.0, -12.0), (-12.0, -2.0), (9.0, -9.0)] {
        if let c = castOf(read(picture([(0.4, skin(cast)), (0.6, wall(cast))]))) {
            most = max(most, (c.0 * c.0 + c.1 * c.1).squareRoot())
        }
    }
    check(most > 4 && most <= TrueColour.balanceMost + 0.1, "a heavy cast is only ever nudged",
          "most taken off \(f1(most)) units, limit \(f1(TrueColour.balanceMost))")

    // Warmth stays. A warm light, a cream wall and skin look alike by colour.
    var cooled = 0, warmTried = 0
    for cast in [(1.0, 2.0), (2.0, 5.0), (3.0, 9.0), (4.0, 12.0), (0.5, 2.6), (2.5, 1.0)] {
        warmTried += 1
        if castOf(read(picture([(0.55, skin(cast)), (0.45, wall(cast))]))) != nil { cooled += 1 }
    }
    check(cooled == 0, "a warm light is never taken off, slight or strong", "\(cooled) of \(warmTried) warm lights touched")
    var yellowTaken = 0.0, greenTaken = 0.0
    for cast in [(-6.0, 6.0), (-4.0, 9.0), (-8.0, 3.0)] {
        if let c = castOf(read(picture([(0.5, skin(cast)), (0.5, wall(cast))]))) {
            yellowTaken = max(yellowTaken, c.1)
            greenTaken = max(greenTaken, -c.0)
        }
    }
    check(yellowTaken < 0.3 && greenTaken > 1, "under a yellow-green light only the green is taken off: the yellow stays",
          "green taken \(f1(greenTaken)), yellow taken \(f1(yellowTaken))")

    // Pictures that give nothing to go by are left alone.
    let onlySkin = read(picture([(1.0, skin())]))
    check(onlySkin == .unreadable, "a picture that is all skin gives nothing to go by", says(onlySkin))
    let busy = read(picture([(0.5, skin()), (0.46, colourful), (0.04, wall())]))
    check(busy == .unreadable, "nor does skin among strong colours with almost no grey", says(busy))
    let mixed = read(picture([(0.4, skin()), (0.3, wall((-2.0, -9.0))), (0.3, wall((-8.0, 6.0)))]))
    check(mixed == .unreadable, "nor do two lights of different colours on the same wall", says(mixed))
    let blown = read(picture([(0.5, skin()), (0.5, { (1.0, 1.0, 0.99) })]))
    check(blown == .unreadable, "nor does a blown-out white background", says(blown))
    let dark = read(picture([(0.5, skin()), (0.5, { screenColour((8 + rnd() * 10, -2, -6)) ?? (0.05, 0.05, 0.07) })]))
    check(dark == .unreadable, "nor does a near-black background", says(dark))
    check(TrueColour.readBalance(rgba: [], width: 0, height: 0) == .unreadable
          && TrueColour.readBalance(rgba: [1, 2, 3], width: 4, height: 4) == .unreadable,
          "a picture that is empty or cut short is left alone")
}

// MARK: - Result

print("\n\(checks) checks, \(failed.count) failed, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
if !failed.isEmpty {
    print("FAILED:")
    for name in failed { print("  " + name) }
    exit(1)
}
print("True Colour engine: all checks passed.")

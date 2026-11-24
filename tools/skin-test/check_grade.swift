// Checks the grade on top of a look: the Skin first presets and the Grade
// Room colour tools (curves, wheels, HSL bands, split tone), using the app's
// own files, compiled in, not a copy.
//
// It exists because of a fault found on 24 Nov 2026. A Skin first preset
// stayed switched on under every look picked after it, and the Grade Room
// colour tools worked on the wrong numbers, so every look came out teal and
// milky on the big picture while its thumbnail was right. It asks three
// things:
//
//   1. Does a preset come off, whole, when another look is picked?
//   2. Do the colour tools do on screen what their numbers say?
//   3. Is every look, picked after a preset, the look its thumbnail shows?
//
// Later sections ask the same of the film tools and tone sliders (5), of the
// exported cube and the three picture sizes (6), and of the White balance
// picker (7).
//
//   mkdir -p /tmp/grade && cp tools/skin-test/check_grade.swift /tmp/grade/main.swift
//   swiftc -O -o /tmp/grade/check /tmp/grade/main.swift \
//       LumaLook/Models/LumaModels.swift LumaLook/Engine/SkinFirstPresets.swift \
//       LumaLook/Engine/ColorMath.swift LumaLook/Engine/LookPipeline.swift \
//       LumaLook/Engine/LogNormalizer.swift LumaLook/Engine/OverlayEffects.swift \
//       LumaLook/Engine/TrueColour.swift LumaLook/Engine/LUTParser.swift \
//       LumaLook/Engine/LUTDensifier.swift
//   /tmp/grade/check check  tools/skin-test/looks.json LumaLook/Resources/FilmLUTs \
//       tools/skin-test/out/candidates /tmp/grade/pictures
//
// "check" runs the checks, writes a few pictures (two test portraits through
// the presets and two film looks) to the last folder, and exits 1 if any
// check failed. "render" writes only the pictures, for looking at a change
// before and after. The Mac runner keeps the pictures with its run, as
// "grade-pictures".
//
// Run it whenever SkinFirstPresets.swift, ColorMath.swift, LookPipeline.swift
// or the settings in LumaModels.swift change. Part 1 needs no Mac.
import Foundation
import CoreImage
#if os(macOS)
import CoreImage.CIFilterBuiltins
import ImageIO
#endif

/// LumaModels.swift names this type for the Home screen's sample clips. The
/// real one lives with the artwork (Design/SceneArt.swift) and is not needed
/// to grade a picture.
enum MockScene: CaseIterable, Hashable { case none }

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

func f1(_ x: Double) -> String { String(format: "%.1f", x) }

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "check"
let started = Date()

// MARK: - 1. A preset comes off when another look is picked

/// The colour half of a grade: everything a preset sets, and nothing the
/// person sets with the film tools on the look screen.
func colourIsNeutral(_ s: LookSettings) -> Bool {
    let fresh = LookSettings()
    return s.exposure == fresh.exposure && s.contrast == fresh.contrast
        && s.highlights == fresh.highlights && s.shadows == fresh.shadows
        && s.saturation == fresh.saturation && s.warmth == fresh.warmth
        && s.tint == fresh.tint && s.fade == fresh.fade
        && s.curves == nil && s.wheels == nil && s.hsl == nil && s.splitTone == nil
}

/// What Auto leaves behind on a warm portrait: a cooler white balance, a
/// little exposure, and contrast never under 14 (AppModel.autoGrade).
func withAutoOnTop(_ settings: LookSettings) -> LookSettings {
    var s = settings
    s.exposure = 5
    s.warmth = -45
    s.tint = 16
    s.contrast = max(s.contrast, 14)
    return s
}

if mode == "check" {
    section("1. A Skin first preset comes off when another look is picked")
    let fresh = LookSettings()
    check(SkinFirstPreset.worn(by: fresh) == nil, "a new grade wears no preset")
    check(SkinFirstPreset.takenOff(fresh) == fresh, "taking nothing off changes nothing")

    for preset in SkinFirstPreset.allCases {
        let on = preset.settings
        check(SkinFirstPreset.worn(by: on) == preset, "\(preset.name): seen as worn straight after it is picked")
        check(SkinFirstPreset.takenOff(on) == fresh,
              "\(preset.name): taken off, the grade is a new grade at the strength a look opens at",
              "strength \(Int(SkinFirstPreset.takenOff(on).intensity))")

        // The person turned Strength down and added grain and a lens.
        var tuned = on
        tuned.intensity = 60
        tuned.grain = 20
        tuned.vignette = 12
        tuned.lensKind = LensKind.vintage.rawValue
        let tunedOff = SkinFirstPreset.takenOff(tuned)
        check(SkinFirstPreset.worn(by: tuned) == preset, "\(preset.name): still seen with Strength, grain and a lens changed")
        check(colourIsNeutral(tunedOff) && tunedOff.intensity == 60 && tunedOff.grain == 20
                && tunedOff.vignette == 12 && tunedOff.lensKind == LensKind.vintage.rawValue,
              "\(preset.name): taken off, their Strength, grain, vignette and lens stay")

        // Auto or the white-balance picker was used on top (the state the
        // fault was found in: a preset with a cooler white balance over it).
        let auto = withAutoOnTop(on)
        check(SkinFirstPreset.worn(by: auto) == preset, "\(preset.name): still seen with Auto on top of it")
        check(colourIsNeutral(SkinFirstPreset.takenOff(auto)),
              "\(preset.name): taken off, what Auto added on top goes with it")

        // A saved project keeps its settings as JSON.
        if let data = try? JSONEncoder().encode(on),
           let back = try? JSONDecoder().decode(LookSettings.self, from: data) {
            check(SkinFirstPreset.worn(by: back) == preset, "\(preset.name): still seen after a project is saved and opened")
        } else {
            check(false, "\(preset.name): settings survive being saved")
        }

        // Reshaped by hand in the Grade Room: now the person's own grade.
        var own = on
        own.curves?.master[0].y += 0.05
        check(SkinFirstPreset.worn(by: own) == nil && SkinFirstPreset.takenOff(own) == own,
              "\(preset.name): once its curve is reshaped by hand it is the person's grade, and is left alone")
    }

    var handMade = LookSettings()
    handMade.warmth = 20
    handMade.exposure = -10
    handMade.splitTone = SplitTone(shadowHue: 200, shadowSat: 0.3, highlightHue: 40, highlightSat: 0.2, balance: 0)
    check(SkinFirstPreset.worn(by: handMade) == nil && SkinFirstPreset.takenOff(handMade) == handMade,
          "a grade made by hand is never taken for a preset")

    let names = Set(SkinFirstPreset.allCases.map { preset -> String in
        let s = preset.settings
        return "\(String(describing: s.curves))|\(String(describing: s.hsl))|\(String(describing: s.splitTone))"
    })
    check(names.count == SkinFirstPreset.allCases.count, "no two presets share a curve, bands and split tone")

    // A look saved under Mine replaces the whole grade in the same way, and
    // stayed on under the next look in the same way.
    section("1b. A look saved under Mine comes off when another look is picked")

    // The hand-made grade above, saved as a look and picked again.
    let saved = handMade
    check(handMade.wears(saved), "a saved look with a split tone: seen as worn straight after it is picked")
    check(colourIsNeutral(handMade.takingOff(saved)), "taken off, the grade is a new grade")
    var savedTuned = withAutoOnTop(saved)
    savedTuned.grain = 30
    savedTuned.lensKind = LensKind.vintage.rawValue
    check(savedTuned.wears(saved), "still seen with a white balance, grain and a lens changed on top")
    let savedOff = savedTuned.takingOff(saved)
    check(colourIsNeutral(savedOff) && savedOff.grain == 30 && savedOff.lensKind == LensKind.vintage.rawValue,
          "taken off, the white balance goes with it and the grain and lens stay")
    var redrawn = saved
    redrawn.splitTone?.shadowSat = 0.5
    check(!redrawn.wears(saved) && redrawn.takingOff(saved) == redrawn,
          "once its split tone is redrawn by hand it is the person's grade, and is left alone")

    // A saved look made of sliders alone.
    var slidersOnly = LookSettings()
    slidersOnly.warmth = 18
    slidersOnly.contrast = 30
    slidersOnly.grain = 25
    check(slidersOnly.wears(slidersOnly), "a saved look made of sliders alone: seen as worn while they are untouched")
    let slidersOff = slidersOnly.takingOff(slidersOnly)
    check(colourIsNeutral(slidersOff) && slidersOff.grain == 25, "taken off, the sliders are back to neutral and its grain stays")
    var nudged = slidersOnly
    nudged.exposure = 12
    check(!nudged.wears(slidersOnly) && nudged.takingOff(slidersOnly) == nudged,
          "with a slider moved by hand since, it is the person's grade, and is left alone")
    check(!handMade.wears(slidersOnly), "a grade with a shape of its own never wears a sliders-only look")

    // A saved look that sets no colour at all (a film look with grain) has
    // nothing to take off, and a new grade wears nothing.
    var grainOnly = LookSettings()
    grainOnly.grain = 40
    check(!grainOnly.wears(grainOnly) && !fresh.wears(grainOnly) && !fresh.wears(fresh),
          "a saved look with no colour of its own is never worn, and a new grade wears nothing")

    // What lights the More tile.
    var withGrain = fresh
    withGrain.grain = 40
    withGrain.intensity = 50
    var withExposure = fresh
    withExposure.exposure = 5
    check(!fresh.isAdjusted(from: fresh) && !withGrain.isAdjusted(from: fresh),
          "More is not lit for a new grade, or for Strength and grain alone")
    check(withExposure.isAdjusted(from: fresh) && handMade.isAdjusted(from: fresh),
          "More is lit when a slider or a split tone is on")
    let cinema = SkinFirstPreset.richCinema.settings
    check(!cinema.isAdjusted(from: cinema) && withAutoOnTop(cinema).isAdjusted(from: cinema),
          "More is not lit for a preset as picked, and is lit once something is changed on top of it")
}

#if os(macOS)

// MARK: - Core Image helpers

guard args.count >= 6 else {
    print("usage: check <check|render> looks.json FilmLUTs portraits out")
    exit(2)
}
let looksURL = URL(fileURLWithPath: args[2])
let filmDir = URL(fileURLWithPath: args[3])
let portraitDir = URL(fileURLWithPath: args[4])
let outDir = URL(fileURLWithPath: args[5])

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let pipeline = LookPipeline.shared

typealias RGB = (Double, Double, Double)

/// A one-row picture of exact colours, as the numbers a screen shows.
func strip(_ colours: [RGB]) -> CIImage {
    var px = [Float](repeating: 1, count: colours.count * 4)
    for (i, c) in colours.enumerated() {
        px[i * 4] = Float(c.0)
        px[i * 4 + 1] = Float(c.1)
        px[i * 4 + 2] = Float(c.2)
    }
    return CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) },
                   bytesPerRow: colours.count * 16, size: CGSize(width: colours.count, height: 1),
                   format: .RGBAf, colorSpace: srgb)
}

/// The same colours after the whole pipeline, again as a screen shows them.
func graded(_ colours: [RGB], _ state: LookState) -> [RGB] {
    let source = strip(colours)
    let image = pipeline.apply(state: state, to: source, includeSplit: false).cropped(to: source.extent)
    let width = colours.count
    var buf = [Float](repeating: 0, count: width * 4)
    buf.withUnsafeMutableBytes { raw in
        pipeline.context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                                bounds: CGRect(x: 0, y: 0, width: width, height: 1),
                                format: .RGBAf, colorSpace: srgb)
    }
    return (0..<width).map { (Double(buf[$0 * 4]), Double(buf[$0 * 4 + 1]), Double(buf[$0 * 4 + 2])) }
}

func state(recipe: LookRecipe = LookRecipe(), lut: ParsedLUT? = nil, _ settings: LookSettings) -> LookState {
    let s = LookState()
    s.recipe = recipe
    s.lut = lut
    s.settings = settings
    return s
}

/// Settings with nothing on, at full strength: what a thumbnail is made with.
func full(_ change: (inout LookSettings) -> Void = { _ in }) -> LookSettings {
    var s = LookSettings()
    s.intensity = 100
    change(&s)
    return s
}

func gap(_ a: RGB, _ b: RGB) -> Double {
    max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) * 255
}

func show(_ c: RGB) -> String {
    "(\(Int((c.0 * 255).rounded())), \(Int((c.1 * 255).rounded())), \(Int((c.2 * 255).rounded())))"
}

// MARK: - The looks the app ships

struct ShippedLook: Decodable {
    struct Recipe: Decodable {
        var temperature: Float
        var tint: Float
        var contrast: Float
        var saturation: Float
        var brightness: Float
        var vignette: Float
        var bloom: Float
    }
    var id: String
    var code: String
    var name: String
    var recipe: Recipe?
    var cube: String?

    var lookRecipe: LookRecipe? {
        guard let r = recipe else { return nil }
        return LookRecipe(temperature: r.temperature, tint: r.tint, contrast: r.contrast,
                          saturation: r.saturation, brightness: r.brightness,
                          vignette: r.vignette, bloom: r.bloom)
    }
}

guard let looksData = try? Data(contentsOf: looksURL),
      let shipped = try? JSONDecoder().decode([ShippedLook].self, from: looksData), !shipped.isEmpty else {
    print("Could not read the looks from \(looksURL.path)")
    exit(2)
}

func film(_ code: String) -> ParsedLUT? {
    try? pipeline.loadLUT(at: filmDir.appendingPathComponent("FS_\(code).cube"))
}

/// The look a new install opens with, which a preset is worn over until the
/// person picks another built-in look (MockData.defaultLook).
let goldenHour = shipped.first { $0.code == "KD2" }?.lookRecipe ?? LookRecipe()

if mode == "check" {

    // MARK: - 2. The colour tools do on screen what their numbers say

    section("2. The Grade Room colour tools work on the numbers a screen shows")
    let black: RGB = (0, 0, 0), mid: RGB = (0.5, 0.5, 0.5), white: RGB = (1, 1, 1)

    // A curve whose black point is lifted to 0.1 and is otherwise straight.
    let lifted = full { $0.curves = CurveSet(master: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)]) }
    let curveOut = graded([black, mid, white], state(lifted))
    check(gap(curveOut[0], (0.1, 0.1, 0.1)) < 1.5, "a curve lifted to 0.1 at black shows 0.1 on screen (26 of 255)",
          "shows \(show(curveOut[0]))")
    check(gap(curveOut[1], (0.55, 0.55, 0.55)) < 1.5 && gap(curveOut[2], white) < 1.5,
          "the same curve puts mid grey at 0.55 and leaves white alone",
          "mid \(show(curveOut[1])), white \(show(curveOut[2]))")

    // A wheel lifting the shadows by 0.1.
    let wheel = full { $0.wheels = ColorWheels(liftR: 0.1, liftG: 0.1, liftB: 0.1) }
    let wheelOut = graded([black, white], state(wheel))
    check(gap(wheelOut[0], (0.1, 0.1, 0.1)) < 1.5 && gap(wheelOut[1], white) < 1.5,
          "a shadow wheel lifted by 0.1 shows 0.1 at black", "shows \(show(wheelOut[0]))")

    // The red band taken to no saturation: pure red becomes mid grey.
    let noRed = full { s in
        var bands = HSLBands()
        bands.sat[0] = -1
        s.hsl = bands
    }
    let hslOut = graded([(1, 0, 0), mid], state(noRed))
    check(gap(hslOut[0], mid) < 1.5 && gap(hslOut[1], mid) < 1.5,
          "the red band with its colour taken out turns pure red into mid grey (128 of 255)",
          "shows \(show(hslOut[0]))")

    // A blue shadow tint of 0.2: black gains 0.1 of blue and nothing else.
    let tinted = full { $0.splitTone = SplitTone(shadowHue: 240, shadowSat: 0.2, highlightHue: 60,
                                                 highlightSat: 0, balance: 0) }
    let splitOut = graded([black, white], state(tinted))
    check(gap(splitOut[0], (0, 0, 0.1)) < 1.5 && gap(splitOut[1], white) < 1.5,
          "a blue shadow tint of 0.2 adds 0.1 of blue to black and leaves white alone",
          "black \(show(splitOut[0]))")

    // The presets themselves: a lifted toe, never a milky black. Before the
    // fix Rich Cinema's black came out at (0, 62, 87).
    for preset in SkinFirstPreset.allCases {
        var s = preset.settings
        s.intensity = 100
        let out = graded([black], state(s))[0]
        check(max(out.0, out.1, out.2) * 255 < 46,
              "\(preset.name): black stays dark, no colour above 46 of 255", "shows \(show(out))")
    }

    // A black-and-white film look with nothing else on is black and white.
    let ramp: [RGB] = (0...16).map { let v = Double($0) / 16; return (v, v, v) }
    let warmSkin: [RGB] = [(0.55, 0.38, 0.30), (0.30, 0.19, 0.14), (0.80, 0.62, 0.52), (0.2, 0.4, 0.7)]
    // Press Mono 800 is the app's own black-and-white cube. It is checked
    // whenever it is in the app; the two measured stocks always are.
    let ownMono = ["PM800"].filter {
        FileManager.default.fileExists(atPath: filmDir.appendingPathComponent("FS_\($0).cube").path)
    }
    for code in ["HP400", "TX400"] + ownMono {
        guard let lut = film(code) else { check(false, "\(code): the film file opens"); continue }
        let out = graded(ramp + warmSkin, state(lut: lut, full()))
        let cast = out.map { max(abs($0.0 - $0.1), abs($0.2 - $0.1)) * 255 }.max() ?? 0
        check(cast < 1.5, "\(code): a black-and-white look with nothing else on has no colour in it",
              "largest tint \(f1(cast)) of 255")
    }

    // MARK: - 3. Every look, picked after a preset, is the look its thumbnail shows

    section("3. Every look picked after a preset is the look its thumbnail shows")
    // A small picture with skin, greys and strong colours in it.
    var patches: [RGB] = ramp + warmSkin
    for r in [0.1, 0.5, 0.9] { for g in [0.1, 0.5, 0.9] { for b in [0.1, 0.5, 0.9] { patches.append((r, g, b)) } } }

    var looksChecked = 0
    var wrongAfterFix: [String] = []
    var offBefore: [Double] = []
    for look in shipped {
        let recipe = look.lookRecipe ?? LookRecipe()
        var lut: ParsedLUT?
        if let cube = look.cube {
            lut = try? pipeline.loadLUT(at: filmDir.appendingPathComponent(cube))
            if lut == nil { wrongAfterFix.append("\(look.code) (file would not open)"); continue }
        }
        // What LookThumbs renders for this look.
        let thumbnail = graded(patches, state(recipe: recipe, lut: lut, full()))
        looksChecked += 1
        for preset in SkinFirstPreset.allCases {
            // Preset picked, Auto used on top, then this look picked:
            // AppModel.select(look:) takes the preset off, then the look goes on.
            var after = SkinFirstPreset.takenOff(withAutoOnTop(preset.settings))
            after.intensity = 100          // compare at the thumbnail's strength
            let picked = graded(patches, state(recipe: recipe, lut: lut, after))
            let worst = zip(thumbnail, picked).map { gap($0, $1) }.max() ?? 0
            if worst > 0.5 { wrongAfterFix.append("\(look.code) after \(preset.name): \(f1(worst)) of 255") }
        }
        // For the record: how far off the same look was with Rich Cinema left on.
        var stuck = SkinFirstPreset.richCinema.settings
        stuck.intensity = 100
        let wrong = graded(patches, state(recipe: recipe, lut: lut, stuck))
        offBefore.append(zip(thumbnail, wrong).map { gap($0, $1) }.reduce(0, +) / Double(patches.count))
    }
    check(looksChecked == shipped.count, "all \(shipped.count) looks were opened", "\(looksChecked) opened")
    check(wrongAfterFix.isEmpty,
          "all \(looksChecked) looks, picked after each of the 3 presets, match their thumbnail exactly",
          wrongAfterFix.isEmpty ? "largest gap under 0.5 of 255" : wrongAfterFix.prefix(6).joined(separator: "; "))
    let meanOff = offBefore.reduce(0, +) / Double(max(offBefore.count, 1))
    print("  note  with Rich Cinema left on underneath (the old fault), the same looks are off by "
          + "\(f1(meanOff)) of 255 on average, \(f1(offBefore.max() ?? 0)) for the worst.")
}

// MARK: - Measuring helpers (the checks below and the measure mode share them)

func i255(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
func tri(_ c: RGB) -> String { "\(i255(c.0)),\(i255(c.1)),\(i255(c.2))" }
func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

/// A square picture through the whole pipeline, read back at one pixel.
func through(_ px: [Float], side: Int, _ st: LookState, at point: (Int, Int)) -> RGB {
    let source = CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) },
                         bytesPerRow: side * 16, size: CGSize(width: side, height: side),
                         format: .RGBAf, colorSpace: srgb)
    let image = pipeline.apply(state: st, to: source, includeSplit: false).cropped(to: source.extent)
    var buf = [Float](repeating: 0, count: 4)
    buf.withUnsafeMutableBytes { raw in
        pipeline.context.render(image, toBitmap: raw.baseAddress!, rowBytes: 16,
                                bounds: CGRect(x: point.0, y: point.1, width: 1, height: 1),
                                format: .RGBAf, colorSpace: srgb)
    }
    return (Double(buf[0]), Double(buf[1]), Double(buf[2]))
}

/// A flat square of one colour through the whole pipeline, read back at
/// its centre (or its corner), so a spatial tool sees no neighbours.
func flat(_ c: RGB, _ st: LookState, side: Int = 64, corner: Bool = false) -> RGB {
    var px = [Float](repeating: 1, count: side * side * 4)
    for i in 0..<(side * side) {
        px[i * 4] = Float(c.0)
        px[i * 4 + 1] = Float(c.1)
        px[i * 4 + 2] = Float(c.2)
    }
    let at = corner ? 0 : side / 2
    return through(px, side: side, st, at: (at, at))
}

/// How far the cube the app exports for a grade is from the picture that
/// grade gives, over a spread of colours: the largest and the mean gap, of
/// 255. Built the way `GradeCubeBaker` builds it: a 33-point lattice through
/// the pipeline with the spatial tools taken off.
func cubeDistance(recipe: LookRecipe = LookRecipe(), _ settings: LookSettings)
    -> (worst: Double, mean: Double, at: String) {
    let n = 33
    let width = n * n, height = n
    var pixels = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = Float(x % n) / Float(n - 1)
            pixels[i + 1] = Float(y) / Float(n - 1)
            pixels[i + 2] = Float(x / n) / Float(n - 1)
            pixels[i + 3] = 1
        }
    }
    let identity = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
                           bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                           format: .RGBAf, colorSpace: srgb)
    // As GradeCubeBaker strips them.
    var s = settings
    s.grain = 0; s.halation = 0; s.bloom = 0; s.vignette = 0; s.sharpness = 0
    s.lensKind = LensKind.none.rawValue
    let st = state(recipe: recipe, s)
    let lattice = pipeline.apply(state: st, to: identity, includeSplit: false).cropped(to: identity.extent)
    var out = [Float](repeating: 0, count: width * height * 4)
    out.withUnsafeMutableBytes { raw in
        pipeline.context.render(lattice, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                format: .RGBAf, colorSpace: srgb)
    }
    var worst = 0.0, total = 0.0, count = 0.0
    var worstAt = ""
    for b in stride(from: 0, to: n, by: 8) {
        for g in stride(from: 0, to: n, by: 8) {
            for r in stride(from: 0, to: n, by: 4) {
                let i = (g * width + (b * n + r)) * 4
                let cube: RGB = (Double(out[i]), Double(out[i + 1]), Double(out[i + 2]))
                let c: RGB = (Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                let truth = flat(c, st, side: 24)
                let d = gap(cube, truth)
                total += d
                count += 1
                if d > worst {
                    worst = d
                    worstAt = "colour \(tri(c)): cube \(tri(cube)), picture \(tri(truth))"
                }
            }
        }
    }
    return (worst, total / count, worstAt)
}

/// The red channel of a 512 pixel window, 0 to 255: its mean, its spread
/// (standard deviation), its lowest and highest value, and the mean alpha.
struct Spread {
    var mean = 0.0, sd = 0.0, lowest = 0.0, highest = 0.0, alpha = 0.0
    var line: String {
        "mean \(f1(mean))  spread \(f1(sd))  lowest \(f1(lowest))  highest \(f1(highest))  alpha \(f1(alpha * 100))%"
    }
}

func spread(_ image: CIImage, window: CGRect, managed: Bool = true) -> Spread {
    let w = Int(window.width), h = Int(window.height)
    var buf = [Float](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        pipeline.context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                                bounds: window, format: .RGBAf, colorSpace: managed ? srgb : nil)
    }
    var sum = 0.0, squares = 0.0, lo = 1e9, hi = -1e9, alpha = 0.0
    let n = Double(w * h)
    for i in stride(from: 0, to: buf.count, by: 4) {
        let v = Double(buf[i]) * 255
        sum += v
        squares += v * v
        lo = min(lo, v)
        hi = max(hi, v)
        alpha += Double(buf[i + 3])
    }
    let mean = sum / n
    return Spread(mean: mean, sd: max(0, squares / n - mean * mean).squareRoot(),
                  lowest: lo, highest: hi, alpha: alpha / n)
}

/// A flat grey the size of the big picture, and a window in the middle of it.
let bigPicture = CGRect(x: 0, y: 0, width: 1400, height: 1400)
let middleWindow = CGRect(x: 400, y: 400, width: 512, height: 512)
func grey(_ v: Double) -> CIImage {
    CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: srgb)!).cropped(to: bigPicture)
}

/// The picture scaled so its long edge is `longEdge`, with its corner at 0, 0.
func sized(_ image: CIImage, longEdge: CGFloat) -> CIImage {
    let longest = max(image.extent.width, image.extent.height)
    let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: longEdge / longest, kCIInputAspectRatioKey: 1.0])
    let e = scaled.extent
    return scaled.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
}

/// How far a grade moves a picture when the picture is `longEdge` pixels
/// long, judged at look-tile size (220 pixels, one pixel in from the edge):
/// the mean change and the root-mean-square change, of 255. The same grade
/// should move a tile, the big picture and a full-size export by the same.
func change(_ st: LookState, on photo: CIImage, at longEdge: CGFloat) -> (Double, Double) {
    let thumb = sized(photo, longEdge: 220).extent
    let tw = max(8, Int(thumb.width.rounded(.down)) - 2)
    let th = max(8, Int(thumb.height.rounded(.down)) - 2)
    func small(_ image: CIImage) -> [UInt8] {
        let down = sized(image, longEdge: 220)
        var buf = [UInt8](repeating: 0, count: tw * th * 4)
        buf.withUnsafeMutableBytes { raw in
            pipeline.context.render(down, toBitmap: raw.baseAddress!, rowBytes: tw * 4,
                                    bounds: CGRect(x: 1, y: 1, width: tw, height: th),
                                    format: .RGBA8, colorSpace: srgb)
        }
        return buf
    }
    let base = sized(photo, longEdge: longEdge)
    let rect = CGRect(x: 0, y: 0, width: base.extent.width.rounded(.down),
                      height: base.extent.height.rounded(.down))
    let cropped = base.cropped(to: rect)
    let out = pipeline.apply(state: st, to: cropped, includeSplit: false).cropped(to: rect)
    let a = small(cropped), b = small(out)
    var sum = 0.0, squares = 0.0, n = 0.0
    for i in stride(from: 0, to: a.count, by: 4) {
        for c in 0..<3 {
            let d = Double(b[i + c]) - Double(a[i + c])
            sum += abs(d)
            squares += d * d
            n += 1
        }
    }
    return (sum / n, (squares / n).squareRoot())
}

let testPortrait = CIImage(contentsOf: portraitDir.appendingPathComponent("day-pexels-9629932.jpg"),
                           options: [.applyOrientationProperty: true])

// MARK: - 5. The film tools and the tone sliders do what they say

if mode == "check" {
    section("5. Halation, grain, Shadows and Highlights do what they say, and nothing else")
    let deepSkin: RGB = (0.30, 0.19, 0.14), lightSkin: RGB = (0.80, 0.62, 0.52)
    let grey10: RGB = (0.1, 0.1, 0.1), grey25: RGB = (0.25, 0.25, 0.25)
    let grey50: RGB = (0.5, 0.5, 0.5), grey75: RGB = (0.75, 0.75, 0.75)
    let pureBlack: RGB = (0, 0, 0), pureWhite: RGB = (1, 1, 1)

    // Halation is a glow around highlights. With no highlight in the picture
    // it has nothing to do. It used to take red out of everything below the
    // highlights: mid grey came out teal (0, 91, 120), deep skin black.
    let halation = state(full { $0.halation = 50 })
    var halationWorst = 0.0, halationAt = ""
    for c in [pureBlack, grey10, grey25, grey50, grey75, deepSkin, lightSkin] {
        let out = flat(c, halation)
        if gap(out, c) > halationWorst { halationWorst = gap(out, c); halationAt = "\(tri(c)) came out \(tri(out))" }
    }
    check(halationWorst < 1.5, "Halation leaves a picture with no highlights alone (it turned mid grey teal)",
          halationWorst < 1.5 ? "largest change \(f1(halationWorst)) of 255" : halationAt)

    // Half white, half dark grey: the glow reaches into the dark half, warm,
    // and nothing in it gets darker.
    let side = 96
    var halves = [Float](repeating: 1, count: side * side * 4)
    for y in 0..<side {
        for x in (side / 2)..<side {
            let i = (y * side + x) * 4
            halves[i] = 0.1; halves[i + 1] = 0.1; halves[i + 2] = 0.1
        }
    }
    let nearEdge = through(halves, side: side, halation, at: (side / 2 + 2, side / 2))
    check(nearEdge.0 > 0.1 + 2.0 / 255 && nearEdge.0 > nearEdge.1 && nearEdge.1 >= nearEdge.2
              && nearEdge.1 > 0.1 - 1.0 / 255 && nearEdge.2 > 0.1 - 1.0 / 255,
          "Halation still glows warm next to a highlight, and darkens nothing",
          "dark grey 26,26,26 beside white came out \(tri(nearEdge))")

    // Shadows pulled down deepens deep skin and keeps its colour. It used to
    // take the green and blue out: 77,48,36 became 65,22,0.
    let down = flat(deepSkin, state(full { $0.shadows = -50 }))
    let hueBefore = deepSkin.1 / deepSkin.0, hueAfter = down.1 / max(down.0, 1e-6)
    check(down.0 < deepSkin.0 && down.0 > down.1 && down.1 > down.2 && down.2 > 12.0 / 255
              && abs(hueAfter - hueBefore) < 0.10,
          "Shadows at -50 darkens deep skin and keeps its colour (it turned 77,48,36 into 65,22,0)",
          "came out \(tri(down))")

    // Shadows up: black and white stay, and the greys land where the
    // slider always put them.
    let up = state(full { $0.shadows = 50 })
    let upGreys = [pureBlack, grey25, grey50, pureWhite].map { flat($0, up) }
    check(gap(upGreys[0], pureBlack) < 1.5 && gap(upGreys[3], pureWhite) < 1.5
              && abs(upGreys[1].0 * 255 - 97) < 3 && abs(upGreys[2].0 * 255 - 157) < 3,
          "Shadows at +50 lifts 25% grey to 97 and mid grey to 157, and leaves black and white alone",
          "black \(tri(upGreys[0])), 25% \(tri(upGreys[1])), mid \(tri(upGreys[2])), white \(tri(upGreys[3]))")

    // Highlights moves the top half by the same amount up or down. Pulled
    // down it used to move 75% grey by 7 where Shadows moved its own end by 30.
    let lower = state(full { $0.highlights = -50 }), raise = state(full { $0.highlights = 50 })
    let lowered = (flat(grey75, lower).0 - 0.75) * 255, raised = (flat(grey75, raise).0 - 0.75) * 255
    check(lowered < -10 && lowered > -22 && raised > 10 && raised < 22 && abs(lowered + raised) < 4,
          "Highlights at -50 and +50 move 75% grey by the same amount, down and up",
          "down \(f1(lowered)), up \(f1(raised)) of 255")
    var highlightStray = 0.0
    for st in [lower, raise] {
        for c in [pureBlack, grey25, grey50, pureWhite] { highlightStray = max(highlightStray, gap(flat(c, st), c)) }
    }
    check(highlightStray < 1.5, "Highlights leaves black, the lower half and white where they are",
          "largest change \(f1(highlightStray)) of 255")
    let warm = flat(lightSkin, raise)
    check(abs(warm.1 / warm.0 - lightSkin.1 / lightSkin.0) < 0.03 && abs(warm.2 / warm.0 - lightSkin.2 / lightSkin.0) < 0.04,
          "Highlights at +50 brightens light skin without changing its colour",
          "204,158,133 came out \(tri(warm))")

    // Grain roughens the picture. It must not brighten it or leave white
    // specks: it lifted mid grey from 128 to 139, with specks at 255. It
    // must also be there to see: with the specks gone and nothing else
    // changed, Grain at 50 moved mid grey by under 3 of 255.
    for v in [0.25, 0.5, 0.75] {
        let before = spread(grey(v), window: middleWindow)
        let after = spread(pipeline.applyGrain(strength: 0.5, to: grey(v)), window: middleWindow)
        check(abs(after.mean - before.mean) < 1.5 && after.sd > 2.5 && after.sd < 10
                  && after.highest < before.mean + 40 && after.lowest > before.mean - 40,
              "Grain at 50 on grey \(i255(v)) can be seen, and roughens it without brightening it or leaving specks",
              after.line)
    }

    section("6. The exported .cube is the picture, and a tile is the big picture made small")
    var cubeWorst = 0.0, cubeAt = ""
    var grades: [(String, LookSettings)] = SkinFirstPreset.allCases.map { preset in
        var s = preset.settings
        s.intensity = 100
        return (preset.name, s)
    }
    grades.append(("shadows +50", full { $0.shadows = 50 }))
    grades.append(("shadows -50", full { $0.shadows = -50 }))
    grades.append(("highlights -50", full { $0.highlights = -50 }))
    grades.append(("highlights +50", full { $0.highlights = 50 }))
    grades.append(("fade 50", full { $0.fade = 50 }))
    grades.append(("contrast 60, warmth 30, sharpness 50", full { $0.contrast = 60; $0.warmth = 30; $0.sharpness = 50 }))
    for (name, settings) in grades {
        let d = cubeDistance(settings)
        if d.worst > cubeWorst { cubeWorst = d.worst; cubeAt = "\(name): \(d.at)" }
    }
    check(cubeWorst < 1.0,
          "the exported .cube matches the picture for the 3 presets and for Shadows, Highlights and Fade",
          cubeWorst < 1.0 ? "largest gap \(f1(cubeWorst)) of 255 over \(grades.count) grades" : cubeAt)

    if let photo = testPortrait {
        // Sized in pixels, Bloom at 50 moved a tile by 14 of 255, the big
        // picture by 3 and a full-size export by 1.
        var tools: [(String, LookState)] = [
            ("Golden Hour", state(recipe: goldenHour, full())),
            ("bloom 50", state(full { $0.bloom = 50 })),
            ("halation 50", state(full { $0.halation = 50 })),
            ("vignette 50", state(full { $0.vignette = 50 })),
            ("the soft lens", state(full { $0.lensKind = LensKind.diffusion.rawValue; $0.lensAmount = 75 })),
            ("the tilt-shift lens", state(full { $0.lensKind = LensKind.tiltShift.rawValue; $0.lensAmount = 75 })),
            ("the toy lens", state(full { $0.lensKind = LensKind.plastic.rawValue; $0.lensAmount = 75 })),
        ]
        if let glow = shipped.filter({ $0.recipe != nil })
            .max(by: { ($0.recipe?.bloom ?? 0) < ($1.recipe?.bloom ?? 0) }), let r = glow.lookRecipe {
            tools.append(("\(glow.code), the look with the most bloom", state(recipe: r, full())))
        }
        var uneven: [String] = []
        var widest = 0.0
        for (name, st) in tools {
            let sizes = [220.0, 1400.0, 4032.0].map { change(st, on: photo, at: CGFloat($0)).0 }
            let lo = sizes.min() ?? 0, hi = sizes.max() ?? 0
            widest = max(widest, hi - lo)
            // The same to within 1 of 255, or within a quarter of itself.
            if hi - lo > max(1.0, 0.25 * hi) {
                uneven.append("\(name): \(sizes.map(f1).joined(separator: " / "))")
            }
        }
        check(uneven.isEmpty,
              "glow, blur and lenses move a 220 pixel tile, the 1400 pixel big picture and a 4032 pixel export alike",
              uneven.isEmpty ? "\(tools.count) tools, widest difference \(f1(widest)) of 255" : uneven.joined(separator: "; "))
    } else {
        print("  note  no test portrait in \(portraitDir.path), so the sizes were not compared")
    }
}

// MARK: - 7. The White balance picker

if mode == "check" {
    section("7. The White balance picker makes the point it is given grey")
    // Greys that carry a cast the Warmth and Tint sliders can reach.
    let casts: [(String, RGB)] = [
        ("a grey that looks green", (0.48, 0.52, 0.48)),
        ("a grey that looks magenta", (0.53, 0.48, 0.53)),
        ("a grey that looks blue", (0.48, 0.50, 0.53)),
        ("a grey that looks yellow", (0.52, 0.51, 0.47)),
        ("a light grey that looks blue and green", (0.74, 0.80, 0.82)),
        ("a dark grey that looks green", (0.17, 0.20, 0.17)),
    ]
    func fromGrey(_ c: RGB) -> Double { max(abs(c.0 - c.1), abs(c.2 - c.1)) * 255 }
    var oldLeft: [String] = []
    for (name, c) in casts {
        let wb = pipeline.neutralising((r: c.0, g: c.1, b: c.2))
        let out = graded([c], state(full { $0.warmth = wb.warmth; $0.tint = wb.tint }))[0]
        check(fromGrey(out) < 2.0 && abs(wb.warmth) < 80 && abs(wb.tint) < 80,
              "\(name) comes out grey",
              "\(tri(c)) with Warmth \(Int(wb.warmth)) and Tint \(Int(wb.tint)) came out \(tri(out)), \(f1(fromGrey(out))) of 255 from grey")
        // The rule the picker used before, for the record.
        let warmth = max(-80, min(80, (c.2 - c.0) * 340))
        let tint = max(-80, min(80, ((c.0 + c.2) / 2 - c.1) * 340))
        let old = graded([c], state(full { $0.warmth = warmth; $0.tint = tint }))[0]
        oldLeft.append("\(f1(fromGrey(c))) to \(f1(fromGrey(old)))")
    }
    print("  note  the rule it replaces left these as far from grey (of 255, before to after): " + oldLeft.joined(separator: "; "))
    let grey = pipeline.neutralising((r: 0.5, g: 0.5, b: 0.5))
    check(grey.warmth == 0 && grey.tint == 0, "a grey that is already grey is left alone")
}

// MARK: - Pictures

/// Writes two test portraits through the presets and two film looks, so a
/// change to this part of the engine can be looked at, not only measured.
func writePictures() {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let portraits = ["day-pexels-9629932", "day-pexels-31579771"]
    var written = 0
    for name in portraits {
        let url = portraitDir.appendingPathComponent(name + ".jpg")
        guard let photo = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            print("  note  no portrait at \(url.path), so no pictures of it")
            continue
        }
        func save(_ tag: String, _ st: LookState?) {
            let image: CGImage?
            if let st {
                image = pipeline.gradedStill(photo, state: st, maxDimension: 720)
            } else {
                let longest = max(photo.extent.width, photo.extent.height)
                let scale = min(1, 720 / longest)
                let small = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                image = pipeline.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: srgb)
            }
            guard let image else { return }
            let file = outDir.appendingPathComponent("\(name)__\(tag).jpg")
            guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
            if CGImageDestinationFinalize(dest) { written += 1 }
        }
        save("original", nil)
        for preset in SkinFirstPreset.allCases {
            var s = preset.settings
            s.intensity = 100
            save("preset-\(preset.rawValue)", state(recipe: goldenHour, s))
        }
        for code in ["HP400", "PR100"] {
            guard let lut = film(code) else { continue }
            save("look-\(code)", state(lut: lut, full()))
        }
    }
    print("\nWrote \(written) pictures to \(outDir.path)")
}

// MARK: - Measurements (mode "measure"): what the tools really do

if mode == "measure" {
    setvbuf(stdout, nil, _IOLBF, 0)
    // M1. Each slider on flat colours.
    section("M1. What each slider does to flat colours (0 to 255, as a screen shows them)")
    let patches: [(String, RGB)] = [
        ("black", (0, 0, 0)), ("10%", (0.1, 0.1, 0.1)), ("25%", (0.25, 0.25, 0.25)),
        ("mid", (0.5, 0.5, 0.5)), ("75%", (0.75, 0.75, 0.75)), ("white", (1, 1, 1)),
        ("deep skin", (0.30, 0.19, 0.14)), ("brown skin", (0.55, 0.38, 0.30)),
        ("light skin", (0.80, 0.62, 0.52))]
    print("  " + pad("setting", 24) + patches.map { pad($0.0, 13) }.joined())
    func row(_ name: String, _ st: LookState, corner: Bool = false) {
        let cells = patches.map { pad(tri(flat($0.1, st, corner: corner)), 13) }
        print("  " + pad(name, 24) + cells.joined())
    }
    row("nothing on", state(full()))
    row("exposure +50", state(full { $0.exposure = 50 }))
    row("exposure -50", state(full { $0.exposure = -50 }))
    row("contrast 60", state(full { $0.contrast = 60 }))
    row("contrast -40", state(full { $0.contrast = -40 }))
    row("highlights +50", state(full { $0.highlights = 50 }))
    row("highlights -50", state(full { $0.highlights = -50 }))
    row("shadows +50", state(full { $0.shadows = 50 }))
    row("shadows -50", state(full { $0.shadows = -50 }))
    row("saturation +50", state(full { $0.saturation = 50 }))
    row("saturation -50", state(full { $0.saturation = -50 }))
    row("warmth +50", state(full { $0.warmth = 50 }))
    row("warmth -50", state(full { $0.warmth = -50 }))
    row("tint +50", state(full { $0.tint = 50 }))
    row("tint -50", state(full { $0.tint = -50 }))
    row("fade 50", state(full { $0.fade = 50 }))
    row("fade 100", state(full { $0.fade = 100 }))
    row("sharpness 50", state(full { $0.sharpness = 50 }))
    row("bloom 50", state(full { $0.bloom = 50 }))
    row("halation 50", state(full { $0.halation = 50 }))
    row("vignette 50 centre", state(full { $0.vignette = 50 }))
    row("vignette 50 corner", state(full { $0.vignette = 50 }), corner: true)
    row("vignette 100 corner", state(full { $0.vignette = 100 }), corner: true)
    if let hp = film("HP400") {
        row("HP400 at 100", state(lut: hp, full()))
        row("HP400 at 75", state(lut: hp, LookSettings()))
        let mixed: [String] = patches.map { patch in
            let g = flat(patch.1, state(lut: hp, full()))
            let m: RGB = (patch.1.0 * 0.25 + g.0 * 0.75, patch.1.1 * 0.25 + g.1 * 0.75,
                          patch.1.2 * 0.25 + g.2 * 0.75)
            return pad(tri(m), 13)
        }
        print("  " + pad("(75% of the numbers)", 24) + mixed.joined())
    }
    row("Golden Hour at 100", state(recipe: goldenHour, full()))
    row("Golden Hour at 75", state(recipe: goldenHour, LookSettings()))

    // M2. The same picture at thumbnail, preview and export size.
    section("M2. How strong each spatial tool looks at thumbnail (220), preview (1400) and export (4032) size")
    if let photo = testPortrait {
        var tools: [(String, LookState)] = []
        tools.append(("Golden Hour (the default look)", state(recipe: goldenHour, full())))
        if let glow = shipped.filter({ $0.recipe != nil })
            .max(by: { ($0.recipe?.bloom ?? 0) < ($1.recipe?.bloom ?? 0) }), let r = glow.lookRecipe {
            tools.append(("\(glow.code) \(glow.name) (most bloom, \(r.bloom))", state(recipe: r, full())))
        }
        tools.append(("bloom 50", state(full { $0.bloom = 50 })))
        tools.append(("halation 50", state(full { $0.halation = 50 })))
        tools.append(("grain 50", state(full { $0.grain = 50 })))
        tools.append(("sharpness 50", state(full { $0.sharpness = 50 })))
        tools.append(("vignette 50", state(full { $0.vignette = 50 })))
        tools.append(("shadows +50", state(full { $0.shadows = 50 })))
        tools.append(("highlights -50", state(full { $0.highlights = -50 })))
        for lens in LensKind.allCases where lens != .none {
            tools.append(("lens \(lens.rawValue) 75", state(full { $0.lensKind = lens.rawValue; $0.lensAmount = 75 })))
        }
        print("  " + pad("tool", 44) + pad("at 220", 18) + pad("at 1400", 18) + pad("at 4032", 18) + "(mean change, rms change)")
        for (name, st) in tools {
            var cells = ""
            for edge in [220.0, 1400.0, 4032.0] {
                let e = change(st, on: photo, at: CGFloat(edge))
                cells += pad("\(f1(e.0)), \(f1(e.1))", 18)
            }
            print("  " + pad(name, 44) + cells)
        }
    } else {
        print("  note  no test portrait in \(portraitDir.path)")
    }

    // M3. The exported cube against the picture.
    section("M3. The exported .cube against the picture it was made from (largest gap, of 255)")
    func cubeGap(_ name: String, _ settings: LookSettings) {
        let d = cubeDistance(settings)
        print("  " + pad(name, 30) + pad("worst \(f1(d.worst))", 14) + pad("mean \(f1(d.mean))", 12) + d.at)
    }
    cubeGap("nothing on", full())
    for preset in SkinFirstPreset.allCases {
        var s = preset.settings
        s.intensity = 100
        cubeGap(preset.name, s)
    }
    cubeGap("shadows +50", full { $0.shadows = 50 })
    cubeGap("shadows -50", full { $0.shadows = -50 })
    cubeGap("highlights -50", full { $0.highlights = -50 })
    cubeGap("highlights +50", full { $0.highlights = 50 })
    cubeGap("fade 50", full { $0.fade = 50 })
    cubeGap("sharpness 50", full { $0.sharpness = 50 })
    cubeGap("contrast 60, warmth 30", full { $0.contrast = 60; $0.warmth = 30 })
    cubeGap("shadows +50, highlights -50", full { $0.shadows = 50; $0.highlights = -50 })

    // M4. Grain: does it shift the picture, or only roughen it?
    section("M4. Grain 50 on flat greys, a 512 pixel window of a 1400 pixel picture (0 to 255)")
    if let noise = CIFilter.randomGenerator().outputImage {
        print("  " + pad("raw noise, red channel", 34) + spread(noise.cropped(to: bigPicture), window: middleWindow, managed: false).line)
        print("  " + pad("raw noise with alpha set to 1", 34)
              + spread(noise.cropped(to: bigPicture).settingAlphaOne(in: bigPicture),
                       window: middleWindow, managed: false).line)
    }
    for v in [0.1, 0.25, 0.5, 0.75, 0.9] {
        let base = grey(v)
        print("  " + pad("grey \(i255(v)) as it is", 34) + spread(base, window: middleWindow).line)
        print("  " + pad("grey \(i255(v)) with grain 50", 34) + spread(pipeline.applyGrain(strength: 0.5, to: base), window: middleWindow).line)
    }

    // M5. The playing video preview used to hand the pipeline a frame with
    // no bounds (clamped to extent). How far is that from the same frame
    // with its bounds, which is what the export hands it?
    section("M5. A frame without bounds (the old video preview) against the same frame with bounds (the export), of 255")
    if let photo = testPortrait {
        let rect = CGRect(x: 0, y: 0, width: photo.extent.width.rounded(.down),
                          height: photo.extent.height.rounded(.down))
        let frame = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.minX,
                                                            y: -photo.extent.minY)).cropped(to: rect)
        func bytes(_ image: CIImage) -> [UInt8] {
            let w = Int(rect.width), h = Int(rect.height)
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { raw in
                pipeline.context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4,
                                        bounds: rect, format: .RGBA8, colorSpace: srgb)
            }
            return buf
        }
        func apart(_ name: String, _ st: LookState, split: Bool = false) {
            let bounded = bytes(pipeline.apply(state: st, to: frame, includeSplit: split).cropped(to: rect))
            let unbounded = bytes(pipeline.apply(state: st, to: frame.clampedToExtent(), includeSplit: split)
                .cropped(to: rect))
            var sum = 0.0, worst = 0.0
            for i in stride(from: 0, to: bounded.count, by: 4) {
                for c in 0..<3 {
                    let d = abs(Double(bounded[i + c]) - Double(unbounded[i + c]))
                    sum += d
                    worst = max(worst, d)
                }
            }
            print("  " + pad(name, 40) + "mean \(f1(sum / Double(bounded.count / 4 * 3)))   worst \(f1(worst))")
        }
        apart("nothing on", state(full()))
        apart("Golden Hour (the default look)", state(recipe: goldenHour, full()))
        apart("vignette 50", state(full { $0.vignette = 50 }))
        apart("bloom 50", state(full { $0.bloom = 50 }))
        apart("grain 50", state(full { $0.grain = 50 }))
        apart("sharpness 50", state(full { $0.sharpness = 50 }))
        for lens in LensKind.allCases where lens != .none {
            apart("lens \(lens.rawValue) 75", state(full { $0.lensKind = lens.rawValue; $0.lensAmount = 75 }))
        }
        let wiped = state(recipe: goldenHour, full())
        wiped.splitFraction = 0.3
        apart("the before and after wipe at 30%", wiped, split: true)
        // Halation is left out: its glow is sized against the frame, and
        // a frame without bounds has no size to give it.
    }

    exit(0)
}

writePictures()

#endif

// MARK: - Result

if mode == "check" {
    print("\n\(checks) checks, \(failed.count) failed, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    if !failed.isEmpty {
        print("FAILED:")
        for name in failed { print("  " + name) }
        exit(1)
    }
    print("Grade on top of a look: all checks passed.")
}

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
    for code in ["HP400", "TX400", "PM800"] {
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

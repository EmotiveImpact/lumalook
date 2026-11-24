// Pictures for a before and after sheet: one test portrait through the tools
// on the look screen, written by whichever engine this file is compiled with.
//
// The skin test workflow compiles it twice, once with this branch's engine
// and once with master's, so a change to how a tool looks can be put side by
// side and looked at, not only measured. It uses only what both engines have
// (LookPipeline.apply and gradedStill), and it checks nothing: the checks
// are in check_grade.swift.
//
//   mkdir -p /tmp/sheet && cp tools/skin-test/sheet_pictures.swift /tmp/sheet/main.swift
//   swiftc -O -o /tmp/sheet/now /tmp/sheet/main.swift \
//       LumaLook/Models/LumaModels.swift LumaLook/Engine/SkinFirstPresets.swift \
//       LumaLook/Engine/ColorMath.swift LumaLook/Engine/LookPipeline.swift \
//       LumaLook/Engine/LogNormalizer.swift LumaLook/Engine/OverlayEffects.swift \
//       LumaLook/Engine/TrueColour.swift LumaLook/Engine/LUTParser.swift \
//       LumaLook/Engine/LUTDensifier.swift
//   /tmp/sheet/now tools/skin-test/looks.json LumaLook/Resources/FilmLUTs \
//       tools/skin-test/out/candidates /tmp/sheet/pictures
//
// Three sizes matter. A look tile is 220 pixels long, the big picture on the
// look screen is 1400, and a photo from an iPhone exports at 4032. The same
// tool should look the same on all three, so most tools are written at each
// size, with the export scaled back to 1400 so the three can sit in a row.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// LumaModels.swift names this type for the Home screen's sample clips. The
/// real one lives with the artwork (Design/SceneArt.swift) and is not needed
/// to grade a picture.
enum MockScene: CaseIterable, Hashable { case none }

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: sheet looks.json FilmLUTs portraits out [portrait]")
    exit(2)
}
let looksURL = URL(fileURLWithPath: args[1])
let filmDir = URL(fileURLWithPath: args[2])
let portraitDir = URL(fileURLWithPath: args[3])
let outDir = URL(fileURLWithPath: args[4])
let portraitName = args.count > 5 ? args[5] : "day-pexels-9629932"

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let pipeline = LookPipeline.shared

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
guard let photo = CIImage(contentsOf: portraitDir.appendingPathComponent(portraitName + ".jpg"),
                          options: [.applyOrientationProperty: true]) else {
    print("No portrait called \(portraitName) in \(portraitDir.path)")
    exit(2)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// A grade with nothing on but what `change` sets. Strength is 100 unless
/// said: what a look tile is drawn with.
func grade(recipe: LookRecipe = LookRecipe(), lut: ParsedLUT? = nil, strength: Double = 100,
           _ change: (inout LookSettings) -> Void = { _ in }) -> LookState {
    var settings = LookSettings()
    settings.intensity = strength
    change(&settings)
    let s = LookState()
    s.recipe = recipe
    s.lut = lut
    s.settings = settings
    return s
}

/// The picture scaled so its long edge is `longEdge`, with its corner at 0, 0.
func sized(_ image: CIImage, longEdge: CGFloat) -> CIImage {
    let longest = max(image.extent.width, image.extent.height)
    let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: longEdge / longest, kCIInputAspectRatioKey: 1.0])
    let e = scaled.extent
    let moved = scaled.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    return moved.cropped(to: CGRect(x: 0, y: 0, width: e.width.rounded(.down), height: e.height.rounded(.down)))
}

var written = 0
func write(_ image: CIImage, _ tag: String) {
    guard let cg = pipeline.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb) else {
        print("  no picture for \(tag)")
        return
    }
    let file = outDir.appendingPathComponent(tag + ".jpg")
    guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    if CGImageDestinationFinalize(dest) {
        written += 1
        print("  \(tag)  \(cg.width) x \(cg.height)")
    }
}

/// The grade on the picture at one size, as a still: what the look screen,
/// a tile and a photo export all do.
func still(_ st: LookState, longEdge: CGFloat) -> CIImage {
    let source = sized(photo, longEdge: longEdge)
    return pipeline.apply(state: st, to: source, includeSplit: false).cropped(to: source.extent)
}

/// One tool at the three sizes: the tile, the big picture, and the export
/// scaled back to the big picture's size.
func threeSizes(_ tag: String, _ st: LookState) {
    write(still(st, longEdge: 220), tag + "__tile")
    write(still(st, longEdge: 1400), tag + "__big")
    write(sized(still(st, longEdge: 4032), longEdge: 1400), tag + "__export")
}

/// One tool on the big picture only.
func big(_ tag: String, _ st: LookState) {
    write(still(st, longEdge: 1400), tag + "__big")
}

/// A video frame graded two ways: with its bounds, as an export does, and
/// without them, as a frame handed over with its edges stretched out for ever.
func videoFrame(_ tag: String, _ st: LookState) {
    let frame = sized(photo, longEdge: 1400)
    write(pipeline.apply(state: st, to: frame, includeSplit: false).cropped(to: frame.extent),
          tag + "__frame-with-bounds")
    write(pipeline.apply(state: st, to: frame.clampedToExtent(), includeSplit: false).cropped(to: frame.extent),
          tag + "__frame-without-bounds")
}

print("Pictures of \(portraitName)")
write(sized(photo, longEdge: 1400), "original__big")
write(sized(photo, longEdge: 220), "original__tile")

// The film tools and the tone sliders, each on its own at 50.
big("halation-50", grade { $0.halation = 50 })
big("shadows-minus-50", grade { $0.shadows = -50 })
big("shadows-plus-50", grade { $0.shadows = 50 })
big("highlights-minus-50", grade { $0.highlights = -50 })
big("highlights-plus-50", grade { $0.highlights = 50 })

// Glow, blur and lenses at the three sizes.
if let golden = shipped.first(where: { $0.code == "KD2" })?.lookRecipe {
    threeSizes("golden-hour", grade(recipe: golden))
}
if let glow = shipped.filter({ $0.recipe != nil }).max(by: { ($0.recipe?.bloom ?? 0) < ($1.recipe?.bloom ?? 0) }),
   let recipe = glow.lookRecipe {
    print("  (most-bloom is \(glow.code) \(glow.name))")
    threeSizes("most-bloom", grade(recipe: recipe))
}
threeSizes("bloom-50", grade { $0.bloom = 50 })
threeSizes("grain-50", grade { $0.grain = 50 })
threeSizes("soft-lens-75", grade { $0.lensKind = LensKind.diffusion.rawValue; $0.lensAmount = 75 })
threeSizes("tilt-shift-75", grade { $0.lensKind = LensKind.tiltShift.rawValue; $0.lensAmount = 75 })

// A playing video frame, with and without its bounds.
videoFrame("vignette-50", grade { $0.vignette = 50 })
videoFrame("vintage-lens-75", grade { $0.lensKind = LensKind.vintage.rawValue; $0.lensAmount = 75 })

// A black and white film look at the strength a look opens at, and at full.
if let mono = try? pipeline.loadLUT(at: filmDir.appendingPathComponent("FS_HP400.cube")) {
    big("hp400-at-75", grade(lut: mono, strength: 75))
    big("hp400-at-100", grade(lut: mono, strength: 100))
}

// The choices that change how a look feels (24 Nov 2026). This engine and
// master's each write them, so a sheet can show how it is beside a proposal.

// Exposure, up and down.
big("exposure-plus-50", grade { $0.exposure = 50 })
big("exposure-minus-50", grade { $0.exposure = -50 })

// A Skin first preset on its own, and over three built-in looks: it sits on
// top of whichever one was picked last.
func worn(_ preset: SkinFirstPreset, over recipe: LookRecipe = LookRecipe()) -> LookState {
    let s = LookState()
    s.recipe = recipe
    s.settings = preset.settings
    return s
}
for preset in SkinFirstPreset.allCases {
    big("preset-\(preset.rawValue)-alone", worn(preset))
}
for (tag, code, name) in [("golden-hour", "KD2", "Golden Hour"), ("london-rain", "AG60", "London Rain"),
                          ("documentary-grit", "BW32", "Documentary Grit")] {
    if let recipe = shipped.first(where: { $0.code == code && $0.name == name })?.lookRecipe {
        big("preset-deepTrue-over-\(tag)", worn(.deepTrue, over: recipe))
        big("look-\(tag)", grade(recipe: recipe))
    }
}

// The white balance under Strength: a portrait with a grey wall under a blue
// light, with the white balance a tap on something grey gives, at the 75 a
// look opens with and at 100, with no look and under Golden Hour.
if let wallPhoto = CIImage(contentsOf: portraitDir.appendingPathComponent("day-pexels-3973059.jpg"),
                           options: [.applyOrientationProperty: true]) {
    func lin(_ e: Double) -> Double { e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4) }
    func enc(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    let gain = (0.90, 1.00, 1.14)
    let wall = sized(wallPhoto, longEdge: 1400)
    let cast = wall.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: CGFloat(gain.0), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: CGFloat(gain.1), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain.2), w: 0)]).cropped(to: wall.extent)
    // Mid grey under that light: what a tap on something grey would read.
    let grey = lin(0.5)
    let wb = pipeline.neutralising((r: enc(grey * gain.0), g: enc(grey * gain.1), b: enc(grey * gain.2)))
    print("  (white balance for the blue light: Warmth \(Int(wb.warmth)) Tint \(Int(wb.tint)))")
    func balanced(_ st: LookState) -> CIImage {
        pipeline.apply(state: st, to: cast, includeSplit: false).cropped(to: cast.extent)
    }
    write(wall, "wall-as-shot__big")
    write(cast, "wall-blue-light__big")
    for strength in [75.0, 100.0] {
        write(balanced(grade(strength: strength) { $0.warmth = wb.warmth; $0.tint = wb.tint }),
              "wall-blue-light-balanced-at-\(Int(strength))__big")
    }
    if let golden = shipped.first(where: { $0.code == "KD2" })?.lookRecipe {
        for strength in [75.0, 100.0] {
            write(balanced(grade(recipe: golden, strength: strength) { $0.warmth = wb.warmth; $0.tint = wb.tint }),
                  "wall-blue-light-golden-hour-balanced-at-\(Int(strength))__big")
        }
    }
}

print("Wrote \(written) pictures to \(outDir.path)")

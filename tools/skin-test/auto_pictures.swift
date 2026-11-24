// Pictures of Auto on the test portraits, to look at before it is switched
// back on: each portrait as shot, after the Auto that was taken out (the
// frame's average colour, which cooled warm skin), and after the Auto that
// replaces it (a colour cast only, read where the picture is nearly grey and
// cannot be skin). Portraits Auto can read are also shown under a blue and a
// green light, before and after.
//
// It checks nothing: the checks are in check_grade.swift (section 9) and
// check_truecolour.swift (section 11). It also writes auto.txt, one line a
// portrait, with what Auto read and what it set.
//
//   mkdir -p /tmp/auto && cp tools/skin-test/auto_pictures.swift /tmp/auto/main.swift
//   swiftc -O -o /tmp/auto/pictures /tmp/auto/main.swift \
//       LumaLook/Models/LumaModels.swift LumaLook/Engine/SkinFirstPresets.swift \
//       LumaLook/Engine/ColorMath.swift LumaLook/Engine/LookPipeline.swift \
//       LumaLook/Engine/LogNormalizer.swift LumaLook/Engine/OverlayEffects.swift \
//       LumaLook/Engine/TrueColour.swift LumaLook/Engine/LUTParser.swift \
//       LumaLook/Engine/LUTDensifier.swift
//   /tmp/auto/pictures tools/skin-test/out/candidates /tmp/auto/out
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// LumaModels.swift names this type for the Home screen's sample clips. The
/// real one lives with the artwork (Design/SceneArt.swift) and is not needed
/// to grade a picture.
enum MockScene: CaseIterable, Hashable { case none }

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: pictures portraits out")
    exit(2)
}
let portraitDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let pipeline = LookPipeline.shared
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

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
    let small = sized(image, longEdge: 700)
    guard let cg = pipeline.context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: srgb) else {
        print("  no picture for \(tag)")
        return
    }
    let file = outDir.appendingPathComponent(tag + ".jpg")
    guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    if CGImageDestinationFinalize(dest) { written += 1 }
}

/// The picture with these settings on it and no look, at the Strength the
/// look screen opens with.
func with(_ image: CIImage, _ change: (inout LookSettings) -> Void) -> CIImage {
    var settings = LookSettings()
    change(&settings)
    let s = LookState()
    s.settings = settings
    return pipeline.apply(state: s, to: image, includeSplit: false).cropped(to: image.extent)
}

/// The Auto that was taken out: exposure, white balance and contrast from
/// the frame's average colour.
func oldAuto(_ image: CIImage) -> (exposure: Double, warmth: Double, tint: Double) {
    let avg = CIFilter.areaAverage()
    avg.inputImage = image
    avg.extent = image.extent
    var px = [UInt8](repeating: 0, count: 4)
    if let out = avg.outputImage {
        pipeline.context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                format: .RGBA8, colorSpace: srgb)
    }
    let r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return (max(-0.6, min(0.6, (0.45 - luma) * 2.2)) * 100,
            max(-70, min(70, (b - r) * 320)),
            max(-70, min(70, ((r + b) / 2 - g) * 320)))
}

/// The picture as if the light on it had another colour: gains on red,
/// green and blue in linear light.
func lit(_ image: CIImage, _ gain: (Double, Double, Double)) -> CIImage {
    image.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: CGFloat(gain.0), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: CGFloat(gain.1), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain.2), w: 0)]).cropped(to: image.extent)
}

func says(_ b: TrueColour.Balance) -> String {
    switch b {
    case .unreadable: return "nothing to go by"
    case .balanced: return "balanced"
    case .cast(let r, let g, let bl):
        return "cast (\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((bl * 255).rounded())))"
    }
}

let names = ((try? FileManager.default.contentsOfDirectory(atPath: portraitDir.path)) ?? [])
    .filter { $0.hasSuffix(".jpg") }.sorted()
var report: [String] = []
var left = 0, fixed = 0
for file in names {
    guard let photo = CIImage(contentsOf: portraitDir.appendingPathComponent(file),
                              options: [.applyOrientationProperty: true]) else { continue }
    let name = String(file.dropLast(4))
    let image = sized(photo, longEdge: 1400)
    let reading = pipeline.readBalance(of: image)
    let new = pipeline.autoBalance(of: image)
    let old = oldAuto(image)
    var line = "\(name): \(says(reading)); Auto "
    if let new {
        fixed += 1
        line += "sets Warmth \(Int(new.warmth)) Tint \(Int(new.tint))"
    } else {
        left += 1
        line += "leaves it alone"
    }
    line += "; the old Auto set Exposure \(Int(old.exposure)) Warmth \(Int(old.warmth)) Tint \(Int(old.tint))"
    write(image, name + "__as-shot")
    write(with(image) { $0.exposure = old.exposure; $0.warmth = old.warmth; $0.tint = old.tint; $0.contrast = 14 },
          name + "__old-auto")
    write(with(image) { if let new { $0.warmth = new.warmth; $0.tint = new.tint } }, name + "__auto")

    // A portrait Auto can read, under a light of another colour.
    if reading == .balanced {
        for (light, gain) in [("blue", (0.90, 1.00, 1.14)), ("green", (0.95, 1.08, 0.95))] {
            let cast = lit(image, gain)
            let wb = pipeline.autoBalance(of: cast)
            write(cast, name + "__\(light)-light")
            write(with(cast) { if let wb { $0.warmth = wb.warmth; $0.tint = wb.tint } }, name + "__\(light)-light-auto")
            line += "; under a \(light) light " + (wb.map { "Warmth \(Int($0.warmth)) Tint \(Int($0.tint))" } ?? "left alone")
        }
    }
    report.append(line)
    print("  " + line)
}
report.append("")
report.append("\(names.count) portraits as shot: Auto leaves \(left) alone and sets a white balance on \(fixed).")
try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("auto.txt"), atomically: true, encoding: .utf8)
print("Wrote \(written) pictures and auto.txt to \(outDir.path)")

// Bakes every recipe look through real Core Image, the way the app does it
// (LookPipeline.applyRecipe: CITemperatureAndTint, then CIColorControls, in
// Core Image's default linear working space), so the skin test on Linux
// matches what a phone shows.
//
//   swift tools/skin-test/bake_recipes.swift tools/skin-test/looks.json OUTDIR HERO.jpg
//
// Writes, per recipe look, OUTDIR/luts/<id>.u16: a 25x25x25 colour cube,
// sRGB in and out, little-endian UInt16 RGB, red fastest, then green, then
// blue. Bloom and vignette are spatial, so instead of baking them it writes
// probe images (OUTDIR/probes) that the Python side fits its versions to.
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

let args = CommandLine.arguments
let looksURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let heroURL = URL(fileURLWithPath: args[3])
let lutDir = outDir.appendingPathComponent("luts")
let probeDir = outDir.appendingPathComponent("probes")
try FileManager.default.createDirectory(at: lutDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)

struct Recipe: Decodable {
    let temperature: Double, tint: Double, contrast: Double, saturation: Double
    let brightness: Double, vignette: Double, bloom: Double
}
struct Look: Decodable { let id: String; let recipe: Recipe? }

let looks = try JSONDecoder().decode([Look].self, from: Data(contentsOf: looksURL))
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
// The app's own context options (LookPipeline.shared.context).
let ctx = CIContext(options: [.useSoftwareRenderer: false])
print("working space:", ctx.workingColorSpace.map { String(describing: $0) } ?? "nil",
      "format:", ctx.workingFormat.rawValue)

// MARK: - The app's recipe, colour part (copied from LookPipeline.swift)

func shiftWhite(_ image: CIImage, towards kelvin: CGFloat, tint: CGFloat) -> CIImage {
    let filter = CIFilter.temperatureAndTint()
    filter.inputImage = image
    filter.neutral = CIVector(x: 6500, y: tint)
    filter.targetNeutral = CIVector(x: kelvin, y: 0)
    return filter.outputImage ?? image
}

func applyColour(_ recipe: Recipe, to image: CIImage) -> CIImage {
    var output = image
    if recipe.temperature != 6500 || recipe.tint != 0 {
        output = shiftWhite(output, towards: CGFloat(recipe.temperature), tint: CGFloat(recipe.tint))
    }
    if recipe.contrast != 1 || recipe.saturation != 1 || recipe.brightness != 0 {
        let controls = CIFilter.colorControls()
        controls.inputImage = output
        controls.contrast = Float(recipe.contrast)
        controls.saturation = Float(recipe.saturation)
        controls.brightness = Float(recipe.brightness)
        output = controls.outputImage ?? output
    }
    return output
}

// MARK: - Identity cube as an image: width N*N (r fastest, then b), height N (g)

let N = 25
let W = N * N, H = N
var px = [Float](repeating: 1, count: W * H * 4)
for g in 0..<N { for b in 0..<N { for r in 0..<N {
    let i = (g * W + b * N + r) * 4
    px[i] = Float(r) / Float(N - 1)
    px[i + 1] = Float(g) / Float(N - 1)
    px[i + 2] = Float(b) / Float(N - 1)
}}}
let identity = CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) },
                       bytesPerRow: W * 16, size: CGSize(width: W, height: H),
                       format: .RGBAf, colorSpace: srgb)

func renderFloats(_ image: CIImage, width: Int, height: Int) -> [Float] {
    var buf = [Float](repeating: 0, count: width * height * 4)
    buf.withUnsafeMutableBytes { raw in
        ctx.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                   bounds: CGRect(x: 0, y: 0, width: width, height: height),
                   format: .RGBAf, colorSpace: srgb)
    }
    return buf
}

var baked = 0
for look in looks {
    guard let recipe = look.recipe else { continue }
    let out = applyColour(recipe, to: identity).cropped(to: identity.extent)
    let buf = renderFloats(out, width: W, height: H)
    var cube = [UInt16](repeating: 0, count: N * N * N * 3)
    // Reorder rows (g) and columns (b, r) into r-fastest, then g, then b.
    for g in 0..<N { for b in 0..<N { for r in 0..<N {
        let src = (g * W + b * N + r) * 4
        let dst = ((b * N + g) * N + r) * 3
        for c in 0..<3 {
            cube[dst + c] = UInt16((max(0, min(1, buf[src + c])) * 65535).rounded())
        }
    }}}
    try cube.withUnsafeBufferPointer { Data(buffer: $0) }
        .write(to: lutDir.appendingPathComponent("\(look.id).u16"))
    baked += 1
}
print("baked \(baked) recipe cubes")

// MARK: - Probes for the spatial parts and the intensity blend

func writePNG(_ image: CIImage, _ name: String) throws {
    try ctx.writePNGRepresentation(of: image, to: probeDir.appendingPathComponent(name),
                                   format: .RGBA16, colorSpace: srgb)
}

// Vignette on flat mid grey at a phone-video size: the result is the mask.
let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: srgb)!)
    .cropped(to: CGRect(x: 0, y: 0, width: 1080, height: 1350))
for intensity in [0.25, 0.5, 1.0] {
    let v = CIFilter.vignette()
    v.inputImage = flat
    v.intensity = Float(intensity)
    v.radius = 2.0
    try writePNG(v.outputImage!.cropped(to: flat.extent), "vignette_\(Int(intensity * 100)).png")
}
try writePNG(flat, "vignette_input.png")

// Bloom on the golden-hour portrait, scaled to 1080 wide.
if let heroRaw = CIImage(contentsOf: heroURL) {
    let s = 1080 / heroRaw.extent.width
    let hero = heroRaw.transformed(by: CGAffineTransform(scaleX: s, y: s))
    let ext = hero.extent.integral
    let base = hero.cropped(to: ext)
    try writePNG(base, "bloom_input.png")
    for intensity in [0.2, 0.45, 1.0] {
        let b = CIFilter.bloom()
        b.inputImage = base.clampedToExtent()
        b.intensity = Float(intensity)
        b.radius = 8
        try writePNG(b.outputImage!.cropped(to: ext), "bloom_\(Int(intensity * 100)).png")
    }
} else {
    print("hero image missing: \(heroURL.path)")
}

// Intensity blend (CIDissolveTransition): black to white at 75 %.
let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, colorSpace: srgb)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: srgb)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
let d = CIFilter.dissolveTransition()
d.inputImage = black
d.targetImage = white
d.time = 0.75
let mix = renderFloats(d.outputImage!.cropped(to: black.extent), width: 8, height: 8)
print("dissolve black->white at 0.75 gives sRGB \(mix[0])  (linear blend would be 0.881, sRGB blend 0.75)")
let probe = "{\"dissolve75\": \(mix[0])}"
try probe.write(to: probeDir.appendingPathComponent("probes.json"), atomically: true, encoding: .utf8)
print("done")

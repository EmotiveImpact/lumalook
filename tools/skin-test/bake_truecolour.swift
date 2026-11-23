// Bakes every look through the app's True Colour engine on real Core Image,
// so the skin test on Linux measures exactly what a phone shows after the fix.
// Compiled together with the app's own files (TrueColour.swift, LUTParser.swift,
// LUTDensifier.swift), so it runs the shipping code, not a copy:
//
//   cp tools/skin-test/bake_truecolour.swift /tmp/tc/main.swift
//   swiftc -O -o /tmp/tc/bake /tmp/tc/main.swift LumaLook/Engine/TrueColour.swift \
//       LumaLook/Engine/LUTParser.swift LumaLook/Engine/LUTDensifier.swift
//   /tmp/tc/bake tools/skin-test/looks.json tools/skin-test/out LumaLook/Resources/FilmLUTs
//
// Writes 25x25x25 cubes (sRGB in and out, little-endian UInt16 RGB, red
// fastest, then green, then blue), the same format as bake_recipes.swift:
//   OUTDIR/luts_tc/<id>.u16       recipe colour stage, True Colour on
//   OUTDIR/luts_classic/<id>.u16  recipe colour stage, True Colour off
//   OUTDIR/film_tc/<id>.u16       film cube with the skin guard, as the app
//                                 runs it (densified to 64, guarded, trilinear)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

let args = CommandLine.arguments
let looksURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let filmDir = URL(fileURLWithPath: args[3])

struct Recipe: Decodable {
    let temperature: Double, tint: Double, contrast: Double, saturation: Double
    let brightness: Double, vignette: Double, bloom: Double
}
struct Look: Decodable { let id: String; let recipe: Recipe?; let cube: String? }

let looks = try JSONDecoder().decode([Look].self, from: Data(contentsOf: looksURL))
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CIContext(options: [.useSoftwareRenderer: false])   // LookPipeline.shared.context
UserDefaults.standard.set(true, forKey: TrueColour.key)

// The app's recipe colour stage (LookPipeline.applyRecipe without bloom and
// vignette, which are spatial).
func shiftWhite(_ image: CIImage, towards kelvin: CGFloat, tint: CGFloat) -> CIImage {
    let filter = CIFilter.temperatureAndTint()
    filter.inputImage = image
    filter.neutral = CIVector(x: 6500, y: tint)
    filter.targetNeutral = CIVector(x: kelvin, y: 0)
    return filter.outputImage ?? image
}

func applyColour(_ r: Recipe, to image: CIImage, protectSkin: Bool) -> CIImage {
    var output = image
    if r.temperature != 6500 || r.tint != 0 {
        output = shiftWhite(output, towards: CGFloat(r.temperature), tint: CGFloat(r.tint))
    }
    if let tone = TrueColour.toneFilter(contrast: Float(r.contrast), saturation: Float(r.saturation),
                                        brightness: Float(r.brightness), protectSkin: protectSkin) {
        tone.setValue(output, forKey: kCIInputImageKey)
        output = tone.outputImage ?? output
    }
    return output
}

// Identity lattice as an image: width N*N (r fastest, then b), height N (g).
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

func bake(_ image: CIImage, to url: URL) throws {
    var buf = [Float](repeating: 0, count: W * H * 4)
    buf.withUnsafeMutableBytes { raw in
        ctx.render(image.cropped(to: identity.extent), toBitmap: raw.baseAddress!, rowBytes: W * 16,
                   bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBAf, colorSpace: srgb)
    }
    var cube = [UInt16](repeating: 0, count: N * N * N * 3)
    for g in 0..<N { for b in 0..<N { for r in 0..<N {
        let src = (g * W + b * N + r) * 4
        let dst = ((b * N + g) * N + r) * 3
        for c in 0..<3 { cube[dst + c] = UInt16((max(0, min(1, buf[src + c])) * 65535).rounded()) }
    }}}
    try cube.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
}

for dir in ["luts_tc", "luts_classic", "film_tc"] {
    try FileManager.default.createDirectory(at: outDir.appendingPathComponent(dir),
                                            withIntermediateDirectories: true)
}

var counts = [String: Int]()
let start = Date()
for look in looks {
    if let r = look.recipe {
        try bake(applyColour(r, to: identity, protectSkin: true),
                 to: outDir.appendingPathComponent("luts_tc/\(look.id).u16"))
        try bake(applyColour(r, to: identity, protectSkin: false),
                 to: outDir.appendingPathComponent("luts_classic/\(look.id).u16"))
        counts["recipe", default: 0] += 1
    } else if let cube = look.cube {
        // As LookPipeline.loadLUT + applyLUT(protectSkin: true) run it.
        let parsed = try LUTParser.parseCubeFile(at: filmDir.appendingPathComponent(cube))
        let dense = parsed.size < 48 ? parsed.densifiedTetrahedral(to: 64) : parsed
        let t0 = Date()
        let data = TrueColour.lutData(for: dense)
        counts["guard_ms", default: 0] += Int(Date().timeIntervalSince(t0) * 1000)
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = identity
        filter.cubeDimension = Float(dense.size)
        filter.cubeData = data
        filter.colorSpace = srgb
        try bake(filter.outputImage!, to: outDir.appendingPathComponent("film_tc/\(look.id).u16"))
        counts["film", default: 0] += 1
    }
}
print("baked", counts, "in", Int(Date().timeIntervalSince(start)), "s")

// Timing for the tone cube build (the cost of moving a slider to a new value).
let t1 = Date()
for i in 0..<20 {
    _ = TrueColour.toneFilter(contrast: 1 + Float(i) * 0.01 + 0.001, saturation: 1.1, brightness: 0.01)
}
print("tone cube build:", Int(Date().timeIntervalSince(t1) * 1000 / 20), "ms each")

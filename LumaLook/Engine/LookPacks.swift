import Foundation
import CoreImage
import SwiftUI

// MARK: - Pack catalog (research/OPPORTUNITY_MAP.md §4)

/// One look inside a pack: a coded name, a character line (the copy pattern
/// reviewers quote), and the recipe it bakes from.
struct PackLook: Identifiable {
    var id: String { code }
    let code: String            // e.g. "KD2"
    let name: String            // e.g. "KD2 · Golden Gate"
    let character: String       // "thick contrast in the mids, peachy highlights"
    let recipe: LookRecipe
}

/// A "roll of film": 5 looks, one family, an era tag and a hero image.
struct LookPack: Identifiable {
    let id: String              // stable slug, future StoreKit product id suffix
    let name: String
    let familyLine: String      // one-line pack character
    let eraTag: String          // "inspired by 60s chrome"
    let photo: HeroPhoto
    let isFree: Bool
    let price: String           // display only until StoreKit (C5)
    let looks: [PackLook]
}

enum PackCatalog {
    /// Launch catalog per the merchandising playbook: Negative free anchor,
    /// Cine flagship, B&W, Originals.
    static let packs: [LookPack] = [
        LookPack(
            id: "negative-set-01",
            name: "Negative Set 01",
            familyLine: "Everyday colour negative — soft contrast, honest skin, forgiving highlights.",
            eraTag: "Inspired by classic colour negative processes",
            photo: .golden,
            isFree: true,
            price: "FREE",
            looks: [
                PackLook(code: "KD2", name: "KD2 · Morning Gold",
                         character: "Warm mids, honeyed highlights, gentle lift in the shadows.",
                         recipe: LookRecipe(temperature: 5600, tint: 4, contrast: 1.06,
                                            saturation: 1.08, brightness: 0.02, vignette: 0.2, bloom: 0.2)),
                PackLook(code: "KD4", name: "KD4 · Portrait Neutral",
                         character: "Clean neutral base with a whisper of warmth — skin first.",
                         recipe: LookRecipe(temperature: 6200, tint: 2, contrast: 1.03,
                                            saturation: 1.02, brightness: 0.01, vignette: 0.1, bloom: 0)),
                PackLook(code: "KD52", name: "KD52 · Cine Negative",
                         character: "Motion-picture negative feel: dense blacks, restrained colour.",
                         recipe: LookRecipe(temperature: 6100, tint: -2, contrast: 1.12,
                                            saturation: 0.94, brightness: -0.01, vignette: 0.3, bloom: 0.12)),
                PackLook(code: "FJ4", name: "FJ4 · Meadow Green",
                         character: "Cooler greens, airy highlights — the summer-holiday stock.",
                         recipe: LookRecipe(temperature: 6900, tint: -8, contrast: 1.05,
                                            saturation: 1.12, brightness: 0.02, vignette: 0.15, bloom: 0.15)),
                PackLook(code: "AG20", name: "AG20 · Faded Album",
                         character: "Sun-faded warmth, lifted blacks, quiet saturation.",
                         recipe: LookRecipe(temperature: 5400, tint: 6, contrast: 0.94,
                                            saturation: 0.85, brightness: 0.05, vignette: 0.35, bloom: 0.25)),
            ]
        ),
        LookPack(
            id: "cine-print-set-01",
            name: "Cine Print Set 01",
            familyLine: "The projection-print look: teal shadows, amber skin, blacks that mean it.",
            eraTag: "Inspired by Hollywood release prints",
            photo: .night,
            isFree: false,
            price: "$3.99",
            looks: [
                PackLook(code: "CN83", name: "CN83 · Hollywood Print",
                         character: "The teal-and-amber print stock every blockbuster graded to.",
                         recipe: LookRecipe(temperature: 5200, tint: -10, contrast: 1.18,
                                            saturation: 1.05, brightness: -0.02, vignette: 0.4, bloom: 0.2)),
                PackLook(code: "CN93", name: "CN93 · Premiere Night",
                         character: "Champagne highlights over velvet shadows — the red-carpet grade.",
                         recipe: LookRecipe(temperature: 5000, tint: 2, contrast: 1.14,
                                            saturation: 0.98, brightness: 0, vignette: 0.45, bloom: 0.35)),
                PackLook(code: "CN71", name: "CN71 · Night Street",
                         character: "Sodium-lamp warmth against blue night — city films after dark.",
                         recipe: LookRecipe(temperature: 4600, tint: -6, contrast: 1.2,
                                            saturation: 1.1, brightness: -0.04, vignette: 0.5, bloom: 0.3)),
                PackLook(code: "CN12", name: "CN12 · Bleach Bypass",
                         character: "Silver retained: crushed colour, brutal contrast, war-film grit.",
                         recipe: LookRecipe(temperature: 6300, tint: 0, contrast: 1.32,
                                            saturation: 0.55, brightness: -0.02, vignette: 0.4, bloom: 0.1)),
                PackLook(code: "CN44", name: "CN44 · Anamorphic Dusk",
                         character: "Indigo dusk with ember highlights — widescreen melancholy.",
                         recipe: LookRecipe(temperature: 5100, tint: 10, contrast: 1.1,
                                            saturation: 1.02, brightness: -0.01, vignette: 0.35, bloom: 0.4)),
            ]
        ),
        LookPack(
            id: "bw-set-01",
            name: "B&W Set 01",
            familyLine: "Monochrome with intent — street contrast to gallery softness.",
            eraTag: "Inspired by classic panchromatic stocks",
            photo: .desert,
            isFree: false,
            price: "$2.99",
            looks: [
                PackLook(code: "BW32", name: "BW32 · Street Contrast",
                         character: "Thick blacks, bright pavement — the documentarian's default.",
                         recipe: LookRecipe(temperature: 6500, tint: 0, contrast: 1.28,
                                            saturation: 0, brightness: 0, vignette: 0.4, bloom: 0.1)),
                PackLook(code: "BW4", name: "BW4 · Gallery Soft",
                         character: "Long tonal ramp, delicate highlights — portraits on a wall.",
                         recipe: LookRecipe(temperature: 6500, tint: 0, contrast: 1.08,
                                            saturation: 0, brightness: 0.03, vignette: 0.2, bloom: 0.2)),
                PackLook(code: "BW16", name: "BW16 · Push Process",
                         character: "Pushed-film energy: hot contrast that begs for grain at 40.",
                         recipe: LookRecipe(temperature: 6500, tint: 0, contrast: 1.4,
                                            saturation: 0, brightness: -0.02, vignette: 0.5, bloom: 0.15)),
            ]
        ),
        LookPack(
            id: "originals-01",
            name: "Originals 01",
            familyLine: "LumaLook signatures — moods, not stocks.",
            eraTag: "Original LumaLook grades",
            photo: .neon,
            isFree: false,
            price: "$2.99",
            looks: [
                PackLook(code: "LL1", name: "Neon Nights",
                         character: "Magenta-soaked shadows, electric highlights — the city humming.",
                         recipe: LookRecipe(temperature: 7200, tint: 18, contrast: 1.15,
                                            saturation: 1.25, brightness: -0.02, vignette: 0.4, bloom: 0.45)),
                PackLook(code: "LL2", name: "Night Drive",
                         character: "Blue hour forever: cool mids, headlight blooms.",
                         recipe: LookRecipe(temperature: 8200, tint: -4, contrast: 1.12,
                                            saturation: 0.95, brightness: -0.03, vignette: 0.45, bloom: 0.35)),
                PackLook(code: "LL3", name: "Afrobeats Glow",
                         character: "Sun-drenched saturation with golden skin — festival light.",
                         recipe: LookRecipe(temperature: 5300, tint: 8, contrast: 1.1,
                                            saturation: 1.3, brightness: 0.03, vignette: 0.25, bloom: 0.4)),
            ]
        ),
    ]

    static func pack(id: String) -> LookPack? { packs.first { $0.id == id } }

    static var totalLookCount: Int { packs.reduce(0) { $0 + $1.looks.count } }
}

// MARK: - Cube generation + install

/// Bakes a recipe into a 33-point .cube by pushing an identity lattice
/// through the REAL pipeline — the cube is the pipeline's own output, so
/// pack LUTs match previews exactly (the "preview never lies" guarantee).
enum PackInstaller {
    static let cubeSize = 33

    /// Renders the identity lattice through `applyRecipe` and returns the
    /// .cube file text.
    ///
    /// Only PER-COLOR operations may bake into a LUT: bloom and vignette are
    /// SPATIAL (vignette varies by pixel position — poison in a lattice;
    /// bloom's kernel eats edge texels, zeroing the white point). They are
    /// stripped here and remain live pipeline passes at apply time.
    static func cubeText(for recipe: LookRecipe, title: String) -> String? {
        var recipe = recipe
        recipe.bloom = 0
        recipe.vignette = 0
        let n = cubeSize
        let width = n * n
        let height = n

        // Identity lattice image: pixel(x, y) encodes r = x % n, b = x / n, g = y.
        var pixels = [Float32](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i + 0] = Float32(x % n) / Float32(n - 1)
                pixels[i + 1] = Float32(y) / Float32(n - 1)
                pixels[i + 2] = Float32(x / n) / Float32(n - 1)
                pixels[i + 3] = 1
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let identity = CIImage(bitmapData: data,
                               bytesPerRow: width * 16,
                               size: CGSize(width: width, height: height),
                               format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let graded = LookPipeline.shared.applyRecipe(recipe, to: identity)
            .cropped(to: identity.extent)

        var out = [Float32](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { raw in
            LookPipeline.shared.context.render(
                graded, toBitmap: raw.baseAddress!,
                rowBytes: width * 16,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        var text = """
        TITLE "\(title)"
        # Generated by LumaLook — baked from the app's own grading pipeline.
        LUT_3D_SIZE \(n)
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0

        """
        // .cube order: red fastest, then green, then blue.
        // CIImage(bitmapData:) and render(toBitmap:) both treat the first
        // data row as the TOP row, so lattice row g maps straight through.
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let row = g
                    let i = (row * width + (b * n + r)) * 4
                    let rv = max(0, min(1, out[i + 0]))
                    let gv = max(0, min(1, out[i + 1]))
                    let bv = max(0, min(1, out[i + 2]))
                    text += String(format: "%.6f %.6f %.6f\n", rv, gv, bv)
                }
            }
        }
        return text
    }

    /// Bakes every look in the pack to a .cube and imports it into the LUT
    /// repository. Returns the number installed.
    @MainActor
    static func install(_ pack: LookPack, into repository: LUTRepository) -> Int {
        var installed = 0
        let tmp = FileManager.default.temporaryDirectory
        for look in pack.looks {
            guard let text = cubeText(for: look.recipe, title: look.name) else { continue }
            let url = tmp.appendingPathComponent("\(look.name).cube")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                _ = try repository.importLUT(from: url)
                try? FileManager.default.removeItem(at: url)
                installed += 1
            } catch {
                continue
            }
        }
        return installed
    }
}

// MARK: - Ownership / installed state

/// Which packs are installed (and, post-C5, owned). JSON-persisted.
@MainActor
final class PackStore: ObservableObject {
    @Published private(set) var installedPackIDs: Set<String> = []

    private var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Packs.json")
    }

    init() {
        if let data = try? Data(contentsOf: url),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            installedPackIDs = ids
        }
    }

    func isInstalled(_ pack: LookPack) -> Bool { installedPackIDs.contains(pack.id) }

    func markInstalled(_ pack: LookPack) {
        installedPackIDs.insert(pack.id)
        if let data = try? JSONEncoder().encode(installedPackIDs) {
            try? data.write(to: url)
        }
    }
}

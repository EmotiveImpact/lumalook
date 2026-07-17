import SwiftUI
import Foundation

// MARK: - Look grading recipe for built-in looks

struct LookRecipe: Hashable, Codable {
    var temperature: Float = 6500   // target neutral, 6500 = unchanged
    var tint: Float = 0
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var brightness: Float = 0
    var vignette: Float = 0         // 0...2
    var bloom: Float = 0            // 0...1
    var shadowLift: Float = 0       // gamma-ish adjustment via CIGammaAdjust, 1 = unchanged offset 0
}

struct LookPreset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let category: String
    let systemImage: String
    let colours: [Color]
    var gradeTint: Color? = nil     // colour cast painted over the shared scene thumbnail
    var recipe: LookRecipe = LookRecipe()
    var isPremium: Bool = false
}

/// Lens simulation (medium transformation): optical character applied AFTER
/// the grade — glass, not colour. Each kind is a distinct piece of physical
/// glass the footage appears to have been shot through.
enum LensKind: String, Codable, CaseIterable {
    case none
    case anamorphic
    case vintage
    case diffusion
    case fisheye
    case tiltShift
    case swirl
    case plastic

    var label: String {
        switch self {
        case .none: return "None"
        case .anamorphic: return "Anamorphic"
        case .vintage: return "Vintage Prime"
        case .diffusion: return "Diffusion"
        case .fisheye: return "Fisheye"
        case .tiltShift: return "Tilt-Shift"
        case .swirl: return "Swirl 58"
        case .plastic: return "Toy Cam"
        }
    }

    var icon: String {
        switch self {
        case .none: return "circle.slash"
        case .anamorphic: return "camera.aperture"
        case .vintage: return "camera.on.rectangle"
        case .diffusion: return "sun.haze.fill"
        case .fisheye: return "circle.grid.cross"
        case .tiltShift: return "square.3.layers.3d.middle.filled"
        case .swirl: return "hurricane"
        case .plastic: return "camera.macro.circle"
        }
    }

    var blurb: String {
        switch self {
        case .none: return "Clean digital glass"
        case .anamorphic: return "Blue horizontal flares, cinema scope feel"
        case .vintage: return "Chromatic fringing + heavy corner falloff"
        case .diffusion: return "Pro-mist glow, lifted dreamy highlights"
        case .fisheye: return "Curved ultra-wide barrel distortion"
        case .tiltShift: return "Miniature world, razor focus band"
        case .swirl: return "Soviet-prime swirl, edges spin around the subject"
        case .plastic: return "Toy camera: crushed corners, popped colour"
        }
    }

    /// The cinematic glass is part of the Pro membership; Diffusion and
    /// Fisheye stay free so the Lens tool never feels like a locked door.
    var requiresPro: Bool {
        switch self {
        case .none, .diffusion, .fisheye: return false
        case .anamorphic, .vintage, .tiltShift, .swirl, .plastic: return true
        }
    }
}

// MARK: - Pro color model (Grade Room: curves, wheels, HSL)

/// A tone-curve control point in normalised 0…1 input/output space.
struct CurvePoint: Codable, Equatable {
    var x: Double
    var y: Double
}

/// Per-channel tone curves. An empty channel means identity (no remap).
/// Applied as a single separable CIColorCube: channel(master(v)).
struct CurveSet: Codable, Equatable {
    var master: [CurvePoint] = []
    var red: [CurvePoint] = []
    var green: [CurvePoint] = []
    var blue: [CurvePoint] = []

    var isIdentity: Bool {
        master.isEmpty && red.isEmpty && green.isEmpty && blue.isEmpty
    }
}

/// Lift / Gamma / Gain 3-way colour wheels. Each wheel is an RGB triple;
/// identity = lift 0, gamma 1, gain 1. Separable per channel, so it folds
/// into the same transfer LUT as the curves.
struct ColorWheels: Codable, Equatable {
    var liftR = 0.0, liftG = 0.0, liftB = 0.0
    var gammaR = 1.0, gammaG = 1.0, gammaB = 1.0
    var gainR = 1.0, gainG = 1.0, gainB = 1.0

    var isIdentity: Bool {
        liftR == 0 && liftG == 0 && liftB == 0 &&
        gammaR == 1 && gammaG == 1 && gammaB == 1 &&
        gainR == 1 && gainG == 1 && gainB == 1
    }
}

/// Eight-band HSL secondary (Lightroom-style): per band a hue shift,
/// saturation and luminance offset in −1…1. Identity = all zero. Hue-
/// dependent, so it bakes a small 3-D CIColorCube of its own.
struct HSLBands: Codable, Equatable {
    /// red, orange, yellow, green, aqua, blue, purple, magenta.
    static let names = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    /// Band hue centres in degrees (non-uniform, matching the colour wheel).
    static let centers: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]

    var hue: [Double] = Array(repeating: 0, count: 8)
    var sat: [Double] = Array(repeating: 0, count: 8)
    var lum: [Double] = Array(repeating: 0, count: 8)

    var isIdentity: Bool { (hue + sat + lum).allSatisfy { $0 == 0 } }
}

/// Split toning: tint shadows one hue and highlights another, weighted by
/// luma and a balance pivot. Identity = both saturations 0.
struct SplitTone: Codable, Equatable {
    var shadowHue = 210.0      // degrees; teal by default
    var shadowSat = 0.0        // 0…1
    var highlightHue = 40.0    // orange
    var highlightSat = 0.0
    var balance = 0.0          // −1 (favour shadows) … 1 (favour highlights)

    var isIdentity: Bool { shadowSat == 0 && highlightSat == 0 }
}

/// Blend mode for the creative LUT slot: `Blend(base, LUT(base))` then the
/// slot opacity. Both operands are pure functions of input RGB, so the result
/// still bakes into a cube. Conversion slot stays Normal.
enum LUTBlendMode: String, Codable, CaseIterable {
    case normal, softLight, overlay, screen
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .softLight: return "Soft Light"
        case .overlay: return "Overlay"
        case .screen: return "Screen"
        }
    }
    var ciName: String? {
        switch self {
        case .normal: return nil
        case .softLight: return "CISoftLightBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .screen: return "CIScreenBlendMode"
        }
    }
}

struct LookSettings: Codable, Equatable {
    var intensity: Double = 75
    var exposure: Double = 0
    var contrast: Double = 10
    var highlights: Double = 0
    var shadows: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var grain: Double = 0
    var bloom: Double = 0
    var halation: Double = 0
    var vignette: Double = 0
    var sharpness: Double = 0
    var fade: Double = 0        // lifted blacks, the matte-film look
    /// Lens simulation (LensKind rawValue) + its strength. Spatial like
    /// grain/bloom: stripped from cube bakes, applied after the grade.
    var lensKind: String = LensKind.none.rawValue
    var lensAmount: Double = 75
    /// Pro colour surfaces (Grade Room). nil = identity, so legacy looks and
    /// sessions decode unchanged and cost nothing until the user touches them.
    var curves: CurveSet? = nil
    var wheels: ColorWheels? = nil
    var hsl: HSLBands? = nil
    var splitTone: SplitTone? = nil

    init() {}

    /// Custom decode: every field optional-with-default so saved looks from
    /// any app version decode (synthesized decode would throw keyNotFound).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 75
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 10
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        bloom = try c.decodeIfPresent(Double.self, forKey: .bloom) ?? 0
        halation = try c.decodeIfPresent(Double.self, forKey: .halation) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        fade = try c.decodeIfPresent(Double.self, forKey: .fade) ?? 0
        lensKind = try c.decodeIfPresent(String.self, forKey: .lensKind) ?? LensKind.none.rawValue
        lensAmount = try c.decodeIfPresent(Double.self, forKey: .lensAmount) ?? 75
        curves = try c.decodeIfPresent(CurveSet.self, forKey: .curves)
        wheels = try c.decodeIfPresent(ColorWheels.self, forKey: .wheels)
        hsl = try c.decodeIfPresent(HSLBands.self, forKey: .hsl)
        splitTone = try c.decodeIfPresent(SplitTone.self, forKey: .splitTone)
    }
}

/// A clip-level grade override in the editor (per-clip looks): the timeline
/// keeps a global grade; a clip with a ClipGrade wears its own.
struct ClipGrade: Codable, Equatable {
    var baseLookName: String
    var lutID: UUID?
    var settings: LookSettings
}

struct MockClip: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let duration: String
    let scene: MockScene
}

struct LUTFile: Identifiable, Codable, Hashable {
    var id = UUID()
    var displayName: String
    var originalFileName: String
    var fileName: String            // file name inside the ImportedLUTs folder
    var cubeSize: Int?
    var fileSizeBytes: Int?
    var importedAt: Date
    var isFavourite: Bool
    /// Remembered creative-slot opacity (0…100) + blend for this LUT, so
    /// switching subtle↔strong LUTs doesn't re-blow the level. Optional →
    /// synthesized Codable decodes old indexes unchanged.
    var defaultOpacity: Double? = nil
    var defaultBlend: String? = nil

    /// The #1 user mistake in the LUT ecosystem is applying a Log-input LUT
    /// to normal footage ("everything looks washed out / too harsh").
    /// Detect Log-target LUTs from filename conventions and badge them.
    var isLogTarget: Bool {
        let name = originalFileName.lowercased()
        let markers = ["slog", "s-log", "vlog", "v-log", "clog", "c-log",
                       "dlog", "d-log", "flog", "f-log", "nlog", "n-log",
                       "log2", "log3", "logc", "_log", "-log", " log"]
        return markers.contains { name.contains($0) }
    }
}

struct ProjectItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let date: String
    let duration: String
    let scene: MockScene
}

enum LumaRoute: Hashable {
    case selectClip
    case applyLook
    case beforeAfter
    case lutManager
    case camera
    case editor
    case exportComplete
    case filterStore
    case filterPack
    case savedLooks
    case customLook
    case projectLibrary
    case cropFormat
    case audio
    case settings
}

enum LumaTab: String, CaseIterable {
    case home = "Home"
    case store = "Store"
    case projects = "Projects"
    case looks = "Looks"
    case profile = "Profile"

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .store: return "bag"
        case .projects: return "folder"
        case .looks: return "cube.transparent"
        case .profile: return "person"
        }
    }
}

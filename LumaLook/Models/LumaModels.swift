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

    var label: String {
        switch self {
        case .none: return "None"
        case .anamorphic: return "Anamorphic"
        case .vintage: return "Vintage Prime"
        case .diffusion: return "Diffusion"
        case .fisheye: return "Fisheye"
        case .tiltShift: return "Tilt-Shift"
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

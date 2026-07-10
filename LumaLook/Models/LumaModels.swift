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

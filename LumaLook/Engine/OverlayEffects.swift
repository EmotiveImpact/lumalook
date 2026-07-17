import Foundation

/// Compositing blend mode for a media overlay: `Blend(overlay, base)` then
/// source-over. Each maps to a named Core Image blend filter (nil = normal
/// source-over).
enum OverlayBlendMode: String, Codable, CaseIterable {
    case normal, screen, multiply, overlay, softLight, lighten, add

    var ciFilterName: String? {
        switch self {
        case .normal: return nil
        case .screen: return "CIScreenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .add: return "CIAdditionCompositing"
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .screen: return "Screen"
        case .multiply: return "Multiply"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .lighten: return "Lighten"
        case .add: return "Add"
        }
    }
}

/// Green-screen keying: pixels whose hue is within `tolerance` of `colorHex`
/// go transparent, with a `softness` feather at the edge.
struct ChromaKeySettings: Codable, Equatable {
    var colorHex = "#00FF00"
    var tolerance = 0.35     // 0…1 hue+chroma distance
    var softness = 0.10      // edge feather
}

/// Alpha mask shaping the overlay: rect / rounded-rect / ellipse / linear
/// gradient, in the overlay's local extent.
struct OverlayMaskSettings: Codable, Equatable {
    var shape = "roundedRect"   // rect | roundedRect | ellipse | linear
    var feather = 0.05
    var cornerRadius = 0.12
    var invert = false
}

/// Per-overlay tone tweak layered on top of the shared grade.
struct OverlayAdjustments: Codable, Equatable {
    var exposure = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var warmth = 0.0
    var isIdentity: Bool { self == OverlayAdjustments() }
}

/// Solid ring drawn around the overlay (frame / border).
struct OverlayBorderSettings: Codable, Equatable {
    var widthFraction = 0.02
    var colorHex = "#FFFFFF"
    var cornerRadiusFraction = 0.0
}

/// The full non-placement effect stack for one overlay. Optional sub-structs =
/// off. A per-field decode (LookSettings-style) means adding fields never
/// breaks old projects.
struct OverlayEffects: Codable, Equatable {
    var blendMode: OverlayBlendMode = .normal
    var chroma: ChromaKeySettings? = nil
    var mask: OverlayMaskSettings? = nil
    var adjust: OverlayAdjustments? = nil
    var border: OverlayBorderSettings? = nil

    var isIdentity: Bool { self == OverlayEffects() }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blendMode = try c.decodeIfPresent(OverlayBlendMode.self, forKey: .blendMode) ?? .normal
        chroma = try c.decodeIfPresent(ChromaKeySettings.self, forKey: .chroma)
        mask = try c.decodeIfPresent(OverlayMaskSettings.self, forKey: .mask)
        adjust = try c.decodeIfPresent(OverlayAdjustments.self, forKey: .adjust)
        border = try c.decodeIfPresent(OverlayBorderSettings.self, forKey: .border)
    }
}

/// Live per-overlay effects the compositor reads each frame without a rebuild
/// — the `OverlayLayout` trick, for values that don't interpolate.
final class OverlayEffectsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: OverlayEffects] = [:]

    func replaceAll(_ new: [UUID: OverlayEffects]) {
        lock.lock(); entries = new; lock.unlock()
    }

    func effects(for id: UUID) -> OverlayEffects? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }
}

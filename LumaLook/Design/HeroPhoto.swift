import SwiftUI
import CoreImage

/// Bundled CC0 photography (sources in Resources/HeroPhotos/CREDITS.md)
/// used for hero surfaces and empty states until the user's own media
/// takes over. Real imagery is what separates the app from a mockup.
enum HeroPhoto: String {
    case golden = "hero_golden"
    case coast = "hero_coast"
    case desert = "hero_desert"
    case neon = "hero_neon"
    case night = "hero_night"

    private static var cache: [String: UIImage] = [:]

    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "jpg") }

    var uiImage: UIImage? {
        if let cached = Self.cache[rawValue] { return cached }
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        Self.cache[rawValue] = image
        return image
    }

    var ciImage: CIImage? { url.flatMap { CIImage(contentsOf: $0) } }

    static func forScene(_ scene: MockScene) -> HeroPhoto {
        switch scene {
        case .sunsetRoad, .goldenField, .forest: return .golden
        case .cityNight, .rainyCity: return .night
        case .neonStreet, .duskPurple: return .neon
        case .coast: return .coast
        case .desert: return .desert
        }
    }
}

/// Full-bleed photo that fills whatever frame it is given.
struct HeroImage: View {
    let photo: HeroPhoto
    var radius: CGFloat = 0

    var body: some View {
        Color.clear
            .overlay {
                if let ui = photo.uiImage {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                } else {
                    LumaTheme.surfaceStrong
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            // The scaledToFill image overflows the frame it is given. clipShape
            // hides the overflow but still hit-tests it, so a hero inside (or
            // beside) a Button would steal taps from its neighbours. Match the
            // touch region to the visible shape.
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

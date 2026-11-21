import SwiftUI
import CoreImage

/// Bundled sample photography for hero surfaces, look previews and empty
/// states until the user's own media takes over. Every sample has a person in
/// it, because skin is the proof that a grade works.
///
/// All from Unsplash under the Unsplash Licence (commercial use allowed, no
/// permission needed). Photographers are credited in Settings, Photo credits,
/// and in Resources/HeroPhotos/CREDITS.md.
enum HeroPhoto: String, CaseIterable {
    case golden = "hero_golden"
    case neon = "hero_neon"
    case drive = "hero_drive"
    case rain = "hero_rain"
    case party = "hero_party"
    case skate = "hero_skate"
    case gig = "hero_gig"
    case campaign = "hero_campaign"
    case bridge = "hero_bridge"

    /// Photographer, for the credits page.
    var photographer: String {
        switch self {
        case .golden: return "Diana Simumpande"
        case .neon: return "Italo Guimas"
        case .drive: return "Bobby Thapa"
        case .rain: return "Matt Antonioli"
        case .party: return "Jared Pizarro"
        case .skate: return "Ash Edmonds"
        case .gig: return "Anthony Delanoix"
        case .campaign: return "Lola Azizada"
        case .bridge: return "Chuko Cribb"
        }
    }

    /// Where the photo lives on Unsplash.
    var sourceURL: URL? {
        let slug: String
        switch self {
        case .golden: slug = "woman-wearing-beige-off-shoulder-top-xZgkFQ4Hijc"
        case .neon: slug = "young-woman-illuminated-by-red-and-green-lights-SVuwruJJiZg"
        case .drive: slug = "person-in-car-under-red-light-SN72o2xIO5w"
        case .rain: slug = "red-bus-parking-beside-walkway-MJ611qxf5Bk"
        case .party: slug = "people-dancing-and-enjoying-a-lively-party-atmosphere-b7IkZFcCRDI"
        case .skate: slug = "woman-in-white-shirt-and-black-pants-jumping-on-black-round-trampoline-during-daytime-oqyoL_G6ZHA"
        case .gig: slug = "person-performing-heart-hand-gesture-hzgs56Ze49s"
        case .campaign: slug = "a-woman-with-an-afro-standing-in-front-of-a-red-background-HyoTmwZQwWU"
        case .bridge: slug = "a-man-in-an-orange-jacket-standing-on-a-bridge-bYTmw7nc7K4"
        }
        return URL(string: "https://unsplash.com/photos/\(slug)")
    }

    /// Where the subject sits in the frame (unit point), so tight crops keep
    /// the face instead of the background.
    var focus: UnitPoint {
        switch self {
        case .golden: return UnitPoint(x: 0.55, y: 0.35)
        case .neon: return UnitPoint(x: 0.5, y: 0.4)
        case .drive: return UnitPoint(x: 0.7, y: 0.5)
        case .rain: return UnitPoint(x: 0.55, y: 0.5)
        case .party: return UnitPoint(x: 0.45, y: 0.6)
        case .skate: return UnitPoint(x: 0.5, y: 0.35)
        case .gig: return UnitPoint(x: 0.5, y: 0.45)
        case .campaign: return UnitPoint(x: 0.5, y: 0.32)
        case .bridge: return UnitPoint(x: 0.5, y: 0.35)
        }
    }

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
        case .sunsetRoad, .goldenField: return .golden
        case .forest: return .skate
        case .cityNight: return .drive
        case .rainyCity: return .rain
        case .neonStreet: return .neon
        case .duskPurple: return .gig
        case .coast: return .bridge
        case .desert: return .party
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
                    GeometryReader { geo in
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height,
                                   alignment: Alignment(horizontal: photo.focus.x < 0.4 ? .leading : (photo.focus.x > 0.6 ? .trailing : .center),
                                                        vertical: photo.focus.y < 0.4 ? .top : (photo.focus.y > 0.6 ? .bottom : .center)))
                    }
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

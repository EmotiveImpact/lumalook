import SwiftUI

enum MockData {
    // The 10 built-in P0 looks. Each carries a real Core Image recipe and a
    // grade tint so its thumbnail shows the shared scene under that grade.
    //
    // `isPremium` marks every built-in whose full version a PAID pack sells
    // (see LookLibraryStore.builtInReplacements): free to preview, and the
    // pack or Pro unlocks export. Otherwise Originals 01 would be selling
    // Neon Nights, Night Drive and Afrobeats Glow to people who already have
    // them. Looks whose replacement lives in a free pack stay free.
    static let looks: [LookPreset] = [
        .init(name: "KD4 · Clean Neutral", category: "Negative", systemImage: "circle.lefthalf.filled",
              colours: [.gray, .white.opacity(0.7)], gradeTint: Color(white: 0.85),
              recipe: LookRecipe(contrast: 1.02, saturation: 0.98)),
        .init(name: "CN83 · Teal & Orange", category: "Cine", systemImage: "sparkles",
              colours: [LumaTheme.cyan, LumaTheme.orange], gradeTint: Color(red: 0.1, green: 0.75, blue: 0.75),
              recipe: LookRecipe(temperature: 5850, tint: -10, contrast: 1.1, saturation: 1.18, vignette: 0.4),
              isPremium: true),
        .init(name: "Neon Nights", category: "Original", systemImage: "cube.transparent",
              colours: [LumaTheme.accent, .pink, LumaTheme.orange], gradeTint: Color(red: 0.75, green: 0.3, blue: 1.0),
              recipe: LookRecipe(temperature: 7000, tint: 11, contrast: 1.18, saturation: 1.32, vignette: 0.7, bloom: 0.35),
              isPremium: true),
        .init(name: "Night Drive", category: "Original", systemImage: "moon.stars",
              colours: [.blue, LumaTheme.accent], gradeTint: Color(red: 0.2, green: 0.3, blue: 0.9),
              recipe: LookRecipe(temperature: 7600, tint: 6, contrast: 1.2, saturation: 0.92, brightness: -0.04, vignette: 0.9),
              isPremium: true),
        .init(name: "KD52 · Cine Negative", category: "Negative", systemImage: "camera.filters",
              colours: [.brown, .orange], gradeTint: Color(red: 0.85, green: 0.6, blue: 0.35),
              recipe: LookRecipe(temperature: 5900, tint: 4, contrast: 1.08, saturation: 1.06, vignette: 0.25)),
        .init(name: "KD2 · Golden Hour", category: "Negative", systemImage: "sun.max",
              colours: [.yellow, .orange], gradeTint: Color(red: 1.0, green: 0.75, blue: 0.3),
              recipe: LookRecipe(temperature: 5300, tint: 4, contrast: 1.06, saturation: 1.1, brightness: 0.03, bloom: 0.3)),
        .init(name: "AG60 · London Rain", category: "Slide", systemImage: "cloud.rain",
              colours: [.blue, .gray], gradeTint: Color(red: 0.4, green: 0.55, blue: 0.7),
              recipe: LookRecipe(temperature: 7350, tint: -4, contrast: 1.05, saturation: 0.88, brightness: -0.02, vignette: 0.5)),
        .init(name: "Afrobeats Glow", category: "Original", systemImage: "music.note",
              colours: [.orange, .pink], gradeTint: Color(red: 1.0, green: 0.45, blue: 0.4),
              recipe: LookRecipe(temperature: 5450, tint: 8, contrast: 1.12, saturation: 1.1, bloom: 0.45),
              isPremium: true),
        .init(name: "BW32 · Documentary Grit", category: "B&W", systemImage: "doc.viewfinder",
              colours: [.gray, .black], gradeTint: Color(white: 0.45),
              recipe: LookRecipe(temperature: 6700, contrast: 1.22, saturation: 0, vignette: 0.6),
              isPremium: true),
        .init(name: "CN93 · Luxury Campaign", category: "Cine", systemImage: "crown",
              colours: [.black, LumaTheme.orange], gradeTint: Color(red: 0.9, green: 0.7, blue: 0.45),
              recipe: LookRecipe(temperature: 6100, tint: 2, contrast: 1.16, saturation: 1.04, brightness: 0.02, vignette: 0.55, bloom: 0.2),
              isPremium: true)
    ]

    /// What a Skin first preset stands on: no built-in look at all. A preset
    /// is a whole grade, picked like a look, so it takes the place of the
    /// look before it instead of sitting on top of it. Nothing lists this
    /// one (it is not in `looks`), it is never sold, and its recipe changes
    /// nothing, so a grade saved under its name draws from its settings alone.
    static let plainLook = LookPreset(name: "Skin first", category: "Skin",
                                      systemImage: "person.crop.circle",
                                      colours: [Color(hex: 0xC98A5E), Color(hex: 0xB87A4E)])

    /// A built-in look by the name a saved grade carries.
    static func look(named name: String) -> LookPreset? {
        name == plainLook.name ? plainLook : looks.first { $0.name == name }
    }

    /// The built-in look a saved grade stands on. A grade wearing a Skin
    /// first preset stands on none, whatever look it was saved over: the
    /// picture leaves that look out (`LookPipeline.apply`), and so does the
    /// grade once it is opened, or reshaping the preset's curve by hand
    /// would bring the old look back from underneath.
    static func base(named name: String, under settings: LookSettings) -> LookPreset? {
        SkinFirstPreset.worn(by: settings) != nil ? plainLook : look(named: name)
    }

    /// The look a fresh install opens with: the first free one people would
    /// actually want on their footage. Never premium, so the very first export
    /// a new user makes cannot hit a paywall they did not choose.
    static var defaultLook: LookPreset {
        looks.first { $0.name == "KD2 · Golden Hour" && !$0.isPremium }
            ?? looks.first { !$0.isPremium }
            ?? looks[0]
    }

    /// The free built-in look closest to `look`, for the "Export with a free
    /// look" way out of the premium lock. Nearest by recipe, with each axis
    /// scaled to roughly one visible step (1000 K of warmth, 0.1 of contrast,
    /// 0.2 of saturation and so on), so a cool, moody look lands on a cool,
    /// moody free one: Night Drive gives AG60 London Rain, Afrobeats Glow
    /// gives KD2 Golden Hour, the Cine prints give KD52 Cine Negative.
    /// A look that is already free comes back unchanged.
    static func freeAlternative(to look: LookPreset) -> LookPreset {
        guard look.isPremium else { return look }
        let a = look.recipe
        func distance(_ b: LookRecipe) -> Float {
            let steps: [Float] = [
                (a.temperature - b.temperature) / 1000,
                (a.tint - b.tint) / 20,
                (a.contrast - b.contrast) / 0.1,
                (a.saturation - b.saturation) / 0.2,
                (a.brightness - b.brightness) / 0.05,
                (a.vignette - b.vignette) / 0.5,
                (a.bloom - b.bloom) / 0.3,
                (a.shadowLift - b.shadowLift) / 0.1,
            ]
            return steps.reduce(0) { $0 + $1 * $1 }
        }
        return looks.filter { !$0.isPremium }
            .min { distance($0.recipe) < distance($1.recipe) } ?? defaultLook
    }

    // RNI-style process taxonomy (research §4.2): grouping by process reads
    // as expertise; "Trending" reads as commodity.
    static let categories = ["All", "Skin", "Negative", "Cine", "Slide", "B&W", "Original"]
    /// Nominative-use disclaimer shown in the Store and look details.
    static let namingDisclaimer = "Look names and codes are original Lumalook creations inspired by classic photographic processes. No affiliation with or endorsement by any film manufacturer."

    static let clips: [MockClip] = [
        .init(title: "Sunset Ride", duration: "00:16", scene: .sunsetRoad),
        .init(title: "Lake Trail", duration: "00:11", scene: .coast),
        .init(title: "Golden Peaks", duration: "00:24", scene: .goldenField),
        .init(title: "Evening Walk", duration: "00:21", scene: .duskPurple),
        .init(title: "Boulevard", duration: "00:17", scene: .desert),
        .init(title: "Night Rider", duration: "00:21", scene: .cityNight),
        .init(title: "Highlands", duration: "00:21", scene: .forest),
        .init(title: "Coast Drive", duration: "00:13", scene: .rainyCity),
        .init(title: "Shoreline", duration: "00:24", scene: .neonStreet),
        .init(title: "Pyramids", duration: "02:28", scene: .sunsetRoad)
    ]

    static let projects: [ProjectItem] = [
        .init(title: "Travel Edit", date: "May 14", duration: "00:18", scene: .coast),
        .init(title: "City Nights", date: "May 10", duration: "00:39", scene: .cityNight),
        .init(title: "Brand Ad", date: "May 6", duration: "00:15", scene: .neonStreet),
        .init(title: "Summer Vibes", date: "May 1", duration: "00:22", scene: .goldenField),
        .init(title: "Mountains", date: "Apr 30", duration: "00:31", scene: .forest),
        .init(title: "Dreamscape", date: "Apr 25", duration: "00:16", scene: .duskPurple)
    ]
}

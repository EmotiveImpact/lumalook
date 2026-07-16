import SwiftUI

enum MockData {
    // The 10 built-in P0 looks. Each carries a real Core Image recipe and a
    // grade tint so its thumbnail shows the shared scene under that grade.
    static let looks: [LookPreset] = [
        .init(name: "KD4 · Clean Neutral", category: "Negative", systemImage: "circle.lefthalf.filled",
              colours: [.gray, .white.opacity(0.7)], gradeTint: Color(white: 0.85),
              recipe: LookRecipe(contrast: 1.02, saturation: 0.98)),
        .init(name: "CN83 · Teal & Orange", category: "Cine", systemImage: "sparkles",
              colours: [LumaTheme.cyan, LumaTheme.orange], gradeTint: Color(red: 0.1, green: 0.75, blue: 0.75),
              recipe: LookRecipe(temperature: 5600, tint: -14, contrast: 1.14, saturation: 1.18, vignette: 0.4)),
        .init(name: "Neon Nights", category: "Original", systemImage: "cube.transparent",
              colours: [LumaTheme.accent, .pink, LumaTheme.orange], gradeTint: Color(red: 0.75, green: 0.3, blue: 1.0),
              recipe: LookRecipe(temperature: 7600, tint: 22, contrast: 1.18, saturation: 1.32, vignette: 0.7, bloom: 0.35)),
        .init(name: "Night Drive", category: "Original", systemImage: "moon.stars",
              colours: [.blue, LumaTheme.accent], gradeTint: Color(red: 0.2, green: 0.3, blue: 0.9),
              recipe: LookRecipe(temperature: 8200, tint: 8, contrast: 1.2, saturation: 0.92, brightness: -0.04, vignette: 0.9)),
        .init(name: "KD52 · Cine Negative", category: "Negative", systemImage: "camera.filters",
              colours: [.brown, .orange], gradeTint: Color(red: 0.85, green: 0.6, blue: 0.35),
              recipe: LookRecipe(temperature: 5900, tint: 4, contrast: 1.08, saturation: 1.06, vignette: 0.25)),
        .init(name: "KD2 · Golden Hour", category: "Negative", systemImage: "sun.max",
              colours: [.yellow, .orange], gradeTint: Color(red: 1.0, green: 0.75, blue: 0.3),
              recipe: LookRecipe(temperature: 4900, tint: 6, contrast: 1.06, saturation: 1.12, brightness: 0.03, bloom: 0.3)),
        .init(name: "AG60 · London Rain", category: "Slide", systemImage: "cloud.rain",
              colours: [.blue, .gray], gradeTint: Color(red: 0.4, green: 0.55, blue: 0.7),
              recipe: LookRecipe(temperature: 7800, tint: -6, contrast: 1.1, saturation: 0.78, brightness: -0.02, vignette: 0.5)),
        .init(name: "Afrobeats Glow", category: "Original", systemImage: "music.note",
              colours: [.orange, .pink], gradeTint: Color(red: 1.0, green: 0.45, blue: 0.4),
              recipe: LookRecipe(temperature: 5100, tint: 12, contrast: 1.12, saturation: 1.28, bloom: 0.45)),
        .init(name: "BW32 · Documentary Grit", category: "B&W", systemImage: "doc.viewfinder",
              colours: [.gray, .black], gradeTint: Color(white: 0.45),
              recipe: LookRecipe(temperature: 6700, contrast: 1.22, saturation: 0.7, vignette: 0.6)),
        .init(name: "CN93 · Luxury Campaign", category: "Cine", systemImage: "crown",
              colours: [.black, LumaTheme.orange], gradeTint: Color(red: 0.9, green: 0.7, blue: 0.45),
              recipe: LookRecipe(temperature: 6100, tint: 2, contrast: 1.16, saturation: 1.04, brightness: 0.02, vignette: 0.55, bloom: 0.2),
              isPremium: true)
    ]

    // RNI-style process taxonomy (research §4.2): grouping by process reads
    // as expertise; "Trending" reads as commodity.
    static let categories = ["All", "Skin", "Negative", "Cine", "Slide", "B&W", "Original"]
    /// Nominative-use disclaimer shown in the Store and look details.
    static let namingDisclaimer = "Look names and codes are original LumaLook creations inspired by classic photographic processes. No affiliation with or endorsement by any film manufacturer."

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

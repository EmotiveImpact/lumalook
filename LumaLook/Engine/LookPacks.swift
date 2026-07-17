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
    var recipe: LookRecipe = LookRecipe()
    /// Measured film emulation: a bundled .cube (Resources/FilmLUTs) instead
    /// of a baked recipe. CC BY-SA data — credits in FilmLUTs/CREDITS.md.
    var cubeFile: String? = nil
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
    /// Included with the Pro membership (not sold à la carte): the film
    /// archives. Free packs stay free; recipe packs stay purchasable.
    var isProIncluded: Bool = false
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
            id: "film-stocks-01",
            name: "Film Stocks 01",
            familyLine: "Measured emulations of real photographic film — negative, slide, mono, instant and cinema print.",
            eraTag: "From community-measured film data",
            photo: .coast,
            isFree: true,
            price: "FREE",
            looks: [
                PackLook(code: "PT160", name: "PT160 · Portrait Neg",
                         character: "The wedding stock: soft contrast, unbeatable skin.",
                         cubeFile: "FS_PT160.cube"),
                PackLook(code: "EK100", name: "EK100 · Vivid Neg",
                         character: "Finest-grain colour negative — punchy but honest.",
                         cubeFile: "FS_EK100.cube"),
                PackLook(code: "SP200", name: "SP200 · Drugstore Neg",
                         character: "The 90s point-and-shoot look, greens forward.",
                         cubeFile: "FS_SP200.cube"),
                PackLook(code: "AV200", name: "AV200 · Street Neg",
                         character: "Sun-baked European street colour.",
                         cubeFile: "FS_AV200.cube"),
                PackLook(code: "KC64", name: "KC64 · Chrome 64",
                         character: "The magazine slide of the 60s — dense reds, deep shadow.",
                         cubeFile: "FS_KC64.cube"),
                PackLook(code: "VV50", name: "VV50 · Vivid Slide",
                         character: "Landscape legend: saturated greens, electric skies.",
                         cubeFile: "FS_VV50.cube"),
                PackLook(code: "PR100", name: "PR100 · Clean Slide",
                         character: "Neutral professional chrome, faithful colour.",
                         cubeFile: "FS_PR100.cube"),
                PackLook(code: "XP200", name: "XP200 · Cross Process",
                         character: "Slide through negative chemistry — teal shadows, wild shifts.",
                         cubeFile: "FS_XP200.cube"),
                PackLook(code: "TX400", name: "TX400 · Reportage Mono",
                         character: "The photojournalist's black and white.",
                         cubeFile: "FS_TX400.cube"),
                PackLook(code: "HP400", name: "HP400 · Classic Mono",
                         character: "British documentary grain and glow.",
                         cubeFile: "FS_HP400.cube"),
                PackLook(code: "IN669", name: "IN669 · Instant Warm",
                         character: "Peel-apart instant film — creamy, nostalgic.",
                         cubeFile: "FS_IN669.cube"),
                PackLook(code: "RS100", name: "RS100 · Redscale",
                         character: "Film shot through its own base: fire-orange everything.",
                         cubeFile: "FS_RS100.cube"),
                PackLook(code: "CP2383", name: "CP2383 · Cinema Print",
                         character: "The Hollywood release-print stock — teal shadows, warm faces.",
                         cubeFile: "FS_CP2383.cube"),
                PackLook(code: "CP3513", name: "CP3513 · Cinema Print II",
                         character: "The alternative print house: gentler, greener.",
                         cubeFile: "FS_CP3513.cube"),
            ]
        ),
        LookPack(
            id: "film-neg-archive",
            name: "Negative Archive",
            familyLine: "Every colour negative in the measured collection — portrait pro stocks to drugstore rolls.",
            eraTag: "Measured colour negative stocks",
            photo: .golden,
            isFree: false,
            price: "PRO",
            isProIncluded: true,
            looks: [
                PackLook(code: "FN160", name: "FN160 · Pastel Neg 160",
                         character: "Soft pastel palette, forgiving highlight roll-off.",
                         cubeFile: "FS_FN160.cube"),
                PackLook(code: "FN400", name: "FN400 · Airy Neg 400",
                         character: "The airy wedding look — minty shadows, glowing skin.",
                         cubeFile: "FS_FN400.cube"),
                PackLook(code: "FN800", name: "FN800 · Evening Neg 800",
                         character: "Tungsten-friendly speed with velvet grain.",
                         cubeFile: "FS_FN800.cube"),
                PackLook(code: "PT160N", name: "PT160N · Portrait Neg II",
                         character: "The modern portrait stock, softest contrast.",
                         cubeFile: "FS_PT160N.cube"),
                PackLook(code: "PT400", name: "PT400 · Portrait Neg 400",
                         character: "The do-everything professional negative.",
                         cubeFile: "FS_PT400.cube"),
                PackLook(code: "PT800", name: "PT800 · Portrait Neg 800",
                         character: "Low-light portraits with honeyed warmth.",
                         cubeFile: "FS_PT800.cube"),
                PackLook(code: "PT800H", name: "PT800H · Portrait Neg 800 HC",
                         character: "The high-contrast cut of the night stock.",
                         cubeFile: "FS_PT800H.cube"),
                PackLook(code: "SP100", name: "SP100 · Drugstore Neg 100",
                         character: "Sunny-day consumer colour, clean and cheap.",
                         cubeFile: "FS_SP100.cube"),
                PackLook(code: "SP400", name: "SP400 · Drugstore Neg 400",
                         character: "The family-album stock of the late 90s.",
                         cubeFile: "FS_SP400.cube"),
                PackLook(code: "SP800", name: "SP800 · Drugstore Neg 800",
                         character: "Party-flash colour with chunky grain.",
                         cubeFile: "FS_SP800.cube"),
                PackLook(code: "SP1600", name: "SP1600 · Drugstore Neg 1600",
                         character: "Club-night speed — grain like gravel, mood for days.",
                         cubeFile: "FS_SP1600.cube"),
                PackLook(code: "PT160V", name: "PT160V · Portrait Neg VC",
                         character: "The vivid-colour cut of the portrait classic.",
                         cubeFile: "FS_PT160V.cube"),
                PackLook(code: "PT400N", name: "PT400N · Portrait Neg NC",
                         character: "Neutral-colour 400 — the retoucher's favourite.",
                         cubeFile: "FS_PT400N.cube"),
                PackLook(code: "PT400U", name: "PT400U · Portrait Neg UC",
                         character: "Ultra-colour 400: punchy but still kind to skin.",
                         cubeFile: "FS_PT400U.cube"),
                PackLook(code: "PT400V", name: "PT400V · Portrait Neg VC 400",
                         character: "Vivid-colour 400 for flat grey days.",
                         cubeFile: "FS_PT400V.cube"),
                PackLook(code: "CP2393", name: "CP2393 · Cinema Print III",
                         character: "The richer, older Hollywood print stock.",
                         cubeFile: "FS_CP2393.cube"),
                PackLook(code: "CP3510", name: "CP3510 · Cinema Print IV",
                         character: "The vintage print house look.",
                         cubeFile: "FS_CP3510.cube"),
            ]
        ),
        LookPack(
            id: "film-slide-archive",
            name: "Slide Archive",
            familyLine: "The chrome cabinet: professional and consumer slide films, plus the instant slide oddity.",
            eraTag: "Measured slide films",
            photo: .desert,
            isFree: false,
            price: "PRO",
            isProIncluded: true,
            looks: [
                PackLook(code: "AP100", name: "AP100 · Euro Slide 100",
                         character: "Middle-European chrome — cool, precise, quiet.",
                         cubeFile: "FS_AP100.cube"),
                PackLook(code: "AS100", name: "AS100 · Soft Slide 100",
                         character: "The fashion slide: softest contrast in the chrome family.",
                         cubeFile: "FS_AS100.cube"),
                PackLook(code: "PR400", name: "PR400 · Clean Slide 400",
                         character: "Professional chrome with usable speed.",
                         cubeFile: "FS_PR400.cube"),
                PackLook(code: "PR400X", name: "PR400X · Clean Slide 400X",
                         character: "The last fast slide — saturated, modern.",
                         cubeFile: "FS_PR400X.cube"),
                PackLook(code: "SN100", name: "SN100 · Consumer Slide 100",
                         character: "Everyday chrome, friendlier than the pro stocks.",
                         cubeFile: "FS_SN100.cube"),
                PackLook(code: "VV100", name: "VV100 · Vivid Slide 100",
                         character: "The faster vivid landscape chrome.",
                         cubeFile: "FS_VV100.cube"),
                PackLook(code: "SX200", name: "SX200 · Cross Neg 200",
                         character: "Consumer negative through slide chemistry.",
                         cubeFile: "FS_SX200.cube"),
                PackLook(code: "EC100G", name: "EC100G · Warm Chrome 100",
                         character: "The warm-balanced professional chrome.",
                         cubeFile: "FS_EC100G.cube"),
                PackLook(code: "EC100V", name: "EC100V · Vivid Chrome 100",
                         character: "VS = vivid saturation — the punchy chrome.",
                         cubeFile: "FS_EC100V.cube"),
                PackLook(code: "EL200", name: "EL200 · Consumer Chrome 200",
                         character: "Amateur slide with honest colour.",
                         cubeFile: "FS_EL200.cube"),
                PackLook(code: "EL400", name: "EL400 · Consumer Chrome 400",
                         character: "Fast consumer chrome, warm bias.",
                         cubeFile: "FS_EL400.cube"),
                PackLook(code: "EL100X", name: "EL100X · Extra Chrome 100",
                         character: "The saturated cut of consumer chrome.",
                         cubeFile: "FS_EL100X.cube"),
                PackLook(code: "KC25", name: "KC25 · Chrome 25",
                         character: "The sharpest, slowest legend — museum colour.",
                         cubeFile: "FS_KC25.cube"),
                PackLook(code: "KC200", name: "KC200 · Chrome 200",
                         character: "The fast cut of the legend, grain and all.",
                         cubeFile: "FS_KC200.cube"),
                PackLook(code: "PC35", name: "PC35 · Instant Slide",
                         character: "35mm instant slide — streaky, lo-fi, unrepeatable.",
                         cubeFile: "FS_PC35.cube"),
            ]
        ),
        LookPack(
            id: "film-mono-archive",
            name: "Mono Archive",
            familyLine: "Twenty-two black-and-white emulsions — press, tabular, infrared, ortho and instant monos.",
            eraTag: "Measured monochrome stocks",
            photo: .night,
            isFree: false,
            price: "PRO",
            isProIncluded: true,
            looks: [
                PackLook(code: "APX100", name: "APX100 · Fine Mono 100",
                         character: "European fine-grain classic.",
                         cubeFile: "FS_APX100.cube"),
                PackLook(code: "APX25", name: "APX25 · Glass Mono 25",
                         character: "Slow as syrup, sharp as glass.",
                         cubeFile: "FS_APX25.cube"),
                PackLook(code: "NP1600", name: "NP1600 · Night Mono 1600",
                         character: "Tokyo-street speed, coal-black shadows.",
                         cubeFile: "FS_NP1600.cube"),
                PackLook(code: "NP100", name: "NP100 · Smooth Mono 100",
                         character: "The smoothest 100-speed mono ever coated.",
                         cubeFile: "FS_NP100.cube"),
                PackLook(code: "DL100", name: "DL100 · Modern Mono 100",
                         character: "T-grain precision from the British coater.",
                         cubeFile: "FS_DL100.cube"),
                PackLook(code: "DL400", name: "DL400 · Modern Mono 400",
                         character: "The modern all-rounder.",
                         cubeFile: "FS_DL400.cube"),
                PackLook(code: "DL3200", name: "DL3200 · Night Mono 3200",
                         character: "Available-darkness film.",
                         cubeFile: "FS_DL3200.cube"),
                PackLook(code: "FP125", name: "FP125 · Classic Mono 125",
                         character: "Box-speed classic since 1968.",
                         cubeFile: "FS_FP125.cube"),
                PackLook(code: "HPS800", name: "HPS800 · Press Mono 800",
                         character: "The old press stock, pushed hard.",
                         cubeFile: "FS_HPS800.cube"),
                PackLook(code: "PF50", name: "PF50 · Glass Mono 50",
                         character: "Slow, silvery, impossibly smooth.",
                         cubeFile: "FS_PF50.cube"),
                PackLook(code: "XP2", name: "XP2 · Lab Mono 400",
                         character: "Mono through colour chemistry — creamy latitude.",
                         cubeFile: "FS_XP2.cube"),
                PackLook(code: "BW400", name: "BW400 · Lab Mono CN",
                         character: "The minilab-friendly chromogenic mono.",
                         cubeFile: "FS_BW400.cube"),
                PackLook(code: "IR840", name: "IR840 · Infra Mono",
                         character: "Infrared: white foliage, black skies, dream logic.",
                         cubeFile: "FS_IR840.cube"),
                PackLook(code: "TM100", name: "TM100 · Tabular Mono 100",
                         character: "Clinical T-grain sharpness.",
                         cubeFile: "FS_TM100.cube"),
                PackLook(code: "TM400", name: "TM400 · Tabular Mono 400",
                         character: "The technical 400.",
                         cubeFile: "FS_TM400.cube"),
                PackLook(code: "TM3200", name: "TM3200 · Tabular Mono 3200",
                         character: "Speed by chemistry, grain by choice.",
                         cubeFile: "FS_TM3200.cube"),
                PackLook(code: "PL664", name: "PL664 · Instant Mono 100",
                         character: "Pack-film mono, gentle tones.",
                         cubeFile: "FS_PL664.cube"),
                PackLook(code: "PL667", name: "PL667 · Instant Mono 3000",
                         character: "Blazing-fast instant mono.",
                         cubeFile: "FS_PL667.cube"),
                PackLook(code: "PL672", name: "PL672 · Instant Mono 400",
                         character: "The balanced pack-film mono.",
                         cubeFile: "FS_PL672.cube"),
                PackLook(code: "RIR400", name: "RIR400 · Infra Mono 400",
                         character: "Infrared-ish drama at normal speed.",
                         cubeFile: "FS_RIR400.cube"),
                PackLook(code: "RO25", name: "RO25 · Ortho Mono 25",
                         character: "Orthochromatic: dark lips, luminous skies.",
                         cubeFile: "FS_RO25.cube"),
                PackLook(code: "RR80", name: "RR80 · Retro Mono 80",
                         character: "Aviation-film stock with deep red response.",
                         cubeFile: "FS_RR80.cube"),
            ]
        ),
        LookPack(
            id: "film-instant-lab",
            name: "Instant Lab",
            familyLine: "Integral, silver shade, expired Time-Zero and the peel-apart pack films.",
            eraTag: "Measured instant films",
            photo: .neon,
            isFree: false,
            price: "PRO",
            isProIncluded: true,
            looks: [
                PackLook(code: "PX70W", name: "PX70W · Integral Warm",
                         character: "First-generation integral film, sun-warmed.",
                         cubeFile: "FS_PX70W.cube"),
                PackLook(code: "PX70C", name: "PX70C · Integral Cold",
                         character: "The cool-cast integral batch.",
                         cubeFile: "FS_PX70C.cube"),
                PackLook(code: "PX70", name: "PX70 · Integral Classic",
                         character: "The original integral instant look.",
                         cubeFile: "FS_PX70.cube"),
                PackLook(code: "PX100W", name: "PX100W · Silver Shade Warm",
                         character: "Monochrome-ish silver shade, warm drift.",
                         cubeFile: "FS_PX100W.cube"),
                PackLook(code: "PX100C", name: "PX100C · Silver Shade Cold",
                         character: "Silver shade gone cold and ghostly.",
                         cubeFile: "FS_PX100C.cube"),
                PackLook(code: "PX680", name: "PX680 · Integral 600",
                         character: "The 80s party camera stock.",
                         cubeFile: "FS_PX680.cube"),
                PackLook(code: "PX680W", name: "PX680W · Integral 600 Warm",
                         character: "Sun-soaked 600-speed integral.",
                         cubeFile: "FS_PX680W.cube"),
                PackLook(code: "PX680C", name: "PX680C · Integral 600 Cold",
                         character: "Fridge-stored 600 — cyan whispers.",
                         cubeFile: "FS_PX680C.cube"),
                PackLook(code: "TZ0", name: "TZ0 · Expired Instant",
                         character: "Time-Zero long past its date: gold rot, dream haze.",
                         cubeFile: "FS_TZ0.cube"),
                PackLook(code: "TZ0C", name: "TZ0C · Expired Instant Cold",
                         character: "The expired batch that went blue instead.",
                         cubeFile: "FS_TZ0C.cube"),
                PackLook(code: "FP100", name: "FP100 · Pack Film 100",
                         character: "The beloved peel-apart colour stock.",
                         cubeFile: "FS_FP100.cube"),
                PackLook(code: "FP100C", name: "FP100C · Pack Film Cool",
                         character: "The cool-balanced peel-apart.",
                         cubeFile: "FS_FP100C.cube"),
                PackLook(code: "FP100N", name: "FP100N · Pack Film Negative",
                         character: "Scanned from the thrown-away negative side.",
                         cubeFile: "FS_FP100N.cube"),
                PackLook(code: "FP3000", name: "FP3000 · Pack Mono 3000",
                         character: "Insanely fast instant mono, inky blacks.",
                         cubeFile: "FS_FP3000.cube"),
                PackLook(code: "FP3000N", name: "FP3000N · Pack Mono Negative",
                         character: "The reclaimed-negative look of the fast mono.",
                         cubeFile: "FS_FP3000N.cube"),
                PackLook(code: "PL665", name: "PL665 · Pro Pack Mono",
                         character: "The fine-art pack film with the usable negative.",
                         cubeFile: "FS_PL665.cube"),
                PackLook(code: "IN669C", name: "IN669C · Instant Cold",
                         character: "The classic pack film, cold-stored.",
                         cubeFile: "FS_IN669C.cube"),
                PackLook(code: "PL690", name: "PL690 · Pack Film 690",
                         character: "The last, best colour pack film.",
                         cubeFile: "FS_PL690.cube"),
                PackLook(code: "PL690W", name: "PL690W · Pack Film Warm",
                         character: "690 with the afternoon-sun cast.",
                         cubeFile: "FS_PL690W.cube"),
            ]
        ),
        LookPack(
            id: "film-mirrorless-sims",
            name: "Mirrorless Sims",
            familyLine: "The fifteen in-camera profiles the mirrorless generation shoots — including Classic Chrome and every Acros filter.",
            eraTag: "Measured mirrorless profiles",
            photo: .coast,
            isFree: false,
            price: "PRO",
            isProIncluded: true,
            looks: [
                PackLook(code: "MS1", name: "MS1 · Standard Sim",
                         character: "The mirrorless standard profile.",
                         cubeFile: "FS_MS1.cube"),
                PackLook(code: "MS2", name: "MS2 · Soft Sim",
                         character: "The soft portrait profile.",
                         cubeFile: "FS_MS2.cube"),
                PackLook(code: "MS3", name: "MS3 · Vivid Sim",
                         character: "The vivid landscape profile.",
                         cubeFile: "FS_MS3.cube"),
                PackLook(code: "MS4", name: "MS4 · Classic Chrome Sim",
                         character: "THE documentary look of the mirrorless era.",
                         cubeFile: "FS_MS4.cube"),
                PackLook(code: "MS5", name: "MS5 · Pro Neg Standard",
                         character: "Studio-neutral skin profile.",
                         cubeFile: "FS_MS5.cube"),
                PackLook(code: "MS6", name: "MS6 · Pro Neg High",
                         character: "The contrastier studio profile.",
                         cubeFile: "FS_MS6.cube"),
                PackLook(code: "MS7", name: "MS7 · Acros Sim",
                         character: "The revered digital mono.",
                         cubeFile: "FS_MS7.cube"),
                PackLook(code: "MS8", name: "MS8 · Acros Red Sim",
                         character: "Digital mono through a red filter — dark skies.",
                         cubeFile: "FS_MS8.cube"),
                PackLook(code: "MS9", name: "MS9 · Acros Yellow Sim",
                         character: "The classic yellow-filter mono.",
                         cubeFile: "FS_MS9.cube"),
                PackLook(code: "MS10", name: "MS10 · Acros Green Sim",
                         character: "Green-filter mono — kind to skin.",
                         cubeFile: "FS_MS10.cube"),
                PackLook(code: "MS11", name: "MS11 · Mono Sim",
                         character: "The straight digital mono.",
                         cubeFile: "FS_MS11.cube"),
                PackLook(code: "MS12", name: "MS12 · Mono Red Sim",
                         character: "Straight mono, red-filtered.",
                         cubeFile: "FS_MS12.cube"),
                PackLook(code: "MS13", name: "MS13 · Mono Yellow Sim",
                         character: "Straight mono, yellow-filtered.",
                         cubeFile: "FS_MS13.cube"),
                PackLook(code: "MS14", name: "MS14 · Mono Green Sim",
                         character: "Straight mono, green-filtered.",
                         cubeFile: "FS_MS14.cube"),
                PackLook(code: "MS15", name: "MS15 · Sepia Sim",
                         character: "The tinted heirloom profile.",
                         cubeFile: "FS_MS15.cube"),
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
            // Measured film stocks install their bundled .cube directly.
            if let cubeFile = look.cubeFile {
                guard let bundled = Bundle.main.url(
                    forResource: (cubeFile as NSString).deletingPathExtension,
                    withExtension: "cube") else { continue }
                if (try? repository.importLUT(from: bundled, displayName: look.name,
                                              packID: pack.id)) != nil {
                    installed += 1
                }
                continue
            }
            guard let text = cubeText(for: look.recipe, title: look.name) else { continue }
            let url = tmp.appendingPathComponent("\(look.name).cube")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                _ = try repository.importLUT(from: url, displayName: look.name, packID: pack.id)
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

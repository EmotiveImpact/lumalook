import Foundation

/// "Skin First" — presets tuned to render Black & deep skin tones richly and
/// truthfully (research/BLACK_SKIN_GRADING.md). Expressed purely as
/// `LookSettings` (no LUT), so they bake into exported .cube exactly and flow
/// through preview/export/per-clip/camera like any grade. Richness comes from
/// ORANGE LUMINANCE and a lifted-toe curve, never global contrast.
enum SkinFirstPreset: String, CaseIterable, Identifiable {
    case deepTrue, melaninGlow, richCinema
    var id: String { rawValue }

    var name: String {
        switch self {
        case .deepTrue: return "Deep & True"
        case .melaninGlow: return "Melanin Glow"
        case .richCinema: return "Rich Cinema"
        }
    }

    var blurb: String {
        switch self {
        case .deepTrue: return "Accurate, luminous, no cast"
        case .melaninGlow: return "Warm golden editorial glow"
        case .richCinema: return "Teal-amber print — faces stay warm"
        }
    }

    /// A representative colour for the preset chip's swatch.
    var tintHex: String {
        switch self {
        case .deepTrue: return "#C98A5E"
        case .melaninGlow: return "#D89A55"
        case .richCinema: return "#B87A4E"
        }
    }

    var settings: LookSettings {
        var s = LookSettings()
        s.intensity = 100
        switch self {
        case .deepTrue:
            s.exposure = 8; s.contrast = 14; s.highlights = -6; s.shadows = 12
            s.saturation = 4; s.warmth = 8; s.tint = 3
            s.curves = CurveSet(master: [
                CurvePoint(x: 0, y: 0.015), CurvePoint(x: 0.25, y: 0.235),
                CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.78, y: 0.80), CurvePoint(x: 1, y: 0.985)])
            var h = HSLBands()
            h.lum[1] = 0.12; h.sat[1] = 0.06; h.hue[1] = -0.05
            h.sat[0] = 0.04; h.lum[0] = 0.05
            h.sat[2] = -0.05
            h.sat[4] = -0.08
            s.hsl = h
            s.splitTone = SplitTone(shadowHue: 45, shadowSat: 0.05, highlightHue: 42, highlightSat: 0.10, balance: 0.10)
        case .melaninGlow:
            s.exposure = 10; s.contrast = 16; s.highlights = -4; s.shadows = 12
            s.saturation = 8; s.warmth = 14; s.tint = 2; s.fade = 4
            s.curves = CurveSet(master: [
                CurvePoint(x: 0, y: 0.02), CurvePoint(x: 0.25, y: 0.24),
                CurvePoint(x: 0.5, y: 0.51), CurvePoint(x: 0.78, y: 0.82), CurvePoint(x: 1, y: 0.985)])
            var h = HSLBands()
            h.lum[1] = 0.16; h.sat[1] = 0.10; h.hue[1] = 0.06
            h.sat[0] = 0.06; h.lum[0] = 0.04
            h.sat[2] = 0.04; h.lum[2] = 0.05
            h.sat[4] = -0.10; h.sat[5] = -0.06
            s.hsl = h
            s.splitTone = SplitTone(shadowHue: 35, shadowSat: 0.08, highlightHue: 40, highlightSat: 0.18, balance: 0.15)
        case .richCinema:
            s.exposure = 6; s.contrast = 22; s.highlights = -10; s.shadows = 8
            s.saturation = 2; s.warmth = 6; s.tint = 2; s.fade = 3
            s.curves = CurveSet(master: [
                CurvePoint(x: 0, y: 0.025), CurvePoint(x: 0.2, y: 0.19),
                CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 0.8, y: 0.83), CurvePoint(x: 1, y: 0.97)])
            var h = HSLBands()
            h.hue[1] = -0.06; h.sat[1] = 0.08; h.lum[1] = 0.10
            h.sat[0] = 0.05; h.lum[0] = 0.03
            h.hue[4] = 0.05; h.sat[4] = -0.12
            h.sat[5] = 0.06; h.lum[5] = -0.03
            h.sat[3] = -0.04
            s.hsl = h
            s.splitTone = SplitTone(shadowHue: 200, shadowSat: 0.14, highlightHue: 40, highlightSat: 0.14, balance: -0.05)
        }
        return s
    }

    // MARK: Wearing a preset, and taking it off

    /// The preset this grade is wearing, if any.
    ///
    /// A preset is known by the three things nothing else on the look screen
    /// sets: its curve, its HSL bands and its split tone. Strength, the film
    /// tools, and an Auto or white-balance change made on top of it do not
    /// hide it. Once the person reshapes the curve, the bands, the split tone
    /// or the wheels by hand it is their own grade and no longer a preset.
    static func worn(by settings: LookSettings) -> SkinFirstPreset? {
        allCases.first { settings.wears($0.settings) }
    }

    /// The grade with its preset taken off: every colour adjustment back to
    /// neutral, and the preset's full strength back to the strength a look
    /// opens at. Grain, bloom, halation, vignette, sharpening and the lens
    /// are the person's own and stay. A grade wearing no preset comes back
    /// unchanged.
    ///
    /// The rule is `LookSettings.takingOff`, shared with the looks saved
    /// under Mine, which replace the whole grade in the same way.
    static func takenOff(_ settings: LookSettings) -> LookSettings {
        guard let preset = worn(by: settings) else { return settings }
        return settings.takingOff(preset.settings)
    }

    /// One-screen guidance shown in the Skin First tip card.
    static let guidance: [(String, String)] = [
        ("Expose brighter than the meter says", "Deep skin is usually under-exposed. Aim for skin at ~40–60% on the histogram; don't let auto-exposure darken the face."),
        ("Richness comes from light, not orange", "If skin looks flat, raise Orange Luminance in HSL before you touch saturation."),
        ("Ashy or grey?", "Add a little Warmth and a touch of Tint (magenta), and pull Aqua saturation down."),
        ("Too orange / waxy?", "Lower Orange saturation and nudge Orange hue toward red — keep the glow in luminance."),
        ("Keep detail in the shadows", "Use the lifted-toe curve, not heavy Contrast — contrast crushes dark-skin detail."),
        ("Park skin on the line", "Turn on the vectorscope skin-tone line (~11 o'clock) and land skin on it — it's the hue of blood, true for every complexion."),
    ]
}

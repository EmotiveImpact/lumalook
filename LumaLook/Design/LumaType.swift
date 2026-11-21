import SwiftUI

/// Night Lab type: Inter everywhere (SIL Open Font Licence 1.1, bundled in
/// Resources/Fonts and registered through `UIAppFonts`).
///
/// Hierarchy comes from size, weight and grey rather than from mixing faces.
/// Display sizes (22 pt and up) use Inter Display, the optical size cut for
/// headlines; smaller text uses Inter. Every number is set in tabular figures
/// so timecodes, readouts and prices never jitter.
///
/// `Font.luma(size:weight:design:)` mirrors `Font.system(size:weight:design:)`
/// and `Font.luma(_:design:weight:)` mirrors `Font.system(_:design:weight:)`,
/// so a screen switches face by changing one word. The `design` argument is
/// accepted for source compatibility: monospaced, rounded and serif all set
/// in Inter, with tabular figures doing the job monospacing used to.
enum LumaType {
    /// Headline scale from the Night Lab spec.
    static let display: CGFloat = 34
    static let title: CGFloat = 20
    static let body: CGFloat = 14
    static let label: CGFloat = 12

    /// Display cut from this size up.
    static let displayThreshold: CGFloat = 22

    /// Tracking that keeps Inter tight at a given size (points).
    /// About -0.045 em at display sizes, -0.01 em for body text.
    static func tracking(for size: CGFloat) -> CGFloat {
        if size >= 28 { return -0.045 * size }
        if size >= displayThreshold { return -0.035 * size }
        if size >= 17 { return -0.02 * size }
        return -0.01 * size
    }

    /// The bundled PostScript name for a weight at a size.
    static func postScriptName(weight: Font.Weight, size: CGFloat) -> String {
        let display = size >= displayThreshold
        switch weight {
        case .ultraLight, .thin, .light:
            return "InterDisplay-Light"
        case .medium:
            return "Inter-Medium"
        case .semibold:
            return display ? "InterDisplay-SemiBold" : "Inter-SemiBold"
        case .bold:
            return display ? "InterDisplay-Bold" : "Inter-Bold"
        case .heavy, .black:
            return "InterDisplay-ExtraBold"
        default:
            return "Inter-Regular"
        }
    }

    /// Point size and default weight of each text style at the default
    /// Dynamic Type setting, matching the system's own scale.
    static func metrics(for style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: return (34, .regular)
        case .title: return (28, .regular)
        case .title2: return (22, .regular)
        case .title3: return (20, .regular)
        case .headline: return (17, .semibold)
        case .body: return (17, .regular)
        case .callout: return (16, .regular)
        case .subheadline: return (15, .regular)
        case .footnote: return (13, .regular)
        case .caption: return (12, .regular)
        case .caption2: return (11, .regular)
        @unknown default: return (17, .regular)
        }
    }
}

extension Font {
    /// Inter at a fixed size: the drop-in for `.system(size:weight:design:)`.
    static func luma(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Font.custom(LumaType.postScriptName(weight: weight, size: size), fixedSize: size)
            .monospacedDigit()
    }

    /// Inter that follows Dynamic Type: the drop-in for `.system(_:design:weight:)`
    /// and for the plain text styles (`.headline`, `.footnote`…).
    static func luma(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil) -> Font {
        let base = LumaType.metrics(for: style)
        let name = LumaType.postScriptName(weight: weight ?? base.weight, size: base.size)
        return Font.custom(name, size: base.size, relativeTo: style)
            .monospacedDigit()
    }

    // Night Lab scale.
    /// 34 pt display. Pair `.lumaDisplayLight` and `.lumaDisplayHeavy` for one
    /// light word and one heavy word.
    static let lumaDisplayLight = luma(size: LumaType.display, weight: .light)
    static let lumaDisplayHeavy = luma(size: LumaType.display, weight: .heavy)
    static let lumaTitle = luma(size: LumaType.title, weight: .semibold)
    static let lumaBody = luma(size: LumaType.body)
    static let lumaLabel = luma(size: LumaType.label, weight: .medium)
}

extension View {
    /// Inter tracking for a given point size (tight headlines, near-neutral body).
    func lumaTracking(_ size: CGFloat) -> some View {
        tracking(LumaType.tracking(for: size))
    }
}

/// Two-weight headline: one light word and one heavy word, set tight.
/// `LumaHeadline(light: "Shoot it", heavy: "graded.")`
struct LumaHeadline: View {
    let light: String
    let heavy: String
    var size: CGFloat = LumaType.display
    var heavyColor: Color = LumaTheme.textPrimary
    var lightColor: Color = LumaTheme.textPrimary

    var body: some View {
        (Text(light + " ").font(.luma(size: size, weight: .light)).foregroundColor(lightColor)
         + Text(heavy).font(.luma(size: size, weight: .heavy)).foregroundColor(heavyColor))
            .tracking(LumaType.tracking(for: size))
    }
}

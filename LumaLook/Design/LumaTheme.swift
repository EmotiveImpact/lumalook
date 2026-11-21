import SwiftUI

/// Night Lab: the Lumalook design system (V2, approved 21 Nov 2026).
///
/// Neutral near-black chrome with hairline panels, one typeface (Inter, see
/// `LumaType.swift`) and a single signal yellow for the brand and the one main
/// action on each screen. Everything else that carries colour is a LOOK: each
/// look has a signature colour (`LookSignature`) that tints its chip, tile ring
/// and clip label, so the interface takes the colour of your grade.
///
/// The older member names (`accent`, `surface`, `card`…) are kept so every
/// screen picks up the new system; they now resolve to Night Lab values.
enum LumaTheme {
    // MARK: Neutrals

    /// Ink: the canvas. #08090A
    static let ink = Color(hex: 0x08090A)
    /// Panel: cards and sheets, one step above ink. #0E0F11
    static let panel = Color(hex: 0x0E0F11)
    /// Raised: controls sitting on a panel. #151619
    static let raised = Color(hex: 0x151619)
    /// Control: the selected segment of a segmented control. #1C1D21
    static let control = Color(hex: 0x1C1D21)

    static let background = ink
    /// Tab bar, docks and tool trays: solid ink with a hairline on top.
    static let bar = ink
    /// Translucent fills so the same token works over ink and over footage.
    static let surface = Color.white.opacity(0.045)
    static let surfaceStrong = Color.white.opacity(0.085)
    /// Borders and dividers: white at 7.5%.
    static let hairline = Color.white.opacity(0.075)
    /// The stronger line for selected segments and sheet edges: white at 13%.
    static let border = Color.white.opacity(0.13)

    // MARK: Elevation
    // Panels one step lighter than the background, each with a hairline border.
    /// Default card fill (reads as #0E0F11 on ink, still works over footage).
    static let card = Color.white.opacity(0.03)
    /// A card on a card (reads as #151619 on ink).
    static let cardRaised = Color.white.opacity(0.058)
    /// Unselected chip / pill fill.
    static let chip = Color.white.opacity(0.055)
    /// Shadows are reserved for things floating over footage.
    static let cardShadow = Color.black.opacity(0.4)

    // MARK: Text

    static let textPrimary = Color(hex: 0xF7F8F8)
    static let textSecondary = Color(hex: 0xA3A6AD)
    static let textMuted = Color(hex: 0x6E727A)
    /// Text on a white button or a selected white pill.
    static let onLight = ink

    // MARK: Signal and record

    /// Signal yellow: the brand and the one main action per screen. #FFC53D
    static let signal = Color(hex: 0xFFC53D)
    /// Text and icons on a signal-yellow fill. #120D00
    static let onSignal = Color(hex: 0x120D00)
    /// Recording only. #FF4538
    static let recordRed = Color(hex: 0xFF4538)

    // Legacy accent names map onto signal, so active states, main actions and
    // the wordmark all speak the same colour.
    static let accent = signal
    static let accentBright = signal
    static let accentDeep = Color(hex: 0xC9951F)
    static let accentSoft = signal.opacity(0.14)

    static let gold = signal
    static let teal = Color(hex: 0x3DD68C)   // success
    static let success = teal

    // Kept for the grading engine's mock look chips.
    static let purple = accent
    static let orange = Color(hex: 0xFF8A3D)
    static let cyan = Color(hex: 0x8DB3D6)

    /// The wordmark's mark: solid signal.
    static let wordmarkViolet = LinearGradient(colors: [signal, signal], startPoint: .top, endPoint: .bottom)

    // Home tiles are quiet panels now; colour comes from the photos and looks.
    static let tilePurple = panelGradient
    static let tileTeal = panelGradient
    static let tileAmber = panelGradient
    static let tileIndigo = panelGradient
    private static let panelGradient = LinearGradient(colors: [panel, panel], startPoint: .top, endPoint: .bottom)

    // Legacy aliases still referenced by the engine-agnostic views.
    static let elevated = surface
    static let elevatedStrong = surfaceStrong
    static let mainGradient = LinearGradient(colors: [signal, signal], startPoint: .leading, endPoint: .trailing)
    static let logoGradient = wordmarkViolet

    // MARK: Layout
    /// Four-point grid.
    static func grid(_ n: CGFloat) -> CGFloat { n * 4 }
}

extension Color {
    /// `Color(hex: 0xFFC53D)`
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

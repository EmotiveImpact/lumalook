import SwiftUI

enum LumaTheme {
    // Deep blue-black canvas, per latest reference screens.
    static let background = Color(red: 0.039, green: 0.051, blue: 0.078)   // #0A0D14
    /// Solid near-black for bottom bars, docks, the tab bar and tool sheets.
    /// Replaces `.ultraThinMaterial` on nav surfaces, which frosted content
    /// through as grey — bars stay dark regardless of what scrolls under them.
    static let bar = Color(red: 0.016, green: 0.02, blue: 0.032)           // #04050A
    static let surface = Color.white.opacity(0.055)
    static let surfaceStrong = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.10)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textMuted = Color.white.opacity(0.38)

    // Primary indigo-violet used for every CTA, chip and active state.
    static let accent = Color(red: 0.478, green: 0.408, blue: 0.933)       // #7A68EE
    static let accentBright = Color(red: 0.639, green: 0.557, blue: 1.0)   // #A38EFF
    static let accentDeep = Color(red: 0.357, green: 0.302, blue: 0.722)   // #5B4DB8
    static let accentSoft = accent.opacity(0.22)

    static let gold = Color(red: 1.0, green: 0.733, blue: 0.161)           // crown / stars / coins
    static let teal = Color(red: 0.204, green: 0.878, blue: 0.714)         // success
    static let recordRed = Color(red: 0.918, green: 0.180, blue: 0.180)

    // Kept for the grading engine's mock look chips.
    static let purple = accent
    static let orange = Color(red: 1.0, green: 0.60, blue: 0.12)
    static let cyan = Color(red: 0.0, green: 0.86, blue: 0.90)
    static let success = teal

    // Wordmark: LUMA in white, LOOK in violet.
    static let wordmarkViolet = LinearGradient(
        colors: [Color(red: 0.655, green: 0.482, blue: 1.0), Color(red: 0.478, green: 0.361, blue: 0.949)],
        startPoint: .top, endPoint: .bottom
    )

    // Home action tile gradients, sampled from the reference.
    static let tilePurple = LinearGradient(
        colors: [Color(red: 0.435, green: 0.278, blue: 0.686), Color(red: 0.227, green: 0.137, blue: 0.408)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let tileTeal = LinearGradient(
        colors: [Color(red: 0.118, green: 0.396, blue: 0.373), Color(red: 0.051, green: 0.220, blue: 0.220)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let tileAmber = LinearGradient(
        colors: [Color(red: 0.553, green: 0.322, blue: 0.129), Color(red: 0.318, green: 0.161, blue: 0.063)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let tileIndigo = LinearGradient(
        colors: [Color(red: 0.176, green: 0.196, blue: 0.365), Color(red: 0.098, green: 0.110, blue: 0.224)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // Legacy aliases still referenced by the engine-agnostic views.
    static let elevated = surface
    static let elevatedStrong = surfaceStrong
    static let mainGradient = LinearGradient(colors: [accent, accentBright], startPoint: .leading, endPoint: .trailing)
    static let logoGradient = wordmarkViolet
}

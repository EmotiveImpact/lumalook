import SwiftUI

// MARK: - You › Appearance
//
// Three choices, each with a live preview card (calm mock v2,
// 05-appearance-settings.jpg): Sliders (Ruler · Dial), Look and pack names
// (In colour · Dot and code), Main buttons (Signal yellow · Quiet white).
// The choices live in LumaAppearance (Design/LumaAppearance.swift).

struct AppearanceSettingsView: View {
    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue
    @AppStorage(LumaAppearance.buttonsKey) private var buttonsRaw = LumaMainButtonStyle.signal.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Appearance")
                    .font(.luma(size: 26, weight: .bold))
                    .foregroundStyle(LumaTheme.textPrimary)
            }
            .padding(16)
        }
        .background(LumaTheme.ink.ignoresSafeArea())
    }
}

import SwiftUI

// MARK: - You › Appearance
//
// Three choices, each with a live preview card (calm mock v2,
// 05-appearance-settings.jpg): Sliders (Ruler · Dial), Look and pack names
// (In colour · Dot and code), Main buttons (Signal yellow · Quiet white).
// The choices live in LumaAppearance (Design/LumaAppearance.swift) and are
// written here through @AppStorage, so every screen follows at once.

struct AppearanceSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue
    @AppStorage(LumaAppearance.buttonsKey) private var buttonsRaw = LumaMainButtonStyle.signal.rawValue

    private var slider: LumaSliderStyle { LumaSliderStyle(rawValue: sliderRaw) ?? .ruler }
    private var names: LumaNameStyle { LumaNameStyle(rawValue: namesRaw) ?? .colour }
    private var buttons: LumaMainButtonStyle { LumaMainButtonStyle(rawValue: buttonsRaw) ?? .signal }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    slidersGroup
                    namesGroup
                    buttonsGroup
                    note
                    resetButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .background(LumaTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Text("Appearance")
                .font(.luma(size: 17, weight: .semibold))
                .tracking(-0.25)
                .foregroundStyle(LumaTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                SettingsBackCircle { goBack() }
                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func goBack() {
        if app.path.isEmpty {
            dismiss()
        } else {
            app.path.removeLast()
        }
    }

    // MARK: Groups

    private var slidersGroup: some View {
        AppearanceChoiceGroup(title: "Sliders", topPadding: 14) {
            AppearanceChoiceCard(title: LumaSliderStyle.ruler.title,
                                 detail: LumaSliderStyle.ruler.detail,
                                 isOn: slider == .ruler, isDefault: true,
                                 action: { pick { sliderRaw = LumaSliderStyle.ruler.rawValue } }) {
                MiniRulerPreview()
            }
            AppearanceChoiceCard(title: LumaSliderStyle.dial.title,
                                 detail: LumaSliderStyle.dial.detail,
                                 isOn: slider == .dial, isDefault: false,
                                 action: { pick { sliderRaw = LumaSliderStyle.dial.rawValue } }) {
                MiniDialPreview()
            }
        }
    }

    private var namesGroup: some View {
        AppearanceChoiceGroup(title: "Look and pack names", topPadding: 30) {
            AppearanceChoiceCard(title: LumaNameStyle.colour.title,
                                 detail: LumaNameStyle.colour.detail,
                                 isOn: names == .colour, isDefault: true,
                                 action: { pick { namesRaw = LumaNameStyle.colour.rawValue } }) {
                MiniNamesPreview(inColour: true)
            }
            AppearanceChoiceCard(title: LumaNameStyle.dot.title,
                                 detail: LumaNameStyle.dot.detail,
                                 isOn: names == .dot, isDefault: false,
                                 action: { pick { namesRaw = LumaNameStyle.dot.rawValue } }) {
                MiniNamesPreview(inColour: false)
            }
        }
    }

    private var buttonsGroup: some View {
        AppearanceChoiceGroup(title: "Main buttons", topPadding: 30) {
            AppearanceChoiceCard(title: LumaMainButtonStyle.signal.title,
                                 detail: LumaMainButtonStyle.signal.detail,
                                 isOn: buttons == .signal, isDefault: true,
                                 action: { pick { buttonsRaw = LumaMainButtonStyle.signal.rawValue } }) {
                MiniMainPill(style: .signal)
            }
            AppearanceChoiceCard(title: LumaMainButtonStyle.white.title,
                                 detail: LumaMainButtonStyle.white.detail,
                                 isOn: buttons == .white, isDefault: false,
                                 action: { pick { buttonsRaw = LumaMainButtonStyle.white.rawValue } }) {
                MiniMainPill(style: .white)
            }
        }
    }

    private func pick(_ change: () -> Void) {
        withAnimation(.snappy(duration: 0.2)) {
            change()
        }
        LumaHaptics.shared.tap()
    }

    // MARK: Note and reset

    private var note: some View {
        Text("Changes apply everywhere at once: camera, editor, grade room, Looks and the Store. The shutter stays yellow and recording stays red whatever you pick.")
            .font(.luma(size: 12.5))
            .lineSpacing(3)
            .foregroundStyle(Color.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 34)
    }

    private var resetButton: some View {
        Button {
            LumaAppearance.reset()
            // Mirror the reset through the bindings too, so this page redraws
            // in the same transaction whatever UserDefaults notifies.
            pick {
                sliderRaw = LumaSliderStyle.ruler.rawValue
                namesRaw = LumaNameStyle.colour.rawValue
                buttonsRaw = LumaMainButtonStyle.signal.rawValue
            }
        } label: {
            Text("Reset to default")
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .padding(.top, 18)
    }
}

// MARK: - Back button

/// The way back on pages pushed from You: a chevron in a quiet glass circle.
struct SettingsBackCircle: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Back")
    }
}

// MARK: - Group and card

/// A grey label, then two cards side by side.
private struct AppearanceChoiceGroup<Cards: View>: View {
    let title: String
    var topPadding: CGFloat = 30
    private let cards: Cards

    init(title: String, topPadding: CGFloat = 30, @ViewBuilder cards: () -> Cards) {
        self.title = title
        self.topPadding = topPadding
        self.cards = cards()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
                .padding(.leading, 16)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 10) {
                cards
            }
        }
        .padding(.top, topPadding)
    }
}

/// One choice: a live preview on a quiet card, then its name and a line
/// under it. The picked card wears the pale ring; the default option says
/// "Default" while it is the one picked.
private struct AppearanceChoiceCard<Preview: View>: View {
    let title: String
    let detail: String
    let isOn: Bool
    let isDefault: Bool
    let action: () -> Void
    private let preview: Preview

    init(title: String, detail: String, isOn: Bool, isDefault: Bool,
         action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.isDefault = isDefault
        self.action = action
        self.preview = preview()
    }

    private var cardFill: Color {
        isOn ? LumaTheme.pickedRing.opacity(0.06) : Color.white.opacity(0.055)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    preview
                }
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .pickedRing(isOn, cornerRadius: 18)
                HStack(spacing: 6) {
                    Text(title)
                        .font(.luma(size: 14, weight: .semibold))
                        .tracking(-0.1)
                        .foregroundStyle(LumaTheme.textPrimary)
                        .lineLimit(1)
                    if isOn && isDefault {
                        Text("Default")
                            .font(.luma(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 4)
                Text(detail)
                    .font(.luma(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                    .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Live previews

/// A small straight ruler: ticks with a longer one every seventh, the yellow
/// needle on 75, and 50 · 75 · 100 under it.
private struct MiniRulerPreview: View {
    private static let labels: [(text: String, x: CGFloat, on: Bool)] = [
        ("50", 38, false), ("75", 70, true), ("100", 102, false),
    ]

    var body: some View {
        Canvas { context, _ in
            let base: CGFloat = 32
            var minor = Path()
            var major = Path()
            for k in 0...28 {
                let x = 6 + CGFloat(k) * 4.6 + 0.5
                if k % 7 == 0 {
                    major.move(to: CGPoint(x: x, y: base))
                    major.addLine(to: CGPoint(x: x, y: base - 13))
                } else {
                    minor.move(to: CGPoint(x: x, y: base))
                    minor.addLine(to: CGPoint(x: x, y: base - 7))
                }
            }
            context.stroke(minor, with: .color(Color.white.opacity(0.3)), lineWidth: 1)
            context.stroke(major, with: .color(Color.white.opacity(0.55)), lineWidth: 1)

            var needle = Path()
            needle.move(to: CGPoint(x: 70, y: base))
            needle.addLine(to: CGPoint(x: 70, y: base - 22))
            context.stroke(needle, with: .color(LumaTheme.signal),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))

            for label in Self.labels {
                let text = Text(label.text)
                    .font(.luma(size: 10, weight: .semibold))
                    .foregroundColor(label.on ? Color.white : Color.white.opacity(0.4))
                context.draw(text, at: CGPoint(x: label.x, y: 46), anchor: .center)
            }
        }
        .frame(width: 140, height: 54)
        .accessibilityHidden(true)
    }
}

/// A small curved dial: ticks on an arc under the yellow needle, 75% big in
/// the middle.
private struct MiniDialPreview: View {
    var body: some View {
        Canvas { context, _ in
            let cx: CGFloat = 70
            let cy: CGFloat = 92
            let r: CGFloat = 74
            var minor = Path()
            var major = Path()
            for k in -9...9 {
                let a = CGFloat((-90.0 + Double(k) * 7.0) * Double.pi / 180.0)
                let isMajor = k % 3 == 0
                let len: CGFloat = isMajor ? 10 : 6
                let p1 = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                let p2 = CGPoint(x: cx + (r - len) * cos(a), y: cy + (r - len) * sin(a))
                if isMajor {
                    major.move(to: p1)
                    major.addLine(to: p2)
                } else {
                    minor.move(to: p1)
                    minor.addLine(to: p2)
                }
            }
            context.stroke(minor, with: .color(Color.white.opacity(0.28)), lineWidth: 1)
            context.stroke(major, with: .color(Color.white.opacity(0.55)), lineWidth: 1.4)

            var needle = Path()
            needle.move(to: CGPoint(x: 70, y: 14))
            needle.addLine(to: CGPoint(x: 70, y: 32))
            context.stroke(needle, with: .color(LumaTheme.signal),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

            let value = Text("75%")
                .font(.luma(size: 17, weight: .bold))
                .foregroundColor(LumaTheme.textPrimary)
            context.draw(value, at: CGPoint(x: 70, y: 60), anchor: .center)
        }
        .frame(width: 140, height: 76)
        .accessibilityHidden(true)
    }
}

/// Three small look thumbs with their codes, drawn the way the choice says
/// (each code in its look's colour, or white after a small dot in it). Drawn
/// explicitly rather than with LookNameText, so both cards always show their
/// own option whatever is picked.
private struct MiniNamesPreview: View {
    let inColour: Bool

    private struct Sample {
        let code: String
        let look: String
    }

    private static let samples: [Sample] = [
        Sample(code: "LL1", look: "Neon Nights"),
        Sample(code: "KD2", look: "KD2 · Golden Hour"),
        Sample(code: "CN83", look: "CN83 · Teal & Orange"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.samples, id: \.code) { sample in
                thumb(code: sample.code,
                      colour: LookSignature.colour(forLookNamed: sample.look))
            }
        }
        .accessibilityHidden(true)
    }

    private func thumb(code: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HeroImage(photo: .campaign, radius: 9)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(colour.opacity(0.32))
                        .blendMode(.softLight)
                )
                .frame(width: 40, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            HStack(spacing: 3) {
                if !inColour {
                    Circle()
                        .fill(colour)
                        .frame(width: 5, height: 5)
                }
                Text(code)
                    .font(.luma(size: 10, weight: .bold))
                    .foregroundStyle(inColour ? colour : Color.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(width: 40, alignment: .leading)
    }
}

/// A small Export pill in the option's own fill, not the picked one.
private struct MiniMainPill: View {
    let style: LumaMainButtonStyle

    var body: some View {
        Text("Export")
            .font(.luma(size: 14, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(style.text)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(style.fill, in: Capsule())
            .accessibilityHidden(true)
    }
}

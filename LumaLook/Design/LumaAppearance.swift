import SwiftUI

// MARK: - Appearance (You › Appearance)
//
// Three choices people can change, approved in the calm mock v2
// (calm-mock/other-screens-v2/05-appearance-settings.jpg):
//
//   Sliders            Ruler (default) · Dial
//   Look/pack names    In colour (default) · Dot and code
//   Main buttons       Signal yellow (default) · Quiet white
//
// Every screen reads them through the components below, so a change applies
// everywhere at once. The shutter stays yellow and recording stays red
// whatever is picked: nothing here touches `LumaTheme.signal` on the shutter
// or `LumaTheme.recordRed`.

enum LumaSliderStyle: String, CaseIterable, Identifiable {
    case ruler, dial
    var id: String { rawValue }
    var title: String { self == .ruler ? "Ruler" : "Dial" }
    var detail: String { self == .ruler ? "Straight, like a lens ring" : "Curved, like a camera dial" }
}

enum LumaNameStyle: String, CaseIterable, Identifiable {
    case colour, dot
    var id: String { rawValue }
    var title: String { self == .colour ? "In colour" : "Dot and code" }
    var detail: String { self == .colour ? "Each name in its own colour" : "White names, a small dot" }
    /// The word the You row shows ("Colour · Ruler").
    var short: String { self == .colour ? "Colour" : "Dot" }
}

enum LumaMainButtonStyle: String, CaseIterable, Identifiable {
    case signal, white
    var id: String { rawValue }
    var title: String { self == .signal ? "Signal yellow" : "Quiet white" }
    var detail: String { self == .signal ? "Export, Apply, Subscribe" : "The calmest option" }
    var fill: Color { self == .signal ? LumaTheme.signal : Color(hex: 0xF4F5F6) }
    var text: Color { self == .signal ? LumaTheme.onSignal : LumaTheme.ink }
}

/// Keys and helpers. Views read the choices with `@AppStorage`:
///
///     @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue
///
/// and turn the raw string into the enum with `LumaSliderStyle(rawValue:) ?? .ruler`.
enum LumaAppearance {
    static let sliderKey = "lumalook.appearance.slider"
    static let namesKey = "lumalook.appearance.names"
    static let buttonsKey = "lumalook.appearance.buttons"

    static var slider: LumaSliderStyle {
        LumaSliderStyle(rawValue: UserDefaults.standard.string(forKey: sliderKey) ?? "") ?? .ruler
    }
    static var names: LumaNameStyle {
        LumaNameStyle(rawValue: UserDefaults.standard.string(forKey: namesKey) ?? "") ?? .colour
    }
    static var buttons: LumaMainButtonStyle {
        LumaMainButtonStyle(rawValue: UserDefaults.standard.string(forKey: buttonsKey) ?? "") ?? .signal
    }

    /// Back to Ruler, In colour, Signal yellow.
    static func reset() {
        let d = UserDefaults.standard
        d.set(LumaSliderStyle.ruler.rawValue, forKey: sliderKey)
        d.set(LumaNameStyle.colour.rawValue, forKey: namesKey)
        d.set(LumaMainButtonStyle.signal.rawValue, forKey: buttonsKey)
    }

    /// "Colour · Ruler", the value on the You › Appearance row.
    static func summary(names: LumaNameStyle, slider: LumaSliderStyle) -> String {
        "\(names.short) · \(slider.title)"
    }

    #if DEBUG
    /// Screenshot hook: LUMA_APPEARANCE=dial,dot,white (any order, any
    /// subset) sets the choices at launch; LUMA_APPEARANCE=default resets.
    static func applyLaunchOverride() {
        guard let raw = ProcessInfo.processInfo.environment["LUMA_APPEARANCE"] else { return }
        let words = Set(raw.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        reset()
        let d = UserDefaults.standard
        if words.contains("dial") { d.set(LumaSliderStyle.dial.rawValue, forKey: sliderKey) }
        if words.contains("dot") { d.set(LumaNameStyle.dot.rawValue, forKey: namesKey) }
        if words.contains("white") { d.set(LumaMainButtonStyle.white.rawValue, forKey: buttonsKey) }
    }
    #endif
}

// MARK: - Main action button

/// The one main action on a screen (Export, Apply look, Start free trial,
/// Keep this look, Get started's final step): signal yellow, or quiet white
/// when the person picked that. Full width by default, 52 pt high.
struct LumaMainButton: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 52
    var cornerRadius: CGFloat = 14
    var action: () -> Void
    @AppStorage(LumaAppearance.buttonsKey) private var buttonsRaw = LumaMainButtonStyle.signal.rawValue
    @State private var fired = 0

    var body: some View {
        let style = LumaMainButtonStyle(rawValue: buttonsRaw) ?? .signal
        Button {
            fired += 1
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.luma(size: 16, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(style.text)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(style.fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .sensoryFeedback(.impact(weight: .light), trigger: fired)
    }
}

/// The main action as a small capsule (Export in the editor's top bar, Apply
/// on a preview card). Same colour rule as `LumaMainButton`.
struct LumaMainPill: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 34
    var action: () -> Void
    @AppStorage(LumaAppearance.buttonsKey) private var buttonsRaw = LumaMainButtonStyle.signal.rawValue

    var body: some View {
        let style = LumaMainButtonStyle(rawValue: buttonsRaw) ?? .signal
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.luma(size: 14, weight: .semibold))
                    .tracking(-0.1)
                    .lineLimit(1)
            }
            .foregroundStyle(style.text)
            .padding(.horizontal, 15)
            .frame(height: height)
            .background(style.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .fixedSize()
    }
}

/// A button in a look's or a pack's own colour: Buy pack, Try on a clip,
/// Try tonight's look, Buy After Dark. Ink text on the colour. This one does
/// not follow the Main buttons choice: the colour is the pack's, not an
/// interface colour. With names set to Dot and code it turns quiet glass with
/// a dot, so that setting stays the calmest screen.
struct LumaColourButton: View {
    let title: String
    let colour: Color
    var icon: String? = nil
    var height: CGFloat = 44
    var fullWidth: Bool = false
    var action: () -> Void
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue

    var body: some View {
        let inColour = (LumaNameStyle(rawValue: namesRaw) ?? .colour) == .colour
        Button(action: action) {
            HStack(spacing: 7) {
                if !inColour {
                    Circle().fill(colour).frame(width: 7, height: 7)
                }
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.luma(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(inColour ? Color(hex: 0x0B0B0C) : LumaTheme.textPrimary)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(inColour ? colour : Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Look and pack names

/// A look's or a pack's name as the Names choice says: in its own colour, or
/// white with a small dot in that colour before it. Use it everywhere a look
/// code or a pack name is shown (strips, grids, tags, Store, editor clips).
///
///     LookNameText("KD2", colour: look.signature)
///     LookNameText("KD2 · Golden Hour", colour: c, size: 13, alwaysDot: true)
///
/// `alwaysDot` keeps the dot in colour mode too (labels on a picture, where
/// the dot helps the name read over any frame).
struct LookNameText: View {
    let text: String
    let colour: Color
    var size: CGFloat = 13
    var weight: Font.Weight = .semibold
    var alwaysDot: Bool = false
    /// Text colour in Dot mode (white by default; grey for secondary lines).
    var quietColour: Color = LumaTheme.textPrimary
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue

    init(_ text: String, colour: Color, size: CGFloat = 13, weight: Font.Weight = .semibold,
         alwaysDot: Bool = false, quietColour: Color = LumaTheme.textPrimary) {
        self.text = text
        self.colour = colour
        self.size = size
        self.weight = weight
        self.alwaysDot = alwaysDot
        self.quietColour = quietColour
    }

    var body: some View {
        let inColour = (LumaNameStyle(rawValue: namesRaw) ?? .colour) == .colour
        HStack(spacing: max(4, size * 0.38)) {
            if alwaysDot || !inColour {
                Circle()
                    .fill(colour)
                    .frame(width: max(5, size * 0.42), height: max(5, size * 0.42))
            }
            Text(text)
                .font(.luma(size: size, weight: weight))
                .tracking(size >= 20 ? -0.4 : -0.1)
                .foregroundStyle(inColour ? colour : quietColour)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The colour a name or code takes for the current Names choice, for places
/// that style their own `Text` (for example a two-tone headline).
struct LookNameColour {
    static func forText(_ colour: Color, quiet: Color = LumaTheme.textPrimary) -> Color {
        LumaAppearance.names == .colour ? colour : quiet
    }
}

// MARK: - Pack colours

extension LookPack {
    /// The pack's own colour: its name in the Store, its price tag and its
    /// Buy button. Picked from the cover art, approved in the calm mock v2.
    var colour: Color {
        switch id {
        case "negative-set-01": return Color(hex: 0xC9A27E)
        case "film-stocks-01": return Color(hex: 0x8DB3D6)
        case "film-neg-archive": return Color(hex: 0xF7AA70)
        case "film-slide-archive": return Color(hex: 0x9BE1F7)
        case "film-mono-archive": return Color(hex: 0xD9D4CC)
        case "film-instant-lab": return Color(hex: 0xFF8FB8)
        case "film-mirrorless-sims": return Color(hex: 0x7C9CFF)
        case "cine-print-set-01": return Color(hex: 0xE8B86B)
        case "bw-set-01": return Color(hex: 0xC8C8C8)
        case "originals-01": return Color(hex: 0x86C98B)
        case "after-dark": return Color(hex: 0xFF3DB4)
        default: return LookSignature.colour(name: name)
        }
    }
}

// MARK: - Sliders: the switch

/// A 0...100 value (look strength, grain, bloom, any amount) as the Sliders
/// choice says: the straight `LumaStrengthRuler`, or the curved
/// `LumaStrengthDial`. The ruler is 48 pt high and shows no title or value,
/// so the caller keeps its own "Strength 75%" line above it; the dial is
/// taller and draws its own title and big value, so hide the caller's line
/// when `LumaAppearance.slider == .dial` (read it with @AppStorage).
struct LumaValueSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var title: String = "Strength"
    /// Formats the dial's big centre value. Defaults to "75%".
    var format: (Double) -> String = { "\(Int($0.rounded()))%" }
    var needle: Color = LumaTheme.signal
    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue

    var body: some View {
        if (LumaSliderStyle(rawValue: sliderRaw) ?? .ruler) == .dial {
            LumaStrengthDial(value: $value, range: range, title: title, format: format, needle: needle)
        } else {
            LumaStrengthRuler(value: $value, range: range, needle: needle)
        }
    }
}

/// Stepped values (lens 13 / 24 / 48 / 77, shutter, ISO, white balance) as
/// the Sliders choice says: the straight `LumaRuler` or the curved
/// `LumaStopDial`.
struct LumaStopsSlider: View {
    let stops: [String]
    let index: Int
    var title: String = ""
    var needle: Color = LumaTheme.signal
    let onChange: (Int) -> Void
    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue

    var body: some View {
        if (LumaSliderStyle(rawValue: sliderRaw) ?? .ruler) == .dial {
            LumaStopDial(stops: stops, index: index, title: title, needle: needle, onChange: onChange)
        } else {
            LumaRuler(stops: stops, index: index, needle: needle, onChange: onChange)
        }
    }
}

// MARK: - Dial (continuous)

/// The curved dial, like the old camera lens dial: ticks on an arc that turns
/// under a fixed yellow needle at the top, the value big in the middle and
/// the title at the top left. Ticks every 2.5, longer every 5, labelled every
/// 25 just outside the arc. 108 pt high. Drag sideways to turn it.
struct LumaStrengthDial: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var title: String = "Strength"
    var format: (Double) -> String = { "\(Int($0.rounded()))%" }
    var needle: Color = LumaTheme.signal
    var height: CGFloat = 108

    /// Degrees of arc per unit of value.
    private let degreesPerUnit: Double = 1.25
    /// Only this much of the arc either side of the needle is drawn.
    private let visibleDegrees: Double = 62
    private let radius: CGFloat = 140
    /// Points of finger travel per unit.
    private let pointsPerUnit: CGFloat = 3
    @State private var dragStart: Double?
    private var detent: Int { Int(value / 5) }

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let top: CGFloat = 36
            let cy = top + radius
            var minor = Path()
            var mid = Path()
            var major = Path()
            var unit = range.lowerBound
            while unit <= range.upperBound + 0.001 {
                let d = (unit - value) * degreesPerUnit
                if abs(d) <= visibleDegrees {
                    let a = CGFloat((-90 + d) * .pi / 180)
                    let rounded = Int(unit.rounded())
                    let isMajor = abs(unit - Double(rounded)) < 0.01 && rounded % 25 == 0
                    let isMid = abs(unit - Double(rounded)) < 0.01 && rounded % 5 == 0
                    let len: CGFloat = isMajor ? 13 : (isMid ? 8 : 5)
                    let p1 = CGPoint(x: cx + radius * cos(a), y: cy + radius * sin(a))
                    let p2 = CGPoint(x: cx + (radius - len) * cos(a), y: cy + (radius - len) * sin(a))
                    if isMajor {
                        major.move(to: p1); major.addLine(to: p2)
                        if abs(unit - value) > 4 {
                            let t = CGPoint(x: cx + (radius + 12) * cos(a), y: cy + (radius + 12) * sin(a))
                            let label = Text("\(rounded)")
                                .font(.luma(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(LumaTheme.textMuted)
                            context.draw(label, at: t, anchor: .center)
                        }
                    } else if isMid {
                        mid.move(to: p1); mid.addLine(to: p2)
                    } else {
                        minor.move(to: p1); minor.addLine(to: p2)
                    }
                }
                unit += 2.5
            }
            context.stroke(minor, with: .color(.white.opacity(0.25)), lineWidth: 1)
            context.stroke(mid, with: .color(.white.opacity(0.25)), lineWidth: 1)
            context.stroke(major, with: .color(.white.opacity(0.55)), lineWidth: 1.6)

            var needlePath = Path()
            needlePath.move(to: CGPoint(x: cx, y: top - 6))
            needlePath.addLine(to: CGPoint(x: cx, y: top + 18))
            context.stroke(needlePath, with: .color(needle),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

            let big = Text(format(value))
                .font(.luma(size: 27, weight: .bold))
                .kerning(-0.6)
                .monospacedDigit()
                .foregroundColor(LumaTheme.textPrimary)
            context.draw(big, at: CGPoint(x: cx, y: size.height - 26), anchor: .center)

            if !title.isEmpty {
                let label = Text(title)
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.55))
                context.draw(label, at: CGPoint(x: 20, y: 10), anchor: .leading)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    if dragStart == nil { dragStart = value }
                    let delta = Double(-drag.translation.width / pointsPerUnit)
                    value = min(max(range.lowerBound, (dragStart ?? value) + delta), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: detent)
        .accessibilityElement()
        .accessibilityLabel(title.isEmpty ? "Value" : title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            value = min(max(range.lowerBound, value + step), range.upperBound)
        }
    }
}

// MARK: - Dial (stops)

/// The curved dial for stepped values: each stop 14° apart on the arc with
/// its label outside, the current stop under the yellow needle and big in
/// the middle. 108 pt high.
struct LumaStopDial: View {
    let stops: [String]
    let index: Int
    var title: String = ""
    var needle: Color = LumaTheme.signal
    var height: CGFloat = 108
    let onChange: (Int) -> Void

    private let degreesPerStop: Double = 14
    private let visibleDegrees: Double = 62
    private let radius: CGFloat = 140
    /// Points of finger travel per stop.
    private let pointsPerStop: CGFloat = 34
    @State private var dragBase: Int?

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let top: CGFloat = 36
            let cy = top + radius
            var fine = Path()
            var major = Path()
            let count = stops.count
            guard count > 0 else { return }
            // Fine ticks between stops, five per gap, running a little past both ends.
            var k = -5
            while k <= (count - 1) * 5 + 5 {
                let d = (Double(k) / 5 - Double(index)) * degreesPerStop
                if abs(d) <= visibleDegrees {
                    let a = CGFloat((-90 + d) * .pi / 180)
                    let isStop = k % 5 == 0 && k >= 0 && k / 5 < count
                    let len: CGFloat = isStop ? 13 : 5
                    let p1 = CGPoint(x: cx + radius * cos(a), y: cy + radius * sin(a))
                    let p2 = CGPoint(x: cx + (radius - len) * cos(a), y: cy + (radius - len) * sin(a))
                    if isStop {
                        major.move(to: p1); major.addLine(to: p2)
                        let i = k / 5
                        if i != index {
                            let t = CGPoint(x: cx + (radius + 13) * cos(a), y: cy + (radius + 13) * sin(a))
                            let label = Text(stops[i])
                                .font(.luma(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(LumaTheme.textMuted)
                            context.draw(label, at: t, anchor: .center)
                        }
                    } else {
                        fine.move(to: p1); fine.addLine(to: p2)
                    }
                }
                k += 1
            }
            context.stroke(fine, with: .color(.white.opacity(0.25)), lineWidth: 1)
            context.stroke(major, with: .color(.white.opacity(0.55)), lineWidth: 1.6)

            var needlePath = Path()
            needlePath.move(to: CGPoint(x: cx, y: top - 6))
            needlePath.addLine(to: CGPoint(x: cx, y: top + 18))
            context.stroke(needlePath, with: .color(needle),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

            if stops.indices.contains(index) {
                let big = Text(stops[index])
                    .font(.luma(size: 27, weight: .bold))
                    .kerning(-0.6)
                    .monospacedDigit()
                    .foregroundColor(LumaTheme.textPrimary)
                context.draw(big, at: CGPoint(x: cx, y: size.height - 26), anchor: .center)
            }
            if !title.isEmpty {
                let label = Text(title)
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.55))
                context.draw(label, at: CGPoint(x: 20, y: 10), anchor: .leading)
            }
        }
        .animation(.snappy(duration: 0.12), value: index)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let base = dragBase ?? index
                    if dragBase == nil { dragBase = index }
                    let steps = Int((-value.translation.width / pointsPerStop).rounded())
                    let target = min(max(base + steps, 0), max(stops.count - 1, 0))
                    if target != index { onChange(target) }
                }
                .onEnded { _ in dragBase = nil }
        )
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement()
        .accessibilityLabel(title.isEmpty ? "Value" : title)
        .accessibilityValue(stops.indices.contains(index) ? stops[index] : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < stops.count { onChange(index + 1) }
            case .decrement: if index > 0 { onChange(index - 1) }
            @unknown default: break
            }
        }
    }
}

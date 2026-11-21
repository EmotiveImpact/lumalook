import SwiftUI

/// Every look owns one signature colour. It fills the look's chip, rings its
/// tile and labels its clip on the timeline, so the interface takes the colour
/// of the grade you are using and the chrome itself can stay neutral.
///
/// Built-in looks have hand-picked colours. Pack looks, imports and saved looks
/// are matched by name first, then read from their recipe (warm, cool, mono,
/// magenta), so a colour is always stable for the same look.
enum LookSignature {
    // MARK: Palette

    static let golden = Color(hex: 0xFFB547)
    static let neon = Color(hex: 0xFF3DB4)
    static let nightDrive = Color(hex: 0xFF4B3E)
    static let rain = Color(hex: 0x8DB3D6)
    static let afro = Color(hex: 0xFF8A3D)
    static let teal = Color(hex: 0x2EC4B6)
    static let negative = Color(hex: 0xC9A27E)
    static let luxury = Color(hex: 0xD4AF6A)
    static let neutral = Color(hex: 0xE8E2D6)
    static let mono = Color(hex: 0xC8C8C8)
    static let green = Color(hex: 0x86C98B)
    static let blue = Color(hex: 0x7C9CFF)
    static let rose = Color(hex: 0xFF8FB8)

    /// Name keywords, checked in order, so "Night Drive" wins over "night".
    private static let keywords: [(String, Color)] = [
        ("golden", golden), ("neon", neon), ("night drive", nightDrive),
        ("london rain", rain), ("afrobeats", afro), ("teal", teal),
        ("cine negative", negative), ("luxury", luxury), ("clean neutral", neutral),
        ("documentary", mono), ("grit", mono), ("b&w", mono), ("mono", mono),
        ("noir", mono), ("silver", mono), ("meadow", green), ("green", green),
        ("forest", green), ("rain", rain), ("blue", blue), ("cyber", neon),
        ("pink", rose), ("rose", rose), ("blush", rose), ("orange", afro),
        ("sunset", afro), ("sun", golden), ("amber", golden), ("warm", golden),
        ("faded", negative), ("album", negative), ("portra", negative),
        ("chrome", rain), ("cool", rain), ("neutral", neutral), ("clean", neutral),
    ]

    /// The look's colour, from its name and (when known) its recipe.
    static func colour(name: String, recipe: LookRecipe? = nil) -> Color {
        let lower = name.lowercased()
        for (word, colour) in keywords where lower.contains(word) { return colour }
        guard let recipe else { return neutral }
        return colour(for: recipe)
    }

    /// A built-in look's hand-picked colour, else the name and keyword match.
    static func colour(forLookNamed name: String) -> Color {
        if let preset = MockData.looks.first(where: { $0.name == name }) { return preset.signature }
        return colour(name: name)
    }

    /// Reads a recipe: low saturation is mono, a strong tint is magenta or
    /// teal, then warm, neutral or cool by white balance.
    static func colour(for recipe: LookRecipe) -> Color {
        if recipe.saturation < 0.78 { return mono }
        if recipe.tint > 14 { return neon }
        if recipe.tint < -12 { return teal }
        switch recipe.temperature {
        case ..<5200: return golden
        case ..<6000: return afro
        case ..<6300: return luxury
        case ..<7000: return neutral
        case ..<8000: return rain
        default: return blue
        }
    }

    /// "KD2" from "KD2 · Golden Hour"; nil for a name with no stock code.
    static func code(in name: String) -> String? {
        guard let range = name.range(of: " · ") else { return nil }
        let head = String(name[..<range.lowerBound])
        guard head.count <= 6, head.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        return head
    }

    /// "Golden Hour" from "KD2 · Golden Hour"; the whole name otherwise.
    static func title(in name: String) -> String {
        guard code(in: name) != nil, let range = name.range(of: " · ") else { return name }
        return String(name[range.upperBound...])
    }
}

extension LookPreset {
    var signature: Color { LookSignature.colour(name: name, recipe: recipe) }
    var code: String? { LookSignature.code(in: name) }
    var title: String { LookSignature.title(in: name) }
}

extension PackLook {
    var signature: Color { LookSignature.colour(name: name, recipe: cubeFile == nil ? recipe : nil) }
}

extension LibraryLook {
    var signature: Color {
        switch source {
        case .builtIn(let preset): return preset.signature
        case .saved(let saved):
            let base = MockData.looks.first { $0.name == saved.baseLookName }
            return base?.signature ?? LookSignature.colour(name: saved.name)
        case .lut(let file): return LookSignature.colour(name: file.displayName)
        }
    }
}

// MARK: - Look chip

/// The current look, filled with its signature colour. Used on the cameras,
/// editor clips, the grade room and Home.
struct LookChip: View {
    let name: String
    var colour: Color = LumaTheme.signal
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: size * 0.45) {
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: size * 0.45, height: size * 0.45)
            Text(name)
                .font(.luma(size: size, weight: .semibold))
                .kerning(-0.1)
                .lineLimit(1)
        }
        .foregroundStyle(Color(hex: 0x0B0B0C))
        .padding(.horizontal, size * 0.9)
        .padding(.vertical, size * 0.36)
        .background(colour, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Look: \(name)")
    }
}

// MARK: - Readout cell

/// One live value in a readout row (Look 75%, Lens 24 mm, Shutter 1/48,
/// ISO 800). Tapping a cell puts it on the ruler; the active cell turns signal.
struct ReadoutCell: View {
    let label: String
    let value: String
    var dimmed: Bool = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(active ? LumaTheme.signal : LumaTheme.textMuted)
                Text(value)
                    .font(.luma(size: 17, weight: .semibold))
                    .kerning(-0.3)
                    .monospacedDigit()
                    .foregroundStyle(active ? LumaTheme.signal : LumaTheme.textPrimary.opacity(dimmed ? 0.55 : 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(active ? LumaTheme.signal.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(active ? LumaTheme.signal.opacity(0.3) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Ruler

/// A physical ruler: labelled stops with fine ticks between them, dragged
/// under a fixed glowing needle. Light haptic on every stop. Index based, so
/// lens, shutter, ISO and look strength all share one control.
struct LumaRuler: View {
    let stops: [String]
    let index: Int
    var needle: Color = LumaTheme.signal
    let onChange: (Int) -> Void

    /// Distance between labelled stops.
    private let spacing: CGFloat = 64
    /// Fine ticks between two labelled stops.
    private let minorTicks = 5
    @State private var dragBase: Int?

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, size in
                let mid = size.width / 2
                let origin = mid - CGFloat(index) * spacing
                let count = stops.count
                guard count > 0 else { return }
                // Fine ticks run past both ends so the strip never looks cut off.
                let step = spacing / CGFloat(minorTicks)
                var x = origin - spacing
                let end = origin + CGFloat(count) * spacing
                var fine = Path()
                while x <= end {
                    if x > -step, x < size.width + step {
                        fine.move(to: CGPoint(x: x, y: 8))
                        fine.addLine(to: CGPoint(x: x, y: 17))
                    }
                    x += step
                }
                context.stroke(fine, with: .color(.white.opacity(0.3)), lineWidth: 1)

                for i in 0..<count {
                    let sx = origin + CGFloat(i) * spacing
                    guard sx > -spacing, sx < size.width + spacing else { continue }
                    var major = Path()
                    major.move(to: CGPoint(x: sx, y: 4))
                    major.addLine(to: CGPoint(x: sx, y: 22))
                    context.stroke(major, with: .color(.white.opacity(0.72)), lineWidth: 1.5)
                    let current = i == index
                    let label = Text(stops[i])
                        .font(.luma(size: 12, weight: current ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundColor(current ? LumaTheme.textPrimary : LumaTheme.textSecondary)
                    context.draw(label, at: CGPoint(x: sx, y: 36), anchor: .center)
                }
            }
            .animation(.snappy(duration: 0.12), value: index)

            Capsule()
                .fill(needle)
                .frame(width: 2.5, height: 28)
                .shadow(color: needle.opacity(0.8), radius: 6)
                .allowsHitTesting(false)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.2),
                .init(color: .black, location: 0.8),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let base = dragBase ?? index
                    if dragBase == nil { dragBase = index }
                    let steps = Int((-value.translation.width / (spacing * 0.6)).rounded())
                    let target = min(max(base + steps, 0), max(stops.count - 1, 0))
                    if target != index { onChange(target) }
                }
                .onEnded { _ in dragBase = nil }
        )
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement()
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

// MARK: - Continuous ruler

/// The strength ruler: fine ticks every 2.5, labelled every 25, dragged
/// continuously under a needle in the look's colour. Light haptic every 5.
struct LumaStrengthRuler: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var needle: Color = LumaTheme.signal

    @State private var dragStart: Double?
    private let pointsPerUnit: CGFloat = 2.6
    private var detent: Int { Int(value / 5) }

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, size in
                let mid = size.width / 2
                var unit = range.lowerBound
                var fine = Path()
                var major = Path()
                while unit <= range.upperBound + 0.001 {
                    let x = mid + CGFloat(unit - value) * pointsPerUnit
                    if x > -20, x < size.width + 20 {
                        let isMajor = Int(unit.rounded()) % 25 == 0
                        if isMajor {
                            major.move(to: CGPoint(x: x, y: 4))
                            major.addLine(to: CGPoint(x: x, y: 22))
                            let label = Text("\(Int(unit.rounded()))")
                                .font(.luma(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(LumaTheme.textSecondary)
                            context.draw(label, at: CGPoint(x: x, y: 36), anchor: .center)
                        } else {
                            fine.move(to: CGPoint(x: x, y: 8))
                            fine.addLine(to: CGPoint(x: x, y: 17))
                        }
                    }
                    unit += 2.5
                }
                context.stroke(fine, with: .color(.white.opacity(0.3)), lineWidth: 1)
                context.stroke(major, with: .color(.white.opacity(0.72)), lineWidth: 1.5)
            }
            Capsule()
                .fill(needle)
                .frame(width: 2.5, height: 28)
                .shadow(color: needle.opacity(0.8), radius: 6)
                .allowsHitTesting(false)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.2),
                .init(color: .black, location: 0.8),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
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
        .accessibilityLabel("Strength")
        .accessibilityValue("\(Int(value.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            value = min(max(range.lowerBound, value + step), range.upperBound)
        }
    }
}

// MARK: - Glass pill

extension View {
    /// The small dark glass pill used for HUD values over footage
    /// (4K · 24 · HEVC, the recording timer, zoom).
    func lumaGlassPill() -> some View {
        self
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color(hex: 0x0C0C0E).opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 1))
    }
}

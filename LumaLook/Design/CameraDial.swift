import SwiftUI

// =============================================================================
// Camera A's own parts: the dial that curves over the shutter, the look ring,
// the thumb fan of tools and the Pro panel's tool tiles. Same tokens and type
// voice as the rest of the app; signal yellow marks what is live.
// =============================================================================

// MARK: - The dial over the shutter

/// One big dial on an arc centred on the shutter. Drag sideways to turn it;
/// drag up to pull up the Pro panel. Index based, so the lens, shutter, ISO,
/// white balance, exposure, focus and look strength all share it.
struct CameraArcDial: View {
    let ticks: [String]
    let index: Int
    /// How far below this view's bottom edge the arc's centre sits (the
    /// shutter's centre), so the dial wraps the shutter.
    var centreBelow: CGFloat = 71
    var radius: CGFloat = 168
    let onChange: (Int) -> Void
    var onPullUp: (() -> Void)? = nil

    @State private var dragF: Double?
    @State private var dragBase: Double?
    @State private var axis: Axis?
    @State private var pulled = false

    private var stepDegrees: Double {
        let n = max(ticks.count - 1, 1)
        return min(18, max(9, 130 / Double(n)))
    }

    var body: some View {
        let f = dragF ?? Double(index)
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height + centreBelow
            let r = radius
            let step = stepDegrees
            // Labels every stop when there is room on the arc, else every other.
            let gap = step * .pi / 180 * Double(r + 17)
            let every = gap < 40 ? 2 : 1
            let current = Int(f.rounded())
            // Keep everything above this view's bottom edge, clear of the
            // mode names under it.
            let minSin = Double(centreBelow + 6) / Double(r + 20)
            for i in ticks.indices {
                for m in 0..<4 {
                    if m > 0 && i == ticks.count - 1 { break }
                    let a = 90 - (Double(i) + Double(m) / 4 - f) * step
                    let th = a * .pi / 180
                    guard sin(th) > minSin, a > 12, a < 168 else { continue }
                    let major = m == 0
                    let fade = pow(max(0, 1 - abs(a - 90) / 80), 0.8)
                    let r1 = r - (major ? 11 : 6)
                    var tick = Path()
                    tick.move(to: CGPoint(x: cx + r1 * CGFloat(cos(th)), y: cy - r1 * CGFloat(sin(th))))
                    tick.addLine(to: CGPoint(x: cx + r * CGFloat(cos(th)), y: cy - r * CGFloat(sin(th))))
                    context.stroke(tick, with: .color(.white.opacity(fade * (major ? 0.95 : 0.5))),
                                   style: StrokeStyle(lineWidth: major ? 1.6 : 1.1, lineCap: .round))
                    if major && (i % every == 0 || i == current) {
                        let rl = r + 17
                        let on = i == current
                        let label = Text(ticks[i])
                            .font(.luma(size: 12, weight: on ? .semibold : .medium))
                            .monospacedDigit()
                            .foregroundColor(on ? LumaTheme.signal : .white.opacity(fade * 0.75))
                        context.draw(label, at: CGPoint(x: cx + rl * CGFloat(cos(th)),
                                                        y: cy - rl * CGFloat(sin(th))), anchor: .center)
                    }
                }
            }
            // The needle, at the top of the arc.
            var needle = Path()
            needle.move(to: CGPoint(x: cx, y: cy - r + 16))
            needle.addLine(to: CGPoint(x: cx, y: cy - r - 2))
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: LumaTheme.signal.opacity(0.9), radius: 5))
                layer.stroke(needle, with: .color(LumaTheme.signal),
                             style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let dx = value.translation.width, dy = value.translation.height
                    if axis == nil, hypot(dx, dy) > 6 {
                        axis = abs(dy) > abs(dx) * 1.2 ? .vertical : .horizontal
                    }
                    switch axis {
                    case .vertical:
                        if dy < -30, !pulled {
                            pulled = true
                            onPullUp?()
                        }
                    case .horizontal:
                        let base = dragBase ?? Double(index)
                        if dragBase == nil { dragBase = base }
                        let degrees = Double(dx / radius) * 180 / .pi
                        let n = Double(max(ticks.count - 1, 0))
                        let next = min(max(base - degrees / stepDegrees, 0), n)
                        dragF = next
                        let snapped = Int(next.rounded())
                        if snapped != index { onChange(snapped) }
                    case nil:
                        break
                    }
                }
                .onEnded { _ in
                    withAnimation(.snappy(duration: 0.18)) { dragF = nil }
                    dragBase = nil
                    axis = nil
                    pulled = false
                }
        )
        .animation(.snappy(duration: 0.14), value: index)
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement()
        .accessibilityValue(ticks.indices.contains(index) ? ticks[index] : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < ticks.count { onChange(index + 1) }
            case .decrement: if index > 0 { onChange(index - 1) }
            @unknown default: break
            }
        }
    }
}

/// A chip over the dial: what the dial turns. The live one is filled signal.
struct CameraDialChip: View {
    let title: String
    let active: Bool
    var manual: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.luma(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if manual && !active {
                    // A value you set by hand keeps a small dot, so manual
                    // settings never hide behind another chip.
                    Circle().fill(LumaTheme.signal).frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(active ? LumaTheme.onSignal : Color.white.opacity(0.72))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                if active {
                    Capsule().fill(LumaTheme.signal)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(Color(hex: 0x0C0D0F).opacity(0.4))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - The look ring

/// The look on the picture: a ring in the look's colour that fills with its
/// strength, a gap at the bottom, the stock code inside.
struct CameraLookRing: View {
    let code: String
    let colour: Color
    /// 0...1
    let strength: Double
    var size: CGFloat = 42

    var body: some View {
        let line = max(2.5, size * 0.075)
        let sweep = 0.82
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(90 + (1 - sweep) * 180))
                .padding(line / 2)
            Circle()
                .trim(from: 0, to: sweep * min(max(strength, 0), 1))
                .stroke(colour, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(90 + (1 - sweep) * 180))
                .padding(line / 2)
                .shadow(color: colour.opacity(strength > 0 ? 0.7 : 0), radius: 4)
            Text(code)
                .font(.luma(size: size * Self.codeScale(code.count), weight: .bold))
                .kerning(code.count > 4 ? -0.2 : 0)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, size * 0.14)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: strength)
    }

    /// Longer codes set smaller, so "CP2383" fits the ring as well as "KD2".
    private static func codeScale(_ length: Int) -> CGFloat {
        switch length {
        case ...4: return 0.29
        case 5:    return 0.25
        case 6:    return 0.205
        default:   return 0.18
        }
    }
}

// MARK: - The thumb fan

/// One tool in the fan.
struct CameraFanItem: Identifiable {
    let id: String
    let symbol: String
    let label: String
    let on: Bool
}

/// Press and hold anywhere: the tools fan out on an arc above the thumb.
/// Slide onto one and let go to use it.
struct CameraToolFan: View {
    /// Where the finger is.
    let touch: CGPoint
    /// The fan's centre (the touch, kept clear of the screen edges).
    let centre: CGPoint
    let items: [CameraFanItem]
    let positions: [CGPoint]
    let hot: Int?

    @State private var shown = false

    static let radius: CGFloat = 140

    /// Bubble centres on an arc above `centre`, from 170° round to 10°.
    static func layout(centre: CGPoint, count: Int, radius: CGFloat = CameraToolFan.radius) -> [CGPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let degrees = count == 1 ? 90 : 170 - Double(i) * 160 / Double(count - 1)
            let t = degrees * .pi / 180
            return CGPoint(x: centre.x + radius * CGFloat(cos(t)),
                           y: centre.y - radius * CGFloat(sin(t)))
        }
    }

    /// The fan's centre for a touch, clamped so every bubble stays on screen.
    static func centre(for touch: CGPoint, in size: CGSize) -> CGPoint {
        let margin = radius + 30
        let x = min(max(touch.x, margin), max(margin, size.width - margin))
        let y = min(max(touch.y, radius + 70), max(radius + 70, size.height - 60))
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack {
            RadialGradient(colors: [.black.opacity(0.6), .black.opacity(0.25), .clear],
                           center: UnitPoint(x: 0.5, y: 0.5), startRadius: 0, endRadius: 330)
                .frame(width: 660, height: 660)
                .position(centre)
            Circle()
                .fill(Color.white.opacity(0.18))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 2))
                .shadow(color: .white.opacity(0.35), radius: 12)
                .frame(width: 56, height: 56)
                .position(touch)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let isHot = hot == i
                Image(systemName: item.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isHot ? LumaTheme.onSignal : (item.on ? LumaTheme.signal : .white))
                    .frame(width: 46, height: 46)
                    .background {
                        if isHot {
                            Circle().fill(LumaTheme.signal)
                        } else {
                            Circle().fill(.ultraThinMaterial)
                            Circle().fill(Color(hex: 0x16171B).opacity(0.82))
                        }
                    }
                    .overlay {
                        if item.on && !isHot {
                            Circle().strokeBorder(LumaTheme.signal.opacity(0.8), lineWidth: 2)
                        }
                    }
                    .shadow(color: isHot ? LumaTheme.signal.opacity(0.6) : .black.opacity(0.35),
                            radius: isHot ? 9 : 8, y: isHot ? 0 : 4)
                    .scaleEffect(isHot ? 1.2 : (shown ? 1 : 0.4))
                    .opacity(shown ? 1 : 0)
                    .position(shown ? positions[i] : centre)
                    .animation(.spring(response: 0.26, dampingFraction: 0.78).delay(Double(i) * 0.018), value: shown)
                    .animation(.easeOut(duration: 0.12), value: isHot)
            }
            if let hot, items.indices.contains(hot) {
                Text(items[hot].label)
                    .font(.luma(size: 13, weight: .bold))
                    .foregroundStyle(LumaTheme.signal)
                    .shadow(color: .black.opacity(0.7), radius: 3)
                    .fixedSize()
                    .position(x: positions[hot].x, y: positions[hot].y - 48)
            }
        }
        .allowsHitTesting(false)
        .onAppear { shown = true }
    }
}

// MARK: - Pro panel tiles

/// A tool in the Pro panel: an icon over its name, lit signal when on.
struct CameraToolTile: View {
    let symbol: String
    let label: String
    var on: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 22)
                Text(label)
                    .font(.luma(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(on ? LumaTheme.signal : Color.white.opacity(0.78))
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(on ? LumaTheme.signal.opacity(0.15) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

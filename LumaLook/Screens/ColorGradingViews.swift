import SwiftUI

// MARK: - Curve editor (RGB + per-channel)

/// Draggable tone-curve editor. Tap empty space to add a point, drag to move,
/// drag a point off the canvas to delete. Channel picker switches Master/R/G/B.
struct CurveEditorPanel: View {
    @Binding var curves: CurveSet?
    @State private var channel = 0   // 0 master, 1 R, 2 G, 3 B

    private let channelNames = ["RGB", "R", "G", "B"]
    private let channelTints: [Color] = [.white, .red, .green, .blue]

    private var points: [CurvePoint] {
        let c = curves ?? CurveSet()
        switch channel {
        case 1: return c.red; case 2: return c.green; case 3: return c.blue
        default: return c.master
        }
    }

    private func setPoints(_ pts: [CurvePoint]) {
        var c = curves ?? CurveSet()
        let sorted = pts.sorted { $0.x < $1.x }
        switch channel {
        case 1: c.red = sorted; case 2: c.green = sorted; case 3: c.blue = sorted
        default: c.master = sorted
        }
        curves = c.isIdentity ? nil : c
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    Button {
                        channel = i
                        LumaHaptics.shared.tap()
                    } label: {
                        Text(channelNames[i])
                            .font(.luma(size: 13, weight: .bold))
                            .foregroundStyle(channel == i ? .white : LumaTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(channel == i ? channelTints[i].opacity(0.28) : LumaTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(channel == i ? channelTints[i] : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            CurveCanvas(points: Binding(get: { points }, set: setPoints),
                        tint: channelTints[channel])
                .aspectRatio(1, contentMode: .fit)

            HStack {
                Text("Tap to add a point · drag off to delete")
                    .font(.luma(.footnote))
                    .foregroundStyle(LumaTheme.textMuted)
                Spacer()
                Button("Reset") { setPoints([]) }
                    .font(.luma(.footnote, weight: .semibold))
                    .foregroundStyle(LumaTheme.accentBright)
                    .disabled(points.isEmpty)
            }
        }
    }
}

private struct CurveCanvas: View {
    @Binding var points: [CurvePoint]
    let tint: Color
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(LumaTheme.bar)
                // Grid.
                Path { p in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        p.move(to: CGPoint(x: f * size.width, y: 0))
                        p.addLine(to: CGPoint(x: f * size.width, y: size.height))
                        p.move(to: CGPoint(x: 0, y: f * size.height))
                        p.addLine(to: CGPoint(x: size.width, y: f * size.height))
                    }
                }.stroke(.white.opacity(0.06), lineWidth: 1)
                // Identity diagonal.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    p.addLine(to: CGPoint(x: size.width, y: 0))
                }.stroke(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                // Curve.
                Path { p in
                    let samples = ColorMath.curveSamples(points, count: 128)
                    for (i, y) in samples.enumerated() {
                        let px = CGFloat(i) / CGFloat(samples.count - 1) * size.width
                        let py = (1 - CGFloat(y)) * size.height
                        if i == 0 { p.move(to: CGPoint(x: px, y: py)) }
                        else { p.addLine(to: CGPoint(x: px, y: py)) }
                    }
                }.stroke(tint, lineWidth: 2.5)
                // Control points.
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(tint)
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                        .position(x: CGFloat(points[i].x) * size.width,
                                  y: (1 - CGFloat(points[i].y)) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = Double(min(max(0, value.location.x / size.width), 1))
                        let y = Double(min(max(0, 1 - value.location.y / size.height), 1))
                        if dragging == nil {
                            // Grab nearest point within tolerance, else create.
                            if let near = nearestPoint(to: value.location, in: size), near.dist < 28 {
                                dragging = near.index
                            } else {
                                var pts = points.isEmpty ? defaultPoints() : points
                                pts.append(CurvePoint(x: x, y: y))
                                points = pts
                                dragging = pts.firstIndex { $0.x == x && $0.y == y }
                            }
                        }
                        guard let d = dragging, points.indices.contains(d) else { return }
                        var pts = points
                        pts[d] = CurvePoint(x: x, y: y)
                        points = pts
                    }
                    .onEnded { value in
                        // Drag off the canvas edge (and not an endpoint) → delete.
                        if let d = dragging, points.count > 2,
                           value.location.y < -20 || value.location.y > size.height + 20 {
                            var pts = points; pts.remove(at: d); points = pts
                            LumaHaptics.shared.tap()
                        }
                        dragging = nil
                    }
            )
        }
    }

    private func defaultPoints() -> [CurvePoint] {
        [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    }

    private func nearestPoint(to loc: CGPoint, in size: CGSize) -> (index: Int, dist: CGFloat)? {
        var best: (Int, CGFloat)?
        for (i, pt) in points.enumerated() {
            let px = CGFloat(pt.x) * size.width
            let py = (1 - CGFloat(pt.y)) * size.height
            let d = hypot(px - loc.x, py - loc.y)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best.map { ($0.0, $0.1) }
    }
}

// MARK: - 3-way colour wheels (lift / gamma / gain)

struct ColorWheelsPanel: View {
    @Binding var wheels: ColorWheels?

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                ColorWheelPad(zone: .lift, wheels: bindingOrDefault)
                ColorWheelPad(zone: .gamma, wheels: bindingOrDefault)
                ColorWheelPad(zone: .gain, wheels: bindingOrDefault)
            }
            VStack(spacing: 14) {
                ColorWheelMasterSlider(zone: .lift, wheels: bindingOrDefault)
                ColorWheelMasterSlider(zone: .gamma, wheels: bindingOrDefault)
                ColorWheelMasterSlider(zone: .gain, wheels: bindingOrDefault)
            }
            Button("Reset wheels") { wheels = nil }
                .font(.luma(.footnote, weight: .semibold))
                .foregroundStyle(LumaTheme.accentBright)
                .disabled(wheels?.isIdentity ?? true)
        }
    }

    private var bindingOrDefault: Binding<ColorWheels> {
        Binding(
            get: { wheels ?? ColorWheels() },
            set: { wheels = $0.isIdentity ? nil : $0 }
        )
    }
}

enum WheelZone { case lift, gamma, gain
    var title: String { self == .lift ? "Lift" : self == .gamma ? "Gamma" : "Gain" }
    var range: ClosedRange<Double> { self == .lift ? -0.2...0.2 : self == .gamma ? 0.4...2.2 : 0.5...2.0 }
    var neutral: Double { self == .lift ? 0 : 1 }
}

/// The Lift/Gamma/Gain master (luma) slider, decomposed from the triple.
private struct ColorWheelMasterSlider: View {
    let zone: WheelZone
    @Binding var wheels: ColorWheels

    var body: some View {
        InlineSlider(title: zone.title, value: binding, range: zone.range) {
            zone == .lift ? String(format: "%+.2f", $0) : String(format: "%.2f", $0)
        }
    }

    private var triple: (Double, Double, Double) {
        switch zone {
        case .lift: return (wheels.liftR, wheels.liftG, wheels.liftB)
        case .gamma: return (wheels.gammaR, wheels.gammaG, wheels.gammaB)
        case .gain: return (wheels.gainR, wheels.gainG, wheels.gainB)
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: { let t = triple; return (t.0 + t.1 + t.2) / 3 },
            set: { newMean in
                let t = triple
                let mean = (t.0 + t.1 + t.2) / 3
                let nt = [t.0 - mean + newMean, t.1 - mean + newMean, t.2 - mean + newMean]
                switch zone {
                case .lift: wheels.liftR = nt[0]; wheels.liftG = nt[1]; wheels.liftB = nt[2]
                case .gamma: wheels.gammaR = nt[0]; wheels.gammaG = nt[1]; wheels.gammaB = nt[2]
                case .gain: wheels.gainR = nt[0]; wheels.gainG = nt[1]; wheels.gainB = nt[2]
                }
            }
        )
    }
}

/// A colour-balance trackpad (R/G/B primaries 120° apart) — chroma only; the
/// master luma lives in the stacked slider below.
private struct ColorWheelPad: View {
    let zone: WheelZone
    @Binding var wheels: ColorWheels

    // Primary screen angles (deg): R up, G lower-left, B lower-right.
    private let primaryAngles: [Double] = [90, 210, 330]

    var body: some View {
        VStack(spacing: 8) {
            Text(zone.title)
                .font(.luma(size: 12, weight: .semibold))
                .foregroundStyle(LumaTheme.textSecondary)
            let diameter: CGFloat = 92
            let center = CGPoint(x: diameter / 2, y: diameter / 2)
            let puck = puckPosition(center: center, radius: diameter / 2)
            ZStack {
                Circle().fill(AngularGradient(
                    colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                    center: .center)).opacity(0.5)
                Circle().stroke(.white.opacity(0.15), lineWidth: 1)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .position(puck)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                setBalance(from: v.location, center: center, radius: diameter / 2)
            })
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: balance (chroma) <-> triple

    private var triple: (r: Double, g: Double, b: Double) {
        switch zone {
        case .lift: return (wheels.liftR, wheels.liftG, wheels.liftB)
        case .gamma: return (wheels.gammaR, wheels.gammaG, wheels.gammaB)
        case .gain: return (wheels.gainR, wheels.gainG, wheels.gainB)
        }
    }

    private var neutral: Double { zone == .lift ? 0 : 1 }

    private func balance() -> (Double, Double, Double) {
        let t = triple
        let mean = (t.r + t.g + t.b) / 3
        return (t.r - mean, t.g - mean, t.b - mean)
    }

    private func puckPosition(center: CGPoint, radius: CGFloat) -> CGPoint {
        let (br, bg, bb) = balance()
        var x = 0.0, y = 0.0
        let bals = [br, bg, bb]
        for (i, a) in primaryAngles.enumerated() {
            x += bals[i] * cos(a * .pi / 180)
            y += bals[i] * sin(a * .pi / 180)
        }
        // scale: balance magnitude ~ (2/3)*amp; invert.
        let scale = radius / 0.28
        return CGPoint(x: center.x + CGFloat(x) * scale * 1.5,
                       y: center.y - CGFloat(y) * scale * 1.5)
    }

    private func setBalance(from loc: CGPoint, center: CGPoint, radius: CGFloat) {
        var dx = Double(loc.x - center.x) / Double(radius)
        var dy = Double(center.y - loc.y) / Double(radius)   // up = +
        let mag = (dx * dx + dy * dy).squareRoot()
        if mag > 1 { dx /= mag; dy /= mag }
        let amp = 0.28   // max chroma offset
        let angle = atan2(dy, dx)
        let radiusN = min(1, mag)
        var newTriple = [neutral, neutral, neutral]
        for (i, a) in primaryAngles.enumerated() {
            let contrib = cos(angle - a * .pi / 180) * radiusN * amp
            newTriple[i] = neutral + master() + (zone == .gamma ? -contrib : contrib)
        }
        // Re-centre luma so the master stays orthogonal to chroma.
        applyTriple(newTriple)
    }

    private func applyTriple(_ t: [Double]) {
        switch zone {
        case .lift: wheels.liftR = t[0]; wheels.liftG = t[1]; wheels.liftB = t[2]
        case .gamma: wheels.gammaR = clampG(t[0]); wheels.gammaG = clampG(t[1]); wheels.gammaB = clampG(t[2])
        case .gain: wheels.gainR = t[0]; wheels.gainG = t[1]; wheels.gainB = t[2]
        }
    }
    private func clampG(_ v: Double) -> Double { min(3, max(0.2, v)) }

    private func master() -> Double {
        let t = triple; return (t.r + t.g + t.b) / 3 - neutral
    }

    private var masterRange: ClosedRange<Double> {
        zone == .lift ? -0.2...0.2 : zone == .gamma ? 0.4...2.2 : 0.5...2.0
    }

    private var masterBinding: Binding<Double> {
        Binding(
            get: { zone == .lift ? neutral + master() : (triple.r + triple.g + triple.b) / 3 },
            set: { newMean in
                let (br, bg, bb) = balance()
                let bals = [br, bg, bb]
                var nt = [Double](repeating: 0, count: 3)
                for i in 0..<3 { nt[i] = newMean + bals[i] }
                applyTriple(nt)
            }
        )
    }
}

// MARK: - Split toning

struct SplitTonePanel: View {
    @Binding var tone: SplitTone?

    var body: some View {
        VStack(spacing: 20) {
            toneZone("Shadows", hue: hueBinding(\.shadowHue), sat: satBinding(\.shadowSat))
            toneZone("Highlights", hue: hueBinding(\.highlightHue), sat: satBinding(\.highlightSat))
            InlineSlider(title: "Balance", value: balanceBinding, range: -1...1) {
                $0 < -0.05 ? "Shadows" : $0 > 0.05 ? "Highlights" : "Even"
            }
            Button("Reset split tone") { tone = nil }
                .font(.luma(.footnote, weight: .semibold))
                .foregroundStyle(LumaTheme.accentBright)
                .disabled(tone?.isIdentity ?? true)
        }
    }

    private func toneZone(_ label: String, hue: Binding<Double>, sat: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.luma(.subheadline, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Circle().fill(Color(hue: hue.wrappedValue / 360, saturation: 0.9, brightness: 0.95))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                    .opacity(0.35 + sat.wrappedValue * 0.65)
            }
            // Hue slider over a rainbow track.
            Slider(value: hue, in: 0...360)
                .tint(Color(hue: hue.wrappedValue / 360, saturation: 0.9, brightness: 0.95))
                .background(
                    LinearGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.9) },
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 4).clipShape(Capsule()).padding(.horizontal, 2)
                        .allowsHitTesting(false))
            InlineSlider(title: "Strength", value: Binding(get: { sat.wrappedValue * 100 },
                                                           set: { sat.wrappedValue = $0 / 100 })) { "\(Int($0))" }
        }
    }

    private func hueBinding(_ key: WritableKeyPath<SplitTone, Double>) -> Binding<Double> {
        Binding(get: { (tone ?? SplitTone())[keyPath: key] },
                set: { var t = tone ?? SplitTone(); t[keyPath: key] = $0; tone = t.isIdentity ? nil : t })
    }
    private func satBinding(_ key: WritableKeyPath<SplitTone, Double>) -> Binding<Double> {
        Binding(get: { (tone ?? SplitTone())[keyPath: key] },
                set: { var t = tone ?? SplitTone(); t[keyPath: key] = max(0, min(1, $0)); tone = t.isIdentity ? nil : t })
    }
    private var balanceBinding: Binding<Double> {
        Binding(get: { (tone ?? SplitTone()).balance },
                set: { var t = tone ?? SplitTone(); t.balance = $0; tone = t.isIdentity ? nil : t })
    }
}

// MARK: - 8-band HSL secondary

struct HSLPanel: View {
    @Binding var hsl: HSLBands?
    @State private var band = 0

    private let bandTints: [Color] = [
        .red, .orange, .yellow, .green,
        Color(red: 0.2, green: 0.8, blue: 0.8), .blue,
        .purple, Color(red: 0.9, green: 0.2, blue: 0.6)]

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<8, id: \.self) { i in
                    Button {
                        band = i; LumaHaptics.shared.tap()
                    } label: {
                        Circle()
                            .fill(bandTints[i])
                            .frame(height: 26)
                            .overlay(Circle().stroke(.white, lineWidth: band == i ? 2.5 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(HSLBands.names[band])
                .font(.luma(.subheadline, weight: .semibold))
                .foregroundStyle(.white)

            InlineSlider(title: "Hue", value: comp(\.hue), range: -1...1) { String(format: "%+.0f°", $0 * 30) }
            InlineSlider(title: "Saturation", value: comp(\.sat), range: -1...1) { "\(Int($0 * 100))" }
            InlineSlider(title: "Luminance", value: comp(\.lum), range: -1...1) { "\(Int($0 * 100))" }

            Button("Reset HSL") { hsl = nil }
                .font(.luma(.footnote, weight: .semibold))
                .foregroundStyle(LumaTheme.accentBright)
                .disabled(hsl?.isIdentity ?? true)
        }
    }

    private func comp(_ key: WritableKeyPath<HSLBands, [Double]>) -> Binding<Double> {
        Binding(
            get: { (hsl ?? HSLBands())[keyPath: key][band] },
            set: { newValue in
                var b = hsl ?? HSLBands()
                b[keyPath: key][band] = newValue
                hsl = b.isIdentity ? nil : b
            }
        )
    }
}

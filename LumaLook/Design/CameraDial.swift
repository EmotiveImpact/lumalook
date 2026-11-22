import SwiftUI

// =============================================================================
// Camera Lab, option A ("one camera that grows"): the camera's own parts,
// measured from the lab Edem designed in. The lab was drawn on a 402 x 874
// screen; every size, weight and colour here is the lab's. Positions hang off
// the top safe area or the bottom edge, so other iPhones keep the same plate,
// dial and shutter.
// =============================================================================

// MARK: - Tokens

enum CamLab {
    static let ink = Color(hex: 0x08090A)
    static let panel = Color(hex: 0x111215)
    static let raised = Color(hex: 0x1F2025)
    static let text = Color(hex: 0xF7F8F8)
    static let grey = Color(hex: 0xA3A6AD)
    static let grey3 = Color(hex: 0x6E727A)
    static let label = Color(hex: 0x8A8E96)
    static let sig = Color(hex: 0xFFC53D)
    static let rec = Color(hex: 0xFF4538)

    /// The plate under the shutter, from the bottom edge of the screen.
    static let plateHeight: CGFloat = 100
    /// The shutter's centre, up from the bottom edge. The dial turns on it.
    static let shutterRise: CGFloat = 74
}

extension View {
    /// The lab's glass: the picture blurred behind a dark tint, no outline.
    func camGlass<S: Shape>(_ shape: S, tint: Color = Color(hex: 0x121316),
                            opacity: Double = 0.5) -> some View {
        background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(tint.opacity(opacity))
            }
        }
    }
}

// MARK: - Icons

/// The lab's line icons, each on a 24 pt grid.
enum CamIcon {
    case photo, video, slomo, portrait, flip, close, up, down, pro, format, guides
    case scope, zebras, peaking, grid, level, auto, lock, search, plus, rotate

    static func paths(_ icon: CamIcon) -> (solid: Path, dashed: Path, dash: [CGFloat]) {
        var solid = Path()
        var dashed = Path()
        let dash = draw(icon, into: &solid, dashed: &dashed)
        return (solid, dashed, dash)
    }

    /// The lab's own line icons, on a 24 pt grid (generated from its SVG paths).
    static func draw(_ icon: CamIcon, into p: inout Path, dashed d: inout Path) -> [CGFloat] {
        switch icon {
        case .photo:
            p.move(to: CGPoint(x: 4, y: 8.5))
            p.addCurve(to: CGPoint(x: 6.5, y: 6), control1: CGPoint(x: 4, y: 7.119), control2: CGPoint(x: 5.119, y: 6))
            p.addLine(to: CGPoint(x: 8.3, y: 6))
            p.addLine(to: CGPoint(x: 9.7, y: 4))
            p.addLine(to: CGPoint(x: 14.3, y: 4))
            p.addLine(to: CGPoint(x: 15.7, y: 6))
            p.addLine(to: CGPoint(x: 17.5, y: 6))
            p.addCurve(to: CGPoint(x: 20, y: 8.5), control1: CGPoint(x: 18.881, y: 6), control2: CGPoint(x: 20, y: 7.119))
            p.addLine(to: CGPoint(x: 20, y: 16.5))
            p.addCurve(to: CGPoint(x: 17.5, y: 19), control1: CGPoint(x: 20, y: 17.881), control2: CGPoint(x: 18.881, y: 19))
            p.addLine(to: CGPoint(x: 6.5, y: 19))
            p.addCurve(to: CGPoint(x: 4, y: 16.5), control1: CGPoint(x: 5.119, y: 19), control2: CGPoint(x: 4, y: 17.881))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 8.6, y: 9.1, width: 6.8, height: 6.8))
            return []
        case .video:
            p.addRoundedRect(in: CGRect(x: 3, y: 6.5, width: 12.5, height: 11), cornerSize: CGSize(width: 2.5, height: 2.5), style: .circular)
            p.move(to: CGPoint(x: 15.5, y: 10.5))
            p.addLine(to: CGPoint(x: 21, y: 7.5))
            p.addLine(to: CGPoint(x: 21, y: 16.5))
            p.addLine(to: CGPoint(x: 15.5, y: 13.5))
            return []
        case .slomo:
            p.move(to: CGPoint(x: 12, y: 8))
            p.addLine(to: CGPoint(x: 12, y: 12))
            p.addLine(to: CGPoint(x: 14.6, y: 13.8))
            d.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
            return [2.2, 2.6]
        case .portrait:
            p.addEllipse(in: CGRect(x: 8.4, y: 5.4, width: 7.2, height: 7.2))
            p.move(to: CGPoint(x: 5, y: 20))
            p.addCurve(to: CGPoint(x: 12, y: 14.6), control1: CGPoint(x: 6, y: 16.4), control2: CGPoint(x: 8.8, y: 14.6))
            p.addCurve(to: CGPoint(x: 19, y: 20), control1: CGPoint(x: 15.2, y: 14.6), control2: CGPoint(x: 18, y: 16.4))
            return []
        case .flip:
            p.move(to: CGPoint(x: 4.5, y: 10))
            p.addCurve(to: CGPoint(x: 10.147, y: 3.99), control1: CGPoint(x: 5.013, y: 7.049), control2: CGPoint(x: 7.233, y: 4.686))
            p.addCurve(to: CGPoint(x: 17.9, y: 6.8), control1: CGPoint(x: 13.06, y: 3.295), control2: CGPoint(x: 16.109, y: 4.399))
            p.move(to: CGPoint(x: 19.5, y: 14))
            p.addCurve(to: CGPoint(x: 13.853, y: 20.01), control1: CGPoint(x: 18.987, y: 16.951), control2: CGPoint(x: 16.767, y: 19.314))
            p.addCurve(to: CGPoint(x: 6.1, y: 17.2), control1: CGPoint(x: 10.94, y: 20.705), control2: CGPoint(x: 7.891, y: 19.601))
            p.move(to: CGPoint(x: 18.4, y: 3.6))
            p.addLine(to: CGPoint(x: 18.4, y: 7.5))
            p.addLine(to: CGPoint(x: 14.5, y: 7.5))
            p.move(to: CGPoint(x: 5.6, y: 20.4))
            p.addLine(to: CGPoint(x: 5.6, y: 16.5))
            p.addLine(to: CGPoint(x: 9.5, y: 16.5))
            return []
        case .close:
            p.move(to: CGPoint(x: 7, y: 7))
            p.addLine(to: CGPoint(x: 17, y: 17))
            p.move(to: CGPoint(x: 17, y: 7))
            p.addLine(to: CGPoint(x: 7, y: 17))
            return []
        case .up:
            p.move(to: CGPoint(x: 7, y: 14))
            p.addLine(to: CGPoint(x: 12, y: 9))
            p.addLine(to: CGPoint(x: 17, y: 14))
            return []
        case .down:
            p.move(to: CGPoint(x: 7, y: 10))
            p.addLine(to: CGPoint(x: 12, y: 15))
            p.addLine(to: CGPoint(x: 17, y: 10))
            return []
        case .pro:
            p.move(to: CGPoint(x: 4, y: 7))
            p.addLine(to: CGPoint(x: 13, y: 7))
            p.move(to: CGPoint(x: 19, y: 7))
            p.addLine(to: CGPoint(x: 20, y: 7))
            p.move(to: CGPoint(x: 4, y: 12))
            p.addLine(to: CGPoint(x: 7, y: 12))
            p.move(to: CGPoint(x: 13, y: 12))
            p.addLine(to: CGPoint(x: 20, y: 12))
            p.move(to: CGPoint(x: 4, y: 17))
            p.addLine(to: CGPoint(x: 15, y: 17))
            p.addEllipse(in: CGRect(x: 13.8, y: 4.8, width: 4.4, height: 4.4))
            p.addEllipse(in: CGRect(x: 7.8, y: 9.8, width: 4.4, height: 4.4))
            p.addEllipse(in: CGRect(x: 15.8, y: 14.8, width: 4.4, height: 4.4))
            return []
        case .format:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 8, width: 12, height: 10), cornerSize: CGSize(width: 2, height: 2), style: .circular)
            p.move(to: CGPoint(x: 8, y: 5))
            p.addLine(to: CGPoint(x: 18, y: 5))
            p.addCurve(to: CGPoint(x: 20, y: 7), control1: CGPoint(x: 19.105, y: 5), control2: CGPoint(x: 20, y: 5.895))
            p.addLine(to: CGPoint(x: 20, y: 15))
            return []
        case .guides:
            d.addRoundedRect(in: CGRect(x: 3.5, y: 6, width: 17, height: 12), cornerSize: CGSize(width: 2, height: 2), style: .circular)
            return [2.6, 2.4]
        case .scope:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 5, width: 17, height: 14), cornerSize: CGSize(width: 2.5, height: 2.5), style: .circular)
            p.move(to: CGPoint(x: 6.5, y: 15))
            p.addLine(to: CGPoint(x: 9, y: 11))
            p.addLine(to: CGPoint(x: 11.5, y: 14))
            p.addLine(to: CGPoint(x: 14, y: 8))
            p.addLine(to: CGPoint(x: 17.5, y: 15))
            return []
        case .zebras:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 5, width: 17, height: 14), cornerSize: CGSize(width: 2.5, height: 2.5), style: .circular)
            p.move(to: CGPoint(x: 7, y: 19))
            p.addLine(to: CGPoint(x: 15, y: 5))
            p.move(to: CGPoint(x: 12, y: 19))
            p.addLine(to: CGPoint(x: 20, y: 5.5))
            p.move(to: CGPoint(x: 3.5, y: 12.5))
            p.addLine(to: CGPoint(x: 7.8, y: 5))
            return []
        case .peaking:
            p.addEllipse(in: CGRect(x: 5, y: 5, width: 14, height: 14))
            p.addEllipse(in: CGRect(x: 10, y: 10, width: 4, height: 4))
            p.move(to: CGPoint(x: 12, y: 2.5))
            p.addLine(to: CGPoint(x: 12, y: 5.5))
            p.move(to: CGPoint(x: 12, y: 18.5))
            p.addLine(to: CGPoint(x: 12, y: 21.5))
            p.move(to: CGPoint(x: 2.5, y: 12))
            p.addLine(to: CGPoint(x: 5.5, y: 12))
            p.move(to: CGPoint(x: 18.5, y: 12))
            p.addLine(to: CGPoint(x: 21.5, y: 12))
            return []
        case .grid:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17), cornerSize: CGSize(width: 2.5, height: 2.5), style: .circular)
            p.move(to: CGPoint(x: 9.2, y: 3.5))
            p.addLine(to: CGPoint(x: 9.2, y: 20.5))
            p.move(to: CGPoint(x: 14.8, y: 3.5))
            p.addLine(to: CGPoint(x: 14.8, y: 20.5))
            p.move(to: CGPoint(x: 3.5, y: 9.2))
            p.addLine(to: CGPoint(x: 20.5, y: 9.2))
            p.move(to: CGPoint(x: 3.5, y: 14.8))
            p.addLine(to: CGPoint(x: 20.5, y: 14.8))
            return []
        case .level:
            p.move(to: CGPoint(x: 2.5, y: 12))
            p.addLine(to: CGPoint(x: 8, y: 12))
            p.move(to: CGPoint(x: 16, y: 12))
            p.addLine(to: CGPoint(x: 21.5, y: 12))
            p.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
            return []
        case .auto:
            p.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            p.move(to: CGPoint(x: 9, y: 16))
            p.addLine(to: CGPoint(x: 12, y: 8))
            p.addLine(to: CGPoint(x: 15, y: 16))
            p.move(to: CGPoint(x: 10.1, y: 13.4))
            p.addLine(to: CGPoint(x: 13.9, y: 13.4))
            return []
        case .lock:
            p.addRoundedRect(in: CGRect(x: 5, y: 11, width: 14, height: 10), cornerSize: CGSize(width: 2, height: 2), style: .circular)
            p.move(to: CGPoint(x: 8, y: 11))
            p.addLine(to: CGPoint(x: 8, y: 8))
            p.addCurve(to: CGPoint(x: 12, y: 4), control1: CGPoint(x: 8, y: 5.791), control2: CGPoint(x: 9.791, y: 4))
            p.addCurve(to: CGPoint(x: 16, y: 8), control1: CGPoint(x: 14.209, y: 4), control2: CGPoint(x: 16, y: 5.791))
            p.addLine(to: CGPoint(x: 16, y: 11))
            return []
        case .search:
            p.addEllipse(in: CGRect(x: 4.5, y: 4.5, width: 13, height: 13))
            p.move(to: CGPoint(x: 16, y: 16))
            p.addLine(to: CGPoint(x: 20.5, y: 20.5))
            return []
        case .plus:
            p.move(to: CGPoint(x: 12, y: 5))
            p.addLine(to: CGPoint(x: 12, y: 19))
            p.move(to: CGPoint(x: 5, y: 12))
            p.addLine(to: CGPoint(x: 19, y: 12))
            return []
        case .rotate:
            p.addRoundedRect(in: CGRect(x: 3.5, y: 8, width: 13, height: 9), cornerSize: CGSize(width: 2, height: 2), style: .circular)
            p.move(to: CGPoint(x: 14, y: 3.5))
            p.addCurve(to: CGPoint(x: 20.5, y: 10), control1: CGPoint(x: 17.59, y: 3.5), control2: CGPoint(x: 20.5, y: 6.41))
            p.move(to: CGPoint(x: 20.5, y: 7))
            p.addLine(to: CGPoint(x: 20.5, y: 10))
            p.addLine(to: CGPoint(x: 17.5, y: 10))
            return []
        }
    }
}

/// One lab icon, stroked in the current foreground colour. `weight` is the
/// stroke on the icon's own 24 pt grid, as the lab sets it.
struct CamGlyph: View {
    let icon: CamIcon
    var size: CGFloat = 20
    var weight: CGFloat = 1.8

    var body: some View {
        let parts = CamIcon.paths(icon)
        let scale = size / 24
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        ZStack {
            parts.solid.applying(transform)
                .stroke(style: StrokeStyle(lineWidth: weight * scale, lineCap: .round, lineJoin: .round))
            if !parts.dash.isEmpty {
                parts.dashed.applying(transform)
                    .stroke(style: StrokeStyle(lineWidth: weight * scale, lineCap: .round,
                                               lineJoin: .round, dash: parts.dash.map { $0 * scale }))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - The plate

/// The plate under the shutter: full width, round top corners, and a notch
/// that wraps the shutter (a circle of radius 44 round the shutter's centre,
/// which sits 26 pt below the plate's top edge).
struct CamPlateShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = w / 2
        let cy: CGFloat = 26, r: CGFloat = 44, shoulder: CGFloat = 16, corner: CGFloat = 22
        let dy = shoulder - cy
        let dx = sqrt(max(r * r - dy * dy, 0))
        var path = Path()
        path.move(to: CGPoint(x: 0, y: corner))
        path.addQuadCurve(to: CGPoint(x: corner, y: 0), control: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: cx - dx - shoulder, y: 0))
        path.addQuadCurve(to: CGPoint(x: cx - dx, y: shoulder), control: CGPoint(x: cx - dx, y: 0))
        // Round the shutter, through the bottom of the notch.
        let start = atan2(Double(dy), Double(-dx)) + 2 * Double.pi
        let end = atan2(Double(dy), Double(dx))
        let steps = 56
        for step in 1...steps {
            let a = start + (end - start) * Double(step) / Double(steps)
            path.addLine(to: CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a))))
        }
        path.addQuadCurve(to: CGPoint(x: cx + dx + shoulder, y: 0), control: CGPoint(x: cx + dx, y: 0))
        path.addLine(to: CGPoint(x: w - corner, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: corner), control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.closeSubpath()
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The plate's fill: panel grey with a soft glow in the look's colour rising
/// from the bottom left.
struct CamPlate: View {
    let glow: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let reach = w * 0.65
            ZStack {
                CamLab.panel
                RadialGradient(colors: [glow.opacity(0.26), glow.opacity(0)],
                               center: .center, startRadius: 0, endRadius: reach)
                    .frame(width: reach * 2, height: reach * 2)
                    .scaleEffect(x: 1, y: (h * 0.65) / reach)
                    .position(x: w * 0.2, y: h * 0.95)
            }
            .frame(width: w, height: h)
            .clipShape(CamPlateShape())
        }
        .animation(.easeOut(duration: 0.3), value: glow)
    }
}

/// White ring on a dark well. Video has a red core that squares off while
/// rolling; the photo modes have a signal-yellow core, with the frames left
/// on it while a roll is loaded.
struct CamShutter: View {
    let isRecording: Bool
    var photoMode: Bool = false
    /// Frames left on the roll; nil when no roll is loaded.
    var rollCount: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(0.35))
                Circle().strokeBorder(Color.white, lineWidth: 3)
                RoundedRectangle(cornerRadius: isRecording ? 7 : 28)
                    .fill(photoMode ? CamLab.sig : CamLab.rec)
                    .frame(width: isRecording ? 28 : 56, height: isRecording ? 28 : 56)
                if photoMode, let rollCount {
                    Text("\(rollCount)")
                        .font(.luma(size: 22, weight: .bold))
                        .kerning(-0.6)
                        .monospacedDigit()
                        .foregroundStyle(CamLab.ink)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            .frame(width: 70, height: 70)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
            .animation(.easeInOut(duration: 0.2), value: photoMode)
            .animation(.snappy(duration: 0.2), value: rollCount)
            .contentShape(Circle())
        }
        .buttonStyle(CamPressStyle(scale: 0.94))
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if photoMode, let rollCount { return "Take photo, \(rollCount) frames left" }
        if photoMode { return "Take photo" }
        return isRecording ? "Stop recording" : "Record"
    }
}

/// The lab's press: the control shrinks a touch under the finger.
struct CamPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// One mode in the plate's switch.
struct CamMode: Identifiable {
    let id: String
    let icon: CamIcon
    let label: String
    var enabled: Bool = true
}

/// Photo, Video, Slo-mo, Portrait: icons in an ink well, a white knob under
/// the one in use.
struct CamModeSwitch: View {
    let modes: [CamMode]
    let selected: String
    /// Turns each icon in place when the phone is held sideways.
    var turn: Double = 0
    let onPick: (CamMode) -> Void

    private static let width: CGFloat = 132
    private static let height: CGFloat = 46
    private static let inset: CGFloat = 23

    var body: some View {
        let step: CGFloat = modes.count > 1
            ? (Self.width - Self.inset * 2) / CGFloat(modes.count - 1) : 0
        let at = modes.firstIndex { $0.id == selected } ?? 0
        ZStack {
            Capsule().fill(CamLab.ink)
            Circle()
                .fill(CamLab.text)
                .frame(width: 38, height: 38)
                .position(x: Self.inset + step * CGFloat(at), y: Self.height / 2)
            ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                let on = mode.id == selected
                Button {
                    onPick(mode)
                } label: {
                    CamGlyph(icon: mode.icon, size: 18)
                        .foregroundStyle(on ? CamLab.ink : CamLab.grey3)
                        .rotationEffect(.degrees(turn))
                        .frame(width: max(step, 26), height: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(mode.enabled ? 1 : 0.4)
                .position(x: Self.inset + step * CGFloat(index), y: Self.height / 2)
                .accessibilityLabel(mode.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(width: Self.width, height: Self.height)
        .animation(.easeInOut(duration: 0.2), value: at)
    }
}

// MARK: - The look ring

/// The look on the picture: a ring in the look's colour that fills with its
/// strength, a gap at the bottom, the stock code inside.
struct CamRing: View {
    let code: String
    let colour: Color
    /// 0...1
    let strength: Double
    var size: CGFloat = 42

    var body: some View {
        let radius = size / 2 - 3
        let line: CGFloat = size >= 44 ? 3.5 : 3
        let sweep = 0.82
        ZStack {
            Circle()
                .fill(colour.opacity(0.16))
                .frame(width: (radius - 2) * 2, height: (radius - 2) * 2)
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(90 + 0.09 * 360))
            Circle()
                .trim(from: 0, to: sweep * min(max(strength, 0), 1))
                .stroke(colour, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(90 + 0.09 * 360))
                .shadow(color: colour.opacity(strength > 0 ? 0.9 : 0), radius: 2.5)
            Text(code)
                .font(.luma(size: size * Self.codeScale(code.count), weight: .bold))
                .kerning(code.count > 4 ? -0.2 : 0)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, size * 0.12)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: strength)
    }

    /// Longer codes set smaller, so "CP2383" fits the ring as well as "KD2".
    private static func codeScale(_ length: Int) -> CGFloat {
        switch length {
        case ...3: return 0.29
        case 4:    return 0.25
        case 5:    return 0.205
        default:   return 0.18
        }
    }
}

// MARK: - The histogram in the top bar

/// The live luminance histogram as the lab draws it: a white line over a
/// soft fill, 52 x 20.
struct CamHistogramGlyph: View {
    /// Bins normalised so the tallest is 1; nil before the first frame.
    let bins: [Float]?

    private static let resting: [Float] = [0, 4, 10, 18, 22, 16, 12, 14, 20, 26, 22, 15, 9, 6, 8, 12, 10, 6, 3, 1]
        .map { $0 / 26 }

    /// The live bins, each averaged with its neighbours, so 48 thin bins
    /// draw as one curve at this size.
    private static func smoothed(_ bins: [Float]?) -> [Float]? {
        guard let bins, bins.count > 2 else { return nil }
        let last = bins.count - 1
        return bins.indices.map { i in
            (bins[max(i - 1, 0)] + bins[i] * 2 + bins[min(i + 1, last)]) / 4
        }
    }

    var body: some View {
        Canvas { context, size in
            let values = Self.smoothed(bins) ?? Self.resting
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in values.enumerated() {
                let v = CGFloat(min(max(value, 0), 1))
                line.addLine(to: CGPoint(x: CGFloat(i) * step, y: size.height - v * size.height * 0.91))
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.white.opacity(0.22)))
            context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 1.1)
        }
        .frame(width: 52, height: 20)
        .accessibilityLabel("Histogram")
    }
}

// MARK: - Chips and the dial

/// A chip over the dial: what the dial turns. The live one is signal yellow.
struct CamChip: View {
    let title: String
    let active: Bool
    /// Tighter sides, for a phone too narrow for the full row.
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? CamLab.ink : Color.white.opacity(0.66))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 7 : 10)
                .padding(.vertical, 6)
                .background {
                    if active {
                        Capsule().fill(CamLab.sig)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color(hex: 0x0C0D0F).opacity(0.4))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(CamPressStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// One big dial on an arc centred on the shutter. Drag sideways to turn it;
/// drag up to pull up Pro. Index based, so the lens, shutter, ISO, exposure,
/// white balance and focus all share it.
struct CamDial: View {
    let ticks: [String]
    let index: Int
    /// Label every nth stop; 1 labels them all.
    var labelEvery: Int = 1
    let onChange: (Int) -> Void
    var onPullUp: (() -> Void)? = nil

    static let radius: CGFloat = 168
    /// The view is this tall, and the arc's centre (the shutter's) sits this
    /// far under its bottom edge.
    static let height: CGFloat = 186
    static let centreBelow: CGFloat = 30

    @State private var dragF: Double?
    @State private var dragBase: Double?
    @State private var axis: Axis?
    @State private var pulled = false
    @State private var sent: Int?

    private var stepDegrees: Double {
        let n = max(ticks.count - 1, 1)
        return min(18, max(9, 130 / Double(n)))
    }

    var body: some View {
        CamDialFace(ticks: ticks, position: dragF ?? Double(index),
                    step: stepDegrees, labelEvery: max(labelEvery, 1))
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let dx = value.translation.width, dy = value.translation.height
                        if axis == nil, hypot(dx, dy) > 6 {
                            axis = abs(dy) > abs(dx) * 1.4 ? .vertical : .horizontal
                        }
                        switch axis {
                        case .vertical:
                            if dy < -34, !pulled {
                                pulled = true
                                onPullUp?()
                            }
                        case .horizontal:
                            let base = dragBase ?? Double(index)
                            if dragBase == nil { dragBase = base }
                            let degrees = Double(dx / Self.radius) * 180 / Double.pi
                            let n = Double(max(ticks.count - 1, 0))
                            let next = min(max(base - degrees / stepDegrees, 0), n)
                            dragF = next
                            let snapped = Int(next.rounded())
                            if snapped != index, snapped != sent {
                                sent = snapped
                                onChange(snapped)
                            }
                        case nil:
                            break
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.16)) { dragF = nil }
                        dragBase = nil
                        axis = nil
                        pulled = false
                        sent = nil
                    }
            )
            .animation(dragF == nil ? .easeOut(duration: 0.16) : nil, value: index)
            .sensoryFeedback(.selection, trigger: index)
            .accessibilityElement()
            .accessibilityLabel("Dial")
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

/// The dial's face. `position` animates, so the arc glides to a stop.
private struct CamDialFace: View, Animatable {
    let ticks: [String]
    var position: Double
    let step: Double
    let labelEvery: Int

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height + CamDial.centreBelow
            let r = CamDial.radius
            let current = Int(position.rounded())
            for i in ticks.indices {
                for m in 0..<4 {
                    if m > 0 && i == ticks.count - 1 { break }
                    let a = 90 - (Double(i) + Double(m) / 4 - position) * step
                    if a < 14 || a > 166 { continue }
                    let th = a * Double.pi / 180
                    let major = m == 0
                    let fade = pow(max(0, 1 - abs(a - 90) / 80), 0.8)
                    let r1 = r - (major ? 11 : 6)
                    var tick = Path()
                    tick.move(to: CGPoint(x: cx + r1 * CGFloat(cos(th)), y: cy - r1 * CGFloat(sin(th))))
                    tick.addLine(to: CGPoint(x: cx + r * CGFloat(cos(th)), y: cy - r * CGFloat(sin(th))))
                    context.stroke(tick, with: .color(.white.opacity(fade * (major ? 0.95 : 0.5))),
                                   style: StrokeStyle(lineWidth: major ? 1.6 : 1.1, lineCap: .round))
                    if major && i % labelEvery == 0 {
                        let rl = r + 17
                        let on = i == current
                        let label = Text(ticks[i])
                            .font(.luma(size: 12, weight: on ? .semibold : .medium))
                            .foregroundColor(on ? CamLab.sig : .white.opacity(fade * 0.75))
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
                layer.addFilter(.shadow(color: CamLab.sig, radius: 2.5))
                layer.stroke(needle, with: .color(CamLab.sig),
                             style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }
}

// MARK: - The ruler

/// A ruler under a fixed needle: Pro's readouts, the sideways readouts and
/// the look strength all drag it. Major tick per stop, three minor between.
struct CamRuler: View {
    let ticks: [String]
    let index: Int
    /// Points between stops.
    var spacing: CGFloat = 42
    /// Label every nth stop; 1 labels them all.
    var labelEvery: Int = 1
    let onChange: (Int) -> Void

    @State private var dragF: Double?
    @State private var dragBase: Double?
    @State private var sent: Int?

    var body: some View {
        CamRulerFace(ticks: ticks, position: dragF ?? Double(index),
                     spacing: spacing, labelEvery: max(labelEvery, 1))
            .frame(height: 46)
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.2),
                    .init(color: .black, location: 0.8),
                    .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let base = dragBase ?? Double(index)
                        if dragBase == nil { dragBase = base }
                        let n = Double(max(ticks.count - 1, 0))
                        let next = min(max(base - Double(value.translation.width / spacing), 0), n)
                        dragF = next
                        let snapped = Int(next.rounded())
                        if snapped != index, snapped != sent {
                            sent = snapped
                            onChange(snapped)
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.18)) { dragF = nil }
                        dragBase = nil
                        sent = nil
                    }
            )
            .animation(dragF == nil ? .easeOut(duration: 0.18) : nil, value: index)
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

private struct CamRulerFace: View, Animatable {
    let ticks: [String]
    var position: Double
    let spacing: CGFloat
    let labelEvery: Int

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.width / 2
            let current = Int(position.rounded())
            let reach = Double(mid / max(spacing, 1)) + 1
            let first = max(0, Int((position - reach).rounded(.down)))
            let last = min(ticks.count - 1, Int((position + reach).rounded(.up)))
            if first <= last {
                for i in first...last {
                    let x = mid + CGFloat(Double(i) - position) * spacing
                    context.fill(Path(roundedRect: CGRect(x: x - 0.75, y: 4, width: 1.5, height: 14),
                                      cornerRadius: 0.75),
                                 with: .color(.white.opacity(0.92)))
                    if i < ticks.count - 1 {
                        for m in 1..<4 {
                            let mx = x + CGFloat(m) / 4 * spacing
                            context.fill(Path(roundedRect: CGRect(x: mx - 0.75, y: 4, width: 1.5, height: 7),
                                              cornerRadius: 0.75),
                                         with: .color(.white.opacity(0.5)))
                        }
                    }
                    if i % labelEvery == 0 {
                        let on = i == current
                        let label = Text(ticks[i])
                            .font(.luma(size: 12, weight: on ? .semibold : .medium))
                            .foregroundColor(on ? CamLab.sig : .white.opacity(0.55))
                        context.draw(label, at: CGPoint(x: x, y: 25), anchor: .top)
                    }
                }
            }
            let needle = Path(roundedRect: CGRect(x: mid - 1.25, y: 0, width: 2.5, height: 22),
                              cornerRadius: 1.25)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: CamLab.sig.opacity(0.7), radius: 4))
                layer.fill(needle, with: .color(CamLab.sig))
            }
        }
    }
}

// MARK: - Pro's readouts and tiles

/// One of Pro's readouts: the value, a rule that lights when the ruler is
/// on it, the name, and an "A" while the camera is choosing it.
struct CamReadout: View {
    let name: String
    let value: String
    var auto: Bool = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.luma(size: 15.5, weight: .medium))
                    .kerning(-0.3)
                    .foregroundStyle(CamLab.text)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: 15.5)
                Color.clear.frame(width: 1, height: 11.5)
                HStack(spacing: 4) {
                    Text(name)
                        .font(.luma(size: 9, weight: .semibold))
                        .kerning(0.7)
                        .foregroundStyle(active ? CamLab.text : CamLab.label)
                    if auto {
                        Text("A")
                            .font(.luma(size: 8.5, weight: .bold))
                            .foregroundStyle(CamLab.ink)
                            .padding(.horizontal, 3)
                            .frame(height: 12)
                            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .frame(height: 12)
            }
            .frame(minWidth: 34, alignment: .leading)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(active ? CamLab.sig : Color.white.opacity(0.16))
                    .frame(height: 1.5)
                    .shadow(color: active ? CamLab.sig.opacity(0.5) : .clear, radius: 3)
                    .offset(y: 21.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CamPressStyle())
        .accessibilityLabel("\(name) \(value)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A tool in Pro: an icon over its name, lit signal when on.
struct CamTile: View {
    let icon: CamIcon
    let label: String
    var on: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                CamGlyph(icon: icon, size: 22, weight: 1.6)
                    .foregroundStyle(on ? CamLab.sig : Color.white.opacity(0.85))
                Text(label)
                    .font(.luma(size: 11.5, weight: .medium))
                    .foregroundStyle(on ? CamLab.sig : Color.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(on ? CamLab.sig.opacity(0.15) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(CamPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The small round button in a sheet's header (close, and Pro's Auto).
struct CamMiniLabel: View {
    var icon: CamIcon? = nil
    var title: String? = nil
    var lit: Bool = false

    var body: some View {
        Group {
            if let icon {
                CamGlyph(icon: icon, size: 20)
                    .frame(width: 32, height: 32)
            } else {
                Text(title ?? "")
                    .font(.luma(size: 12, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 32)
            }
        }
        .foregroundStyle(lit ? CamLab.ink : CamLab.text)
        .background(lit ? CamLab.sig : CamLab.raised, in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - The thumb fan

/// One tool in the fan.
struct CamFanItem: Identifiable {
    let id: String
    let icon: CamIcon
    let label: String
    let on: Bool
}

/// Press and hold anywhere: the tools fan out on an arc above the thumb.
/// Slide onto one and let go to use it.
struct CamFan: View {
    /// Where the finger is.
    let touch: CGPoint
    /// The fan's centre (the touch, kept clear of the screen edges).
    let centre: CGPoint
    let items: [CamFanItem]
    let positions: [CGPoint]
    let hot: Int?
    /// Shown over the finger while it rests on no tool.
    var restLabel: String? = nil

    @State private var shown = false

    static let radius: CGFloat = 122

    /// Bubble centres on an arc above `centre`, from 165° round to 15°.
    static func layout(centre: CGPoint, count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let degrees = count == 1 ? 90 : 165 - Double(i) * 150 / Double(count - 1)
            let t = degrees * Double.pi / 180
            return CGPoint(x: centre.x + radius * CGFloat(cos(t)),
                           y: centre.y - radius * CGFloat(sin(t)))
        }
    }

    /// The fan's centre for a touch, clamped so every bubble stays on screen
    /// and clear of the top bar and the plate.
    static func centre(for touch: CGPoint, in size: CGSize) -> CGPoint {
        let x = min(max(touch.x, 140), max(140, size.width - 140))
        let y = min(max(touch.y, 300), max(300, size.height - 184))
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack {
            RadialGradient(stops: [
                .init(color: .black.opacity(0.6), location: 0),
                .init(color: .black.opacity(0.25), location: 220.0 / 330.0),
                .init(color: .black.opacity(0), location: 1),
            ], center: .center, startRadius: 0, endRadius: 330)
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
                CamGlyph(icon: item.icon, size: 21, weight: 1.7)
                    .foregroundStyle(isHot ? CamLab.ink : (item.on ? CamLab.sig : Color.white))
                    .frame(width: 46, height: 46)
                    .background {
                        if isHot {
                            Circle().fill(CamLab.sig)
                        } else {
                            Circle().fill(.ultraThinMaterial)
                            Circle().fill(Color(hex: 0x16171B).opacity(0.82))
                        }
                    }
                    .overlay {
                        if item.on && !isHot {
                            Circle().strokeBorder(CamLab.sig.opacity(0.8), lineWidth: 2)
                        }
                    }
                    .shadow(color: isHot ? CamLab.sig.opacity(0.6) : .black.opacity(0.35),
                            radius: isHot ? 9 : 8, y: isHot ? 0 : 6)
                    .scaleEffect(isHot ? 1.2 : (shown ? 1 : 0.3))
                    .opacity(shown ? 1 : 0)
                    .position(positions.indices.contains(i) ? positions[i] : centre)
                    .animation(.easeOut(duration: 0.2).delay(Double(i) * 0.018), value: shown)
                    .animation(.easeOut(duration: 0.12), value: isHot)
            }
            if let hot, items.indices.contains(hot), positions.indices.contains(hot) {
                fanLabel(items[hot].label)
                    .position(x: positions[hot].x, y: positions[hot].y - 46)
            } else if let restLabel {
                fanLabel(restLabel)
                    .position(x: touch.x, y: touch.y - 46)
            }
        }
        .allowsHitTesting(false)
        .onAppear { shown = true }
    }

    private func fanLabel(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 13, weight: .bold))
            .foregroundStyle(CamLab.sig)
            .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
            .fixedSize()
    }
}

// MARK: - Focus

/// The square a tap leaves on the picture: it snaps in from a touch larger
/// and carries what is being held ("AF", or "AE/AF L" while locked).
struct CamFocusSquare: View {
    var label: String = "AF"

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(CamLab.sig, lineWidth: 1.5)
            .frame(width: 74, height: 74)
            .overlay(alignment: .topTrailing) {
                Text(label)
                    .font(.luma(size: 11, weight: .bold))
                    .foregroundStyle(CamLab.sig)
                    .fixedSize()
                    .alignmentGuide(.trailing) { d in d[.leading] - 6 }
                    .offset(y: -2)
            }
            .shadow(color: .black.opacity(0.35), radius: 3)
            .allowsHitTesting(false)
    }
}

/// The square as a tap leaves it: in from a touch larger, held, then gone.
/// `hold` keeps it up (AE/AF locked, or the preview's seeded frame).
struct CamFocusPulse: View {
    var label: String = "AF"
    var hold: Bool = false

    @State private var shown = false
    @State private var gone = false

    var body: some View {
        CamFocusSquare(label: label)
            .scaleEffect(shown ? 1 : 1.3)
            .opacity(gone ? 0 : (shown ? 1 : 0))
            .onAppear {
                withAnimation(.easeOut(duration: 0.165)) { shown = true }
                if !hold {
                    withAnimation(.easeOut(duration: 0.22).delay(0.88)) { gone = true }
                }
            }
    }
}

// MARK: - Small parts

/// A short caption over the picture.
struct CamToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.luma(size: 13, weight: .semibold))
            .foregroundStyle(CamLab.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .camGlass(RoundedRectangle(cornerRadius: 16), tint: Color(hex: 0x0C0D0F), opacity: 0.8)
            .allowsHitTesting(false)
    }
}

/// The bar at the top of a sheet that says it drags.
struct CamGrab: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .frame(width: 36, height: 5)
    }
}

/// Rule of thirds, as the lab draws it.
struct CamGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = (size.width * CGFloat(i) / 3).rounded()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = (size.height * CGFloat(i) / 3).rounded()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A frame guide: everything outside the box dimmed, the box outlined and
/// named. `safeZone` adds the social safe area inside a 9:16 guide.
struct CamGuide: View {
    let box: CGRect
    let label: String
    var safeZone: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                Text(label)
                    .font(.luma(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .fixedSize()
                    .offset(x: box.minX + 8, y: box.minY + 6)
                if safeZone {
                    // Platform chrome eats about 10% at the top, 22% at the
                    // bottom and 12% down the right of a 9:16 feed.
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(CamLab.sig.opacity(0.8),
                                      style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .frame(width: box.width * 0.84, height: box.height * 0.68)
                        .offset(x: box.minX + box.width * 0.04, y: box.minY + box.height * 0.10)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One choice in the format card.
struct CamOption: View {
    let title: String
    let on: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 14, weight: .semibold))
                .foregroundStyle(on ? CamLab.sig : Color.white.opacity(0.78))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(on ? CamLab.sig.opacity(0.15) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(CamPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

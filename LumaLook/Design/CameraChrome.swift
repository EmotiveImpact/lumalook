import SwiftUI

/// Shared cinematic chrome for the camera and grade screens: monospaced
/// technical readouts, SMPTE-style timecode, rule-of-thirds grid,
/// letterbox mattes and the before/after wipe handle.
///
/// Design rules (Darkroom / Kino / Blackmagic grammar):
///   - Chrome is hueless — pure whites and blacks only, so it never
///     biases grading perception. The violet accent is reserved for
///     interactive / selected elements.
///   - Technical values speak in small ALL-CAPS monospaced type,
///     tracked out, white at reduced opacity.

// MARK: - Technical readout type

/// Small ALL-CAPS monospaced technical readout — the "instrument" voice
/// of the UI, used for format badges, timecode and media metadata.
struct TechReadout: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = .white.opacity(0.72)

    init(_ text: String, size: CGFloat = 12, color: Color = .white.opacity(0.72)) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .kerning(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: - Timecode

enum Timecode {
    /// SMPTE-style `HH:MM:SS:FF` string for an elapsed duration.
    static func string(seconds: Double, fps: Double = 30) -> String {
        let clamped = max(seconds, 0)
        let whole = Int(clamped)
        let frames = Int((clamped - Double(whole)) * fps)
        return String(format: "%02d:%02d:%02d:%02d",
                      whole / 3600, (whole / 60) % 60, whole % 60, frames)
    }
}

// MARK: - Rule-of-thirds grid

/// Hairline rule-of-thirds overlay for the viewfinder. Hueless, thin,
/// never intercepts touches.
struct RuleOfThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Letterbox mattes

/// Cinema-style letterbox: black mattes above and below the picture with
/// a hairline marking the frame edge. Sized from the content's aspect
/// ratio inside whatever container it overlays.
struct LetterboxMattes: View {
    /// Aspect ratio (width / height) of the content being letterboxed.
    let contentAspect: CGFloat

    var body: some View {
        GeometryReader { geo in
            let contentHeight = geo.size.width / max(contentAspect, 0.01)
            let barHeight = max((geo.size.height - contentHeight) / 2, 0)
            if barHeight > 2 {
                VStack(spacing: 0) {
                    matte(height: barHeight, hairlineAt: .bottom)
                    Spacer(minLength: 0)
                    matte(height: barHeight, hairlineAt: .top)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func matte(height: CGFloat, hairlineAt edge: Alignment) -> some View {
        Rectangle()
            .fill(.black.opacity(0.85))
            .frame(height: height)
            .overlay(alignment: edge) {
                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(height: 0.5)
            }
    }
}

// MARK: - Capture format chip

/// Top-left format signal: resolution · fps · codec, read straight off the
/// active `CameraSpec` so the chip can never disagree with what is recorded.
///
/// These are format VALUES, so they keep the mono instrument voice — but not
/// via `TechReadout`, whose forced uppercase turns "1080p" into "1080P" and
/// "H.264" into a tracked-out shout. The chip now sits on the camera's black
/// matte, so it needs no scrim of its own either.
struct CaptureFormatChip: View {
    let spec: CameraSpec

    var body: some View {
        Text("\(spec.resolution.rawValue) · \(spec.fps) · \(spec.codec.rawValue)")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .padding(.vertical, 5)
    }
}

// MARK: - RETIRED with the old full-bleed camera
//
// Everything from here to the end of the pro-panel section belonged to the
// previous viewfinder, where chrome floated on glass over the picture. The
// promoted camera puts every control on a black matte, so it needs no glass,
// no rail and no violet accent: `ProRailButton` / `ProRailGroup` /
// `ProRailDivider` / `CameraAssistChip` / `ProReadout` / `RulerDial` now have
// no call sites. They are left in place rather than deleted only because
// sibling screens are being promoted concurrently — safe to remove once that
// wave lands. `ProParameter` below is still live and must stay.

/// The rail's shared glass. One surface definition so a lone button and a
/// grouped cluster are cut from the same material — the rail must read as a
/// few machined objects, not a stack of unrelated chips.
private struct RailGlass: View {
    var radius: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(.black.opacity(0.30))
            shape.fill(.ultraThinMaterial)
        }
        // Over live video the chrome has no predictable backdrop, so a
        // hairline is meaning rather than decoration: it is what keeps the
        // control's edge legible against a blown-out sky.
        .overlay(shape.strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
    }
}

/// One 40pt control on the viewfinder's right rail. The rail is the only
/// control column over the feed, which is what keeps the centre two-thirds
/// of the frame clear.
///
/// `grouped` members paint no surface of their own — a `ProRailGroup` carries
/// one shared piece of glass for the whole cluster, which is what takes the
/// rail's visual weight down without shrinking a single hit target.
struct ProRailButton<Label: View>: View {
    var active: Bool = false
    var grouped: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? LumaTheme.accentBright : .white)
                // Every rail control is the same 40pt square so the column has
                // one hard right edge, and so no hit target shrank.
                .frame(width: 40, height: 40)
                // Colour is the accent, never the fill: an armed control is a
                // 2pt accent tally on the frame-facing edge plus a tinted
                // glyph. A saturated block over live video reads as a toy.
                .overlay(alignment: .leading) {
                    if active {
                        Capsule()
                            .fill(LumaTheme.accentBright)
                            .frame(width: 2, height: 16)
                            .padding(.leading, 3)
                    }
                }
                .background { if !grouped { RailGlass() } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }
}

/// A rail cluster: several controls sharing one glass surface, hairline-
/// separated. Used for the three exposure controls, which are one class of
/// thing and should read as one object.
struct ProRailGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background { RailGlass() }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Inset hairline between two `ProRailGroup` members — separation by value,
/// not by drawing a box round every control.
struct ProRailDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(width: 22, height: 0.5)
    }
}

// MARK: - D2: pro panel parts

/// The five parameters the pro panel's shared dial can target.
enum ProParameter: String, CaseIterable, Identifiable {
    case iso = "ISO"
    case shutter = "Shutter"
    case wb = "WB"
    case ev = "EV"
    case focus = "Focus"

    var id: String { rawValue }
}

/// One of the five pro readouts. Tapping it re-targets the shared dial —
/// the readout row is a selector, not decoration.
struct ProReadout: View {
    let parameter: ProParameter
    let value: String
    /// True when the camera is choosing this value itself. The concrete value
    /// is still shown — it is what the dial points at — but dimmed and tagged,
    /// so the readout and the dial can never state two different truths.
    var auto: Bool = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                TechReadout(auto ? "\(parameter.rawValue) A" : parameter.rawValue, size: 8,
                            color: active ? LumaTheme.accentBright : LumaTheme.textMuted)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(active ? LumaTheme.accentBright : .white)
                    .opacity(auto ? 0.6 : 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(minWidth: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }
}

/// Detented horizontal ruler: one shared dial that drives whichever pro
/// parameter is active. Values are discrete stops (cine practice), the
/// current one sits centred under the violet indicator, and a horizontal
/// drag steps through them.
struct RulerDial: View {
    /// Tick labels, in order. The dial is index-based so any parameter —
    /// ISO stops, shutter angles, kelvin, EV thirds — uses the same widget.
    let ticks: [String]
    let index: Int
    let onChange: (Int) -> Void

    /// Drag distance that advances one detent.
    private let stride: CGFloat = 46
    @State private var dragBase: Int?

    var body: some View {
        // No GeometryReader: the indicator is simply the ZStack's own centre
        // and the tick rail is offset relative to that same centre, so the
        // caret always lands on the row's horizontal midpoint — the readout
        // row above and the dial can never disagree about where "centre" is.
        ZStack {
            HStack(spacing: 0) {
                ForEach(ticks.indices, id: \.self) { i in
                    let current = i == index
                    VStack(spacing: 5) {
                        Rectangle()
                            .fill(current ? AnyShapeStyle(LumaTheme.accentBright)
                                          : AnyShapeStyle(Color.white.opacity(0.22)))
                            .frame(width: current ? 2 : 1, height: current ? 15 : 9)
                        Text(ticks[i])
                            .font(.system(size: current ? 12 : 10,
                                          weight: current ? .bold : .regular,
                                          design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(current ? .white : LumaTheme.textMuted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(width: stride)
                }
            }
            // Distance from the rail's own centre to tick `index`.
            .offset(x: stride * (CGFloat(ticks.count) / 2 - CGFloat(index) - 0.5))
            .animation(.snappy(duration: 0.14), value: index)

            Rectangle()
                .fill(LumaTheme.accentBright)
                .frame(width: 2, height: 8)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let base = dragBase ?? index
                    if dragBase == nil { dragBase = index }
                    let steps = Int((-value.translation.width / stride).rounded())
                    let target = min(max(base + steps, 0), max(ticks.count - 1, 0))
                    if target != index { onChange(target) }
                }
                .onEnded { _ in dragBase = nil }
        )
        .sensoryFeedback(.selection, trigger: index)
    }
}

/// Assist toggle chip (Zebras / Focus peaking / Grid / Level). Each one owns
/// a real overlay renderer; there are no decorative chips in this row.
///
/// An engaged assist is stated by a lit tally dot and accent type on a
/// near-black surface — not by flooding the chip with saturated violet. A
/// solid colour block in a pro viewfinder panel reads as a toy, and four of
/// them lit at once reads as a toy shop.
struct CameraAssistChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(on ? AnyShapeStyle(LumaTheme.accentBright)
                             : AnyShapeStyle(Color.white.opacity(0.22)))
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 11, weight: on ? .bold : .medium))
                    .foregroundStyle(on ? LumaTheme.accentBright : .white.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.white.opacity(on ? 0.10 : 0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .sensoryFeedback(.selection, trigger: on)
    }
}

// MARK: - Before/After wipe handle

/// Industry-standard comparison wipe: a vertical hairline with a circular
/// grabber carrying left/right arrows, soft-shadowed so it reads over any
/// footage.
struct WipeHandle: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .shadow(color: .black.opacity(0.45), radius: 4)
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                .overlay {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.72))
                }
        }
    }
}

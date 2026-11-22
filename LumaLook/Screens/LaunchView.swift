import SwiftUI

// MARK: - Launch: "Develop"
//
// About two seconds on a cold launch, laid over the app while it loads
// underneath (LumaLookApp shows it as an overlay):
//
//   1. the signal mark appears in the middle of the dark screen,
//   2. it stretches into a thin line of light,
//   3. the line opens into a photo that starts flat and dark, then develops
//      into tonight's look (a bundled sample photo graded by the real pipeline),
//   4. the wordmark and the look's chip settle at the bottom,
//   5. the whole layer fades and grows slightly to hand off to the app.
//
// Every frame is a pure function of the elapsed time, so the DEBUG route
// LUMA_ROUTE=launch can hold one frame for the preview screenshot. A tap skips
// it at any point. Reduce Motion gets a short fade of the mark instead.

// MARK: - Gate

/// Whether the launch animation plays, plus its DEBUG hooks.
enum LaunchGate {
    /// Read once into App state (LumaLookApp), so it plays on a cold launch
    /// only and never when the app comes back from the background.
    static var shouldShow: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let route = env["LUMA_ROUTE"], route == "launch" || route == "launchLive" { return true }
        // Any other LUMA_ hook is a preview screenshot of another screen,
        // which the launch layer would cover.
        if env.keys.contains(where: { $0.hasPrefix("LUMA_") }) { return false }
        #endif
        return true
    }

    /// DEBUG `LUMA_ROUTE=launch` holds one representative frame for the
    /// preview screenshot. `LUMA_ROUTE=launchLive` plays it normally.
    static var freezeTime: Double? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_ROUTE"] == "launch" {
            return LaunchTimeline.debugFreeze
        }
        #endif
        return nil
    }

    /// Tonight's look; the preview routes use one fixed look so screenshots
    /// compare like for like between runs.
    static var look: LaunchLook {
        #if DEBUG
        if let route = ProcessInfo.processInfo.environment["LUMA_ROUTE"],
           route == "launch" || route == "launchLive",
           let fixed = LaunchLook.named("Neon Nights", photo: .neon) {
            return fixed
        }
        #endif
        return LaunchLook.tonight
    }
}

// MARK: - Look

/// The look the launch photo develops into.
struct LaunchLook {
    let preset: LookPreset
    let photo: HeroPhoto

    /// "Tonight · Neon Nights", "Tonight · KD2 Golden Hour".
    var chipText: String {
        if let code = preset.code {
            return "Tonight · \(code) \(preset.title)"
        }
        return "Tonight · \(preset.title)"
    }

    /// Same rotation and day maths as Home's `TonightsLook` (HomeView.swift),
    /// kept here so the launch does not depend on Home's internals. Changes
    /// at midnight.
    private static let rotation: [(String, HeroPhoto)] = [
        ("Neon Nights", .neon),
        ("KD2 · Golden Hour", .golden),
        ("Night Drive", .drive),
        ("AG60 · London Rain", .rain),
        ("Afrobeats Glow", .party),
        ("CN83 · Teal & Orange", .skate),
        ("CN93 · Luxury Campaign", .campaign),
        ("BW32 · Documentary Grit", .gig)
    ]

    static var tonight: LaunchLook {
        let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .era, for: Date()) ?? 0
        let options = rotation.compactMap { entry in LaunchLook.named(entry.0, photo: entry.1) }
        guard !options.isEmpty else {
            return LaunchLook(preset: MockData.defaultLook, photo: .golden)
        }
        return options[abs(day) % options.count]
    }

    static func named(_ name: String, photo: HeroPhoto) -> LaunchLook? {
        guard let preset = MockData.looks.first(where: { $0.name == name }) else { return nil }
        return LaunchLook(preset: preset, photo: photo)
    }
}

// MARK: - Timeline

/// Seconds from the first frame. Ends at `total` (under 2.1 s).
enum LaunchTimeline {
    // 1. Mark appears, holds, then stretches into the line.
    static let markInStart: Double = 0.04
    static let markInEnd: Double = 0.30
    static let stretchStart: Double = 0.42
    static let stretchEnd: Double = 0.60
    // 2. Line of light grows across the screen, then fades as the frame opens.
    static let lineInEnd: Double = 0.48
    static let lineGrowEnd: Double = 0.70
    static let lineFadeEnd: Double = 0.98
    // 3. The frame opens from the line and the photo develops.
    static let openStart: Double = 0.66
    static let openEnd: Double = 1.02
    static let developStart: Double = 0.68
    static let developEnd: Double = 1.55
    static let settleEnd: Double = 1.80
    // 4. Wordmark, then the look chip.
    static let wordStart: Double = 0.98
    static let wordEnd: Double = 1.34
    static let chipStart: Double = 1.16
    static let chipEnd: Double = 1.42
    // 5. Hand-off to the app.
    static let handoffStart: Double = 1.72
    static let handoffEnd: Double = 2.02
    static let total: Double = 2.04

    /// The frame `LUMA_ROUTE=launch` holds: photo mostly developed, wordmark
    /// settled, chip arriving.
    static let debugFreeze: Double = 1.2

    // Reduce Motion: the mark fades in, then a 0.4 s fade to the app.
    static let calmInEnd: Double = 0.15
    static let calmFadeStart: Double = 0.2
    static let calmFadeEnd: Double = 0.6
    static let calmTotal: Double = 0.62

    /// 0 before `start`, 1 after `end`, linear between.
    static func phase(_ t: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return t >= end ? 1 : 0 }
        return min(max((t - start) / (end - start), 0), 1)
    }

    static func mix(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * amount
    }
}

/// A CSS-style cubic Bezier timing curve, so the motion matches the mock.
struct LaunchEase {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    /// CSS `ease-out`.
    static let easeOut = LaunchEase(x1: 0, y1: 0, x2: 0.58, y2: 1)
    /// CSS `ease-in`.
    static let easeIn = LaunchEase(x1: 0.42, y1: 0, x2: 1, y2: 1)
    /// The mark's pop and stretch.
    static let pop = LaunchEase(x1: 0.3, y1: 0.7, x2: 0.2, y2: 1)
    /// The frame opening: slow start, quick finish.
    static let opening = LaunchEase(x1: 0.6, y1: 0, x2: 0.2, y2: 1)
    /// The wordmark settling.
    static let settle = LaunchEase(x1: 0.2, y1: 0.8, x2: 0.2, y2: 1)

    /// Eased value for a linear progress `x` in 0...1.
    func value(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // Newton's method on x(t) = x, falling back to bisection.
        var t = x
        for _ in 0..<8 {
            let error = sample(t, x1, x2) - x
            if abs(error) < 0.00001 { return sample(t, y1, y2) }
            let slope = derivative(t, x1, x2)
            if abs(slope) < 0.000001 { break }
            t -= error / slope
        }
        var low: Double = 0
        var high: Double = 1
        t = x
        for _ in 0..<24 {
            let current = sample(t, x1, x2)
            if abs(current - x) < 0.00001 { break }
            if current < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(t, y1, y2)
    }

    /// One axis of the curve (P0 = 0, P3 = 1).
    private func sample(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }
}

// MARK: - Launch view

/// The launch layer. Calls `onFinish` once, when it has handed off or when
/// the person taps to skip; the owner then removes it.
struct LaunchView: View {
    let look: LaunchLook
    let frozenAt: Double?
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var finished = false

    init(look: LaunchLook = LaunchGate.look,
         frozenAt: Double? = LaunchGate.freezeTime,
         onFinish: @escaping () -> Void) {
        self.look = look
        self.frozenAt = frozenAt
        self.onFinish = onFinish
    }

    /// The calm version, unless DEBUG is holding a frame of the full one.
    private var calm: Bool { reduceMotion && frozenAt == nil }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: frozenAt != nil)) { context in
            launchFrame(at: elapsed(at: context.date))
        }
        .ignoresSafeArea()
        .onTapGesture { finish(quickly: true) }
        .onAppear {
            if start == nil { start = Date() }
        }
        .task { await runClock() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("lumalook. Tonight's look, \(look.preset.title)")
        .accessibilityHint("Double tap to skip")
        .accessibilityAddTraits([.isButton, .isModal])
        .accessibilityAction { finish(quickly: true) }
    }

    @ViewBuilder
    private func launchFrame(at t: Double) -> some View {
        if calm {
            LaunchCalmFrame(t: t)
        } else {
            LaunchDevelopFrame(t: t, look: look)
        }
    }

    private func elapsed(at date: Date) -> Double {
        if let frozenAt = frozenAt { return frozenAt }
        guard let start = start else { return 0 }
        return max(0, date.timeIntervalSince(start))
    }

    /// Hands off when the animation has run. Never blocks the app: the app
    /// is already live underneath, and a tap ends this early.
    private func runClock() async {
        guard frozenAt == nil else { return }
        let total = calm ? LaunchTimeline.calmTotal : LaunchTimeline.total
        try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
        guard !Task.isCancelled else { return }
        finish(quickly: false)
    }

    private func finish(quickly: Bool) {
        guard !finished else { return }
        finished = true
        // The layer has already faded by the natural end; a skip fades it now.
        withAnimation(.easeOut(duration: quickly ? 0.22 : 0.1)) {
            onFinish()
        }
    }
}

// MARK: - Develop frame

/// One frame of the full animation at time `t`.
private struct LaunchDevelopFrame: View {
    let t: Double
    let look: LaunchLook

    var body: some View {
        ZStack {
            Color.black
            photo
            shade
            gateLine
            centreMark
            titles
        }
        .ignoresSafeArea()
        .compositingGroup()
        .scaleEffect(handoffScale)
        .opacity(1 - handoff)
    }

    // MARK: Layers

    /// The photo, flat and dark at first, developing into the graded look
    /// inside a frame that opens from the line of light.
    private var photo: some View {
        GradedHeroImage(photo: look.photo, lookName: look.preset.name)
            .grayscale(1 - develop)
            .colorMultiply(Color(white: 0.22 + 0.78 * develop))
            .contrast(1 + 0.3 * (1 - develop))
            .scaleEffect(photoScale)
            .clipShape(LaunchBand(amount: openAmount))
    }

    /// Darkens the lower half so the wordmark reads on any photo.
    private var shade: some View {
        LinearGradient(stops: [
            Gradient.Stop(color: Color.black.opacity(0), location: 0.48),
            Gradient.Stop(color: Color.black.opacity(0.55), location: 0.71),
            Gradient.Stop(color: Color.black.opacity(0.9), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    }

    /// The mark stretched into a thin line of signal light.
    private var gateLine: some View {
        LaunchLine(progress: lineGrow, thickness: 2)
            .fill(LumaTheme.signal)
            .shadow(color: LumaTheme.signal.opacity(0.75), radius: 9)
            .shadow(color: LumaTheme.signal.opacity(0.5), radius: 2)
            .opacity(lineOpacity)
            .allowsHitTesting(false)
    }

    private var centreMark: some View {
        LaunchMark(size: 36)
            .scaleEffect(x: markScaleX, y: markScaleY)
            .opacity(markOpacity)
    }

    private var titles: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            wordmark
            chip
        }
        .padding(.bottom, 92)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wordmark: some View {
        HStack(spacing: 12) {
            LaunchMark(size: 25)
            Text("lumalook")
                .font(.luma(size: 42, weight: .bold))
                .tracking(CGFloat(42 * LaunchTimeline.mix(0.25, -0.05, word)))
                .foregroundStyle(LumaTheme.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
        .offset(y: CGFloat(12 * (1 - word)))
        .opacity(word)
    }

    private var chip: some View {
        LookChip(name: look.chipText, colour: look.preset.signature, size: 14)
            .offset(y: CGFloat(9 * (1 - chipIn)))
            .opacity(chipIn)
    }

    // MARK: Curves

    private func phase(_ start: Double, _ end: Double) -> Double {
        LaunchTimeline.phase(t, start, end)
    }

    private var markPop: Double {
        LaunchEase.pop.value(phase(LaunchTimeline.markInStart, LaunchTimeline.markInEnd))
    }

    private var markStretch: Double {
        LaunchEase.pop.value(phase(LaunchTimeline.stretchStart, LaunchTimeline.stretchEnd))
    }

    private var markScaleX: CGFloat {
        CGFloat(LaunchTimeline.mix(0.55, 1, markPop) * LaunchTimeline.mix(1, 3.2, markStretch))
    }

    private var markScaleY: CGFloat {
        CGFloat(LaunchTimeline.mix(0.55, 1, markPop) * LaunchTimeline.mix(1, 0.08, markStretch))
    }

    private var markOpacity: Double { markPop * (1 - markStretch) }

    private var lineGrow: Double {
        LaunchEase.easeOut.value(phase(LaunchTimeline.stretchStart, LaunchTimeline.lineGrowEnd))
    }

    private var lineOpacity: Double {
        phase(LaunchTimeline.stretchStart, LaunchTimeline.lineInEnd)
            * (1 - phase(LaunchTimeline.lineGrowEnd, LaunchTimeline.lineFadeEnd))
    }

    private var openAmount: Double {
        LaunchEase.opening.value(phase(LaunchTimeline.openStart, LaunchTimeline.openEnd))
    }

    private var develop: Double {
        LaunchEase.easeOut.value(phase(LaunchTimeline.developStart, LaunchTimeline.developEnd))
    }

    private var photoScale: CGFloat {
        let settle = LaunchEase.easeOut.value(phase(LaunchTimeline.developStart, LaunchTimeline.settleEnd))
        return CGFloat(LaunchTimeline.mix(1.12, 1, settle))
    }

    private var word: Double {
        LaunchEase.settle.value(phase(LaunchTimeline.wordStart, LaunchTimeline.wordEnd))
    }

    private var chipIn: Double {
        LaunchEase.easeOut.value(phase(LaunchTimeline.chipStart, LaunchTimeline.chipEnd))
    }

    private var handoff: Double {
        LaunchEase.easeIn.value(phase(LaunchTimeline.handoffStart, LaunchTimeline.handoffEnd))
    }

    private var handoffScale: CGFloat { CGFloat(1 + 0.05 * handoff) }
}

// MARK: - Calm frame (Reduce Motion)

/// The mark fades in, then the layer fades to the app. No movement.
private struct LaunchCalmFrame: View {
    let t: Double

    var body: some View {
        ZStack {
            Color.black
            LaunchMark(size: 36)
                .opacity(LaunchTimeline.phase(t, 0, LaunchTimeline.calmInEnd))
        }
        .ignoresSafeArea()
        .compositingGroup()
        .opacity(1 - LaunchTimeline.phase(t, LaunchTimeline.calmFadeStart, LaunchTimeline.calmFadeEnd))
    }
}

// MARK: - Parts

/// The lumalook mark as drawn in the launch mock: a signal square with a
/// thin signal rim, a dark ring and a signal core.
private struct LaunchMark: View {
    let size: CGFloat

    private var radius: CGFloat { size * 0.28 }
    private var rim: CGFloat { size * 0.08 }
    private var core: CGFloat { size * 0.2 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LumaTheme.signal)
            RoundedRectangle(cornerRadius: max(radius - rim, 1), style: .continuous)
                .fill(Color.black)
                .padding(rim)
            RoundedRectangle(cornerRadius: max(radius - core, 1), style: .continuous)
                .fill(LumaTheme.signal)
                .padding(core)
        }
        .frame(width: size, height: size)
    }
}

/// A horizontal band centred vertically; `amount` 0 shows nothing, 1 is the
/// whole frame.
private struct LaunchBand: Shape {
    var amount: Double

    func path(in rect: CGRect) -> Path {
        let height = rect.height * CGFloat(amount)
        return Path(CGRect(x: rect.minX, y: rect.midY - height / 2,
                           width: rect.width, height: height))
    }
}

/// A thin line through the centre that grows outwards from the middle.
private struct LaunchLine: Shape {
    var progress: Double
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = rect.width * CGFloat(progress)
        return Path(CGRect(x: rect.midX - width / 2, y: rect.midY - thickness / 2,
                           width: width, height: thickness))
    }
}

#Preview("Launch, held at 1.2 s") {
    LaunchView(frozenAt: LaunchTimeline.debugFreeze) {}
        .preferredColorScheme(.dark)
}

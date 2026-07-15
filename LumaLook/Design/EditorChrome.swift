import SwiftUI

// =============================================================================
// EditorChrome — self-contained chrome kit for the video editor & camera.
//
// Contents:
//   1. Custom presentation detents  (.lumaMicro / .lumaTiny / .lumaSmall / .lumaMedium)
//   2. LumaSheetStyle + .lumaToolSheet(...)   — undimmed tool sheets over the canvas
//   3. EdgeFadeMask + .lumaEdgeFade(...)      — gradient fade on horizontal scrollers
//   4. Timeline spring animations             (.lumaTimelineCollapse etc.)
//   5. TechnicalReadout                       — "4K • 30 • 00:00:00" mono header text
//   6. LumaHoldButtonStyle                    — tap vs. 0.6 s hold, separate callbacks
//
// Everything here is presentation-only: no app state, no engine imports.
// =============================================================================

// MARK: - 1. Custom presentation detents

/// Size-class-aware fixed-height detents for editor tool sheets.
///
/// Each detent is a hand-picked height in portrait on iPhone; in a vertically
/// compact environment (landscape phone) the same detent resolves to a
/// fraction of the available space instead, so a "small" panel never swallows
/// the whole canvas. All values are clamped to `maxDetentValue`.
private enum LumaDetentMetrics {
    /// Resolve a portrait design height against the current presentation
    /// context. In a vertically compact environment (landscape phone) the
    /// fixed height would swallow the canvas, so we fall back to a fraction
    /// of the available space instead. Always clamped to `maxDetentValue`.
    static func resolve(_ portraitHeight: CGFloat,
                        compactFraction: CGFloat,
                        in context: PresentationDetent.Context) -> CGFloat {
        if context.verticalSizeClass == .compact {
            return min(context.maxDetentValue * compactFraction, portraitHeight)
        }
        return min(portraitHeight, context.maxDetentValue)
    }
}

/// ~Dock height. Just enough for one row of tool icons — the sheet acts as a
/// persistent dock while the user works on the canvas above it.
struct LumaMicroDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        LumaDetentMetrics.resolve(96, compactFraction: 0.35, in: context)
    }
}

/// One row of options + a title (e.g. a look-strip picker).
struct LumaTinyDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        LumaDetentMetrics.resolve(160, compactFraction: 0.5, in: context)
    }
}

/// A compact control panel: title, a slider or two, confirm row.
struct LumaSmallDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        LumaDetentMetrics.resolve(280, compactFraction: 0.75, in: context)
    }
}

/// Full tool panel: grid of options plus controls, still leaving the top half
/// of the canvas visible.
struct LumaMediumDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        LumaDetentMetrics.resolve(340, compactFraction: 0.9, in: context)
    }
}

extension PresentationDetent {
    /// ~96 pt dock — one row of tool icons.
    static let lumaMicro = PresentationDetent.custom(LumaMicroDetent.self)
    /// ~160 pt — one option strip + title.
    static let lumaTiny = PresentationDetent.custom(LumaTinyDetent.self)
    /// ~280 pt — compact control panel.
    static let lumaSmall = PresentationDetent.custom(LumaSmallDetent.self)
    /// ~340 pt — full tool panel.
    static let lumaMedium = PresentationDetent.custom(LumaMediumDetent.self)
}

// MARK: - 2. Sheet style + .lumaToolSheet

/// Bundles everything that makes an editor sheet feel like a *tool panel*
/// rather than a modal: which detents it can rest at, up to which detent the
/// canvas behind it stays interactive (undimmed), and its chrome.
struct LumaSheetStyle {
    /// Detents the sheet can rest at, smallest first.
    var detents: Set<PresentationDetent>
    /// The canvas behind the sheet stays fully interactive (no dimming) up
    /// through this detent. `nil` = normal modal dimming.
    var undimmedUpThrough: PresentationDetent?
    /// Whether to show the system grabber.
    var showsDragIndicator: Bool = true
    /// Corner radius of the sheet chrome.
    var cornerRadius: CGFloat = 24
    /// Whether swiping the sheet down can dismiss it. Persistent docks set
    /// this `false` so the panel can only collapse, never vanish.
    var allowsDismissal: Bool = true

    /// Persistent tool dock: collapses to a 96 pt strip, expands to a panel,
    /// never dims the canvas, can't be swiped away.
    static let dock = LumaSheetStyle(
        detents: [.lumaMicro, .lumaMedium],
        undimmedUpThrough: .lumaMedium,
        showsDragIndicator: true,
        allowsDismissal: false
    )

    /// One-shot option strip (choose a look, pick a speed): tiny, undimmed,
    /// swipe to dismiss.
    static let strip = LumaSheetStyle(
        detents: [.lumaTiny],
        undimmedUpThrough: .lumaTiny
    )

    /// Adjustment panel with sliders: small ↔ medium, canvas live while small.
    static let panel = LumaSheetStyle(
        detents: [.lumaSmall, .lumaMedium],
        undimmedUpThrough: .lumaSmall
    )
}

private struct LumaToolSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let style: LumaSheetStyle
    let onDismiss: (() -> Void)?
    @ViewBuilder let sheetContent: () -> SheetContent

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
            sheetContent()
                .presentationDetents(style.detents)
                .presentationDragIndicator(style.showsDragIndicator ? .visible : .hidden)
                .presentationCornerRadius(style.cornerRadius)
                .presentationBackgroundInteraction(
                    style.undimmedUpThrough.map { .enabled(upThrough: $0) } ?? .disabled
                )
                // Solid dark sheet: the tool panels read as part of the same
                // black bar system, not frosted grey glass over content.
                .presentationBackground {
                    ZStack(alignment: .top) {
                        Rectangle().fill(LumaTheme.bar)
                        LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 1)
                    }
                }
                .interactiveDismissDisabled(!style.allowsDismissal)
                .preferredColorScheme(.dark)
        }
    }
}

extension View {
    /// Presents an editor tool sheet: custom detents, dark-material glass
    /// background, and — crucially — an *undimmed, interactive* canvas behind
    /// it up through `style.undimmedUpThrough`, so the user keeps scrubbing
    /// the timeline while the panel is docked.
    ///
    /// ```swift
    /// canvas.lumaToolSheet(isPresented: $showingTools, style: .dock) {
    ///     ToolDockContent()
    /// }
    /// ```
    func lumaToolSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        style: LumaSheetStyle = .panel,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(LumaToolSheetModifier(isPresented: isPresented,
                                       style: style,
                                       onDismiss: onDismiss,
                                       sheetContent: content))
    }
}

// MARK: - 3. Edge fade mask

/// Fades out the leading/trailing edges of a horizontal `ScrollView` so
/// content appears to slide out from under the chrome instead of being
/// clipped by a hard edge (look strips, the timeline ruler, filmstrips).
///
/// Implementation: the content is masked by an opaque rectangle from which
/// two edge gradients are *punched out* with `.destinationOut`, flattened by
/// a `compositingGroup` so the blend applies to the mask only. The mask is
/// rasterized with `drawingGroup()` — it is static per size, and this keeps
/// the per-frame cost flat while the scroller animates under it.
struct EdgeFadeMask: ViewModifier {
    /// Width of the leading fade. 0 disables it.
    var leading: CGFloat = 20
    /// Width of the trailing fade. 0 disables it.
    var trailing: CGFloat = 20

    func body(content: Content) -> some View {
        content.mask {
            ZStack {
                Rectangle()
                HStack(spacing: 0) {
                    if leading > 0 {
                        LinearGradient(colors: [.black, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: leading)
                    }
                    Spacer(minLength: 0)
                    if trailing > 0 {
                        LinearGradient(colors: [.clear, .black],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: trailing)
                    }
                }
                .blendMode(.destinationOut)
            }
            .compositingGroup()
            .drawingGroup()
        }
    }
}

extension View {
    /// Masks this view (typically a horizontal `ScrollView`) with soft
    /// gradient fades at the horizontal edges. Apply to the scroll view
    /// itself, not the content inside it.
    func lumaEdgeFade(leading: CGFloat = 20, trailing: CGFloat = 20) -> some View {
        modifier(EdgeFadeMask(leading: leading, trailing: trailing))
    }
}

// MARK: - 4. Timeline springs

/// Hand-tuned interpolating springs for editor chrome. `interpolatingSpring`
/// preserves gesture velocity when a drag hands off to an animation, which is
/// exactly what timeline chrome needs — a flicked panel should keep moving.
extension Animation {
    /// Timeline panel collapsing to its docked height: heavy-ish, minimal
    /// bounce, settles fast so playback controls land immediately.
    static let lumaTimelineCollapse = Animation.interpolatingSpring(
        mass: 1.0, stiffness: 320, damping: 32, initialVelocity: 0
    )

    /// Timeline panel expanding to full height: slightly softer than
    /// collapse, with a hint of overshoot so the expansion feels eager.
    static let lumaTimelineExpand = Animation.interpolatingSpring(
        mass: 1.0, stiffness: 260, damping: 26, initialVelocity: 0
    )

    /// A clip snapping into its slot after a drag: tight and crisp — one
    /// small overshoot, then dead. Pair with `LumaHaptics.shared.reorderDrop()`.
    static let lumaClipSnap = Animation.interpolatingSpring(
        mass: 0.6, stiffness: 420, damping: 26, initialVelocity: 0
    )

    /// The playhead or scrubber settling to a snapped position: no visible
    /// overshoot at all (a playhead that wobbles reads as broken).
    static let lumaScrubSettle = Animation.interpolatingSpring(
        mass: 0.5, stiffness: 380, damping: 38, initialVelocity: 0
    )

    /// Selection chrome (handles, borders) appearing on a clip: light and
    /// quick, a touch of bounce.
    static let lumaSelectionPop = Animation.interpolatingSpring(
        mass: 0.5, stiffness: 400, damping: 22, initialVelocity: 0
    )
}

// MARK: - 5. Technical readout

/// A single line of mono-spaced, uppercased, letter-spaced technical text —
/// "4K • 30 • 00:00:00" — for the camera HUD and editor headers. Segments
/// are joined with a dimmed bullet so the values read as separate fields.
struct TechnicalReadout: View {
    /// The fields to display, in order (e.g. `["4K", "30", "00:00:00"]`).
    let segments: [String]
    /// Point size of the text.
    var size: CGFloat = 12
    /// Foreground of the value segments.
    var tint: Color = LumaTheme.textSecondary
    /// One segment may be highlighted (e.g. the running timecode while
    /// recording). Index into `segments`, or `nil`.
    var emphasizedIndex: Int? = nil
    /// Color used for the emphasized segment.
    var emphasisTint: Color = .white

    /// Convenience: variadic segments.
    init(_ segments: String..., size: CGFloat = 12, tint: Color = LumaTheme.textSecondary,
         emphasizedIndex: Int? = nil, emphasisTint: Color = .white) {
        self.segments = segments
        self.size = size
        self.tint = tint
        self.emphasizedIndex = emphasizedIndex
        self.emphasisTint = emphasisTint
    }

    init(segments: [String], size: CGFloat = 12, tint: Color = LumaTheme.textSecondary,
         emphasizedIndex: Int? = nil, emphasisTint: Color = .white) {
        self.segments = segments
        self.size = size
        self.tint = tint
        self.emphasizedIndex = emphasizedIndex
        self.emphasisTint = emphasisTint
    }

    var body: some View {
        // Built as one Text so it wraps/truncates as a unit and tracking is
        // continuous across separators.
        segments.enumerated().reduce(Text("")) { acc, item in
            let (index, segment) = item
            let value = Text(segment.uppercased())
                .foregroundStyle(index == emphasizedIndex ? emphasisTint : tint)
            if index == 0 { return acc + value }
            let dot = Text(" \u{2022} ").foregroundStyle(tint.opacity(0.45))
            return acc + dot + value
        }
        .font(.system(size: size, weight: .semibold, design: .monospaced))
        .tracking(size * 0.09)
        .monospacedDigit()
        .lineLimit(1)
        .contentTransition(.numericText())
    }
}

// MARK: - 6. Hold button style

/// Distinguishes a **tap** from a **hold** on the same button with separate
/// callbacks — e.g. tap the record button for a quick clip, hold it for
/// press-and-hold recording; or tap a look to apply, hold to preview.
///
/// Mechanics: when the press begins, a task is scheduled for `holdDuration`
/// (default 0.6 s). If the finger lifts first, the task is cancelled and
/// `onTap` fires. If the task fires while still pressed, `onHold` fires
/// (with a medium haptic) and the eventual release is swallowed. If the
/// system cancels the press (scroll steal), neither callback fires.
///
/// Because the callbacks live in the style, pass an **empty action** to the
/// `Button` itself:
/// ```swift
/// Button {} label: { RecordGlyph() }
///     .buttonStyle(LumaHoldButtonStyle(
///         onTap: { camera.captureStill() },
///         onHold: { camera.beginRecording() },
///         onHoldEnd: { camera.endRecording() }
///     ))
/// ```
struct LumaHoldButtonStyle: ButtonStyle {
    /// Press duration after which the interaction becomes a hold.
    var holdDuration: TimeInterval = 0.6
    /// Scale applied while pressed (matches `.lumaPress` feel).
    var pressedScale: CGFloat = 0.94
    /// Fired when the finger lifts *before* `holdDuration`.
    var onTap: () -> Void
    /// Fired once, the moment the press crosses `holdDuration`.
    var onHold: () -> Void
    /// Fired when the finger lifts *after* a hold began (e.g. stop
    /// press-and-hold recording). Optional.
    var onHoldEnd: (() -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        HoldBody(configuration: configuration,
                 holdDuration: holdDuration,
                 pressedScale: pressedScale,
                 onTap: onTap,
                 onHold: onHold,
                 onHoldEnd: onHoldEnd)
    }

    /// `ButtonStyle.makeBody` can't own `@State`, so the press tracking lives
    /// in this nested view.
    private struct HoldBody: View {
        let configuration: Configuration
        let holdDuration: TimeInterval
        let pressedScale: CGFloat
        let onTap: () -> Void
        let onHold: () -> Void
        let onHoldEnd: (() -> Void)?

        @State private var holdTask: Task<Void, Never>?
        @State private var holdFired = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? pressedScale : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7),
                           value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed {
                        beginPress()
                    } else {
                        endPress()
                    }
                }
        }

        private func beginPress() {
            holdFired = false
            LumaHaptics.shared.prepare()
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                holdFired = true
                LumaHaptics.shared.reorderStart()
                onHold()
            }
        }

        private func endPress() {
            holdTask?.cancel()
            holdTask = nil
            if holdFired {
                onHoldEnd?()
            } else {
                LumaHaptics.shared.tap()
                onTap()
            }
            holdFired = false
        }
    }
}

// MARK: - Previews

#Preview("Tool sheet + detents") {
    struct SheetDemo: View {
        @State private var showDock = true
        @State private var showPanel = false

        var body: some View {
            ZStack {
                LumaTheme.background.ignoresSafeArea()
                VStack(spacing: 16) {
                    TechnicalReadout("4K", "30", "00:00:00")
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LumaTheme.tileIndigo)
                        .frame(height: 260)
                        .overlay(Text("CANVAS — stays interactive")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LumaTheme.textSecondary))
                    SolidCTA(title: "Adjust panel", icon: "slider.horizontal.3") {
                        showPanel = true
                    }
                    Spacer()
                }
                .padding(22)
            }
            .lumaToolSheet(isPresented: $showDock, style: .dock) {
                HStack(spacing: 0) {
                    FlatTool(title: "Looks", icon: "camera.filters", selected: true)
                    FlatTool(title: "Trim", icon: "timeline.selection")
                    FlatTool(title: "Speed", icon: "gauge.with.needle")
                    FlatTool(title: "Audio", icon: "waveform")
                }
                .padding(.top, 18)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .lumaToolSheet(isPresented: $showPanel, style: .panel) {
                VStack(spacing: 18) {
                    SectionHeader(title: "Adjust")
                    InlineSlider(title: "Intensity", value: .constant(64))
                    InlineSlider(title: "Warmth", value: .constant(38))
                    Spacer(minLength: 0)
                }
                .padding(22)
            }
            .preferredColorScheme(.dark)
        }
    }
    return SheetDemo()
}

#Preview("Edge fade mask") {
    ZStack {
        LumaTheme.background.ignoresSafeArea()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 12)
                        .fill(index % 2 == 0 ? LumaTheme.tilePurple : LumaTheme.tileTeal)
                        .frame(width: 84, height: 56)
                        .overlay(Text("\(index)")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white))
                }
            }
            .padding(.horizontal, 22)
        }
        .lumaEdgeFade(leading: 28, trailing: 28)
    }
    .preferredColorScheme(.dark)
}

#Preview("Timeline springs") {
    struct SpringDemo: View {
        @State private var expanded = false

        var body: some View {
            ZStack {
                LumaTheme.background.ignoresSafeArea()
                VStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LumaTheme.accentSoft)
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(LumaTheme.accent, lineWidth: 1.5))
                        .frame(height: expanded ? 220 : 84)
                        .overlay(Text(expanded ? "EXPANDED" : "COLLAPSED")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(LumaTheme.accentBright))
                    SolidCTA(title: expanded ? "Collapse" : "Expand") {
                        withAnimation(expanded ? .lumaTimelineCollapse : .lumaTimelineExpand) {
                            expanded.toggle()
                        }
                    }
                    Spacer()
                }
                .padding(22)
            }
            .preferredColorScheme(.dark)
        }
    }
    return SpringDemo()
}

#Preview("Technical readout") {
    ZStack {
        LumaTheme.background.ignoresSafeArea()
        VStack(spacing: 18) {
            TechnicalReadout("4K", "30", "00:00:00")
            TechnicalReadout("1080p", "60", "00:12:47", emphasizedIndex: 2,
                             emphasisTint: LumaTheme.recordRed)
            TechnicalReadout("HEVC", "Rec.709", "24 fps", size: 14, tint: LumaTheme.textMuted)
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Hold button") {
    struct HoldDemo: View {
        @State private var lastEvent = "—"

        var body: some View {
            ZStack {
                LumaTheme.background.ignoresSafeArea()
                VStack(spacing: 26) {
                    TechnicalReadout(segments: [lastEvent], size: 14, tint: LumaTheme.accentBright)
                    Button {} label: {
                        ZStack {
                            Circle().fill(LumaTheme.recordRed).frame(width: 74, height: 74)
                            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4)
                                .frame(width: 88, height: 88)
                        }
                    }
                    .buttonStyle(LumaHoldButtonStyle(
                        onTap: { lastEvent = "tap" },
                        onHold: { lastEvent = "hold began" },
                        onHoldEnd: { lastEvent = "hold ended" }
                    ))
                    Text("Tap for one event, hold 0.6 s for another")
                        .font(.system(size: 13))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
    return HoldDemo()
}

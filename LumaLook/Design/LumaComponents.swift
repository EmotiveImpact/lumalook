import SwiftUI

// MARK: - Press feedback

/// The single most important "native" cue: every tappable surface compresses
/// on touch with a spring, like a physical object.
struct LumaPressStyle: ButtonStyle {
    var scale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LumaPressStyle {
    static var lumaPress: LumaPressStyle { LumaPressStyle() }
}

// MARK: - Card depth

/// Night Lab panels: one value step above the canvas and no border, so the
/// fill alone carries the structure. No drop
/// shadow on ink; shadows are kept for things that float over footage.
struct LumaCardChrome: ViewModifier {
    var cornerRadius: CGFloat = 14
    /// Set when this card sits on top of another card and needs one more step.
    var raised: Bool = false
    /// Kept for source compatibility; panels on ink no longer cast shadows.
    var shadow: Bool = true

    func body(content: Content) -> some View {
        content
            .background(raised ? LumaTheme.cardRaised : LumaTheme.card,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LumaTheme.edge, lineWidth: 1)
            )
    }
}

extension View {
    func lumaCard(cornerRadius: CGFloat = 14, raised: Bool = false, shadow: Bool = true) -> some View {
        modifier(LumaCardChrome(cornerRadius: cornerRadius, raised: raised, shadow: shadow))
    }

    /// A borderless panel in any shape colour (default: panel).
    func lumaPanel(_ fill: Color = LumaTheme.card, cornerRadius: CGFloat = 14) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LumaTheme.edge, lineWidth: 1))
    }

    /// Glass pill over footage: dark translucent fill and blur.
    func lumaGlass(cornerRadius: CGFloat = 999) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(Color(hex: 0x0C0C0E, opacity: 0.45), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LumaTheme.edge, lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Screen shell with pinned glass header

private struct LumaScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct LumaScreen<Content: View>: View {
    let title: String
    var trailingIcon: String? = nil
    var trailingText: String? = nil
    var trailingAction: (() -> Void)? = nil
    var showBack: Bool = true
    var scrollable: Bool = true
    let content: Content
    @Environment(\.dismiss) private var dismiss
    @State private var scrolled = false

    init(title: String, trailingIcon: String? = nil, trailingText: String? = nil,
         trailingAction: (() -> Void)? = nil, showBack: Bool = true, scrollable: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailingIcon = trailingIcon
        self.trailingText = trailingText
        self.trailingAction = trailingAction
        self.showBack = showBack
        self.scrollable = scrollable
        self.content = content()
    }

    var body: some View {
        Group {
            if scrollable {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) { content }
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                        .padding(.bottom, 36)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: LumaScrollOffsetKey.self,
                                                       value: proxy.frame(in: .named("luma.scroll")).minY)
                            }
                        )
                }
                .coordinateSpace(name: "luma.scroll")
                .onPreferenceChange(LumaScrollOffsetKey.self) { offset in
                    // Only once content actually moves under the bar — at
                    // rest the header must match the app background exactly.
                    let isScrolled = offset < -6
                    if isScrolled != scrolled {
                        withAnimation(.easeInOut(duration: 0.18)) { scrolled = isScrolled }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 20) { content }
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LumaTheme.background.ignoresSafeArea())
        // Header pinned above the scroll: content passes under it and blurs
        // through the material once you scroll, exactly like a native bar.
        .safeAreaInset(edge: .top, spacing: 0) {
            LumaHeader(title: title, trailingIcon: trailingIcon, trailingText: trailingText,
                       trailingAction: trailingAction, showBack: showBack) { dismiss() }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .background {
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(LumaTheme.ink.opacity(0.94))
                        Hairline()
                    }
                    .ignoresSafeArea(edges: .top)
                    .opacity(scrolled ? 1 : 0)
                }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct LumaHeader: View {
    let title: String
    var trailingIcon: String? = nil
    var trailingText: String? = nil
    var trailingAction: (() -> Void)? = nil
    var showBack: Bool = true
    var backAction: () -> Void = {}

    var body: some View {
        ZStack {
            // Title Case, system-nav-bar weight — caps-tracked titles read
            // as web branding; Apple reads as headline.
            Text(title)
                .font(.luma(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(LumaTheme.textPrimary)
            HStack {
                if showBack {
                    Button(action: backAction) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.lumaPress)
                }
                Spacer()
                if let trailingText {
                    Button { trailingAction?() } label: {
                        Text(trailingText)
                            .font(.luma(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.lumaPress)
                } else if let trailingIcon {
                    Button { trailingAction?() } label: {
                        Image(systemName: trailingIcon)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
        }
        .frame(height: 44)
    }
}

// MARK: - Wordmark

/// The Lumalook mark: a signal-yellow frame square and the name with a
/// capital L, set tight in Inter Bold.
struct LumaWordmark: View {
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.32) {
            LumaMark(size: size * 0.66)
            Text("Lumalook")
                .font(.luma(size: size, weight: .bold))
                .tracking(-0.05 * size)
                .foregroundStyle(LumaTheme.textPrimary)
        }
    }
}

/// The square brand mark on its own (a frame inside a frame).
struct LumaMark: View {
    var size: CGFloat = 13

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(LumaTheme.signal)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .fill(LumaTheme.ink)
                    .padding(size * 0.21)
            )
            .frame(width: size, height: size)
    }
}

// MARK: - Tab top bar

/// Where the shared top row sits on every tab, so switching tabs never moves
/// it.
enum LumaTabMetrics {
    /// The row's top below the safe area, on every tab.
    static let top: CGFloat = 6
    static let rowHeight: CGFloat = 40
    static let sideInset: CGFloat = 16
    /// The bar's bottom edge below the safe area: the row plus a little air.
    /// Home's story bars start here at rest.
    static let barBottom: CGFloat = top + rowHeight + 8
}

/// The one row at the top of every tab. The left says where you are: the
/// tab's title, or the wordmark when there is none (Home builds the same row
/// on its photo, see HomeTopBar). The right never changes: Pro, then You.
/// Anything that belongs to one tab (search, import, new) lives in that
/// page, never in this row.
struct LumaTopBar: View {
    var title: String? = nil

    var body: some View {
        LumaTabHeader {
            if let title {
                LumaTabTitle(text: title)
            } else {
                LumaWordmark(size: 20)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Lumalook")
            }
        } trailing: {
            LumaTopBarButtons()
        }
    }
}

/// Pro and You, the right side of every tab's bar. Pro opens the paywall
/// while free, and once you have Pro it turns into a quiet badge that opens
/// your plan on the You tab. You jumps to the You tab and lights up white
/// while you are there.
///
/// `onPhoto` runs from 1 (the bar on Home's picture) to 0 (the bar on ink):
/// on the photo the glyph is white and the Pro badge frosted.
struct LumaTopBarButtons: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    var onPhoto: CGFloat = 0
    @State private var showPaywall = false

    var body: some View {
        HStack(spacing: 4) {
            proButton
            youButton
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private var proButton: some View {
        let pro = storeService.isPro
        return Button {
            if pro {
                openYou()
                // Already on You and scrolled down: bring the plan back up.
                NotificationCenter.default.post(name: .lumaShowPlan, object: nil)
            } else {
                showPaywall = true
            }
            LumaHaptics.shared.tap()
        } label: {
            LumaProBadge(isPro: pro, onPhoto: onPhoto)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(pro ? "Your plan, Pro" : "Get Pro")
    }

    private var youButton: some View {
        let here = app.tab == .profile
        let glyph = LumaTab.profile.icon
        return Button {
            openYou()
            LumaHaptics.shared.tap()
        } label: {
            ZStack {
                LumaTabGlyph(systemName: glyph, active: true)
                    .opacity(here ? 1 : onPhoto)
                LumaTabGlyph(systemName: glyph)
                    .opacity(here ? 0 : 1 - onPhoto)
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("You")
        .accessibilityAddTraits(here ? .isSelected : [])
    }

    private func openYou() {
        app.path = []
        app.tab = .profile
    }
}

extension Notification.Name {
    /// Asks the You tab to scroll its plan card into view (the Pro badge).
    static let lumaShowPlan = Notification.Name("lumalook.showPlan")
}

/// The Pro button's face: the calm chip from the approved calm mock. A quiet
/// frosted capsule with white text, the only colour being the small yellow
/// spark. Free reads "Get Pro"; Pro or Lifetime reads "Pro" on the same chip.
struct LumaProBadge: View {
    let isPro: Bool
    var onPhoto: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LumaTheme.signal)
            Text(isPro ? "Pro" : "Get Pro")
                .font(.luma(size: 13, weight: .semibold))
                .tracking(-0.1)
                .lineLimit(1)
                .foregroundStyle(LumaTheme.textPrimary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 32)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                    .opacity(onPhoto)
                Capsule().fill(Color.white.opacity(0.12))
            }
        }
        .fixedSize()
    }
}

/// The top row every tab shares (Home, Looks, Projects, You): the title on
/// the left, Home's being the wordmark, and the tab's actions on the right as
/// plain glyphs, all at one height and one inset.
struct LumaTabHeader<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 4) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: LumaTabMetrics.rowHeight)
        .padding(.horizontal, LumaTabMetrics.sideInset)
    }
}

/// A tab's title in the shared top row.
struct LumaTabTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.luma(size: 26, weight: .bold))
            .kerning(-1)
            .foregroundStyle(LumaTheme.textPrimary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One action in the shared top row: a plain glyph on a 40 pt target, grey
/// at rest and white while it is on (search open, say). No circle behind it.
struct LumaTabGlyph: View {
    let systemName: String
    var active: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(active ? LumaTheme.textPrimary : LumaTheme.textSecondary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }
}

// MARK: - Buttons

/// The one main action on a screen: signal yellow, ink text. With the
/// default fill it follows You › Appearance › Main buttons (yellow or quiet
/// white), see `LumaMainButton`.
struct SolidCTA: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 52
    var fill: Color = LumaTheme.signal
    var action: () -> Void
    @State private var fired = 0
    @AppStorage(LumaAppearance.buttonsKey) private var buttonsRaw = LumaMainButtonStyle.signal.rawValue

    var body: some View {
        let main = fill == LumaTheme.signal
        let style = LumaMainButtonStyle(rawValue: buttonsRaw) ?? .signal
        let resolvedFill = main ? style.fill : fill
        let resolvedText = main ? style.text : LumaTheme.textPrimary
        Button {
            fired += 1
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.luma(size: 16, weight: .semibold))
                    .tracking(-0.2)
            }
            .foregroundStyle(resolvedText)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(resolvedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .sensoryFeedback(.impact(weight: .light), trigger: fired)
    }
}

/// White button: the secondary action that still wants to be found.
struct WhiteCTA: View {
    let title: String
    var height: CGFloat = 52
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 16, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(LumaTheme.onLight)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(LumaTheme.textPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }
}

/// Quiet secondary action: a raised panel with a hairline.
struct GhostCTA: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 16, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(LumaTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .lumaPanel(LumaTheme.cardRaised, cornerRadius: 12)
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Chips & segments

/// Filter pill. Selected is a white pill with ink text; unselected is a
/// hairline outline with grey text.
struct Chip: View {
    let title: String
    var selected: Bool = false

    var body: some View {
        Text(title)
            .font(.luma(size: 14, weight: selected ? .semibold : .medium))
            .tracking(-0.1)
            .foregroundStyle(selected ? LumaTheme.onLight : LumaTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? LumaTheme.textPrimary : LumaTheme.chip))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : LumaTheme.edge, lineWidth: 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

/// Segmented control on a raised panel. The selected segment is one step
/// lighter and slides between options.
struct SegmentPills: View {
    let options: [String]
    @Binding var selection: String
    var caps: Bool = true
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = option
                    }
                } label: {
                    Text(option)
                        .font(.luma(size: 14, weight: selection == option ? .semibold : .medium))
                        .tracking(-0.1)
                        .foregroundStyle(selection == option ? LumaTheme.textPrimary : LumaTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LumaTheme.control)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(LumaTheme.edge, lineWidth: 1))
                                    .matchedGeometryEffect(id: "segment.pill", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .lumaPanel(LumaTheme.card, cornerRadius: 11)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Sliders

/// Reference-style inline row: Label —— slider —— value.
struct InlineSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var display: ((Double) -> String)? = nil

    // 20 haptic detents across the range, like a physical dial.
    private var tickIndex: Int {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return Int(((value - range.lowerBound) / span) * 20)
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(LumaTheme.textPrimary)
            Text(display?(value) ?? "\(Int(value))")
                .font(.luma(size: 17, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: Int(value))
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .trailing)
        }
        .sensoryFeedback(.selection, trigger: tickIndex)
    }
}

// MARK: - Tools

/// Bare icon + label (Choose Look tool row, editor tool rows).
struct FlatTool: View {
    let title: String
    let icon: String
    var selected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .symbolVariant(selected ? .fill : .none)
                Text(title)
                    .font(.luma(size: 13))
            }
            .foregroundStyle(selected ? LumaTheme.accentBright : LumaTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }
}

/// Rounded-square tile with the label below (Before/After tools, Format options).
struct ToolTile: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    var selected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button { action?() } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? AnyShapeStyle(LumaTheme.accentSoft) : AnyShapeStyle(LumaTheme.card))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(LumaTheme.edge, lineWidth: 1))
                    .frame(height: 62)
                    .overlay(Image(systemName: icon)
                        .font(.luma(size: 21, weight: .medium))
                        .foregroundStyle(selected ? LumaTheme.accentBright : .white))
                    // MEANINGFUL stroke: the selection ring. Unselected tiles
                    // carry no outline at all — they are just a lighter surface.
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(LumaTheme.accent, lineWidth: 1.5)
                        }
                    }
                Text(title)
                    .font(.luma(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? LumaTheme.accentBright : LumaTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let subtitle {
                    Text(subtitle)
                        .font(.luma(size: 12))
                        .foregroundStyle(selected ? LumaTheme.accentBright : LumaTheme.textMuted)
                        .padding(.top, -4)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.lumaPress)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

// MARK: - Section header

/// Linear-style section label: a short title in white, the action in grey.
struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.luma(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(LumaTheme.textPrimary)
            Spacer()
            if let actionTitle {
                Button { action?() } label: {
                    Text(actionTitle)
                        .font(.luma(size: 13, weight: .medium))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                .buttonStyle(.lumaPress)
            }
        }
    }
}

// MARK: - Rows

struct Hairline: View {
    var body: some View {
        Rectangle().fill(LumaTheme.hairline).frame(height: 1)
    }
}

// MARK: - Tab bar

/// Four tabs (Home, Looks, Projects, You) around a floating shutter that
/// opens the camera. Solid ink with a hairline on top; the active tab is
/// white, the rest grey.
struct LumaTabBar: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @State private var shutterTaps = 0

    private let leading: [LumaTab] = [.home, .looks]
    private let trailing: [LumaTab] = [.projects, .profile]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(leading, id: \.self) { tabButton($0) }
            // Room for the shutter. Height is pinned: an unsized Color is
            // greedy, and inside the bottom safe-area inset it stretched the
            // whole bar up the screen.
            Color.clear.frame(width: 84, height: 1)
            ForEach(trailing, id: \.self) { tabButton($0) }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background {
            ZStack(alignment: .top) {
                LumaTheme.bar
                Hairline()
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Button {
                shutterTaps += 1
                app.path = [.camera]
            } label: {
                LumaShutterGlyph(size: 62)
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel("Open camera")
            // Centred exactly where the camera's record button sits, so the
            // camera opens with its button under the thumb that just tapped
            // (both measure from the bottom safe area).
            .offset(y: -16)
            .sensoryFeedback(.impact(weight: .medium), trigger: shutterTaps)
        }
        .sensoryFeedback(.selection, trigger: app.tab)
    }

    private func isOn(_ tab: LumaTab) -> Bool {
        app.tab == tab || (tab == .looks && app.tab == .store)
    }

    private func tabButton(_ tab: LumaTab) -> some View {
        Button {
            app.path = []
            app.tab = tab
        } label: {
            VStack(spacing: 4) {
                tabGlyph(tab)
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if tab == .profile && storeService.isPro {
                            Text("Pro")
                                .font(.luma(size: 8, weight: .bold))
                                .foregroundStyle(LumaTheme.onSignal)
                                .fixedSize()
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(LumaTheme.signal, in: Capsule())
                                .offset(x: 14, y: -4)
                        }
                    }
                Text(tab.title)
                    .font(.luma(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn(tab) ? LumaTheme.textPrimary : LumaTheme.textMuted)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }

    /// Home wears our own house; the other tabs use SF Symbols.
    @ViewBuilder
    private func tabGlyph(_ tab: LumaTab) -> some View {
        if tab == .home {
            LumaHomeGlyph()
        } else {
            Image(systemName: tab.icon)
                .font(.system(size: 20, weight: .regular))
        }
    }
}

/// The Home tab icon: a house drawn in Night Lab shapes, rounded walls with
/// the logo mark's square as its window. Strokes match SF Symbols Regular at
/// 20 pt and take the foreground colour, so it greys out off the tab like
/// the symbols beside it.
struct LumaHomeGlyph: View {
    var size: CGFloat = 24

    var body: some View {
        let s = size / 24
        ZStack {
            HouseOutline()
                .stroke(style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round, lineJoin: .round))
            RoundedRectangle(cornerRadius: 1.3 * s, style: .continuous)
                .frame(width: 5 * s, height: 5 * s)
                .position(x: 12 * s, y: 14.9 * s)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Drawn on a 24 x 24 grid and scaled to the frame.
    private struct HouseOutline: Shape {
        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / 24
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
            }
            var path = Path()
            path.move(to: pt(3.8, 10.4))
            path.addLine(to: pt(12, 3.6))
            path.addLine(to: pt(20.2, 10.4))
            path.addArc(tangent1End: pt(20.2, 21), tangent2End: pt(18, 21), radius: 2.2 * s)
            path.addArc(tangent1End: pt(3.8, 21), tangent2End: pt(3.8, 10.4), radius: 2.2 * s)
            path.closeSubpath()
            return path
        }
    }
}

/// White ring, ink gap, signal-yellow centre: the shutter used in the tab bar
/// and on the photo camera. Pass `label` for a roll counter ("24").
struct LumaShutterGlyph: View {
    var size: CGFloat = 62
    var label: String? = nil
    var fill: Color = LumaTheme.signal

    var body: some View {
        ZStack {
            Circle().fill(LumaTheme.ink)
            Circle().strokeBorder(LumaTheme.textPrimary, lineWidth: size * 0.048)
            Circle()
                .fill(fill)
                .padding(size * 0.13)
            if let label {
                Text(label)
                    .font(.luma(size: size * 0.28, weight: .bold))
                    .tracking(-0.04 * size * 0.28)
                    .foregroundStyle(LumaTheme.onSignal)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

// MARK: - Export progress overlay

struct ExportOverlay: View {
    let progress: Double
    var cancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(LumaTheme.surfaceStrong, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: max(progress, 0.02))
                        .stroke(LumaTheme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.luma(size: 24, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: Int(progress * 100))
                        .foregroundStyle(.white)
                }
                .frame(width: 110, height: 110)

                Text("Exporting your video…")
                    .font(.luma(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Button("Cancel", action: cancel)
                    .font(.luma(size: 15, weight: .medium))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .buttonStyle(.lumaPress)
            }
            .padding(36)
        }
    }
}

// MARK: - Text pills

extension Text {
    func pill(border: Bool = false) -> some View {
        self
            .font(.luma(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .lumaGlass(cornerRadius: 12)
            // Only the "called out" variant draws a rim — that one means
            // something. The plain pill relies on its fill.
            .overlay {
                if border {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(LumaTheme.signal)
                }
            }
    }
}

// MARK: - Empty state

/// Shared "nothing here yet" block: icon, headline, one line of guidance and —
/// crucially — an actual place to tap. An empty screen should always point
/// somewhere. Center it in the space it owns; it sizes to its content.
struct LumaEmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(LumaTheme.textMuted)
            Text(title)
                .font(.luma(.headline))
                .foregroundStyle(LumaTheme.textSecondary)
            if let message {
                Text(message)
                    .font(.luma(.subheadline))
                    .foregroundStyle(LumaTheme.textMuted)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.luma(size: 16, weight: .semibold))
                        .foregroundStyle(LumaTheme.onSignal)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(LumaTheme.signal, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.lumaPress)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

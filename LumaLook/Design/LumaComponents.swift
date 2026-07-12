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

/// Dark-UI depth trick: a top-lit hairline gradient instead of a flat border.
struct LumaCardChrome: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func lumaCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(LumaCardChrome(cornerRadius: cornerRadius))
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
                    let isScrolled = offset < 4
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
                        Rectangle().fill(.ultraThinMaterial)
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
                .font(.headline)
                .foregroundStyle(.white)
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
                            .font(.system(size: 17, weight: .semibold))
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

struct LumaWordmark: View {
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            Text("LUMA")
                .foregroundStyle(.white)
            Text("LOOK")
                .foregroundStyle(LumaTheme.wordmarkViolet)
        }
        .font(.system(size: size, weight: .semibold))
        .tracking(size * 0.22)
    }
}

// MARK: - Buttons

struct SolidCTA: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 58
    var fill: Color = LumaTheme.accent
    var action: () -> Void
    @State private var fired = 0

    var body: some View {
        Button {
            fired += 1
            action()
        } label: {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .bold))
                }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                LinearGradient(colors: [fill.opacity(1.0), fill.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.0)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: fill.opacity(0.35), radius: 16, y: 6)
        }
        .buttonStyle(.lumaPress)
        .sensoryFeedback(.impact(weight: .light), trigger: fired)
    }
}

struct GhostCTA: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Chips & segments

struct Chip: View {
    let title: String
    var selected: Bool = false

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                if selected {
                    Capsule().fill(LumaTheme.accent)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.18 : 0.07), lineWidth: 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

/// Equal-width capsule segments (VIDEO / PHOTOS, IMPORTED / FAVORITES / RECENTS).
/// The selected capsule physically slides between options.
struct SegmentPills: View {
    let options: [String]
    @Binding var selection: String
    var caps: Bool = true
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = option
                    }
                } label: {
                    Text(option)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == option ? .white : LumaTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background {
                            if selection == option {
                                Capsule()
                                    .fill(LumaTheme.accent)
                                    .matchedGeometryEffect(id: "segment.pill", in: ns)
                            } else {
                                Capsule().fill(.ultraThinMaterial)
                            }
                        }
                        .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(LumaTheme.accent)
            Text(display?(value) ?? "\(Int(value))")
                .font(.system(size: 17, weight: .bold))
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
                    .font(.system(size: 13))
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
                    .fill(selected ? AnyShapeStyle(LumaTheme.accentSoft) : AnyShapeStyle(.ultraThinMaterial))
                    .frame(height: 62)
                    .overlay(Image(systemName: icon)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(selected ? LumaTheme.accentBright : .white))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                selected
                                    ? AnyShapeStyle(LumaTheme.accent)
                                    : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)],
                                                                   startPoint: .top, endPoint: .bottom)),
                                lineWidth: selected ? 1.5 : 1
                            )
                    )
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? LumaTheme.accentBright : LumaTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
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

struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(LumaTheme.textSecondary)
            Spacer()
            if let actionTitle {
                Button { action?() } label: {
                    Text(actionTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LumaTheme.accentBright)
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

struct LumaTabBar: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack {
            ForEach(LumaTab.allCases, id: \.self) { tab in
                Button {
                    app.path = []
                    app.tab = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 21, weight: .regular))
                            .symbolVariant(app.tab == tab ? .fill : .none)
                            .symbolEffect(.bounce.up.byLayer, options: .speed(1.4), value: app.tab == tab)
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: app.tab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(app.tab == tab ? LumaTheme.accentBright : LumaTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        // Solid near-black bar (reference mock) — content fades out above it
        // instead of tinting through it.
        .background {
            Color(red: 0.02, green: 0.025, blue: 0.04).opacity(0.98)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
        .sensoryFeedback(.selection, trigger: app.tab)
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
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: Int(progress * 100))
                        .foregroundStyle(.white)
                }
                .frame(width: 110, height: 110)

                Text("Exporting your video…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Button("Cancel", action: cancel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LumaTheme.accentBright)
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
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(border ? LumaTheme.accentBright : .white.opacity(0.12)))
    }
}

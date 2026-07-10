import SwiftUI

// MARK: - Screen shell with flat caps header

struct LumaScreen<Content: View>: View {
    let title: String
    var trailingIcon: String? = nil
    var trailingText: String? = nil
    var trailingAction: (() -> Void)? = nil
    var showBack: Bool = true
    var scrollable: Bool = true
    let content: Content
    @Environment(\.dismiss) private var dismiss

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
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                LumaHeader(title: title, trailingIcon: trailingIcon, trailingText: trailingText,
                           trailingAction: trailingAction, showBack: showBack) { dismiss() }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                if scrollable {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 20) { content }
                            .padding(.horizontal, 22)
                            .padding(.bottom, 90)
                    }
                } else {
                    VStack(spacing: 20) { content }
                        .padding(.horizontal, 22)
                    Spacer(minLength: 0)
                }
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
            Text(title.uppercased())
                .font(.system(size: 17, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(.white)
            HStack {
                if showBack {
                    Button(action: backAction) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40, alignment: .leading)
                    }
                }
                Spacer()
                if let trailingText {
                    Button { trailingAction?() } label: {
                        Text(trailingText)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                } else if let trailingIcon {
                    Button { trailingAction?() } label: {
                        Image(systemName: trailingIcon)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40, alignment: .trailing)
                    }
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .bold))
                }
                Text(title.uppercased())
                    .font(.system(size: 17, weight: .bold))
                    .tracking(1.6)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

struct GhostCTA: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 17, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(LumaTheme.hairline))
        }
        .buttonStyle(.plain)
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
            .background(selected ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
    }
}

/// Equal-width capsule segments (VIDEO / PHOTOS, IMPORTED / FAVORITES / RECENTS).
struct SegmentPills: View {
    let options: [String]
    @Binding var selection: String
    var caps: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(caps ? option.uppercased() : option)
                        .font(.system(size: 14, weight: .bold))
                        .tracking(caps ? 1.2 : 0)
                        .foregroundStyle(selection == option ? .white : LumaTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(selection == option ? LumaTheme.accent : LumaTheme.surface,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Sliders

/// Reference-style inline row: Label —— slider —— value.
struct InlineSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var display: ((Double) -> String)? = nil

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
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .trailing)
        }
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
                Text(title)
                    .font(.system(size: 13))
            }
            .foregroundStyle(selected ? LumaTheme.accentBright : LumaTheme.textSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
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
                    .fill(selected ? LumaTheme.accentSoft : LumaTheme.surface)
                    .frame(height: 62)
                    .overlay(Image(systemName: icon)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(selected ? LumaTheme.accentBright : .white))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(selected ? LumaTheme.accent : .clear, lineWidth: 1.5))
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
        .buttonStyle(.plain)
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
                .font(.system(size: 15, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(.white)
            Spacer()
            if let actionTitle {
                Button { action?() } label: {
                    Text(actionTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .buttonStyle(.plain)
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
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: app.tab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(app.tab == tab ? LumaTheme.accentBright : LumaTheme.textMuted)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Export progress overlay

struct ExportOverlay: View {
    let progress: Double
    var cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
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
                        .foregroundStyle(.white)
                }
                .frame(width: 110, height: 110)

                Text("Exporting your video…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Button("Cancel", action: cancel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LumaTheme.accentBright)
            }
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
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(border ? LumaTheme.accentBright : .white.opacity(0.12)))
    }
}

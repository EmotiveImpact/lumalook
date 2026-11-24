import SwiftUI
import UIKit
import AVFoundation

// =============================================================================
// "Push, never cover."
//
// Opening a tool COMPRESSES the preview and leaves this miniature timeline
// under it, so tuning a value and finding the frame it applies to stay one
// gesture apart. The tool drawer itself is an inline region of the editor's
// own layout now — not a sheet — so the preview height falls out of the
// VStack and no geometry probing is needed to keep the two from overlapping.
// =============================================================================

/// Geometry of the push-up frame.
enum ToolPanelMetrics {
    /// Height of the mini timeline strip.
    static let stripHeight: CGFloat = 74
    /// Gap between the preview and the mini timeline strip.
    static let stripTopPadding: CGFloat = 10
}

/// A read-and-scrub-only miniature of the timeline: the clip filmstrip plus
/// the first audio lane, under a fixed centre playhead. Dragging scrubs the
/// same `editor.seek` the full timeline drives.
struct MiniTimelineStrip: View {
    @ObservedObject var editor: EditorState
    /// Shared zoom (points per second) so the strip matches the full timeline.
    let zoom: CGFloat

    /// Playhead time when the current scrub began.
    @State private var scrubAnchor: Double?

    private var clipHeight: CGFloat { 34 }
    private var audioHeight: CGFloat { 20 }

    var body: some View {
        GeometryReader { geo in
            // Centre-fixed, matching the main timeline: the playhead holds
            // station and the film runs under it. A mini strip on a different
            // model would flip the mental model the moment a tool opened.
            let centre = geo.size.width / 2
            let offset = centre - CGFloat(editor.currentTime) * zoom
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(editor.clips) { clip in
                            TimelineClipCell(clip: clip,
                                             width: max(CGFloat(clip.timelineDuration) * zoom, 10),
                                             selected: clip.id == editor.selectedClipID)
                                .frame(height: clipHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .frame(height: clipHeight)
                    if let track = editor.audioTracks.first {
                        MiniAudioBar(track: track)
                            .frame(width: max(CGFloat(track.timelineDuration) * zoom, 12),
                                   height: audioHeight)
                            .offset(x: CGFloat(track.timelineOffset) * zoom)
                    }
                }
                .offset(x: offset)
                .allowsHitTesting(false)

                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .offset(x: centre - 1)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let anchor = scrubAnchor ?? editor.currentTime
                        if scrubAnchor == nil { scrubAnchor = anchor }
                        let delta = Double(-value.translation.width / max(zoom, 1))
                        editor.seek(to: min(max(0, anchor + delta), editor.totalDuration))
                    }
                    .onEnded { _ in scrubAnchor = nil }
            )
        }
        .frame(height: ToolPanelMetrics.stripHeight)
    }
}

/// The audio lane, miniature: kind glyph, title, and the real waveform. The
/// lane is identified by its glyph and its name, not by a hue — colour on this
/// screen belongs to content the user chose.
private struct MiniAudioBar: View {
    let track: EditorState.MusicTrack

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LumaTheme.surfaceStrong)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(LumaTheme.edge, lineWidth: 1))
            if !track.waveform.isEmpty {
                MiniWaveform(samples: track.waveform)
                    .padding(.horizontal, 5)
            }
            HStack(spacing: 4) {
                Image(systemName: track.kind.icon)
                    .font(.system(size: 8, weight: .semibold))
                Text(track.title)
                    .font(.luma(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MiniWaveform: View {
    let samples: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard !samples.isEmpty else { return }
            let bars = max(4, Int(size.width / 3))
            for i in 0..<bars {
                let frac = Double(i) / Double(bars)
                let sample = samples[min(samples.count - 1, Int(frac * Double(samples.count)))]
                let h = max(1.5, CGFloat(abs(sample)) * size.height * 0.9)
                let rect = CGRect(x: CGFloat(i) * size.width / CGFloat(bars),
                                  y: (size.height - h) / 2, width: 1.6, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                         with: .color(.white.opacity(0.55)))
            }
        }
        .allowsHitTesting(false)
    }
}

// =============================================================================
// Night Lab round three: the editor's dock, the More tools sheet, the look
// drawer's tiles and the preview surface. Presentation only; the editor wires
// every action, so nothing here knows about tools or the engine.
// =============================================================================

// MARK: - Preview surface

/// The preview, bare: an AVPlayerLayer with no system controls, so nothing
/// is ever drawn over the picture. Aspect-fit on black inside a frame the
/// editor sizes to the project's canvas.
struct EditorPreviewSurface: UIViewRepresentable {
    let player: AVPlayer

    final class SurfaceView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

// MARK: - Dock

/// One of the six dock tools: icon over label, equal width. The dock stays
/// quiet (calm mock v2): the open tool is simply white, the rest grey. Signal
/// yellow belongs to Export, the one main action on the editor.
struct EditorDockButton: View {
    let title: String
    let icon: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 22)
                    .foregroundStyle(active ? LumaTheme.textPrimary : LumaTheme.textPrimary.opacity(0.82))
                Text(title)
                    .font(.luma(size: 11, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(active ? LumaTheme.textPrimary : LumaTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - More tools sheet

/// One tile in the More sheet.
struct EditorToolEntry: Identifiable {
    let title: String
    let icon: String
    var enabled: Bool = true
    var active: Bool = false
    let action: () -> Void

    var id: String { title }
}

/// A titled group of tiles (Create, Colour, Layers, Sound).
struct EditorToolGroup: Identifiable {
    let title: String
    let entries: [EditorToolEntry]

    var id: String { title }
}

/// Every tool the dock doesn't carry, in plain groups, with templates as one
/// band at the foot. Search filters the tiles by name.
struct EditorMoreToolsSheet: View {
    let groups: [EditorToolGroup]
    let onTemplates: () -> Void

    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private static let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var visibleGroups: [EditorToolGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group -> EditorToolGroup? in
            let hits = group.entries.filter { $0.title.lowercased().contains(needle) }
            return hits.isEmpty ? nil : EditorToolGroup(title: group.title, entries: hits)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 4)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(visibleGroups) { group in
                        groupSection(group)
                    }
                    if visibleGroups.isEmpty {
                        Text("No tool by that name")
                            .font(.luma(size: 13))
                            .foregroundStyle(LumaTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            if LumaFeatures.templates {
                templateBand
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
        .background(LumaTheme.panel.ignoresSafeArea())
    }

    @ViewBuilder
    private var header: some View {
        if searching {
            searchField
        } else {
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("More")
                        .font(.luma(size: 22, weight: .light))
                    Text("tools")
                        .font(.luma(size: 22, weight: .bold))
                }
                .foregroundStyle(LumaTheme.textPrimary)
                Spacer(minLength: 0)
                Button {
                    searching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Search tools")
            }
            .frame(height: 40)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
                TextField("Search tools", text: $query)
                    .font(.luma(size: 15))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onAppear {
                        DispatchQueue.main.async { searchFocused = true }
                    }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(LPanelStyle.glass, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Button {
                query = ""
                searchFocused = false
                searching = false
            } label: {
                Text("Cancel")
                    .font(.luma(size: 14, weight: .medium))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        }
        .frame(height: 40)
    }

    private func groupSection(_ group: EditorToolGroup) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(group.title)
                .font(.luma(size: 12.5, weight: .semibold))
                .foregroundStyle(LumaTheme.textMuted)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                ForEach(group.entries) { entry in
                    EditorToolTile(entry: entry)
                }
            }
        }
    }

    private var templateBand: some View {
        Button(action: onTemplates) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(LPanelStyle.glass, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start from a template")
                        .font(.luma(size: 15, weight: .semibold))
                        .foregroundStyle(LumaTheme.textPrimary)
                    Text("Your clips, cut to a ready-made edit")
                        .font(.luma(size: 12.5))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 64)
            // Quiet glass: a way in, not the screen's main action.
            .background(LPanelStyle.glass, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }
}

/// A tool tile: the glyph on a quiet glass square, its name underneath. The
/// open tool is white, the rest a step greyer.
private struct EditorToolTile: View {
    let entry: EditorToolEntry

    var body: some View {
        Button(action: entry.action) {
            VStack(spacing: 6) {
                Image(systemName: entry.icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(entry.active ? LumaTheme.textPrimary : LumaTheme.textPrimary.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(entry.active ? LPanelStyle.glassStrong : LPanelStyle.glass,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(entry.title)
                    .font(.luma(size: 11.5, weight: entry.active ? .semibold : .medium))
                    .foregroundStyle(entry.active ? LumaTheme.textPrimary : LumaTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .opacity(entry.enabled ? 1 : 0.32)
        .disabled(!entry.enabled)
        .accessibilityLabel(entry.title)
    }
}

// MARK: - Look drawer parts

/// Two-way switch for the drawer header ("This clip" / "All clips"): words,
/// the picked one white on a little glass, the other grey. No box around it.
struct EditorMiniSegment: View {
    let options: [String]
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                LPanelFilterTab(title: options[index], isOn: index == selection) {
                    if index != selection { onSelect(index) }
                }
            }
        }
    }
}

/// A look tile in the editor's drawer: the real grade on the clip's own
/// frame, the look's short name on it, its full name underneath, and the
/// picked ring while it is applied.
struct EditorLookTile: View {
    let image: CGImage?
    let code: String
    let name: String
    var picked = false
    var locked = false
    /// The look's own colour for its code. Nil reads it from the name.
    var colour: Color? = nil

    static let width: CGFloat = 70

    private var codeColour: Color { colour ?? LookSignature.colour(forLookNamed: name) }
    static let height: CGFloat = 86

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                artwork
                LinearGradient(colors: [.clear, .black.opacity(0.72)],
                               startPoint: .center, endPoint: .bottom)
                // The code in the look's own colour (or white with a dot, per
                // You › Appearance), with the dot kept since it sits on a frame.
                LookNameText(code, colour: codeColour, size: 12, weight: .bold, alwaysDot: true)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 5)
            }
            .frame(width: Self.width, height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // clipShape clips pixels, not touches: without this the
            // overflowing fill steals its neighbour's taps.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if locked { LookLockGlyph(compact: true) }
            }
            .pickedRing(picked, cornerRadius: 10)
            Text(name)
                .font(.luma(size: 11, weight: .medium))
                .foregroundStyle(picked ? LumaTheme.textPrimary : LumaTheme.textMuted)
                .lineLimit(1)
                .frame(width: Self.width)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.width, height: Self.height)
        } else {
            Color(white: 0.12)
        }
    }

    /// "KD2" for a stock look, else the first word ("Neon" for Neon Nights).
    static func code(for name: String) -> String {
        if let code = LookSignature.code(in: name) { return code }
        let title = LookSignature.title(in: name)
        return title.split(separator: " ").first.map(String.init) ?? title
    }
}

/// A tile with a glyph instead of a frame (None, All looks), sized to sit in
/// a row of `EditorLookTile`s.
struct EditorPlainTile: View {
    let icon: String
    let title: String
    var picked = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                LPanelStyle.glass
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(LumaTheme.textSecondary)
            }
            .frame(width: EditorLookTile.width, height: EditorLookTile.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .pickedRing(picked, cornerRadius: 10)
            Text(title)
                .font(.luma(size: 11, weight: .medium))
                .foregroundStyle(picked ? LumaTheme.textPrimary : LumaTheme.textMuted)
                .lineLimit(1)
                .frame(width: EditorLookTile.width)
        }
    }
}

// =============================================================================
// Calm panel parts (calm mock v2, 06-editor.jpg): quiet glass, text tabs,
// quiet pills and the amount slider that follows You › Appearance. Shared by
// the editor's tool panels and the export screens. Prefixed LPanel so they
// never collide with the atoms elsewhere.
// =============================================================================

enum LPanelStyle {
    /// Quiet glass: tools, chips, secondary pills (white at 7%).
    static let glass = Color.white.opacity(0.07)
    /// One step up: a picked filter, an engaged tool (white at 12%).
    static let glassStrong = Color.white.opacity(0.12)
    /// The fill of an "on" quiet pill (Loop, a picked effect).
    static let onFill = Color.white.opacity(0.9)
    /// Text on that fill.
    static let onText = Color(hex: 0x0B0C0E)
    /// Grey words: unpicked tabs and labels.
    static let quietText = Color.white.opacity(0.42)
    /// A switch that is on: quiet grey, never the signal.
    static let toggleTint = Color(hex: 0x8E929A)
}

/// Text tabs: words in a row, the picked one white with a short white line
/// under it, the rest grey. Used instead of boxed segmented controls.
struct LPanelTabs: View {
    let labels: [String]
    let selected: Int?
    var size: CGFloat = 13.5
    var spacing: CGFloat = 18
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(labels.indices, id: \.self) { index in
                tab(index)
            }
        }
    }

    private func tab(_ index: Int) -> some View {
        let isOn = index == selected
        return Button {
            onSelect(index)
        } label: {
            Text(labels[index])
                .font(.luma(size: size, weight: .semibold))
                .foregroundStyle(isOn ? LumaTheme.textPrimary : LPanelStyle.quietText)
                .lineLimit(1)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    if isOn {
                        Capsule()
                            .fill(Color.white)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A filter word: grey, or white on a little glass when picked (All looks,
/// moods, This clip / All clips).
struct LPanelFilterTab: View {
    let title: String
    var icon: String? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.luma(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? LumaTheme.textPrimary : Color.white.opacity(0.5))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(isOn ? Color.white.opacity(0.13) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A quiet pill: glass with grey-white words, or near-white with ink words
/// when on (Mute, Duck under voice, Loop; effect and shape choices).
struct LPanelPill: View {
    let title: String
    var icon: String? = nil
    var isOn: Bool = false
    var height: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.luma(size: 13.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? LPanelStyle.onText : Color.white.opacity(0.8))
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(isOn ? LPanelStyle.onFill : LPanelStyle.glass, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small heading inside a panel, in sentence case and grey.
struct LPanelLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.luma(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.48))
    }
}

/// An amount (strength, wet, feather, size) as the Sliders choice says. With
/// the ruler it shows its own "Wet 40%" line above the 48 pt ruler; the dial
/// draws its own title and big value, so the line is left out then.
struct LPanelAmount: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw: String = LumaSliderStyle.ruler.rawValue

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...100,
         format: @escaping (Double) -> String = { "\(Int($0.rounded()))%" }) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        let dial = (LumaSliderStyle(rawValue: sliderRaw) ?? .ruler) == .dial
        VStack(spacing: 2) {
            if !dial {
                HStack {
                    Text(title)
                        .font(.luma(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer(minLength: 8)
                    Text(format(value))
                        .font(.luma(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(LumaTheme.textPrimary)
                }
            }
            LumaValueSlider(value: $value, range: range, title: title, format: format)
        }
    }
}

/// A panel's confirm (Done, Use, Generate captions) inside the editor: a
/// near-white pill with ink words, like "Shape this audio lane · Done" in the
/// calm mock. It is never the signal: on the editor that belongs to Export,
/// the one main action. `fullWidth` makes it a 48 pt bar instead of a pill.
struct LPanelConfirmButton: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 32
    var fullWidth: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: fullWidth ? 15 : 12, weight: .semibold))
                }
                Text(title)
                    .font(.luma(size: fullWidth ? 15.5 : 13.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(LPanelStyle.onText)
            .padding(.horizontal, fullWidth ? 18 : 15)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(LPanelStyle.onFill, in: confirmShape)
            .contentShape(confirmShape)
        }
        .buttonStyle(.lumaPress)
        .fixedSize(horizontal: !fullWidth, vertical: false)
    }

    private var confirmShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: fullWidth ? 14 : height / 2, style: .continuous)
    }
}

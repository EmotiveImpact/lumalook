import SwiftUI

// =============================================================================
// B3 — the push-up tool-panel pattern, generalised.
//
// Every editor tool panel follows the same shape: the preview compresses to a
// fixed height, a mini timeline strip stays under it so the edit can still be
// scrubbed while a value is tuned, and the panel itself owns the rest of the
// screen at full uncropped height with sub-tools as chips and one Done.
//
// This file holds the two reusable pieces — `MiniTimelineStrip` and
// `ToolPanelScaffold` — that make that shape identical everywhere instead of
// each panel improvising it.
// =============================================================================

/// Geometry of the B3 push-up frame.
///
/// The compressed preview used to be a CONSTANT, which is what broke B3 both
/// ways: against a 620 pt sheet the preview and the whole mini strip ended up
/// *behind* the panel, and against a 340 pt sheet a ~140 pt band of dead black
/// opened up between the strip and the sheet. It is now derived from the space
/// the open panel actually leaves, so the preview always ends exactly where the
/// sheet begins — never covered, never floating above a gap.
enum ToolPanelMetrics {
    /// Fallback used before the geometry probe has reported (first frame only).
    static let compressedPreview: CGFloat = 236
    /// Floor: below this the preview is too small to judge a grade in.
    static let minPreview: CGFloat = 150
    static let stripHeight: CGFloat = 74
    /// Gap between the preview and the mini timeline strip.
    static let stripTopPadding: CGFloat = 10

    /// Height `.lumaMedium` resolves to — the detent most tool panels open at.
    /// Mirrors `LumaMediumDetent` in EditorChrome.swift; if that changes, this
    /// must follow.
    static let panelDetentHeight: CGFloat = 340
    /// Height `.lumaSmall` resolves to, for panels whose controls fit it.
    static let smallPanelDetentHeight: CGFloat = 280

    /// Ceiling used only until the natural (uncompressed) preview height has
    /// been measured. Opening a panel must never GROW the preview.
    static let maxPreview: CGFloat = 330

    /// Preview height that exactly fills the space above an open panel.
    ///
    /// - Parameters:
    ///   - spaceToPanelBaseline: distance from the top of the editor's content
    ///     area to the edge a sheet detent is measured from — the SAFE-AREA
    ///     bottom, not the physical screen bottom. Measuring to the physical
    ///     bottom overstated the room by the home-indicator inset and pushed
    ///     the mini strip under the sheet.
    ///   - headerHeight: measured height of the editor header row.
    ///   - panelHeight: the detent height the open panel actually uses.
    ///   - naturalPreview: measured height the preview takes with no panel
    ///     open; the compressed height is clamped to it so a panel always
    ///     shrinks the preview instead of adding letterbox. 0 = not measured.
    static func previewHeight(spaceToPanelBaseline: CGFloat,
                              headerHeight: CGFloat,
                              panelHeight: CGFloat = panelDetentHeight,
                              naturalPreview: CGFloat = 0) -> CGFloat {
        let ceiling = naturalPreview > 0 ? naturalPreview : maxPreview
        guard spaceToPanelBaseline > 0 else { return min(compressedPreview, ceiling) }
        let above = spaceToPanelBaseline - panelHeight - headerHeight
        let fitted = above - stripHeight - stripTopPadding
        return max(minPreview, min(fitted, ceiling))
    }
}

/// Measured height of the editor header row.
struct ToolPanelHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Distance from the top of the editor content area to the safe-area bottom —
/// the yardstick a sheet detent is measured against.
struct ToolPanelSpaceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Height the preview resolves to with NO panel open. The compressed height is
/// clamped to this so opening a panel can only ever shrink the preview.
struct NaturalPreviewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A read-and-scrub-only miniature of the timeline: the clip filmstrip plus
/// the first audio lane, under a fixed centre playhead. Dragging scrubs the
/// same `editor.seek` the full timeline drives, so tuning a value and finding
/// the frame it applies to stay one gesture apart.
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
                        MiniAudioBar(track: track, zoom: zoom)
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

/// The audio lane, miniature: kind tint, title, and the real waveform.
private struct MiniAudioBar: View {
    let track: EditorState.MusicTrack
    let zoom: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(track.kind.tint.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(track.kind.tint.opacity(0.6), lineWidth: 1))
            if !track.waveform.isEmpty {
                MiniWaveform(samples: track.waveform, tint: track.kind.tint)
                    .padding(.horizontal, 5)
            }
            HStack(spacing: 4) {
                Image(systemName: track.kind.icon)
                    .font(.system(size: 8, weight: .bold))
                Text(track.title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MiniWaveform: View {
    let samples: [Float]
    let tint: Color

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

// MARK: - Panel scaffold

/// Shared chrome for a push-up tool panel: title row with one unambiguous
/// Done, an optional sub-tool chip row, then the panel's own controls in a
/// scroller that can never clip them.
struct ToolPanelScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Sub-tool chips. Empty = no chip row.
    var chips: [String] = []
    var selectedChip: String?
    var onSelectChip: ((String) -> Void)?
    let onDone: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LumaTheme.accentBright)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
            .padding(.horizontal, 20)

            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            ToolPanelChip(title: chip, selected: chip == selectedChip) {
                                onSelectChip?(chip)
                                LumaHaptics.shared.tap()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .lumaEdgeFade(leading: 12, trailing: 12)
            }

            ScrollView {
                content()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// B1 empty-state call to action. Two of these sit side by side at equal
/// weight — neither path is the fallback.
struct EmptyStateCTA: View {
    let title: String
    let caption: String
    let icon: String
    /// The filled variant carries the accent; the ghost carries a hairline.
    let filled: Bool
    var iconTint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconTint ?? .white)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(caption)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(filled ? .white.opacity(0.65) : LumaTheme.textMuted)
                    .lineLimit(1)
            }
            .frame(width: 138)
            .padding(.vertical, 18)
            .background(filled ? AnyShapeStyle(LumaTheme.accent)
                               : AnyShapeStyle(LumaTheme.surface),
                        in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(filled ? 0.18 : 0.10), lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
    }
}

/// B2 contextual clip action: a compact icon+label chip. Delete renders red
/// so the destructive action is never mistaken for the others.
struct ClipActionChip: View {
    let title: String
    let icon: String
    var selected: Bool = false
    var destructive: Bool = false
    let action: () -> Void

    private var tint: Color {
        if destructive { return LumaTheme.orange }
        return selected ? .white : LumaTheme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(LumaTheme.accent)
                                 : AnyShapeStyle(LumaTheme.surface),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
    }
}

/// Sub-tool chip inside a panel.
struct ToolPanelChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(LumaTheme.accent)
                                     : AnyShapeStyle(LumaTheme.surface),
                            in: Capsule())
        }
        .buttonStyle(.lumaPress)
    }
}

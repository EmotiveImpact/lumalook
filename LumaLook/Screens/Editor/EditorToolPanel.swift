import SwiftUI

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
            // Left-anchored with a follow band, matching the main timeline.
            // A centre-fixed mini strip flipped the model the moment a tool
            // opened: content jumped to the middle of the strip mid-edit.
            let playheadX = CGFloat(editor.currentTime) * zoom
            let follow = geo.size.width * 0.65
            let offset = -max(0, playheadX - follow)
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
                    .offset(x: playheadX + offset - 1)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let anchor = scrubAnchor ?? editor.currentTime
                        if scrubAnchor == nil { scrubAnchor = anchor }
                        let delta = Double(value.translation.width / max(zoom, 1))
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
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            if !track.waveform.isEmpty {
                MiniWaveform(samples: track.waveform)
                    .padding(.horizontal, 5)
            }
            HStack(spacing: 4) {
                Image(systemName: track.kind.icon)
                    .font(.system(size: 8, weight: .semibold))
                Text(track.title)
                    .font(.system(size: 9.5, weight: .medium))
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

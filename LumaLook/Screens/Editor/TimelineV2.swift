import SwiftUI
import UIKit

// MARK: - Metrics

/// Time <-> points mapping shared by all timeline lanes.
struct TimelineMetrics: Equatable {
    var pointsPerSecond: CGFloat = 50           // zoom level
    static let minPPS: CGFloat = 12             // ~50 s visible on a 600 pt strip
    static let maxPPS: CGFloat = 240            // frame-accurate trimming zoom

    func x(for time: Double) -> CGFloat { CGFloat(time) * pointsPerSecond }
    func time(for x: CGFloat) -> Double { Double(x / pointsPerSecond) }
}

/// Lane heights for the vertical track stack.
enum LaneMetrics {
    static let ruler: CGFloat = 18
    static let video: CGFloat = 66
    static let overlay: CGFloat = 30
    static let clipAudio: CGFloat = 14
    static let music: CGFloat = 36
    static let spacing: CGFloat = 8

    /// Total stack height for N audio lanes (+1 row for the add button).
    /// The overlay lane is always present: bars when overlays exist, a slim
    /// "+ Overlay" affordance when none do.
    static func total(audioLanes: Int) -> CGFloat {
        let lanes = CGFloat(audioLanes + 1)   // + "Add audio" row
        return ruler + spacing + video + 4 + overlay + 4 + clipAudio
             + lanes * (music + spacing)
    }
}

// MARK: - Reorder state

/// Shared drag state for long-press clip reordering. The UIKit recognizer on
/// the scroller writes it; the SwiftUI lanes render from it; nothing in the
/// model mutates until the drop commits (img.ly's preview-cascade pattern).
@MainActor
final class TimelineReorderState: ObservableObject {
    @Published var draggingClipID: UUID?
    /// Finger x in timeline CONTENT coordinates.
    @Published var dragX: CGFloat = 0
    /// Offset from the clip's leading edge to the grab point, so the
    /// floating cell stays glued to the finger.
    @Published var grabOffset: CGFloat = 0
    /// Proposed insertion slot (index in the array with the clip lifted out).
    @Published var insertSlot: Int?

    var isDragging: Bool { draggingClipID != nil }

    func reset() {
        draggingClipID = nil
        insertSlot = nil
        dragX = 0
        grabOffset = 0
    }
}

// MARK: - Timeline V2 (assembled)

/// Center-fixed-playhead multitrack timeline: content scrolls under a fixed
/// centre line; scrubbing drags the content, playback drives the scroll.
/// Live snap indicator state: the timeline time a dragged bar is currently
/// snapped to, shared so a single accent guide-line renders in content space.
final class SnapState: ObservableObject {
    @Published var snappedTime: Double?
}

/// Shared snap-target maths for the timeline: t = 0, every clip boundary, and
/// the current playhead. Used by the overlay + music bars (magnet drag).
enum TimelineSnap {
    @MainActor static func targets(editor: EditorState) -> [Double] {
        var result: [Double] = [0]
        var cursor = 0.0
        for clip in editor.clips {
            cursor += clip.timelineDuration
            result.append(cursor)
        }
        result.append(editor.currentTime)
        return result
    }

    /// The nearest snap target to `time` within `window` seconds, or nil.
    @MainActor static func nearest(to time: Double, editor: EditorState, within window: Double) -> Double? {
        guard let target = targets(editor: editor).min(by: {
            abs($0 - time) < abs($1 - time)
        }), abs(target - time) < window else { return nil }
        return target
    }
}

struct TimelineV2View: View {
    @ObservedObject var editor: EditorState
    let onAddMusic: () -> Void
    let onTapMusic: (UUID) -> Void
    let onTapTransition: (UUID) -> Void
    let onAddOverlay: () -> Void
    let onTapOverlay: (UUID) -> Void

    @State private var metrics = TimelineMetrics()
    @StateObject private var reorder = TimelineReorderState()
    @StateObject private var snap = SnapState()
    @AppStorage("timelineMagnet") private var magnetOn = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if editor.isEmpty {
                emptyPlaceholder
            } else {
                TimelineScroller(editor: editor, metrics: $metrics,
                                 reorder: reorder,
                                 contentHeight: LaneMetrics.total(audioLanes: editor.audioTracks.count)) { m in
                    TimelineContentView(editor: editor, metrics: m, reorder: reorder,
                                        snap: snap, magnetOn: magnetOn,
                                        onAddMusic: onAddMusic, onTapMusic: onTapMusic,
                                        onTapTransition: onTapTransition,
                                        onAddOverlay: onAddOverlay, onTapOverlay: onTapOverlay)
                }
                playhead
                magnetButton
            }
        }
        .frame(height: LaneMetrics.total(audioLanes: editor.audioTracks.count))
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: editor.audioTracks.count)
    }

    /// Magnet toggle: when on, dragged bars snap to clip boundaries + playhead.
    private var magnetButton: some View {
        Button {
            magnetOn.toggle()
            LumaHaptics.shared.tap()
        } label: {
            Image(systemName: "dot.squareshape.split.2x2")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(magnetOn ? .black : LumaTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(magnetOn ? AnyShapeStyle(LumaTheme.accentBright)
                                     : AnyShapeStyle(.ultraThinMaterial),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .padding(.trailing, 8)
    }

    /// Fixed centre playhead: triangle cap over a full-height line.
    private var playhead: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(.white)
                .frame(width: 10, height: 5)
            Rectangle()
                .fill(.white)
                .frame(width: 2.5)
                .shadow(color: .black.opacity(0.6), radius: 3)
        }
        .allowsHitTesting(false)
    }

    private var emptyPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.white.opacity(0.15)))
            .overlay(Text("Timeline is empty")
                .font(.system(size: 13))
                .foregroundStyle(LumaTheme.textMuted))
            .padding(.horizontal, 22)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Lane stack (hosted content)

struct TimelineContentView: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    @ObservedObject var reorder: TimelineReorderState
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    let onAddMusic: () -> Void
    let onTapMusic: (UUID) -> Void
    let onTapTransition: (UUID) -> Void
    let onAddOverlay: () -> Void
    let onTapOverlay: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LaneMetrics.spacing) {
            RulerLane(duration: editor.totalDuration, metrics: metrics)
            VStack(alignment: .leading, spacing: 4) {
                VideoLane(editor: editor, metrics: metrics, reorder: reorder,
                          onTapTransition: onTapTransition)
                OverlayLane(editor: editor, metrics: metrics, snap: snap, magnetOn: magnetOn,
                            onAddOverlay: onAddOverlay, onTapOverlay: onTapOverlay)
                ClipAudioLane(editor: editor, metrics: metrics)
            }
            ForEach(editor.audioTracks) { track in
                MusicLane(editor: editor, metrics: metrics, track: track,
                          snap: snap, magnetOn: magnetOn, onTapMusic: onTapMusic)
            }
            AddAudioRow(action: onAddMusic)
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: LaneMetrics.total(audioLanes: editor.audioTracks.count),
               alignment: .leading)
        // Snap guide-line: a full-height accent rule at the snapped time.
        .overlay(alignment: .topLeading) {
            if let t = snap.snappedTime {
                Rectangle()
                    .fill(LumaTheme.accentBright)
                    .frame(width: 2, height: LaneMetrics.total(audioLanes: editor.audioTracks.count))
                    .offset(x: metrics.x(for: t) - 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Diamond chip at a cut: tap to pick the transition. White ghost = plain
/// cut, accent = transition set (the CapCut affordance everyone knows).
struct TransitionChip: View {
    let style: TransitionStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5)
                .fill(style == .none ? AnyShapeStyle(.ultraThinMaterial)
                                     : AnyShapeStyle(LumaTheme.accent))
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(45))
                .overlay {
                    Image(systemName: style == .none ? "plus" : "sparkles")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.5), radius: 3)
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.lumaPress)
        .frame(height: LaneMetrics.video)
    }
}

/// Slim lane showing which clips carry their own sound — the imported
/// video's audio, visible as its own track like every NLE.
struct ClipAudioLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics

    var body: some View {
        HStack(spacing: 0) {
            ForEach(editor.clips) { clip in
                Group {
                    if clip.hasAudio {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(editor.muteAudio ? LumaTheme.surfaceStrong
                                                   : LumaTheme.teal.opacity(0.42))
                            .overlay(alignment: .leading) {
                                Image(systemName: editor.muteAudio ? "speaker.slash.fill" : "waveform")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.leading, 5)
                            }
                            .padding(.horizontal, 1)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: max(metrics.x(for: clip.timelineDuration), 10),
                       height: LaneMetrics.clipAudio)
            }
        }
        .frame(height: LaneMetrics.clipAudio, alignment: .leading)
    }
}

/// Persistent "+ Audio" row under the audio lanes — add as many as you want.
struct AddAudioRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Add audio")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .frame(width: 150, height: LaneMetrics.music)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.white.opacity(0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Ruler lane

struct RulerLane: View {
    let duration: Double
    let metrics: TimelineMetrics

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            // Label stride widens as the timeline zooms out.
            let pps = metrics.pointsPerSecond
            let labelStride = pps < 20 ? 10 : (pps < 45 ? 5 : (pps < 110 ? 2 : 1))
            let seconds = Int(duration.rounded(.up))
            for s in 0...seconds {
                let x = metrics.x(for: Double(s))
                let isLabelTick = s % labelStride == 0
                let tickHeight: CGFloat = isLabelTick ? 6 : 3.5
                context.fill(
                    Path(CGRect(x: x - 0.5, y: size.height - tickHeight, width: 1, height: tickHeight)),
                    with: .color(.white.opacity(isLabelTick ? 0.45 : 0.2))
                )
                if isLabelTick {
                    let label = Text(Self.label(for: s))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.45))
                    context.draw(label,
                                 at: CGPoint(x: s == 0 ? x + 2 : x, y: 4),
                                 anchor: s == 0 ? .topLeading : .top)
                }
            }
        }
        .frame(width: max(metrics.x(for: duration), 1),
               height: LaneMetrics.ruler, alignment: .leading)
    }

    private static func label(for seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Video lane

struct VideoLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    @ObservedObject var reorder: TimelineReorderState
    let onTapTransition: (UUID) -> Void

    /// Live on-cell trim (#3/#106): point deltas applied to the selected
    /// clip's cell while a handle drags; committed as ONE applyTrim on
    /// release (single undo entry, single rebuild).
    private struct TrimDraft: Equatable {
        let id: UUID
        var headX: CGFloat = 0   // + shrinks from the left
        var tailX: CGFloat = 0   // + extends to the right
    }
    @State private var trimDraft: TrimDraft?

    private func draftedWidth(for clip: EditorState.Clip) -> CGFloat {
        let base = max(metrics.x(for: clip.timelineDuration), 10)
        guard let draft = trimDraft, draft.id == clip.id else { return base }
        return max(10, base - draft.headX + draft.tailX)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(editor.clips) { clip in
                    TimelineClipCell(clip: clip,
                                     width: draftedWidth(for: clip),
                                     selected: clip.id == editor.selectedClipID)
                        // Head trim: the left edge follows the finger, the
                        // out-point stays anchored (standard NLE feel).
                        .padding(.leading,
                                 trimDraft?.id == clip.id ? (trimDraft?.headX ?? 0) : 0)
                        // Lifted clip stays in layout (siblings don't reflow
                        // mid-drag) but goes ghost, img.ly-style.
                        .opacity(reorder.draggingClipID == clip.id ? 0.25 : 1)
                        .onTapGesture {
                            editor.selectedClipID = clip.id == editor.selectedClipID ? nil : clip.id
                        }
                        .contextMenu {
                            Button {
                                editor.selectedClipID = clip.id
                                editor.duplicateSelected()
                            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            Button {
                                editor.selectedClipID = clip.id
                                editor.copySelected()
                            } label: { Label("Copy", systemImage: "doc.on.doc") }
                            Button {
                                editor.selectedClipID = clip.id
                                editor.pasteClip()
                            } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                                .disabled(EditorState.clipboardClip == nil)
                            Divider()
                            Button(role: .destructive) {
                                editor.selectedClipID = clip.id
                                editor.deleteSelected(ripple: true)
                            } label: { Label("Ripple Delete", systemImage: "trash") }
                            Button(role: .destructive) {
                                editor.selectedClipID = clip.id
                                editor.deleteSelected(ripple: false)
                            } label: { Label("Delete, keep other lanes", systemImage: "trash.slash") }
                        }
                }
            }

            // On-cell trim handles for the selected clip.
            if !reorder.isDragging,
               let selected = editor.clips.first(where: { $0.id == editor.selectedClipID }) {
                ClipTrimHandles(editor: editor, metrics: metrics, clip: selected,
                                draftHeadX: Binding(
                                    get: { trimDraft?.id == selected.id ? trimDraft!.headX : 0 },
                                    set: { newValue in
                                        var draft = trimDraft?.id == selected.id
                                            ? trimDraft! : TrimDraft(id: selected.id)
                                        draft.headX = newValue
                                        trimDraft = draft
                                    }),
                                draftTailX: Binding(
                                    get: { trimDraft?.id == selected.id ? trimDraft!.tailX : 0 },
                                    set: { newValue in
                                        var draft = trimDraft?.id == selected.id
                                            ? trimDraft! : TrimDraft(id: selected.id)
                                        draft.tailX = newValue
                                        trimDraft = draft
                                    }),
                                onCommit: { trimDraft = nil })
                    .frame(width: draftedWidth(for: selected), height: LaneMetrics.video)
                    .offset(x: leadingX(of: selected.id)
                              + (trimDraft?.id == selected.id ? trimDraft!.headX : 0))
            }

            // Transition chips at every cut (hidden while reordering).
            if !reorder.isDragging {
                ForEach(Array(editor.clips.enumerated().dropLast()), id: \.element.id) { index, clip in
                    TransitionChip(style: clip.transitionAfter) {
                        onTapTransition(clip.id)
                    }
                    .offset(x: boundaryX(after: index) - 11)
                }
            }

            if reorder.isDragging {
                // Insertion slot indicator: accent line at the drop boundary.
                if let slot = reorder.insertSlot {
                    Rectangle()
                        .fill(LumaTheme.accentBright)
                        .frame(width: 3, height: LaneMetrics.video + 6)
                        .shadow(color: LumaTheme.accent.opacity(0.8), radius: 4)
                        .offset(x: slotX(slot) - 1.5)
                        .animation(.spring(response: 0.22, dampingFraction: 0.8),
                                   value: reorder.insertSlot)
                }
                // Floating condensed clip glued to the finger.
                if let clip = editor.clips.first(where: { $0.id == reorder.draggingClipID }) {
                    TimelineClipCell(clip: clip, width: 72, selected: true)
                        .scaleEffect(1.06)
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                        .offset(x: reorder.dragX - min(reorder.grabOffset, 36))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: LaneMetrics.video, alignment: .leading)
    }

    /// Content-space x of a clip's left edge (pre-draft).
    private func leadingX(of id: UUID) -> CGFloat {
        var x: CGFloat = 0
        for clip in editor.clips {
            if clip.id == id { return x }
            x += max(metrics.x(for: clip.timelineDuration), 10)
        }
        return x
    }

    /// Content-space x of the cut after clip `index`.
    private func boundaryX(after index: Int) -> CGFloat {
        var x: CGFloat = 0
        for i in 0...index {
            x += max(metrics.x(for: editor.clips[i].timelineDuration), 10)
        }
        return x
    }

    /// Content-space x of an insertion slot: the boundary before the clip at
    /// `slot` in the sequence with the dragged clip removed.
    private func slotX(_ slot: Int) -> CGFloat {
        let remaining = editor.clips.filter { $0.id != reorder.draggingClipID }
        var x: CGFloat = 0
        for (i, clip) in remaining.enumerated() {
            if i == slot { return x }
            x += max(metrics.x(for: clip.timelineDuration), 10)
        }
        return x
    }
}

/// On-cell trim handles (#3/#106): bracket-style grips on the selected
/// clip's edges. Dragging previews the new cell width live; releasing
/// commits one `applyTrim` (one undo entry, one rebuild) with a haptic.
private struct ClipTrimHandles: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    let clip: EditorState.Clip
    @Binding var draftHeadX: CGFloat
    @Binding var draftTailX: CGFloat
    let onCommit: () -> Void

    private var baseWidth: CGFloat { max(metrics.x(for: clip.timelineDuration), 10) }

    var body: some View {
        HStack {
            grip(system: "chevron.compact.left")
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            // + shrinks from the left; − extends into unused
                            // head material (never past the asset start).
                            let minX = -metrics.x(for: clip.trimStart / clip.speed)
                            let maxX = baseWidth - metrics.x(for: 0.2 / clip.speed) - draftTailX
                            draftHeadX = min(max(value.translation.width, minX), max(minX, maxX))
                        }
                        .onEnded { _ in commit() }
                )
            Spacer(minLength: 0)
            grip(system: "chevron.compact.right")
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            // + extends into unused tail material.
                            let maxX = metrics.x(for: (clip.assetDuration - clip.trimEnd) / clip.speed)
                            let minX = -(baseWidth - metrics.x(for: 0.2 / clip.speed) - draftHeadX)
                            draftTailX = min(max(value.translation.width, min(minX, maxX)), maxX)
                        }
                        .onEnded { _ in commit() }
                )
        }
        .allowsHitTesting(true)
    }

    private func commit() {
        let headDelta = metrics.time(for: draftHeadX) * clip.speed
        let tailDelta = metrics.time(for: draftTailX) * clip.speed
        if abs(headDelta) > 0.01 || abs(tailDelta) > 0.01 {
            editor.selectedClipID = clip.id
            editor.applyTrim(start: clip.trimStart + headDelta,
                             end: clip.trimEnd + tailDelta)
            LumaHaptics.shared.trimRubberband()
        }
        onCommit()
    }

    private func grip(system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 17, height: LaneMetrics.video)
            .background(LumaTheme.accentBright)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: system.contains("left") ? 10 : 0,
                bottomLeadingRadius: system.contains("left") ? 10 : 0,
                bottomTrailingRadius: system.contains("left") ? 0 : 10,
                topTrailingRadius: system.contains("left") ? 0 : 10))
            .contentShape(Rectangle().inset(by: -8))
    }
}

/// Filmstrip cell at an explicit time-derived width: the frame repeats in
/// square tiles across the clip, like a real NLE track.
struct TimelineClipCell: View {
    let clip: EditorState.Clip
    let width: CGFloat
    let selected: Bool

    var body: some View {
        Group {
            if clip.thumbnail != nil || !clip.filmstrip.isEmpty {
                // Real filmstrip: each tile shows the frame at that point in
                // the clip; falls back to the poster frame until the strip
                // renders.
                let tiles = max(1, Int(ceil(width / 44)))
                HStack(spacing: 0) {
                    ForEach(0..<tiles, id: \.self) { i in
                        Color.clear
                            .frame(width: 44, height: LaneMetrics.video)
                            .overlay {
                                if let frame = frameForTile(i, of: tiles) {
                                    Image(decorative: frame, scale: 1)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                }
                            }
                            .clipped()
                    }
                }
                .frame(width: width, alignment: .leading)
            } else {
                LumaTheme.surfaceStrong
            }
        }
        .frame(width: width, height: LaneMetrics.video)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if width > 48 {
                HStack(spacing: 3) {
                    if clip.speed != 1 {
                        Text(String(format: "%g×", clip.speed))
                            .font(.system(size: 10, weight: .heavy))
                    }
                    Text(String(format: "%.1fs", clip.timelineDuration))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Per-clip grade badge: this clip wears its own look.
            if clip.grade != nil {
                Image(systemName: "camera.filters")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(LumaTheme.accent, in: Circle())
                    .padding(4)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? LumaTheme.accentBright : .white.opacity(0.08),
                    lineWidth: selected ? 2.5 : 1))
        .shadow(color: selected ? LumaTheme.accent.opacity(0.45) : .clear, radius: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }

    /// Maps a tile position to its filmstrip frame (time-proportional),
    /// falling back to the poster frame while the strip renders.
    private func frameForTile(_ index: Int, of tiles: Int) -> CGImage? {
        guard !clip.filmstrip.isEmpty else { return clip.thumbnail }
        let position = (Double(index) + 0.5) / Double(tiles)
        let frameIndex = min(clip.filmstrip.count - 1,
                             Int(position * Double(clip.filmstrip.count)))
        return clip.filmstrip[frameIndex]
    }
}

// MARK: - Overlay lane (T1)

/// PIP layer lane between the video lane and the clip-audio strip. Bars
/// drag horizontally (offset) like the music bar, snap to clip boundaries,
/// tap to open the overlay panel. Empty state shows a slim "+ Overlay"
/// affordance consistent with Add audio.
struct OverlayLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    let onAddOverlay: () -> Void
    let onTapOverlay: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            if editor.overlays.isEmpty {
                Button(action: onAddOverlay) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Overlay")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(width: 110, height: LaneMetrics.overlay)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.18)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            } else {
                ForEach(editor.overlays) { item in
                    OverlayBar(editor: editor, metrics: metrics, item: item,
                               snap: snap, magnetOn: magnetOn, onTapOverlay: onTapOverlay)
                }
            }
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: LaneMetrics.overlay, alignment: .leading)
    }
}

/// One overlay's bar: thumbnail chip + title, long-press-drag to move.
private struct OverlayBar: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    let item: EditorState.OverlayItem
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    let onTapOverlay: (UUID) -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingBar = false
    @State private var lastSnappedTime: Double?

    var body: some View {
        let barWidth = max(metrics.x(for: item.duration), 28)
        HStack(spacing: 6) {
            if let thumb = item.thumbnail {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: LaneMetrics.overlay - 8)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.isImage ? "photo" : "rectangle.on.rectangle")
                    .font(.system(size: 10, weight: .bold))
            }
            if barWidth > 90 {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(String(format: "%.1fs", item.duration))
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: barWidth, height: LaneMetrics.overlay)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(LumaTheme.teal.opacity(0.34)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(isDraggingBar ? LumaTheme.accentBright : .white.opacity(0.14),
                          lineWidth: isDraggingBar ? 2 : 1))
        .opacity(isDraggingBar ? 0.92 : 1)
        // Trim handles (gap fix): head trims content + anchors the out-point,
        // tail adjusts duration. One engine commit per drag.
        .overlay {
            if !isDraggingBar, barWidth > 54 {
                HStack {
                    overlayTrimHandle(system: "chevron.compact.left")
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onEnded { value in
                                    editor.trimOverlayHead(
                                        id: item.id,
                                        deltaSeconds: metrics.time(for: value.translation.width))
                                    LumaHaptics.shared.trimRubberband()
                                }
                        )
                    Spacer(minLength: 0)
                    overlayTrimHandle(system: "chevron.compact.right")
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onEnded { value in
                                    editor.trimOverlayTail(
                                        id: item.id,
                                        deltaSeconds: metrics.time(for: value.translation.width))
                                    LumaHaptics.shared.trimRubberband()
                                }
                        )
                }
            }
        }
        .offset(x: metrics.x(for: item.timelineOffset) + dragTranslation)
        .onTapGesture { onTapOverlay(item.id) }
        .contextMenu {
            Button(role: .destructive) {
                editor.removeOverlay(id: item.id)
            } label: { Label("Remove Overlay", systemImage: "trash") }
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture())
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    isDraggingBar = true
                    var t = clampTranslation(drag?.translation.width ?? 0)
                    // Live magnet snap: pull the bar's LEADING edge onto the
                    // nearest boundary within ~8pt and show the guide-line.
                    if magnetOn {
                        let offset = item.timelineOffset + metrics.time(for: t)
                        if let target = TimelineSnap.nearest(to: offset, editor: editor,
                                                             within: metrics.time(for: 8)) {
                            t = clampTranslation(metrics.x(for: target - item.timelineOffset))
                            snap.snappedTime = target
                            if lastSnappedTime != target {
                                LumaHaptics.shared.timelineSnap()
                                lastSnappedTime = target
                            }
                        } else {
                            snap.snappedTime = nil
                            lastSnappedTime = nil
                        }
                    }
                    dragTranslation = t
                }
                .onEnded { value in
                    if case .second(true, let drag) = value {
                        commitDrag(translation: clampTranslation(drag?.translation.width ?? 0))
                    }
                    isDraggingBar = false
                    dragTranslation = 0
                    snap.snappedTime = nil
                    lastSnappedTime = nil
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: isDraggingBar)
    }

    private func overlayTrimHandle(system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: LaneMetrics.overlay)
            .background(.white.opacity(0.2))
            .contentShape(Rectangle().inset(by: -6))
    }

    private func clampTranslation(_ translation: CGFloat) -> CGFloat {
        let minX = -metrics.x(for: item.timelineOffset)
        let maxX = metrics.x(for: max(0, editor.totalDuration - 0.2 - item.timelineOffset))
        return min(max(translation, minX), maxX)
    }

    private func commitDrag(translation: CGFloat) {
        var offset = item.timelineOffset + metrics.time(for: translation)
        // Snap to t = 0 and clip boundaries within 0.15 s.
        var boundaries: [Double] = [0]
        var cursor = 0.0
        for clip in editor.clips {
            cursor += clip.timelineDuration
            boundaries.append(cursor)
        }
        if let snap = boundaries.min(by: { abs($0 - offset) < abs($1 - offset) }),
           abs(snap - offset) < 0.15 {
            offset = snap
        }
        editor.setOverlayOffset(id: item.id, offset)
    }
}

// MARK: - Music lane

struct MusicLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    let track: EditorState.MusicTrack
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    let onTapMusic: (UUID) -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingBar = false
    @State private var lastSnappedTime: Double?

    var body: some View {
        ZStack(alignment: .leading) {
            musicBar(track)
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: LaneMetrics.music, alignment: .leading)
        .sensoryFeedback(.impact(weight: .light), trigger: isDraggingBar)
    }

    private func musicBar(_ music: EditorState.MusicTrack) -> some View {
        let rendered = max(0.05, min(music.timelineDuration,
                                     editor.totalDuration - music.timelineOffset))
        let barWidth = max(metrics.x(for: rendered), 28)
        return HStack(spacing: 6) {
            Image(systemName: music.isMuted ? "speaker.slash.fill" : music.kind.icon)
                .font(.system(size: 11, weight: .bold))
            if barWidth > 90 {
                Text(music.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(String(format: "%.1fs", rendered))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(width: barWidth, height: LaneMetrics.music)
        .background {
            // Fill + real waveform (trimmed window of whole-file RMS buckets).
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(music.isMuted ? AnyShapeStyle(LumaTheme.surfaceStrong)
                                        : AnyShapeStyle(music.kind.tint))
                if !music.waveform.isEmpty {
                    WaveformBars(samples: music.waveform,
                                 windowStart: music.trimStart / max(music.assetDuration, 0.01),
                                 windowEnd: music.trimEnd / max(music.assetDuration, 0.01))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(isDraggingBar ? LumaTheme.accentBright : .white.opacity(0.12),
                          lineWidth: isDraggingBar ? 2 : 1))
        .overlay {
            if barWidth > 120 {
                MusicTrimHandles(metrics: metrics, trackID: music.id, editor: editor)
            }
        }
        .opacity(isDraggingBar ? 0.92 : 1)
        .offset(x: metrics.x(for: music.timelineOffset) + dragTranslation)
        .onTapGesture { onTapMusic(music.id) }
        .contextMenu {
            Button {
                editor.setMusicMuted(id: music.id, !music.isMuted)
            } label: {
                Label(music.isMuted ? "Unmute" : "Mute",
                      systemImage: music.isMuted ? "speaker.wave.2" : "speaker.slash")
            }
            Button(role: .destructive) {
                editor.removeAudioTrack(id: music.id)
            } label: { Label("Remove Audio", systemImage: "trash") }
        }
        // Long-press-then-drag repositions the music on the timeline; the
        // initial hold lets the scroll view's pan fail first.
        .gesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture())
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    isDraggingBar = true
                    var t = clampTranslation(drag?.translation.width ?? 0, music: music)
                    if magnetOn {
                        let offset = music.timelineOffset + metrics.time(for: t)
                        if let target = TimelineSnap.nearest(to: offset, editor: editor,
                                                             within: metrics.time(for: 8)) {
                            t = clampTranslation(metrics.x(for: target - music.timelineOffset), music: music)
                            snap.snappedTime = target
                            if lastSnappedTime != target {
                                LumaHaptics.shared.timelineSnap()
                                lastSnappedTime = target
                            }
                        } else {
                            snap.snappedTime = nil
                            lastSnappedTime = nil
                        }
                    }
                    dragTranslation = t
                }
                .onEnded { value in
                    if case .second(true, let drag) = value {
                        let translation = clampTranslation(drag?.translation.width ?? 0, music: music)
                        commitDrag(translation: translation, music: music)
                    }
                    isDraggingBar = false
                    dragTranslation = 0
                    snap.snappedTime = nil
                    lastSnappedTime = nil
                }
        )
    }

    private func clampTranslation(_ translation: CGFloat, music: EditorState.MusicTrack) -> CGFloat {
        let minX = -metrics.x(for: music.timelineOffset)
        let maxX = metrics.x(for: max(0, editor.totalDuration - 0.2 - music.timelineOffset))
        return min(max(translation, minX), maxX)
    }

    private func commitDrag(translation: CGFloat, music: EditorState.MusicTrack) {
        var offset = music.timelineOffset + metrics.time(for: translation)
        // Snap to t = 0 and clip boundaries within 0.15 s.
        var boundaries: [Double] = [0]
        var cursor = 0.0
        for clip in editor.clips {
            cursor += clip.timelineDuration
            boundaries.append(cursor)
        }
        if let snap = boundaries.min(by: { abs($0 - offset) < abs($1 - offset) }),
           abs(snap - offset) < 0.15 {
            offset = snap
        }
        editor.setMusicOffset(id: music.id, offset)
    }

    /// Waveform bars over the trimmed sample window.
    private struct WaveformBars: View {
        let samples: [Float]
        let windowStart: Double
        let windowEnd: Double

        var body: some View {
            Canvas { context, size in
                guard !samples.isEmpty, windowEnd > windowStart else { return }
                let barCount = max(4, Int(size.width / 3))
                for i in 0..<barCount {
                    let fraction = windowStart + (windowEnd - windowStart)
                        * Double(i) / Double(barCount)
                    let sample = samples[min(samples.count - 1,
                                             Int(fraction * Double(samples.count)))]
                    let h = max(1.5, CGFloat(sample) * size.height * 0.72)
                    let rect = CGRect(x: CGFloat(i) * size.width / CGFloat(barCount),
                                      y: (size.height - h) / 2,
                                      width: 1.8, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.9),
                                 with: .color(.white.opacity(0.28)))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Leading/trailing trim handles on the music bar. Dragging the head
    /// trims content AND advances the bar (tail stays anchored); dragging
    /// the tail just shortens it — standard NLE behaviour.
    private struct MusicTrimHandles: View {
        let metrics: TimelineMetrics
        let trackID: UUID
        @ObservedObject var editor: EditorState
        var body: some View {
            // One engine commit per drag (single undo entry, single rebuild);
            // haptic on release confirms the cut landed.
            HStack {
                handle(system: "chevron.compact.left")
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onEnded { value in
                                editor.trimMusicHead(
                                    id: trackID,
                                    deltaSeconds: metrics.time(for: value.translation.width))
                                LumaHaptics.shared.trimRubberband()
                            }
                    )
                Spacer()
                handle(system: "chevron.compact.right")
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onEnded { value in
                                editor.trimMusicTail(
                                    id: trackID,
                                    deltaSeconds: metrics.time(for: value.translation.width))
                                LumaHaptics.shared.trimRubberband()
                            }
                    )
            }
        }

        private func handle(system: String) -> some View {
            Image(systemName: system)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: LaneMetrics.music)
                .background(.white.opacity(0.18))
                .contentShape(Rectangle().inset(by: -6))
        }
    }

}

// MARK: - Scroller (UIKit)

/// Center-fixed-playhead scroller. Content scrolls under a fixed centre line:
/// `contentInset = viewport/2` on both sides, so t = 0 and t = duration both
/// land exactly under the playhead at the scroll extremes.
struct TimelineScroller<Content: View>: UIViewRepresentable {
    @ObservedObject var editor: EditorState
    @Binding var metrics: TimelineMetrics
    var reorder: TimelineReorderState
    let contentHeight: CGFloat
    @ViewBuilder let content: (TimelineMetrics) -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = LayoutReportingScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.scrollsToTop = false
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.delegate = context.coordinator

        let host = UIHostingController(rootView: AnyView(content(metrics)))
        host.view.backgroundColor = .clear
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        scrollView.addSubview(host.view)
        context.coordinator.host = host
        context.coordinator.editor = editor
        context.coordinator.contentHeight = contentHeight

        // Re-apply geometry once the first real layout gives us a width.
        scrollView.onLayout = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView, let coordinator else { return }
            coordinator.applyGeometry(scrollView)
        }

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(pinch)

        // Long-press-then-drag reorders clips. Standard iOS reorder timing;
        // tight allowableMovement so a real pan fails the press quickly and
        // the scroll view keeps scrubbing (the img.ly gesture split).
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleReorder(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 12
        longPress.delegate = context.coordinator
        scrollView.addGestureRecognizer(longPress)

        context.coordinator.reorder = reorder
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.editor = editor
        coordinator.metrics = metrics
        coordinator.metricsBinding = $metrics
        coordinator.reorder = reorder
        coordinator.contentHeight = contentHeight
        coordinator.host.rootView = AnyView(content(metrics))
        coordinator.applyGeometry(scrollView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var host: UIHostingController<AnyView>!
        weak var editor: EditorState?
        var metrics = TimelineMetrics()
        var metricsBinding: Binding<TimelineMetrics>?
        var reorder: TimelineReorderState?
        var contentHeight: CGFloat = 0
        private var lastInsertSlot: Int?

        /// Write-side guard: offset assignments from code must not read back
        /// as user scrubs.
        var isProgrammaticScroll = false
        private var isPinching = false
        private var pinchStartPPS: CGFloat = 50
        private var pinchWasClamped = false
        private var lastHapticSecond = Int.min
        private var lastBoundaryHit: Int?
        private let scrubTick = UISelectionFeedbackGenerator()
        private let limitThump = UIImpactFeedbackGenerator(style: .light)

        // MARK: Geometry

        /// Single source of geometry truth: insets, content size, hosted
        /// frame, and (when the user isn't interacting) playhead-follow.
        func applyGeometry(_ scrollView: UIScrollView, followPlayhead: Bool = true) {
            guard let editor else { return }
            let viewportWidth = scrollView.bounds.width
            guard viewportWidth > 0 else { return }   // first layout pass

            let contentWidth = max(metrics.x(for: editor.totalDuration), 1)
            let inset = (viewportWidth / 2).rounded()
            if scrollView.contentInset.left != inset || scrollView.contentInset.right != inset {
                isProgrammaticScroll = true
                scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
                isProgrammaticScroll = false
            }

            let size = CGSize(width: contentWidth, height: contentHeight)
            if scrollView.contentSize != size {
                scrollView.contentSize = size
            }
            if host.view.frame.size != size {
                host.view.frame = CGRect(origin: .zero, size: size)
            }

            // Playback (or seek) drives the scroll — but never while the
            // user owns the gesture: that's the other half of the loop guard.
            guard followPlayhead, !isPinching,
                  !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating
            else { return }
            let target = metrics.x(for: editor.currentTime) - inset
            if abs(scrollView.contentOffset.x - target) > 0.25 {
                isProgrammaticScroll = true
                scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: false)
                isProgrammaticScroll = false
            }
        }

        private func recenterOnPlayhead(_ scrollView: UIScrollView) {
            guard let editor else { return }
            isProgrammaticScroll = true
            scrollView.contentOffset = CGPoint(
                x: metrics.x(for: editor.currentTime) - scrollView.contentInset.left, y: 0)
            isProgrammaticScroll = false
        }

        // MARK: UIScrollViewDelegate (user scrub → player)

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isProgrammaticScroll, !isPinching,
                  scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating,
                  let editor, editor.totalDuration > 0 else { return }
            let raw = metrics.time(for: scrollView.contentOffset.x + scrollView.contentInset.left)
            let clamped = min(max(0, raw), editor.totalDuration)
            editor.seek(to: clamped)

            // Sparing haptic tick when the scrub crosses a second boundary.
            let second = Int(clamped)
            if second != lastHapticSecond {
                if lastHapticSecond != Int.min { scrubTick.selectionChanged() }
                lastHapticSecond = second
            }

            // Firmer detent when the playhead lands on a clip boundary —
            // the edit points are where scrubbing precision matters.
            var cursor = 0.0
            var nearBoundary: Int? = nil
            for (index, clip) in editor.clips.enumerated().dropLast() {
                cursor += clip.timelineDuration
                if abs(clamped - cursor) < 0.06 { nearBoundary = index; break }
            }
            if let hit = nearBoundary, hit != lastBoundaryHit {
                LumaHaptics.shared.timelineSnap()
                lastBoundaryHit = hit
            } else if nearBoundary == nil {
                lastBoundaryHit = nil
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if let editor {
                lastHapticSecond = Int(editor.currentTime)
                // CapCut behaviour: dragging pauses, the user taps play again.
                if editor.isPlaying { editor.togglePlayback() }
            }
            scrubTick.prepare()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finalizeScrub(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finalizeScrub(scrollView)
        }

        /// Always land the final frame exactly where the scroll settled.
        private func finalizeScrub(_ scrollView: UIScrollView) {
            guard let editor, editor.totalDuration > 0 else { return }
            let raw = metrics.time(for: scrollView.contentOffset.x + scrollView.contentInset.left)
            editor.seek(to: min(max(0, raw), editor.totalDuration))
        }

        // MARK: Pinch zoom

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            switch gesture.state {
            case .began:
                isPinching = true
                pinchStartPPS = metrics.pointsPerSecond
                pinchWasClamped = false
            case .changed:
                let raw = pinchStartPPS * gesture.scale
                let clamped = min(max(raw, TimelineMetrics.minPPS), TimelineMetrics.maxPPS)
                let hitLimit = clamped != raw
                if hitLimit, !pinchWasClamped { limitThump.impactOccurred() }
                pinchWasClamped = hitLimit
                guard clamped != metrics.pointsPerSecond else { return }
                metrics.pointsPerSecond = clamped
                metricsBinding?.wrappedValue.pointsPerSecond = clamped
                // Re-derive geometry now so zoom stays anchored on the
                // playhead even before SwiftUI's update pass lands.
                applyGeometry(scrollView, followPlayhead: false)
                recenterOnPlayhead(scrollView)
            default:
                isPinching = false
                applyGeometry(scrollView)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: Long-press clip reorder

        @objc func handleReorder(_ gesture: UILongPressGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView,
                  let editor, let reorder, editor.clips.count > 1 else { return }
            // Location in content space (the hosted SwiftUI tree's frame).
            let location = gesture.location(in: host.view)

            switch gesture.state {
            case .began:
                // Only lift when the press lands inside the video lane.
                let laneTop = LaneMetrics.ruler + LaneMetrics.spacing
                guard location.y >= laneTop - 4,
                      location.y <= laneTop + LaneMetrics.video + 4,
                      let hit = clipHit(atContentX: location.x) else { return }
                scrollView.isScrollEnabled = false
                editor.selectedClipID = hit.clip.id
                reorder.draggingClipID = hit.clip.id
                reorder.grabOffset = location.x - hit.startX
                reorder.dragX = location.x
                reorder.insertSlot = hit.index > 0 ? hit.index : 0
                lastInsertSlot = reorder.insertSlot
                LumaHaptics.shared.reorderStart()
            case .changed:
                guard reorder.isDragging else { return }
                reorder.dragX = location.x
                let slot = insertionSlot(forContentX: location.x)
                if slot != reorder.insertSlot {
                    reorder.insertSlot = slot
                    if slot != lastInsertSlot {
                        LumaHaptics.shared.timelineSnap()
                        lastInsertSlot = slot
                    }
                }
            case .ended:
                defer {
                    reorder.reset()
                    scrollView.isScrollEnabled = true
                }
                guard let id = reorder.draggingClipID, let slot = reorder.insertSlot else { return }
                editor.moveClip(id: id, toSlot: slot)
                LumaHaptics.shared.reorderDrop()
            default:
                reorder.reset()
                scrollView.isScrollEnabled = true
            }
        }

        /// Which clip sits at a content-space x, with its start offset.
        private func clipHit(atContentX x: CGFloat)
            -> (clip: EditorState.Clip, index: Int, startX: CGFloat)? {
            guard let editor else { return nil }
            var cursor: CGFloat = 0
            for (index, clip) in editor.clips.enumerated() {
                let width = max(metrics.x(for: clip.timelineDuration), 10)
                if x >= cursor && x < cursor + width {
                    return (clip, index, cursor)
                }
                cursor += width
            }
            return nil
        }

        /// Insertion slot in the sequence WITHOUT the dragged clip: the slot
        /// flips when the finger crosses a remaining clip's midpoint (the
        /// img.ly rule — long clips never need overshooting).
        private func insertionSlot(forContentX x: CGFloat) -> Int {
            guard let editor, let reorder else { return 0 }
            let remaining = editor.clips.filter { $0.id != reorder.draggingClipID }
            var cursor: CGFloat = 0
            for (index, clip) in remaining.enumerated() {
                let width = max(metrics.x(for: clip.timelineDuration), 10)
                if x < cursor + width / 2 { return index }
                cursor += width
            }
            return remaining.count
        }
    }

    /// UIScrollView that reports layout passes, so the coordinator can apply
    /// insets once `bounds.width` becomes non-zero.
    private final class LayoutReportingScrollView: UIScrollView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }
}

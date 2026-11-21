import SwiftUI
import UIKit

// MARK: - Metrics

/// Time <-> points mapping shared by all timeline lanes.
struct TimelineMetrics: Equatable {
    var pointsPerSecond: CGFloat = 50           // zoom level
    static let minPPS: CGFloat = 12             // ~50 s visible on a 600 pt strip
    static let maxPPS: CGFloat = 360            // frame-accurate trimming zoom

    func x(for time: Double) -> CGFloat { CGFloat(time) * pointsPerSecond }
    func time(for x: CGFloat) -> Double { Double(x / pointsPerSecond) }
}

/// Lane heights for the vertical track stack (Night Lab, round three).
enum LaneMetrics {
    static let ruler: CGFloat = 18
    static let video: CGFloat = 66
    static let overlay: CGFloat = 30
    /// Caption blocks: one slim row, drawn only while captions exist.
    static let caption: CGFloat = 22
    /// Clip sound: drawn only when at least one clip carries its own audio.
    static let clipAudio: CGFloat = 22
    static let music: CGFloat = 34
    static let spacing: CGFloat = 8
    /// Gap between the rows that hang off the film strip.
    static let innerSpacing: CGFloat = 4
    /// The one slim "+ Add" row that replaced the old dashed placeholder
    /// lanes (Overlay, Music, Voiceover each used to take a big empty row).
    static let addRow: CGFloat = 30
    /// Breathing room above the lane stack. The magnet toggle used to live
    /// here; it is now a single control in the transport row (same
    /// `timelineMagnet` value), so nothing can float over a filmstrip.
    static let magnetGutter: CGFloat = 10
}

/// Which rows the lane stack draws. The pinned chrome and the scrolling lanes
/// both read this one value, so they can never lose vertical sync.
///
/// Empty lanes are not drawn at all: an overlay lane exists only while a
/// layer sits on it, the caption row only while captions exist, and the clip
/// sound row only when a clip has sound. Everything you can add lives on the
/// single "+ Add" row under the stack.
struct TimelineLayout {
    /// Stacking lanes that hold a non-caption layer, highest first (the
    /// compositor's z-order, top of the stack on top).
    var overlayLanes: [Int] = []
    var hasCaptions = false
    var hasClipAudio = false
    var audioCount = 0

    @MainActor
    init(editor: EditorState) {
        var lanes = Set<Int>()
        var captions = false
        for item in editor.overlays {
            if TimelineLayout.isCaption(item) {
                captions = true
            } else {
                lanes.insert(item.lane)
            }
        }
        overlayLanes = lanes.sorted(by: >)
        hasCaptions = captions
        hasClipAudio = editor.clips.contains { $0.hasAudio }
        audioCount = editor.audioTracks.count
    }

    /// Caption layers ride the overlay machinery but get their own row.
    @MainActor
    static func isCaption(_ item: EditorState.OverlayItem) -> Bool {
        item.kind == "caption"
    }

    /// Ruler down to the last audio lane: everything the playhead crosses.
    var lanesHeight: CGFloat {
        var h = LaneMetrics.ruler + LaneMetrics.spacing + LaneMetrics.video
        h += CGFloat(overlayLanes.count) * (LaneMetrics.overlay + LaneMetrics.innerSpacing)
        if hasCaptions { h += LaneMetrics.caption + LaneMetrics.innerSpacing }
        if hasClipAudio { h += LaneMetrics.clipAudio + LaneMetrics.innerSpacing }
        h += CGFloat(audioCount) * (LaneMetrics.music + LaneMetrics.spacing)
        return h
    }

    /// The whole stack, including the "+ Add" row.
    var height: CGFloat { lanesHeight + LaneMetrics.spacing + LaneMetrics.addRow }
}

/// Music lanes detect their beats once per session so the beat marks show
/// without a trip to the Music panel. Remembered here so a song with no
/// detectable beat isn't re-analysed every time its lane is rebuilt.
@MainActor
enum BeatMarksAutoDetect {
    static var attempted: Set<UUID> = []
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
    /// Width of the timeline viewport. Not published: it only feeds the snap
    /// maths, so a size change shouldn't re-render every lane.
    var viewportWidth: CGFloat = 0
}

/// Held while a trim handle or a bar is being dragged, so the timeline's own
/// scroll pan can't start under the finger and slide the content away
/// mid-trim. Static because only one timeline is ever on screen.
@MainActor enum TimelineDragLock {
    static var isHeld = false
}

/// A hit area wider than the grip it belongs to, so a narrow trim handle
/// still takes a 44 pt touch without reaching into the lanes above and below.
struct HitSlop: Shape {
    var horizontal: CGFloat
    var vertical: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -horizontal, dy: -vertical))
    }
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

    /// Where a dragged bar should land, or nil to leave it under the finger.
    /// Either edge can catch, within 8 pt, but only on a target the person
    /// can see. A long bar used to snap by its leading edge while that edge,
    /// and the boundary it caught, were both scrolled off-screen.
    @MainActor static func magnet(start: Double, duration: Double,
                                  editor: EditorState, metrics: TimelineMetrics,
                                  viewportWidth: CGFloat) -> (shift: Double, target: Double)? {
        let window = metrics.time(for: 8)
        // The playhead sits mid-viewport, so the visible span centres on it.
        let now = editor.currentTime
        let halfSpan = viewportWidth > 0 ? metrics.time(for: viewportWidth / 2)
                                         : .greatestFiniteMagnitude
        func isVisible(_ time: Double) -> Bool { abs(time - now) <= halfSpan }

        let candidates = targets(editor: editor).filter { isVisible($0) }
        var best: (shift: Double, target: Double)?
        for edge in [start, start + duration] where isVisible(edge) {
            guard let target = candidates.min(by: { abs($0 - edge) < abs($1 - edge) }),
                  abs(target - edge) < window,
                  abs(target - edge) < abs(best?.shift ?? .greatestFiniteMagnitude) else { continue }
            best = (target - edge, target)
        }
        return best
    }
}

struct TimelineV2View: View {
    @ObservedObject var editor: EditorState
    let onAddMusic: () -> Void
    let onTapMusic: (UUID) -> Void
    /// Opens the Clip sound panel from the clip-audio lane.
    let onTapClipAudio: (UUID) -> Void
    let onTapTransition: (UUID) -> Void
    let onAddOverlay: () -> Void
    let onTapOverlay: (UUID) -> Void
    /// Starts a voiceover take from the "+ Add" row.
    let onRecordVoiceover: () -> Void
    /// Opens the add-clip picker (the "+" on the film strip, or the empty
    /// timeline's video row).
    let onAddClip: () -> Void
    /// Zoom (points per second) is owned by the editor so the transport's
    /// zoom control and the scroller's pinch drive the same value.
    @Binding var zoom: CGFloat
    /// The editor's own "add text" route, if it wants the "+ Add" row to use
    /// it. Left nil, the timeline adds the text layer itself and opens it
    /// through `onTapOverlay`, exactly as the Text tool does.
    var onAddText: (() -> Void)? = nil
    /// The whole-edit look's name ("KD2 · Golden Hour"), so clips that follow
    /// it wear its tag too. Left nil, only clips with their own look carry a
    /// tag and clips without one show none.
    var globalLookName: String? = nil

    @StateObject private var reorder = TimelineReorderState()
    @StateObject private var snap = SnapState()
    @AppStorage("timelineMagnet") private var magnetOn = true

    /// Bridges the shared zoom scalar to the metrics struct the lanes read.
    private var metrics: Binding<TimelineMetrics> {
        Binding(get: { TimelineMetrics(pointsPerSecond: zoom) },
                set: { zoom = $0.pointsPerSecond })
    }

    private var layout: TimelineLayout { TimelineLayout(editor: editor) }

    /// The "no media yet" placeholder must describe the WHOLE project, not
    /// just the video track. Keying it off `editor.isEmpty` (= clips only)
    /// meant a project that already carried music or overlays kept rendering
    /// the empty state, so that content was invisible, unselectable and
    /// undeletable.
    private var projectIsEmpty: Bool {
        editor.clips.isEmpty && editor.audioTracks.isEmpty && editor.overlays.isEmpty
    }

    /// Ruler, one video row and a line of help.
    private static let emptyHeight: CGFloat = LaneMetrics.ruler + LaneMetrics.spacing
        + LaneMetrics.video + LaneMetrics.spacing + 16

    private var stackHeight: CGFloat {
        projectIsEmpty ? Self.emptyHeight : layout.height
    }

    var body: some View {
        // `.top` centres the playhead horizontally over the scroller (whose
        // contentInset = viewport/2 puts the current frame at screen-centre).
        ZStack(alignment: .top) {
            if projectIsEmpty {
                emptyPlaceholder
            } else {
                TimelineScroller(editor: editor, metrics: metrics,
                                 reorder: reorder,
                                 contentHeight: stackHeight) { m in
                    TimelineContentView(editor: editor, metrics: m, reorder: reorder,
                                        snap: snap, magnetOn: magnetOn,
                                        onTapMusic: onTapMusic,
                                        onTapClipAudio: onTapClipAudio,
                                        onTapTransition: onTapTransition,
                                        onTapOverlay: onTapOverlay,
                                        globalLookName: globalLookName)
                }
                pinnedChrome
                playhead
            }
        }
        .frame(height: stackHeight)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { snap.viewportWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in snap.viewportWidth = width }
            }
        }
        .padding(.top, projectIsEmpty ? 0 : LaneMetrics.magnetGutter)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: stackHeight)
    }

    /// Viewport chrome pinned OUTSIDE the scroller: the "+" that adds a clip,
    /// on the film strip's trailing edge, and the "+ Add" row under the
    /// lanes. Inside the scrolling content they slid off-screen the moment
    /// you scrubbed forward. Non-hit-testing spacers everywhere else, so
    /// touches between the controls still reach the scroller.
    private var pinnedChrome: some View {
        let lanes = layout.lanesHeight
        let belowVideo = max(0, lanes - LaneMetrics.ruler - LaneMetrics.spacing - LaneMetrics.video)
        return VStack(spacing: 0) {
            Color.clear
                .frame(height: LaneMetrics.ruler + LaneMetrics.spacing)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                Color.clear.allowsHitTesting(false)
                TimelineAddClipButton(action: onAddClip)
            }
            .frame(height: LaneMetrics.video)
            Color.clear
                .frame(height: belowVideo + LaneMetrics.spacing)
                .allowsHitTesting(false)
            TimelineAddRow(onAddText: addText,
                           onAddOverlay: onAddOverlay,
                           onAddMusic: onAddMusic,
                           onRecordVoiceover: onRecordVoiceover)
                .frame(height: LaneMetrics.addRow)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Text chip on the "+ Add" row. Same steps as the Text tool: the new
    /// layer lands at the playhead and its panel opens, and ✕ on that panel
    /// takes the new text away again.
    private func addText() {
        if let onAddText {
            onAddText()
            return
        }
        let before = Set(editor.overlays.map(\.id))
        editor.prepareToolSessionForAdd()
        editor.addTextOverlay()
        if let added = editor.overlays.first(where: { !before.contains($0.id) }) {
            onTapOverlay(added.id)
        }
    }

    /// Fixed centre playhead: a small cap over a 2 pt line, ruler to the last
    /// audio lane (it stops above the "+ Add" row).
    private var playhead: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LumaTheme.textPrimary)
                .frame(width: 10, height: 6)
            Rectangle()
                .fill(LumaTheme.textPrimary)
                .frame(width: 2)
        }
        .frame(height: layout.lanesHeight + 4)
        .offset(y: -3)
        .shadow(color: .black.opacity(0.6), radius: 4)
        .allowsHitTesting(false)
    }

    /// The empty timeline: one row that adds the first clip. Text, overlays,
    /// music and voiceover all need a base timeline to land on
    /// (`addOverlay`, `addTextOverlay` and `startVoiceover` all guard on
    /// `totalDuration > 0.4`), so they wait for a clip instead of rendering
    /// as rows that swallow the tap.
    private var emptyPlaceholder: some View {
        VStack(alignment: .leading, spacing: LaneMetrics.spacing) {
            HStack {
                Text("00:00.00")
                    .font(.luma(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LumaTheme.textMuted)
                Spacer()
                Text("Timeline")
                    .font(.luma(size: 11, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .frame(height: LaneMetrics.ruler)
            EmptyLaneRow(label: "Add a clip", icon: "film", height: LaneMetrics.video,
                         action: onAddClip)
            Text("Text, music and voiceover open up once a clip is in.")
                .font(.luma(size: 11, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: 16, alignment: .leading)
        }
        .padding(.horizontal, 20)
    }
}

/// The white "+" on the film strip's trailing edge: adds a clip. An ink ring
/// keeps it apart from the frames scrolling under it.
private struct TimelineAddClipButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LumaTheme.ink)
                .frame(width: 30, height: 30)
                .background(LumaTheme.textPrimary,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(4)
                .background(Color.black,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Add clip")
    }
}

/// One slim row in place of the dashed placeholder lanes: "+ Add" and the
/// four things a timeline can take. Each chip is the control that fills it.
struct TimelineAddRow: View {
    let onAddText: () -> Void
    let onAddOverlay: () -> Void
    let onAddMusic: () -> Void
    let onRecordVoiceover: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Add")
                    .font(.luma(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(LumaTheme.textMuted)
            .padding(.trailing, 2)
            .accessibilityHidden(true)
            chip("Text", icon: "textformat", action: onAddText)
            chip("Overlay", icon: "square.on.square", action: onAddOverlay)
            chip("Music", icon: "music.note", action: onAddMusic)
            chip("Voice", icon: "mic", action: onRecordVoiceover)
            Spacer(minLength: 0)
        }
        .frame(height: LaneMetrics.addRow)
    }

    private func chip(_ title: String, icon: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.luma(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(LumaTheme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(LumaTheme.hairline, lineWidth: 1))
            .fixedSize()
            .contentShape(HitSlop(horizontal: 3, vertical: 4))
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("Add \(title.lowercased())")
    }
}

// MARK: - Lane stack (hosted content)

struct TimelineContentView: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    @ObservedObject var reorder: TimelineReorderState
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    let onTapMusic: (UUID) -> Void
    let onTapClipAudio: (UUID) -> Void
    let onTapTransition: (UUID) -> Void
    let onTapOverlay: (UUID) -> Void
    var globalLookName: String? = nil

    private var layout: TimelineLayout { TimelineLayout(editor: editor) }

    /// With a clip selected, everything else on the timeline steps back so it
    /// is clear what the clip tools act on. Opacity only: every lane still
    /// takes its taps.
    private var dimsOtherLanes: Bool {
        editor.selectedClipID != nil && !reorder.isDragging
    }

    private var laneOpacity: Double { dimsOtherLanes ? 0.45 : 1 }

    var body: some View {
        let lanes = layout.lanesHeight
        VStack(alignment: .leading, spacing: LaneMetrics.spacing) {
            RulerLane(duration: editor.totalDuration, metrics: metrics)
            filmBlock
            ForEach(editor.audioTracks) { track in
                MusicLane(editor: editor, metrics: metrics, track: track,
                          snap: snap, magnetOn: magnetOn, onTapMusic: onTapMusic)
                    .opacity(laneOpacity)
            }
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: layout.height,
               alignment: .topLeading)
        // Snap guide-line: a full-height accent rule at the snapped time.
        .overlay(alignment: .topLeading) {
            if let t = snap.snappedTime {
                Rectangle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 2, height: lanes)
                    .offset(x: metrics.x(for: t) - 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: dimsOtherLanes)
    }

    /// The film strip and the rows that hang off it: overlay layers (highest
    /// lane on top, matching the compositor's z-order), captions, clip sound.
    private var filmBlock: some View {
        VStack(alignment: .leading, spacing: LaneMetrics.innerSpacing) {
            VideoLane(editor: editor, metrics: metrics, reorder: reorder,
                      onTapTransition: onTapTransition,
                      globalLookName: globalLookName)
            ForEach(layout.overlayLanes, id: \.self) { lane in
                OverlayLane(editor: editor, metrics: metrics, snap: snap, magnetOn: magnetOn,
                            lane: lane, onTapOverlay: onTapOverlay)
                    .opacity(laneOpacity)
            }
            if layout.hasCaptions {
                CaptionLane(editor: editor, metrics: metrics, snap: snap, magnetOn: magnetOn,
                            onTapOverlay: onTapOverlay)
                    .opacity(laneOpacity)
            }
            if layout.hasClipAudio {
                ClipAudioLane(editor: editor, metrics: metrics,
                              onTapClipAudio: onTapClipAudio)
                    .opacity(laneOpacity)
            }
        }
    }
}

/// The square at a cut: tap to pick the transition. A plain cut shows the
/// bow-tie; a set one wears the style's own glyph, so the cut says which
/// transition it is without being opened.
struct TransitionChip: View {
    let style: TransitionStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LumaTheme.textPrimary)
                .frame(width: 20, height: 20)
                .overlay { glyph }
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(hex: 0x050506), lineWidth: 2))
                .shadow(color: .black.opacity(0.5), radius: 3)
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.lumaPress)
        .frame(height: LaneMetrics.video)
        .accessibilityLabel(style == .none ? "Add transition" : "Transition: \(style.label)")
    }

    @ViewBuilder
    private var glyph: some View {
        if style == .none {
            CutBowTie()
                .fill(LumaTheme.ink)
                .frame(width: 9, height: 8)
        } else {
            Image(systemName: style.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(LumaTheme.ink)
        }
    }
}

/// Two triangles meeting in the middle: the mark for a plain cut.
private struct CutBowTie: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Slim lane showing which clips carry their own sound — the imported
/// video's audio, visible as its own track like every NLE. Only drawn when
/// at least one clip has sound.
struct ClipAudioLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    /// Opens the Clip sound panel for the tapped clip. The lane is drawn like
    /// every other tappable track, so it has to answer like one.
    let onTapClipAudio: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(editor.clips) { clip in
                Group {
                    if clip.hasAudio {
                        let w = max(metrics.x(for: clip.timelineDuration), 10)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(editor.muteAudio || clip.isMuted ? LumaTheme.surface
                                                                   : LumaTheme.surfaceStrong)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(LumaTheme.hairline, lineWidth: 1))
                            .overlay(alignment: .leading) {
                                // A lane nobody can name is a rendering
                                // artifact, not a track: label it wherever
                                // there is room for the words.
                                HStack(spacing: 4) {
                                    Image(systemName: editor.muteAudio || clip.isMuted
                                          ? "speaker.slash.fill" : "waveform")
                                        .font(.system(size: 8.5, weight: .bold))
                                    if w > 96 {
                                        Text("Clip sound")
                                            .font(.luma(size: 10, weight: .medium))
                                            .lineLimit(1)
                                    }
                                }
                                .foregroundStyle(LumaTheme.textSecondary)
                                .padding(.leading, 6)
                            }
                            .padding(.horizontal, 1)
                            .contentShape(Rectangle().inset(by: -9))
                            .onTapGesture { onTapClipAudio(clip.id) }
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

/// A dashed, labelled empty row: the empty timeline's "Add a clip". The label
/// says what the row is for and the row itself is the control that fills it.
struct EmptyLaneRow: View {
    let label: String
    let icon: String
    let height: CGFloat
    /// nil = stretch to the available width; a number pins the row's width.
    var width: CGFloat?
    /// Trailing note shown INSTEAD of the "+" when this lane cannot be filled
    /// yet. Keeps the row honest about what it does.
    var caption: String?
    /// `false` dims the row. It stays tappable: its action routes to whatever
    /// unblocks it, so it is never a control that silently does nothing.
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: height > 40 ? 12 : 10, weight: .semibold))
                Text(label)
                    .font(.luma(size: height > 40 ? 13 : 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let caption {
                    Text(caption)
                        .font(.luma(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(LumaTheme.textMuted)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LumaTheme.textPrimary)
                }
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .opacity(isEnabled ? 1 : 0.45)
            .padding(.horizontal, 14)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width, height: height)
            .background(LumaTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(LumaTheme.border))
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
                let tickHeight: CGFloat = isLabelTick ? 5 : 3
                context.fill(
                    Path(CGRect(x: x - 0.5, y: size.height - tickHeight, width: 1, height: tickHeight)),
                    with: .color(.white.opacity(isLabelTick ? 0.4 : 0.2))
                )
                // Half-second ticks once there is room for them.
                if pps >= 40, Double(s) + 0.5 <= duration {
                    let hx = metrics.x(for: Double(s) + 0.5)
                    context.fill(
                        Path(CGRect(x: hx - 0.5, y: size.height - 2.5, width: 1, height: 2.5)),
                        with: .color(.white.opacity(0.14))
                    )
                }
                if isLabelTick {
                    let label = Text(Self.label(for: s))
                        .font(.luma(size: 9, weight: .medium))
                        .foregroundColor(LumaTheme.textMuted)
                    context.draw(label,
                                 at: CGPoint(x: s == 0 ? x + 2 : x, y: 3),
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
    /// The whole-edit look, for clips without their own (see TimelineV2View).
    var globalLookName: String? = nil

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

    /// The selected clip's length as the trim stands right now, for the tab.
    private func draftedSeconds(for clip: EditorState.Clip) -> Double {
        guard let draft = trimDraft, draft.id == clip.id else { return clip.timelineDuration }
        return max(0, clip.timelineDuration + metrics.time(for: draft.tailX - draft.headX))
    }

    /// Other clips step back while one is selected (round-three clip view).
    private func cellOpacity(_ clip: EditorState.Clip) -> Double {
        if reorder.draggingClipID == clip.id { return 0.25 }
        if reorder.isDragging { return 1 }
        if let selected = editor.selectedClipID, selected != clip.id { return 0.4 }
        return 1
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(editor.clips) { clip in
                    TimelineClipCell(clip: clip,
                                     width: draftedWidth(for: clip),
                                     selected: clip.id == editor.selectedClipID,
                                     fallbackLookName: globalLookName)
                        // Head trim: the left edge follows the finger, the
                        // out-point stays anchored (standard NLE feel).
                        .padding(.leading,
                                 trimDraft?.id == clip.id ? (trimDraft?.headX ?? 0) : 0)
                        // Lifted clip stays in layout (siblings don't reflow
                        // mid-drag) but goes ghost, img.ly-style.
                        .opacity(cellOpacity(clip))
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

            // On-cell trim handles for the selected clip, in signal yellow.
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

                // The length tab above the selected clip, live while trimming.
                ClipLengthTab(seconds: draftedSeconds(for: selected))
                    .offset(x: leadingX(of: selected.id)
                              + (trimDraft?.id == selected.id ? trimDraft!.headX : 0),
                            y: -(LaneMetrics.video / 2) - 12)
                    .allowsHitTesting(false)
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
                        .fill(LumaTheme.signal)
                        .frame(width: 3, height: LaneMetrics.video + 6)
                        .shadow(color: .black.opacity(0.7), radius: 4)
                        .offset(x: slotX(slot) - 1.5)
                        .animation(.spring(response: 0.22, dampingFraction: 0.8),
                                   value: reorder.insertSlot)
                }
                // Floating condensed clip glued to the finger.
                if let clip = editor.clips.first(where: { $0.id == reorder.draggingClipID }) {
                    TimelineClipCell(clip: clip, width: 72, selected: true,
                                     fallbackLookName: globalLookName)
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

/// "3.0 s" in a signal tab over the selected clip's leading edge.
private struct ClipLengthTab: View {
    let seconds: Double

    var body: some View {
        Text(String(format: "%.1f s", seconds))
            .font(.luma(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(LumaTheme.onSignal)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LumaTheme.signal, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
    }
}

/// On-cell trim handles (#3/#106): signal-yellow grips on the selected
/// clip's edges. Dragging previews the new cell width live; releasing
/// commits one `applyTrim` (one undo entry, one rebuild) with a haptic.
private struct ClipTrimHandles: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    let clip: EditorState.Clip
    @Binding var draftHeadX: CGFloat
    @Binding var draftTailX: CGFloat
    let onCommit: () -> Void

    @GestureState private var headActive = false
    @GestureState private var tailActive = false

    private var baseWidth: CGFloat { max(metrics.x(for: clip.timelineDuration), 10) }

    var body: some View {
        HStack {
            grip(leading: true)
                .gesture(
                    // Global coordinates: the grip rides the draft offset, so
                    // a local translation would fight its own movement.
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($headActive) { _, active, _ in active = true }
                        .onChanged { value in
                            TimelineDragLock.isHeld = true
                            // + shrinks from the left; − extends into unused
                            // head material (never past the asset start).
                            let minX = -metrics.x(for: clip.trimStart / clip.speed)
                            let maxX = baseWidth - metrics.x(for: 0.2 / clip.speed) - draftTailX
                            draftHeadX = min(max(value.translation.width, minX), max(minX, maxX))
                        }
                        .onEnded { _ in commit() }
                )
            Spacer(minLength: 0)
            grip(leading: false)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($tailActive) { _, active, _ in active = true }
                        .onChanged { value in
                            TimelineDragLock.isHeld = true
                            // + extends into unused tail material.
                            let maxX = metrics.x(for: (clip.assetDuration - clip.trimEnd) / clip.speed)
                            let minX = -(baseWidth - metrics.x(for: 0.2 / clip.speed) - draftHeadX)
                            draftTailX = min(max(value.translation.width, min(minX, maxX)), maxX)
                        }
                        .onEnded { _ in commit() }
                )
        }
        .allowsHitTesting(true)
        // Releases the scroll lock on end AND on cancel (a cancelled drag
        // never reaches onEnded, but its gesture state always resets).
        .onChange(of: headActive || tailActive) { _, active in
            TimelineDragLock.isHeld = active
        }
        .onDisappear { TimelineDragLock.isHeld = false }
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

    /// A signal tab with a dark grip line, rounded on its outer side.
    private func grip(leading: Bool) -> some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: leading ? 6 : 0,
                bottomLeadingRadius: leading ? 6 : 0,
                bottomTrailingRadius: leading ? 0 : 6,
                topTrailingRadius: leading ? 0 : 6,
                style: .continuous)
                .fill(LumaTheme.signal)
            Capsule()
                .fill(LumaTheme.onSignal.opacity(0.55))
                .frame(width: 2.5, height: 16)
        }
        .frame(width: 14, height: LaneMetrics.video)
        .shadow(color: LumaTheme.signal.opacity(0.45), radius: 6)
        // 14 pt grip, 44 pt touch.
        .contentShape(HitSlop(horizontal: 15, vertical: 4))
        .accessibilityLabel(leading ? "Trim start" : "Trim end")
    }
}

/// Film-strip cell at an explicit time-derived width: real frames on a black
/// film base with sprocket holes top and bottom, and the clip's look tag in
/// its signature colour, so the lane reads as film rather than a grey bar.
struct TimelineClipCell: View {
    let clip: EditorState.Clip
    let width: CGFloat
    let selected: Bool
    /// The whole-edit look, tagged on a clip that has no look of its own.
    /// nil = such a clip shows no tag.
    var fallbackLookName: String? = nil

    /// Height of the sprocket band above and below the frames.
    private let band: CGFloat = 9

    var body: some View {
        ZStack {
            Color(hex: 0x050506)
            if clip.thumbnail != nil || !clip.filmstrip.isEmpty {
                // Real filmstrip: each tile shows the frame at that point in
                // the clip; falls back to the poster frame until the strip
                // renders.
                let tiles = max(1, Int(ceil(width / 44)))
                HStack(spacing: 1.5) {
                    ForEach(0..<tiles, id: \.self) { i in
                        Color.clear
                            .frame(width: 42.5, height: LaneMetrics.video - band * 2)
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
                .frame(width: max(0, width - 4), alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                LumaTheme.surfaceStrong
                    .padding(.vertical, band)
            }
        }
        .overlay { SprocketRows(band: band) }
        .frame(width: width, height: LaneMetrics.video)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // `clipShape` clips PIXELS, not TOUCHES, and the filmstrip is tiled in
        // fixed 44 pt squares that can overrun the cell's own width by up to
        // 43 pt. Without this the last tile stole the next clip's taps.
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(LumaTheme.hairline, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            // The selected clip's length rides the tab above it instead.
            if width > 48, !selected {
                HStack(spacing: 3) {
                    if clip.speed != 1 {
                        Text(String(format: "%g×", clip.speed))
                    }
                    Text(String(format: "%.1fs", clip.timelineDuration))
                }
                .font(.luma(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LumaTheme.textPrimary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.bottom, band + 3)
                .padding(.trailing, 5)
            }
        }
        .overlay(alignment: .topLeading) {
            // The clip's look tag, filled with the look's signature colour,
            // so a graded cut is identifiable at a glance.
            if let tag = lookTag {
                Text(width > 70 ? tag.text : String(tag.text.prefix(3)))
                    .font(.luma(size: 10, weight: .bold))
                    .lineLimit(1)
                    .foregroundStyle(Color(hex: 0x0B0B0C))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tag.colour, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(.top, band + 3)
                    .padding(.leading, selected ? 17 : 5)
            }
        }
        // A stroke means selection and nothing else, in signal yellow.
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(LumaTheme.signal, lineWidth: 2)
                    .shadow(color: LumaTheme.signal.opacity(0.5), radius: 7)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }

    /// The tag's words and colour: the clip's own look first, else the
    /// whole-edit look when one was passed in, else nothing.
    private var lookTag: (text: String, colour: Color)? {
        if let grade = clip.grade {
            let name = grade.baseLookName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                if grade.lutID == nil { return nil }
                return (text: "LUT", colour: LookSignature.neutral)
            }
            return (text: Self.shortName(name), colour: LookSignature.colour(forLookNamed: name))
        }
        if let fallback = fallbackLookName?.trimmingCharacters(in: .whitespaces),
           !fallback.isEmpty {
            return (text: Self.shortName(fallback), colour: LookSignature.colour(forLookNamed: fallback))
        }
        return nil
    }

    /// The stock code where there is one ("KD2"), else the look's name.
    private static func shortName(_ name: String) -> String {
        LookSignature.code(in: name) ?? LookSignature.title(in: name)
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

/// Sprocket holes along the top and bottom edge of a film-strip cell.
private struct SprocketRows: View {
    let band: CGFloat

    var body: some View {
        Canvas { context, size in
            let hole = CGSize(width: 4, height: 3)
            let pitch: CGFloat = 9
            var x: CGFloat = 4
            var path = Path()
            while x + hole.width <= size.width - 2 {
                let topY = (band - hole.height) / 2
                let bottomY = size.height - band + (band - hole.height) / 2
                path.addRoundedRect(in: CGRect(origin: CGPoint(x: x, y: topY), size: hole),
                                    cornerSize: CGSize(width: 1, height: 1))
                path.addRoundedRect(in: CGRect(origin: CGPoint(x: x, y: bottomY), size: hole),
                                    cornerSize: CGSize(width: 1, height: 1))
                x += pitch
            }
            context.fill(path, with: .color(.white.opacity(0.26)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Overlay lane (T1)

/// One stacking lane of layers (PIP, text, stickers, shapes) between the
/// video lane and the caption row. Bars drag horizontally like the music bar,
/// snap to clip boundaries, and open the overlay panel on tap. Only lanes
/// that hold a layer are drawn; adding lives on the "+ Add" row.
struct OverlayLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    /// Which stacking lane this row renders (F0).
    var lane: Int = 0
    let onTapOverlay: (UUID) -> Void

    private var laneItems: [EditorState.OverlayItem] {
        editor.overlays.filter { $0.lane == lane && !TimelineLayout.isCaption($0) }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(laneItems) { item in
                OverlayBar(editor: editor, metrics: metrics, item: item,
                           snap: snap, magnetOn: magnetOn, onTapOverlay: onTapOverlay)
            }
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: LaneMetrics.overlay, alignment: .leading)
    }
}

/// Caption blocks on one slim row ("Aa golden hour hits…"), whatever
/// stacking lane each caption layer sits on. Drawn only while captions exist.
/// Tap opens the caption in the overlay panel; long-press drag moves it.
struct CaptionLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    let onTapOverlay: (UUID) -> Void

    private var captions: [EditorState.OverlayItem] {
        editor.overlays.filter { TimelineLayout.isCaption($0) }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(captions) { item in
                OverlayBar(editor: editor, metrics: metrics, item: item,
                           snap: snap, magnetOn: magnetOn, onTapOverlay: onTapOverlay,
                           isCaption: true)
            }
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: LaneMetrics.caption, alignment: .leading)
    }
}

/// One layer's bar: thumbnail chip + title, long-press-drag to move. Caption
/// layers draw as slim "Aa" blocks without trim grips.
private struct OverlayBar: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    let item: EditorState.OverlayItem
    @ObservedObject var snap: SnapState
    let magnetOn: Bool
    let onTapOverlay: (UUID) -> Void
    var isCaption: Bool = false

    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingBar = false
    @State private var lastSnappedTime: Double?
    /// Live trim preview in seconds, already clamped by the engine, so the
    /// bar moves under the finger like a clip's grips instead of jumping
    /// only on release.
    @State private var headTrim: Double = 0
    @State private var tailTrim: Double = 0
    @GestureState private var headActive = false
    @GestureState private var tailActive = false
    @GestureState private var barActive = false

    private var laneHeight: CGFloat { isCaption ? LaneMetrics.caption : LaneMetrics.overlay }
    private var corner: CGFloat { isCaption ? 5 : 7 }

    var body: some View {
        let shownStart = item.timelineOffset + headTrim
        let shownDuration = item.duration - headTrim + tailTrim
        let minWidth: CGFloat = isCaption ? 18 : 28
        let barWidth = max(metrics.x(for: shownDuration) - (isCaption ? 2 : 0), minWidth)
        // Handles come and go with the COMMITTED width: keying them off the
        // preview would remove a grip mid-drag and cancel the trim.
        let committedWidth = max(metrics.x(for: item.duration), minWidth)
        barLabel(width: barWidth, duration: shownDuration)
            .frame(width: barWidth, height: laneHeight)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isCaption ? Color.white.opacity(0.08) : LumaTheme.cardRaised))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isDraggingBar ? Color.white : Color.white.opacity(isCaption ? 0.06 : 0.1),
                              lineWidth: isDraggingBar ? 1.5 : 1))
            .opacity(isDraggingBar ? 0.92 : 1)
            // Trim handles (gap fix): head trims content + anchors the
            // out-point, tail adjusts duration. One engine commit per drag.
            .overlay {
                if !isCaption, !isDraggingBar, committedWidth > 54 {
                    trimHandles
                }
            }
            .offset(x: metrics.x(for: shownStart) + dragTranslation)
            .onTapGesture { onTapOverlay(item.id) }
            .contextMenu {
                Button(role: .destructive) {
                    editor.removeOverlay(id: item.id)
                } label: {
                    Label(isCaption ? "Remove Caption" : "Remove Overlay", systemImage: "trash")
                }
            }
            .gesture(moveGesture)
            .sensoryFeedback(.impact(weight: .light), trigger: isDraggingBar)
            // Releases the scroll lock and any half-shown trim on end AND on
            // cancel (a cancelled drag never reaches onEnded).
            .onChange(of: headActive || tailActive || barActive) { _, active in
                TimelineDragLock.isHeld = active
                if !active {
                    headTrim = 0
                    tailTrim = 0
                }
            }
            .onDisappear { TimelineDragLock.isHeld = false }
    }

    @ViewBuilder
    private func barLabel(width: CGFloat, duration: Double) -> some View {
        if isCaption {
            HStack(spacing: 4) {
                Text("Aa")
                    .font(.luma(size: 9.5, weight: .bold))
                    .foregroundStyle(LumaTheme.textMuted)
                if width > 40 {
                    Text(item.text ?? item.title)
                        .font(.luma(size: 10.5, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        } else {
            HStack(spacing: 6) {
                layerGlyph
                if width > 90 {
                    Text(item.text ?? item.title)
                        .font(.luma(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(String(format: "%.1fs", duration))
                        .font(.luma(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.75)
                }
            }
            .foregroundStyle(LumaTheme.textPrimary.opacity(0.9))
            .padding(.horizontal, 6)
        }
    }

    /// Media thumbnail where there is one, else a glyph for the layer kind.
    @ViewBuilder
    private var layerGlyph: some View {
        if let thumb = item.thumbnail {
            Image(decorative: thumb, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: LaneMetrics.overlay - 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // `.scaledToFill` in a fixed frame overflows, and clipShape
                // does not clip touches, so pin the hit area to the tile.
                .contentShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: glyphName)
                .font(.system(size: 10, weight: .bold))
        }
    }

    private var glyphName: String {
        if item.text != nil { return "textformat" }
        if item.shapeKind != nil { return "square.on.circle" }
        return item.isImage ? "photo" : "rectangle.on.rectangle"
    }

    private var trimHandles: some View {
        HStack {
            overlayTrimHandle(system: "chevron.compact.left")
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($headActive) { _, active, _ in active = true }
                        .onChanged { value in
                            TimelineDragLock.isHeld = true
                            headTrim = editor.overlayHeadTrim(
                                id: item.id,
                                deltaSeconds: metrics.time(for: value.translation.width))
                        }
                        .onEnded { value in
                            headTrim = 0
                            editor.trimOverlayHead(
                                id: item.id,
                                deltaSeconds: metrics.time(for: value.translation.width))
                            LumaHaptics.shared.trimRubberband()
                        }
                )
            Spacer(minLength: 0)
            overlayTrimHandle(system: "chevron.compact.right")
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($tailActive) { _, active, _ in active = true }
                        .onChanged { value in
                            TimelineDragLock.isHeld = true
                            tailTrim = editor.overlayTailTrim(
                                id: item.id,
                                deltaSeconds: metrics.time(for: value.translation.width))
                        }
                        .onEnded { value in
                            tailTrim = 0
                            editor.trimOverlayTail(
                                id: item.id,
                                deltaSeconds: metrics.time(for: value.translation.width))
                            LumaHaptics.shared.trimRubberband()
                        }
                )
        }
    }

    /// Long-press then drag repositions the layer; the initial hold lets the
    /// scroll view's pan fail first.
    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture())
            .updating($barActive) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                isDraggingBar = true
                TimelineDragLock.isHeld = true
                var t = clampTranslation(drag?.translation.width ?? 0)
                // Live magnet snap: pull either edge onto the nearest
                // visible boundary within ~8pt and show the guide-line.
                if magnetOn {
                    let start = item.timelineOffset + metrics.time(for: t)
                    if let hit = TimelineSnap.magnet(start: start, duration: item.duration,
                                                     editor: editor, metrics: metrics,
                                                     viewportWidth: snap.viewportWidth) {
                        t = clampTranslation(metrics.x(for: start + hit.shift - item.timelineOffset))
                        snap.snappedTime = hit.target
                        if lastSnappedTime != hit.target {
                            LumaHaptics.shared.timelineSnap()
                            lastSnappedTime = hit.target
                        }
                    } else {
                        snap.snappedTime = nil
                        lastSnappedTime = nil
                    }
                }
                dragTranslation = t
            }
            .onEnded { value in
                if case .second(true, _) = value {
                    commitDrag(translation: dragTranslation)
                }
                isDraggingBar = false
                dragTranslation = 0
                snap.snappedTime = nil
                lastSnappedTime = nil
            }
    }

    private func overlayTrimHandle(system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(LumaTheme.ink)
            .frame(width: 14, height: LaneMetrics.overlay)
            .background(LumaTheme.textPrimary.opacity(0.9))
            // 14 pt grip, 44 pt touch; only 2 pt into the lanes above/below.
            .contentShape(HitSlop(horizontal: 15, vertical: 2))
    }

    private func clampTranslation(_ translation: CGFloat) -> CGFloat {
        let minX = -metrics.x(for: item.timelineOffset)
        let maxX = metrics.x(for: max(0, editor.totalDuration - 0.2 - item.timelineOffset))
        return min(max(translation, minX), maxX)
    }

    private func commitDrag(translation: CGFloat) {
        // The live magnet has already put a snapped bar on its target. A
        // second snap here, on a fixed 0.15 s window, ignored the magnet
        // switch and could catch a boundary the person couldn't see.
        editor.setOverlayOffset(id: item.id, item.timelineOffset + metrics.time(for: translation))
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
    /// Live trim preview, already clamped by the engine, so the bar and its
    /// waveform follow the grip like a clip's instead of jumping on release.
    @State private var headTrimShift: Double = 0
    @State private var headOffsetShift: Double = 0
    @State private var tailTrimShift: Double = 0
    @GestureState private var barActive = false

    var body: some View {
        ZStack(alignment: .leading) {
            musicBar(track)
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: LaneMetrics.music, alignment: .leading)
        .sensoryFeedback(.impact(weight: .light), trigger: isDraggingBar)
        .onChange(of: barActive) { _, active in
            TimelineDragLock.isHeld = active
        }
        // Not on the grips: they hide when a bar drag starts, and releasing
        // there would drop the lock that drag has just taken.
        .onDisappear { TimelineDragLock.isHeld = false }
        .task(id: track.id) { await detectBeatsIfNeeded() }
    }

    /// Music lanes wear signal yellow (round-three timeline); voice and
    /// detached sound stay neutral so the song reads first.
    private var tintsSignal: Bool { track.kind == .music || track.kind == .sfx }

    /// One beat analysis per music lane per session, so the beat marks show
    /// without opening the Music panel. Uses the engine's own `detectBeats`
    /// (BeatDetector), which stores the markers on the track.
    @MainActor
    private func detectBeatsIfNeeded() async {
        let id = track.id
        guard track.kind == .music,
              !BeatMarksAutoDetect.attempted.contains(id),
              let current = editor.audioTracks.first(where: { $0.id == id }),
              current.beatMarkers.isEmpty else { return }
        BeatMarksAutoDetect.attempted.insert(id)
        await editor.detectBeats(trackID: id)
    }

    private func musicBar(_ music: EditorState.MusicTrack) -> some View {
        let shownStart = music.timelineOffset + headOffsetShift
        let shownTrimStart = music.trimStart + headTrimShift
        let shownTrimEnd = music.trimEnd + tailTrimShift
        let rendered = max(0.05, min(shownTrimEnd - shownTrimStart,
                                     editor.totalDuration - shownStart))
        let barWidth = max(metrics.x(for: rendered), 28)
        // Handles come and go with the COMMITTED width, so a preview can't
        // remove a grip mid-drag and cancel the trim.
        let committedWidth = max(metrics.x(for: max(0.05, min(music.timelineDuration,
                                                            editor.totalDuration - music.timelineOffset))), 28)
        return HStack(spacing: 6) {
            Image(systemName: music.isMuted ? "speaker.slash.fill" : music.kind.icon)
                .font(.system(size: 10.5, weight: .bold))
            if music.isLooping {
                Image(systemName: "repeat").font(.system(size: 9, weight: .heavy)).opacity(0.85)
            }
            // Chrome is dropped progressively as the bar narrows, so a short
            // voiceover never cuts its title to "Voi…" over the waveform.
            if barWidth > 132 {
                Text(music.title)
                    .font(.luma(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if barWidth > 176 {
                Text(String(format: "%.1fs", rendered))
                    .font(.luma(size: 10, weight: .medium))
                    .monospacedDigit()
                    // An opaque plate so the readout never overprints waveform.
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .foregroundStyle(LumaTheme.textPrimary.opacity(0.9))
        .padding(.horizontal, 8)
        .frame(width: barWidth, height: LaneMetrics.music)
        .background {
            // Fill + real waveform (trimmed window of whole-file RMS buckets).
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(laneFill(muted: music.isMuted))
                if !music.waveform.isEmpty {
                    WaveformBars(samples: music.waveform,
                                 windowStart: shownTrimStart / max(music.assetDuration, 0.01),
                                 windowEnd: shownTrimEnd / max(music.assetDuration, 0.01),
                                 colour: tintsSignal ? LumaTheme.signal.opacity(music.isMuted ? 0.25 : 0.5)
                                                     : Color.white.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(isDraggingBar ? Color.white : laneStroke,
                          lineWidth: isDraggingBar ? 1.5 : 1))
        .overlay(alignment: .leading) {
            // Beat marks (C6): a dot at each detected beat, a bigger signal
            // dot on every fourth so the bar lines read.
            if !music.beatMarkers.isEmpty {
                BeatDots(beats: music.beatMarkers, trimStart: shownTrimStart,
                         metrics: metrics, signal: tintsSignal)
                    .frame(width: barWidth, height: LaneMetrics.music)
            }
        }
        .overlay {
            if !isDraggingBar, committedWidth > 120 {
                MusicTrimHandles(metrics: metrics, trackID: music.id, editor: editor,
                                 headTrimShift: $headTrimShift,
                                 headOffsetShift: $headOffsetShift,
                                 tailTrimShift: $tailTrimShift)
            }
        }
        .opacity(isDraggingBar ? 0.92 : 1)
        .offset(x: metrics.x(for: shownStart) + dragTranslation)
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
                .updating($barActive) { value, active, _ in
                    if case .second(true, _) = value { active = true }
                }
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    isDraggingBar = true
                    TimelineDragLock.isHeld = true
                    var t = clampTranslation(drag?.translation.width ?? 0, music: music)
                    if magnetOn {
                        let start = music.timelineOffset + metrics.time(for: t)
                        if let hit = TimelineSnap.magnet(start: start, duration: music.timelineDuration,
                                                         editor: editor, metrics: metrics,
                                                         viewportWidth: snap.viewportWidth) {
                            t = clampTranslation(metrics.x(for: start + hit.shift - music.timelineOffset),
                                                 music: music)
                            snap.snappedTime = hit.target
                            if lastSnappedTime != hit.target {
                                LumaHaptics.shared.timelineSnap()
                                lastSnappedTime = hit.target
                            }
                        } else {
                            snap.snappedTime = nil
                            lastSnappedTime = nil
                        }
                    }
                    dragTranslation = t
                }
                .onEnded { value in
                    if case .second(true, _) = value {
                        commitDrag(translation: dragTranslation, music: music)
                    }
                    isDraggingBar = false
                    dragTranslation = 0
                    snap.snappedTime = nil
                    lastSnappedTime = nil
                }
        )
    }

    private func laneFill(muted: Bool) -> Color {
        if tintsSignal { return LumaTheme.signal.opacity(muted ? 0.03 : 0.07) }
        return muted ? LumaTheme.surface : LumaTheme.surfaceStrong
    }

    private var laneStroke: Color {
        tintsSignal ? LumaTheme.signal.opacity(0.18) : Color.white.opacity(0.1)
    }

    private func clampTranslation(_ translation: CGFloat, music: EditorState.MusicTrack) -> CGFloat {
        let minX = -metrics.x(for: music.timelineOffset)
        let maxX = metrics.x(for: max(0, editor.totalDuration - 0.2 - music.timelineOffset))
        return min(max(translation, minX), maxX)
    }

    private func commitDrag(translation: CGFloat, music: EditorState.MusicTrack) {
        // The live magnet has already put a snapped bar on its target; see
        // OverlayBar.commitDrag for why there is no second snap here.
        editor.setMusicOffset(id: music.id, music.timelineOffset + metrics.time(for: translation))
    }

    /// Waveform bars over the trimmed sample window.
    private struct WaveformBars: View {
        let samples: [Float]
        let windowStart: Double
        let windowEnd: Double
        var colour: Color = Color.white.opacity(0.28)

        var body: some View {
            Canvas { context, size in
                guard !samples.isEmpty, windowEnd > windowStart else { return }
                let barCount = max(4, Int(size.width / 3))
                for i in 0..<barCount {
                    let fraction = windowStart + (windowEnd - windowStart)
                        * Double(i) / Double(barCount)
                    let sample = samples[min(samples.count - 1,
                                             max(0, Int(fraction * Double(samples.count))))]
                    let h = max(1.5, CGFloat(sample) * size.height * 0.62)
                    let rect = CGRect(x: CGFloat(i) * size.width / CGFloat(barCount),
                                      y: size.height - h - 4,
                                      width: 1.8, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.9),
                                 with: .color(colour))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Beat dots along the top of the bar. Beat times are seconds into the
    /// source, so they shift with the bar's trim window.
    private struct BeatDots: View {
        let beats: [Double]
        let trimStart: Double
        let metrics: TimelineMetrics
        let signal: Bool

        var body: some View {
            Canvas { context, size in
                for (index, beat) in beats.enumerated() {
                    let x = metrics.x(for: beat - trimStart)
                    guard x >= 2, x <= size.width - 2 else { continue }
                    let strong = index % 4 == 0
                    let d: CGFloat = strong ? 3.5 : 2.2
                    let rect = CGRect(x: x - d / 2, y: 3, width: d, height: d)
                    let base: Color = signal ? LumaTheme.signal : Color.white
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(strong ? base : base.opacity(0.5)))
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
        @Binding var headTrimShift: Double
        @Binding var headOffsetShift: Double
        @Binding var tailTrimShift: Double
        @GestureState private var headActive = false
        @GestureState private var tailActive = false

        var body: some View {
            // The bar previews live while a grip drags; one engine commit per
            // drag (single undo entry, single rebuild), haptic on release.
            // Global coordinates, because the grip moves with the preview.
            HStack {
                handle(system: "chevron.compact.left")
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .updating($headActive) { _, active, _ in active = true }
                            .onChanged { value in
                                TimelineDragLock.isHeld = true
                                let shift = editor.musicHeadTrim(
                                    id: trackID,
                                    deltaSeconds: metrics.time(for: value.translation.width))
                                headTrimShift = shift.trimShift
                                headOffsetShift = shift.offsetShift
                            }
                            .onEnded { value in
                                headTrimShift = 0
                                headOffsetShift = 0
                                editor.trimMusicHead(
                                    id: trackID,
                                    deltaSeconds: metrics.time(for: value.translation.width))
                                LumaHaptics.shared.trimRubberband()
                            }
                    )
                Spacer()
                handle(system: "chevron.compact.right")
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .updating($tailActive) { _, active, _ in active = true }
                            .onChanged { value in
                                TimelineDragLock.isHeld = true
                                tailTrimShift = editor.musicTailTrim(
                                    id: trackID,
                                    deltaSeconds: metrics.time(for: value.translation.width))
                            }
                            .onEnded { value in
                                tailTrimShift = 0
                                editor.trimMusicTail(
                                    id: trackID,
                                    deltaSeconds: metrics.time(for: value.translation.width))
                                LumaHaptics.shared.trimRubberband()
                            }
                    )
            }
            // Releases the scroll lock and any half-shown trim on end AND on
            // cancel (a cancelled drag never reaches onEnded).
            .onChange(of: headActive || tailActive) { _, active in
                TimelineDragLock.isHeld = active
                if !active {
                    headTrimShift = 0
                    headOffsetShift = 0
                    tailTrimShift = 0
                }
            }
        }

        private func handle(system: String) -> some View {
            Image(systemName: system)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LumaTheme.ink)
                .frame(width: 14, height: LaneMetrics.music)
                .background(LumaTheme.textPrimary.opacity(0.85))
                // 14 pt grip, 44 pt touch; only 2 pt into the lanes above/below.
                .contentShape(HitSlop(horizontal: 15, vertical: 2))
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
            editor.seek(to: clamped, precise: false)

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

        /// A fresh touch can't be mid-trim, so it clears any lock a grip that
        /// vanished mid-drag never got to release.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if let touches = event?.allTouches, !touches.isEmpty,
               touches.allSatisfy({ $0.phase == .began }) {
                TimelineDragLock.isHeld = false
            }
            return super.hitTest(point, with: event)
        }

        /// While a trim handle or bar is mid-drag the pan must not start, or
        /// the timeline slides away under the finger.
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGestureRecognizer, TimelineDragLock.isHeld { return false }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
    }
}

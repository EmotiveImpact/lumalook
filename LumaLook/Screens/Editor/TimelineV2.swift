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

/// Lane heights for the vertical track stack. A future overlay lane is one
/// more row here + a `total` bump — nothing else changes.
enum LaneMetrics {
    static let ruler: CGFloat = 18
    static let video: CGFloat = 66
    static let music: CGFloat = 36
    static let spacing: CGFloat = 8
    static var total: CGFloat { ruler + video + music + 2 * spacing }
}

// MARK: - Timeline V2 (assembled)

/// Center-fixed-playhead multitrack timeline: content scrolls under a fixed
/// centre line; scrubbing drags the content, playback drives the scroll.
struct TimelineV2View: View {
    @ObservedObject var editor: EditorState
    let onAddMusic: () -> Void
    let onTapMusic: () -> Void

    @State private var metrics = TimelineMetrics()

    var body: some View {
        ZStack {
            if editor.isEmpty {
                emptyPlaceholder
            } else {
                TimelineScroller(editor: editor, metrics: $metrics,
                                 contentHeight: LaneMetrics.total) { m in
                    TimelineContentView(editor: editor, metrics: m,
                                        onAddMusic: onAddMusic, onTapMusic: onTapMusic)
                }
                playhead
            }
        }
        .frame(height: LaneMetrics.total)
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
    let onAddMusic: () -> Void
    let onTapMusic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LaneMetrics.spacing) {
            RulerLane(duration: editor.totalDuration, metrics: metrics)
            VideoLane(editor: editor, metrics: metrics)
            MusicLane(editor: editor, metrics: metrics,
                      onAddMusic: onAddMusic, onTapMusic: onTapMusic)
        }
        .frame(width: max(metrics.x(for: editor.totalDuration), 1),
               height: LaneMetrics.total, alignment: .leading)
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(editor.clips) { clip in
                TimelineClipCell(clip: clip,
                                 width: max(metrics.x(for: clip.timelineDuration), 10),
                                 selected: clip.id == editor.selectedClipID)
                    .onTapGesture {
                        editor.selectedClipID = clip.id == editor.selectedClipID ? nil : clip.id
                    }
                    .contextMenu {
                        Button {
                            editor.selectedClipID = clip.id
                            editor.moveSelected(by: -1)
                        } label: { Label("Move Left", systemImage: "arrow.left") }
                        Button {
                            editor.selectedClipID = clip.id
                            editor.moveSelected(by: 1)
                        } label: { Label("Move Right", systemImage: "arrow.right") }
                        Button(role: .destructive) {
                            editor.selectedClipID = clip.id
                            editor.deleteSelected()
                        } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .frame(height: LaneMetrics.video, alignment: .leading)
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
            if let thumb = clip.thumbnail {
                HStack(spacing: 0) {
                    ForEach(0..<max(1, Int(ceil(width / 44))), id: \.self) { _ in
                        Color.clear
                            .frame(width: 44, height: LaneMetrics.video)
                            .overlay {
                                Image(decorative: thumb, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
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
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? LumaTheme.accentBright : .white.opacity(0.08),
                    lineWidth: selected ? 2.5 : 1))
        .shadow(color: selected ? LumaTheme.accent.opacity(0.45) : .clear, radius: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

// MARK: - Music lane

struct MusicLane: View {
    @ObservedObject var editor: EditorState
    let metrics: TimelineMetrics
    let onAddMusic: () -> Void
    let onTapMusic: () -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingBar = false

    var body: some View {
        ZStack(alignment: .leading) {
            if let music = editor.music {
                musicBar(music)
            } else {
                addButton
            }
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
            Image(systemName: music.isMuted ? "speaker.slash.fill" : "music.note")
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
        .background(music.isMuted ? AnyShapeStyle(LumaTheme.surfaceStrong)
                                  : AnyShapeStyle(LumaTheme.accentDeep),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(isDraggingBar ? LumaTheme.accentBright : .white.opacity(0.12),
                          lineWidth: isDraggingBar ? 2 : 1))
        .opacity(isDraggingBar ? 0.92 : 1)
        .offset(x: metrics.x(for: music.timelineOffset) + dragTranslation)
        .onTapGesture(perform: onTapMusic)
        .contextMenu {
            Button {
                editor.setMusicMuted(!music.isMuted)
            } label: {
                Label(music.isMuted ? "Unmute" : "Mute",
                      systemImage: music.isMuted ? "speaker.wave.2" : "speaker.slash")
            }
            Button(role: .destructive) {
                editor.removeMusic()
            } label: { Label("Remove Music", systemImage: "trash") }
        }
        // Long-press-then-drag repositions the music on the timeline; the
        // initial hold lets the scroll view's pan fail first.
        .gesture(
            LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture())
                .onChanged { value in
                    guard case .second(true, let drag) = value else { return }
                    isDraggingBar = true
                    dragTranslation = clampTranslation(drag?.translation.width ?? 0, music: music)
                }
                .onEnded { value in
                    if case .second(true, let drag) = value {
                        let translation = clampTranslation(drag?.translation.width ?? 0, music: music)
                        commitDrag(translation: translation, music: music)
                    }
                    isDraggingBar = false
                    dragTranslation = 0
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
        editor.setMusicOffset(offset)
    }

    private var addButton: some View {
        Button(action: onAddMusic) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Add music")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .frame(width: 170, height: LaneMetrics.music)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.white.opacity(0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Scroller (UIKit)

/// Center-fixed-playhead scroller. Content scrolls under a fixed centre line:
/// `contentInset = viewport/2` on both sides, so t = 0 and t = duration both
/// land exactly under the playhead at the scroll extremes.
struct TimelineScroller<Content: View>: UIViewRepresentable {
    @ObservedObject var editor: EditorState
    @Binding var metrics: TimelineMetrics
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

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.editor = editor
        coordinator.metrics = metrics
        coordinator.metricsBinding = $metrics
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
        var contentHeight: CGFloat = 0

        /// Write-side guard: offset assignments from code must not read back
        /// as user scrubs.
        var isProgrammaticScroll = false
        private var isPinching = false
        private var pinchStartPPS: CGFloat = 50
        private var pinchWasClamped = false
        private var lastHapticSecond = Int.min
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

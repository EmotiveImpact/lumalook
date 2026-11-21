import SwiftUI
import AVKit

// =============================================================================
// C2 — COMPARE & CONFIRM, in the approved design language.
//
// The canonical deep-compare surface: three explicit compare modes (no hidden
// gestures), strength adjustable without leaving the screen, and an instruction
// bar that either goes back to browsing or chains straight into the export
// sheet with the grade applied.
//
// Relationship to the grade room (C1): ApplyLookView's ORIGINAL tile is the
// QUICK peek — press and hold, local, gesture-only. This screen is where
// comparing is a task with modes and an outcome. The grade room's Compare tool
// and its Apply button both land here.
//
// FEATURE INVENTORY — nothing is dropped.
//   ✓ Split wipe — draggable divider, ORIGINAL left / GRADED right, labels
//     pinned to match the render rather than the other way round
//   ✓ Hold to flip — press and hold anywhere to drop to the original
//   ✓ Side by side — two panes off ONE reference frame, stacked or beside each
//     other according to the SOURCE aspect so a grade is actually judgeable
//   ✓ Strength stays live inside compare — no mode switch to tweak it
//   ✓ Playback transport for video: play/pause, scrub, elapsed / duration
//   ✓ Apply & export → ExportSpecSheet → single OR batch export → Done
//   ✓ Export progress overlay with cancel, and the batch status caption
//   ✓ Export errors surfaced here rather than dying with the sheet
//   ✓ Empty-state hint when nothing is picked (the hero photo still grades)
//   ✓ Grade-session autosave on the way to export
//   ✓ The wipe is preview chrome and is never baked into an export
//   ✓ LUMA_SEED_COMPARE=split|flip|side headless seeding preserved
//
// THE LANGUAGE
//   1. The image is the interface — media uncovered at the top with a generous
//      radius, every control in the drawer below it. The only things drawn on
//      the frame are the ones that must REGISTER with the picture: the wipe
//      divider and its two side labels, and the transient hold-to-flip state.
//   2. Monochrome chrome — no accent anywhere. All colour is the footage.
//   3. Stroke means selection; modes separate by surface value and weight.
//   5. Two-axis browsing — the compare mode is a centred label with its
//      neighbours faded either side, swipeable, exactly like the look
//      categories in the grade room.
//   6. Mono is for NUMBERS ONLY — percentages and timecode. No TechReadout.
//   8. A calm instruction bar: back at one edge, the applied look and its
//      strength stated in the middle, Apply & export at the other.
// =============================================================================

struct BeforeAfterView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss

    enum CompareMode: String, CaseIterable, Identifiable {
        case split, flip, side
        var id: String { rawValue }
        /// A mode is a NAME — sentence case, system font, no tracked caps.
        var title: String {
            switch self {
            case .split: return "Split wipe"
            case .flip:  return "Hold to flip"
            case .side:  return "Side by side"
            }
        }
    }

    @State private var mode: CompareMode = CompareMode(
        rawValue: ProcessInfo.processInfo.environment["LUMA_SEED_COMPARE"] ?? "") ?? .split
    @State private var splitFraction: Double = 0.5
    @State private var holdingOriginal = false
    @State private var stashedIntensity: Double?

    // Side-by-side panes: one reference frame, rendered twice.
    @State private var originalPane: CGImage?
    @State private var gradedPane: CGImage?

    // Playback
    @State private var isPlaying = true
    @State private var progress: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserver: Any?
    @State private var timeObserverPlayer: AVPlayer?

    // Export
    @State private var showExportSheet = false
    @State private var isExporting = false
    /// Set when the grade uses a premium look this user has not unlocked.
    @State private var lookLock: LookLock?

    private var modes: [CompareMode] { CompareMode.allCases }
    private var modeIndex: Int { modes.firstIndex(of: mode) ?? 0 }

    private var hasRealMedia: Bool {
        app.player != nil || app.selectedImage != nil
    }

    private var lookName: String {
        app.selectedLUT?.displayName ?? app.selectedLook.name
    }

    /// Identifies the selected asset, not merely its dimensions. Two different
    /// photographs can have identical extents and still require fresh panes.
    private var mediaIdentity: String {
        if let url = app.selectedVideoURL { return "video-\(url.absoluteString)" }
        if let still = app.selectedImage { return "still-\(ObjectIdentifier(still))" }
        if let player = app.player { return "player-\(ObjectIdentifier(player))" }
        return "sample"
    }

    /// Everything that changes what the graded pane should look like.
    private var gradeStamp: String {
        "\(app.settings)-\(app.selectedLook.id)-\(app.selectedLUT?.id.uuidString ?? "")"
        + "-\(app.conversionLUT?.id.uuidString ?? "")-\(Int(app.creativeOpacity))"
        // Keyed on the RESOLVED source, so swapping between the hero fallback
        // and real media re-renders the panes instead of holding a stale pair.
        + "-\(Int(app.conversionOpacity))-\(mediaIdentity)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                stage
                drawer
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            attachTimeObserver()
            app.exportError = nil
            applyMode(mode)
        }
        .onChange(of: mode) { _, new in applyMode(new) }
        .task(id: "\(gradeStamp)|\(mode.rawValue)") {
            guard mode == .side else { return }
            await renderPanes()
        }
        .onDisappear {
            detachTimeObserver()
            releaseHold()
            app.lookState.splitFraction = nil
            app.refreshPreviewFrame()
        }
        // Previewing a premium look is free; exporting it asks once, and a
        // purchase carries straight on into the export sheet.
        .lockedLookSheet($lookLock) { openExportSheet() }
        .lumaToolSheet(isPresented: $showExportSheet, style: .panel) {
            ExportSpecSheet(durationSeconds: app.selectedImage != nil ? 0 : duration,
                            gradeCubeTitle: "LumaLook_\(app.selectedLook.name.components(separatedBy: " ").first ?? "Grade")",
                            lookState: app.lookState) { spec in
                showExportSheet = false
                startExport(spec: spec)
            }
        }
        // Export failures/refusals surface here rather than dying with the
        // sheet — over the DRAWER, never over the picture.
        .overlay(alignment: .bottom) { exportErrorToast }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.exportError != nil)
        .overlay {
            if isExporting {
                ExportOverlay(progress: app.exporter.progress) { app.exporter.cancel() }
                    .overlay(alignment: .top) {
                        if let status = app.batchStatus {
                            Text(status)
                                .font(.luma(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(.top, 90)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var exportErrorToast: some View {
        if let error = app.exportError, !isExporting {
            Text(error)
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(LumaTheme.bar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { app.exportError = nil }
                }
        }
    }

    // MARK: - Mode

    /// Each mode owns exactly one pipeline state, so switching can never leave
    /// a stale wipe or a stashed strength behind.
    private func applyMode(_ new: CompareMode) {
        releaseHold()
        switch new {
        case .split:
            app.lookState.splitFraction = splitFraction
        case .flip, .side:
            app.lookState.splitFraction = nil
        }
        app.refreshPreviewFrame()
        app.objectWillChange.send()
    }

    // MARK: - Stage — the picture, cut to the source, uncovered

    /// Width / height of the reference frame, defaulting to 16:9.
    private var sourceAspect: CGFloat {
        let extent = GradeSourceFrame.current(app).extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return 16.0 / 9.0 }
        return extent.width / extent.height
    }

    /// The side-by-side pair is a PAIR — it owns the whole stage and sets its
    /// own proportions. The single-picture modes are cut to the source.
    private var stage: some View {
        Group {
            switch mode {
            case .split: splitStage.aspectRatio(sourceAspect, contentMode: .fit)
            case .flip:  flipStage.aspectRatio(sourceAspect, contentMode: .fit)
            case .side:  sideStage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: sourceAspect)
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: - Split (wipe)

    /// The pipeline composites ORIGINAL left of the divider and GRADED right
    /// (`LookPipeline.apply`), so the labels are pinned to match the render,
    /// not the other way round. The divider and its labels are the one thing
    /// on this screen that MUST be drawn on the picture — they register with it.
    private var splitStage: some View {
        GeometryReader { geo in
            ZStack {
                LookPreviewSurface(radius: 22, showsEmptyHint: false)
                    .frame(width: geo.size.width, height: geo.size.height)

                let x = geo.size.width * splitFraction
                WipeHandle()
                    .frame(height: geo.size.height)
                    .position(x: x, y: geo.size.height / 2)

                // Labels ride the handle so which side is which is never a guess.
                wipeLabel("Original", bright: false)
                    .position(x: max(52, x - 50), y: 22)
                wipeLabel("Graded", bright: true)
                    .position(x: min(geo.size.width - 48, x + 48), y: 22)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // clipShape clips PIXELS, not touches.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        splitFraction = min(max(value.location.x / geo.size.width, 0.02), 0.98)
                        app.lookState.splitFraction = splitFraction
                        app.refreshPreviewFrame()
                        app.objectWillChange.send()
                    }
            )
        }
    }

    private func wipeLabel(_ text: String, bright: Bool) -> some View {
        Text(text)
            .font(.luma(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(bright ? 0.95 : 0.7))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.black.opacity(0.5), in: Capsule())
            .allowsHitTesting(false)
    }

    // MARK: - Hold to flip

    private var flipStage: some View {
        LookPreviewSurface(radius: 22, showsEmptyHint: false)
            .overlay(alignment: .top) {
                // The instruction IS the affordance — the point of this mode is
                // that nothing about it is discovered by accident.
                Text(holdingOriginal ? "Original" : "Press and hold to flip")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(holdingOriginal ? 1 : 0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 14)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 60) {
            } onPressingChanged: { pressing in
                if pressing { takeHold() } else { releaseHold() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: holdingOriginal)
            .animation(.easeOut(duration: 0.12), value: holdingOriginal)
    }

    private func takeHold() {
        if stashedIntensity == nil { stashedIntensity = app.settings.intensity }
        holdingOriginal = true
        app.settings.intensity = 0
    }

    private func releaseHold() {
        guard let stashed = stashedIntensity else { return }
        app.settings.intensity = stashed
        stashedIntensity = nil
        holdingOriginal = false
    }

    // MARK: - Side by side

    /// Two panes off ONE reference frame: video pauses so both halves describe
    /// the same moment.
    ///
    /// The pair is sized to the SOURCE, and WHICH way the pair stacks follows
    /// the source too. A landscape frame laid out as two side-by-side cards
    /// makes a 32:9 pair that width-fits down to postage stamps; stacked, each
    /// pane gets the full stage width and a grade is actually judgeable.
    /// Portrait sources take the mirror rule.
    private var sideStage: some View {
        Group {
            if sourceAspect >= 1 {
                VStack(spacing: 6) {
                    originalPaneView
                    gradedPaneView
                }
                .aspectRatio(sourceAspect / 2, contentMode: .fit)
            } else {
                HStack(spacing: 6) {
                    originalPaneView
                    gradedPaneView
                }
                .aspectRatio(sourceAspect * 2, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var originalPaneView: some View {
        pane(originalPane) {
            Text("Original")
                .font(.luma(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var gradedPaneView: some View {
        pane(gradedPane) {
            HStack(spacing: 6) {
                Text("Graded")
                    .font(.luma(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("\(Int(app.settings.intensity.rounded()))%")
                    .font(.luma(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func pane<Label: View>(_ image: CGImage?,
                                   @ViewBuilder label: () -> Label) -> some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .top) {
            label()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }

    /// Renders both panes from the reference frame. `previewFrame` is already
    /// bounded to 480px; nothing here is clamped-to-extent, so the spatial ops
    /// in the pipeline stay honest.
    private func renderPanes() async {
        app.player?.pause()
        isPlaying = false
        // Same ladder Split and Flip resolve through (LookPreviewSurface), so
        // all three modes compare the SAME photograph — distinct modes, one image.
        let frame = GradeSourceFrame.current(app)
        let extent = frame.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else {
            originalPane = nil
            gradedPane = nil
            return
        }
        let state = app.lookState
        let panes = await Task.detached(priority: .userInitiated) {
            let original = LookPipeline.shared.context.createCGImage(frame, from: extent)
            let graded = LookPipeline.shared.gradedStill(frame, state: state,
                                                          includeSplit: false)
            return (original, graded)
        }.value
        guard !Task.isCancelled else { return }
        originalPane = panes.0
        gradedPane = panes.1
    }

    // MARK: - Drawer

    private var drawer: some View {
        VStack(spacing: 0) {
            statusLine
                .padding(.top, 12)
                .padding(.bottom, 12)
            modeBar
                .padding(.bottom, 14)
            if app.player != nil {
                transport
                    .padding(.bottom, 12)
            }
            GradeOpacityRow(value: $app.settings.intensity)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            instructionBar
        }
        .frame(maxWidth: .infinity)
        .background { Color.black.ignoresSafeArea(edges: .bottom) }
    }

    /// One line that says what the mode does, plus the empty-state caveat.
    private var statusLine: some View {
        Group {
            if !hasRealMedia {
                Text("Previewing the sample photo — pick a clip to compare your own")
            } else {
                Text(modeBlurb)
            }
        }
        .font(.luma(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    private var modeBlurb: String {
        switch mode {
        case .split: return "Drag the divider across the frame"
        case .flip:  return "Press and hold the picture to drop the look"
        case .side:  return "One frame, rendered twice"
        }
    }

    /// The current mode centred, its neighbours faded either side — the same
    /// two-axis bar the grade room browses categories with, so the gesture is
    /// learned once and works everywhere.
    private var modeBar: some View {
        HStack(spacing: 0) {
            modeLabel(at: modeIndex - 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(mode.title)
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
            modeLabel(at: modeIndex + 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let delta = value.translation.width < 0 ? 1 : -1
                    stepMode(to: modeIndex + delta)
                }
        )
    }

    private func stepMode(to index: Int) {
        guard modes.indices.contains(index) else { return }
        LumaHaptics.shared.tap()
        withAnimation(.snappy(duration: 0.22)) { mode = modes[index] }
    }

    @ViewBuilder
    private func modeLabel(at index: Int) -> some View {
        if modes.indices.contains(index) {
            Button { stepMode(to: index) } label: {
                Text(modes[index].title)
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    // MARK: - Instruction bar

    private var instructionBar: some View {
        let strength = Int(app.settings.intensity.rounded())
        return ZStack {
            Group {
                if strength == 0 {
                    Text("Showing the original")
                        .font(.luma(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    HStack(spacing: 7) {
                        Text(lookName)
                            .font(.luma(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text("\(strength)%")
                            .font(.luma(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .lineLimit(1)
            // Clears the wider of the two edge controls on both sides, so the
            // statement is optically centred and can never slide under the CTA.
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 132)
            .allowsHitTesting(false)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Back to looks")
                Spacer(minLength: 0)
                exportButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// The one filled button on the screen.
    private var exportButton: some View {
        Button {
            guard hasRealMedia else {
                LumaHaptics.shared.tap()
                app.path = [.selectClip]
                return
            }
            LumaHaptics.shared.tap()
            if let lock = app.lockedLookInGrade(storeService) {
                lookLock = lock
                return
            }
            openExportSheet()
        } label: {
            Text("Apply & export")
                .font(.luma(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.lumaPress)
    }

    /// Commit the grade as compared: drop the wipe (it is preview chrome,
    /// never baked) and open the export sheet with the same lookState.
    private func openExportSheet() {
        releaseHold()
        app.lookState.splitFraction = nil
        app.saveGradeSession()
        app.exportError = nil
        showExportSheet = true
    }

    // MARK: - Playback

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                guard let player = app.player else { return }
                if isPlaying { player.pause() } else { player.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)

            Text(timeString(progress * duration))
                .font(.luma(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText())

            Slider(value: $progress, in: 0...1) { editing in
                guard let player = app.player else { return }
                if editing {
                    player.pause()
                } else {
                    let target = CMTime(seconds: progress * duration, preferredTimescale: 600)
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    if isPlaying { player.play() }
                }
            }
            .tint(.white.opacity(0.85))

            Text(timeString(duration))
                .font(.luma(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 20)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func attachTimeObserver() {
        guard let player = app.player, let item = player.currentItem else { return }
        detachTimeObserver()
        Task {
            if let d = try? await item.asset.load(.duration).seconds, d.isFinite, d > 0 {
                duration = d
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { time in
            guard duration > 0 else { return }
            progress = min(max(time.seconds / duration, 0), 1)
        }
        timeObserverPlayer = player
    }

    private func detachTimeObserver() {
        if let timeObserver, let player = timeObserverPlayer {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeObserverPlayer = nil
    }

    // MARK: - Export

    private func startExport(spec: ExportSpec) {
        guard hasRealMedia else {
            app.exportError = "Pick a video or photo from your library first."
            return
        }
        isExporting = true
        Task {
            // Batch grading (one look across a picked set) runs through the same
            // exporter as a single clip; only the completion count differs.
            if !app.batchItems.isEmpty {
                let done = await app.runBatchExport(spec: spec)
                isExporting = false
                if done > 0 {
                    LumaHaptics.shared.exportSuccess()
                    app.path.append(.exportComplete)
                }
            } else {
                let success = await app.exportCurrentVideo(spec: spec)
                isExporting = false
                if success {
                    LumaHaptics.shared.exportSuccess()
                    app.path.append(.exportComplete)
                }
            }
        }
    }
}

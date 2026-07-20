import SwiftUI
import AVKit

// =============================================================================
// C2 — Compare & confirm. The canonical deep-compare surface: three explicit
// compare modes (no hidden gestures), opacity adjustable without leaving the
// screen, and a footer that either goes back to browsing or chains straight
// into the export sheet with the grade applied.
//
// Relationship to the grade room (C1): ApplyLookView's corner tile is the
// QUICK peek — press and hold, local, gesture-only. This screen is where
// comparing is a task with modes and an outcome. The grade room's header
// Compare button and its Apply CTA both land here.
// =============================================================================

struct BeforeAfterView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    enum CompareMode: String, CaseIterable, Identifiable {
        case split, flip, side
        var id: String { rawValue }
        var title: String {
            switch self {
            case .split: return "Split ⇔"
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

    // Export
    @State private var showExportSheet = false
    @State private var isExporting = false

    private var hasRealMedia: Bool {
        app.player != nil || app.selectedImage != nil
    }

    private var lookName: String {
        (app.selectedLUT?.displayName ?? app.selectedLook.name).uppercased()
    }

    /// Everything that changes what the graded pane should look like.
    private var gradeStamp: String {
        "\(app.settings)-\(app.selectedLook.id)-\(app.selectedLUT?.id.uuidString ?? "")"
        + "-\(app.conversionLUT?.id.uuidString ?? "")-\(Int(app.creativeOpacity))"
        + "-\(Int(app.conversionOpacity))-\(app.previewFrame?.extent.debugDescription ?? "none")"
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            footer
        }
        .background(LumaTheme.background.ignoresSafeArea())
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
            renderPanes()
        }
        .onDisappear {
            detachTimeObserver()
            releaseHold()
            app.lookState.splitFraction = nil
            app.refreshPreviewFrame()
        }
        .lumaToolSheet(isPresented: $showExportSheet, style: .panel) {
            ExportSpecSheet(durationSeconds: app.selectedImage != nil ? 0 : duration,
                            gradeCubeTitle: "LumaLook_\(app.selectedLook.name.components(separatedBy: " ").first ?? "Grade")",
                            lookState: app.lookState) { spec in
                showExportSheet = false
                startExport(spec: spec)
            }
        }
        // Export failures/refusals surface here rather than dying with the sheet.
        .overlay(alignment: .top) {
            if let error = app.exportError, !isExporting {
                Text(error)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(LumaTheme.orange.opacity(0.55), lineWidth: 1))
                    .padding(.horizontal, 30)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        withAnimation(.easeOut(duration: 0.25)) { app.exportError = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.exportError != nil)
        .overlay {
            if isExporting {
                ExportOverlay(progress: app.exporter.progress) { app.exporter.cancel() }
                    .overlay(alignment: .top) {
                        if let status = app.batchStatus {
                            TechReadout(status, size: 11, color: .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(.top, 90)
                        }
                    }
            }
        }
    }

    // MARK: - Mode

    /// Each mode owns exactly one pipeline state, so switching can never leave
    /// a stale wipe or a stashed intensity behind.
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

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            Color.black
            switch mode {
            case .split: splitStage
            case .flip:  flipStage
            case .side:  sideStage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottomLeading) {
            // One stack owns this anchor. The empty-state hint is folded in here
            // rather than left inside LookPreviewSurface, where it composited on
            // top of this readout.
            VStack(alignment: .leading, spacing: 6) {
                if app.player == nil && app.selectedImage == nil {
                    EmptyMediaHint()
                }
                TechReadout("\(lookName) · \(Int(app.settings.intensity))%", size: 9,
                            color: LumaTheme.accentBright)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            Spacer()
            TechReadout("COMPARE", size: 12, color: .white.opacity(0.85))
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .background {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Split (wipe)

    /// The pipeline composites ORIGINAL left of the divider and GRADED right
    /// (`LookPipeline.apply`), so the labels are pinned to match the render,
    /// not the other way round.
    private var splitStage: some View {
        GeometryReader { geo in
            // The divider and its labels belong to the PICTURE, not the stage.
            // Spanning the full stage drew a hard white line straight through
            // the COMPARE header and the bottom readout, and stranded the
            // ORIGINAL/GRADED chips in the letterbox void above the frame.
            let media = fittedRect(in: geo.size)
            let labelY = max(media.minY + 18, 96)
            ZStack {
                LookPreviewSurface(radius: 0, showsEmptyHint: false)
                    .frame(width: geo.size.width, height: geo.size.height)

                let x = geo.size.width * splitFraction
                WipeHandle()
                    .frame(height: media.height)
                    .position(x: x, y: media.midY)

                // Labels ride the handle so which side is which is never a guess.
                wipeLabel("ORIGINAL", tint: .white.opacity(0.8))
                    .position(x: max(56, x - 52), y: labelY)
                wipeLabel("GRADED", tint: LumaTheme.accentBright)
                    .position(x: min(geo.size.width - 50, x + 50), y: labelY)
            }
            .contentShape(Rectangle())
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

    private func wipeLabel(_ text: String, tint: Color) -> some View {
        TechReadout(text, size: 9, color: tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .allowsHitTesting(false)
    }

    // MARK: - Hold to flip

    private var flipStage: some View {
        LookPreviewSurface(radius: 0, showsEmptyHint: false)
            .overlay(alignment: .top) {
                // The instruction IS the affordance — the point of this mode is
                // that nothing about it is discovered by accident.
                TechReadout(holdingOriginal ? "ORIGINAL" : "PRESS AND HOLD TO FLIP",
                            size: 9,
                            color: holdingOriginal ? .white : .white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 92)
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 60) {
            } onPressingChanged: { pressing in
                if pressing { takeHold() } else { releaseHold() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: holdingOriginal)
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
    /// the same moment. Labelled as a frame comparison, not live playback.
    private var sideStage: some View {
        // The pair is sized to the SOURCE, not to the stage — but WHICH way the
        // pair stacks has to follow the source too. A landscape frame laid out
        // as two side-by-side cards makes a 32:9 pair that width-fits down to
        // postage stamps; stacked, each pane gets the full stage width and a
        // grade is actually judgeable. Portrait sources take the mirror rule.
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
        .padding(.top, 78)
        .padding(.bottom, 44)
        .padding(.horizontal, 10)
    }

    private var originalPaneView: some View {
        pane(originalPane, label: "ORIGINAL", tint: .white.opacity(0.8))
    }

    private var gradedPaneView: some View {
        pane(gradedPane, label: "GRADED · \(Int(app.settings.intensity))%",
             tint: LumaTheme.accentBright)
    }

    /// The rect the aspect-fitted media actually occupies inside `size`.
    private func fittedRect(in size: CGSize) -> CGRect {
        guard size.width > 1, size.height > 1 else { return CGRect(origin: .zero, size: size) }
        var w = size.width
        var h = size.width / sourceAspect
        if h > size.height {
            h = size.height
            w = size.height * sourceAspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Width / height of the reference frame, defaulting to 16:9.
    private var sourceAspect: CGFloat {
        let extent = (app.previewFrame ?? LookThumbs.fallbackFrame).extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return 16.0 / 9.0 }
        return extent.width / extent.height
    }

    private func pane(_ image: CGImage?, label: String, tint: Color) -> some View {
        ZStack {
            LumaTheme.surfaceStrong
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1)))
        .overlay(alignment: .top) {
            TechReadout(label, size: 8, color: tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.top, 8)
        }
    }

    /// Renders both panes from the reference frame. `previewFrame` is already
    /// bounded to 480px; nothing here is clamped-to-extent, so the spatial ops
    /// in the pipeline stay honest.
    private func renderPanes() {
        app.player?.pause()
        isPlaying = false
        let frame = app.previewFrame ?? LookThumbs.fallbackFrame
        let extent = frame.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else {
            originalPane = nil
            gradedPane = nil
            return
        }
        originalPane = LookPipeline.shared.context.createCGImage(frame, from: extent)
        gradedPane = LookPipeline.shared.gradedStill(frame, state: app.lookState,
                                                     includeSplit: false)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            if app.player != nil { transport }

            HStack(spacing: 8) {
                ForEach(CompareMode.allCases) { option in
                    Button {
                        LumaHaptics.shared.tap()
                        withAnimation(.easeOut(duration: 0.18)) { mode = option }
                    } label: {
                        Text(option.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(mode == option ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(mode == option ? AnyShapeStyle(LumaTheme.accent)
                                                       : AnyShapeStyle(LumaTheme.surface),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .frame(maxWidth: .infinity)

            // Opacity stays live inside compare — no mode switch to tweak.
            GradeOpacityRow(value: $app.settings.intensity)
                .padding(.horizontal, 20)

            // Explicit fractional widths: an HStack cannot express the mockup's
            // 1 : 1.4 split on its own, and giving the CTA `maxWidth: .infinity`
            // plus `layoutPriority(1)` let it eat the whole row and collapse the
            // ghost button to zero width.
            GeometryReader { geo in
                let gap: CGFloat = 10
                let unit = max(0, (geo.size.width - gap) / 2.4)
                HStack(spacing: gap) {
                    Button { dismiss() } label: {
                        Text("Back to looks")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(.white.opacity(0.14), lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.lumaPress)
                    .frame(width: unit)

                    SolidCTA(title: "Apply & Export ›", height: 52) {
                        // Commit the grade as compared: drop the wipe (it is preview
                        // chrome, never baked) and open G1 with the same lookState.
                        releaseHold()
                        app.lookState.splitFraction = nil
                        app.saveGradeSession()
                        app.exportError = nil
                        LumaHaptics.shared.tap()
                        showExportSheet = true
                    }
                    .frame(width: unit * 1.4)
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 20)
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(LumaTheme.bar)
                LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.03)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        }
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
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Text(timeString(progress * duration))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
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
            .tint(LumaTheme.accent)

            Text(timeString(duration))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(LumaTheme.textSecondary)
        }
        .padding(.horizontal, 20)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func attachTimeObserver() {
        guard let player = app.player, let item = player.currentItem else { return }
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
    }

    private func detachTimeObserver() {
        if let timeObserver, let player = app.player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
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

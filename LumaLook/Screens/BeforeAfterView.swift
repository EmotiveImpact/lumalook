import SwiftUI
import AVKit

// =============================================================================
// C2 — PHOTO EDIT (the compare and confirm screen), Night Lab layout.
//
// Original against Edited down the middle, a strip of look codes under it,
// three slim sliders, and a bottom bar of tools: Looks, Adjust, Crop, Mask.
// Save chains straight into the export sheet with the grade applied. The grade
// room's Compare tool and its Apply button both land here (LUMA_ROUTE=
// beforeAfter).
//
// FEATURE INVENTORY — nothing is dropped.
//   ✓ Split view: draggable vertical divider, Original left, Edited right
//   ✓ Original | Edited switch in the top bar (latches the original)
//   ✓ Hold to flip: press and hold the picture to see the original
//   ✓ Side by side: two panes off ONE reference frame, stacked or beside each
//     other according to the source aspect (corner button on the picture)
//   ✓ Look codes strip: every chip is the real grade of the user's frame,
//     the applied look wears the picked ring; All opens the full browser
//   ✓ Strength stays live inside compare (slider, plus the ruler in Looks)
//   ✓ Exposure and warmth, and the colour panels (curves, wheels, HSL, split
//     tone) from ColorGradingViews
//   ✓ Crop (centre crops at fixed ratios) and Mask (blur, mosaic or fill over
//     an ellipse or rectangle) for photos, undoable, saved with the photo
//   ✓ Playback transport for video: play/pause, scrub, elapsed / duration
//   ✓ Save → ExportSpecSheet → single OR batch export → Done
//   ✓ Export progress overlay with cancel, and the batch status caption
//   ✓ Export errors surfaced here rather than dying with the sheet
//   ✓ Empty-state hint when nothing is picked (the hero photo still grades)
//   ✓ Grade-session autosave on the way to export
//   ✓ The divider is preview chrome and is never baked into an export
//   ✓ LUMA_SEED_COMPARE=side and LUMA_SEED_PHOTOTOOL=looks|adjust|crop|mask
// =============================================================================

struct BeforeAfterView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()

    enum CompareMode: String, CaseIterable, Identifiable {
        case split, side
        var id: String { rawValue }
    }

    private static var seededMode: CompareMode {
        ProcessInfo.processInfo.environment["LUMA_SEED_COMPARE"] == "side" ? .side : .split
    }

    @State private var mode: CompareMode = BeforeAfterView.seededMode
    @State private var splitFraction: CGFloat = 0.5
    /// The Original segment: the untouched picture until Edited is tapped.
    @State private var showOriginal = false
    @State private var holdingOriginal = false
    @State private var stashedIntensity: Double?

    // Tools
    @State private var tool: PhotoTool = PhotoTool.seeded
    @State private var showLookBrowser = false
    @State private var proPanel: PhotoProPanel?
    @State private var cropRatio: PhotoCropRatio = .original
    /// The untouched photo, cropped, while a mask is placed on it.
    @State private var maskBase: CIImage?
    @State private var maskDraft: ClipMaskSpec?
    /// The draft as last applied, so Save knows whether one is waiting.
    @State private var maskApplied: ClipMaskSpec?
    @State private var isApplyingEdit = false

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

    private static let panelHeight: CGFloat = 252

    /// Same detents as the grade room's browser: opens at medium so the
    /// picture stays live above it.
    private static let lookBrowserSheetStyle = LumaSheetStyle(
        detents: [.lumaMedium, .lumaLarge, .large],
        defaultDetent: .lumaMedium,
        undimmedUpThrough: .lumaMedium
    )

    // MARK: - Derived

    private var hasRealMedia: Bool {
        app.player != nil || app.selectedImage != nil
    }

    private var isVideo: Bool { app.player != nil }

    /// A photo the user picked: crop and mask work on it.
    private var canEditStill: Bool { app.player == nil && app.selectedImage != nil }

    private var lookName: String {
        app.selectedLUT?.displayName ?? app.selectedLook.name
    }

    private var lookColour: Color {
        app.selectedLUT.map { LookSignature.colour(name: $0.displayName) }
            ?? app.selectedLook.signature
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

    private var thumbStamp: String {
        "\(mediaIdentity)-\(app.library.all.count)"
    }

    /// The still on stage at full size. While a mask is placed it is the
    /// untouched photo, cropped, so the draft is never drawn over an older
    /// mask. nil while a video plays.
    private var stageStill: CIImage? {
        guard app.player == nil else { return nil }
        if tool == .mask, let maskBase { return maskBase }
        return app.selectedImage ?? StillCompare.hero
    }

    /// Width / height of the reference frame, defaulting to 16:9.
    private var sourceAspect: CGFloat {
        let extent = GradeSourceFrame.current(app).extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return 16.0 / 9.0 }
        return extent.width / extent.height
    }

    private var stageAspect: CGFloat {
        PhotoEditMath.aspect(of: stageStill) ?? sourceAspect
    }

    /// Preview pixels per full-size pixel of the stage still.
    private var maskScale: CGFloat {
        guard let extent = stageStill?.extent, !extent.isInfinite else { return 1 }
        let longest = max(extent.width, extent.height)
        guard longest > 1 else { return 1 }
        return min(1, StillCompare.previewMax / longest)
    }

    private var maskPending: Bool {
        tool == .mask && maskDraft != nil && maskDraft != maskApplied
    }

    // MARK: - Body

    var body: some View {
        sheets(lifecycle(screen))
    }

    private var screen: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                stage
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                if isVideo {
                    transport
                        .padding(.top, 10)
                }
                toolPanel
                    .frame(height: Self.panelHeight, alignment: .top)
                    .padding(.top, 14)
                toolBar
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func lifecycle<V: View>(_ content: V) -> some View {
        content
            .task(id: thumbStamp) {
                thumbs.render(source: app.previewFrame,
                              library: app.library.all,
                              fileURL: { app.lutRepository.fileURL(for: $0) },
                              maxDimension: 160)
            }
            .onAppear {
                attachTimeObserver()
                app.exportError = nil
                applyMode(mode)
                if tool == .crop { syncCropRatio() }
                if tool == .mask { beginMask() }
                #if DEBUG
                // Preview cell: LUMA_SEED_LOCK=<built-in look name> puts that
                // look on the grade and opens the lock, as export would.
                if let name = ProcessInfo.processInfo.environment["LUMA_SEED_LOCK"],
                   let look = MockData.looks.first(where: { $0.name == name }) {
                    app.select(look: LibraryLook(builtIn: look))
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        lookLock = app.lockedLookInGrade(storeService)
                        print("[LUMA] LOCK \(name) -> \(lookLock?.pack?.name ?? "no lock")")
                    }
                }
                #endif
            }
            .onChange(of: mode) { _, new in applyMode(new) }
            .onChange(of: splitFraction) { _, _ in syncVideoSplit() }
            .onChange(of: showOriginal) { _, on in originalToggled(on) }
            .onChange(of: tool) { old, new in toolChanged(from: old, to: new) }
            .task(id: "\(gradeStamp)|\(mode.rawValue)") {
                guard mode == .side else { return }
                await renderPanes()
            }
            .onDisappear {
                detachTimeObserver()
                releaseHold()
                holdingOriginal = false
                app.lookState.splitFraction = nil
                app.refreshPreviewFrame()
            }
    }

    private func sheets<V: View>(_ content: V) -> some View {
        content
            // Previewing a premium look is free; exporting it asks once, and a
            // purchase, or the swap to the closest free look, carries straight
            // on into the export sheet.
            .lockedLookSheet($lookLock) {
                openExportSheet()
            } onUseFreeLook: {
                app.useFreeLookInGrade(storeService)
                openExportSheet()
            }
            .lumaToolSheet(isPresented: $showExportSheet, style: .panel) {
                ExportSpecSheet(durationSeconds: app.selectedImage != nil ? 0 : duration,
                                gradeCubeTitle: "LumaLook_\(app.selectedLook.name.components(separatedBy: " ").first ?? "Grade")",
                                lookState: app.lookState) { spec in
                    showExportSheet = false
                    startExport(spec: spec)
                }
            }
            .lumaToolSheet(isPresented: $showLookBrowser, style: Self.lookBrowserSheetStyle) {
                LookBrowserSheet(context: .grade, intensity: $app.settings.intensity)
            }
            .lumaToolSheet(isPresented: proPanelShown, style: .panel) {
                proPanelSheet
            }
            // Export failures/refusals surface here rather than dying with the
            // sheet, over the tools and never over the picture.
            .overlay(alignment: .bottom) { exportErrorToast }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.exportError != nil)
            .overlay { exportingOverlay }
    }

    @ViewBuilder
    private var exportingOverlay: some View {
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
                    .strokeBorder(LumaTheme.edge, lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { app.exportError = nil }
                }
        }
    }

    // MARK: - Modes

    /// Each mode owns exactly one pipeline state, so switching can never leave
    /// a stale wipe or a stashed strength behind.
    private func applyMode(_ new: CompareMode) {
        releaseHold()
        syncVideoSplit()
    }

    /// A still draws its own divider. Video has no ungraded twin, so the
    /// engine composites the wipe from `splitFraction`.
    private func syncVideoSplit() {
        guard isVideo else {
            app.lookState.splitFraction = nil
            return
        }
        let on = mode == .split && !showOriginal && tool != .crop && tool != .mask
        app.lookState.splitFraction = on ? Double(splitFraction) : nil
        app.refreshPreviewFrame()
        app.objectWillChange.send()
    }

    private func originalToggled(_ on: Bool) {
        if isVideo {
            if on { takeHold() } else { releaseHold() }
        }
        syncVideoSplit()
    }

    /// Hold to flip. A still swaps to its original layer; a video drops the
    /// look's strength to 0 until release.
    private func setHold(_ pressing: Bool) {
        guard !showOriginal else { return }
        if isVideo {
            if pressing { takeHold() } else { releaseHold() }
        } else {
            holdingOriginal = pressing
        }
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

    private func toolChanged(from old: PhotoTool, to new: PhotoTool) {
        if new == .mask {
            beginMask()
        } else if old == .mask {
            maskBase = nil
            maskDraft = nil
            maskApplied = nil
        }
        if new == .crop { syncCropRatio() }
        syncVideoSplit()
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LumaTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Back to looks")
                Spacer(minLength: 0)
                saveButton
            }
            compareSwitch
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }

    private var compareSwitch: some View {
        HStack(spacing: 2) {
            compareSegment("Original", on: showOriginal) { showOriginal = true }
            compareSegment("Edited", on: !showOriginal) { showOriginal = false }
        }
        .padding(2)
        .background(LumaTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(LumaTheme.edge, lineWidth: 1))
    }

    private func compareSegment(_ title: String, on: Bool,
                                action: @escaping () -> Void) -> some View {
        Button {
            guard !on else { return }
            LumaHaptics.shared.tap()
            withAnimation(.easeOut(duration: 0.15)) { action() }
        } label: {
            Text(title)
                .font(.luma(size: 13, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? LumaTheme.textPrimary : LumaTheme.textMuted)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(on ? LumaTheme.control : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(on ? Color.white.opacity(0.12) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The one filled button on the screen.
    private var saveButton: some View {
        Button { save() } label: {
            Text(isVideo ? "Export" : "Save")
                .font(.luma(size: 14, weight: .semibold))
                .foregroundStyle(LumaTheme.onLight)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(LumaTheme.textPrimary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(isApplyingEdit)
        .opacity(isApplyingEdit ? 0.5 : 1)
        .accessibilityLabel(isVideo ? "Export with this look" : "Save with this look")
    }

    // MARK: - Stage

    @ViewBuilder
    private var stage: some View {
        Group {
            if mode == .side {
                sideStage
            } else {
                PhotoSplitStage(aspect: stageAspect,
                                still: stageStill,
                                split: $splitFraction,
                                originalOnly: showOriginal || (holdingOriginal && !isVideo),
                                fullFrame: tool == .crop || tool == .mask,
                                mask: tool == .mask ? maskDraft : nil,
                                maskScale: maskScale,
                                code: LookCode.short(lookName),
                                signature: lookColour,
                                onHold: { pressing in setHold(pressing) },
                                onMaskMove: { point in maskDraft?.center = point })
                    .overlay(alignment: .bottomTrailing) { sideToggle }
                    .overlay(alignment: .bottomLeading) { sampleHint }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.impact(weight: .light), trigger: holdingOriginal)
        .animation(.easeInOut(duration: 0.25), value: stageAspect)
    }

    /// Side by side lives on the picture's corner, out of the way.
    private var sideToggle: some View {
        Button {
            LumaHaptics.shared.tap()
            withAnimation(.snappy(duration: 0.22)) { mode = mode == .side ? .split : .side }
        } label: {
            Image(systemName: mode == .side ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.lumaPress)
        .padding(10)
        .accessibilityLabel(mode == .side ? "Back to the split view" : "Side by side")
    }

    @ViewBuilder
    private var sampleHint: some View {
        if !hasRealMedia {
            Text("Sample photo. Pick one to edit your own.")
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .lumaGlassPill()
                .padding(10)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Side by side

    /// Two panes off ONE reference frame: video pauses so both halves describe
    /// the same moment. A landscape pair stacks, so each pane gets the full
    /// width; portrait sources take the mirror rule.
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
        .overlay(alignment: .bottomTrailing) { sideToggle }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var originalPaneView: some View {
        pane(originalPane) {
            Text("Original")
                .font(.luma(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var gradedPaneView: some View {
        pane(gradedPane) {
            HStack(spacing: 6) {
                Text(LookCode.short(lookName))
                    .font(.luma(size: 12, weight: .semibold))
                    .foregroundStyle(lookColour)
                Text("\(Int(app.settings.intensity.rounded()))%")
                    .font(.luma(size: 11, weight: .medium))
                    .monospacedDigit()
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            label()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    /// Renders both panes from the reference frame. `previewFrame` is already
    /// bounded to 480px; nothing here is clamped-to-extent, so the spatial ops
    /// in the pipeline stay honest.
    private func renderPanes() async {
        app.player?.pause()
        isPlaying = false
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

    // MARK: - Tool panels

    @ViewBuilder
    private var toolPanel: some View {
        switch tool {
        case .looks:  looksPanel
        case .adjust: adjustPanel
        case .crop:   cropPanel
        case .mask:   maskPanel
        }
    }

    private var looksPanel: some View {
        VStack(spacing: 12) {
            codeStrip
            GradeOpacityRow(value: $app.settings.intensity)
                .padding(.horizontal, 18)
            Button {
                showLookBrowser = true
                LumaHaptics.shared.tap()
            } label: {
                panelButtonLabel("All looks", icon: "square.grid.2x2")
            }
            .buttonStyle(.lumaPress)
            .padding(.horizontal, 16)
        }
    }

    private var adjustPanel: some View {
        VStack(spacing: 12) {
            codeStrip
            VStack(spacing: 10) {
                SlimSlider(title: "Strength", value: $app.settings.intensity,
                           range: 0...100, bipolar: false,
                           format: { "\(Int($0.rounded()))%" })
                SlimSlider(title: "Exposure", value: $app.settings.exposure,
                           format: { PhotoEditMath.exposureLabel($0) })
                SlimSlider(title: "Warmth", value: $app.settings.warmth)
            }
            .padding(.horizontal, 16)
            proToolsRow
        }
    }

    private var proToolsRow: some View {
        HStack(spacing: 8) {
            ForEach(PhotoProPanel.allCases) { panel in
                Button {
                    proPanel = panel
                    LumaHaptics.shared.tap()
                } label: {
                    Text(panel.title)
                        .font(.luma(size: 12, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(LumaTheme.raised, in: Capsule())
                        .overlay(Capsule().strokeBorder(LumaTheme.edge, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.lumaPress)
            }
        }
        .padding(.horizontal, 16)
    }

    private func panelButtonLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.luma(size: 14, weight: .semibold))
        }
        .foregroundStyle(LumaTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(LumaTheme.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(LumaTheme.edge, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func panelNote(_ text: String) -> some View {
        Text(text)
            .font(.luma(size: 13, weight: .medium))
            .foregroundStyle(LumaTheme.textMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 40)
    }

    // MARK: - Code strip

    private var stripLooks: [LibraryLook] {
        app.library.stripLooks(limit: 30)
    }

    private var codeStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(stripLooks) { look in
                        codeTile(look).id(look.id)
                    }
                    allLooksChip
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
            .lumaEdgeFade(leading: 12, trailing: 12)
            .sensoryFeedback(.selection, trigger: app.selectedLook.id)
            .onAppear {
                guard let id = stripLooks.first(where: { app.isCurrent($0) })?.id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(height: 72)
    }

    private func codeTile(_ look: LibraryLook) -> some View {
        let selected = app.isCurrent(look)
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                app.select(look: look)
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 5) {
                Color.clear
                    .frame(width: 48, height: 48)
                    .overlay { codeThumb(look) }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .pickedRing(selected, cornerRadius: 9)
                    .overlay(alignment: .topTrailing) {
                        if storeService.isLocked(look) { LookLockGlyph(compact: true) }
                    }
                Text(LookCode.short(look))
                    .font(.luma(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? LumaTheme.textPrimary : LumaTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 52)
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel(look.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func codeThumb(_ look: LibraryLook) -> some View {
        if let cg = thumbs.images[look.thumbKey] {
            Image(decorative: cg, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LumaTheme.raised
        }
    }

    private var allLooksChip: some View {
        Button {
            showLookBrowser = true
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LumaTheme.raised)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(LumaTheme.textSecondary)
                    }
                Text("All")
                    .font(.luma(size: 11, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(width: 52)
            }
        }
        .buttonStyle(.lumaPress)
        .accessibilityLabel("All looks")
    }

    // MARK: - Colour panels

    private var proPanelShown: Binding<Bool> {
        Binding(get: { proPanel != nil },
                set: { if !$0 { proPanel = nil } })
    }

    @ViewBuilder
    private var proPanelSheet: some View {
        if let panel = proPanel {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(panel.title)
                        .font(.luma(size: 17, weight: .semibold))
                        .foregroundStyle(LumaTheme.textPrimary)
                    proPanelBody(panel)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private func proPanelBody(_ panel: PhotoProPanel) -> some View {
        switch panel {
        case .curves: CurveEditorPanel(curves: $app.settings.curves)
        case .wheels: ColorWheelsPanel(wheels: $app.settings.wheels)
        case .hsl:    HSLPanel(hsl: $app.settings.hsl)
        case .split:  SplitTonePanel(tone: $app.settings.splitTone)
        }
    }

    // MARK: - Crop

    @ViewBuilder
    private var cropPanel: some View {
        if canEditStill {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PhotoCropRatio.allCases) { ratio in
                            cropChip(ratio)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 1)
                }
                .lumaEdgeFade(leading: 16, trailing: 16)
                Text("Crops from the centre. Original puts the whole photo back.")
                    .font(.luma(size: 12, weight: .medium))
                    .foregroundStyle(LumaTheme.textMuted)
                    .padding(.horizontal, 18)
            }
        } else {
            panelNote(isVideo
                      ? "Crop works on photos. Open a clip in the editor to reframe it."
                      : "Pick a photo to crop it.")
        }
    }

    private func cropChip(_ ratio: PhotoCropRatio) -> some View {
        let on = cropRatio == ratio
        return Button { pickCrop(ratio) } label: {
            VStack(spacing: 7) {
                ratioGlyph(ratio, on: on)
                    .frame(width: 26, height: 26)
                Text(ratio.label)
                    .font(.luma(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? LumaTheme.textPrimary : LumaTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 64, height: 66)
            .background(on ? LumaTheme.control : LumaTheme.raised,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? Color.white.opacity(0.3) : LumaTheme.edge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(isApplyingEdit)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func ratioGlyph(_ ratio: PhotoCropRatio, on: Bool) -> some View {
        let r = ratio.ratio ?? (PhotoEditMath.aspect(of: PhotoEditSession.shared.pristine) ?? stageAspect)
        let w: CGFloat = r >= 1 ? 24 : 24 * r
        let h: CGFloat = r >= 1 ? 24 / r : 24
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(on ? LumaTheme.textPrimary : LumaTheme.textMuted, lineWidth: 1.5)
            .frame(width: max(w, 6), height: max(h, 6))
    }

    private func syncCropRatio() {
        guard let current = app.selectedImage else {
            cropRatio = .original
            return
        }
        PhotoEditSession.shared.adopt(current)
        cropRatio = PhotoEditSession.shared.ratio
    }

    private func pickCrop(_ ratio: PhotoCropRatio) {
        guard canEditStill, !isApplyingEdit, ratio != cropRatio else { return }
        cropRatio = ratio
        applyPhotoEdit(ratio: ratio, mask: PhotoEditSession.shared.mask)
        LumaHaptics.shared.tap()
    }

    // MARK: - Mask

    private var maskAspect: CGFloat {
        PhotoEditMath.aspect(of: maskBase) ?? stageAspect
    }

    @ViewBuilder
    private var maskPanel: some View {
        if canEditStill, maskDraft == nil {
            VStack(spacing: 14) {
                panelNote("Blur, pixelate or fill part of the photo.")
                Button { addMask() } label: {
                    panelButtonLabel("Add a mask", icon: "plus")
                }
                .buttonStyle(.lumaPress)
                .padding(.horizontal, 16)
            }
        } else if canEditStill {
            VStack(spacing: 12) {
                maskChoices
                VStack(spacing: 10) {
                    SlimSlider(title: "Size", value: maskSizeBinding,
                               range: 5...100, bipolar: false,
                               format: { "\(Int($0.rounded()))%" })
                    SlimSlider(title: "Strength", value: maskAmountBinding,
                               range: 0...100, bipolar: false,
                               format: { "\(Int($0.rounded()))%" })
                }
                .padding(.horizontal, 16)
                maskActions
            }
        } else {
            panelNote(isVideo
                      ? "Mask works on photos. Open a clip in the editor for spot masks."
                      : "Pick a photo to mask part of it.")
        }
    }

    private var maskChoices: some View {
        HStack(spacing: 6) {
            ForEach(ClipMaskShape.allCases, id: \.self) { shape in
                choiceChip(shape.label, on: maskDraft?.shape == shape) {
                    maskDraft?.shape = shape
                }
            }
            Rectangle()
                .fill(LumaTheme.hairline)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 2)
            ForEach(ClipMaskEffect.allCases, id: \.self) { effect in
                choiceChip(effect.label, on: maskDraft?.effect == effect) {
                    maskDraft?.effect = effect
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func choiceChip(_ title: String, on: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            action()
            LumaHaptics.shared.tap()
        } label: {
            Text(title)
                .font(.luma(size: 12, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? LumaTheme.onLight : LumaTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(on ? AnyShapeStyle(LumaTheme.textPrimary) : AnyShapeStyle(LumaTheme.raised),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
    }

    private var maskActions: some View {
        HStack(spacing: 10) {
            Text("Drag on the photo to place it")
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button { removeMask() } label: {
                Text("Remove")
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .disabled(isApplyingEdit)
            Button { applyMask() } label: {
                Text("Apply")
                    .font(.luma(size: 13, weight: .semibold))
                    .foregroundStyle(LumaTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(LumaTheme.control, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LumaTheme.edge, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.lumaPress)
            .disabled(isApplyingEdit || !maskPending)
            .opacity(maskPending ? 1 : 0.4)
        }
        .padding(.horizontal, 16)
    }

    private var maskSizeBinding: Binding<Double> {
        Binding(
            get: { Double((maskDraft?.size.width ?? 0.4) * 100) },
            set: { newValue in
                guard var spec = maskDraft else { return }
                let width = CGFloat(newValue / 100)
                spec.size = CGSize(width: width, height: min(1, width * maskAspect))
                maskDraft = spec
            })
    }

    private var maskAmountBinding: Binding<Double> {
        Binding(
            get: { (maskDraft?.amount ?? 0.6) * 100 },
            set: { newValue in maskDraft?.amount = min(max(newValue / 100, 0), 1) })
    }

    /// Mask placement starts from the untouched photo, cropped as it stands,
    /// with the applied mask (if any) as the draft. What the stage shows is
    /// what Save keeps: a new draft is drawn live and counts as waiting.
    private func beginMask() {
        guard canEditStill, let current = app.selectedImage else { return }
        let session = PhotoEditSession.shared
        session.adopt(current)
        guard let base = session.croppedBase else { return }
        maskBase = base
        maskApplied = session.mask
        maskDraft = session.mask ?? PhotoEditMath.defaultMask(aspect: PhotoEditMath.aspect(of: base) ?? 1)
    }

    private func addMask() {
        maskDraft = PhotoEditMath.defaultMask(aspect: maskAspect)
        LumaHaptics.shared.tap()
    }

    private func applyMask() {
        guard let draft = maskDraft else { return }
        maskApplied = draft
        applyPhotoEdit(ratio: PhotoEditSession.shared.ratio, mask: draft)
        LumaHaptics.shared.tap()
    }

    /// Drops the draft, and the applied mask if there is one.
    private func removeMask() {
        if PhotoEditSession.shared.mask != nil {
            applyPhotoEdit(ratio: PhotoEditSession.shared.ratio, mask: nil)
        }
        maskDraft = nil
        maskApplied = nil
        LumaHaptics.shared.tap()
    }

    /// Crop and mask always start from the untouched photo, so changing one
    /// never compounds the other. A mask is rendered once, off the main
    /// thread, so the preview stays quick afterwards.
    private func applyPhotoEdit(ratio: PhotoCropRatio, mask: ClipMaskSpec?,
                                then: (() -> Void)? = nil) {
        guard let current = app.selectedImage else { return }
        let session = PhotoEditSession.shared
        session.adopt(current)
        guard let edited = session.edit(ratio: ratio, mask: mask) else { return }
        guard mask != nil else {
            session.commit(edited)
            app.replaceSelectedStill(with: edited)
            then?()
            return
        }
        isApplyingEdit = true
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                PhotoEditMath.materialise(edited)
            }.value
            let solid = rendered.map { CIImage(cgImage: $0) } ?? edited
            session.commit(solid)
            app.replaceSelectedStill(with: solid)
            isApplyingEdit = false
            then?()
        }
    }

    // MARK: - Tool bar

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(PhotoTool.allCases) { item in
                toolButton(item)
            }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(LumaTheme.hairline).frame(height: 1)
        }
    }

    private func toolButton(_ item: PhotoTool) -> some View {
        let on = tool == item
        return Button {
            guard !on else { return }
            LumaHaptics.shared.tap()
            withAnimation(.easeOut(duration: 0.18)) { tool = item }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 22)
                Text(item.title)
                    .font(.luma(size: 11, weight: .medium))
            }
            .foregroundStyle(on ? LumaTheme.textPrimary : LumaTheme.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Save

    private func save() {
        LumaHaptics.shared.tap()
        guard hasRealMedia else {
            app.path = [.selectClip]
            return
        }
        if let lock = app.lockedLookInGrade(storeService) {
            lookLock = lock
            return
        }
        // A mask placed but not applied goes into the save.
        if maskPending, let draft = maskDraft {
            maskApplied = draft
            applyPhotoEdit(ratio: PhotoEditSession.shared.ratio, mask: draft) {
                openExportSheet()
            }
            return
        }
        openExportSheet()
    }

    /// Commit the grade as compared: drop the wipe (it is preview chrome,
    /// never baked) and open the export sheet with the same lookState.
    private func openExportSheet() {
        releaseHold()
        holdingOriginal = false
        if showOriginal { showOriginal = false }
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
                .font(.luma(size: 12, weight: .medium))
                .monospacedDigit()
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
                .font(.luma(size: 12, weight: .medium))
                .monospacedDigit()
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

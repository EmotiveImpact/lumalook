import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

// =============================================================================
// EditorTimelineView — the SHIPPING video editor, in the approved design
// language (promoted from the retired Design Lab editor after a line-by-line
// parity pass).
//
// THE LANGUAGE
//   1. The image is the interface. The preview is never covered; opening a tool
//      COMPRESSES it and leaves a scrubbable mini timeline underneath.
//   2. Monochrome chrome. The only colour on screen is CONTENT colour the user
//      chose (text swatches, chroma key, border colour).
//   3. A stroke means selection and nothing else. Everything else separates by
//      surface value.
//   4. The tile IS the preview: look tiles are the real grade, clip cells are
//      real filmstrip frames, a speed ramp plots its actual curve.
//   5. Mono type is for NUMBERS ONLY. Every other label is the system font,
//      sentence case, 11–17pt medium/semibold at 0.55–1.0 white.
//   6. Prefer a live value over a glyph — Speed reads "1×", Volume "100%".
//   7. Each tool ends in one calm centred sentence with ✕ and ✓ at the edges.
//
// CARRIED ACROSS FROM THE PREVIOUS SHIPPING EDITOR (the preview did not have
// these, and losing them was not an option):
//   · Export spec sheet + exporter progress + GIF + save-to-Photos
//   · Long-press-drag clip REORDER and the centre-fixed playhead scroller
//     (TimelineScroller, restyled monochrome — not replaced)
//   · Clip / overlay / music context menus
//   · Sound-library audition playback
//   · The full LookBrowserSheet ("All looks")
//   · Whole-library adjustment layers, grouped by section
//   · The audio-focus card over the preview while an audio tool is open
//   · The tap-to-play fullscreen preview with its own scrub bar
//   · Every LUMA_SEED_* debug hook the verification harness drives
// =============================================================================

// MARK: - Monochrome atoms

/// Icon-over-label, unboxed. The whole tool-row grammar.
private struct LDToolItem: View {
    let title: String
    let icon: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .frame(height: 21)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    // Floor at ~10 pt; every current label fits 64 pt at 11.
                    .minimumScaleFactor(0.9)
                    .foregroundStyle(.white.opacity(active ? 0.7 : 0.5))
            }
            .foregroundStyle(active ? Color.white : .white.opacity(0.62))
            .frame(width: 64, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
    }
}

/// The instrument twin of LDToolItem: a live VALUE in mono over its name in
/// sentence case. Used wherever the control's whole job is to carry a number.
private struct LDValueTool: View {
    let value: String
    let label: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(active ? .white : .white.opacity(0.82))
                    .lineLimit(1)
                    // Floor at ~13 pt so a long value still reads.
                    .minimumScaleFactor(0.85)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(active ? 0.7 : 0.45))
                    .lineLimit(1)
            }
            .frame(width: 64, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
    }
}

/// A pill. Selection is a ring; unselected is a value step. No accent.
private struct LDChip: View {
    let title: String
    var selected = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : LumaTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(LumaTheme.surface, in: Capsule())
                .overlay {
                    if selected { Capsule().strokeBorder(Color.white, lineWidth: 1.2) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.32)
        .disabled(!enabled)
    }
}

/// A wide action row inside a panel — the "do it" affordances that are not
/// selections (Detect beats, Normalize, Remove…).
private struct LDAction: View {
    let title: String
    let icon: String
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if busy {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .light))
                }
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .opacity(enabled ? 1 : 0.32)
        .disabled(!enabled || busy)
    }
}

/// A menu wearing LDAction's clothes, for "pick one of many" actions that are
/// too numerous for chips (the whole look library as adjustment layers).
private struct LDActionMenu<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13, weight: .light))
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Mono microtype on every number, per the pro-cinema signature.
private struct LDSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var readout: (Double) -> String = { String(format: "%.2f", $0) }
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 4)
                Text(readout(value))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
            }
            GeometryReader { geo in
                let span = range.upperBound - range.lowerBound
                let frac = span > 0 ? (value - range.lowerBound) / span : 0
                let w = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(LumaTheme.surfaceStrong).frame(height: 3)
                    Capsule().fill(Color.white.opacity(0.7))
                        .frame(width: max(0, w * frac), height: 3)
                    Circle().fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(0, w * frac - 6), w - 12))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = min(max(0, g.location.x / w), 1)
                            value = range.lowerBound + f * span
                        }
                        .onEnded { _ in onCommit() }
                )
            }
            .frame(height: 24)
        }
    }
}

/// A slider for a setter that is EXPENSIVE — one that pushes an undo snapshot
/// and schedules a composition rebuild per call. Tracks locally while the
/// finger is down and commits exactly once on release, so a single drag is one
/// undo step and one rebuild instead of ~200 of each.
private struct LDCommitSlider: View {
    let label: String
    let initial: Double
    var range: ClosedRange<Double> = 0...1
    var readout: (Double) -> String = { String(format: "%.2f", $0) }
    let commit: (Double) -> Void

    @State private var draft: Double?

    var body: some View {
        LDSlider(label: label,
                 value: Binding(get: { draft ?? initial }, set: { draft = $0 }),
                 range: range,
                 readout: readout,
                 onCommit: {
                     if let d = draft { commit(d) }
                     draft = nil
                 })
    }
}

/// Section heading. System font, sentence case, real contrast. Numbers that
/// belong to a heading ("3 pinned", "12.4s") ride along in `value`, in mono.
private struct LDCaption: View {
    let text: String
    var value: String?

    init(_ text: String, value: String? = nil) {
        self.text = text
        self.value = value
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Explanatory sentence inside a panel. Never uppercase, never tracked.
private struct LDNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Unit-square drag pad for the spot mask, whose centre lives on a clip rather
/// than on screen. Overlays, text, stickers and shapes are NOT positioned here
/// any more — they are dragged on the picture itself.
private struct LDPositionPad: View {
    let point: CGPoint
    /// Release-only setter — the mask setter snapshots undo and rebuilds, so it
    /// must not run per tick. The knob still tracks the finger via the draft.
    var onCommit: ((CGPoint) -> Void)?

    @State private var draft: CGPoint?

    private var shown: CGPoint { draft ?? point }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LumaTheme.surface)
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                Circle().fill(Color.white).frame(width: 11, height: 11)
                    .position(x: shown.x * w, y: shown.y * h)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        draft = CGPoint(x: min(max(0, g.location.x / w), 1),
                                        y: min(max(0, g.location.y / h), 1))
                    }
                    .onEnded { _ in
                        if let d = draft { onCommit?(d) }
                        draft = nil
                    }
            )
        }
        .frame(height: 92)
    }
}

/// The one calm sentence a tool ends in. ✕ and ✓ at the edges, nothing shouted.
private struct LDInstructionBar: View {
    let sentence: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            Text(sentence)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Button(action: onConfirm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
    }
}

/// Monochrome RMS bars.
private struct LDWaveform: View {
    let samples: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int(geo.size.width / 2.5))
            Path { p in
                for i in 0..<count {
                    let x = CGFloat(i) * 2.5
                    let v: CGFloat = {
                        guard !samples.isEmpty else { return 0.08 }
                        let idx = min(samples.count - 1, Int(Double(i) / Double(count) * Double(samples.count)))
                        return CGFloat(max(0.05, min(1, samples[idx])))
                    }()
                    let h = v * geo.size.height
                    p.move(to: CGPoint(x: x, y: geo.size.height / 2 - h / 2))
                    p.addLine(to: CGPoint(x: x, y: geo.size.height / 2 + h / 2))
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1.2)
        }
    }
}

// MARK: - Formatting

private enum LDFormat {
    static func secs(_ s: Double) -> String { String(format: "%.1fs", max(0, s)) }

    static func clock(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }

    /// "24 fps", "29.97 fps": the rate the frame counter is counting in.
    static func rate(_ r: Double) -> String {
        abs(r - r.rounded()) < 0.01 ? "\(Int(r.rounded())) fps" : String(format: "%.2f fps", r)
    }

    /// MM:SS:FF at the project's own rate: frame numbers run 0…23 for 24 fps
    /// footage and 0…59 for 60, not 0…29 for everything. The tiny epsilon
    /// stops 0.9999… of a frame flooring to the previous one.
    static func timecode(_ s: Double, frameDuration: Double) -> String {
        let t = max(0, s)
        let perSecond = frameDuration > 0 ? max(1, Int((1 / frameDuration).rounded())) : 30
        let f = frameDuration > 0
            ? min(perSecond - 1, Int((t - floor(t)) / frameDuration + 1e-6))
            : 0
        return String(format: "%02d:%02d:%02d", Int(t) / 60, Int(t) % 60, f)
    }
}

// MARK: - Tools

private enum EditorTool: Hashable {
    case none
    // project-level
    case looks, sticker, shape, effects, particles, adjLayer, template
    case canvas, captions, audioReactive, audioAdd, voice
    // clip-level
    case trim, speed, clipLook, motion, mask, transition, clipAudio, geometry
    // element-level
    case overlay, music
}

// MARK: - Screen (route `.editor`)

struct EditorTimelineView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss

    // Which tool owns the drawer. One value replaces the old parallel
    // show*Panel booleans, so two tools can never be open at once.
    @State private var tool: EditorTool = .none

    @State private var selectedOverlayID: UUID?
    @State private var selectedAudioID: UUID?
    @State private var transitionAfterID: UUID?

    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    /// In/out points as they were when the Trim tool opened, so ✕ can put them
    /// back (the sliders commit live, and undo is a coarser instrument).
    @State private var trimOriginal: (start: Double, end: Double)?

    @State private var timelineZoom: CGFloat = 50
    @AppStorage("timelineMagnet") private var magnetOn = true
    @State private var showFrames = true

    // Media entry
    @State private var addPickerItem: PhotosPickerItem?
    @State private var showAddPicker = false
    @State private var overlayPickerItem: PhotosPickerItem?
    @State private var showOverlayPicker = false
    @State private var replacePickerItem: PhotosPickerItem?
    @State private var showReplacePicker = false
    @State private var showMusicImporter = false
    @State private var isLoadingClip = false

    // Full-screen / sheets kept from the shipping editor
    @State private var showCropPanel = false
    @State private var showFullscreenPreview = false
    @State private var showLookBrowser = false
    @State private var looksTargetClipID: UUID?

    // Export
    @State private var showExportSheet = false
    @State private var isExporting = false
    @State private var exportError: String?
    /// A premium look somewhere in the project that is not unlocked yet.
    @State private var lookLock: LookLock?

    @State private var isCaptioning = false
    /// Strength parked by the whole-edit "None" tile so the next look restores it.
    @State private var stashedIntensity: Double?

    #if DEBUG
    @State private var debugFXTrackID: UUID?   // opens AudioEffectsPanel for verification
    #endif

    private var editor: EditorState { app.editor }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EditorContent(
                editor: editor,
                tool: $tool,
                selectedOverlayID: $selectedOverlayID,
                selectedAudioID: $selectedAudioID,
                transitionAfterID: $transitionAfterID,
                trimStart: $trimStart,
                trimEnd: $trimEnd,
                trimOriginal: $trimOriginal,
                timelineZoom: $timelineZoom,
                magnetOn: $magnetOn,
                showFrames: $showFrames,
                looksTargetClipID: $looksTargetClipID,
                stashedIntensity: $stashedIntensity,
                isCaptioning: $isCaptioning,
                isLoadingClip: isLoadingClip,
                exportError: exportError,
                onBack: { dismiss() },
                onAddClip: { showAddPicker = true },
                onAddOverlayMedia: {
                    // An overlay/music track added before any clip exists is
                    // silently discarded: `addOverlay` guards on totalDuration
                    // and `buildComposition` refuses to build without clips.
                    // Say so instead of taking the media and losing it.
                    if editor.isEmpty { app.importToast = "Add a video clip first" }
                    else { showOverlayPicker = true }
                },
                onReplaceMedia: { showReplacePicker = true },
                onImportAudioFile: { showMusicImporter = true },
                onOpenCropSheet: { showCropPanel = true },
                onOpenLookBrowser: { showLookBrowser = true },
                onFullscreen: { showFullscreenPreview = true },
                onExport: {
                    if let lock = app.lockedLookInProject(storeService) {
                        lookLock = lock
                    } else {
                        showExportSheet = true
                    }
                },
                onRecordFootage: { app.path.append(.camera) },
                onOpenProjects: { app.path.append(.projectLibrary) },
                onOpenAdjust: { app.path.append(.customLook) },
                onOpenCropScreen: { app.path.append(.cropFormat) },
                onOpenMixer: { app.path.append(.audio) }
            )
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        #if DEBUG
        .sheet(item: $debugFXTrackID) { id in
            AudioEffectsPanel(editor: editor, trackID: id) { debugFXTrackID = nil }
                .presentationDetents([.height(560), .large])
        }
        #endif
        // Mixed pickers (T7): picking an image adds a photo clip to the MAIN
        // track; the Overlay picker layers it as PIP instead.
        .photosPicker(isPresented: $showAddPicker, selection: $addPickerItem,
                      matching: .any(of: [.images, .videos]))
        .photosPicker(isPresented: $showOverlayPicker, selection: $overlayPickerItem,
                      matching: .any(of: [.images, .videos]))
        .photosPicker(isPresented: $showReplacePicker, selection: $replacePickerItem,
                      matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showMusicImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            handleMusicImport(result)
        }
        .onChange(of: addPickerItem) { _, newItem in
            guard let newItem else { return }
            isLoadingClip = true
            Task {
                defer { isLoadingClip = false }
                if let video = try? await newItem.loadTransferable(type: PickedVideo.self) {
                    await editor.addClip(from: video.url)
                    // Select the new clip so its tools appear right away.
                    editor.selectedClipID = editor.clips.last?.id
                } else if let imageURL = await Self.pickedImageFile(from: newItem) {
                    await editor.addPhotoClip(from: imageURL)
                }
                addPickerItem = nil
            }
        }
        .onChange(of: overlayPickerItem) { _, newItem in
            guard let newItem else { return }
            isLoadingClip = true
            Task {
                defer { isLoadingClip = false }
                let before = Set(editor.overlays.map(\.id))
                if let video = try? await newItem.loadTransferable(type: PickedVideo.self) {
                    // ✕ on the Overlay panel this opens removes the new media.
                    editor.prepareToolSessionForAdd()
                    await editor.addOverlay(from: video.url, isImage: false)
                } else if let imageURL = await Self.pickedImageFile(from: newItem) {
                    editor.prepareToolSessionForAdd()
                    await editor.addOverlay(from: imageURL, isImage: true)
                }
                // Open the panel on the freshly added overlay (the array is
                // offset-sorted, so "last" isn't necessarily the new one).
                if let added = editor.overlays.first(where: { !before.contains($0.id) }) {
                    selectedOverlayID = added.id
                    tool = .overlay
                }
                overlayPickerItem = nil
            }
        }
        .onChange(of: replacePickerItem) { _, newItem in
            guard let newItem, let targetID = editor.selectedClipID else {
                replacePickerItem = nil
                return
            }
            isLoadingClip = true
            Task {
                defer { isLoadingClip = false }
                if let video = try? await newItem.loadTransferable(type: PickedVideo.self) {
                    await editor.replaceClip(id: targetID, with: video.url)
                } else if let imageURL = await Self.pickedImageFile(from: newItem) {
                    await editor.replaceClip(id: targetID, with: imageURL)
                }
                replacePickerItem = nil
            }
        }
        .onAppear {
            // Continuity: seed the timeline with the Apply-a-Look clip.
            if editor.isEmpty, let url = app.selectedVideoURL {
                Task { await editor.addClip(from: url) }
            } else if editor.isEmpty,
                      ProcessInfo.processInfo.environment["LUMA_SEED_CLIP"] == nil,
                      let last = app.store.projects.max(by: { $0.updatedAt < $1.updatedAt }) {
                // Resume: cold-opening the editor picks up your last project
                // instead of a fresh empty one. The title menu's New Project
                // stays one tap for a clean slate.
                editor.load(project: last)
                app.importToast = "Resumed \u{201C}\(last.title)\u{201D}"
            }
            applyDebugSeed()
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUMA_SEED_CROPUI"] == "1" {
                Task {
                    for _ in 0..<40 where editor.clips.isEmpty || editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    editor.selectedClipID = editor.clips.first?.id
                    showCropPanel = true
                }
            }
            #endif
        }
        .onDisappear {
            // A take left running keeps the microphone hot and the 30 Hz meter
            // task alive after the editor is gone, with no visible stop control
            // anywhere in the app. `EditorState` is owned by AppModel and
            // outlives this view (AppModel.swift), so nothing else would ever
            // stop it. Committing rather than discarding: the user recorded
            // audio, and silently binning it would be the worse failure.
            if editor.isRecordingVoiceover { editor.stopVoiceover() }
            editor.saveProject()
        }
        .lockedLookSheet($lookLock) {
            // One purchase may not cover every locked look in the project
            // (two packs); check again rather than assume.
            if let next = app.lockedLookInProject(storeService) {
                lookLock = next
            } else {
                showExportSheet = true
            }
        }
        .lumaToolSheet(isPresented: $showExportSheet, style: .panel) {
            ExportSpecSheet(durationSeconds: editor.totalDuration,
                            gradeCubeTitle: nil,
                            lookState: nil) { spec in
                showExportSheet = false
                startExport(spec: spec)
            }
        }
        .overlay {
            if isExporting {
                ExportOverlay(progress: app.exporter.progress) { app.exporter.cancel() }
            }
        }
        // The footage owns the whole display; one tap minimises back in.
        .fullScreenCover(isPresented: $showFullscreenPreview) {
            FullscreenPreview(editor: editor)
        }
        .sheet(isPresented: $showCropPanel) {
            if let clip = editor.selectedClip {
                CropStraightenView(
                    thumbnail: clip.thumbnail,
                    aspect: CGFloat(editor.format.aspect),
                    initialCrop: clip.cropRect,
                    initialStraighten: clip.straightenDegrees,
                    onApply: { rect, deg in
                        editor.setCropStraighten(id: clip.id, cropRect: rect, straightenDegrees: deg)
                        showCropPanel = false
                    },
                    onCancel: { showCropPanel = false })
                    .presentationDetents([.large])
                    .presentationBackground(Color.black)
            }
        }
        // The FULL look library — chips, search, import — one tap from the
        // strip, exactly as the previous editor offered it.
        .sheet(isPresented: $showLookBrowser) {
            LookBrowserSheet(context: looksTargetClipID.map { .editorClip($0) } ?? .editorTimeline)
        }
    }

    /// Writes a picked photo to a temp file so the engine can import it into
    /// the durable clip library (photo clips + image overlays need a URL).
    private static func pickedImageFile(from item: PhotosPickerItem) async -> URL? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              !data.isEmpty else { return nil }
        let ext = item.supportedContentTypes
            .first(where: { $0.conforms(to: .image) })?
            .preferredFilenameExtension ?? "jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaLook_Picked_\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Copies the picked audio into the library *inside* the security scope,
    /// synchronously, then hands the durable URL to the engine.
    private func handleMusicImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let imported = editor.importMusicFile(from: url) else {
            exportError = "Couldn't import that audio file. If it's in iCloud, download it first."
            return
        }
        exportError = nil
        let title = url.deletingPathExtension().lastPathComponent
        Task { await editor.addAudioTrack(importedURL: imported, title: title) }
    }

    private func startExport(spec: ExportSpec = ExportSpec()) {
        guard !editor.isEmpty else {
            exportError = "Add a clip to the timeline first."
            return
        }
        exportError = nil
        isExporting = true
        Task {
            do {
                // 4K spec needs a 4K canvas — renderSize caps the preset.
                let built = try await editor.buildComposition(
                    renderScale: spec.resolution == .uhd4K ? 2 : 1)
                let url: URL
                if spec.audioOnly {
                    // M4A: no video, share-only (Photos rejects audio).
                    url = try await app.exporter.exportAudioOnly(asset: built.composition,
                                                                 audioMix: built.audioMix)
                    app.lastExportSavedToPhotos = false
                } else {
                    url = try await app.exporter.export(asset: built.composition,
                                                        videoComposition: built.videoComposition,
                                                        audioMix: built.audioMix,
                                                        spec: spec)
                    // F5: transcode BEFORE the Photos hand-off. The GIF is a
                    // local artefact and must not depend on the photo-library
                    // permission — if the user denies it, they still get it.
                    app.lastExportGIFURL = (spec.alsoGIF && !spec.audioOnly)
                        ? await GIFExporter.makeGIF(from: url)
                        : nil
                    app.lastExportSavedToPhotos = await app.exporter.saveToPhotos(url: url)
                }
                app.lastExportURL = url
                isExporting = false
                LumaHaptics.shared.exportSuccess()
                app.path.append(.exportComplete)
            } catch is CancellationError {
                isExporting = false
            } catch {
                isExporting = false
                LumaHaptics.shared.failure()
                exportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Debug seeding (verification harness)

extension EditorTimelineView {

    /// Debug-only UI-check seeding, sibling to AppModel's LUMA_ROUTE:
    /// SIMCTL_CHILD_LUMA_SEED_CLIP / _MUSIC / _PHOTO / _OVERLAY point at
    /// media files on the host, SIMCTL_CHILD_LUMA_SEED_PLAY=1 starts
    /// playback once seeded.
    private func applyDebugSeed() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        let seedKeys = ["LUMA_SEED_CLIP", "LUMA_SEED_MUSIC", "LUMA_SEED_PHOTO", "LUMA_SEED_OVERLAY"]
        guard seedKeys.contains(where: { env[$0] != nil }) else { return }
        Task {
            if editor.isEmpty, let path = env["LUMA_SEED_CLIP"],
               FileManager.default.fileExists(atPath: path) {
                await editor.addClip(from: URL(fileURLWithPath: path))
            }
            // Second clip for cross-transition cells (different content —
            // a dissolve between identical frames is invisible by definition).
            if let path = env["LUMA_SEED_CLIP2"], FileManager.default.fileExists(atPath: path) {
                await editor.addClip(from: URL(fileURLWithPath: path))
            }
            // Third distinct clip (apply-to-all-cuts tests need 2 real cuts).
            if let path = env["LUMA_SEED_CLIP3"], FileManager.default.fileExists(atPath: path) {
                await editor.addClip(from: URL(fileURLWithPath: path))
            }
            // Photo clip on the MAIN track (T7).
            if let path = env["LUMA_SEED_PHOTO"], FileManager.default.fileExists(atPath: path) {
                await editor.addPhotoClip(from: URL(fileURLWithPath: path))
            }
            // PIP overlay (T1) — image or video, sniffed by extension.
            // Placement clamps against totalDuration, which the async
            // rebuild publishes — wait for the base timeline to settle.
            if let path = env["LUMA_SEED_OVERLAY"], FileManager.default.fileExists(atPath: path) {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let url = URL(fileURLWithPath: path)
                let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff"]
                await editor.addOverlay(from: url,
                                        isImage: imageExtensions.contains(url.pathExtension.lowercased()))
            }
            for key in ["LUMA_SEED_MUSIC", "LUMA_SEED_MUSIC2"] {
                if let path = env[key], FileManager.default.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    if let imported = editor.importMusicFile(from: url) {
                        await editor.addAudioTrack(importedURL: imported,
                                                   title: url.deletingPathExtension().lastPathComponent)
                    }
                }
            }
            // B2/B3 verification hooks. LUMA_SEED_SELECTCLIP=1 selects the
            // first clip so the contextual action chips render;
            // LUMA_SEED_TOOLPANEL=trim|speed|clipaudio|overlay opens that
            // panel so the push-up layout can be captured headlessly.
            if env["LUMA_SEED_SELECTCLIP"] == "1" || env["LUMA_SEED_TOOLPANEL"] != nil {
                for _ in 0..<40 where editor.clips.isEmpty || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
            }
            if let panel = env["LUMA_SEED_TOOLPANEL"] {
                switch panel {
                case "trim":
                    if let clip = editor.selectedClip {
                        trimStart = clip.trimStart
                        trimEnd = clip.trimEnd
                        trimOriginal = (clip.trimStart, clip.trimEnd)
                    }
                    tool = .trim
                case "speed":     tool = .speed
                case "clipaudio": tool = .clipAudio
                case "overlay":
                    selectedOverlayID = editor.overlays.first?.id
                    if editor.overlays.first != nil { tool = .overlay }
                default: break
                }
            }
            // Open an audio panel for verification: "music" → the music/clip
            // audio panel; "fx" → the AudioEffectsPanel (EQ/pitch/voice/reverb).
            if let which = env["LUMA_SEED_AUDIOPANEL"] {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                if which == "fx" {
                    debugFXTrackID = editor.audioTracks.first?.id
                } else {
                    selectedAudioID = editor.audioTracks.first?.id
                    tool = .music
                }
            }
            // Per-clip looks (Next-10 #1): split the seeded clip at its
            // midpoint and give the FIRST half its own grade, so an export
            // shows two visibly different looks either side of the cut.
            if let lookName = env["LUMA_SEED_CLIPLOOK"], !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: editor.totalDuration / 2)
                editor.splitAtPlayhead()
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let first = editor.clips.first {
                    editor.setClipGrade(id: first.id,
                                        ClipGrade(baseLookName: lookName, lutID: nil,
                                                  settings: LookSettings()))
                }
            }
            // Voiceover cell (#8): record ~2 s of mic and drop the lane.
            if env["LUMA_SEED_VOICEOVER"] == "1", !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.startVoiceover()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                editor.stopVoiceover()
            }
            // Text cell (T6): LUMA_SEED_TEXT="HELLO WORLD" drops a title.
            if let text = env["LUMA_SEED_TEXT"], !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.addTextOverlay()
                if let added = editor.overlays.last(where: { $0.text != nil }) {
                    editor.setOverlayText(id: added.id, text)
                }
            }
            // Keyframe cell (T5): overlay animates small/top-left -> large/
            // bottom-right across its run. LUMA_SEED_KEYFRAMES=1.
            if env["LUMA_SEED_KEYFRAMES"] == "1", let overlay = editor.overlays.first {
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.setOverlaySize(id: overlay.id, 0.3)
                editor.setOverlayCenter(id: overlay.id, CGPoint(x: 0.2, y: 0.2))
                editor.seek(to: overlay.timelineOffset)
                editor.addOverlayKeyframe(id: overlay.id)
                editor.seek(to: overlay.timelineOffset + overlay.duration - 0.05)
                editor.setOverlaySize(id: overlay.id, 0.7)
                editor.setOverlayCenter(id: overlay.id, CGPoint(x: 0.75, y: 0.75))
                editor.setOverlayRotation(id: overlay.id, 45)
                editor.addOverlayKeyframe(id: overlay.id)
                editor.seek(to: 0)
            }
            // True-transition cells: split the seeded clip at its midpoint and
            // set the given style at the cut, e.g. LUMA_SEED_TRANSITION=dissolve.
            if let raw = env["LUMA_SEED_TRANSITION"],
               let style = TransitionStyle(rawValue: raw), !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                // Two seeded clips: style the cut between them. One clip:
                // split it at the midpoint first.
                if editor.clips.count < 2 {
                    editor.seek(to: editor.totalDuration / 2)
                    editor.splitAtPlayhead()
                    for _ in 0..<40 where editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                if env["LUMA_SEED_TRANSITION_ALL"] == "1" {
                    // Need ≥3 clips for 2 cuts: split the last clip once.
                    if editor.clips.count < 3 {
                        editor.seek(to: editor.totalDuration * 0.75)
                        editor.splitAtPlayhead()
                        for _ in 0..<40 where editor.isRebuilding {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    editor.setTransitionForAllCuts(style: style)
                } else if let first = editor.clips.first {
                    editor.setTransition(afterClipID: first.id, style: style)
                }
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // Parity-matrix cells (#93): drive format + export spec headlessly,
            // e.g. LUMA_SEED_FORMAT=9:16  LUMA_SEED_SPEC="4K|HEVC|24".
            if let raw = env["LUMA_SEED_FORMAT"], let format = EditorFormat(rawValue: raw) {
                editor.setFormat(format, zoom: editor.zoom)
            }
            // Fullscreen preview cell: LUMA_SEED_FULLSCREEN=1.
            if env["LUMA_SEED_FULLSCREEN"] == "1" {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                showFullscreenPreview = true
            }
            if env["LUMA_SEED_DUPLICATE"] == "1", !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                editor.duplicateSelected()
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // F0 auto-stack test: two overlays added at the same playhead must
            // land on lanes 0/1 (not be pushed later) and both render.
            // F11: apply a template by id.
            if let tid = env["LUMA_SEED_TEMPLATE"], !editor.isEmpty {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let before = editor.totalDuration
                if let t = TemplateLibrary.all.first(where: { $0.id == tid }) {
                    let ok = editor.applyTemplate(t)
                    for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                    print("[LUMA] TEMPLATE id=\(tid) ok=\(ok) fmt=\(editor.format.rawValue) before=\(String(format: "%.2f", before)) after=\(String(format: "%.2f", editor.totalDuration)) clip0dur=\(String(format: "%.2f", editor.clips.first?.timelineDuration ?? 0)) trans=\(editor.clips.first?.transitionAfter.rawValue ?? "nil")")
                } else {
                    print("[LUMA] TEMPLATE id=\(tid) NOT FOUND ids=\(TemplateLibrary.all.map(\.id))")
                }
            }
            // F10: caption layers from injected segments. Format
            // "text@start@dur;text@start@dur". Bypasses STT so the layering +
            // SRT path is verifiable headlessly (simctl cannot grant speech).
            if let cs = env["LUMA_SEED_CAPTIONS"], !editor.isEmpty {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let segs: [CaptionSegment] = cs.split(separator: ";").compactMap { part in
                    let f = part.split(separator: "@").map(String.init)
                    guard f.count == 3, let st = Double(f[1]), let d = Double(f[2]) else { return nil }
                    return CaptionSegment(text: f[0], start: st, duration: d)
                }
                let n = editor.addCaptions(segs)
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let srt = editor.captionsSRT()
                try? srt.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
                print("[LUMA] CAPTIONS added=\(n) layers=\(editor.overlays.filter { $0.kind == "caption" }.count)")
            }
            // F3: an animated title. Format "TEXT|preset".
            if let ta = env["LUMA_SEED_TEXTANIM"], !editor.isEmpty {
                let f = ta.split(separator: "|").map(String.init)
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: 0)
                editor.addTextOverlay()
                if let o = editor.overlays.last {
                    editor.setOverlayText(id: o.id, f[0])
                    if f.count > 1, let p = TextAnimation(rawValue: f[1]) {
                        editor.setTextAnimation(id: o.id, p)
                    }
                    editor.setOverlayCenter(id: o.id, CGPoint(x: 0.5, y: 0.5))
                    editor.setOverlaySize(id: o.id, 0.7)
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let o = editor.overlays.last
                print("[LUMA] TEXTANIM text=\(o?.text ?? "nil") anim=\(o?.textAnimation ?? "nil")")
                // Open the text panel so its scroll/expand fix is screenshot-verifiable.
                if env["LUMA_SEED_OPENPANEL"] == "1", let id = editor.overlays.last?.id {
                    selectedOverlayID = id
                    tool = .overlay
                }
            }
            // F7: a particle layer over the whole clip. Format "kind|intensity".
            if let pt = env["LUMA_SEED_PARTICLES"], !editor.isEmpty {
                let f = pt.split(separator: "|").map(String.init)
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: 0)
                if let kind = ParticleKind(rawValue: f[0]),
                   let id = editor.addParticleLayer(kind: kind, duration: editor.totalDuration) {
                    if f.count > 1, let v = Double(f[1]) { editor.setParticleIntensity(id: id, v) }
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let l = editor.particleLayers.last
                print("[LUMA] PARTICLES kind=\(l?.kind ?? "nil") intensity=\(l?.intensity ?? -1)")
            }
            // B2: install a pack, apply its first installed look to clip 0,
            // report the unified library. Proves installed looks reach the
            // editor AND grade the clip (lutID → makeLookState → compositor).
            if env["LUMA_SEED_LIBLOOK"] != nil, !editor.isEmpty {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let pack = PackCatalog.packs.first {
                    let n = PackInstaller.install(pack, into: app.lutRepository)
                    app.packStore.markInstalled(pack)
                    let lib = app.libraryLooks
                    let installed = lib.filter { $0.section == .installed }
                    print("[LUMA] LIBLOOK installedCount=\(n) libraryTotal=\(lib.count) installedInLib=\(installed.count) sections=\(app.libraryLooksBySection.map { "\($0.section):\($0.looks.count)" }) favourites=\(app.library.looks(category: .favourites).count) recents=\(app.library.recents.count)")
                    if let first = installed.first, let clip = editor.clips.first {
                        app.select(look: first, forClip: clip.id)
                        print("[LUMA] LIBLOOK applied='\(first.name)' lutID=\(first.clipGrade().lutID?.uuidString.prefix(8) ?? "nil") recentsAfter=\(app.library.recents.count)")
                    }
                    for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                    if env["LUMA_SEED_LIBLOOK"] == "strip" { looksTargetClipID = nil; tool = .looks }
                }
            }
            // F5: an animated GIF as an overlay — must advance with time.
            if let g = env["LUMA_SEED_GIF"], !editor.isEmpty {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: 0)
                await editor.addOverlay(from: URL(fileURLWithPath: g), isImage: true)
                if let o = editor.overlays.last {
                    editor.setOverlayCenter(id: o.id, CGPoint(x: 0.5, y: 0.5))
                    editor.setOverlaySize(id: o.id, 0.5)
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                print("[LUMA] GIFIMPORT overlays=\(editor.overlays.count)")
            }
            // F8: a spot tool on the first clip. Format "shape|effect|amount".
            if let m = env["LUMA_SEED_CLIPMASK"], !editor.isEmpty {
                let f = m.split(separator: "|").map(String.init)
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let clip = editor.clips.first, let shape = ClipMaskShape(rawValue: f[0]) {
                    editor.setClipMask(id: clip.id,
                                       shape: shape,
                                       effect: f.count > 1 ? ClipMaskEffect(rawValue: f[1]) : nil,
                                       center: CGPoint(x: 0.5, y: 0.5),
                                       size: CGSize(width: 0.4, height: 0.4),
                                       amount: f.count > 2 ? Double(f[2]) : nil)
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let c = editor.clips.first
                print("[LUMA] CLIPMASK shape=\(c?.maskShape ?? "nil") effect=\(c?.maskEffect ?? "nil") amount=\(c?.maskAmount ?? -1)")
            }
            // F6: a full-frame effect over the whole clip. Format "kind|intensity".
            if let fx = env["LUMA_SEED_EFFECT"], !editor.isEmpty {
                let f = fx.split(separator: "|").map(String.init)
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: 0)
                if let kind = EffectKind(rawValue: f[0]),
                   let id = editor.addEffectLayer(kind: kind, duration: editor.totalDuration) {
                    if f.count > 1, let v = Double(f[1]) { editor.setEffectIntensity(id: id, v) }
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let l = editor.effectLayers.last
                print("[LUMA] EFFECT kind=\(l?.kind ?? "nil") intensity=\(l?.intensity ?? -1) span=\(l?.duration ?? 0)")
            }
            // F4: a shape at centre. Format "kind|fillHex".
            if let sh = env["LUMA_SEED_SHAPE"], !editor.isEmpty {
                let f = sh.split(separator: "|").map(String.init)
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: 0)
                if let kind = ShapeKind(rawValue: f[0]), let id = editor.addShapeOverlay(kind: kind) {
                    if f.count > 1 { editor.setShapeDecor(id: id, fillHex: .some(f[1])) }
                    editor.setOverlayCenter(id: id, CGPoint(x: 0.5, y: 0.5))
                    editor.setOverlaySize(id: id, 0.5)
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let o = editor.overlays.last
                print("[LUMA] SHAPE kind=\(o?.shapeKind ?? "nil") fill=\(o?.shapeFillHex ?? "nil") kindTag=\(o?.kind ?? "nil")")
            }
            // F2: a stroked/boxed title, centred, for pixel sampling.
            // Format: "TEXT|strokeHex|strokeWidth|boxHex|align"
            if let t = env["LUMA_SEED_TEXTDECOR"], !editor.isEmpty {
                let f = t.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: 0)
                editor.addTextOverlay()
                if let o = editor.overlays.last {
                    editor.setOverlayText(id: o.id, f.first ?? "AB")
                    editor.setTextDecor(id: o.id,
                                        strokeHex: f.count > 1 && !f[1].isEmpty ? .some(f[1]) : nil,
                                        strokeWidth: f.count > 2 ? Double(f[2]) : nil,
                                        boxHex: f.count > 3 && !f[3].isEmpty ? .some(f[3]) : nil,
                                        alignment: f.count > 4 && !f[4].isEmpty ? f[4] : nil)
                    editor.setOverlayCenter(id: o.id, CGPoint(x: 0.5, y: 0.5))
                    editor.setOverlaySize(id: o.id, 0.7)
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let o = editor.overlays.last
                print("[LUMA] TEXTDECOR text=\(o?.text ?? "nil") stroke=\(o?.textStrokeHex ?? "nil")@\(o?.textStrokeWidth ?? 0) box=\(o?.textBoxHex ?? "nil") align=\(o?.textAlignment ?? "nil")")
            }
            // F1: bake an emoji sticker and centre it for pixel sampling.
            if let emoji = env["LUMA_SEED_STICKER"], !editor.isEmpty {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: 0)
                let ok = await editor.addSticker(emoji: emoji)
                if let s = editor.overlays.last {
                    editor.setOverlayCenter(id: s.id, CGPoint(x: 0.5, y: 0.5))
                    editor.setOverlaySize(id: s.id, 0.6)
                }
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                print("[LUMA] STICKER ok=\(ok) count=\(editor.overlays.count) kind=\(editor.overlays.last?.kind ?? "nil")")
            }
            // F9: project frame preset (rawValue), e.g. thinWhite / letterbox.
            if let fp = env["LUMA_SEED_FRAME"], !editor.isEmpty,
               let preset = FramePreset(rawValue: fp) {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.setFramePreset(preset)
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                print("[LUMA] FRAME preset=\(editor.framePreset)")
            }
            if let s2 = env["LUMA_SEED_STACK2"], !editor.isEmpty {
                let paths = s2.split(separator: ",").map(String.init)
                if paths.count >= 2 {
                    for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    editor.seek(to: 0)
                    await editor.addOverlay(from: URL(fileURLWithPath: paths[0]), isImage: true)
                    await editor.addOverlay(from: URL(fileURLWithPath: paths[1]), isImage: true)
                    // Distinct centres so both are separately samplable.
                    if editor.overlays.count >= 2 {
                        editor.setOverlayCenter(id: editor.overlays[0].id, CGPoint(x: 0.3, y: 0.3))
                        editor.setOverlayCenter(id: editor.overlays[1].id, CGPoint(x: 0.7, y: 0.7))
                        editor.setOverlaySize(id: editor.overlays[0].id, 0.3)
                        editor.setOverlaySize(id: editor.overlays[1].id, 0.3)
                    }
                    for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                    print("[LUMA] STACK2 lanes=\(editor.overlays.map { "\($0.lane)@\(String(format: "%.1f", $0.timelineOffset))" })")
                }
            }
            // Z-order test: overlay A (paths[0]) and B (paths[1]) overlap at
            // one centre. B rides lane 1 (on top by default → B visible). With
            // LUMA_SEED_ZORDER_LANE=1, A jumps to lane 2 so A wins instead.
            if let z = env["LUMA_SEED_ZORDER"], !editor.isEmpty {
                let paths = z.split(separator: ",").map(String.init)
                if paths.count >= 2 {
                    for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    await editor.addOverlay(from: URL(fileURLWithPath: paths[0]), isImage: true)
                    await editor.addOverlay(from: URL(fileURLWithPath: paths[1]), isImage: true)
                    let a = editor.overlays.first?.id
                    let b = editor.overlays.dropFirst().first?.id
                    if let a, let b {
                        editor.nudgeOverlayLane(id: b, by: 1)        // B → lane 1
                        editor.setOverlayOffset(id: b, 0)            // overlap A
                        editor.setOverlayCenter(id: a, CGPoint(x: 0.5, y: 0.5))
                        editor.setOverlayCenter(id: b, CGPoint(x: 0.5, y: 0.5))
                        editor.setOverlaySize(id: a, 0.6)
                        editor.setOverlaySize(id: b, 0.6)
                        if env["LUMA_SEED_ZORDER_LANE"] == "1" {
                            editor.nudgeOverlayLane(id: a, by: 2)    // A → lane 2 (wins)
                        }
                    }
                    for _ in 0..<40 where editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            // Adjustment-layer test: a strong warm grade over the FIRST half
            // of the timeline; frames inside should read warmer than outside.
            if env["LUMA_SEED_ADJUST"] == "1", !editor.isEmpty {
                for _ in 0..<40 where editor.totalDuration <= 0.1 || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                var settings = LookSettings()
                settings.saturation = env["LUMA_SEED_ADJUST_DESAT"] == "1" ? -100 : 90
                if env["LUMA_SEED_ADJUST_DESAT"] != "1" { settings.warmth = 90 }
                let grade = ClipGrade(baseLookName: "", lutID: nil, settings: settings)
                let id = editor.addAdjustmentLayer(grade: grade)
                editor.setAdjustmentSpan(id: id, offset: 0, duration: editor.totalDuration / 2)
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // Music fade: LUMA_SEED_FADE="1.5|1.5|sCurve" on the first lane.
            if let fadeStr = env["LUMA_SEED_FADE"], let m = editor.audioTracks.first {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let parts = fadeStr.split(separator: "|")
                let fin = parts.count > 0 ? Double(parts[0]) : nil
                let fout = parts.count > 1 ? Double(parts[1]) : nil
                let curve = parts.count > 2 ? FadeCurve(rawValue: String(parts[2])) : nil
                editor.setMusicFade(id: m.id, fadeIn: fin, fadeOut: fout, curve: curve)
                for _ in 0..<20 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            // Music envelope dip: LUMA_SEED_ENVELOPE="t,v;t,v" on the first lane.
            if let envStr = env["LUMA_SEED_ENVELOPE"], let m = editor.audioTracks.first {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let pts = envStr.split(separator: ";").compactMap { seg -> AudioVolumePoint? in
                    let xy = seg.split(separator: ",")
                    guard xy.count == 2, let t = Double(xy[0]), let v = Double(xy[1]) else { return nil }
                    return AudioVolumePoint(time: t, volume: v)
                }
                editor.setMusicEnvelope(id: m.id, pts)
                for _ in 0..<20 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            // Auto-duck: LUMA_SEED_DUCK=1 tags track[1] as voice at offset 3,
            // enables ducking on track[0] (music) — music dips under the voice.
            if env["LUMA_SEED_DUCK"] == "1", editor.audioTracks.count >= 2 {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                let voiceID = editor.audioTracks[1].id
                editor.setAudioKind(id: voiceID, .voice)
                editor.setMusicOffset(id: voiceID, 3.0)
                editor.setMusicDucking(id: editor.audioTracks[0].id, true)
                for _ in 0..<20 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            // Loop-to-fill: LUMA_SEED_LOOP=1 on the first music lane.
            if env["LUMA_SEED_LOOP"] == "1", let m = editor.audioTracks.first {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                editor.setMusicLooping(id: m.id, true)
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            // Assign audio-lane kinds in order, e.g. LUMA_SEED_AUDIO_KINDS="voice,sfx".
            if let kinds = env["LUMA_SEED_AUDIO_KINDS"], !editor.audioTracks.isEmpty {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                for (i, raw) in kinds.split(separator: ",").enumerated()
                where i < editor.audioTracks.count {
                    if let k = AudioLaneKind(rawValue: String(raw)) {
                        editor.setAudioKind(id: editor.audioTracks[i].id, k)
                    }
                }
            }
            // PIP preset: LUMA_SEED_PIP_PRESET=circleCam applied to the first overlay.
            if let presetID = env["LUMA_SEED_PIP_PRESET"], let ov = editor.overlays.first,
               let preset = PipPreset.all.first(where: { $0.id == presetID }) {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                editor.applyPipPreset(id: ov.id, preset)
                for _ in 0..<20 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            // Overlay effects: e.g. LUMA_SEED_OVERLAY_FX="blend=screen" or
            // "chroma=#00FF00;mask=ellipse;adjust=exposure:1.0;border=0.04,#FFFFFF,0.1".
            if let fxStr = env["LUMA_SEED_OVERLAY_FX"], let ov = editor.overlays.first {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                for part in fxStr.split(separator: ";") {
                    let kv = part.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { continue }
                    let key = String(kv[0]), val = String(kv[1])
                    switch key {
                    case "blend":
                        if let m = OverlayBlendMode(rawValue: val) { editor.setOverlayBlendMode(id: ov.id, m) }
                    case "chroma":
                        editor.setOverlayChroma(id: ov.id, ChromaKeySettings(colorHex: val))
                    case "mask":
                        editor.setOverlayMask(id: ov.id, OverlayMaskSettings(shape: val))
                    case "adjust":
                        let f = val.split(separator: ":")
                        var a = OverlayAdjustments()
                        if f.count == 2, let v = Double(f[1]) {
                            switch f[0] {
                            case "exposure": a.exposure = v
                            case "contrast": a.contrast = v
                            case "saturation": a.saturation = v
                            case "warmth": a.warmth = v
                            default: break
                            }
                        }
                        editor.setOverlayAdjustments(id: ov.id, a)
                    case "border":
                        let f = val.split(separator: ",")
                        var b = OverlayBorderSettings()
                        if let w = f.first.flatMap({ Double($0) }) { b.widthFraction = w }
                        if f.count > 1 { b.colorHex = String(f[1]) }
                        if f.count > 2, let r = Double(f[2]) { b.cornerRadiusFraction = r }
                        editor.setOverlayBorder(id: ov.id, b)
                    default: break
                    }
                }
                for _ in 0..<20 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            if let mode = env["LUMA_SEED_DETACH"], let id = editor.clips.first?.id {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await editor.detachAudio(clipID: id)
                for _ in 0..<60 where editor.isRebuilding || editor.isDetaching {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                // Mode 2: also delete the extracted lane → export should be
                // silent, proving the clip stayed muted.
                if mode == "2", let laneID = editor.audioTracks.last?.id {
                    editor.removeAudioTrack(id: laneID)
                    for _ in 0..<40 where editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            // Standalone renderer test: LUMA_SEED_FXRENDER="<path>|gain:-20"
            // renders the file and copies the output next to the source.
            if let spec = env["LUMA_SEED_FXRENDER"] {
                let parts = spec.split(separator: "|")
                if let path = parts.first.map(String.init), FileManager.default.fileExists(atPath: path) {
                    var settings = AudioEffectSettings()
                    for token in parts.dropFirst() {
                        let kv = token.split(separator: ":")
                        if kv.count == 2, kv[0] == "gain", let g = Double(kv[1]) { settings.gainDB = g }
                        if kv.count == 2, kv[0] == "pitch", let p = Double(kv[1]) { settings.pitchSemitones = p }
                        if kv.count == 2, kv[0] == "reverb" { settings.reverbPreset = String(kv[1]); settings.reverbMix = 60 }
                    }
                    if let out = try? await AudioEffectsRenderer.shared.renderedURL(
                        source: URL(fileURLWithPath: path), settings: settings) {
                        let dest = URL(fileURLWithPath: path).deletingLastPathComponent()
                            .appendingPathComponent("fxrender_out.m4a")
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.copyItem(at: out, to: dest)
                        print("[LUMA] FXRENDER done -> \(dest.path)")
                    }
                }
            }
            // Audio effect seeds (C1-C5) applied to the first audio lane.
            if let m = editor.audioTracks.first {
                var s = m.effects
                var touched = false
                if let eq = env["LUMA_SEED_EQ"] {
                    touched = true
                    if let preset = AudioEffectsPanel.eqPresets.first(where: { $0.0.lowercased().replacingOccurrences(of: " ", with: "") == eq.lowercased() }) {
                        s.eqBandGains = preset.1
                    } else {
                        s.eqBandGains = eq.split(separator: ",").compactMap { Double($0) }
                    }
                }
                if let p = env["LUMA_SEED_PITCH"], let v = Double(p) { s.pitchSemitones = v; touched = true }
                if let vfx = env["LUMA_SEED_VOICEFX"] { s.voiceEffect = vfx; touched = true }
                if let rv = env["LUMA_SEED_REVERB"] {
                    let parts = rv.split(separator: "|")
                    s.reverbPreset = String(parts[0]); touched = true
                    if parts.count > 1, let mix = Double(parts[1]) { s.reverbMix = mix }
                }
                if touched {
                    for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                    await editor.applyTrackEffects(id: m.id, s)
                    for _ in 0..<80 where editor.isRebuilding || editor.isRenderingEffects {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                if let norm = env["LUMA_SEED_NORMALIZE"], let target = Double(norm) {
                    for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                    await editor.normalizeTrack(id: m.id, targetLUFS: target)
                    for _ in 0..<80 where editor.isRebuilding || editor.isRenderingEffects {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            // Bundled-library test: add entry <id> from the library at t=0.
            if let libID = env["LUMA_SEED_LIBADD"], !editor.isEmpty {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                print("[LUMA] LIBRARY count=\(BundledAudioLibrary.all.count)")
                if let entry = BundledAudioLibrary.all.first(where: { $0.id == libID }),
                   let url = BundledAudioLibrary.url(for: entry),
                   let imported = editor.importMusicFile(from: url) {
                    await editor.addAudioTrack(importedURL: imported, title: entry.title,
                                               at: 0, kind: entry.category == "sfx" ? .sfx : .music)
                    for _ in 0..<30 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
            }
            // Audio-reactive: LUMA_SEED_REACTIVE="glow|1.0" on the first lane.
            if let spec = env["LUMA_SEED_REACTIVE"], let m = editor.audioTracks.first {
                let parts = spec.split(separator: "|")
                if let style = AudioReactiveStyle(rawValue: String(parts[0])) {
                    let strength = parts.count > 1 ? (Double(parts[1]) ?? 1) : 1
                    for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                    editor.setAudioReactive(.init(style: style, strength: strength, sourceTrackID: m.id))
                    for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
            }
            // Auto-cut to beats: detect on the first music lane, split the video.
            if env["LUMA_SEED_BEATCUT"] == "1", let m = editor.audioTracks.first {
                for _ in 0..<40 where editor.isRebuilding { try? await Task.sleep(nanoseconds: 100_000_000) }
                await editor.autoCutToBeats(trackID: m.id)
                for _ in 0..<40 where editor.isRebuilding || editor.isDetectingBeats {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                print("[LUMA] BEATCUT clips=\(editor.clips.count)")
            }
            // Beat-detector test: prints detected beats + bpm.
            if let path = env["LUMA_SEED_BEATTEST"], FileManager.default.fileExists(atPath: path) {
                let a = await BeatDetector.analyze(url: URL(fileURLWithPath: path))
                let spacings = zip(a.beats.dropFirst(), a.beats).map { $0 - $1 }.sorted()
                let median = spacings.isEmpty ? 0 : spacings[spacings.count / 2]
                print("[LUMA] BEATTEST bpm=\(a.bpm) count=\(a.beats.count) medianSpacing=\(median)")
            }
            // Loudness test: prints integrated LUFS.
            if let path = env["LUMA_SEED_LUFSTEST"], FileManager.default.fileExists(atPath: path) {
                let lufs = await LoudnessAnalyzer.integratedLUFS(url: URL(fileURLWithPath: path))
                print("[LUMA] LUFSTEST lufs=\(lufs.map { String($0) } ?? "nil")")
            }
            if env["LUMA_SEED_PASTE"] == "1", !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                editor.copySelected()
                editor.pasteClip()
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // Ripple test: place the seeded overlay on clip 2 (offset 12s),
            // then ripple-delete clip 1 — the overlay must slide to ~2s.
            // LUMA_SEED_RIPPLE=2 leaves clip 1 in place (control export).
            if let rippleMode = env["LUMA_SEED_RIPPLE"], editor.clips.count >= 2 {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let ov = editor.overlays.first {
                    editor.setOverlayOffset(id: ov.id, 12)
                    for _ in 0..<20 where editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                if rippleMode == "1" {
                    editor.selectedClipID = editor.clips.first?.id
                    editor.deleteSelected(ripple: true)
                    for _ in 0..<40 where editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            if env["LUMA_SEED_REVERSE"] == "1", !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                await editor.reverseSelectedClip()
                for _ in 0..<60 where editor.isRebuilding || editor.isBaking {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if let path = env["LUMA_SEED_REPLACE"], FileManager.default.fileExists(atPath: path),
               !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                await editor.replaceClip(id: editor.clips.first!.id,
                                         with: URL(fileURLWithPath: path))
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if let rampRaw = env["LUMA_SEED_RAMP"],
               let ramp = EditorState.SpeedRamp(rawValue: rampRaw), !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                editor.setSpeedRamp(ramp)
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if env["LUMA_SEED_FREEZE"] == "1", !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.seek(to: editor.totalDuration / 2)
                await editor.freezeAtPlayhead()
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if let kbRaw = env["LUMA_SEED_KENBURNS"],
               let preset = EditorState.KenBurnsPreset(rawValue: kbRaw), !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let id = editor.clips.first?.id {
                    editor.selectedClipID = id
                    let ease = env["LUMA_SEED_KBEASE"].flatMap { KeyframeEasing(rawValue: $0) } ?? .easeInOut
                    editor.setKenBurns(id: id, preset: preset, easing: ease)
                    for _ in 0..<20 where editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            if let cropStr = env["LUMA_SEED_CROP"], !editor.isEmpty {
                let parts = cropStr.split(separator: ",").compactMap { Double($0) }
                if parts.count >= 4, let id = editor.clips.first?.id {
                    for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    editor.selectedClipID = id
                    editor.setCropStraighten(
                        id: id,
                        cropRect: CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]),
                        straightenDegrees: parts.count > 4 ? parts[4] : 0)
                    for _ in 0..<40 where editor.isRebuilding {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
            if let raw = env["LUMA_SEED_CANVAS"], let mode = CanvasBackgroundMode(rawValue: raw),
               !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if let fmt = env["LUMA_SEED_FORMAT"], let f = EditorFormat(rawValue: fmt) {
                    editor.setFormat(f, zoom: editor.zoom)
                }
                editor.setCanvasMode(mode)
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if let rotStr = env["LUMA_SEED_ROTATE"], let turns = Int(rotStr), !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                for _ in 0..<turns { editor.rotateSelectedClip() }
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if env["LUMA_SEED_MIRROR"] == "1", !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                editor.mirrorSelectedClip()
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if let nudgeStr = env["LUMA_SEED_NUDGE"], let n = Int(nudgeStr), !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                editor.stepFrame(n)
            }
            if let speedStr = env["LUMA_SEED_SPEED"], let speed = Double(speedStr), !editor.isEmpty {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                editor.selectedClipID = editor.clips.first?.id
                editor.setClipSpeed(speed)
                for _ in 0..<40 where editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if env["LUMA_SEED_EXPORTSHEET"] == "1" {
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                showExportSheet = true
            }
            if env["LUMA_SEED_PLAY"] == "1" || env["LUMA_SEED_EXPORT"] == "1" {
                // Wait out the async rebuild before hitting play/export.
                for _ in 0..<40 where editor.player == nil || editor.isRebuilding {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if env["LUMA_SEED_EXPORT"] == "1" {
                    let spec = env["LUMA_SEED_SPEC"].map(ExportSpec.from(rawValue:)) ?? ExportSpec()
                    startExport(spec: spec)
                } else if !editor.isPlaying {
                    editor.togglePlayback()
                }
            }
        }
        #endif
    }
}

// MARK: - Content

/// The editor proper. Split out from `EditorTimelineView` so it can observe
/// `EditorState` directly — AppModel does not forward the engine's changes.
private struct EditorContent: View {
    @ObservedObject var editor: EditorState
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @StateObject private var thumbs = LookThumbs()

    @Binding var tool: EditorTool
    @Binding var selectedOverlayID: UUID?
    @Binding var selectedAudioID: UUID?
    @Binding var transitionAfterID: UUID?
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var trimOriginal: (start: Double, end: Double)?
    @Binding var timelineZoom: CGFloat
    @Binding var magnetOn: Bool
    @Binding var showFrames: Bool
    @Binding var looksTargetClipID: UUID?
    @Binding var stashedIntensity: Double?
    @Binding var isCaptioning: Bool

    let isLoadingClip: Bool
    let exportError: String?

    let onBack: () -> Void
    let onAddClip: () -> Void
    let onAddOverlayMedia: () -> Void
    let onReplaceMedia: () -> Void
    let onImportAudioFile: () -> Void
    let onOpenCropSheet: () -> Void
    let onOpenLookBrowser: () -> Void
    let onFullscreen: () -> Void
    let onExport: () -> Void
    let onRecordFootage: () -> Void
    let onOpenProjects: () -> Void
    let onOpenAdjust: () -> Void
    let onOpenCropScreen: () -> Void
    let onOpenMixer: () -> Void

    /// Real waveforms for clips' own audio, extracted once per clip and kept
    /// for the session — the music lane has always shown genuine RMS data and
    /// the clip-sound card has no reason to differ.
    @State private var clipWaveforms: [UUID: [Float]] = [:]
    /// The global grade (and the None tile's parked strength) as the
    /// whole-edit Looks tool found them, so ✕ can put them back. The project
    /// itself is snapshotted by `EditorState.beginToolSession()`.
    @State private var looksStash: (grade: AppModel.GradeStash, parkedIntensity: Double?)?

    private var toolIsOpen: Bool { tool != .none }
    private var hasClips: Bool { !editor.isEmpty }

    var body: some View {
        GeometryReader { geo in
            // The panel and the compressed preview are proportions of the
            // screen, not constants: on a 4.7" phone a fixed 300pt drawer plus
            // a fixed 210pt preview does not fit, and the timeline gets eaten.
            let panelHeight = min(300, max(196, geo.size.height * 0.40))
            let previewCeiling = min(214, max(118, geo.size.height * 0.26))

            VStack(spacing: 0) {
                topBar
                preview
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: toolIsOpen ? previewCeiling : .infinity)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                transport
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                timelineSection
                if let exportError {
                    Text(exportError)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
                drawer(panelHeight: panelHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.snappy(duration: 0.22), value: toolIsOpen)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor.selectedClipID != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: editor.audioTracks.count)
        // One physical thump whenever the timeline structure changes.
        .sensoryFeedback(.impact(weight: .medium), trigger: editor.clips.count)
        .sensoryFeedback(.selection, trigger: editor.selectedClipID)
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.library.all.count)") {
            thumbs.render(source: app.previewFrame, library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        .onChange(of: tool) { old, new in
            if new == .clipAudio { loadClipWaveformIfNeeded() }
            toolSessionChanged(from: old, to: new)
        }
        // The timeline grade is read live by the compositor, and a paused
        // player never re-renders on its own: without this a whole-edit look
        // picked (or put back by ✕) while paused did not show until Play.
        .onChange(of: app.selectedLook.id) { _, _ in editor.refreshPausedFrame() }
        .onChange(of: app.selectedLUT?.id) { _, _ in editor.refreshPausedFrame() }
        .onChange(of: app.settings) { _, _ in editor.refreshPausedFrame() }
        .onChange(of: editor.selectedClipID) { _, _ in
            if tool == .clipAudio { loadClipWaveformIfNeeded() }
        }
    }

    // MARK: Top bar — monochrome, Export is a plain word

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)

            Menu {
                Button("New Project") { editor.startNewProject(); tool = .none }
                Button("Open Project Library") { onOpenProjects() }
            } label: {
                HStack(spacing: 5) {
                    Text(editor.projectTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 4)

            Button { editor.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(editor.canUndo ? Color.white : LumaTheme.textMuted)
                    .frame(width: 30, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress).disabled(!editor.canUndo)

            Button { editor.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(editor.canRedo ? Color.white : LumaTheme.textMuted)
                    .frame(width: 30, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress).disabled(!editor.canRedo)

            Button(action: onExport) {
                Text("Export")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.lumaPress)
            .opacity(editor.isEmpty ? 0.35 : 1)
            // Looked disabled but still opened the export sheet on an empty
            // timeline, erroring only after the user picked a spec.
            .disabled(editor.isEmpty)
        }
        .padding(.horizontal, 12)
    }

    // MARK: Preview — the image is the interface. Never covered.

    @ViewBuilder
    private var preview: some View {
        Group {
            if let player = editor.player {
                VideoPlayer(player: player)
                    .onDisappear { if editor.isPlaying { editor.togglePlayback() } }
            } else {
                emptyStage
            }
        }
        // Overlays, text, stickers and shapes are moved WITH A FINGER, on the
        // picture itself. Nothing is drawn unless a layer is live at the
        // playhead, so this never intercepts a touch it has no answer for.
        .overlay {
            if editor.player != nil {
                PreviewOverlayEditor(editor: editor, selectedOverlayID: $selectedOverlayID)
            }
        }
        // The audio asset the open tool is editing, as a card pinned to the top
        // of the frame — so the controls below read as belonging to it without
        // the picture being taken away.
        .overlay(alignment: .top) {
            if let f = audioFocus {
                AudioFocusView(title: f.title, subtitle: f.subtitle,
                               icon: f.icon, samples: f.samples)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeInOut(duration: 0.22), value: audioFocusKey)
    }

    /// The asset being edited when an audio tool is open (nil otherwise).
    private var audioFocus: (title: String, subtitle: String, icon: String, samples: [Float])? {
        if tool == .music,
           let t = editor.audioTracks.first(where: { $0.id == selectedAudioID }) ?? editor.audioTracks.first {
            return (t.title,
                    "\(t.kind.label) · \(LDFormat.secs(t.timelineDuration))",
                    t.kind.icon, t.waveform)
        }
        if tool == .clipAudio, let c = editor.selectedClip {
            // Photos-imported assets have UUID filenames, so the URL stem is a
            // machine identifier, not a name. Title the clip by its position.
            let index = editor.clips.firstIndex(where: { $0.id == c.id })
            let name = index.map { "Clip \($0 + 1)" }
                ?? c.url.deletingPathExtension().lastPathComponent
            return (name, "Clip sound", "waveform", clipWaveforms[c.id] ?? [])
        }
        return nil
    }

    private var audioFocusKey: String {
        "\(tool)\(selectedAudioID?.uuidString ?? "")\(editor.selectedClipID?.uuidString ?? "")"
    }

    /// Extracts the selected clip's waveform off the main actor if it isn't
    /// cached yet. Cheap no-op on every other call.
    private func loadClipWaveformIfNeeded() {
        guard let clip = editor.selectedClip, clip.hasAudio,
              clipWaveforms[clip.id] == nil else { return }
        let id = clip.id
        let url = clip.url
        Task {
            let samples = await Task.detached(priority: .utility) {
                await EditorState.waveformSamples(url: url)
            }.value
            if !samples.isEmpty { clipWaveforms[id] = samples }
        }
    }

    private var emptyStage: some View {
        ZStack {
            Color(white: 0.07)
            VStack(spacing: 16) {
                if isLoadingClip {
                    ProgressView().tint(.white)
                    Text("Loading clip…").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                } else {
                    LDCaption("Nothing on the timeline yet")
                    HStack(spacing: 10) {
                        stageEntry("Add video", "plus", action: onAddClip)
                        stageEntry("Record", "record.circle", action: onRecordFootage)
                        stageEntry("Projects", "folder", action: onOpenProjects)
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .foregroundStyle(Color.white.opacity(0.14))
        }
    }

    private func stageEntry(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 18, weight: .light))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 84, height: 74)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    // MARK: Transport — every number in mono

    /// Playhead, length and (with frames on) the rate. The play button sits
    /// dead centre, so this gets a third of the row: about 130 pt on a 6.3"
    /// phone, where the one-line frames form (about 190 pt) used to wrap
    /// mid-number. It now picks the first layout that fits.
    private var timeReadout: some View {
        let current = showFrames
            ? LDFormat.timecode(editor.currentTime, frameDuration: editor.frameDuration)
            : LDFormat.clock(editor.currentTime)
        let total = showFrames
            ? LDFormat.timecode(editor.totalDuration, frameDuration: editor.frameDuration)
            : LDFormat.clock(editor.totalDuration)
        // Frames are only meaningful with their rate beside them.
        let rate = showFrames ? LDFormat.rate(editor.frameRate) : nil
        let playhead = Text(current)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.95))
        return ViewThatFits(in: .horizontal) {
            // One line when there's room (the minutes:seconds form fits).
            HStack(spacing: 5) {
                playhead
                Text("/")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
                Text(total)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                if let rate {
                    Text(rate)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .lineLimit(1)
            .fixedSize()
            // Otherwise the playhead keeps its size and the length and rate
            // sit beneath it, smaller.
            VStack(alignment: .leading, spacing: 1) {
                playhead
                Text(rate.map { "\(total) · \($0)" } ?? total)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
            .lineLimit(1)
            .fixedSize()
            // Last resort: the playhead alone, shrinking rather than wrapping.
            playhead
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            timeReadout
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onLongPressGesture { showFrames.toggle(); LumaHaptics.shared.tap() }

            HStack(spacing: 24) {
                Button {} label: { Image(systemName: "backward.end").font(.system(size: 14, weight: .light)) }
                    .buttonStyle(LumaHoldButtonStyle(onTap: { editor.seekToBoundary(forward: false) },
                                                     onHold: { editor.stepFrame(-1) }))
                Button { editor.togglePlayback() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26)
                }
                .buttonStyle(.lumaPress)
                Button {} label: { Image(systemName: "forward.end").font(.system(size: 14, weight: .light)) }
                    .buttonStyle(LumaHoldButtonStyle(onTap: { editor.seekToBoundary(forward: true) },
                                                     onHold: { editor.stepFrame(1) }))
            }
            .foregroundStyle(.white)
            .opacity(editor.isEmpty ? 0.3 : 1)
            .disabled(editor.isEmpty)

            // Spacing 10, not 16: at 16 the three controls outgrew their
            // third of the row on 6.3" phones and the zoom value wrapped.
            HStack(spacing: 10) {
                if editor.isRebuilding {
                    ProgressView().controlSize(.mini).tint(LumaTheme.textMuted)
                }
                // Glyphs stay small; each touch area is ~44 pt square.
                Button { magnetOn.toggle(); LumaHaptics.shared.tap() } label: {
                    Image(systemName: magnetOn ? "magnet.fill" : "magnet")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(magnetOn ? Color.white : LumaTheme.textMuted)
                        .frame(width: 26, height: 30)
                        .contentShape(HitSlop(horizontal: 8, vertical: 7))
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel(magnetOn ? "Snapping on" : "Snapping off")
                Button(action: onFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .light))
                        .frame(width: 26, height: 30)
                        .contentShape(HitSlop(horizontal: 8, vertical: 7))
                }
                .buttonStyle(.lumaPress).disabled(editor.isEmpty)
                .accessibilityLabel("Full screen preview")
                Button {
                    timelineZoom = nextZoom(timelineZoom)
                    LumaHaptics.shared.tap()
                } label: {
                    // The control has a value, so it shows the value. Zoom
                    // reads as a percentage beside a magnifier; "×" belongs
                    // to Speed alone, so the two can't be mistaken.
                    HStack(spacing: 3) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 11, weight: .regular))
                        Text("\(Int((timelineZoom / 50 * 100).rounded()))%")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(minWidth: 34, minHeight: 30)
                    .contentShape(HitSlop(horizontal: 4, vertical: 7))
                }
                .buttonStyle(.lumaPress).disabled(editor.isEmpty)
                .accessibilityLabel("Timeline zoom")
                .accessibilityValue("\(Int((timelineZoom / 50 * 100).rounded())) percent")
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private static let zoomSteps: [CGFloat] = [25, 50, 100, 200]

    private func nextZoom(_ current: CGFloat) -> CGFloat {
        let next = Self.zoomSteps.first { $0 > current + 0.5 } ?? Self.zoomSteps[0]
        return min(max(next, TimelineMetrics.minPPS), TimelineMetrics.maxPPS)
    }

    // MARK: Timeline — the full lane stack, or a scrubbable mini strip

    @ViewBuilder
    private var timelineSection: some View {
        if toolIsOpen {
            // "Push, never cover": tuning a value and finding the frame it
            // applies to stay one gesture apart.
            MiniTimelineStrip(editor: editor, zoom: timelineZoom)
                .padding(.horizontal, 12)
                .padding(.top, 2)
            Spacer(minLength: 0)
        } else {
            TimelineV2View(editor: editor,
                           onAddMusic: { tool = .audioAdd },
                           onTapMusic: { id in selectedAudioID = id; tool = .music },
                           onTapClipAudio: { id in editor.selectedClipID = id; tool = .clipAudio },
                           onTapTransition: { id in transitionAfterID = id; tool = .transition },
                           onAddOverlay: onAddOverlayMedia,
                           onTapOverlay: { id in selectedOverlayID = id; tool = .overlay },
                           onRecordVoiceover: { tool = .voice },
                           onAddClip: onAddClip,
                           zoom: $timelineZoom)
                .padding(.bottom, 8)
        }
    }

    // MARK: Drawer — tool rows, or one tool and its instruction bar

    @ViewBuilder
    private func drawer(panelHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(LumaTheme.hairline).frame(height: 1)
            if tool == .none {
                toolRow
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .overlay(alignment: .top) {
                        if editor.isRecordingVoiceover {
                            InputMeterView(level: editor.inputLevel)
                                .offset(y: -44)
                                .transition(.opacity)
                        }
                    }
            } else {
                panelBody(height: panelHeight)
                LDInstructionBar(sentence: instruction,
                                 onCancel: { cancelTool() },
                                 onConfirm: { closeTool() })
                    .padding(.bottom, 2)
            }
        }
        .background(Color.black)
    }

    private func closeTool() {
        withAnimation(.snappy(duration: 0.2)) { tool = .none }
        trimOriginal = nil
        LumaHaptics.shared.tap()
    }

    /// ✕ means "put it back", for every tool. Sliders commit live so the frame
    /// updates as you drag, which used to make ✕ exactly the same as ✓ for all
    /// but Trim. Now the project is snapshotted when the drawer opens and
    /// restored here; the cancelled state waits on Redo in case ✕ was a slip.
    private func cancelTool() {
        if let stash = looksStash {
            app.restoreGrade(stash.grade)
            stashedIntensity = stash.parkedIntensity
            looksStash = nil
        }
        editor.cancelToolSession()
        closeTool()
    }

    /// One opening of the drawer is one session. Switching tools inside it
    /// (Shape, then the new shape's Overlay panel) continues the session, so
    /// ✕ undoes the whole visit, including the shape that was added.
    private func toolSessionChanged(from old: EditorTool, to new: EditorTool) {
        // Voiceover records on its own clock and lands its take after the
        // writer closes; a snapshot restore could race it, so ✕ there simply
        // closes, as it always has.
        if new == .voice {
            editor.commitToolSession()
            looksStash = nil
            return
        }
        if old == .none, new != .none {
            editor.beginToolSession()
            looksStash = nil
        } else if new == .none {
            editor.commitToolSession()
            looksStash = nil
        }
        if new == .looks, looksStash == nil {
            looksStash = (app.stashGrade(), stashedIntensity)
        }
    }

    /// The tool row swaps on selection — context decides the tools.
    @ViewBuilder
    private var toolRow: some View {
        if editor.selectedClipID != nil, !editor.isEmpty {
            HStack(spacing: 0) {
                Button {
                    editor.selectedClipID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .frame(width: 32, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) { clipTools }.padding(.trailing, 26)
                }
                .lumaEdgeFade(leading: 6, trailing: 20)
            }
            .padding(.horizontal, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) { projectTools }
                    .padding(.horizontal, 12)
                    .padding(.trailing, 26)
            }
            .lumaEdgeFade(leading: 14, trailing: 20)
        }
    }

    /// Mirrors `EditorState.performSplit`'s own admissibility test: the
    /// playhead must sit strictly inside a clip, at least 0.15 s from an edge.
    private var canSplitAtPlayhead: Bool {
        let starts = editor.clipStartTimes
        let t = editor.currentTime
        return editor.clips.contains { clip in
            guard let start = starts[clip.id] else { return false }
            return t > start + 0.15 && t < start + clip.timelineDuration - 0.15
        }
    }

    @ViewBuilder
    private var projectTools: some View {
        LDToolItem(title: "Add", icon: "plus", action: onAddClip)
        LDToolItem(title: "Edit", icon: "scissors", enabled: hasClips) { selectClipAtPlayhead() }
        LDToolItem(title: "Looks", icon: "camera.filters", enabled: hasClips) {
            looksTargetClipID = nil; tool = .looks
        }
        LDToolItem(title: "Adjust", icon: "slider.horizontal.3", enabled: hasClips, action: onOpenAdjust)
        LDToolItem(title: "Text", icon: "textformat", enabled: hasClips) { addText() }
        LDToolItem(title: "Overlay", icon: "rectangle.on.rectangle",
                   enabled: hasClips, action: onAddOverlayMedia)
        LDToolItem(title: "Sticker", icon: "face.smiling", enabled: hasClips) { tool = .sticker }
        LDToolItem(title: "Shape", icon: "square.on.circle", enabled: hasClips) { tool = .shape }
        LDToolItem(title: "Effects", icon: "sparkles", enabled: hasClips) { tool = .effects }
        LDToolItem(title: "Particles", icon: "sparkles.rectangle.stack", enabled: hasClips) { tool = .particles }
        LDToolItem(title: "Adj Layer", icon: "square.stack.3d.up",
                   active: !editor.adjustmentLayers.isEmpty, enabled: hasClips) { tool = .adjLayer }
        LDToolItem(title: "Audio", icon: "music.note", enabled: hasClips) { tool = .audioAdd }
        LDToolItem(title: editor.isRecordingVoiceover ? "Stop" : "Voice",
                   icon: editor.isRecordingVoiceover ? "stop.circle" : "mic",
                   active: editor.isRecordingVoiceover, enabled: hasClips) { tool = .voice }
        LDToolItem(title: "Audio FX", icon: "waveform.circle",
                   active: editor.audioReactive != nil,
                   enabled: !editor.audioTracks.isEmpty) { tool = .audioReactive }
        LDToolItem(title: "Captions", icon: "captions.bubble", enabled: hasClips) { tool = .captions }
        LDToolItem(title: "Template", icon: "wand.and.stars", enabled: hasClips) { tool = .template }
        LDToolItem(title: "Canvas", icon: "aspectratio", enabled: hasClips) { tool = .canvas }
        LDToolItem(title: "Spot", icon: "circle.dashed.inset.filled", enabled: hasClips) {
            if editor.selectedClipID == nil { editor.selectedClipID = editor.clips.first?.id }
            tool = .mask
        }
        LDToolItem(title: "Crop", icon: "crop", enabled: hasClips, action: onOpenCropScreen)
    }

    @ViewBuilder
    private var clipTools: some View {
        let clip = editor.selectedClip
        // Split is only legal strictly INSIDE a clip — `performSplit` rejects a
        // playhead within 0.15 s of either boundary, and `splitAtPlayhead`
        // pushes its undo snapshot BEFORE finding that out. So the button must
        // disable itself rather than silently burn an undo step.
        LDToolItem(title: "Split", icon: "square.split.2x1", enabled: canSplitAtPlayhead) {
            editor.splitAtPlayhead(); LumaHaptics.shared.tap()
        }
        LDToolItem(title: "Trim", icon: "scissors") {
            if let c = clip {
                trimStart = c.trimStart
                trimEnd = c.trimEnd
                trimOriginal = (c.trimStart, c.trimEnd)
            }
            tool = .trim
        }
        LDValueTool(value: String(format: "%g×", clip?.speed ?? 1), label: "Speed",
                    active: (clip?.speed ?? 1) != 1) { tool = .speed }
        LDToolItem(title: "Look", icon: "camera.filters") {
            looksTargetClipID = editor.selectedClipID; tool = .clipLook
        }
        LDToolItem(title: "Motion", icon: "arrow.up.left.and.down.right.magnifyingglass",
                   active: !(clip?.transformKeyframes.isEmpty ?? true)) { tool = .motion }
        LDValueTool(value: "\(Int((clip?.volume ?? 100).rounded()))%", label: "Volume",
                    active: (clip?.isMuted ?? false) || (clip?.volume ?? 100) != 100) { tool = .clipAudio }
        LDToolItem(title: "Frame", icon: "rotate.right") { tool = .geometry }
        LDToolItem(title: "Crop", icon: "crop", action: onOpenCropSheet)
        LDToolItem(title: "Spot", icon: "circle.dashed.inset.filled") { tool = .mask }
        LDToolItem(title: "Freeze", icon: "snowflake") {
            LumaHaptics.shared.tap(); Task { await editor.freezeAtPlayhead() }
        }
        LDToolItem(title: editor.isBaking ? "Reversing" : "Reverse", icon: "backward",
                   enabled: clip?.isImage == false && !editor.isBaking) {
            LumaHaptics.shared.tap(); Task { await editor.reverseSelectedClip() }
        }
        LDToolItem(title: editor.isDetaching ? "Detaching" : "Detach", icon: "waveform.badge.minus",
                   enabled: clip?.hasAudio == true && !editor.isDetaching) {
            guard let id = editor.selectedClipID else { return }
            LumaHaptics.shared.tap(); Task { await editor.detachAudio(clipID: id) }
        }
        LDToolItem(title: "Replace", icon: "arrow.triangle.2.circlepath", action: onReplaceMedia)
        LDToolItem(title: "Duplicate", icon: "plus.square.on.square") {
            editor.duplicateSelected(); LumaHaptics.shared.tap()
        }
        LDToolItem(title: "Copy", icon: "doc.on.doc") {
            editor.copySelected(); app.importToast = "Clip copied"
        }
        LDToolItem(title: "Paste", icon: "doc.on.clipboard",
                   enabled: EditorState.clipboardClip != nil) { editor.pasteClip() }
        LDToolItem(title: "Move ◀", icon: "arrow.left.to.line") { editor.moveSelected(by: -1) }
        LDToolItem(title: "Move ▶", icon: "arrow.right.to.line") { editor.moveSelected(by: 1) }
        LDToolItem(title: "Delete", icon: "trash") { editor.deleteSelected(ripple: true) }
        LDToolItem(title: "Lift", icon: "trash.slash") { editor.deleteSelected(ripple: false) }
    }

    // MARK: Instruction sentences

    private var instruction: String {
        switch tool {
        case .none:          return ""
        case .looks:         return "Choose a look for the whole edit"
        case .clipLook:      return "Choose a look for this clip"
        case .sticker:       return "Tap a sticker to drop it at the playhead"
        case .shape:         return "Pick a shape to add"
        case .effects:       return "Add an effect, then set its strength"
        case .particles:     return "Add particles, then set their density"
        case .adjLayer:      return "Grade a span of the timeline"
        case .template:      return "Pick a template to restyle the cut"
        case .canvas:        return "Set the frame this project renders into"
        case .captions:      return "Transcribe speech into text overlays"
        case .audioReactive: return "Let the sound drive the picture"
        case .audioAdd:      return "Add music, sound effects or a file"
        case .voice:         return "Record a voiceover over the timeline"
        case .trim:          return "Set where this clip starts and ends"
        case .speed:         return "Set the speed of this clip"
        case .motion:        return "Add a pan or zoom to this clip"
        case .mask:          return "Blur, pixelate or fill a spot"
        case .transition:    return "Choose what happens at this cut"
        case .clipAudio:     return "Balance this clip's own sound"
        case .geometry:      return "Rotate or mirror this clip"
        case .overlay:       return "Place and style this overlay"
        case .music:         return "Shape this audio lane"
        }
    }

    // MARK: Panel body

    @ViewBuilder
    private func panelBody(height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch tool {
                case .none:          EmptyView()
                case .looks:         looksPanel(clipID: nil)
                case .clipLook:      looksPanel(clipID: editor.selectedClipID)
                case .sticker:       LDStickerPanel(editor: editor)
                case .shape:         shapePanel
                case .effects:       LDEffectsPanel(editor: editor, particles: false)
                case .particles:     LDEffectsPanel(editor: editor, particles: true)
                case .adjLayer:      adjustmentPanel
                case .template:      templatePanel
                case .canvas:        LDCanvasPanel(editor: editor)
                case .captions:      captionsPanel
                case .audioReactive: LDAudioReactivePanel(editor: editor)
                case .audioAdd:      audioAddPanel
                case .voice:         voicePanel
                case .trim:          trimPanel
                case .speed:         LDSpeedPanel(editor: editor)
                case .motion:        LDMotionPanel(editor: editor)
                case .mask:          LDMaskPanel(editor: editor)
                case .transition:    LDTransitionPanel(editor: editor, afterClipID: transitionAfterID)
                case .clipAudio:     clipAudioPanel
                case .geometry:      geometryPanel
                case .overlay:       LDOverlayPanel(editor: editor, overlayID: selectedOverlayID)
                case .music:         LDMusicPanel(editor: editor, trackID: selectedAudioID,
                                                  onOpenMixer: onOpenMixer)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: height)
    }

    // MARK: Looks (whole edit, or one clip) — real graded tiles

    @ViewBuilder
    private func looksPanel(clipID: UUID?) -> some View {
        LDCaption(clipID == nil ? "Look for the whole edit" : "Look for this clip")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                noneTile(clipID: clipID)
                ForEach(app.library.stripLooks()) { look in
                    Button {
                        // Picking a look while the edit is graded OFF has to
                        // bring the strength back, or the tile reads as dead.
                        if clipID == nil, app.settings.intensity == 0 {
                            app.settings.intensity = stashedIntensity ?? 75
                            stashedIntensity = nil
                        }
                        app.select(look: look, forClip: clipID)
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let cg = thumbs.images[LookThumbs.key(look)] {
                                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color(white: 0.12)
                                }
                            }
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            // clipShape clips PIXELS, not TOUCHES: without this
                            // the overflowing fill steals its neighbour's taps.
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if storeService.isLocked(look) { LookLockGlyph(compact: true) }
                            }
                            .overlay {
                                if isLookActive(look, clipID: clipID) {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 2)
                                }
                            }
                            Text(look.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isLookActive(look, clipID: clipID)
                                                 ? Color.white : .white.opacity(0.55))
                                .lineLimit(1).frame(width: 68)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
                allLooksTile(clipID: clipID)
            }
            .padding(.trailing, 24)
        }
        .lumaEdgeFade(leading: 0, trailing: 16)
        if let clipID, let grade = editor.clips.first(where: { $0.id == clipID })?.grade {
            LDAction(title: "Apply this look to every clip", icon: "square.stack.3d.down.right") {
                editor.applyGradeToAllClips(grade)
                LumaHaptics.shared.tap()
            }
        }
    }

    /// The whole library — chips, search, LUT import — one tap away.
    private func allLooksTile(clipID: UUID?) -> some View {
        Button {
            looksTargetClipID = clipID
            onOpenLookBrowser()
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    LumaTheme.surface
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("All looks").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1).frame(width: 68)
            }
        }
        .buttonStyle(.lumaPress)
    }

    /// The whole-edit "None" tile stashes the strength, zeroes it (which
    /// genuinely neutralises the grade, since the compositor reads
    /// `lookState.settings`), and restores it on the next tap.
    private func noneTile(clipID: UUID?) -> some View {
        let active: Bool = {
            if let clipID { return editor.clips.first(where: { $0.id == clipID })?.grade == nil }
            return app.settings.intensity == 0
        }()
        return Button {
            if let clipID {
                editor.setClipGrade(id: clipID, nil)
            } else if active {
                app.settings.intensity = stashedIntensity ?? 75
                stashedIntensity = nil
            } else {
                stashedIntensity = app.settings.intensity
                app.settings.intensity = 0
                // Per-clip overrides would out-vote the off state, so clear them.
                editor.applyGradeToAllClips(nil)
            }
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color(white: 0.12)
                    Image(systemName: "circle.slash")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white, lineWidth: 2)
                    }
                }
                Text("None").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? Color.white : .white.opacity(0.55))
                    .frame(width: 68)
            }
        }
        .buttonStyle(.lumaPress)
    }

    /// One selection truth: per-clip grade when a clip is targeted, the global
    /// grade state otherwise. Matches every source a look can come from.
    private func isLookActive(_ look: LibraryLook, clipID: UUID?) -> Bool {
        if let clipID {
            guard let g = editor.clips.first(where: { $0.id == clipID })?.grade else { return false }
            switch look.source {
            case .builtIn(let p): return g.lutID == nil && g.baseLookName == p.name
            case .lut(let f):     return g.lutID == f.id
            case .saved(let s):   return g.baseLookName == s.baseLookName && g.lutID == s.lutID
            }
        }
        return app.isCurrent(look)
    }

    // MARK: Shapes

    @ViewBuilder
    private var shapePanel: some View {
        LDCaption("Shape")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(ShapeKind.allCases, id: \.self) { kind in
                Button {
                    if let id = editor.addShapeOverlay(kind: kind) {
                        selectedOverlayID = id
                        tool = .overlay
                        LumaHaptics.shared.tap()
                    }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: kind.icon).font(.system(size: 18, weight: .light))
                        Text(kind.label).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 66)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.lumaPress)
            }
        }
    }

    // MARK: Adjustment layers

    @ViewBuilder
    private var adjustmentPanel: some View {
        LDCaption("Grade a span", value: "\(editor.adjustmentLayers.count)")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(app.library.stripLooks()) { look in
                    Button {
                        editor.addAdjustmentLayer(grade: look.clipGrade())
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let cg = thumbs.images[LookThumbs.key(look)] {
                                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else { Color(white: 0.12) }
                            }
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                if storeService.isLocked(look) { LookLockGlyph(compact: true) }
                            }
                            Text(look.name).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55)).lineLimit(1).frame(width: 62)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.trailing, 24)
        }
        .lumaEdgeFade(leading: 0, trailing: 16)
        // The strip is the recents/favourites shortlist; the WHOLE library —
        // signature presets, installed packs, imported LUTs, saved looks — is
        // still reachable, exactly as the previous dock menu offered it.
        LDActionMenu(title: "Grade from the whole library", icon: "square.stack.3d.up") {
            ForEach(app.libraryLooksBySection, id: \.section) { group in
                Section(group.section.title) {
                    ForEach(group.looks) { look in
                        Button {
                            editor.addAdjustmentLayer(grade: look.clipGrade())
                            LumaHaptics.shared.tap()
                        } label: { Text(look.name) }
                    }
                }
            }
        }
        ForEach(editor.adjustmentLayers) { layer in
            HStack(spacing: 10) {
                Text(layer.grade.baseLookName.isEmpty ? "LUT" : layer.grade.baseLookName)
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text(LDFormat.secs(layer.duration))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                Button { editor.removeAdjustmentLayer(id: layer.id) } label: {
                    Image(systemName: "trash").font(.system(size: 12, weight: .light))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        if editor.adjustmentLayers.count > 1 {
            LDAction(title: "Clear every adjustment layer", icon: "trash") {
                for layer in editor.adjustmentLayers { editor.removeAdjustmentLayer(id: layer.id) }
                LumaHaptics.shared.tap()
            }
        }
    }

    // MARK: Templates

    @ViewBuilder
    private var templatePanel: some View {
        LDCaption("Template")
        if editor.clips.isEmpty {
            LDNote("Templates restyle clips you already have. Add footage first.")
        }
        ForEach(TemplateLibrary.all) { template in
            Button {
                if editor.applyTemplate(template) {
                    LumaHaptics.shared.tap()
                    closeTool()
                } else { app.importToast = "Add a clip first" }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: template.icon)
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(LumaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        HStack(spacing: 6) {
                            Text(template.aspect)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text("·").foregroundStyle(.white.opacity(0.25))
                            Text("\(template.slots.count) shots").font(.system(size: 12))
                            Text("·").foregroundStyle(.white.opacity(0.25))
                            Text(LDFormat.secs(template.totalDuration))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.lumaPress)
            .opacity(editor.clips.isEmpty ? 0.4 : 1)
            .disabled(editor.clips.isEmpty)
        }
    }

    // MARK: Captions

    @ViewBuilder
    private var captionsPanel: some View {
        LDCaption("Captions")
        LDAction(title: isCaptioning ? "Transcribing…" : "Transcribe speech",
                 icon: "captions.bubble", busy: isCaptioning) {
            isCaptioning = true
            Task {
                let n = await editor.generateCaptions()
                isCaptioning = false
                app.importToast = n == 0
                    ? "No speech found — check Settings › Privacy › Speech Recognition"
                    : "Added \(n) captions"
            }
        }
        LDAction(title: "Copy SRT", icon: "doc.on.doc") {
            UIPasteboard.general.string = editor.captionsSRT()
            app.importToast = "SRT copied"
        }
        LDNote("Captions land as text overlays you can restyle like any other.")
    }

    // MARK: Audio add

    @ViewBuilder
    private var audioAddPanel: some View {
        LDCaption("Sound library")
        LDSoundLibrary(editor: editor)
        LDAction(title: "Import from Files", icon: "folder", action: onImportAudioFile)
        LDAction(title: "Open the project mixer", icon: "slider.horizontal.3", action: onOpenMixer)
    }

    // MARK: Voiceover

    @ViewBuilder
    private var voicePanel: some View {
        LDCaption(editor.isRecordingVoiceover ? "Recording" : "Voiceover")
        HStack(spacing: 3) {
            ForEach(0..<28, id: \.self) { i in
                let lit = Double(i) / 28.0 < editor.inputLevel
                Capsule()
                    .fill(lit ? Color.white : LumaTheme.surfaceStrong)
                    .frame(width: 3, height: 6 + CGFloat(i % 5) * 4)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.08), value: editor.inputLevel)
        LDAction(title: editor.isRecordingVoiceover ? "Stop recording" : "Start recording",
                 icon: editor.isRecordingVoiceover ? "stop.circle" : "mic") {
            if editor.isRecordingVoiceover {
                editor.stopVoiceover()
                LumaHaptics.shared.exportSuccess()
            } else if editor.totalDuration > 0.4 {
                // `startVoiceover` needs picture to record against and returns
                // silently otherwise — explain rather than swallow the tap.
                editor.startVoiceover()
                LumaHaptics.shared.tap()
            } else {
                app.importToast = "Add a video clip first"
            }
        }
        LDNote("Recording plays the timeline back so you can talk to picture. The take lands as its own lane.")
    }

    // MARK: Trim

    @ViewBuilder
    private var trimPanel: some View {
        if let clip = editor.selectedClip {
            LDCaption("Trim", value: LDFormat.secs(max(0, trimEnd - trimStart)))
            LDSlider(label: "Start", value: $trimStart, range: 0...max(0.1, clip.assetDuration),
                     readout: { LDFormat.secs($0) },
                     onCommit: { commitTrim(clip) })
            LDSlider(label: "End", value: $trimEnd, range: 0...max(0.1, clip.assetDuration),
                     readout: { LDFormat.secs($0) },
                     onCommit: { commitTrim(clip) })
            LDNote("The handles on the selected clip in the timeline do the same thing.")
                // trimStart/trimEnd are a LOCAL copy seeded when the tool opens.
                // The mini timeline stays live underneath, so tapping a
                // different clip used to leave the old clip's values in the
                // sliders — and commit them onto the newly selected clip.
                .onChange(of: editor.selectedClipID) { _, _ in
                    guard let c = editor.selectedClip else { return }
                    trimStart = c.trimStart
                    trimEnd = c.trimEnd
                    trimOriginal = (c.trimStart, c.trimEnd)
                }
        }
    }

    private func commitTrim(_ clip: EditorState.Clip) {
        let s = min(trimStart, trimEnd - 0.1)
        let e = max(trimEnd, s + 0.1)
        editor.selectedClipID = clip.id
        editor.applyTrim(start: max(0, s), end: min(clip.assetDuration, e))
    }

    // MARK: Rotate / mirror

    @ViewBuilder
    private var geometryPanel: some View {
        if let clip = editor.selectedClip {
            LDCaption("Frame")
            HStack(spacing: 8) {
                LDChip(title: "Rotate 90°", selected: clip.rotationQuarterTurns != 0) {
                    editor.rotateSelectedClip(); LumaHaptics.shared.tap()
                }
                LDChip(title: "Mirror", selected: clip.isMirrored) {
                    editor.mirrorSelectedClip(); LumaHaptics.shared.tap()
                }
                LDChip(title: "Crop & straighten", action: onOpenCropSheet)
            }
            HStack(spacing: 16) {
                LDCaption("Rotation", value: "\(clip.rotationQuarterTurns * 90)°")
                LDCaption("Straighten", value: "\(Int(clip.straightenDegrees))°")
            }
        }
    }

    // MARK: Clip sound

    @ViewBuilder
    private var clipAudioPanel: some View {
        if let clip = editor.selectedClip {
            LDCaption("Clip sound", value: LDFormat.secs(clip.timelineDuration))
            LDSlider(label: "Volume",
                     value: Binding(get: { clip.volume },
                                    set: { editor.setClipVolume(id: clip.id, $0) }),
                     range: 0...100, readout: { "\(Int($0))%" })
            HStack(spacing: 8) {
                LDChip(title: clip.isMuted ? "Unmute clip" : "Mute clip", selected: clip.isMuted) {
                    editor.setClipMuted(id: clip.id, !clip.isMuted)
                }
                LDChip(title: editor.isDetaching ? "Detaching…" : "Detach audio",
                       enabled: clip.hasAudio && !editor.isDetaching) {
                    Task { await editor.detachAudio(clipID: clip.id) }
                }
            }
            if !clip.hasAudio {
                LDNote("This clip has no audio track of its own.")
            }
            LDAction(title: "Open the project mixer", icon: "slider.horizontal.3", action: onOpenMixer)
        }
    }

    // MARK: Plumbing

    private func addText() {
        let before = Set(editor.overlays.map(\.id))
        // ✕ on the panel this opens should take the new text away too.
        editor.prepareToolSessionForAdd()
        editor.addTextOverlay()
        if let added = editor.overlays.first(where: { !before.contains($0.id) }) {
            selectedOverlayID = added.id
            tool = .overlay
        } else {
            app.importToast = "Add a video clip first"
        }
    }

    /// Select the clip under the playhead so its tools appear without hunting
    /// for a tap target.
    private func selectClipAtPlayhead() {
        guard !editor.isEmpty else { return }
        var elapsed: Double = 0
        for clip in editor.clips {
            elapsed += clip.timelineDuration
            if editor.currentTime < elapsed { editor.selectedClipID = clip.id; return }
        }
        editor.selectedClipID = editor.clips.last?.id
    }
}

// MARK: - Sound library (with audition)

/// The bundled library, inline. The audition button is carried over from the
/// old Sound Library sheet: pausing the timeline first means the preview and
/// the composition never talk over each other.
private struct LDSoundLibrary: View {
    @ObservedObject var editor: EditorState
    @StateObject private var preview = AudioPreviewPlayer()
    @State private var auditioning: String?
    @State private var category = "sfx"

    private var entries: [BundledAudioEntry] { BundledAudioLibrary.entries(category: category) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LDChip(title: "Sound effects", selected: category == "sfx") { category = "sfx" }
                LDChip(title: "Music", selected: category == "music") { category = "music" }
            }
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Button {
                        if auditioning == entry.id {
                            preview.stop(); auditioning = nil
                        } else if let url = BundledAudioLibrary.url(for: entry) {
                            // Two players over one pair of ears is noise.
                            if editor.isPlaying { editor.togglePlayback() }
                            preview.play(url); auditioning = entry.id
                        }
                    } label: {
                        Image(systemName: auditioning == entry.id ? "stop.fill" : "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(auditioning == entry.id ? Color.black : Color.white)
                            .frame(width: 28, height: 28)
                            .background(auditioning == entry.id ? AnyShapeStyle(Color.white)
                                                               : AnyShapeStyle(LumaTheme.surfaceStrong),
                                        in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.lumaPress)

                    Text(entry.title)
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(LDFormat.secs(entry.duration))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                    Button {
                        guard let url = BundledAudioLibrary.url(for: entry) else { return }
                        guard let imported = editor.importMusicFile(from: url) else { return }
                        LumaHaptics.shared.tap()
                        Task {
                            await editor.addAudioTrack(importedURL: imported, title: entry.title,
                                                       kind: entry.category == "sfx" ? .sfx : .music)
                        }
                    } label: {
                        Text("Add")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(Color.white, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .onDisappear { preview.stop(); auditioning = nil }
    }
}

// MARK: - Speed

private struct LDSpeedPanel: View {
    @ObservedObject var editor: EditorState

    private let presets: [Double] = [0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("Constant speed")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(presets, id: \.self) { speed in
                    let on = editor.selectedClip?.speed == speed
                    Button {
                        editor.setClipSpeed(speed); LumaHaptics.shared.tap()
                    } label: {
                        Text(String(format: "%g×", speed))
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundStyle(on ? Color.white : .white.opacity(0.7))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                if on {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 1.2)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.lumaPress)
                }
            }

            LDCaption("Speed ramp")
            // Each ramp draws its own curve — the tile shows what it does.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EditorState.SpeedRamp.allCases, id: \.self) { ramp in
                        let on = editor.selectedClip?.speedRamp == ramp.rawValue
                        Button {
                            editor.setSpeedRamp(ramp); LumaHaptics.shared.tap()
                        } label: {
                            VStack(spacing: 6) {
                                LDRampCurve(ramp: ramp)
                                    .frame(width: 62, height: 30)
                                Text(ramp.label).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(on ? Color.white : .white.opacity(0.55))
                                    .lineLimit(1).frame(width: 62)
                            }
                            .padding(6)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                if on {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 1.2)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.trailing, 24)
            }
            .lumaEdgeFade(leading: 0, trailing: 16)

            LDNote("Audio is pitch-preserved at every speed.")
        }
    }
}

/// The ramp's real `speed(at:)` curve, plotted. Not an icon.
private struct LDRampCurve: View {
    let ramp: EditorState.SpeedRamp

    var body: some View {
        GeometryReader { geo in
            Path { p in
                let n = 24
                for i in 0...n {
                    let t = Double(i) / Double(n)
                    let s = ramp.speed(at: t)
                    let y = geo.size.height * (1 - CGFloat(min(max(s / 4, 0), 1)))
                    let pt = CGPoint(x: geo.size.width * CGFloat(t), y: y)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(Color.white.opacity(0.8), lineWidth: 1.4)
        }
    }
}

// MARK: - Motion

private struct LDMotionPanel: View {
    @ObservedObject var editor: EditorState

    /// `Clip` stores no preset name — only the keyframes a preset generated. So
    /// the active preset is recovered by regenerating each preset's curve for
    /// this clip's duration and matching the endpoints. Without this every chip
    /// rendered unselected forever, whatever the clip was doing.
    private var activePreset: EditorState.KenBurnsPreset? {
        guard let clip = editor.selectedClip else { return nil }
        let kfs = clip.transformKeyframes
        if kfs.isEmpty { return EditorState.KenBurnsPreset.none }
        guard let first = kfs.first, let last = kfs.last else { return nil }
        return EditorState.KenBurnsPreset.allCases.first { preset in
            let ref = preset.keyframes(duration: clip.timelineDuration)
            guard let rf = ref.first, let rl = ref.last else { return false }
            func same(_ a: ClipTransformKeyframe, _ b: ClipTransformKeyframe) -> Bool {
                abs(a.zoom - b.zoom) < 0.01
                    && abs(a.centerX - b.centerX) < 0.01
                    && abs(a.centerY - b.centerY) < 0.01
            }
            return same(first, rf) && same(last, rl)
        }
    }

    private var activeEasing: KeyframeEasing? {
        guard let raw = editor.selectedClip?.transformKeyframes.first?.easing else { return nil }
        return KeyframeEasing(rawValue: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("Pan & zoom")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(EditorState.KenBurnsPreset.allCases, id: \.self) { preset in
                    LDChip(title: preset.label, selected: activePreset == preset) {
                        guard let id = editor.selectedClipID else { return }
                        editor.setKenBurns(id: id, preset: preset,
                                           easing: activeEasing ?? .easeInOut)
                        LumaHaptics.shared.tap()
                    }
                }
            }
            if let clip = editor.selectedClip, !clip.transformKeyframes.isEmpty {
                LDCaption("Easing")
                HStack(spacing: 8) {
                    ForEach(KeyframeEasing.allCases, id: \.self) { ease in
                        LDChip(title: ease.label, selected: activeEasing == ease) {
                            editor.setKenBurnsEasing(id: clip.id, easing: ease)
                            LumaHaptics.shared.tap()
                        }
                    }
                }
                LDCaption("Keyframes", value: "\(clip.transformKeyframes.count)")
            }
        }
    }
}

// MARK: - Transition

private struct LDTransitionPanel: View {
    @ObservedObject var editor: EditorState
    let afterClipID: UUID?

    private var current: TransitionStyle {
        guard let id = afterClipID else { return .none }
        return editor.clips.first { $0.id == id }?.transitionAfter ?? .none
    }

    private var currentDuration: Double {
        guard let id = afterClipID else { return 0.6 }
        return editor.clips.first { $0.id == id }?.transitionDuration ?? current.duration
    }

    /// The cut this panel edits still has to exist — the id is captured when a
    /// transition chip is tapped, and a delete/undo can outlive it. Every
    /// setter guards on the clip, so a stale id turned the grid into dead
    /// pixels; say so instead.
    private var cutExists: Bool {
        guard let id = afterClipID else { return false }
        return editor.clips.contains { $0.id == id }
    }

    var body: some View {
        if !cutExists {
            LDNote("That cut is no longer on the timeline. Tap a diamond between two clips to choose its transition.")
        } else {
            grid
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(["Basic", "Motion", "FX"], id: \.self) { group in
                let styles = TransitionStyle.allCases.filter { $0.category == group }
                if !styles.isEmpty {
                    LDCaption(group)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(styles, id: \.self) { style in
                            let on = current == style
                            Button {
                                guard let id = afterClipID else { return }
                                editor.setTransition(afterClipID: id, style: style, duration: currentDuration)
                                LumaHaptics.shared.tap()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: style.icon)
                                        .font(.system(size: 15, weight: .light))
                                    Text(style.label).font(.system(size: 11, weight: .medium))
                                        .lineLimit(1).minimumScaleFactor(0.85)
                                }
                                .foregroundStyle(on ? Color.white : LumaTheme.textSecondary)
                                .frame(maxWidth: .infinity).frame(height: 56)
                                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay {
                                    if on {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(Color.white, lineWidth: 1.2)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.lumaPress)
                        }
                    }
                }
            }

            LDCaption("Duration")
            HStack(spacing: 8) {
                ForEach([0.3, 0.6, 1.0, 1.5], id: \.self) { seconds in
                    LDChip(title: String(format: "%gs", seconds),
                           selected: abs(currentDuration - seconds) < 0.01) {
                        guard let id = afterClipID else { return }
                        editor.setTransition(afterClipID: id, style: current, duration: seconds)
                        LumaHaptics.shared.tap()
                    }
                }
            }

            if current != .none, editor.clips.count > 2 {
                LDAction(title: "Use this transition at every cut", icon: "arrow.triangle.branch") {
                    editor.setTransitionForAllCuts(style: current, duration: currentDuration)
                    LumaHaptics.shared.tap()
                }
            }
        }
    }
}

// MARK: - Spot mask

private struct LDMaskPanel: View {
    @ObservedObject var editor: EditorState

    private var clip: EditorState.Clip? { editor.selectedClip ?? editor.clips.first }
    private var shape: ClipMaskShape? { ClipMaskShape(rawValue: clip?.maskShape ?? "") }
    private var effect: ClipMaskEffect {
        ClipMaskEffect(rawValue: clip?.maskEffect ?? "") ?? .blur
    }

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 16) {
                LDCaption("Shape")
                HStack(spacing: 8) {
                    ForEach(ClipMaskShape.allCases, id: \.self) { s in
                        LDChip(title: s.label, selected: shape == s) {
                            editor.setClipMask(id: clip.id, shape: shape == s ? nil : s)
                            LumaHaptics.shared.tap()
                        }
                    }
                    if shape != nil {
                        LDChip(title: "Clear") {
                            editor.setClipMask(id: clip.id, shape: nil)
                            LumaHaptics.shared.tap()
                        }
                    }
                }

                if let shape {
                    LDCaption("Effect")
                    HStack(spacing: 8) {
                        ForEach(ClipMaskEffect.allCases, id: \.self) { e in
                            LDChip(title: e.label, selected: effect == e) {
                                editor.setClipMask(id: clip.id, shape: shape, effect: e)
                            }
                        }
                        LDChip(title: "Invert", selected: clip.maskInverted) {
                            editor.setClipMask(id: clip.id, shape: shape, inverted: !clip.maskInverted)
                        }
                    }

                    // setClipMask snapshots undo AND rebuilds on every call, so
                    // these commit on release rather than per gesture tick.
                    LDCommitSlider(label: effect == .fill ? "Opacity" : "Strength",
                                   initial: clip.maskAmount, range: 0...1,
                                   readout: { "\(Int($0 * 100))%" }) {
                        editor.setClipMask(id: clip.id, shape: shape, amount: $0)
                    }
                    LDCommitSlider(label: "Size", initial: clip.maskWidth, range: 0.05...1.0,
                                   readout: { "\(Int($0 * 100))%" }) {
                        editor.setClipMask(id: clip.id, shape: shape,
                                           size: CGSize(width: $0, height: $0))
                    }
                    LDCommitSlider(label: "Feather", initial: clip.maskFeather, range: 0...0.3,
                                   readout: { "\(Int($0 * 100))%" }) {
                        editor.setClipMask(id: clip.id, shape: shape, feather: $0)
                    }
                    LDCaption("Position")
                    LDPositionPad(point: CGPoint(x: clip.maskCenterX, y: clip.maskCenterY),
                                  onCommit: { pt in
                                      editor.setClipMask(id: clip.id, shape: shape, center: pt)
                                  })
                } else {
                    LDNote("Pick a shape to blur, pixelate or block out part of the frame.")
                }
            }
        }
    }
}

// MARK: - Stickers

private struct LDStickerPanel: View {
    @ObservedObject var editor: EditorState
    @State private var category = 0
    @State private var busy = false

    private var categories: [(name: String, emojis: [String])] { StickerBaker.emojiCategories }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                        LDChip(title: cat.name, selected: idx == category) { category = idx }
                    }
                }
                .padding(.trailing, 24)
            }
            .lumaEdgeFade(leading: 0, trailing: 16)

            if categories.indices.contains(category) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(categories[category].emojis, id: \.self) { emoji in
                        Button {
                            busy = true
                            Task {
                                let ok = await editor.addSticker(emoji: emoji)
                                busy = false
                                if ok { LumaHaptics.shared.tap() }
                            }
                        } label: {
                            Text(emoji).font(.system(size: 25))
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.lumaPress)
                        .disabled(busy)
                    }
                }
                .opacity(busy ? 0.5 : 1)
            }
        }
    }
}

// MARK: - Effects & particles

private struct LDEffectsPanel: View {
    @ObservedObject var editor: EditorState
    let particles: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption(particles ? "Particles" : "Effects")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                if particles {
                    ForEach(ParticleKind.allCases, id: \.self) { kind in
                        tile(kind.label, kind.icon) {
                            editor.addParticleLayer(kind: kind); LumaHaptics.shared.tap()
                        }
                    }
                } else {
                    ForEach(EffectKind.allCases, id: \.self) { kind in
                        tile(kind.label, kind.icon) {
                            editor.addEffectLayer(kind: kind); LumaHaptics.shared.tap()
                        }
                    }
                }
            }

            if particles {
                ForEach(editor.particleLayers) { layer in
                    row(title: ParticleKind(rawValue: layer.kind)?.label ?? layer.kind,
                        offset: layer.timelineOffset,
                        intensity: layer.intensity,
                        setIntensity: { editor.setParticleIntensity(id: layer.id, $0) },
                        remove: { editor.removeParticleLayer(id: layer.id) })
                }
            } else {
                ForEach(editor.effectLayers) { layer in
                    row(title: EffectKind(rawValue: layer.kind)?.label ?? layer.kind,
                        offset: layer.timelineOffset,
                        intensity: layer.intensity,
                        setIntensity: { editor.setEffectIntensity(id: layer.id, $0) },
                        remove: { editor.removeEffectLayer(id: layer.id) })
                }
            }
        }
    }

    private func tile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 17, weight: .light))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.lumaPress)
    }

    private func row(title: String, offset: Double,
                     intensity: Double, setIntensity: @escaping (Double) -> Void,
                     remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text("at \(LDFormat.secs(offset))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Button(action: remove) {
                    Image(systemName: "trash").font(.system(size: 12, weight: .light))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.lumaPress)
            }
            LDCommitSlider(label: "Strength", initial: intensity, range: 0...1,
                           commit: setIntensity)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Canvas / format

private struct LDCanvasPanel: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("Format")
            HStack(spacing: 8) {
                ForEach(EditorFormat.allCases, id: \.self) { f in
                    LDChip(title: f.rawValue, selected: editor.format == f) {
                        editor.setFormat(f, zoom: editor.zoom); LumaHaptics.shared.tap()
                    }
                }
            }
            LDCaption("Canvas")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(CanvasBackgroundMode.allCases, id: \.self) { mode in
                    LDChip(title: mode.rawValue.capitalized, selected: editor.canvasMode == mode) {
                        editor.setCanvasMode(mode); LumaHaptics.shared.tap()
                    }
                }
            }
            LDCommitSlider(label: "Canvas zoom", initial: editor.zoom,
                           range: 100...200, readout: { "\(Int($0))%" },
                           commit: { editor.setFormat(editor.format, zoom: $0) })
            LDCaption("Frame")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(FramePreset.allCases, id: \.self) { preset in
                    LDChip(title: preset.label, selected: editor.framePreset == preset.rawValue) {
                        editor.setFramePreset(preset); LumaHaptics.shared.tap()
                    }
                }
            }
        }
    }
}

// MARK: - Audio-reactive

private struct LDAudioReactivePanel: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LDCaption("Driven by sound")
            HStack(spacing: 8) {
                LDChip(title: "Off", selected: editor.audioReactive == nil) {
                    editor.setAudioReactive(nil); LumaHaptics.shared.tap()
                }
                ForEach(AudioReactiveStyle.allCases, id: \.self) { style in
                    LDChip(title: style.label, selected: editor.audioReactive?.style == style) {
                        editor.setAudioReactive(.init(style: style,
                                                      strength: editor.audioReactive?.strength ?? 1.0,
                                                      sourceTrackID: editor.audioReactive?.sourceTrackID
                                                        ?? editor.audioTracks.first?.id))
                        LumaHaptics.shared.tap()
                    }
                }
            }
            if let config = editor.audioReactive {
                LDSlider(label: "Strength",
                         value: Binding(get: { config.strength },
                                        set: { editor.setAudioReactive(.init(style: config.style,
                                                                             strength: $0,
                                                                             sourceTrackID: config.sourceTrackID)) }),
                         range: 0...2)
                LDCaption("Source lane")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(editor.audioTracks) { track in
                            LDChip(title: track.title, selected: config.sourceTrackID == track.id) {
                                editor.setAudioReactive(.init(style: config.style,
                                                              strength: config.strength,
                                                              sourceTrackID: track.id))
                            }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .lumaEdgeFade(leading: 0, trailing: 16)
            }
        }
    }
}

// MARK: - Overlay panel

private struct LDOverlayPanel: View {
    @ObservedObject var editor: EditorState
    let overlayID: UUID?

    private enum Section: String, CaseIterable {
        case place = "Place", text = "Text", pip = "PIP", blend = "Blend"
        case chroma = "Chroma", mask = "Mask", adjust = "Adjust", border = "Border"
        case motion = "Motion", sound = "Sound"
    }

    @State private var section: Section = .place
    @State private var draftText = ""

    private static let swatches = ["#FFFFFF", "#000000", "#F5C518", "#FF5C5C", "#7A68EE", "#3EC8AC"]

    private var item: EditorState.OverlayItem? {
        guard let overlayID else { return nil }
        return editor.overlays.first { $0.id == overlayID }
    }

    private var sections: [Section] {
        guard let item else { return [] }
        var s: [Section] = [.place]
        if item.text != nil { s.append(.text) }
        if !item.isImage || item.text == nil { s.append(contentsOf: [.pip, .blend, .chroma, .mask, .adjust, .border]) }
        s.append(contentsOf: [.motion, .sound])
        return s
    }

    var body: some View {
        if let item, let id = overlayID {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sections, id: \.self) { s in
                            LDChip(title: s.rawValue, selected: section == s) { section = s }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .lumaEdgeFade(leading: 0, trailing: 16)

                // `section` is @State and the view keeps its identity when you
                // tap a different overlay bar, so leaving Chroma selected on a
                // video overlay and then opening a TEXT overlay used to render
                // green-screen controls under a chip row that did not list them.
                // Clamp the section to what this overlay actually supports.
                switch sections.contains(section) ? section : .place {
                case .place:  place(item, id)
                case .text:   text(item, id)
                case .pip:    pip(id)
                case .blend:  blend(item, id)
                case .chroma: chroma(item, id)
                case .mask:   mask(item, id)
                case .adjust: adjust(item, id)
                case .border: border(item, id)
                case .motion: motion(item, id)
                case .sound:  sound(item, id)
                }

                LDAction(title: "Remove overlay", icon: "trash") {
                    editor.removeOverlay(id: id)
                    LumaHaptics.shared.tap()
                }
            }
            .onAppear { draftText = item.text ?? "" }
            .onChange(of: overlayID) { _, _ in
                draftText = item.text ?? ""
                if !sections.contains(section) { section = .place }
            }
        } else {
            LDNote("Select an overlay on the timeline.")
        }
    }

    // MARK: sections

    @ViewBuilder
    private func place(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDSlider(label: "Opacity",
                 value: Binding(get: { item.opacity * 100 },
                                set: { editor.setOverlayOpacity(id: id, $0 / 100) }),
                 range: 0...100, readout: { "\(Int($0))%" })
        LDSlider(label: "Size",
                 value: Binding(get: { item.sizeFraction * 100 },
                                set: { editor.setOverlaySize(id: id, $0 / 100) }),
                 range: 25...100, readout: { "\(Int($0))%" })
        LDSlider(label: "Rotation",
                 value: Binding(get: { item.rotationDegrees },
                                set: { editor.setOverlayRotation(id: id, $0) }),
                 range: -180...180, readout: { "\(Int($0))°" })
        // A shape's fill is CONTENT colour — the one thing allowed to be
        // coloured on this screen.
        if item.shapeKind != nil {
            LDCaption("Fill")
            HStack(spacing: 9) {
                ForEach(Self.swatches, id: \.self) { hex in
                    Button { editor.setShapeDecor(id: id, fillHex: .some(hex)) } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay {
                                if (item.shapeFillHex ?? "").uppercased() == hex.uppercased() {
                                    Circle().strokeBorder(Color.white, lineWidth: 2)
                                } else {
                                    Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
        }
        // Position is a DIRECT gesture on the picture now. The drag pad and the
        // nine anchor tiles were a widget standing in for a finger on a
        // touchscreen; the sliders above stay because they are the only way to
        // set an exact size or angle. "Centre" earns its place — it is the one
        // placement that is fiddly to hit by hand.
        LDCaption("Position")
        LDNote("Drag the layer on the picture to move it. Pinch to resize, twist to rotate.")
        HStack(spacing: 8) {
            LDChip(title: "Centre") {
                editor.setOverlayCenter(id: id, CGPoint(x: 0.5, y: 0.5))
                LumaHaptics.shared.tap()
            }
            LDChip(title: "Reset angle", enabled: abs(item.rotationDegrees) > 0.01) {
                editor.setOverlayRotation(id: id, 0)
                LumaHaptics.shared.tap()
            }
        }
        LDCaption("Stacking layer", value: "\(item.lane + 1)")
        HStack(spacing: 8) {
            LDChip(title: "Send back", enabled: item.lane > 0) { editor.nudgeOverlayLane(id: id, by: -1) }
            LDChip(title: "Bring forward") { editor.nudgeOverlayLane(id: id, by: 1) }
        }
        LDCaption("Trim")
        HStack(spacing: 8) {
            LDChip(title: "Head −0.2s") { editor.trimOverlayHead(id: id, deltaSeconds: -0.2) }
            LDChip(title: "Head +0.2s") { editor.trimOverlayHead(id: id, deltaSeconds: 0.2) }
            LDChip(title: "Tail −0.2s") { editor.trimOverlayTail(id: id, deltaSeconds: -0.2) }
            LDChip(title: "Tail +0.2s") { editor.trimOverlayTail(id: id, deltaSeconds: 0.2) }
        }
    }

    @ViewBuilder
    private func text(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("Content")
        TextField("", text: $draftText, axis: .vertical)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .tint(.white)
            .lineLimit(1...3)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onSubmit { editor.setOverlayText(id: id, draftText) }
            .onChange(of: draftText) { _, new in editor.setOverlayText(id: id, new) }

        LDCaption("Style")
        HStack(spacing: 8) {
            ForEach(EditorState.TextLayerStyle.allCases, id: \.self) { style in
                LDChip(title: style.label, selected: item.textStyle == style) {
                    editor.setOverlayTextStyle(id: id, style)
                }
            }
        }

        LDCaption("Colour")
        HStack(spacing: 9) {
            ForEach(Self.swatches, id: \.self) { hex in
                Button { editor.setOverlayTextColor(id: id, hex) } label: {
                    Circle().fill(Color(hex: hex))
                        .frame(width: 26, height: 26)
                        .overlay {
                            if item.textColorHex.uppercased() == hex.uppercased() {
                                Circle().strokeBorder(Color.white, lineWidth: 2)
                            } else {
                                Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.lumaPress)
            }
        }

        LDCaption("Align")
        HStack(spacing: 8) {
            ForEach(["left", "center", "right"], id: \.self) { align in
                LDChip(title: align.capitalized, selected: item.textAlignment == align) {
                    editor.setTextDecor(id: id, alignment: align)
                }
            }
        }

        LDCaption("Font")
        Menu {
            Button("Preset font") { editor.setTextDecor(id: id, fontName: .some(nil)) }
            ForEach(FontLibrary.builtInFontNames, id: \.self) { name in
                Button(name) { editor.setTextDecor(id: id, fontName: .some(name)) }
            }
        } label: {
            HStack {
                Text(item.textFontName ?? "Preset font")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        LDCaption("Decoration")
        HStack(spacing: 8) {
            LDChip(title: "Outline", selected: item.textStrokeHex != nil) {
                editor.setTextDecor(id: id,
                                    strokeHex: item.textStrokeHex == nil ? .some("#000000") : .some(nil),
                                    strokeWidth: item.textStrokeHex == nil ? 2 : 0)
            }
            LDChip(title: "Box", selected: item.textBoxHex != nil) {
                editor.setTextDecor(id: id, boxHex: item.textBoxHex == nil ? .some("#000000") : .some(nil))
            }
        }
        if item.textStrokeHex != nil {
            // Starts at 1, not 0: a zero-width outline under a chip that reads
            // "on" is a control that lies about its own state.
            LDCommitSlider(label: "Outline width", initial: max(1, item.textStrokeWidth),
                           range: 1...12, readout: { String(format: "%.1f", $0) },
                           commit: { editor.setTextDecor(id: id, strokeWidth: $0) })
        }

        LDCaption("Animation")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(TextAnimation.allCases, id: \.self) { preset in
                LDChip(title: preset.label, selected: item.textAnimation == preset.rawValue) {
                    editor.setTextAnimation(id: id, preset)
                }
            }
        }
    }

    @ViewBuilder
    private func pip(_ id: UUID) -> some View {
        LDCaption("Picture-in-picture layout")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(PipPreset.all) { preset in
                Button {
                    editor.applyPipPreset(id: id, preset); LumaHaptics.shared.tap()
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: preset.icon).font(.system(size: 16, weight: .light))
                        Text(preset.name).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 62)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.lumaPress)
            }
        }
    }

    @ViewBuilder
    private func blend(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("Blend mode")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(OverlayBlendMode.allCases, id: \.self) { mode in
                LDChip(title: mode.label, selected: item.effects.blendMode == mode) {
                    editor.setOverlayBlendMode(id: id, mode)
                }
            }
        }
    }

    @ViewBuilder
    private func chroma(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        let chroma = item.effects.chroma
        LDCaption("Green screen")
        LDChip(title: chroma == nil ? "Off" : "On", selected: chroma != nil) {
            editor.setOverlayChroma(id: id, chroma == nil ? ChromaKeySettings() : nil)
        }
        if let chroma {
            LDCaption("Key colour")
            HStack(spacing: 9) {
                ForEach(["#00FF00", "#0000FF", "#00FFFF", "#FF00FF"], id: \.self) { hex in
                    Button {
                        var c = chroma; c.colorHex = hex
                        editor.setOverlayChroma(id: id, c)
                    } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 26, height: 26)
                            .overlay {
                                if chroma.colorHex.uppercased() == hex {
                                    Circle().strokeBorder(Color.white, lineWidth: 2)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            LDSlider(label: "Tolerance",
                     value: Binding(get: { chroma.tolerance * 100 },
                                    set: { var c = chroma; c.tolerance = $0 / 100
                                           editor.setOverlayChroma(id: id, c, snapshot: false) }),
                     range: 5...80, readout: { "\(Int($0))" })
            LDSlider(label: "Softness",
                     value: Binding(get: { chroma.softness * 100 },
                                    set: { var c = chroma; c.softness = $0 / 100
                                           editor.setOverlayChroma(id: id, c, snapshot: false) }),
                     range: 0...40, readout: { "\(Int($0))" })
        }
    }

    @ViewBuilder
    private func mask(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("Overlay mask")
        let m = item.effects.mask
        HStack(spacing: 8) {
            ForEach([("none", "None"), ("rect", "Rect"), ("roundedRect", "Rounded"),
                     ("ellipse", "Circle"), ("linear", "Fade")], id: \.0) { pair in
                LDChip(title: pair.1,
                       selected: pair.0 == "none" ? m == nil : m?.shape == pair.0) {
                    if pair.0 == "none" { editor.setOverlayMask(id: id, nil) }
                    else {
                        var s = m ?? OverlayMaskSettings()
                        s.shape = pair.0
                        editor.setOverlayMask(id: id, s)
                    }
                }
            }
        }
        if let m {
            LDSlider(label: "Feather",
                     value: Binding(get: { m.feather * 100 },
                                    set: { var s = m; s.feather = $0 / 100
                                           editor.setOverlayMask(id: id, s, snapshot: false) }),
                     range: 0...40, readout: { "\(Int($0))" })
            LDChip(title: "Invert", selected: m.invert) {
                var s = m; s.invert.toggle(); editor.setOverlayMask(id: id, s)
            }
        }
    }

    @ViewBuilder
    private func adjust(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        let a = item.effects.adjust ?? OverlayAdjustments()
        LDCaption("Adjust")
        LDSlider(label: "Exposure",
                 value: Binding(get: { a.exposure * 100 },
                                set: { var v = a; v.exposure = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        LDSlider(label: "Contrast",
                 value: Binding(get: { a.contrast * 100 },
                                set: { var v = a; v.contrast = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        LDSlider(label: "Saturation",
                 value: Binding(get: { a.saturation * 100 },
                                set: { var v = a; v.saturation = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        LDSlider(label: "Warmth",
                 value: Binding(get: { a.warmth * 100 },
                                set: { var v = a; v.warmth = $0 / 100; editor.setOverlayAdjustments(id: id, v) }),
                 range: -100...100, readout: { "\(Int($0))" })
        if !a.isIdentity {
            LDAction(title: "Reset adjustments", icon: "arrow.counterclockwise") {
                editor.setOverlayAdjustments(id: id, nil)
            }
        }
    }

    @ViewBuilder
    private func border(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("Border")
        let b = item.effects.border
        LDChip(title: b == nil ? "Off" : "On", selected: b != nil) {
            editor.setOverlayBorder(id: id, b == nil ? OverlayBorderSettings() : nil)
        }
        if let b {
            HStack(spacing: 9) {
                ForEach(["#FFFFFF", "#000000", "#F5C518", "#FF5C5C", "#7A68EE"], id: \.self) { hex in
                    Button {
                        var v = b; v.colorHex = hex; editor.setOverlayBorder(id: id, v)
                    } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                            .overlay {
                                if b.colorHex.uppercased() == hex {
                                    Circle().strokeBorder(Color.white, lineWidth: 2)
                                } else {
                                    Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            LDSlider(label: "Width",
                     value: Binding(get: { b.widthFraction * 100 },
                                    set: { var v = b; v.widthFraction = $0 / 100
                                           editor.setOverlayBorder(id: id, v, snapshot: false) }),
                     range: 1...12, readout: { String(format: "%.1f", $0) })
            LDSlider(label: "Corner",
                     value: Binding(get: { b.cornerRadiusFraction * 100 },
                                    set: { var v = b; v.cornerRadiusFraction = $0 / 100
                                           editor.setOverlayBorder(id: id, v, snapshot: false) }),
                     range: 0...50, readout: { "\(Int($0))" })
        }
    }

    @ViewBuilder
    private func motion(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("Keyframes pinned", value: "\(item.keyframes.count)")
        LDAction(title: "Pin this placement at the playhead", icon: "diamond") {
            editor.addOverlayKeyframe(id: id); LumaHaptics.shared.tap()
        }
        if !item.keyframes.isEmpty {
            LDAction(title: "Clear keyframes", icon: "trash") {
                editor.clearOverlayKeyframes(id: id)
            }
        }
        LDNote("Move the overlay, pin it, move it again — the pins animate between placements.")
    }

    @ViewBuilder
    private func sound(_ item: EditorState.OverlayItem, _ id: UUID) -> some View {
        LDCaption("Overlay sound")
        LDSlider(label: "Volume",
                 value: Binding(get: { item.volume },
                                set: { editor.setOverlayVolume(id: id, $0) }),
                 range: 0...100, readout: { "\(Int($0))%" })
        LDChip(title: item.isMuted ? "Unmute" : "Mute", selected: item.isMuted) {
            editor.setOverlayMuted(id: id, !item.isMuted)
        }
        if item.isImage {
            LDNote("Still overlays carry no sound of their own.")
        }
    }
}

// MARK: - Music / audio lane panel

private struct LDMusicPanel: View {
    @ObservedObject var editor: EditorState
    let trackID: UUID?
    let onOpenMixer: () -> Void

    private enum Section: String, CaseIterable {
        case level = "Level", fade = "Fade", envelope = "Envelope"
        case effects = "Effects", beats = "Beats", lane = "Lane"
    }

    @State private var section: Section = .level

    private var track: EditorState.MusicTrack? {
        guard let trackID else { return editor.audioTracks.first }
        return editor.audioTracks.first { $0.id == trackID }
    }

    var body: some View {
        if let track {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Section.allCases, id: \.self) { s in
                            LDChip(title: s.rawValue, selected: section == s) { section = s }
                        }
                    }
                    .padding(.trailing, 24)
                }
                .lumaEdgeFade(leading: 0, trailing: 16)

                switch section {
                case .level:    level(track)
                case .fade:     fade(track)
                case .envelope: LDEnvelopeEditor(editor: editor, track: track)
                case .effects:  LDAudioEffects(editor: editor, track: track)
                case .beats:    beats(track)
                case .lane:     lane(track)
                }
            }
        } else {
            LDNote("No audio lanes yet. Add music, an effect or a voiceover.")
        }
    }

    @ViewBuilder
    private func level(_ track: EditorState.MusicTrack) -> some View {
        LDCaption(track.title, value: LDFormat.secs(track.timelineDuration))
        LDWaveform(samples: track.waveform).frame(height: 34)
        LDSlider(label: "Volume",
                 value: Binding(get: { track.volume },
                                set: { editor.setMusicVolume(id: track.id, $0) }),
                 range: 0...100, readout: { "\(Int($0))%" })
        HStack(spacing: 8) {
            LDChip(title: track.isMuted ? "Unmute" : "Mute", selected: track.isMuted) {
                editor.setMusicMuted(id: track.id, !track.isMuted)
            }
            LDChip(title: "Duck under voice", selected: track.duckingEnabled) {
                editor.setMusicDucking(id: track.id, !track.duckingEnabled)
            }
            LDChip(title: "Loop", selected: track.isLooping) {
                editor.setMusicLooping(id: track.id, !track.isLooping)
            }
        }
        LDAction(title: "Open the project mixer", icon: "slider.horizontal.3", action: onOpenMixer)
        LDAction(title: "Remove this lane", icon: "trash") {
            editor.removeAudioTrack(id: track.id)
        }
    }

    @ViewBuilder
    private func fade(_ track: EditorState.MusicTrack) -> some View {
        // `setMusicFade` clamps to the lane's own length, so a 2 s sting must
        // not offer 5 s of travel that goes nowhere.
        let maxFade = min(5, max(0.1, track.timelineDuration))
        LDSlider(label: "Fade in",
                 value: Binding(get: { track.fadeIn },
                                set: { editor.setMusicFade(id: track.id, fadeIn: $0) }),
                 range: 0...maxFade, readout: { LDFormat.secs($0) })
        LDSlider(label: "Fade out",
                 value: Binding(get: { track.fadeOut },
                                set: { editor.setMusicFade(id: track.id, fadeOut: $0) }),
                 range: 0...maxFade, readout: { LDFormat.secs($0) })
        LDCaption("Fade curve")
        HStack(spacing: 8) {
            ForEach(FadeCurve.allCases, id: \.self) { curve in
                LDChip(title: curve.label, selected: track.fadeCurve == curve) {
                    editor.setMusicFade(id: track.id, curve: curve)
                }
            }
        }
        LDCaption("Edge trim")
        HStack(spacing: 8) {
            LDChip(title: "Head −0.5s") { editor.trimMusicHead(id: track.id, deltaSeconds: -0.5) }
            LDChip(title: "Head +0.5s") { editor.trimMusicHead(id: track.id, deltaSeconds: 0.5) }
            LDChip(title: "Tail −0.5s") { editor.trimMusicTail(id: track.id, deltaSeconds: -0.5) }
            LDChip(title: "Tail +0.5s") { editor.trimMusicTail(id: track.id, deltaSeconds: 0.5) }
        }
    }

    @ViewBuilder
    private func beats(_ track: EditorState.MusicTrack) -> some View {
        LDAction(title: editor.isDetectingBeats ? "Detecting…" : "Detect beats",
                 icon: "metronome", busy: editor.isDetectingBeats) {
            Task { await editor.detectBeats(trackID: track.id) }
        }
        LDAction(title: "Auto-cut clips to the beat", icon: "scissors",
                 enabled: !track.beatMarkers.isEmpty) {
            Task { await editor.autoCutToBeats(trackID: track.id) }
        }
        if track.beatMarkers.isEmpty {
            LDNote("No beats detected yet.")
        } else {
            LDCaption("Beats on the lane", value: "\(track.beatMarkers.count)")
        }
    }

    @ViewBuilder
    private func lane(_ track: EditorState.MusicTrack) -> some View {
        LDCaption("Lane kind")
        HStack(spacing: 8) {
            ForEach(AudioLaneKind.allCases, id: \.self) { kind in
                LDChip(title: kind.label, selected: track.kind == kind) {
                    editor.setAudioKind(id: track.id, kind)
                }
            }
        }
        LDCaption("Offset")
        // `setMusicOffset` clamps to totalDuration − 0.2, so the slider stops
        // exactly where the engine does: no dead travel at the top.
        LDSlider(label: "Start at",
                 value: Binding(get: { track.timelineOffset },
                                set: { editor.setMusicOffset(id: track.id, $0) }),
                 range: 0...max(0.1, editor.totalDuration - 0.2),
                 readout: { LDFormat.secs($0) })
    }
}

// MARK: - Volume envelope

private struct LDEnvelopeEditor: View {
    @ObservedObject var editor: EditorState
    let track: EditorState.MusicTrack

    private var points: [AudioVolumePoint] {
        track.volumePoints.isEmpty
            ? [AudioVolumePoint(time: 0, volume: 1),
               AudioVolumePoint(time: max(0.1, track.timelineDuration), volume: 1)]
            : track.volumePoints.sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LDCaption("Volume over time")
            GeometryReader { geo in
                let dur = max(0.1, track.timelineDuration)
                let w = max(1, geo.size.width)
                let h = max(1, geo.size.height)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LumaTheme.surface)
                    ForEach(1..<3, id: \.self) { i in
                        Rectangle().fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                            .offset(y: h * CGFloat(i) / 3)
                    }
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let x = CGFloat(pt.time / dur) * w
                            let y = h * (1 - CGFloat(pt.volume))
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                            else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    ForEach(Array(points.enumerated()), id: \.offset) { idx, pt in
                        Circle().fill(Color.white).frame(width: 13, height: 13)
                            .position(x: CGFloat(pt.time / dur) * w, y: h * (1 - CGFloat(pt.volume)))
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged { g in
                                    var next = points
                                    guard next.indices.contains(idx) else { return }
                                    // Clamp between the neighbours: the array is
                                    // re-sorted on every write, so letting a
                                    // point cross one renumbered the indices
                                    // mid-drag and you silently started dragging
                                    // a DIFFERENT point.
                                    let lower = idx > 0 ? next[idx - 1].time + 0.01 : 0
                                    let upper = idx < next.count - 1 ? next[idx + 1].time - 0.01 : dur
                                    let raw = Double(g.location.x / w) * dur
                                    next[idx].time = min(max(min(lower, upper), raw), max(lower, upper))
                                    next[idx].volume = min(max(0, 1 - Double(g.location.y / h)), 1)
                                    editor.setMusicEnvelope(id: track.id, next)
                                }
                            )
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture { location in
                    var next = points
                    next.append(AudioVolumePoint(time: min(max(0, Double(location.x / w) * dur), dur),
                                                 volume: min(max(0, 1 - Double(location.y / h)), 1)))
                    editor.setMusicEnvelope(id: track.id, next.sorted { $0.time < $1.time })
                    LumaHaptics.shared.tap()
                }
            }
            .frame(height: 130)
            HStack(spacing: 8) {
                LDChip(title: "Clear") { editor.setMusicEnvelope(id: track.id, []) }
                LDNote("Tap to add a point · drag to shape")
            }
        }
    }
}

// MARK: - Audio effects

private struct LDAudioEffects: View {
    @ObservedObject var editor: EditorState
    let track: EditorState.MusicTrack

    private static let bandLabels = ["80", "250", "1k", "3.5k", "10k"]

    private var fx: AudioEffectSettings { track.effects }

    @State private var renderTask: Task<Void, Never>?

    private func commit(_ s: AudioEffectSettings) {
        let precedingTask = renderTask
        renderTask = Task {
            await precedingTask?.value
            guard !Task.isCancelled else { return }
            await editor.applyTrackEffects(id: track.id, s)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editor.isRenderingEffects {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Baking effects…")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
            }

            LDCaption("Equaliser")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Shared with the seed harness, so a headless
                    // LUMA_SEED_EQ=<name> and a tap land on identical gains.
                    ForEach(AudioEffectsPanel.eqPresets, id: \.0) { name, gains in
                        LDChip(title: name, selected: fx.eqPresetName == name) {
                            var s = fx; s.eqBandGains = gains; s.eqPresetName = name
                            commit(s)
                        }
                    }
                }
                .padding(.trailing, 24)
            }
            .lumaEdgeFade(leading: 0, trailing: 16)

            ForEach(0..<5, id: \.self) { band in
                LDCommitSlider(label: "\(Self.bandLabels[band]) Hz",
                               initial: fx.eqBandGains?.count == 5 ? fx.eqBandGains![band] : 0,
                               range: -12...12, readout: { String(format: "%+.0f dB", $0) }) { v in
                    var gains = fx.eqBandGains?.count == 5 ? fx.eqBandGains! : [0, 0, 0, 0, 0]
                    gains[band] = v
                    var s = fx; s.eqBandGains = gains; s.eqPresetName = nil
                    commit(s)
                }
            }

            LDCommitSlider(label: "Pitch", initial: fx.pitchSemitones,
                           range: -12...12, readout: { String(format: "%+.0f st", $0) }) {
                var s = fx; s.pitchSemitones = $0.rounded(); s.voiceEffect = nil; commit(s)
            }

            LDCaption("Voice changer")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(VoiceEffect.allCases, id: \.self) { effect in
                    LDChip(title: effect.label,
                           selected: effect == .none ? fx.voiceEffect == nil : fx.voiceEffect == effect.rawValue) {
                        var s = fx
                        s.voiceEffect = effect == .none ? nil : effect.rawValue
                        commit(s)
                    }
                }
            }

            LDCaption("Reverb")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ReverbPreset.allCases, id: \.self) { preset in
                    LDChip(title: preset.label,
                           selected: preset == .none ? fx.reverbPreset == nil : fx.reverbPreset == preset.rawValue) {
                        var s = fx
                        s.reverbPreset = preset == .none ? nil : preset.rawValue
                        commit(s)
                    }
                }
            }
            if fx.reverbPreset != nil {
                LDCommitSlider(label: "Wet", initial: fx.reverbMix,
                               range: 0...100, readout: { "\(Int($0))%" }) {
                    var s = fx; s.reverbMix = $0; commit(s)
                }
            }

            LDCaption("Loudness")
            LDAction(title: "Normalize to −14 LUFS", icon: "waveform.path.ecg") {
                Task { await editor.normalizeTrack(id: track.id) }
            }
            if abs(fx.gainDB) > 0.05 {
                LDCaption("Gain", value: String(format: "%+.1f dB", fx.gainDB))
            }
            LDAction(title: "Reset all effects", icon: "arrow.counterclockwise") {
                commit(AudioEffectSettings())
            }
        }
    }
}

// MARK: - Hex colours (content-colour swatches)

extension Color {
    /// "#RRGGBB" convenience for the text / shape / chroma / border palettes.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(cleaned, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Direct manipulation on the preview

/// Move a layer with a finger, on the picture — the whole point of a phone.
///
/// Every tick writes straight through `setOverlayCenter` / `setOverlaySize` /
/// `setOverlayRotation`, which mutate the live `OverlayLayout` box the running
/// compositor reads per frame: no composition rebuild, and the paused player is
/// re-seeked so the new placement is on screen before the finger has moved
/// again. Undo gets exactly ONE entry, recorded on release.
private struct PreviewOverlayEditor: View {
    @ObservedObject var editor: EditorState
    @Binding var selectedOverlayID: UUID?

    private struct GestureStart {
        /// Full model snapshot for the single release-time undo entry.
        let before: EditorState.OverlayItem
        /// Raw placement at the playhead. This is interpolated for keyframed
        /// layers but excludes text animation, whose offset/scale must remain
        /// intact while the user changes the underlying placement.
        let placement: OverlayLayout.Placement
        var translation: CGSize = .zero
        var magnification: CGFloat = 1
        var rotationDegrees: Double = 0
        var hasMutated = false
    }

    @State private var gestureStart: GestureStart?

    /// Layers on screen at the playhead, lowest lane first so the topmost one
    /// is last in the ZStack and therefore takes the touch.
    private var liveLayers: [EditorState.OverlayItem] {
        let t = editor.currentTime
        return editor.overlays
            .filter { t >= $0.timelineOffset - 0.001 && t < $0.timelineEnd + 0.001 }
            .sorted { $0.lane < $1.lane }
    }

    var body: some View {
        GeometryReader { geo in
            let media = OverlayRenderGeometry.aspectFitRect(
                contentSize: editor.format.renderSize,
                in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(liveLayers) { item in
                    layerHandle(item, in: media)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Geometry

    /// The placement actually on screen right now. Read from the live layout
    /// box so a keyframed layer is grabbed where it is being drawn, not where
    /// its base placement sits.
    private func placement(_ item: EditorState.OverlayItem) -> OverlayLayout.Placement {
        editor.overlayLayout.placement(for: item.id,
                                       at: max(0, editor.currentTime - item.timelineOffset))
            ?? OverlayLayout.Placement(sizeFraction: item.sizeFraction,
                                       center: item.center,
                                       opacity: item.opacity,
                                       rotationDegrees: item.rotationDegrees)
    }

    /// Exact compositor geometry for this frame. If a rebuild is in flight and
    /// there is no extent belonging to the currently published player item,
    /// draw no speculative handle — the pixels are not there yet either.
    private func geometry(_ item: EditorState.OverlayItem,
                          in media: CGRect) -> OverlayRenderGeometry.Layout? {
        guard !editor.isRebuilding,
              let sourceExtent = editor.overlaySourceExtents[item.id] else { return nil }
        let localTime = max(0, editor.currentTime - item.timelineOffset)
        let resolved = OverlayRenderGeometry.resolve(
            placement(item),
            textAnimation: item.text == nil ? nil : item.textAnimation,
            localTime: localTime,
            duration: item.duration)
        return OverlayRenderGeometry.layout(sourceExtent: sourceExtent,
                                            placement: resolved.placement,
                                            canvasRect: media)
    }

    // MARK: The handle

    /// How far the touch area reaches past the drawn box. The SELECTED layer is
    /// also the pinch/twist target and two fingers need more room than one — a
    /// sticker can easily be smaller than the gap between them — so its grab
    /// zone never falls below 88 pt. Only one layer is selected at a time, so
    /// the reach stays predictable.
    private struct LayerHitShape: Shape {
        let horizontalInset: CGFloat
        let verticalInset: CGFloat

        func path(in rect: CGRect) -> Path {
            Path(rect.insetBy(dx: -horizontalInset, dy: -verticalInset))
        }
    }

    private func grabInsets(_ rect: CGRect, selected: Bool) -> CGSize {
        guard selected else { return CGSize(width: 11, height: 11) }
        return CGSize(width: max(11, (88 - rect.width) / 2),
                      height: max(11, (88 - rect.height) / 2))
    }

    @ViewBuilder
    private func layerHandle(_ item: EditorState.OverlayItem, in media: CGRect) -> some View {
        if let geometry = geometry(item, in: media) {
            let rect = geometry.frame
            let selected = selectedOverlayID == item.id
            let insets = grabInsets(rect, selected: selected)
            Color.clear
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .overlay {
                    // A stroke means selection and nothing else — a thin white
                    // outline, no handles pretending to be resize grips.
                    if selected {
                        Rectangle().strokeBorder(Color.white, lineWidth: 1)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                // The shape precedes rotation, so the hit target rotates with
                // the pixels. X/Y grow independently: a 200x20 caption becomes
                // 222x88, not the old accidental 268x88 target.
                .contentShape(LayerHitShape(horizontalInset: insets.width,
                                            verticalInset: insets.height))
                .rotationEffect(.degrees(geometry.rotationDegrees))
                .position(x: rect.midX, y: rect.midY)
                .gesture(transformGesture(item, media: media))
        }
    }

    /// One composed recogniser produces one end event for drag + pinch + twist.
    /// Separate `.simultaneousGesture` modifiers can end on different ticks;
    /// the first used to clear the baseline and a trailing callback could open
    /// a second undo transaction.
    private func transformGesture(_ item: EditorState.OverlayItem,
                                  media: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .simultaneously(with: MagnifyGesture())
            .simultaneously(with: RotateGesture())
            .onChanged { value in
                begin(item)
                guard var start = gestureStart, start.before.id == item.id,
                      media.width > 1, media.height > 1 else { return }

                // A component becomes nil after its recogniser ends while a
                // sibling may still be active. Retain its last delta so a
                // continuing drag cannot reset an already-finished twist.
                if let drag = value.first?.first { start.translation = drag.translation }
                if let magnify = value.first?.second { start.magnification = magnify.magnification }
                if let rotate = value.second { start.rotationDegrees = rotate.rotation.degrees }

                var next = start.placement
                next.center = CGPoint(
                    x: min(max(0, start.placement.center.x
                        + start.translation.width / media.width), 1),
                    y: min(max(0, start.placement.center.y
                        + start.translation.height / media.height), 1))
                next.sizeFraction = min(max(0.25,
                    start.placement.sizeFraction * start.magnification), 1)
                next.rotationDegrees = min(max(-180,
                    start.placement.rotationDegrees + start.rotationDegrees), 180)

                let moved = next.center != start.placement.center
                    || next.sizeFraction != start.placement.sizeFraction
                    || next.rotationDegrees != start.placement.rotationDegrees
                if moved || start.hasMutated {
                    start.hasMutated = true
                    editor.setOverlayTransform(id: item.id, next)
                }
                gestureStart = start
            }
            .onEnded { _ in commit(item.id) }
    }

    // MARK: Gesture lifecycle

    /// First tick of a gesture: select the layer and take the undo baseline.
    /// Deliberately does NOT open the overlay panel — the drawer would resize
    /// the preview out from under the finger mid-drag.
    private func begin(_ item: EditorState.OverlayItem) {
        // Nil, not "a different layer": a second finger landing on a NEIGHBOUR
        // mid-drag must not re-baseline the gesture that is already running.
        guard gestureStart == nil else { return }
        gestureStart = GestureStart(before: item, placement: placement(item))
        if selectedOverlayID != item.id {
            selectedOverlayID = item.id
            LumaHaptics.shared.tap()
        }
    }

    /// One snapshot per composed drag + pinch + rotate gesture. A tap takes a
    /// baseline for selection but writes no model value, so commit is a no-op.
    private func commit(_ id: UUID) {
        guard let start = gestureStart, start.before.id == id else { return }
        gestureStart = nil
        editor.commitOverlayGesture(id: id, before: start.before)
    }
}

// MARK: - Fullscreen preview

/// The footage full-screen on black: tap to play/pause, scrub bar along the
/// bottom, minimise back into the editor. Same AVPlayer — same compositor
/// frames — zero rebuilds.
private struct FullscreenPreview: View {
    @ObservedObject var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = editor.player {
                FullscreenPlayerSurface(player: player)
                    .ignoresSafeArea()
            }

            // Tap anywhere toggles playback.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { editor.togglePlayback() }

            if !editor.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.5), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.lumaPress)
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                Text(LDFormat.clock(editor.currentTime))
                Slider(value: Binding(
                    get: { editor.currentTime },
                    set: { editor.seek(to: $0) }
                ), in: 0...max(editor.totalDuration, 0.1))
                .tint(.white)
                Text(LDFormat.clock(editor.totalDuration))
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .animation(.easeOut(duration: 0.18), value: editor.isPlaying)
        .statusBarHidden()
    }
}

/// Bare AVPlayerLayer host — no system chrome, aspect-fit on black.
private struct FullscreenPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

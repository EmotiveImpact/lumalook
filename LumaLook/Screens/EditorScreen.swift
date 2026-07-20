import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import Pow

struct EditorTimelineView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var addPickerItem: PhotosPickerItem?
    @State private var showAddPicker = false
    @State private var overlayPickerItem: PhotosPickerItem?
    @State private var showOverlayPicker = false
    @State private var replacePickerItem: PhotosPickerItem?
    @State private var showReplacePicker = false
    @State private var showCropPanel = false
    @State private var showOverlayPanel = false
    @State private var selectedOverlayID: UUID?
    @State private var isLoadingClip = false
    @State private var showTrimPanel = false
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 1
    @State private var showLooksStrip = false
    @State private var showSpeedPanel = false
    @State private var showMusicPanel = false
    @State private var showClipAudioPanel = false
    @State private var selectedAudioID: UUID?
    #if DEBUG
    @State private var debugFXTrackID: UUID?   // opens AudioEffectsPanel for verification
    #endif
    @State private var transitionClipID: UUID?
    @State private var showMusicImporter = false
    @State private var showAudioSourceChooser = false
    @State private var showAudioLibrary = false
    @State private var showStickerLibrary = false
    @State private var showMaskPanel = false
    @State private var isCaptioning = false
    @State private var showTemplates = false
    @State private var isExporting = false
    @State private var showExportSheet = false
    @State private var showFullscreenPreview = false
    @State private var exportError: String?

    private var editor: EditorState { app.editor }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            EditorContent(
                editor: editor,
                isLoadingClip: isLoadingClip,
                showTrimPanel: $showTrimPanel,
                trimStart: $trimStart,
                trimEnd: $trimEnd,
                showLooksStrip: $showLooksStrip,
                showSpeedPanel: $showSpeedPanel,
                showMusicPanel: $showMusicPanel,
                showClipAudioPanel: $showClipAudioPanel,
                selectedAudioID: $selectedAudioID,
                transitionClipID: $transitionClipID,
                showOverlayPanel: $showOverlayPanel,
                selectedOverlayID: $selectedOverlayID,
                showFullscreenPreview: $showFullscreenPreview,
                exportError: exportError,
                onBack: { dismiss() },
                onAdd: { showAddPicker = true },
                // B1: the second empty-state CTA — shoot straight into the
                // live-look camera instead of leaving to find footage.
                onRecord: { app.path.append(.camera) },
                onAddOverlay: { showOverlayPicker = true },
                onAddSticker: { showStickerLibrary = true },
                onOpenMask: { showMaskPanel = true },
                onCaptions: {
                    Task {
                        isCaptioning = true
                        let n = await editor.generateCaptions()
                        isCaptioning = false
                        if n == 0 {
                            exportError = "No speech found — check Settings › Privacy › Speech Recognition."
                        }
                    }
                },
                onTemplates: { showTemplates = true },
                onAddMusic: { showAudioSourceChooser = true },
                onExport: { showExportSheet = true },
                onOpenAudio: { app.path.append(.audio) },
                onOpenCrop: { app.path.append(.cropFormat) },
                onOpenAdjust: { app.path.append(.customLook) },
                onReplace: { showReplacePicker = true },
                onCropClip: { if editor.selectedClipID != nil { showCropPanel = true } }
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
        .confirmationDialog("Add audio", isPresented: $showAudioSourceChooser, titleVisibility: .visible) {
            Button("Sound Library") { showAudioLibrary = true }
            Button("From Files") { showMusicImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showStickerLibrary) {
            StickerLibraryView()
        }
        .sheet(isPresented: $showTemplates) {
            TemplateLibraryView(editor: editor)
        }
        .sheet(isPresented: $showMaskPanel) {
            if let id = editor.selectedClipID ?? editor.clips.first?.id {
                ScrollView {
                    MaskPanel(editor: editor, clipID: id) { showMaskPanel = false }
                        .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .presentationDetents([.medium, .large])
                .presentationBackground(LumaTheme.background)
            }
        }
        .sheet(isPresented: $showAudioLibrary) {
            AudioLibrarySheet(editor: editor) { showAudioLibrary = false }
                .presentationDetents([.medium, .large])
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
                    await editor.addOverlay(from: video.url, isImage: false)
                } else if let imageURL = await Self.pickedImageFile(from: newItem) {
                    await editor.addOverlay(from: imageURL, isImage: true)
                }
                // Open the panel on the freshly added overlay (the array is
                // offset-sorted, so "last" isn't necessarily the new one).
                if let added = editor.overlays.first(where: { !before.contains($0.id) }) {
                    selectedOverlayID = added.id
                    showOverlayPanel = true
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
                // instead of a fresh empty one — your edit from a minute ago
                // was otherwise silently two screens away. The title menu's
                // New Project stays one tap for a clean slate.
                editor.load(project: last)
                // H4 fix: say so — the silent resume read as "leftover content".
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
            editor.saveProject()
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
        // TikTok-style fullscreen preview: the footage owns the whole
        // display; one tap minimises back into the editor.
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
            }
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
                    }
                    showTrimPanel = true
                case "speed":     showSpeedPanel = true
                case "clipaudio": showClipAudioPanel = true
                case "overlay":
                    selectedOverlayID = editor.overlays.first?.id
                    showOverlayPanel = editor.overlays.first != nil
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
                    showMusicPanel = true
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
                    showOverlayPanel = true
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
                    if env["LUMA_SEED_LIBLOOK"] == "strip" { showLooksStrip = true }
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
                    // permission — if the user denies it (or the prompt is
                    // never answered), they should still get their GIF.
                    // The finished mov already has the grade, overlays and
                    // frame burnt in, so no composition is needed.
                    app.lastExportGIFURL = (spec.alsoGIF && !spec.audioOnly)
                        ? await GIFExporter.makeGIF(from: url)
                        : nil
                    app.lastExportSavedToPhotos = await app.exporter.saveToPhotos(url: url)
                }
                // F5: transcode the FINISHED mov — everything (grade, overlays,
                // frame) is already burnt in, so the GIF needs no composition.
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

// MARK: - Content

private struct EditorContent: View {
    @ObservedObject var editor: EditorState
    @EnvironmentObject private var app: AppModel
    let isLoadingClip: Bool
    @Binding var showTrimPanel: Bool
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var showLooksStrip: Bool
    @Binding var showSpeedPanel: Bool
    @Binding var showMusicPanel: Bool
    @Binding var showClipAudioPanel: Bool
    @Binding var selectedAudioID: UUID?
    @Binding var transitionClipID: UUID?
    @Binding var showOverlayPanel: Bool
    @Binding var selectedOverlayID: UUID?
    @Binding var showFullscreenPreview: Bool
    let exportError: String?
    let onBack: () -> Void
    let onAdd: () -> Void
    let onRecord: () -> Void
    let onAddOverlay: () -> Void
    let onAddSticker: () -> Void
    let onOpenMask: () -> Void
    let onCaptions: () -> Void
    let onTemplates: () -> Void
    let onAddMusic: () -> Void
    let onExport: () -> Void
    let onOpenAudio: () -> Void
    let onOpenCrop: () -> Void
    let onOpenAdjust: () -> Void
    let onReplace: () -> Void
    let onCropClip: () -> Void
    /// When set, the looks strip grades THIS clip instead of the timeline.
    @State private var looksTargetClipID: UUID?
    /// Full LookBrowserSheet over the strip (sheet-over-sheet).
    @State private var showLookBrowser = false
    /// Real graded-frame thumbnails for the looks strip — same renderer as
    /// ApplyLookView/camera, so a look finally previews identically everywhere.
    @StateObject private var lookThumbs = LookThumbs()
    /// Transport readout mode: MM:SS:FF timecode vs plain MM:SS (long-press).
    @State private var showFrames = true
    /// Audio lane whose volume envelope is being edited (A4).
    @State private var envelopeTrackID: UUID?
    /// Audio lane whose effects are being edited (C1–C5).
    @State private var effectsTrackID: UUID?
    /// Timeline zoom (points per second), shared by the transport's zoom
    /// control and the scroller's pinch so they can't disagree.
    @State private var timelineZoom: CGFloat = 50
    /// B3: a tool panel is up, so the preview compresses and a mini timeline
    /// strip takes over from the full stack. Strip-height pickers (looks,
    /// transitions) sit below the preview already and are excluded.
    private var toolPanelOpen: Bool {
        showTrimPanel || showMusicPanel || showClipAudioPanel
            || showOverlayPanel || showSpeedPanel
    }
    /// Which music sub-tool the audio panel is showing (B3 chip row).
    @State private var musicSubTool: String = MusicSubTool.volume
    /// Measured chrome geometry, so the compressed preview can be sized to the
    /// space the open panel actually leaves instead of a guessed constant.
    @State private var headerHeight: CGFloat = 0
    @State private var spaceToScreenBottom: CGFloat = 0

    /// Preview height while a tool panel is up: exactly the room above the
    /// sheet, minus the header and the mini timeline strip.
    private var compressedPreviewHeight: CGFloat {
        ToolPanelMetrics.previewHeight(spaceToScreenBottom: spaceToScreenBottom,
                                       headerHeight: headerHeight)
    }

    var body: some View {
        // Editor-app composition (not a page): the preview flexes to fill,
        // everything else is pinned. Nothing scrolls vertically.
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .background {
                    GeometryReader { g in
                        Color.clear.preference(key: ToolPanelHeaderHeightKey.self,
                                               value: g.size.height)
                    }
                }

            // B3: the preview compresses upward when a panel is open — it is
            // never covered, and the panel gets the whole area below it.
            preview
                .frame(maxWidth: .infinity,
                       maxHeight: toolPanelOpen ? compressedPreviewHeight : .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 10)

            if toolPanelOpen {
                // Scrubbing stays possible while a value is tuned.
                MiniTimelineStrip(editor: editor, zoom: timelineZoom)
                    .padding(.horizontal, 12)
                    .padding(.top, ToolPanelMetrics.stripTopPadding)
                // Collapses to zero once the preview is sized to the real gap.
                Spacer(minLength: 0)
            } else {
                transport
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)

                clipActionChips

                // Timeline V2: edge-to-edge so the fixed playhead sits at true
                // screen centre and content scrolls under it.
                timeline
                    .padding(.bottom, 10)

                if let exportError {
                    Text(exportError)
                        .font(.system(size: 13))
                        .foregroundStyle(LumaTheme.orange)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }

                dock
                    .overlay(alignment: .top) {
                        if editor.isRecordingVoiceover {
                            InputMeterView(level: editor.inputLevel)
                                .offset(y: -46)
                                .transition(.opacity)
                        }
                    }
            }
        }
        // Measures from the top of the content area to the PHYSICAL bottom of
        // the screen (the probe ignores the bottom safe area, which sheet
        // detents also include), so `compressedPreviewHeight` and the sheet
        // agree on where the panel's top edge lands.
        .background {
            GeometryReader { g in
                Color.clear.preference(key: ToolPanelSpaceKey.self, value: g.size.height)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .onPreferenceChange(ToolPanelHeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(ToolPanelSpaceKey.self) { spaceToScreenBottom = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: toolPanelOpen)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: editor.audioTracks.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor.selectedClipID != nil)
        // One physical thump whenever the timeline structure changes
        // (add, split, delete).
        .sensoryFeedback(.impact(weight: .medium), trigger: editor.clips.count)
        .sensoryFeedback(.selection, trigger: editor.selectedClipID)
        // Tool panels are undimmed glass sheets: the timeline stays visible
        // and scrubbable underneath while you trim, mix or pick a look.
        .lumaToolSheet(isPresented: $showTrimPanel, style: .panel) {
            if let clip = editor.selectedClip {
                ToolPanelScaffold(title: "Trim",
                                  subtitle: "\(timeString(trimStart)) – \(timeString(trimEnd))",
                                  onDone: {
                                      editor.applyTrim(start: trimStart, end: trimEnd)
                                      withAnimation(.easeOut(duration: 0.15)) { showTrimPanel = false }
                                  }) {
                    trimPanel(clip: clip)
                }
            } else {
                Color.clear.onAppear { showTrimPanel = false }
            }
        }
        // Both audio panels are `.panel`, not `.tallPanel`: at the 620 pt large
        // detent there is physically no room left for the compressed preview
        // AND the mini timeline strip that B3 requires. They open at 340 pt and
        // can still be dragged to `.large` for the whole stack at once.
        .lumaToolSheet(isPresented: $showMusicPanel, style: .panel) {
            if let music = editor.audioTracks.first(where: { $0.id == selectedAudioID })
                        ?? editor.audioTracks.first {
                ToolPanelScaffold(title: "Audio · \(music.title)",
                                  subtitle: String(format: "%.1fs", music.timelineDuration),
                                  chips: MusicSubTool.all,
                                  selectedChip: musicSubTool,
                                  onSelectChip: { musicSubTool = $0 },
                                  onDone: {
                                      withAnimation(.easeOut(duration: 0.15)) { showMusicPanel = false }
                                  }) {
                    musicPanel(music: music)
                }
            } else {
                Color.clear.onAppear { showMusicPanel = false }
            }
        }
        .sheet(item: $envelopeTrackID) { id in
            AudioEnvelopeEditor(editor: editor, trackID: id) { envelopeTrackID = nil }
                .presentationDetents([.medium])
        }
        .sheet(item: $effectsTrackID) { id in
            AudioEffectsPanel(editor: editor, trackID: id) { effectsTrackID = nil }
                .presentationDetents([.height(560), .large])
        }
        .lumaToolSheet(isPresented: $showClipAudioPanel, style: .panel) {
            if let clip = editor.selectedClip {
                ToolPanelScaffold(title: "Clip sound",
                                  subtitle: clip.hasAudio
                                      ? String(format: "%.1fs", clip.timelineDuration)
                                      : "No sound on this clip",
                                  onDone: {
                                      withAnimation(.easeOut(duration: 0.15)) { showClipAudioPanel = false }
                                  }) {
                    clipAudioPanel(clip: clip)
                }
            } else {
                Color.clear.onAppear { showClipAudioPanel = false }
            }
        }
        .lumaToolSheet(isPresented: $showOverlayPanel, style: .panel) {
            if let overlay = editor.overlays.first(where: { $0.id == selectedOverlayID })
                          ?? editor.overlays.first {
                ToolPanelScaffold(title: overlay.text == nil ? "Overlay" : "Text",
                                  onDone: {
                                      withAnimation(.easeOut(duration: 0.15)) { showOverlayPanel = false }
                                  }) {
                    OverlayPanel(editor: editor, overlayID: overlay.id) {
                        withAnimation(.easeOut(duration: 0.15)) { showOverlayPanel = false }
                    }
                }
            } else {
                Color.clear.onAppear { showOverlayPanel = false }
            }
        }
        .lumaToolSheet(isPresented: Binding(
            get: { transitionClipID != nil },
            set: { if !$0 { transitionClipID = nil } }
        ), style: .strip) {
            transitionPicker
                .padding(.top, 22)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .lumaToolSheet(isPresented: $showLooksStrip, style: .strip) {
            looksStrip
                .padding(.top, 22)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .lumaToolSheet(isPresented: $showSpeedPanel, style: .panel) {
            if let clip = editor.selectedClip {
                speedPanel(clip: clip)
            } else {
                Color.clear.onAppear { showSpeedPanel = false }
            }
        }
    }

    // MARK: Clip action chips (B2)

    /// Contextual chips over the timeline. They exist ONLY while a clip is
    /// selected and vanish the moment it is deselected — the five actions a
    /// selected clip actually implies, with delete last and in red.
    @ViewBuilder
    private var clipActionChips: some View {
        if editor.selectedClipID != nil, !editor.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ClipActionChip(title: "Split", icon: "square.split.2x1") {
                        editor.splitAtPlayhead()
                    }
                    ClipActionChip(title: "Duplicate", icon: "plus.square.on.square") {
                        editor.duplicateSelected()
                        LumaHaptics.shared.tap()
                    }
                    ClipActionChip(title: "Trim", icon: "scissors", selected: showTrimPanel) {
                        guard let clip = editor.selectedClip else { return }
                        trimStart = clip.trimStart
                        trimEnd = clip.trimEnd
                        showTrimPanel = true
                    }
                    ClipActionChip(title: editor.selectedClip.map { speedLabel($0.speed) } ?? "Speed",
                                   icon: "gauge.with.needle",
                                   selected: showSpeedPanel) {
                        showSpeedPanel = true
                    }
                    ClipActionChip(title: "Delete", icon: "trash", destructive: true) {
                        editor.deleteSelected()
                    }
                }
                .padding(.horizontal, 20)
            }
            .lumaEdgeFade(leading: 12, trailing: 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Speed panel (B3 pattern)

    /// Speed as a push-up panel rather than a buried menu: presets as chips,
    /// ramps as chips, one Done. Every control writes through the same
    /// `setClipSpeed` / `setSpeedRamp` the menu used.
    private func speedPanel(clip: EditorState.Clip) -> some View {
        ToolPanelScaffold(
            title: "Speed",
            subtitle: speedLabel(clip.speed) == "Speed" ? "Normal" : speedLabel(clip.speed),
            onDone: { withAnimation(.easeOut(duration: 0.15)) { showSpeedPanel = false } }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    TechReadout("CONSTANT", size: 9, color: LumaTheme.textMuted)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                              spacing: 8) {
                        ForEach([0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0], id: \.self) { speed in
                            let on = editor.selectedClip?.speed == speed
                            Button {
                                editor.setClipSpeed(speed)
                                LumaHaptics.shared.tap()
                            } label: {
                                Text(String(format: "%g×", speed))
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(on ? .white : LumaTheme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(on ? AnyShapeStyle(LumaTheme.accent)
                                                   : AnyShapeStyle(LumaTheme.surface),
                                                in: RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.lumaPress)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    TechReadout("RAMP", size: 9, color: LumaTheme.textMuted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EditorState.SpeedRamp.allCases, id: \.self) { ramp in
                                ToolPanelChip(title: ramp.label,
                                              selected: editor.selectedClip?.speedRamp == ramp.rawValue) {
                                    editor.setSpeedRamp(ramp)
                                    LumaHaptics.shared.tap()
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
                Text("Audio is pitch-preserved at every speed.")
                    .font(.system(size: 12))
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
    }

    // MARK: Dock

    /// Root tool dock ⇄ clip inspector, swapped on selection with a slide —
    /// the CapCut/img.ly pattern: context decides the tools.
    private var dock: some View {
        ZStack {
            if editor.selectedClipID != nil, !editor.isEmpty {
                HStack(spacing: 2) {
                    Button {
                        editor.selectedClipID = nil
                        showTrimPanel = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LumaTheme.textSecondary)
                            .frame(width: 34, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.lumaPress)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                    FlatTool(title: "Trim", icon: "scissors", selected: showTrimPanel) {
                        guard let clip = editor.selectedClip else { return }
                        trimStart = clip.trimStart
                        trimEnd = clip.trimEnd
                        showTrimPanel.toggle()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Split", icon: "square.split.2x1") {
                        editor.splitAtPlayhead()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Freeze", icon: "snowflake") {
                        LumaHaptics.shared.tap()
                        Task { await editor.freezeAtPlayhead() }
                    }
                    .frame(width: 58)
                    FlatTool(title: "Crop", icon: "crop") {
                        onCropClip()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Rotate", icon: "rotate.right") {
                        editor.rotateSelectedClip()
                        LumaHaptics.shared.tap()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Mirror", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                             selected: editor.selectedClip?.isMirrored == true) {
                        editor.mirrorSelectedClip()
                        LumaHaptics.shared.tap()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Duplicate", icon: "plus.square.on.square") {
                        editor.duplicateSelected()
                        LumaHaptics.shared.tap()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Replace", icon: "arrow.triangle.2.circlepath") {
                        onReplace()
                    }
                    .frame(width: 58)
                    FlatTool(title: editor.isBaking ? "Reversing" : "Reverse",
                             icon: "backward.fill") {
                        guard !editor.isBaking, editor.selectedClip?.isImage == false else { return }
                        LumaHaptics.shared.tap()
                        Task { await editor.reverseSelectedClip() }
                    }
                    .frame(width: 58)
                    .opacity((editor.selectedClip?.isImage ?? true) ? 0.35 : 1)
                    if editor.selectedClip?.hasAudio == true {
                        FlatTool(title: editor.isDetaching ? "Detaching" : "Detach",
                                 icon: "waveform.badge.minus") {
                            guard !editor.isDetaching, let id = editor.selectedClipID else { return }
                            LumaHaptics.shared.tap()
                            Task { await editor.detachAudio(clipID: id) }
                        }
                        .frame(width: 58)
                    }
                    FlatTool(title: "Delete", icon: "trash") {
                        editor.deleteSelected()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Volume", icon: "speaker.wave.2",
                             selected: showClipAudioPanel) {
                        showClipAudioPanel.toggle()
                    }
                    .frame(width: 58)
                    FlatTool(title: "Look", icon: "camera.filters",
                             selected: showLooksStrip && looksTargetClipID != nil) {
                        looksTargetClipID = editor.selectedClipID
                        showLooksStrip.toggle()
                    }
                    .frame(width: 58)
                    kenBurnsMenu
                        .frame(width: 58)
                    // Speed is a push-up panel now (B3), not a buried menu.
                    FlatTool(title: editor.selectedClip.map { speedLabel($0.speed) } ?? "Speed",
                             icon: "gauge.with.needle",
                             selected: showSpeedPanel) {
                        showSpeedPanel = true
                    }
                    .frame(width: 58)
                        }
                    }
                    // Matches the unselected dock: content fades under the
                    // chrome instead of being sliced flat at the screen edge.
                    .lumaEdgeFade(leading: 14, trailing: 14)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        FlatTool(title: "Add", icon: "plus", action: onAdd)
                            .frame(width: 58)
                        FlatTool(title: "Edit", icon: "scissors") {
                            selectClipAtPlayhead()
                        }
                        .frame(width: 58)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        FlatTool(title: "Overlay", icon: "rectangle.on.rectangle", action: onAddOverlay)
                            .frame(width: 58)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                        FlatTool(title: "Text", icon: "textformat") {
                            let before = Set(editor.overlays.map(\.id))
                            editor.addTextOverlay()
                            if let added = editor.overlays.first(where: { !before.contains($0.id) }) {
                                selectedOverlayID = added.id
                                withAnimation(.easeOut(duration: 0.15)) { showOverlayPanel = true }
                            }
                        }
                        .frame(width: 58)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        FlatTool(title: "Sticker", icon: "face.smiling", action: onAddSticker)
                        .frame(width: 58)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        Menu {
                            ForEach(ShapeKind.allCases, id: \.self) { kind in
                                Button {
                                    if let id = editor.addShapeOverlay(kind: kind) {
                                        selectedOverlayID = id
                                        withAnimation(.easeOut(duration: 0.15)) { showOverlayPanel = true }
                                    }
                                } label: { Label(kind.label, systemImage: kind.icon) }
                            }
                        } label: {
                            // Mirrors FlatTool's grammar; a Menu can't wrap it
                            // (FlatTool owns its own Button).
                            VStack(spacing: 8) {
                                Image(systemName: "square.on.circle")
                                    .font(.system(size: 19, weight: .medium))
                                Text("Shape").font(.system(size: 13))
                            }
                            .foregroundStyle(LumaTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .frame(width: 58)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        Menu {
                            ForEach(EffectKind.allCases, id: \.self) { kind in
                                Button {
                                    editor.addEffectLayer(kind: kind)
                                    LumaHaptics.shared.tap()
                                } label: { Label(kind.label, systemImage: kind.icon) }
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 19, weight: .medium))
                                Text("Effects").font(.system(size: 13))
                            }
                            .foregroundStyle(LumaTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .frame(width: 58)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        Menu {
                            ForEach(ParticleKind.allCases, id: \.self) { kind in
                                Button {
                                    editor.addParticleLayer(kind: kind)
                                    LumaHaptics.shared.tap()
                                } label: { Label(kind.label, systemImage: kind.icon) }
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 19, weight: .medium))
                                Text("Particles").font(.system(size: 13))
                            }
                            .foregroundStyle(LumaTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .frame(width: 62)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        FlatTool(title: "Looks", icon: "camera.filters", selected: showLooksStrip) {
                            looksTargetClipID = nil
                            showLooksStrip.toggle()
                        }
                        .frame(width: 58)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        FlatTool(title: "Adjust", icon: "slider.horizontal.3", action: onOpenAdjust)
                            .frame(width: 58)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                        adjustLayerMenu
                            .frame(width: 58)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                        audioReactiveMenu
                            .frame(width: 58)
                            .opacity(editor.audioTracks.isEmpty ? 0.35 : 1)
                            .disabled(editor.audioTracks.isEmpty)
                        FlatTool(title: editor.isRecordingVoiceover ? "Stop" : "Record",
                                 icon: editor.isRecordingVoiceover ? "stop.circle.fill" : "mic.fill",
                                 selected: editor.isRecordingVoiceover) {
                            if editor.isRecordingVoiceover {
                                editor.stopVoiceover()
                                LumaHaptics.shared.exportSuccess()
                            } else {
                                editor.startVoiceover()
                                LumaHaptics.shared.tap()
                            }
                        }
                        .frame(width: 58)
                        .opacity(editor.isEmpty ? 0.35 : 1)
                        .disabled(editor.isEmpty)
                        FlatTool(title: "Audio", icon: "music.note", action: onOpenAudio)
                            .frame(width: 58)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                        FlatTool(title: "Template", icon: "wand.and.stars", action: onTemplates)
                            .frame(width: 62)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                        FlatTool(title: "Captions", icon: "captions.bubble", action: onCaptions)
                            .frame(width: 62)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                        FlatTool(title: "Spot", icon: "circle.dashed.inset.filled", action: onOpenMask)
                            .frame(width: 58)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                        FlatTool(title: "Crop", icon: "crop", action: onOpenCrop)
                            .frame(width: 58)
                            .opacity(editor.isEmpty ? 0.35 : 1)
                            .disabled(editor.isEmpty)
                    }
                    .padding(.horizontal, 6)
                }
                .lumaEdgeFade(leading: 14, trailing: 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            HStack(spacing: 6) {
                Text(editor.projectTitle)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            // Without this the trailing Spacer competes with the title for the
            // flexible remainder and "New Project" ellipsises beside a gap.
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button { editor.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(editor.canUndo ? .white : LumaTheme.textMuted)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .disabled(!editor.canUndo)
            Button { editor.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(editor.canRedo ? .white : LumaTheme.textMuted)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .disabled(!editor.canRedo)
            Button(action: onExport) {
                Text("Export")
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [LumaTheme.accent, LumaTheme.accent.opacity(0.82)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.lumaPress)
            .conditionalEffect(.repeat(.shine, every: .seconds(4)), condition: !editor.isEmpty)
            .opacity(editor.isEmpty ? 0.4 : 1)
            // H5 fix: looked disabled but still opened the export sheet on an
            // empty timeline, erroring only after the user picked a spec.
            .disabled(editor.isEmpty)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        Group {
            if let player = editor.player {
                // Fullscreen now lives in the transport row (B2) — the frame
                // stays clean of floating chrome.
                VideoPlayer(player: player)
                    .onDisappear { if editor.isPlaying { editor.togglePlayback() } }
            } else {
                // B1: no placeholder art. Two equal-weight ways in — pick
                // footage, or shoot it — on a dashed, obviously-empty stage.
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.045)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        VStack(spacing: 20) {
                            if isLoadingClip {
                                ProgressView().tint(.white)
                                Text("Loading clip…")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            } else {
                                TechReadout("START YOUR EDIT", size: 10,
                                            color: LumaTheme.textSecondary)
                                HStack(spacing: 12) {
                                    EmptyStateCTA(title: "Add video",
                                                  caption: "Photos · Files",
                                                  icon: "plus",
                                                  filled: true,
                                                  action: onAdd)
                                    EmptyStateCTA(title: "Record",
                                                  caption: "Live look camera",
                                                  icon: "record.circle",
                                                  filled: false,
                                                  iconTint: LumaTheme.recordRed,
                                                  action: onRecord)
                                }
                                Button {
                                    app.path.append(.projectLibrary)
                                } label: {
                                    Text("or open a project")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(LumaTheme.accentBright)
                                }
                                .buttonStyle(.lumaPress)
                            }
                        }
                        .padding(22)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                        .foregroundStyle(.white.opacity(0.16)))
            }
        }
        // Audio-editing focus: when a music/clip-audio panel is open, the
        // preview shows the AUDIO ASSET (waveform + name) instead of the video,
        // so the sheet's controls read as belonging to what's on screen.
        .overlay {
            if let f = audioFocus {
                AudioFocusView(title: f.title, subtitle: f.subtitle,
                               icon: f.icon, samples: f.samples)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: audioFocusKey)
    }

    /// The asset being edited when an audio panel is open (nil otherwise).
    private var audioFocus: (title: String, subtitle: String, icon: String, samples: [Float])? {
        if showMusicPanel,
           let t = editor.audioTracks.first(where: { $0.id == selectedAudioID }) ?? editor.audioTracks.first {
            return (t.title,
                    "\(t.kind.label) · \(String(format: "%.1fs", t.timelineDuration))",
                    t.kind.icon, t.waveform)
        }
        if showClipAudioPanel, let c = editor.selectedClip {
            // Photos-imported assets have UUID filenames, so the URL stem is a
            // machine identifier, not a name. Title the clip by its position in
            // the sequence — the thing the user can actually see on the strip.
            let index = editor.clips.firstIndex(where: { $0.id == c.id })
            let name = index.map { "Clip \($0 + 1)" }
                ?? c.url.deletingPathExtension().lastPathComponent
            return (name,
                    "Clip Audio · \(String(format: "%.1fs", c.timelineDuration))",
                    "waveform", [])
        }
        return nil
    }

    /// Cheap change key so the overlay animates in/out on panel toggles.
    private var audioFocusKey: String {
        "\(showMusicPanel)\(showClipAudioPanel)\(selectedAudioID?.uuidString ?? "")"
    }

    // MARK: Transport

    /// B2: one compact row. Mono position/duration leading, prev/play/next
    /// dead-centre, fullscreen + zoom trailing. Frame-exact nudging moved onto
    /// the prev/next buttons' long press so the row stays three controls wide.
    private var transport: some View {
        HStack(spacing: 0) {
            Text(readout(editor.currentTime))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LumaTheme.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Long-press toggles between MM:SS:FF and plain MM:SS.
                .onLongPressGesture { showFrames.toggle(); LumaHaptics.shared.tap() }
            HStack(spacing: 22) {
                Button {} label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 15))
                }
                .buttonStyle(LumaHoldButtonStyle(
                    onTap: { editor.seekToBoundary(forward: false) },
                    onHold: { editor.stepFrame(-1) }))
                Button { editor.togglePlayback() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30)
                }
                .buttonStyle(.lumaPress)
                Button {} label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 15))
                }
                .buttonStyle(LumaHoldButtonStyle(
                    onTap: { editor.seekToBoundary(forward: true) },
                    onHold: { editor.stepFrame(1) }))
            }
            .foregroundStyle(.white)
            .disabled(editor.isEmpty)
            .sensoryFeedback(.selection, trigger: editor.currentTime)
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                if editor.isRebuilding {
                    ProgressView().tint(LumaTheme.textMuted).scaleEffect(0.7)
                }
                Button { showFullscreenPreview = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.lumaPress)
                .disabled(editor.isEmpty)
                // Zoom cycles the timeline scale; pinch on the scroller writes
                // the same value, so the two never disagree.
                Button {
                    timelineZoom = nextZoom(after: timelineZoom)
                    LumaHaptics.shared.tap()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .overlay(alignment: .bottomTrailing) {
                            Text(zoomLabel)
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(LumaTheme.accentBright)
                                .offset(x: 10, y: 3)
                        }
                }
                .buttonStyle(.lumaPress)
                .disabled(editor.isEmpty)
            }
            .foregroundStyle(LumaTheme.textSecondary)
            .frame(maxWidth: .infinity)
        }
    }

    /// Zoom presets, cycled by the transport button and clamped to the same
    /// range the pinch recogniser enforces.
    private static let zoomSteps: [CGFloat] = [25, 50, 100, 200]

    private func nextZoom(after current: CGFloat) -> CGFloat {
        let next = Self.zoomSteps.first { $0 > current + 0.5 } ?? Self.zoomSteps[0]
        return min(max(next, TimelineMetrics.minPPS), TimelineMetrics.maxPPS)
    }

    private var zoomLabel: String {
        String(format: "%g", (timelineZoom / 50 * 10).rounded() / 10)
    }

    /// Transport readout: `MM:SS:FF / MM:SS:FF` when showFrames, else MM:SS.
    private func readout(_ current: Double) -> String {
        showFrames
            ? "\(timecodeString(current)) / \(timecodeString(editor.totalDuration))"
            : "\(timeString(current)) / \(timeString(editor.totalDuration))"
    }

    /// MM:SS:FF at the composition frame rate (30 fps).
    private func timecodeString(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = Int(total) % 60
        let f = Int((total - floor(total)) / editor.frameDuration) % 30
        return String(format: "%02d:%02d:%02d", m, s, f)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == 1 ? "Speed" : String(format: "%g×", speed)
    }

    /// Adds a full-frame adjustment layer at the playhead, graded by a chosen
    /// look preset. Existing layers can be cleared.
    private var adjustLayerMenu: some View {
        Menu {
            // The whole library, grouped: signature presets, installed packs,
            // imported LUTs and saved looks all become adjustment layers.
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
            if !editor.adjustmentLayers.isEmpty {
                Button(role: .destructive) {
                    for layer in editor.adjustmentLayers { editor.removeAdjustmentLayer(id: layer.id) }
                    LumaHaptics.shared.tap()
                } label: { Label("Clear \(editor.adjustmentLayers.count) layer(s)", systemImage: "trash") }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.badge.a.fill")
                    .font(.system(size: 19, weight: .medium))
                Text("Adj Layer").font(.system(size: 13))
            }
            .foregroundStyle(editor.adjustmentLayers.isEmpty ? LumaTheme.textSecondary : LumaTheme.accentBright)
            .frame(maxWidth: .infinity)
        }
    }

    /// Audio-reactive visual style (pulse/glow/shake) driven by a lane's level.
    private var audioReactiveMenu: some View {
        Menu {
            Button {
                editor.setAudioReactive(nil); LumaHaptics.shared.tap()
            } label: {
                Label("Off", systemImage: editor.audioReactive == nil ? "checkmark" : "circle.slash")
            }
            ForEach(AudioReactiveStyle.allCases, id: \.self) { style in
                Button {
                    let src = editor.audioTracks.first?.id
                    editor.setAudioReactive(.init(style: style, strength: 1.0, sourceTrackID: src))
                    LumaHaptics.shared.tap()
                } label: {
                    if editor.audioReactive?.style == style {
                        Label(style.label, systemImage: "checkmark")
                    } else { Text(style.label) }
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle").font(.system(size: 19, weight: .medium))
                Text("Audio FX").font(.system(size: 13))
            }
            .foregroundStyle(editor.audioReactive == nil ? LumaTheme.textSecondary : LumaTheme.accentBright)
            .frame(maxWidth: .infinity)
        }
    }

    /// Ken Burns pan/zoom presets for the selected clip.
    private var kenBurnsMenu: some View {
        Menu {
            ForEach(EditorState.KenBurnsPreset.allCases, id: \.self) { preset in
                Button {
                    if let id = editor.selectedClipID {
                        editor.setKenBurns(id: id, preset: preset)
                        LumaHaptics.shared.tap()
                    }
                } label: { Text(preset.label) }
            }
            // Easing only matters once motion exists.
            if !(editor.selectedClip?.transformKeyframes.isEmpty ?? true) {
                Menu("Easing") {
                    ForEach(KeyframeEasing.allCases, id: \.self) { ease in
                        Button {
                            if let id = editor.selectedClipID {
                                editor.setKenBurnsEasing(id: id, easing: ease)
                                LumaHaptics.shared.tap()
                            }
                        } label: { Text(ease.label) }
                    }
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                Text("Motion").font(.system(size: 13))
            }
            .foregroundStyle((editor.selectedClip?.transformKeyframes.isEmpty ?? true)
                             ? LumaTheme.textSecondary : LumaTheme.accentBright)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        TimelineV2View(editor: editor,
                       onAddMusic: onAddMusic,
                       onTapMusic: { id in
                           selectedAudioID = id
                           showMusicPanel = true
                       },
                       onTapClipAudio: { id in
                           editor.selectedClipID = id
                           showClipAudioPanel = true
                       },
                       onTapTransition: { id in
                           transitionClipID = id
                       },
                       onAddOverlay: onAddOverlay,
                       onTapOverlay: { id in
                           selectedOverlayID = id
                           showOverlayPanel = true
                       },
                       onRecordVoiceover: {
                           guard !editor.isRecordingVoiceover else {
                               editor.stopVoiceover()
                               LumaHaptics.shared.exportSuccess()
                               return
                           }
                           editor.startVoiceover()
                           LumaHaptics.shared.tap()
                       },
                       onAddClip: onAdd,
                       zoom: $timelineZoom)
    }

    // MARK: Music panel

    /// B3 sub-tool chips for the audio panel. The panel shows ONE section at a
    /// time, so a 340 pt sheet never has to hide half its controls behind a
    /// scroll — and the chip row is a live control, not decoration.
    enum MusicSubTool {
        static let volume = "Volume"
        static let fade = "Fade"
        static let effects = "Effects"
        static let beats = "Beats"
        static let all = [volume, fade, effects, beats]
    }

    @ViewBuilder
    private func musicPanel(music: EditorState.MusicTrack) -> some View {
        VStack(spacing: 14) {
            switch musicSubTool {
            case MusicSubTool.fade:      musicFadeSection(music: music)
            case MusicSubTool.effects:   musicEffectsSection(music: music)
            case MusicSubTool.beats:     musicBeatsSection(music: music)
            default:                     musicVolumeSection(music: music)
            }
            musicTerminalActions(music: music)
        }
        .padding(16)
        .lumaCard()
    }

    /// Volume: which lane the track lives in, and how loud it is.
    private func musicVolumeSection(music: EditorState.MusicTrack) -> some View {
        VStack(spacing: 14) {
            // Lane kind picker (colour/icon).
            HStack(spacing: 8) {
                ForEach(AudioLaneKind.allCases, id: \.self) { kind in
                    let on = music.kind == kind
                    Button {
                        editor.setAudioKind(id: music.id, kind)
                        LumaHaptics.shared.tap()
                    } label: {
                        Label(kind.label, systemImage: kind.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? .black : .white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(on ? AnyShapeStyle(kind.tint) : AnyShapeStyle(LumaTheme.surface),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            InlineSlider(title: "Volume", value: Binding(
                get: { editor.audioTracks.first(where: { $0.id == music.id })?.volume ?? 100 },
                set: { editor.setMusicVolume(id: music.id, $0) }
            )) { "\(Int($0))%" }
        }
    }

    /// Fade: in/out lengths, curve shape, and the full envelope editor.
    private func musicFadeSection(music: EditorState.MusicTrack) -> some View {
        VStack(spacing: 14) {
            // Fades (A3) + curve shape.
            let live = { editor.audioTracks.first(where: { $0.id == music.id }) }
            InlineSlider(title: "Fade In", value: Binding(
                get: { live()?.fadeIn ?? 0 },
                set: { editor.setMusicFade(id: music.id, fadeIn: $0) }
            ), range: 0...5) { String(format: "%.1fs", $0) }
            InlineSlider(title: "Fade Out", value: Binding(
                get: { live()?.fadeOut ?? 0 },
                set: { editor.setMusicFade(id: music.id, fadeOut: $0) }
            ), range: 0...5) { String(format: "%.1fs", $0) }
            HStack(spacing: 8) {
                ForEach(FadeCurve.allCases, id: \.self) { curve in
                    let on = (live()?.fadeCurve ?? .linear) == curve
                    Button {
                        editor.setMusicFade(id: music.id, curve: curve)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text(curve.label).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(on ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(on ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            HStack(spacing: 10) {
                Button {
                    envelopeTrackID = music.id
                    LumaHaptics.shared.tap()
                } label: {
                    Label("Envelope", systemImage: "waveform.path.ecg.rectangle")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(LumaTheme.surface, in: Capsule())
                        .overlay(alignment: .trailing) {
                            if !(live()?.volumePoints.isEmpty ?? true) {
                                Circle().fill(LumaTheme.teal).frame(width: 7, height: 7).offset(x: 4)
                            }
                        }
                }
                .buttonStyle(.lumaPress)
                Spacer(minLength: 0)
            }
        }
    }

    /// Effects: the EQ/reverb stack plus the two mix behaviours.
    private func musicEffectsSection(music: EditorState.MusicTrack) -> some View {
        let live = { editor.audioTracks.first(where: { $0.id == music.id }) }
        return VStack(spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    effectsTrackID = music.id
                    LumaHaptics.shared.tap()
                } label: {
                    Label("Effects", systemImage: "slider.horizontal.2.square")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(LumaTheme.surface, in: Capsule())
                        .overlay(alignment: .trailing) {
                            if !(live()?.effects.isNeutral ?? true) {
                                Circle().fill(LumaTheme.teal).frame(width: 7, height: 7).offset(x: 4)
                            }
                        }
                }
                .buttonStyle(.lumaPress)
                Spacer(minLength: 0)
            }

            // Auto-duck (A5) + loop (A6) toggles.
            HStack(spacing: 14) {
                Toggle("Duck under voice", isOn: Binding(
                    get: { live()?.duckingEnabled ?? false },
                    set: { editor.setMusicDucking(id: music.id, $0) }))
                    .font(.system(size: 13, weight: .semibold)).tint(LumaTheme.accentBright)
                Toggle("Loop", isOn: Binding(
                    get: { live()?.isLooping ?? false },
                    set: { editor.setMusicLooping(id: music.id, $0) }))
                    .font(.system(size: 13, weight: .semibold)).tint(LumaTheme.accentBright)
                    .fixedSize()
            }
        }
    }

    /// Beats: detect the grid, then cut every clip to it (C6).
    private func musicBeatsSection(music: EditorState.MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    LumaHaptics.shared.tap()
                    Task { await editor.detectBeats(trackID: music.id) }
                } label: {
                    Label(editor.isDetectingBeats ? "Detecting…" : "Detect Beats",
                          systemImage: "waveform.and.magnifyingglass")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(LumaTheme.surface, in: Capsule())
                }
                .buttonStyle(.lumaPress)
                Button {
                    LumaHaptics.shared.tap()
                    Task { await editor.autoCutToBeats(trackID: music.id) }
                } label: {
                    Label("Auto-Cut", systemImage: "scissors.badge.ellipsis")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(LumaTheme.accent, in: Capsule())
                }
                .buttonStyle(.lumaPress)
            }
            Text(music.beatMarkers.isEmpty
                 ? "Detect the beat grid, then cut every clip to it."
                 : "\(music.beatMarkers.count) beats detected.")
                .font(.system(size: 12))
                .foregroundStyle(LumaTheme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mute / Remove: terminal actions, visible from every sub-tool so the
    /// track can always be silenced or dropped without hunting for a chip.
    private func musicTerminalActions(music: EditorState.MusicTrack) -> some View {
        HStack(spacing: 12) {
            Button {
                editor.setMusicMuted(id: music.id, !music.isMuted)
            } label: {
                Label(music.isMuted ? "Unmute" : "Mute",
                      systemImage: music.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(music.isMuted ? AnyShapeStyle(LumaTheme.accentDeep)
                                              : AnyShapeStyle(LumaTheme.surface),
                                in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.lumaPress)
            Button {
                editor.removeAudioTrack(id: music.id)
                withAnimation(.easeOut(duration: 0.15)) { showMusicPanel = false }
            } label: {
                Label("Remove", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LumaTheme.orange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.lumaPress)
        }
    }

    // MARK: Transition picker

    private var transitionPicker: some View {
        VStack(spacing: 12) {
            TechReadout("TRANSITION", size: 11, color: LumaTheme.textSecondary)
            // 15 styles now — grouped horizontal scroller (Basic / Motion / FX).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(["Basic", "Motion", "FX"], id: \.self) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            TechReadout(group.uppercased(), size: 9, color: LumaTheme.textMuted)
                            HStack(spacing: 8) {
                                ForEach(TransitionStyle.allCases.filter { $0.category == group }, id: \.self) { style in
                                    ToolTile(title: style.label,
                                             icon: style.icon,
                                             selected: currentTransition == style) {
                                        if let id = transitionClipID {
                                            editor.setTransition(afterClipID: id, style: style,
                                                                 duration: currentTransitionClip?.transitionDuration)
                                            LumaHaptics.shared.tap()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
            }

            // Apply the current style at every cut in one step.
            if currentTransition != .none, editor.clips.count > 2 {
                Button {
                    editor.setTransitionForAllCuts(style: currentTransition,
                                                   duration: currentTransitionClip?.transitionDuration)
                    LumaHaptics.shared.tap()
                } label: {
                    Label("Apply to All Cuts", systemImage: "square.stack.3d.down.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(LumaTheme.accent, in: Capsule())
                }
                .buttonStyle(.lumaPress)
            }

            // Editable duration (gap fix): nil = the style default.
            if currentTransition != .none {
                HStack(spacing: 8) {
                    Text("Duration")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
                    Spacer()
                    ForEach([0.3, 0.6, 1.0, 1.5], id: \.self) { seconds in
                        let selected = abs(currentTransitionDuration - seconds) < 0.01
                        Button {
                            if let id = transitionClipID {
                                editor.setTransition(afterClipID: id,
                                                     style: currentTransition,
                                                     duration: seconds)
                                LumaHaptics.shared.tap()
                            }
                        } label: {
                            Text(String(format: "%.1fs", seconds))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(selected ? LumaTheme.accent : LumaTheme.surface,
                                            in: Capsule())
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }

    private var currentTransitionClip: EditorState.Clip? {
        guard let id = transitionClipID else { return nil }
        return editor.clips.first { $0.id == id }
    }

    private var currentTransition: TransitionStyle {
        currentTransitionClip?.transitionAfter ?? .none
    }

    private var currentTransitionDuration: Double {
        currentTransitionClip?.transitionDuration ?? currentTransition.duration
    }

    // MARK: Clip audio panel

    private func clipAudioPanel(clip: EditorState.Clip) -> some View {
        VStack(spacing: 14) {
            // Title and Done live in ToolPanelScaffold.
            InlineSlider(title: "Volume", value: Binding(
                get: { editor.selectedClip?.volume ?? 100 },
                set: { editor.setClipVolume(id: clip.id, $0) }
            )) { "\(Int($0))%" }
            .disabled(!clip.hasAudio)
            .opacity(clip.hasAudio ? 1 : 0.4)
            HStack(spacing: 12) {
                Button {
                    editor.setClipMuted(id: clip.id, !(editor.selectedClip?.isMuted ?? false))
                } label: {
                    Label((editor.selectedClip?.isMuted ?? false) ? "Unmute clip" : "Mute clip",
                          systemImage: (editor.selectedClip?.isMuted ?? false)
                              ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background((editor.selectedClip?.isMuted ?? false)
                                    ? AnyShapeStyle(LumaTheme.accentDeep)
                                    : AnyShapeStyle(LumaTheme.surface),
                                    in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.lumaPress)
                .disabled(!clip.hasAudio)
                Button {
                    showClipAudioPanel = false
                    onOpenAudio()
                } label: {
                    Label("Project audio", systemImage: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.lumaPress)
            }
        }
        .padding(16)
        .lumaCard()
    }

    // MARK: Trim panel

    private func trimPanel(clip: EditorState.Clip) -> some View {
        VStack(spacing: 14) {
            // Title, range readout and Done (which applies) live in the scaffold.
            InlineSlider(title: "Start", value: $trimStart,
                         range: 0...max(clip.assetDuration - 0.2, 0.01)) { timeString($0) }
                .onChange(of: trimStart) { _, new in
                    if new > trimEnd - 0.2 { trimEnd = min(new + 0.2, clip.assetDuration) }
                }
            InlineSlider(title: "End", value: $trimEnd,
                         range: 0.2...clip.assetDuration) { timeString($0) }
                .onChange(of: trimEnd) { _, new in
                    if new < trimStart + 0.2 { trimStart = max(new - 0.2, 0) }
                }
            // Cancel: leave without committing the drafted in/out points.
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showTrimPanel = false }
            } label: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.lumaPress)
        }
        .padding(16)
        .lumaCard()
    }

    // MARK: Looks strip

    private var looksStrip: some View {
        VStack(spacing: 10) {
            if let clipID = looksTargetClipID,
               let clip = editor.clips.first(where: { $0.id == clipID }) {
                HStack(spacing: 10) {
                    TechnicalReadout("Clip Look")
                    Spacer()
                    if clip.grade != nil {
                        Button("Copy to All") {
                            editor.applyGradeToAllClips(clip.grade)
                            LumaHaptics.shared.tap()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumaTheme.accent)
                        Button("Use Timeline Grade") {
                            editor.setClipGrade(id: clipID, nil)
                            LumaHaptics.shared.tap()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 22)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    // Per-clip target: None-first, so clearing the clip's
                    // grade is as easy as applying one.
                    if let clipID = looksTargetClipID {
                        clipNoneTile(clipID: clipID)
                    }
                    // The library strip — recents → favourites → rest — with
                    // the FULL library (chips, search, import) one tap away.
                    ForEach(app.library.stripLooks()) { look in
                        LookStripTile(look: look,
                                      image: lookThumbs.images[look.thumbKey],
                                      selected: stripSelected(look),
                                      size: CGSize(width: 66, height: 56),
                                      radius: 12) {
                            app.select(look: look, forClip: looksTargetClipID)
                            LumaHaptics.shared.tap()
                        }
                    }
                    AllLooksTile(size: CGSize(width: 66, height: 56), radius: 12) {
                        showLookBrowser = true
                        LumaHaptics.shared.tap()
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 22)
            }
            .lumaEdgeFade()
        }
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.library.all.count)") {
            lookThumbs.render(source: app.previewFrame, library: app.library.all,
                              fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        // Sheet-over-sheet: the browser rides above the strip's tool sheet.
        .lumaToolSheet(isPresented: $showLookBrowser, style: .tallPanel) {
            LookBrowserSheet(context: looksTargetClipID.map { .editorClip($0) }
                                ?? .editorTimeline)
        }
    }

    /// One selection truth for the editor strip: per-clip grade when a clip
    /// is targeted, global grade state otherwise.
    private func stripSelected(_ look: LibraryLook) -> Bool {
        if let id = looksTargetClipID {
            guard let g = editor.clips.first(where: { $0.id == id })?.grade else { return false }
            switch look.source {
            case .builtIn(let p): return g.lutID == nil && g.baseLookName == p.name
            case .lut(let f):     return g.lutID == f.id
            case .saved(let s):   return g.baseLookName == s.baseLookName && g.lutID == s.lutID
            }
        }
        return app.isCurrent(look)
    }

    /// Dashed None tile for a targeted clip — clears its grade so it follows
    /// the timeline grade again.
    private func clipNoneTile(clipID: UUID) -> some View {
        let active = editor.clips.first(where: { $0.id == clipID })?.grade == nil
        return Button {
            editor.setClipGrade(id: clipID, nil)
            LumaHaptics.shared.tap()
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LumaTheme.background)
                    .frame(width: 66, height: 56)
                    .overlay {
                        TechReadout("NONE", size: 8,
                                    color: active ? LumaTheme.accentBright : LumaTheme.textMuted)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]))
                        .foregroundStyle(active ? LumaTheme.accentBright : .white.opacity(0.18)))
                Text("None")
                    .font(.system(size: 11))
                    .foregroundStyle(active ? .white : LumaTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 70)
            }
        }
        .buttonStyle(.lumaPress)
    }

    /// CapCut-style "Edit": select the clip under the playhead so the
    /// inspector dock slides in without hunting for a tap target.
    private func selectClipAtPlayhead() {
        guard !editor.isEmpty else { return }
        var elapsed: Double = 0
        for clip in editor.clips {
            elapsed += clip.timelineDuration
            if editor.currentTime < elapsed {
                editor.selectedClipID = clip.id
                return
            }
        }
        editor.selectedClipID = editor.clips.last?.id
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = Int(total) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Overlay panel (T1)

/// PIP inspector: opacity + size sliders live-update the compositor via
/// `OverlayLayout` (no rebuild); position via a 3×3 preset grid plus fine
/// X/Y sliders; remove drops the overlay from the lane.
private struct OverlayPanel: View {
    @ObservedObject var editor: EditorState
    let overlayID: UUID
    let onClose: () -> Void

    private var overlay: EditorState.OverlayItem? {
        editor.overlays.first { $0.id == overlayID }
    }

    @State private var draftText: String = ""
    @FocusState private var textFieldFocused: Bool

    private static let textSwatches = ["#FFFFFF", "#0A0D14", "#F5C518", "#FF5C5C", "#7A68EE", "#3EC8AC"]

    /// Text-layer controls (T6): content, typography preset, colour.
    private var textControls: some View {
        VStack(spacing: 10) {
            TextField("Your Title", text: $draftText)
                .focused($textFieldFocused)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .submitLabel(.done)
                .onSubmit { editor.setOverlayText(id: overlayID, draftText) }
                .onChange(of: textFieldFocused) { _, focused in
                    if !focused { editor.setOverlayText(id: overlayID, draftText) }
                }
                .onAppear {
                    draftText = overlay?.text ?? ""
                    // Animated titles are invisible at their own t=0 (popIn/
                    // fadeIn start at opacity 0) — park the playhead inside the
                    // hold region so the user styles text they can SEE.
                    if let o = overlay, o.text != nil,
                       o.textAnimation != TextAnimation.none.rawValue {
                        let holdStart = o.timelineOffset + TextAnimator.defaultDuration + 0.05
                        let holdEnd = o.timelineEnd - TextAnimator.defaultDuration - 0.05
                        if editor.currentTime < holdStart || editor.currentTime > max(holdStart, holdEnd) {
                            editor.seek(to: min(holdStart, max(o.timelineOffset, holdEnd)))
                        }
                    }
                }

            HStack(spacing: 8) {
                ForEach(EditorState.TextLayerStyle.allCases, id: \.self) { style in
                    let selected = overlay?.textStyle == style
                    Button {
                        editor.setOverlayTextStyle(id: overlayID, style)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text(style.label)
                            .font(.footnote.weight(.semibold))
                            .fixedSize()          // chips never wrap ("Sub-\ntitle")
                            .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? LumaTheme.accent : LumaTheme.surface,
                                        in: Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
                Spacer()
                ForEach(Self.textSwatches, id: \.self) { hex in
                    let selected = overlay?.textColorHex.uppercased() == hex
                    Button {
                        editor.setOverlayTextColor(id: overlayID, hex)
                        LumaHaptics.shared.tap()
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(selected ? LumaTheme.accentBright : .white.opacity(0.2),
                                                     lineWidth: selected ? 2 : 1))
                    }
                    .buttonStyle(.lumaPress)
                }
            }

            // F3 — animated-text preset.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TextAnimation.allCases, id: \.self) { preset in
                        let on = (overlay?.textAnimation ?? "none") == preset.rawValue
                        Button {
                            editor.setTextAnimation(id: overlayID, preset)
                            LumaHaptics.shared.tap()
                        } label: {
                            Label(preset.label, systemImage: preset.icon)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(on ? .white : LumaTheme.textSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(on ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
            }

            // F2 — font, outline, box, alignment.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Preset font") { editor.setTextDecor(id: overlayID, fontName: .some(nil)) }
                        ForEach(FontLibrary.builtInFontNames, id: \.self) { name in
                            Button(name) { editor.setTextDecor(id: overlayID, fontName: .some(name)) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "character.cursor.ibeam").font(.system(size: 12))
                            Text(overlay?.textFontName ?? "Preset font")
                                .font(.footnote.weight(.semibold)).lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(LumaTheme.surface, in: Capsule())
                    }

                    ForEach(["left", "center", "right"], id: \.self) { align in
                        let on = (overlay?.textAlignment ?? "center") == align
                        Button {
                            editor.setTextDecor(id: overlayID, alignment: align)
                            LumaHaptics.shared.tap()
                        } label: {
                            Image(systemName: "text.align\(align.capitalized)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? .white : LumaTheme.textSecondary)
                                .frame(width: 34, height: 30)
                                .background(on ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
                        }
                        .buttonStyle(.lumaPress)
                    }

                    let stroked = (overlay?.textStrokeHex != nil)
                    Button {
                        editor.setTextDecor(id: overlayID,
                                            strokeHex: stroked ? .some(nil) : .some("#000000"),
                                            strokeWidth: stroked ? 0 : 6)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text("Outline")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(stroked ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(stroked ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.lumaPress)

                    let boxed = (overlay?.textBoxHex != nil)
                    Button {
                        editor.setTextDecor(id: overlayID, boxHex: boxed ? .some(nil) : .some("#000000"))
                        LumaHaptics.shared.tap()
                    } label: {
                        Text("Box")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(boxed ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(boxed ? LumaTheme.accent : LumaTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.lumaPress)
                }
            }

            if overlay?.textStrokeHex != nil {
                InlineSlider(title: "Outline width",
                             value: Binding(
                                get: { overlay?.textStrokeWidth ?? 6 },
                                set: { editor.setTextDecor(id: overlayID, strokeWidth: $0) }),
                             range: 1...20) { String(format: "%.0f", $0) }
            }
        }
    }

    /// 3×3 anchor presets in unit canvas coordinates (y down).
    private static let anchors: [[CGPoint]] = {
        let xs: [CGFloat] = [0.22, 0.5, 0.78]
        let ys: [CGFloat] = [0.18, 0.5, 0.82]
        return ys.map { y in xs.map { x in CGPoint(x: x, y: y) } }
    }()

    var body: some View {
        // The panel's own header and scroller now come from ToolPanelScaffold
        // (B3) — nesting a second vertical ScrollView here would fight it.
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: overlay?.isImage == true ? "photo" : "rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LumaTheme.teal)
                Text(overlay?.title.isEmpty == false ? overlay!.title : "Overlay")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1fs", overlay?.duration ?? 0))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .monospacedDigit()
            }

            if overlay?.text != nil {
                textControls
            } else {
                // Media overlays: blend / chroma / mask / adjust / border.
                OverlayEffectsPanel(editor: editor, overlayID: overlayID)
            }

            InlineSlider(title: "Opacity", value: Binding(
                get: { (overlay?.opacity ?? 1) * 100 },
                set: { editor.setOverlayOpacity(id: overlayID, $0 / 100) }
            )) { "\(Int($0))%" }

            InlineSlider(title: "Size", value: Binding(
                get: { (overlay?.sizeFraction ?? 0.45) * 100 },
                set: { editor.setOverlaySize(id: overlayID, $0 / 100) }
            ), range: 25...100) { "\(Int($0))%" }

            InlineSlider(title: "Rotation", value: Binding(
                get: { overlay?.rotationDegrees ?? 0 },
                set: { editor.setOverlayRotation(id: overlayID, $0) }
            ), range: -180...180) { "\(Int($0))°" }

            // Z-order: move the overlay between stacking lanes.
            HStack(spacing: 12) {
                Text("Layer \((overlay?.lane ?? 0) + 1)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    editor.nudgeOverlayLane(id: overlayID, by: -1)
                    LumaHaptics.shared.tap()
                } label: {
                    Label("Back", systemImage: "square.2.layers.3d.bottom.filled")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(LumaTheme.surface, in: Capsule())
                }
                .buttonStyle(.lumaPress)
                .disabled((overlay?.lane ?? 0) <= 0)
                Button {
                    editor.nudgeOverlayLane(id: overlayID, by: 1)
                    LumaHaptics.shared.tap()
                } label: {
                    Label("Forward", systemImage: "square.2.layers.3d.top.filled")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(LumaTheme.surface, in: Capsule())
                }
                .buttonStyle(.lumaPress)
            }

            // Keyframes (T5): pin the current placement at the playhead;
            // sliders then animate between pins.
            HStack(spacing: 10) {
                Button {
                    editor.addOverlayKeyframe(id: overlayID)
                    LumaHaptics.shared.tap()
                } label: {
                    Label("Keyframe", systemImage: "diamond.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(LumaTheme.accent, in: Capsule())
                }
                .buttonStyle(.lumaPress)
                if let count = overlay?.keyframes.count, count > 0 {
                    Text("\(count) pinned")
                        .font(.footnote)
                        .foregroundStyle(LumaTheme.textSecondary)
                    Spacer()
                    Button("Clear") {
                        editor.clearOverlayKeyframes(id: overlayID)
                        LumaHaptics.shared.tap()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
                } else {
                    Text("Pin placements to animate")
                        .font(.footnote)
                        .foregroundStyle(LumaTheme.textMuted)
                    Spacer()
                }
            }

            // Overlay audio (video overlays carry sound now).
            if overlay?.isImage == false {
                HStack(spacing: 10) {
                    Button {
                        editor.setOverlayMuted(id: overlayID, !(overlay?.isMuted ?? false))
                        LumaHaptics.shared.tap()
                    } label: {
                        Image(systemName: overlay?.isMuted == true
                              ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(overlay?.isMuted == true
                                             ? LumaTheme.textMuted : LumaTheme.teal)
                            .frame(width: 32, height: 32)
                            .background(LumaTheme.surface, in: Circle())
                    }
                    .buttonStyle(.lumaPress)
                    InlineSlider(title: "Volume", value: Binding(
                        get: { overlay?.volume ?? 100 },
                        set: { editor.setOverlayVolume(id: overlayID, $0) }
                    )) { "\(Int($0))%" }
                    .opacity(overlay?.isMuted == true ? 0.4 : 1)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                // 3×3 position preset grid.
                VStack(spacing: 6) {
                    TechReadout("POSITION", size: 10, color: LumaTheme.textMuted)
                    VStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { row in
                            HStack(spacing: 5) {
                                ForEach(0..<3, id: \.self) { column in
                                    anchorButton(Self.anchors[row][column])
                                }
                            }
                        }
                    }
                }
                // Fine placement.
                VStack(spacing: 10) {
                    InlineSlider(title: "X", value: Binding(
                        get: { (overlay?.center.x ?? 0.5) * 100 },
                        set: { new in
                            let y = overlay?.center.y ?? 0.5
                            editor.setOverlayCenter(id: overlayID,
                                                    CGPoint(x: new / 100, y: y))
                        }
                    )) { "\(Int($0))" }
                    InlineSlider(title: "Y", value: Binding(
                        get: { (overlay?.center.y ?? 0.5) * 100 },
                        set: { new in
                            let x = overlay?.center.x ?? 0.5
                            editor.setOverlayCenter(id: overlayID,
                                                    CGPoint(x: x, y: new / 100))
                        }
                    )) { "\(Int($0))" }
                }
            }

            Button {
                editor.removeOverlay(id: overlayID)
                onClose()
            } label: {
                Label("Remove Overlay", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LumaTheme.orange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.lumaPress)
        }
        .padding(16)
        .lumaCard()
    }

    private func anchorButton(_ anchor: CGPoint) -> some View {
        let current = overlay?.center ?? CGPoint(x: 0.5, y: 0.5)
        let selected = abs(current.x - anchor.x) < 0.06 && abs(current.y - anchor.y) < 0.06
        return Button {
            editor.setOverlayCenter(id: overlayID, anchor)
            LumaHaptics.shared.tap()
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? AnyShapeStyle(LumaTheme.accentSoft)
                               : AnyShapeStyle(.ultraThinMaterial))
                .frame(width: 26, height: 26)
                .overlay(Circle()
                    .fill(selected ? LumaTheme.accentBright : .white.opacity(0.45))
                    .frame(width: 5, height: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? LumaTheme.accent : .white.opacity(0.1),
                                  lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
    }
}

// MARK: - Cells

// MARK: - Hex colours (text-layer swatches)

extension Color {
    /// "#RRGGBB" convenience for the text-layer palette.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(cleaned, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Fullscreen preview (TikTok-style)

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
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.lumaPress)
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                Text(timeString(editor.currentTime))
                Slider(value: Binding(
                    get: { editor.currentTime },
                    set: { editor.seek(to: $0) }
                ), in: 0...max(editor.totalDuration, 0.1))
                .tint(.white)
                Text(timeString(editor.totalDuration))
            }
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .animation(.easeOut(duration: 0.18), value: editor.isPlaying)
        .statusBarHidden()
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d", Int(total) / 60, Int(total) % 60)
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

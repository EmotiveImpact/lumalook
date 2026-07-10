import SwiftUI
import AVKit
import PhotosUI

struct EditorTimelineView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var addPickerItem: PhotosPickerItem?
    @State private var showAddPicker = false
    @State private var isLoadingClip = false
    @State private var showTrimPanel = false
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 1
    @State private var showLooksStrip = false
    @State private var isExporting = false
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
                exportError: exportError,
                onBack: { dismiss() },
                onAdd: { showAddPicker = true },
                onExport: { startExport() },
                onOpenAudio: { app.path.append(.audio) },
                onOpenCrop: { app.path.append(.cropFormat) },
                onOpenAdjust: { app.path.append(.customLook) }
            )
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .photosPicker(isPresented: $showAddPicker, selection: $addPickerItem, matching: .videos)
        .onChange(of: addPickerItem) { _, newItem in
            guard let newItem else { return }
            isLoadingClip = true
            Task {
                defer { isLoadingClip = false }
                if let video = try? await newItem.loadTransferable(type: PickedVideo.self) {
                    await editor.addClip(from: video.url)
                }
                addPickerItem = nil
            }
        }
        .onAppear {
            // Continuity: seed the timeline with the Apply-a-Look clip.
            if editor.isEmpty, let url = app.selectedVideoURL {
                Task { await editor.addClip(from: url) }
            }
        }
        .onDisappear {
            editor.saveProject()
        }
        .overlay {
            if isExporting {
                ExportOverlay(progress: app.exporter.progress) { app.exporter.cancel() }
            }
        }
    }

    private func startExport() {
        guard !editor.isEmpty else {
            exportError = "Add a clip to the timeline first."
            return
        }
        exportError = nil
        isExporting = true
        Task {
            do {
                let built = try await editor.buildComposition()
                let mix = editor.makeAudioMix(for: built.composition)
                let url = try await app.exporter.export(asset: built.composition,
                                                        videoComposition: built.videoComposition,
                                                        audioMix: mix)
                try await app.exporter.saveToPhotos(url: url)
                app.lastExportURL = url
                isExporting = false
                app.path.append(.exportComplete)
            } catch is CancellationError {
                isExporting = false
            } catch {
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Content

private struct EditorContent: View {
    @ObservedObject var editor: EditorState
    let isLoadingClip: Bool
    @Binding var showTrimPanel: Bool
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var showLooksStrip: Bool
    let exportError: String?
    let onBack: () -> Void
    let onAdd: () -> Void
    let onExport: () -> Void
    let onOpenAudio: () -> Void
    let onOpenCrop: () -> Void
    let onOpenAdjust: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                header
                preview
                transport
                Hairline()
                editTools
                Hairline()
                timeline

                if showTrimPanel, let clip = editor.selectedClip {
                    trimPanel(clip: clip)
                }
                if showLooksStrip {
                    looksStrip
                }
                if let exportError {
                    Text(exportError)
                        .font(.system(size: 13))
                        .foregroundStyle(LumaTheme.orange)
                }

                Hairline()
                bottomTools
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text(editor.projectTitle)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            Spacer()
            Button { editor.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(editor.canUndo ? .white : LumaTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!editor.canUndo)
            Button { editor.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(editor.canRedo ? .white : LumaTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!editor.canRedo)
            Button(action: onExport) {
                Text("Export")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .opacity(editor.isEmpty ? 0.4 : 1)
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        Group {
            if let player = editor.player {
                VideoPlayer(player: player)
                    .onDisappear { if editor.isPlaying { editor.togglePlayback() } }
            } else {
                SceneArt(scene: .forest)
                    .overlay {
                        VStack(spacing: 12) {
                            if isLoadingClip {
                                ProgressView().tint(.white)
                                Text("Loading clip…")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            } else {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white)
                                Text("Start your edit")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                Button(action: onAdd) {
                                    Text("ADD A CLIP")
                                        .font(.system(size: 14, weight: .bold))
                                        .tracking(1.2)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 22)
                                        .padding(.vertical, 12)
                                        .background(LumaTheme.accent, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(22)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
                    }
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.06)))
    }

    // MARK: Transport

    private var transport: some View {
        HStack {
            Text("\(timeString(editor.currentTime)) / \(timeString(editor.totalDuration))")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Spacer()
            HStack(spacing: 28) {
                Button { editor.seekToBoundary(forward: false) } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 17))
                }
                Button { editor.togglePlayback() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .frame(width: 30)
                }
                Button { editor.seekToBoundary(forward: true) } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 17))
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .disabled(editor.isEmpty)
            Spacer()
            if editor.isRebuilding {
                ProgressView().tint(LumaTheme.textMuted).scaleEffect(0.8)
            } else {
                Color.clear.frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Edit tools

    private var editTools: some View {
        HStack {
            FlatTool(title: "Add", icon: "plus", action: onAdd)
            FlatTool(title: "Trim", icon: "scissors", selected: showTrimPanel) {
                guard let clip = editor.selectedClip else { return }
                trimStart = clip.trimStart
                trimEnd = clip.trimEnd
                withAnimation(.easeOut(duration: 0.15)) { showTrimPanel.toggle() }
            }
            FlatTool(title: "Split", icon: "square.split.2x1") {
                editor.splitAtPlayhead()
            }
            FlatTool(title: "Delete", icon: "trash") {
                editor.deleteSelected()
            }
            FlatTool(title: "Volume", icon: "speaker.wave.2", action: onOpenAudio)
            speedMenu
        }
        .opacity(editor.isEmpty ? 0.35 : 1)
        .disabled(editor.isEmpty)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                Button {
                    editor.setSpeed(speed)
                } label: {
                    if editor.selectedClip?.speed == speed {
                        Label(speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(speed))
                    }
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 19, weight: .medium))
                Text(editor.selectedClip.map { speedLabel($0.speed) } ?? "Speed")
                    .font(.system(size: 13))
            }
            .foregroundStyle((editor.selectedClip?.speed ?? 1) != 1 ? LumaTheme.accentBright : LumaTheme.textSecondary)
            .frame(maxWidth: .infinity)
        }
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == 1 ? "Speed" : String(format: "%g×", speed)
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        if editor.isEmpty {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LumaTheme.surface)
                                .overlay(Text("Timeline is empty")
                                    .font(.system(size: 13))
                                    .foregroundStyle(LumaTheme.textMuted))
                        } else {
                            ForEach(editor.clips) { clip in
                                ClipCell(clip: clip,
                                         totalDuration: editor.totalDuration,
                                         stripWidth: width,
                                         selected: clip.id == editor.selectedClipID)
                                    .onTapGesture { editor.selectedClipID = clip.id }
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
                    }

                    if !editor.isEmpty, editor.totalDuration > 0 {
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2.5)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .offset(x: width * CGFloat(editor.currentTime / editor.totalDuration))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard editor.totalDuration > 0 else { return }
                            let fraction = min(max(0, value.location.x / width), 1)
                            editor.seek(to: fraction * editor.totalDuration)
                        }
                )
            }
            .frame(height: 66)

            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .bold))
                Text(editor.muteAudio ? "Audio muted" : "Ambient Beat")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(timeString(editor.totalDuration))
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(editor.muteAudio ? AnyShapeStyle(LumaTheme.surfaceStrong)
                                         : AnyShapeStyle(LumaTheme.accentDeep),
                        in: RoundedRectangle(cornerRadius: 12))
            .onTapGesture(perform: onOpenAudio)
        }
    }

    // MARK: Trim panel

    private func trimPanel(clip: EditorState.Clip) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("Trim Clip")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(timeString(trimStart)) – \(timeString(trimEnd))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.accentBright)
                    .monospacedDigit()
            }
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
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showTrimPanel = false }
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
                Button {
                    editor.applyTrim(start: trimStart, end: trimEnd)
                    withAnimation(.easeOut(duration: 0.15)) { showTrimPanel = false }
                } label: {
                    Text("APPLY TRIM")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Looks strip

    private var looksStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(MockData.looks) { look in
                    LookStripCell(look: look, editor: editor)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Bottom tools

    private var bottomTools: some View {
        HStack {
            FlatTool(title: "Looks", icon: "camera.filters", selected: showLooksStrip) {
                withAnimation(.easeOut(duration: 0.15)) { showLooksStrip.toggle() }
            }
            FlatTool(title: "Adjust", icon: "slider.horizontal.3", action: onOpenAdjust)
            FlatTool(title: "Audio", icon: "music.note", action: onOpenAudio)
            FlatTool(title: "Crop", icon: "crop", action: onOpenCrop)
            FlatTool(title: "Text", icon: "textformat")
            FlatTool(title: "Overlay", icon: "square.on.square")
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = Int(total) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Cells

private struct ClipCell: View {
    let clip: EditorState.Clip
    let totalDuration: Double
    let stripWidth: CGFloat
    let selected: Bool

    var body: some View {
        Group {
            if let thumb = clip.thumbnail {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LumaTheme.surfaceStrong
            }
        }
        .frame(width: cellWidth, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
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
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? LumaTheme.accentBright : .white.opacity(0.08),
                    lineWidth: selected ? 2.5 : 1))
    }

    private var cellWidth: CGFloat {
        guard totalDuration > 0 else { return 88 }
        let proportional = stripWidth * CGFloat(clip.timelineDuration / totalDuration)
        return max(44, proportional - 3)
    }
}

private struct LookStripCell: View {
    let look: LookPreset
    @ObservedObject var editor: EditorState
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Button {
            app.selectedLUT = nil
            app.selectedLook = look   // lookState updates flow straight into the running preview
        } label: {
            VStack(spacing: 6) {
                SceneThumb(scene: .forest, grade: look.gradeTint, radius: 12,
                           selected: app.selectedLook.id == look.id && app.selectedLUT == nil)
                    .frame(width: 66, height: 56)
                Text(look.name)
                    .font(.system(size: 11))
                    .foregroundStyle(app.selectedLook.id == look.id ? .white : LumaTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 70)
            }
        }
        .buttonStyle(.plain)
    }
}

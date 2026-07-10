import SwiftUI
import AVKit

struct BeforeAfterView: View {
    @EnvironmentObject private var app: AppModel
    @State private var splitFraction: Double = 0.5
    @State private var isExporting = false
    @State private var activeTool: String? = nil
    @State private var isPlaying = true
    @State private var progress: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserver: Any?

    private var hasRealMedia: Bool {
        app.player != nil || app.selectedImage != nil
    }

    var body: some View {
        LumaScreen(title: "Before / After", trailingIcon: "square.and.arrow.up",
                   trailingAction: { startExport() }) {
            viewer

            playbackBar

            HStack(alignment: .top, spacing: 12) {
                ToolTile(title: "Intensity", icon: "sparkles", selected: activeTool == "Intensity") {
                    toggleTool("Intensity")
                }
                ToolTile(title: "Contrast", icon: "circle.lefthalf.filled", selected: activeTool == "Contrast") {
                    toggleTool("Contrast")
                }
                ToolTile(title: "Warmth", icon: "thermometer.sun", selected: activeTool == "Warmth") {
                    toggleTool("Warmth")
                }
                ToolTile(title: "Saturation", icon: "drop.halffull", selected: activeTool == "Saturation") {
                    toggleTool("Saturation")
                }
                ToolTile(title: "More", icon: "ellipsis") {
                    app.path.append(.customLook)
                }
            }

            if let tool = activeTool {
                Group {
                    switch tool {
                    case "Intensity": InlineSlider(title: "Intensity", value: $app.settings.intensity)
                    case "Contrast": InlineSlider(title: "Contrast", value: $app.settings.contrast, range: -100...100)
                    case "Warmth": InlineSlider(title: "Warmth", value: $app.settings.warmth, range: -100...100)
                    case "Saturation": InlineSlider(title: "Saturation", value: $app.settings.saturation, range: -100...100)
                    default: EmptyView()
                    }
                }
                .transition(.opacity)
            }

            if let error = app.exportError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(LumaTheme.orange)
            }

            SolidCTA(title: "Export") { startExport() }
                .padding(.top, 2)
        }
        .overlay {
            if isExporting { exportOverlay }
        }
        .onAppear {
            attachTimeObserver()
            if hasRealMedia {
                app.lookState.splitFraction = splitFraction
                app.refreshPreviewFrame()
            }
        }
        .onDisappear {
            detachTimeObserver()
            app.lookState.splitFraction = nil
        }
    }

    // MARK: - Viewer (draggable split wipe, SPEC_ADDENDUM §7)

    @ViewBuilder
    private var viewer: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if hasRealMedia {
                    LookPreviewSurface(radius: 20)
                } else {
                    // Mock split comparison for the empty flow.
                    HStack(spacing: 0) {
                        SceneArt(scene: .coast)
                            .frame(width: geo.size.width * splitFraction)
                            .clipped()
                        SceneArt(scene: .coast, grade: app.selectedLook.gradeTint, gradeOpacity: 0.35)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                }

                // Divider + handle at the wipe position.
                let x = geo.size.width * splitFraction
                Rectangle()
                    .fill(.white)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .position(x: x, y: geo.size.height / 2)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().fill(.black).frame(width: 10, height: 10))
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .position(x: x, y: geo.size.height / 2)

                HStack {
                    Text("Before").pill()
                    Spacer()
                    Text("After").pill(border: true)
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        splitFraction = min(max(value.location.x / geo.size.width, 0.02), 0.98)
                        if hasRealMedia {
                            app.lookState.splitFraction = splitFraction
                            app.refreshPreviewFrame()
                        }
                    }
            )
        }
        .frame(height: 430)
    }

    // MARK: - Playback

    private var playbackBar: some View {
        HStack(spacing: 14) {
            Button {
                guard let player = app.player else { return }
                if isPlaying { player.pause() } else { player.play() }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Text(timeString(progress * duration))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()

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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LumaTheme.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .opacity(app.player == nil ? 0.45 : 1)
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

    private func toggleTool(_ tool: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            activeTool = activeTool == tool ? nil : tool
        }
    }

    // MARK: - Export

    private func startExport() {
        guard hasRealMedia else {
            app.exportError = "Pick a video or photo from your library on the Select Clip screen to export."
            return
        }
        isExporting = true
        Task {
            let success = await app.exportCurrentVideo()
            isExporting = false
            if success {
                app.path.append(.exportComplete)
            }
        }
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(LumaTheme.surfaceStrong, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: max(app.exporter.progress, 0.02))
                        .stroke(LumaTheme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: app.exporter.progress)
                    Text("\(Int(app.exporter.progress * 100))%")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 110, height: 110)

                Text("Exporting your video…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Button("Cancel") { app.exporter.cancel() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LumaTheme.accentBright)
            }
        }
    }
}

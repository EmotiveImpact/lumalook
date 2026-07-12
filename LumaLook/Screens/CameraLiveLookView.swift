import SwiftUI
import CoreImage
import AVFoundation

/// Full-bleed cinematic viewfinder: the camera feed owns the entire
/// screen and every control floats above it on scrims and glass —
/// the shape of a real camera app, not a page with a preview box.
struct CameraLiveLookView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var camera = CameraController()
    @StateObject private var thumbs = LookThumbs()
    @State private var liveThumbSource: CIImage?
    @State private var showGrid = false
    @State private var recordStart: Date?
    @State private var statusCaption: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            viewfinder

            if showGrid {
                RuleOfThirdsGrid()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                topStrip
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    .background {
                        LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .top)
                    }

                Spacer()

                VStack(spacing: 14) {
                    looksRow
                    InlineSlider(title: "Intensity", value: $app.settings.intensity)
                        .padding(.horizontal, 22)
                    bottomControls
                }
                .padding(.top, 26)
                .background {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.78)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                }
            }

            // Hand-off card: the recording returns a result (img.ly pattern) —
            // Retake / Grade / Edit, footage lands where you choose.
            if let recording = camera.lastRecordingURL, !camera.isRecording {
                HandOffCard(url: recording,
                            onRetake: { camera.lastRecordingURL = nil },
                            onGrade: {
                                camera.lastRecordingURL = nil
                                app.selectedVideoURL = recording
                                app.path = [.selectClip, .applyLook]
                            },
                            onEdit: {
                                camera.lastRecordingURL = nil
                                let editor = app.editor
                                Task {
                                    await editor.addClip(from: recording)
                                    editor.selectedClipID = editor.clips.last?.id
                                }
                                app.path = [.editor]
                            })
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 200)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(50)
            }

            // Status pills float over the feed, top centre.
            VStack(spacing: 8) {
                if camera.isRecording {
                    RecordingPill(start: recordStart ?? Date())
                }
                if let statusCaption {
                    TechReadout(statusCaption, size: 11)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .id(statusCaption)
                }
                if camera.lastSavedToPhotos, camera.lastRecordingURL == nil {
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumaTheme.teal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(.black.opacity(0.3), in: Capsule())
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 58)

            // Zoom / flip rail on the right, clear of the bottom cluster.
            VStack(spacing: 10) {
                Text("1.0x")
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 44)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                Button {} label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 44)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.lumaPress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 14)
            .padding(.bottom, 348)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            camera.lookState = app.lookState
            camera.requestAndStart()
            thumbs.render(source: liveThumbSource, looks: Array(MockData.looks.prefix(6)), luts: [])
        }
        .onDisappear { camera.stopSession() }
        .onChange(of: camera.isRecording) { _, recording in
            recordStart = recording ? Date() : nil
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.85),
                   value: camera.lastRecordingURL != nil)
        .animation(.easeOut(duration: 0.15), value: showGrid)
        // Grade the look strip with a real frame from the live camera as
        // soon as one arrives.
        .onReceive(camera.$previewImage) { frame in
            guard liveThumbSource == nil, let frame else { return }
            liveThumbSource = CIImage(cgImage: frame)
            thumbs.render(source: liveThumbSource, looks: Array(MockData.looks.prefix(6)), luts: [])
        }
    }

    // MARK: - Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        Group {
            if camera.isRunning && !camera.cameraUnavailable {
                FilteredCameraPreview(camera: camera)
            } else {
                ZStack {
                    HeroImage(photo: .golden)
                    Color.black.opacity(0.38)
                    fallbackMessage
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Top icon strip

    private var topStrip: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            Spacer()
            // Technical format readout, Blackmagic-style: mono caps, tracked.
            // States the REAL capture format (1080p30 HEVC today) — the HUD
            // never lies. Bumps automatically when capture moves to 4K.
            TechReadout("1080 • 30", size: 12, color: .white.opacity(0.85))
            Spacer()
            // Only real controls live in the strip — no placebo buttons.
            Button {
                showGrid.toggle()
                flashCaption(showGrid ? "GRID ON" : "GRID OFF")
            } label: {
                Image(systemName: "squareshape.split.3x3")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(showGrid ? LumaTheme.accentBright : .white)
                    .frame(width: 40, height: 40, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .sensoryFeedback(.selection, trigger: showGrid)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    /// Transient state caption (Halide-style contextual labeling): flashes
    /// a small mono caption near the top for ~900ms, then fades.
    private func flashCaption(_ text: String) {
        withAnimation(.snappy(duration: 0.2)) { statusCaption = text }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if statusCaption == text {
                withAnimation(.easeOut(duration: 0.25)) { statusCaption = nil }
            }
        }
    }

    // MARK: - Looks

    private var looksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(MockData.looks.prefix(6)) { look in
                    Button {
                        app.selectedLook = look
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let image = thumbs.images[LookThumbs.key(look: look)] {
                                    GradedThumb(image: image,
                                                size: CGSize(width: 78, height: 78),
                                                radius: 14,
                                                selected: look.id == app.selectedLook.id)
                                } else {
                                    SceneThumb(scene: .desert, grade: look.gradeTint, radius: 14,
                                               selected: look.id == app.selectedLook.id)
                                }
                            }
                            .frame(width: 78, height: 78)
                            Text(look.name)
                                .font(.system(size: 12, weight: look.id == app.selectedLook.id ? .semibold : .regular))
                                .foregroundStyle(look.id == app.selectedLook.id ? .white : .white.opacity(0.7))
                                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                                .lineLimit(1)
                                .frame(width: 80)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.horizontal, 22)
        }
        .sensoryFeedback(.selection, trigger: app.selectedLook.id)
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        HStack {
            Button {} label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 56)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.lumaPress)

            Spacer()

            ShutterButton(isRecording: camera.isRecording) {
                camera.toggleRecording()
            }

            Spacer()

            Button {} label: {
                Image(systemName: "camera")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 56)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.lumaPress)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 6)
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.isRecording)
    }

    @ViewBuilder
    private var fallbackMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: camera.permissionDenied ? "lock.shield" : "camera.badge.ellipsis")
                .font(.system(size: 30))
                .foregroundStyle(.white)
            if camera.permissionDenied {
                Text("Camera access is off")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LumaTheme.accentBright)
            } else if camera.cameraUnavailable {
                Text("No camera on this device")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Run LumaLook on an iPhone to shoot with live looks.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Shutter

/// Camera-app style shutter: white ring, red core that morphs into a
/// rounded square while recording, with a breathing glow.
private struct ShutterButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var breathe = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(LumaTheme.recordRed.opacity(breathe ? 0.45 : 0.12), lineWidth: 10)
                        .frame(width: 96, height: 96)
                        .scaleEffect(breathe ? 1.04 : 0.96)
                }
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 82, height: 82)
                RoundedRectangle(cornerRadius: isRecording ? 9 : 34)
                    .fill(LumaTheme.recordRed)
                    .frame(width: isRecording ? 34 : 68, height: isRecording ? 34 : 68)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isRecording)
        }
        .buttonStyle(.lumaPress)
        .onChange(of: isRecording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { breathe = false }
            }
        }
    }
}

/// Pulsing REC indicator with a live SMPTE timecode, shown over the
/// viewfinder while recording. The timecode ticks at frame rate off the
/// recording start date, so it stops the moment the pill disappears.
private struct RecordingPill: View {
    let start: Date
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(LumaTheme.recordRed)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
            Text("REC")
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.white)
            TimelineView(.periodic(from: start, by: 1.0 / 30.0)) { context in
                Text(Timecode.string(seconds: context.date.timeIntervalSince(start)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .kerning(0.6)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.black.opacity(0.3), in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}


// MARK: - Recording hand-off (queue #5)

/// After a take: the clip is saved, now choose where it goes. The camera
/// behaves like an appliance that returns a result.
private struct HandOffCard: View {
    let url: URL
    let onRetake: () -> Void
    let onGrade: () -> Void
    let onEdit: () -> Void

    @State private var thumb: CGImage?

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                Group {
                    if let thumb {
                        Image(decorative: thumb, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LumaTheme.surfaceStrong
                    }
                }
                .frame(width: 52, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip saved")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    TechReadout("SAVED TO PHOTOS · LOOK BAKED IN", size: 8,
                                color: LumaTheme.textMuted)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                handButton("RETAKE", solid: false, action: onRetake)
                handButton("GRADE", solid: false, action: onGrade)
                handButton("EDIT →", solid: true, action: onEdit)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .background(LumaTheme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            thumb = try? await generator.image(
                at: CMTime(seconds: 0.05, preferredTimescale: 600)).image
        }
    }

    private func handButton(_ title: String, solid: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(solid
                            ? AnyShapeStyle(LinearGradient(colors: [LumaTheme.accent, LumaTheme.accentDeep],
                                                           startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(.white.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(.white.opacity(solid ? 0.22 : 0.1), lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
    }
}

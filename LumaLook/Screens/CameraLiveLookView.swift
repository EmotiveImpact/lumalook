import SwiftUI

struct CameraLiveLookView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var camera = CameraController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topStrip
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                preview
                    .padding(.horizontal, 8)

                looksRow
                    .padding(.top, 16)

                InlineSlider(title: "Intensity", value: $app.settings.intensity)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)

                bottomControls
                    .padding(.top, 14)
                    .padding(.bottom, 12)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            camera.lookState = app.lookState
            camera.requestAndStart()
        }
        .onDisappear { camera.stopSession() }
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
            VStack(spacing: 0) {
                Text("4K").font(.system(size: 13, weight: .heavy))
                Text("30").font(.system(size: 11, weight: .semibold))
            }
            Spacer()
            Image(systemName: "bolt.slash").font(.system(size: 20, weight: .medium))
            Spacer()
            Image(systemName: "squareshape.split.3x3").font(.system(size: 20, weight: .medium))
            Spacer()
            Image(systemName: "timer").font(.system(size: 20, weight: .medium))
            Spacer()
            Image(systemName: "gearshape").font(.system(size: 20, weight: .medium))
        }
        .foregroundStyle(.white)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if camera.isRunning && !camera.cameraUnavailable {
                    // Live look: frames run through the shared pipeline.
                    FilteredCameraPreview(camera: camera)
                } else {
                    SceneArt(scene: .desert)
                        .overlay { fallbackMessage }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.06)))

            VStack(spacing: 10) {
                Text("1.0x")
                    .font(.system(size: 15, weight: .bold))
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
            .padding(12)

            if camera.isRecording {
                VStack {
                    Spacer()
                    HStack {
                        RecordingPill()
                        Spacer()
                    }
                    .padding(12)
                }
            }

            if camera.lastSavedToPhotos {
                VStack {
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumaTheme.teal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
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
                            SceneThumb(scene: .desert, grade: look.gradeTint, radius: 14,
                                       selected: look.id == app.selectedLook.id)
                                .frame(width: 78, height: 78)
                            Text(look.name)
                                .font(.system(size: 12, weight: look.id == app.selectedLook.id ? .semibold : .regular))
                                .foregroundStyle(look.id == app.selectedLook.id ? .white : LumaTheme.textSecondary)
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
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
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

/// Pulsing REC indicator shown over the preview while recording.
private struct RecordingPill: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(LumaTheme.recordRed)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
            Text("REC")
                .font(.system(size: 13, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.white)
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

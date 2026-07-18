import SwiftUI
import CoreImage
import AVFoundation
import Photos

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
    @State private var stillSavedFlash = 0
    /// C1 — focus reticle (view-space position; fades out after a beat).
    @State private var reticlePoint: CGPoint?
    @State private var reticlePulse = false
    /// C2 — pinch-zoom gesture state.
    @State private var isPinching = false
    /// C3 — capture-format picker sheet.
    @State private var showFormatSheet = false
    /// C10 — aspect frame guide + social safe zone.
    @State private var frameGuide: FrameGuide = .off
    @State private var showSafeZone = false
    /// C6/C7 — manual exposure + white balance panel.
    @State private var showProPanel = false

    /// Graded still capture — C5: shoots the FULL sensor resolution through
    /// AVCapturePhotoOutput and grades it with the live look (the old path
    /// saved the ~1MP preview buffer). Sim stub falls back to the preview.
    private func captureStill() {
        if camera.canCaptureFullRes {
            camera.captureFullResStill { cg in
                guard let cg else {
                    // Sensor capture failed — degrade gracefully to the preview.
                    if let frame = camera.previewImage { saveStill(UIImage(cgImage: frame)) }
                    return
                }
                saveStill(UIImage(cgImage: cg))
            }
        } else if let frame = camera.previewImage {
            saveStill(UIImage(cgImage: frame))
        }
    }

    private func saveStill(_ image: UIImage) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                statusCaption = "Turn on Add Photos Only in Settings to save"
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if statusCaption?.hasPrefix("Allow Photos") == true { statusCaption = nil }
                return
            }
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            stillSavedFlash += 1
            statusCaption = "Saved to Photos"
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if statusCaption == "Saved to Photos" { statusCaption = nil }
        }
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            viewfinder

            if showGrid {
                RuleOfThirdsGrid()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // C10 — frame guide mattes sit over the feed, under the controls.
            if frameGuide != .off {
                FrameGuidesOverlay(guide: frameGuide, showSafeZone: showSafeZone)
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
                                // Carry the shot's look into the clip so the
                                // grade you framed with survives into editing.
                                let shotGrade = ClipGrade(
                                    baseLookName: app.selectedLUT == nil ? app.selectedLook.name : "",
                                    lutID: app.selectedLUT?.id,
                                    settings: app.settings)
                                Task {
                                    await editor.addClip(from: recording)
                                    if let id = editor.clips.last?.id {
                                        editor.selectedClipID = id
                                        editor.setClipGrade(id: id, shotGrade)
                                    }
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
                Button {
                    camera.cycleZoom()
                    LumaHaptics.shared.tap()
                } label: {
                    Text(String(format: "%.1fx", camera.zoomFactor))
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 44)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.lumaPress)
                Button {
                    showProPanel = true
                    LumaHaptics.shared.tap()
                } label: {
                    Text("PRO")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(camera.manualExposure || camera.manualWB
                                         ? LumaTheme.accentBright : .white)
                        .frame(width: 54, height: 40)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.lumaPress)
                Button {
                    camera.flipCamera()
                    LumaHaptics.shared.tap()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 44)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.lumaPress)
                .opacity(camera.isRecording ? 0.35 : 1)
                .disabled(camera.isRecording)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 14)
            .padding(.bottom, 348)
        }
        .sheet(isPresented: $showProPanel) {
            CameraProPanel(camera: camera)
                .presentationDetents([.height(420), .large])
                .presentationBackground(LumaTheme.background)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showFormatSheet) {
            CameraFormatSheet(camera: camera)
                .presentationDetents([.height(300)])
                .presentationBackground(LumaTheme.background)
                .preferredColorScheme(.dark)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            camera.lookState = app.lookState
            camera.requestAndStart()
            #if DEBUG
            // Verification: switch viewfinder assists on at launch,
            // e.g. LUMA_SEED_CAMASSIST=peak,zebra,guide916,safe
            if let assists = ProcessInfo.processInfo.environment["LUMA_SEED_CAMASSIST"] {
                if assists.contains("peak") { camera.peakingOn = true }
                if assists.contains("zebra") { camera.zebrasOn = true }
                if assists.contains("guide916") { frameGuide = .vertical }
                if assists.contains("guide239") { frameGuide = .cinemascope }
                if assists.contains("safe") { showSafeZone = true }
            }
            #endif
            thumbs.render(source: liveThumbSource, looks: MockData.looks, luts: favouriteLUTs.map { ($0, app.lutRepository.fileURL(for: $0)) })
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
            thumbs.render(source: liveThumbSource, looks: MockData.looks, luts: favouriteLUTs.map { ($0, app.lutRepository.fileURL(for: $0)) })
        }
    }

    // MARK: - Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        Group {
            if camera.isRunning && !camera.cameraUnavailable {
                FilteredCameraPreview(
                    camera: camera,
                    onTapUnit: { unit, viewPoint in
                        if camera.aeafLocked {
                            camera.unlockAEAF()          // tap releases the lock
                        }
                        camera.focusExpose(at: unit)
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            reticlePoint = viewPoint
                            reticlePulse.toggle()
                        }
                        LumaHaptics.shared.tap()
                        Task {                           // reticle fades after 1.1 s
                            try? await Task.sleep(nanoseconds: 1_100_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { reticlePoint = nil }
                        }
                    },
                    onLongPress: {
                        camera.toggleAEAFLock()
                        LumaHaptics.shared.tap()
                    })
                .overlay {
                    if let p = reticlePoint {
                        FocusReticle(pulse: reticlePulse)
                            .position(p)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if camera.aeafLocked {
                        Text("AE/AF LOCK")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(LumaTheme.gold, in: Capsule())
                            .padding(.top, 110)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: camera.aeafLocked)
            } else {
                ZStack {
                    HeroImage(photo: .golden)
                    Color.black.opacity(0.38)
                    fallbackMessage
                }
            }
        }
        .ignoresSafeArea()
        // C2 — continuous pinch zoom, live on the whole viewfinder.
        // simultaneous so tap-to-focus and long-press keep working.
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if !isPinching { isPinching = true; camera.beginPinch() }
                    camera.updatePinch(scale: scale)
                }
                .onEnded { _ in isPinching = false }
        )
    }

    // MARK: - Top icon strip

    private var topStrip: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            Spacer()
            // Technical format readout, Blackmagic-style: mono caps, tracked.
            // Live from the ACTIVE spec (C3) — the HUD never lies. Tap to
            // change resolution / fps / codec.
            Button {
                showFormatSheet = true
                LumaHaptics.shared.tap()
            } label: {
                TechReadout(camera.spec.hudLabel, size: 12, color: .white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.lumaPress)
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.5 : 1)
            Spacer()
            // Only real controls live in the strip — no placebo buttons.
            // C10 — frame guides: tap cycles aspects, long-press toggles the
            // social safe zone (vertical guide only).
            Button {
                let all = FrameGuide.allCases
                let idx = (all.firstIndex(of: frameGuide)! + 1) % all.count
                frameGuide = all[idx]
                flashCaption(frameGuide == .off ? "GUIDES OFF" : "GUIDE \(frameGuide.label)")
            } label: {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(frameGuide != .off ? LumaTheme.accentBright : .white)
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                showSafeZone.toggle()
                flashCaption(showSafeZone ? "SAFE ZONE ON" : "SAFE ZONE OFF")
            })
            .sensoryFeedback(.selection, trigger: frameGuide)
            // C8 — focus peaking assist.
            Button {
                camera.peakingOn.toggle()
                flashCaption(camera.peakingOn ? "PEAKING ON" : "PEAKING OFF")
            } label: {
                Image(systemName: "camera.metering.spot")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(camera.peakingOn ? LumaTheme.accentBright : .white)
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .sensoryFeedback(.selection, trigger: camera.peakingOn)
            // C9 — zebras (95 IRE clip warning).
            Button {
                camera.zebrasOn.toggle()
                flashCaption(camera.zebrasOn ? "ZEBRA 95" : "ZEBRA OFF")
            } label: {
                Image(systemName: "line.diagonal")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(camera.zebrasOn ? LumaTheme.accentBright : .white)
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            .sensoryFeedback(.selection, trigger: camera.zebrasOn)
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

    /// Favourited LUTs surfaced on the camera strip (bounded so thumbnail
    /// rendering stays cheap; the live grade only ever applies the one).
    private var favouriteLUTs: [LUTFile] {
        Array(app.lutRepository.luts.filter(\.isFavourite).prefix(8))
    }

    private var looksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(MockData.looks) { look in
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
                // Favourited LUTs ride the camera strip too, so a shot can be
                // framed through an imported/installed look, not just built-ins.
                ForEach(favouriteLUTs) { lut in
                    Button {
                        app.selectedLUT = lut
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let image = thumbs.images[LookThumbs.key(lut: lut)] {
                                    GradedThumb(image: image, size: CGSize(width: 78, height: 78),
                                                radius: 14, selected: app.selectedLUT?.id == lut.id)
                                } else {
                                    SceneThumb(scene: .desert, grade: Color(red: 0.3, green: 0.8, blue: 0.9),
                                               radius: 14, selected: app.selectedLUT?.id == lut.id)
                                }
                            }
                            .frame(width: 78, height: 78)
                            .overlay(alignment: .topLeading) {
                                Text(lut.isLogTarget ? "LOG" : "LUT")
                                    .font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(LumaTheme.accent, in: Capsule()).padding(5)
                            }
                            Text(lut.displayName)
                                .font(.system(size: 12, weight: app.selectedLUT?.id == lut.id ? .semibold : .regular))
                                .foregroundStyle(app.selectedLUT?.id == lut.id ? .white : .white.opacity(0.7))
                                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                                .lineLimit(1).frame(width: 80)
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
            Button {
                app.path = [.selectClip]
            } label: {
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

            Button {
                captureStill()
            } label: {
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
        .sensoryFeedback(.success, trigger: stillSavedFlash)
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


/// C1 — the tap-to-focus reticle: a rounded square that lands with a small
/// settle, camera-app grammar. Pure chrome; the device work happens in the
/// controller.
private struct FocusReticle: View {
    var pulse: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(LumaTheme.gold, lineWidth: 1.6)
            .frame(width: 76, height: 76)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(LumaTheme.gold.opacity(0.9), lineWidth: 1.2)
                    .frame(width: 8, height: 8)
            }
            .scaleEffect(pulse ? 1.0 : 1.0)   // keyed by toggle to re-trigger
            .transition(.scale(scale: 1.35).combined(with: .opacity))
            .allowsHitTesting(false)
            .shadow(color: .black.opacity(0.5), radius: 4)
    }
}


/// C3 — capture-format picker: resolution / fps / codec chips. Writes through
/// CameraController.setSpec, which re-formats the live session and persists.
private struct CameraFormatSheet: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    private func chipRow<T: Hashable>(_ title: String, options: [T],
                                      label: @escaping (T) -> String,
                                      isOn: @escaping (T) -> Bool,
                                      pick: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TechReadout(title, size: 10, color: LumaTheme.textMuted)
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button {
                        pick(option)
                        LumaHaptics.shared.tap()
                    } label: {
                        Text(label(option))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isOn(option) ? .black : .white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(isOn(option) ? AnyShapeStyle(LumaTheme.accentBright)
                                                     : AnyShapeStyle(LumaTheme.surface),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Capture Format")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.footnote.weight(.semibold)).foregroundStyle(LumaTheme.accentBright)
            }
            chipRow("RESOLUTION", options: CameraSpec.Resolution.allCases,
                    label: { $0.rawValue }, isOn: { camera.spec.resolution == $0 }) { r in
                var s = camera.spec; s.resolution = r; camera.setSpec(s)
            }
            chipRow("FRAME RATE", options: CameraSpec.fpsOptions,
                    label: { "\($0)" }, isOn: { camera.spec.fps == $0 }) { f in
                var s = camera.spec; s.fps = f; camera.setSpec(s)
            }
            chipRow("CODEC", options: CameraSpec.Codec.allCases,
                    label: { $0.rawValue }, isOn: { camera.spec.codec == $0 }) { c in
                var s = camera.spec; s.codec = c; camera.setSpec(s)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}


/// C6/C7 — the Pro panel: manual ISO / shutter angle / EV, and manual white
/// balance. Every control writes through the controller, which clamps to the
/// device's real ranges and logs what it applied.
private struct CameraProPanel: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    private let angles: [Double] = [45, 90, 180, 270, 360]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Pro Controls")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.footnote.weight(.semibold)).foregroundStyle(LumaTheme.accentBright)
                }

                // — Exposure —
                HStack {
                    TechReadout("EXPOSURE", size: 10, color: LumaTheme.textMuted)
                    Spacer()
                    Button(camera.manualExposure ? "AUTO" : "MANUAL") {
                        camera.manualExposure ? camera.resetAutoExposure()
                                              : camera.setManualExposure()
                        LumaHaptics.shared.tap()
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(camera.manualExposure ? LumaTheme.gold : LumaTheme.teal)
                }

                if camera.manualExposure {
                    InlineSlider(title: "ISO",
                                 value: Binding(
                                    get: { Double(camera.currentISO == 0 ? camera.isoRange.lowerBound : camera.currentISO) },
                                    set: { camera.setManualExposure(iso: Float($0)) }),
                                 range: Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound)) {
                        "\(Int($0))"
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TechReadout("SHUTTER ANGLE", size: 10, color: LumaTheme.textMuted)
                            Spacer()
                            TechReadout("1/\(Int(360.0 / max(camera.shutterAngle, 1) * Double(camera.spec.fps)))s",
                                        size: 10, color: LumaTheme.textSecondary)
                        }
                        HStack(spacing: 8) {
                            ForEach(angles, id: \.self) { angle in
                                Button {
                                    camera.setManualExposure(angle: angle)
                                    LumaHaptics.shared.tap()
                                } label: {
                                    Text("\(Int(angle))°")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(camera.shutterAngle == angle ? .black : .white)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(camera.shutterAngle == angle
                                                    ? AnyShapeStyle(LumaTheme.accentBright)
                                                    : AnyShapeStyle(LumaTheme.surface), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("180° is the cinematic default — motion blur matched to \(camera.spec.fps) fps.")
                            .font(.system(size: 11)).foregroundStyle(LumaTheme.textMuted)
                    }
                } else {
                    InlineSlider(title: "EV",
                                 value: Binding(get: { Double(camera.evBias) },
                                                set: { camera.setEVBias(Float($0)) }),
                                 range: -2...2) { String(format: "%+.1f", $0) }
                }

                Divider().overlay(LumaTheme.hairline)

                // — White balance —
                HStack {
                    TechReadout("WHITE BALANCE", size: 10, color: LumaTheme.textMuted)
                    Spacer()
                    Button(camera.manualWB ? "AUTO" : "MANUAL") {
                        camera.manualWB ? camera.resetAutoWB()
                                        : camera.setWhiteBalance(temperature: camera.wbTemperature,
                                                                 tint: camera.wbTint)
                        LumaHaptics.shared.tap()
                    }
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(camera.manualWB ? LumaTheme.gold : LumaTheme.teal)
                }

                if camera.manualWB {
                    InlineSlider(title: "Temp",
                                 value: Binding(get: { Double(camera.wbTemperature) },
                                                set: { camera.setWhiteBalance(temperature: Float($0), tint: camera.wbTint) }),
                                 range: 2500...9000) { "\(Int($0))K" }
                    InlineSlider(title: "Tint",
                                 value: Binding(get: { Double(camera.wbTint) },
                                                set: { camera.setWhiteBalance(temperature: camera.wbTemperature, tint: Float($0)) }),
                                 range: -50...50) { String(format: "%+.0f", $0) }
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

import SwiftUI
import AVKit

/// Video preview with the live look applied, falling back to the painted
/// scene when no real clip is selected.
struct LookPreviewSurface: View {
    @EnvironmentObject private var app: AppModel
    var radius: CGFloat = 18

    var body: some View {
        Group {
            if let player = app.player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let still = app.selectedImage {
                GradedStillView(source: still)
            } else {
                GradedHeroPreview()
                    .overlay(alignment: .bottomLeading) {
                        Label("Preview — pick a clip to grade live", systemImage: "film")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(10)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.06)))
    }
}

/// Empty-state preview: the bundled hero photograph run through the LIVE
/// grade, so the look responds in real time even before a clip is picked.
struct GradedHeroPreview: View {
    var body: some View {
        if let ci = HeroPhoto.golden.ciImage {
            GradedStillView(source: ci)
        } else {
            SceneArt(scene: .sunsetRoad)
        }
    }
}

/// Live-graded still image preview: re-renders whenever the grade changes.
struct GradedStillView: View {
    @EnvironmentObject private var app: AppModel
    let source: CIImage

    var body: some View {
        // Reading app.settings / selectedLook / selectedLUT here makes the
        // view re-render the still whenever the grade changes.
        let _ = app.settings
        let _ = app.selectedLook
        let _ = app.selectedLUT
        Group {
            if let cg = LookPipeline.shared.gradedStill(source, state: app.lookState,
                                                        maxDimension: 1400, includeSplit: true) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                Color.black
            }
        }
    }
}

struct ApplyLookView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()
    @State private var category = "All"
    @State private var activeTool = "Adjust"
    @State private var mediaReadout: String?
    @State private var videoAspect: CGFloat?

    private var filteredLooks: [LookPreset] {
        category == "All" ? MockData.looks : MockData.looks.filter { $0.category == category }
    }

    private var thumbStamp: String {
        "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.lutRepository.luts.count)"
    }

    private var mediaKey: String {
        if let url = app.selectedVideoURL { return url.absoluteString }
        if let still = app.selectedImage {
            return "still-\(Int(still.extent.width))x\(Int(still.extent.height))"
        }
        return "none"
    }

    /// Loads a technical metadata readout for the selected media:
    /// `1920×1080 • 30 FPS • 00:12` for video, `W×H • STILL` for photos.
    private func loadMediaReadout() async {
        if let url = app.selectedVideoURL {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (naturalSize, transform, fps) = try? await track.load(
                    .naturalSize, .preferredTransform, .nominalFrameRate)
            else {
                mediaReadout = nil
                videoAspect = nil
                return
            }
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let w = Int(abs(rect.width).rounded())
            let h = Int(abs(rect.height).rounded())

            var parts = ["\(w)×\(h)"]
            if fps > 0 {
                let rounded = fps.rounded()
                parts.append(abs(Double(fps) - Double(rounded)) < 0.01
                             ? "\(Int(rounded)) FPS"
                             : String(format: "%.2f FPS", fps))
            }
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                let s = Int(seconds.rounded())
                parts.append(String(format: "%02d:%02d", s / 60, s % 60))
            }
            mediaReadout = parts.joined(separator: " • ")
            videoAspect = h > 0 ? CGFloat(w) / CGFloat(h) : nil
        } else if let still = app.selectedImage {
            let extent = still.extent
            mediaReadout = "\(Int(extent.width))×\(Int(extent.height)) • STILL"
            videoAspect = nil
        } else {
            mediaReadout = nil
            videoAspect = nil
        }
    }

    var body: some View {
        // Media-first grade room: the footage owns the screen; every control
        // floats in a pinned bottom glass drawer. No page scroll.
        VStack(spacing: 0) {
            mediaSurface
            drawer
        }
        .background(LumaTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: thumbStamp) {
            thumbs.render(source: app.previewFrame,
                          looks: MockData.looks,
                          luts: app.lutRepository.luts.map { ($0, app.lutRepository.fileURL(for: $0)) })
        }
        .task(id: mediaKey) { await loadMediaReadout() }
    }

    // MARK: Media surface

    @State private var holdingOriginal = false
    @State private var stashedIntensity: Double?

    private var mediaSurface: some View {
        LookPreviewSurface(radius: 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay {
                if app.player != nil, let aspect = videoAspect, aspect >= 1.4 {
                    LetterboxMattes(contentAspect: aspect)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: videoAspect)
            // Press-and-hold anywhere on the image to see the original —
            // the industry-standard before/after peek.
            .onLongPressGesture(minimumDuration: 0.18, maximumDistance: 60) {
            } onPressingChanged: { pressing in
                if pressing {
                    if stashedIntensity == nil { stashedIntensity = app.settings.intensity }
                    holdingOriginal = true
                    app.settings.intensity = 0
                } else if let stashed = stashedIntensity {
                    app.settings.intensity = stashed
                    stashedIntensity = nil
                    holdingOriginal = false
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: holdingOriginal)
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if holdingOriginal {
                        TechReadout("ORIGINAL", size: 11)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                            .transition(.opacity)
                    }
                    if let mediaReadout {
                        TechReadout(mediaReadout, size: 10, color: .white.opacity(0.65))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                }
                .padding(12)
                .animation(.easeOut(duration: 0.12), value: holdingOriginal)
            }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            Spacer()
            TechReadout("GRADE", size: 12, color: .white.opacity(0.85))
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .background {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: Drawer

    private var drawer: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MockData.categories, id: \.self) { chip in
                        Button { category = chip } label: {
                            Chip(title: chip, selected: chip == category)
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.horizontal, 22)
            }
            .lumaEdgeFade()

            lookStrip

            if app.selectedLUT?.isLogTarget == true {
                Label("Log LUT — designed for Log footage. If it looks harsh here, lower the intensity.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(LumaTheme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .transition(.opacity)
            }

            LumaDial(title: activeTool == "Adjust" ? "Intensity" : activeTool,
                     value: dialBinding)
                .padding(.horizontal, 22)

            HStack(spacing: 4) {
                FlatTool(title: "Adjust", icon: "slider.horizontal.3", selected: activeTool == "Adjust") {
                    activeTool = "Adjust"
                }
                FlatTool(title: "Grain", icon: "circle.dotted", selected: activeTool == "Grain") {
                    activeTool = "Grain"
                }
                FlatTool(title: "Bloom", icon: "sun.haze", selected: activeTool == "Bloom") {
                    activeTool = "Bloom"
                }
                FlatTool(title: "Halation", icon: "circle.hexagongrid.circle", selected: activeTool == "Halation") {
                    activeTool = "Halation"
                }
                FlatTool(title: "Vignette", icon: "smallcircle.filled.circle", selected: activeTool == "Vignette") {
                    activeTool = "Vignette"
                }
                FlatTool(title: "More", icon: "dial.high", action: { app.path.append(.customLook) })
            }
            .padding(.horizontal, 14)

            SolidCTA(title: "Apply Look", height: 52) {
                app.path.append(.beforeAfter)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
        }
        .padding(.top, 14)
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                LumaTheme.background.opacity(0.45)
                LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// One dial, five parameters: the dial always edits the active tool.
    private var dialBinding: Binding<Double> {
        switch activeTool {
        case "Grain": return $app.settings.grain
        case "Bloom": return $app.settings.bloom
        case "Halation": return $app.settings.halation
        case "Vignette": return $app.settings.vignette
        default: return $app.settings.intensity
        }
    }

    private var lookStrip: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(filteredLooks) { look in
                        LookThumbCell(
                            title: look.name,
                            grade: look.gradeTint,
                            selected: look.id == app.selectedLook.id && app.selectedLUT == nil,
                            image: thumbs.images[LookThumbs.key(look: look)]
                        ) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                app.selectedLUT = nil
                                app.selectedLook = look
                            }
                        }
                        .scrollTransition(.interactive) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.9)
                                .opacity(phase.isIdentity ? 1 : 0.6)
                        }
                    }
                    ForEach(app.lutRepository.luts) { lut in
                        LookThumbCell(
                            title: lut.displayName,
                            grade: Color(red: 0.3, green: 0.8, blue: 0.9),
                            selected: app.selectedLUT?.id == lut.id,
                            badge: lut.isLogTarget ? "LOG" : "LUT",
                            image: thumbs.images[LookThumbs.key(lut: lut)]
                        ) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                app.selectedLUT = lut
                            }
                        }
                        .scrollTransition(.interactive) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.9)
                                .opacity(phase.isIdentity ? 1 : 0.6)
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 22)
            }
            .lumaEdgeFade()
            .sensoryFeedback(.selection, trigger: app.selectedLook.id)
            .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
    }
}

struct LookThumbCell: View {
    let title: String
    var grade: Color? = nil
    var selected: Bool = false
    var badge: String? = nil
    var image: CGImage? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let image {
                        GradedThumb(image: image, selected: selected)
                    } else {
                        SceneThumb(scene: .sunsetRoad, grade: grade, radius: 16, selected: selected)
                    }
                }
                    .frame(width: 96, height: 96)
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(LumaTheme.accent, in: Capsule())
                                .padding(6)
                        }
                    }
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 96)
            }
        }
        .buttonStyle(.lumaPress)
    }
}

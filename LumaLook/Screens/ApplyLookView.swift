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
        LumaScreen(title: "Choose Look", trailingIcon: "magnifyingglass") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MockData.categories, id: \.self) { chip in
                        Button { category = chip } label: {
                            Chip(title: chip, selected: chip == category)
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
            }

            LookPreviewSurface()
                .frame(height: 400)
                .overlay {
                    // Letterbox mattes when grading wide (16:9-ish) video,
                    // so the surface reads "cinema", not "player".
                    if app.player != nil, let aspect = videoAspect, aspect >= 1.4 {
                        LetterboxMattes(contentAspect: aspect)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: videoAspect)
                .task(id: mediaKey) { await loadMediaReadout() }

            if let mediaReadout {
                TechReadout(mediaReadout, size: 11, color: LumaTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, -8)
            }

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
                            badge: "LUT",
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
            }
            .sensoryFeedback(.selection, trigger: app.selectedLook.id)
            .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
            .task(id: thumbStamp) {
                thumbs.render(source: app.previewFrame,
                              looks: MockData.looks,
                              luts: app.lutRepository.luts.map { ($0, app.lutRepository.fileURL(for: $0)) })
            }

            InlineSlider(title: "Intensity", value: $app.settings.intensity)
                .padding(.top, 4)

            Hairline()

            HStack(spacing: 4) {
                FlatTool(title: "Adjust", icon: "slider.horizontal.3", selected: activeTool == "Adjust") {
                    activeTool = "Adjust"
                    app.path.append(.customLook)
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
            }

            if activeTool == "Bloom" {
                InlineSlider(title: "Bloom", value: $app.settings.bloom)
            } else if activeTool == "Vignette" {
                InlineSlider(title: "Vignette", value: $app.settings.vignette)
            } else if activeTool == "Grain" {
                InlineSlider(title: "Grain", value: $app.settings.grain)
            } else if activeTool == "Halation" {
                InlineSlider(title: "Halation", value: $app.settings.halation)
            }

            SolidCTA(title: "Apply Look") {
                app.path.append(.beforeAfter)
            }
            .padding(.top, 4)
        }
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

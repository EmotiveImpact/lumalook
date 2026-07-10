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
                SceneArt(scene: .sunsetRoad, grade: app.selectedLook.gradeTint, gradeOpacity: 0.22)
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
    @State private var category = "All"
    @State private var activeTool = "Adjust"

    private var filteredLooks: [LookPreset] {
        category == "All" ? MockData.looks : MockData.looks.filter { $0.category == category }
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(filteredLooks) { look in
                        LookThumbCell(
                            title: look.name,
                            grade: look.gradeTint,
                            selected: look.id == app.selectedLook.id && app.selectedLUT == nil
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
                            badge: "LUT"
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
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                SceneThumb(scene: .sunsetRoad, grade: grade, radius: 16, selected: selected)
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

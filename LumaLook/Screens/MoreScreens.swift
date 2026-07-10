import SwiftUI
import AVFoundation

// MARK: - 09 Filter Store

struct FilterStoreView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false
    @State private var category = "Featured"

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header with coin balance.
                ZStack {
                    Text("FILTER STORE")
                        .font(.system(size: 17, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(.white)
                    HStack {
                        if !isRoot {
                            BackArrow()
                        }
                        Spacer()
                        HStack(spacing: 7) {
                            Circle()
                                .fill(RadialGradient(colors: [LumaTheme.gold, Color(red: 0.85, green: 0.5, blue: 0.05)],
                                                     center: .center, startRadius: 1, endRadius: 12))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color(red: 1.0, green: 0.85, blue: 0.4), lineWidth: 1.5).padding(3))
                            Text("250")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(LumaTheme.textMuted)
                            Text("Search looks or packs")
                                .foregroundStyle(LumaTheme.textMuted)
                            Spacer()
                        }
                        .font(.system(size: 16))
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(["Featured", "Film", "Cinematic", "Moody", "Vintage"], id: \.self) { chip in
                                    Button { category = chip } label: {
                                        Chip(title: chip, selected: category == chip)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        SectionHeader(title: "Featured Pack")

                        Button { app.path.append(.filterPack) } label: {
                            ZStack(alignment: .topTrailing) {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("NOCTURNE")
                                            .font(.system(size: 26, weight: .heavy))
                                            .tracking(1)
                                        Text("COLLECTION")
                                            .font(.system(size: 18, weight: .semibold))
                                            .tracking(2.4)
                                        Text("12 Cinematic Looks")
                                            .font(.system(size: 14))
                                            .foregroundStyle(LumaTheme.textSecondary)
                                            .padding(.top, 2)
                                        Text("$2.99")
                                            .font(.system(size: 16, weight: .bold))
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 8)
                                            .background(LumaTheme.accent, in: Capsule())
                                            .padding(.top, 8)
                                    }
                                    .foregroundStyle(.white)
                                    .padding(18)
                                    Spacer(minLength: 0)
                                    SceneArt(scene: .cityNight)
                                        .frame(width: 158)
                                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                                          bottomTrailingRadius: 18, topTrailingRadius: 18))
                                }
                                .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(LumaTheme.hairline))

                                Text("NEW")
                                    .font(.system(size: 12, weight: .heavy))
                                    .tracking(1)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(LumaTheme.accent, in: Capsule())
                                    .padding(10)
                            }
                        }
                        .buttonStyle(.plain)

                        SectionHeader(title: "Best Sellers", actionTitle: "See All")

                        VStack(spacing: 0) {
                            StoreRow(name: "Golden Hour", looks: "10 Looks", price: "$1.99", scene: .goldenField)
                            Hairline().padding(.leading, 92)
                            StoreRow(name: "London Rain", looks: "12 Looks", price: "$2.99", scene: .rainyCity)
                            Hairline().padding(.leading, 92)
                            StoreRow(name: "Afrobeats Glow", looks: "15 Looks", price: "$2.99", scene: .sunsetRoad)
                            Hairline().padding(.leading, 92)
                            StoreRow(name: "Documentary Grit", looks: "8 Looks", price: "$1.99", scene: .coast)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 36)
                }
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct StoreRow: View {
    @EnvironmentObject private var app: AppModel
    let name: String
    let looks: String
    let price: String
    var scene: MockScene

    var body: some View {
        Button { app.path.append(.filterPack) } label: {
            HStack(spacing: 14) {
                SceneThumb(scene: scene, radius: 12)
                    .frame(width: 78, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text(looks)
                        .font(.system(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                Spacer()
                Text(price)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(LumaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

struct BackArrow: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "arrow.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 10 Filter Pack Detail

struct FilterPackDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Hero with overlaid title.
                    ZStack(alignment: .bottomLeading) {
                        SceneArt(scene: .cityNight)
                            .frame(height: 300)
                            .overlay(LinearGradient(colors: [.clear, LumaTheme.background],
                                                    startPoint: .center, endPoint: .bottom))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("NOCTURNE")
                                .font(.system(size: 42, weight: .heavy))
                                .tracking(2)
                            Text("COLLECTION")
                                .font(.system(size: 26, weight: .medium))
                                .tracking(5)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 4)

                        VStack {
                            HStack {
                                BackArrow()
                                Spacer()
                            }
                            .padding(.horizontal, 22)
                            .padding(.top, 62)   // hero ignores the top safe area
                            Spacer()
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("12 Cinematic Looks")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.top, 18)
                        Text("Deep shadows, rich colors\nand a cinematic vibe.")
                            .font(.system(size: 16))
                            .foregroundStyle(LumaTheme.textSecondary)
                            .lineSpacing(3)

                        HStack(spacing: 12) {
                            // TODO: StoreKit 2 purchase in Phase 6.
                            Button {} label: {
                                Text("$2.99")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 58)
                                    .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            Button {} label: {
                                Image(systemName: "heart")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 58)
                                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(LumaTheme.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 8)

                        SectionHeader(title: "Looks Included")
                            .padding(.top, 14)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                            ForEach(Array(zip(["Nocturne", "Midnight", "Eclipse", "Obsidian", "Neon Rain", "After Dark"],
                                              [MockScene.cityNight, .duskPurple, .rainyCity, .forest, .neonStreet, .sunsetRoad])),
                                    id: \.0) { name, scene in
                                VStack(spacing: 8) {
                                    SceneThumb(scene: scene, grade: Color(red: 0.25, green: 0.3, blue: 0.7),
                                               radius: 14)
                                        .frame(height: 96)
                                    Text(name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 11 Saved Looks

struct SavedLooksView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false

    var body: some View {
        LumaScreen(title: "Saved Looks", trailingText: "Edit", showBack: !isRoot) {
            SavedLooksList(store: app.store)
            Spacer(minLength: 24)
            SolidCTA(title: "Create New Look") {
                app.path.append(.customLook)
            }
        }
    }
}

private struct SavedLooksList: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: PersistenceStore

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        let looks = store.savedLooks
        if looks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 34))
                    .foregroundStyle(LumaTheme.textMuted)
                Text("No saved looks yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
                Text("Dial in a grade in Custom Look and save it.")
                    .font(.system(size: 14))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            VStack(spacing: 12) {
                ForEach(Array(looks.enumerated()), id: \.element.id) { index, look in
                    Button {
                        app.applySavedLook(look)
                        app.path.append(.applyLook)
                    } label: {
                        HStack(spacing: 14) {
                            SceneThumb(scene: MockScene.allCases[index % MockScene.allCases.count],
                                       radius: 12)
                                .frame(width: 92, height: 68)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(look.name)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Based on \(look.baseLookName) • \(look.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: 14))
                                    .foregroundStyle(LumaTheme.textMuted)
                            }
                            Spacer()
                            Menu {
                                Button("Apply") {
                                    app.applySavedLook(look)
                                    app.path.append(.applyLook)
                                }
                                Button("Delete", role: .destructive) {
                                    store.deleteLook(look.id)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 17, weight: .semibold))
                                    .rotationEffect(.degrees(90))
                                    .foregroundStyle(LumaTheme.textSecondary)
                                    .frame(width: 34, height: 44)
                            }
                        }
                        .padding(12)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}


// MARK: - 12 Custom Look Builder

struct CustomLookBuilderView: View {
    @EnvironmentObject private var app: AppModel
    @State private var tab = "ADJUST"
    @State private var showSaveDialog = false
    @State private var lookName = ""
    @State private var savedConfirmation = false

    var body: some View {
        LumaScreen(title: "Custom Look", trailingText: "Save",
                   trailingAction: { showSaveDialog = true }) {
            if savedConfirmation {
                Label("Look saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LumaTheme.teal)
            }
            LookPreviewSurface(radius: 18)
                .frame(height: 210)

            HStack(spacing: 8) {
                ForEach(["ADJUST", "HSL", "COLOR WHEELS", "EFFECTS"], id: \.self) { segment in
                    Button { tab = segment } label: {
                        Text(segment)
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(tab == segment ? .white : LumaTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(tab == segment ? LumaTheme.accent : LumaTheme.surface,
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }

            if tab == "ADJUST" {
                VStack(spacing: 20) {
                    GradeSlider(title: "Exposure", value: $app.settings.exposure) {
                        String(format: "%+.2f", $0 / 500)
                    }
                    GradeSlider(title: "Contrast", value: $app.settings.contrast)
                    GradeSlider(title: "Highlights", value: $app.settings.highlights)
                    GradeSlider(title: "Shadows", value: $app.settings.shadows)
                    GradeSlider(title: "Saturation", value: $app.settings.saturation)
                    GradeSlider(title: "Warmth", value: $app.settings.warmth)
                    GradeSlider(title: "Tint", value: $app.settings.tint)
                }
                .padding(.top, 6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 28))
                        .foregroundStyle(LumaTheme.textMuted)
                    Text("\(tab.capitalized) tools are coming soon")
                        .font(.system(size: 15))
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }

            Hairline()
                .padding(.top, 6)

            HStack {
                Button {
                    app.settings = LookSettings()
                } label: {
                    Text("Reset")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .frame(height: 52)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    app.settings = LookSettings()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .alert("Save Look", isPresented: $showSaveDialog) {
            TextField("Look name", text: $lookName)
            Button("Save") {
                let name = lookName.trimmingCharacters(in: .whitespaces)
                app.saveCurrentLook(named: name.isEmpty ? "My Look" : name)
                lookName = ""
                savedConfirmation = true
            }
            Button("Cancel", role: .cancel) { lookName = "" }
        } message: {
            Text("Saves the current grade so you can reuse it from Saved Looks.")
        }
    }
}

/// Custom Look slider row: label — track — signed value.
private struct GradeSlider: View {
    let title: String
    @Binding var value: Double
    var format: ((Double) -> String)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, alignment: .leading)
            Slider(value: $value, in: -100...100)
                .tint(LumaTheme.accent)
            Text(format?(value) ?? String(format: "%+d", Int(value)))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}

// MARK: - 13 Project Library

struct ProjectLibraryView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false

    var body: some View {
        LumaScreen(title: "Projects", trailingText: "All", showBack: !isRoot) {
            ProjectGrid(store: app.store)

            Spacer(minLength: 30)

            SolidCTA(title: "+ New Project") {
                app.editor.startNewProject()
                app.path.append(.editor)
            }
        }
    }
}

private struct ProjectGrid: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: PersistenceStore

    var body: some View {
        if store.projects.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.system(size: 34))
                    .foregroundStyle(LumaTheme.textMuted)
                Text("No projects yet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
                Text("Edits auto-save here as you work.")
                    .font(.system(size: 14))
                    .foregroundStyle(LumaTheme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 18) {
                ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                    Button {
                        app.editor.load(project: project)
                        app.path.append(.editor)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ProjectThumb(project: project, store: store,
                                         fallback: MockScene.allCases[index % MockScene.allCases.count])
                                .frame(height: 118)
                            Text(project.title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(project.updatedAt.formatted(date: .abbreviated, time: .omitted)) • \(timeString(project.duration))")
                                .font(.system(size: 12))
                                .foregroundStyle(LumaTheme.textMuted)
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                store.deleteProject(project.id)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// First-frame thumbnail of a stored project's first clip.
struct ProjectThumb: View {
    let project: StoredProject
    let store: PersistenceStore
    var fallback: MockScene = .sunsetRoad
    @State private var thumbnail: CGImage?

    var body: some View {
        Color.clear
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    SceneArt(scene: fallback)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06)))
        .task {
            guard thumbnail == nil, let first = project.clips.first else { return }
            let url = store.clipURL(for: first)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            thumbnail = await EditorState.thumbnail(for: AVURLAsset(url: url),
                                                    at: first.trimStart + 0.02)
        }
    }
}

// MARK: - 14 Crop / Format

struct CropFormatView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 100.0
    @State private var format: EditorFormat = .widescreen

    var body: some View {
        LumaScreen(title: "Format", trailingText: "Apply", trailingAction: {
            app.editor.setFormat(format, zoom: zoom)
            dismiss()
        }) {
            // Live crop preview: the chosen aspect framed over the footage,
            // with a rule-of-thirds grid inside the crop box.
            previewSurface
                .frame(height: 340)
                .overlay(
                    GeometryReader { geo in
                        let box = cropBox(in: geo.size)
                        ZStack {
                            // Dim everything outside the crop.
                            Color.black.opacity(0.55)
                                .reverseMask {
                                    Rectangle()
                                        .frame(width: box.width, height: box.height)
                                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                }
                            Path { p in
                                for i in 1...2 {
                                    let x = box.minX + box.width * CGFloat(i) / 3
                                    let y = box.minY + box.height * CGFloat(i) / 3
                                    p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                                    p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                                }
                            }
                            .stroke(.white.opacity(0.5), lineWidth: 1)
                            Rectangle()
                                .stroke(.white.opacity(0.85), lineWidth: 1.5)
                                .frame(width: box.width, height: box.height)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

            HStack(alignment: .top, spacing: 12) {
                ForEach(EditorFormat.allCases, id: \.self) { option in
                    ToolTile(title: option.rawValue, icon: option.icon, subtitle: option.subtitle,
                             selected: format == option) { format = option }
                }
            }

            InlineSlider(title: "Zoom", value: $zoom, range: 100...300) { "\(Int($0))" }

            HStack(spacing: 12) {
                Text("Position")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                ForEach(["align.horizontal.left", "align.horizontal.center", "align.horizontal.right"], id: \.self) { icon in
                    Button {} label: {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 62, height: 50)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                Button { zoom = 100 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            format = app.editor.format
            zoom = app.editor.zoom
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        if let thumb = app.editor.selectedClip?.thumbnail ?? app.editor.clips.first?.thumbnail {
            Image(decorative: thumb, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            SceneArt(scene: .coast)
        }
    }

    private func cropBox(in size: CGSize) -> CGRect {
        let aspect = format.aspect
        var width = size.width - 36
        var height = width / aspect
        if height > size.height - 36 {
            height = size.height - 36
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}

private extension View {
    /// Cuts `mask` out of the receiving view (inverse mask).
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(mask().blendMode(.destinationOut))
                .compositingGroup()
        }
    }
}

// MARK: - 15 Audio

struct AudioView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var volume = 100.0
    @State private var fadeIn = 0.0
    @State private var fadeOut = 0.0
    @State private var mute = false

    var body: some View {
        LumaScreen(title: "Audio", trailingIcon: "checkmark", trailingAction: {
            applyToEditor()
            dismiss()
        }) {
            InlineSlider(title: "Volume", value: $volume) { "\(Int($0))%" }

            Hairline()

            HStack {
                Text("Music")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LumaTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(LumaTheme.accentDeep)
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Chill Vibes")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text("By Soundstripe")
                            .font(.system(size: 14))
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                    Spacer()
                    Button {} label: {
                        Text("Change")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(LumaTheme.accentDeep.opacity(0.55), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Waveform.
                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: 2.5) {
                        ForEach(0..<52, id: \.self) { i in
                            let h = 8 + CGFloat((i * 37) % 40)
                            Capsule()
                                .fill(LumaTheme.accentBright.opacity(i < 40 ? 0.95 : 0.35))
                                .frame(width: 3, height: h)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("02:45")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(height: 60)
            }
            .padding(16)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))

            InlineSlider(title: "Fade In", value: $fadeIn, range: 0...4) { String(format: "%.1fs", $0) }
            InlineSlider(title: "Fade Out", value: $fadeOut, range: 0...4) { String(format: "%.1fs", $0) }

            Hairline()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voiceover")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Tap to record")
                        .font(.system(size: 14))
                        .foregroundStyle(LumaTheme.textMuted)
                }
                Spacer()
                Button {} label: {
                    Circle()
                        .fill(LumaTheme.surfaceStrong)
                        .frame(width: 56, height: 56)
                        .overlay(Image(systemName: "mic")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white))
                }
                .buttonStyle(.plain)
            }

            Hairline()

            Toggle(isOn: $mute) {
                Text("Mute Clip Audio")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .tint(LumaTheme.accent)
        }
        .onAppear {
            volume = app.editor.volume
            fadeIn = app.editor.fadeIn
            fadeOut = app.editor.fadeOut
            mute = app.editor.muteAudio
        }
        .onChange(of: volume) { _, _ in applyToEditor() }
        .onChange(of: mute) { _, _ in applyToEditor() }
        .onChange(of: fadeIn) { _, _ in applyToEditor() }
        .onChange(of: fadeOut) { _, _ in applyToEditor() }
    }

    /// Pushes the settings into the editor's live audio mix.
    private func applyToEditor() {
        app.editor.volume = volume
        app.editor.fadeIn = fadeIn
        app.editor.fadeOut = fadeOut
        app.editor.muteAudio = mute
        app.editor.applyAudioSettings()
    }
}

// MARK: - 16 Settings / Subscription

struct SettingsSubscriptionView: View {
    var isRoot: Bool = false

    var body: some View {
        LumaScreen(title: "Settings", showBack: !isRoot) {
            // Profile / subscription card.
            HStack(spacing: 14) {
                Circle()
                    .fill(LumaTheme.surfaceStrong)
                    .frame(width: 58, height: 58)
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.85)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("LumaLook Pro")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Unlimited Access")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LumaTheme.teal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)
                Spacer()
                Button {} label: {
                    Text("Manage")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(LumaTheme.accentDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))

            // TODO: StoreKit 2 subscription management in Phase 6.
            SettingsGroup(rows: [
                ("creditcard", "Subscription", nil, true),
                ("arrow.clockwise", "Restore Purchases", nil, true),
                ("4k.tv", "Export Quality", "1080p", true),
                ("drop", "Watermark", "Off", true),
                ("icloud", "iCloud Sync", "Off", true),
                ("globe", "App Language", "English", true)
            ])

            SettingsGroup(rows: [
                ("questionmark.circle", "Help & Support", nil, true),
                ("info.circle", "About LumaLook", "v1.0", true)
            ])
        }
    }
}

private struct SettingsGroup: View {
    let rows: [(icon: String, title: String, value: String?, chevron: Bool)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 14) {
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 1.3)
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: row.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white))
                    Text(row.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let value = row.value {
                        Text(value)
                            .font(.system(size: 16))
                            .foregroundStyle(LumaTheme.textSecondary)
                    }
                    if row.chevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                if index < rows.count - 1 {
                    Hairline().padding(.leading, 64)
                }
            }
        }
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

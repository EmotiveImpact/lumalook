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
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()
    @State private var category = "All"
    @State private var activeTool =
        ProcessInfo.processInfo.environment["LUMA_SEED_TOOL"] ?? "Adjust"
    @State private var showLensPaywall = false
    @State private var mediaReadout: String?
    @State private var videoAspect: CGFloat?
    @State private var showLUTImporter = false
    @State private var lutImportError: String?
    @State private var showLogExplainer = false
    @State private var stashedLookIntensity: Double?
    @State private var showConversionPicker = false
    @AppStorage("lumalook.showScope") private var showScope = false
    @AppStorage("lumalook.scopeMode") private var scopeModeRaw = ScopeMode.waveform.rawValue
    @State private var scopeImage: CGImage?
    private var scopeMode: ScopeMode { ScopeMode(rawValue: scopeModeRaw) ?? .waveform }
    @State private var compareMode = false
    @State private var wipeFraction: Double = 0.5
    @State private var showExportSheet = false
    @State private var isExporting = false
    @State private var compareDuration: Double = 0

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
            if compareMode {
                compareBar
            } else {
                drawer
            }
        }
        .background(LumaTheme.background.ignoresSafeArea())
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: compareMode)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: thumbStamp) {
            thumbs.render(source: app.previewFrame,
                          looks: MockData.looks,
                          luts: app.lutRepository.luts.map { ($0, app.lutRepository.fileURL(for: $0)) })
        }
        .task(id: mediaKey) { await loadMediaReadout() }
        .onDisappear { app.saveGradeSession() }
        .sheet(isPresented: $showLensPaywall) { PaywallView() }
        .lumaToolSheet(isPresented: $showExportSheet, style: .panel) {
            ExportSpecSheet(durationSeconds: app.selectedImage != nil ? 0 : compareDuration,
                            gradeCubeTitle: "LumaLook_\(app.selectedLook.name.components(separatedBy: " ").first ?? "Grade")",
                            lookState: app.lookState) { spec in
                showExportSheet = false
                exportNow(spec: spec)
            }
        }
        .overlay {
            if isExporting {
                ExportOverlay(progress: app.exporter.progress) { app.exporter.cancel() }
                    .overlay(alignment: .top) {
                        if let status = app.batchStatus {
                            TechReadout(status, size: 11, color: .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(.top, 90)
                        }
                    }
            }
        }
        .lumaToolSheet(isPresented: $showConversionPicker, style: .panel) {
            conversionPicker
                .padding(.top, 18)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .alert("Log LUT active", isPresented: $showLogExplainer) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("This LUT was built for Log footage (flat, low-contrast source). On regular footage it can look harsh — lower the intensity, or shoot Log for the intended result.")
        }
        .fileImporter(isPresented: $showLUTImporter,
                      allowedContentTypes: [.data, .plainText],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try app.lutRepository.importLUT(from: url)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    app.selectedLUT = imported
                }
                lutImportError = nil
            } catch {
                lutImportError = "Couldn't read that file as a .cube LUT."
            }
        }
    }

    // MARK: Media surface

    @State private var holdingOriginal = false
    @State private var eyedropping = false
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
            // WB eyedropper: tap a neutral in the frame to balance to it.
            .overlay {
                if eyedropping {
                    GeometryReader { geo in
                        ZStack(alignment: .top) {
                            Color.white.opacity(0.001)
                            Text("Tap something that should be neutral grey/white")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(.top, 12)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { loc in
                            let n = CGPoint(x: min(max(0, loc.x / geo.size.width), 1),
                                            y: min(max(0, loc.y / geo.size.height), 1))
                            Task { await app.whiteBalance(atNormalized: n) }
                            eyedropping = false
                        }
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if compareMode {
                    compareOverlay
                }
            }
            .overlay(alignment: .topTrailing) {
                if showScope, !compareMode {
                    scopeOverlay
                        .padding(.top, 104)
                        .padding(.trailing, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showScope.toggle()
                    LumaHaptics.shared.tap()
                } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(showScope ? LumaTheme.accentBright : .white.opacity(0.85))
                        .frame(width: 38, height: 34)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.lumaPress)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
            .animation(.easeOut(duration: 0.18), value: showScope)
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
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.lumaPress)
            Spacer()
            VStack(spacing: 2) {
                TechReadout("GRADE", size: 12, color: .white.opacity(0.85))
                if !app.batchItems.isEmpty {
                    TechReadout("BATCH · \(app.batchItems.count) ITEMS", size: 8,
                                color: LumaTheme.teal)
                }
            }
            Spacer()
            if app.selectedLUT?.isLogTarget == true {
                Button { showLogExplainer = true } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color(red: 0.95, green: 0.64, blue: 0.36))
                            .frame(width: 6, height: 6)
                        TechReadout("LOG LUT", size: 9,
                                    color: Color(red: 0.95, green: 0.64, blue: 0.36))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.79, green: 0.42, blue: 0.12).opacity(0.24), in: Capsule())
                    .overlay(Capsule().strokeBorder(
                        Color(red: 0.79, green: 0.42, blue: 0.12).opacity(0.65), lineWidth: 1))
                }
                .buttonStyle(.lumaPress)
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
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

            slotChain

            if activeTool == "Lens" {
                lensStrip
            } else {
                lookStrip
            }

            LumaDial(title: activeTool == "Adjust" ? "Intensity" : activeTool,
                     value: dialBinding)
                .padding(.horizontal, 22)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    FlatTool(title: app.isAutoGrading ? "…" : "Auto",
                             icon: "wand.and.stars", selected: false) {
                        Task { await app.autoGrade() }
                        LumaHaptics.shared.tap()
                    }
                    .frame(width: 62)
                    .disabled(app.isAutoGrading)
                    FlatTool(title: "WB", icon: "eyedropper.halffull", selected: eyedropping) {
                        withAnimation(.easeOut(duration: 0.15)) { eyedropping.toggle() }
                        LumaHaptics.shared.tap()
                    }
                    .frame(width: 62)
                    FlatTool(title: "Adjust", icon: "slider.horizontal.3", selected: activeTool == "Adjust") {
                        activeTool = "Adjust"
                    }
                    .frame(width: 62)
                    FlatTool(title: "Lens", icon: "camera.aperture", selected: activeTool == "Lens") {
                        activeTool = "Lens"
                    }
                    .frame(width: 62)
                    FlatTool(title: "Grain", icon: "circle.dotted", selected: activeTool == "Grain") {
                        activeTool = "Grain"
                    }
                    .frame(width: 62)
                    FlatTool(title: "Bloom", icon: "sun.haze", selected: activeTool == "Bloom") {
                        activeTool = "Bloom"
                    }
                    .frame(width: 62)
                    FlatTool(title: "Halation", icon: "circle.hexagongrid.circle", selected: activeTool == "Halation") {
                        activeTool = "Halation"
                    }
                    .frame(width: 62)
                    FlatTool(title: "Vignette", icon: "smallcircle.filled.circle", selected: activeTool == "Vignette") {
                        activeTool = "Vignette"
                    }
                    .frame(width: 62)
                    FlatTool(title: "More", icon: "dial.high", action: { app.path.append(.customLook) })
                        .frame(width: 62)
                }
                .padding(.horizontal, 14)
            }
            .lumaEdgeFade(leading: 12, trailing: 12)

            SolidCTA(title: "Apply Look", height: 52) {
                enterCompare()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
        }
        .padding(.top, 14)
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

    /// One dial, five parameters: the dial always edits the active tool.
    private var dialBinding: Binding<Double> {
        switch activeTool {
        case "Grain": return $app.settings.grain
        case "Bloom": return $app.settings.bloom
        case "Halation": return $app.settings.halation
        case "Vignette": return $app.settings.vignette
        case "Lens": return $app.settings.lensAmount
        default: return $app.settings.intensity
        }
    }

    /// Lens picker strip: glass, not colour — swaps in for the look strip
    /// while the Lens tool is active.
    private var lensStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(LensKind.allCases, id: \.self) { lens in
                    let selected = app.settings.lensKind == lens.rawValue
                    let locked = lens.requiresPro && !storeService.isPro
                    Button {
                        if locked {
                            showLensPaywall = true
                            LumaHaptics.shared.tap()
                            return
                        }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            app.settings.lensKind = lens.rawValue
                        }
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: lens.icon)
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                                .frame(width: 66, height: 50)
                                .background(selected ? LumaTheme.accent : LumaTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13)
                                    .stroke(selected ? LumaTheme.accentBright : .white.opacity(0.07),
                                            lineWidth: selected ? 1.5 : 1))
                                .overlay(alignment: .topTrailing) {
                                    if locked {
                                        Image(systemName: "crown.fill")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.black)
                                            .padding(3)
                                            .background(LumaTheme.gold, in: Circle())
                                            .offset(x: 5, y: -5)
                                    }
                                }
                            Text(lens.label)
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                                .lineLimit(1)
                                .frame(width: 74)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 2)
        }
        .lumaEdgeFade()
    }

    private var lookStrip: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // ORIGINAL: one tap to zero the grade, tap again to return.
                    OriginalTile(active: app.settings.intensity == 0) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            if app.settings.intensity == 0 {
                                app.settings.intensity = stashedLookIntensity ?? 75
                                stashedLookIntensity = nil
                            } else {
                                stashedLookIntensity = app.settings.intensity
                                app.settings.intensity = 0
                            }
                        }
                    }
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
                    AddLUTTile { showLUTImporter = true }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 22)
            }
            .lumaEdgeFade()
            .sensoryFeedback(.selection, trigger: app.selectedLook.id)
            .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
    }
}

// MARK: - Luma scope (queue #15)

extension ApplyLookView {
    fileprivate var scopeStamp: String {
        "\(app.settings)-\(app.selectedLook.id)-\(app.selectedLUT?.id.uuidString ?? "")-\(app.conversionLUT?.id.uuidString ?? "")-\(Int(app.conversionOpacity))-\(Int(app.creativeOpacity))-\(mediaKey)"
    }

    fileprivate var scopeOverlay: some View {
        let scopeW: CGFloat = scopeMode == .vectorscope ? 92 : 130
        let scopeH: CGFloat = scopeMode == .vectorscope ? 92 : 76
        return VStack(alignment: .leading, spacing: 3) {
            TechReadout(scopeMode.title, size: 6.5, color: LumaTheme.textMuted)
            Group {
                if let scopeImage {
                    Image(decorative: scopeImage, scale: 1)
                        .resizable()
                        .frame(width: scopeW, height: scopeH)
                } else {
                    Color.black.frame(width: scopeW, height: scopeH)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text("tap to switch scope")
                .font(.system(size: 6.5, weight: .medium))
                .foregroundStyle(LumaTheme.textMuted)
        }
        .padding(7)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.white.opacity(0.16), lineWidth: 1))
        // Tap the scope itself to cycle waveform → parade → vectorscope → histogram.
        .contentShape(Rectangle())
        .onTapGesture {
            scopeModeRaw = scopeMode.next.rawValue
            LumaHaptics.shared.tap()
        }
        .task(id: "\(scopeStamp)|\(scopeModeRaw)|\(Int(scopeW))x\(Int(scopeH))") {
            guard showScope else { return }
            scopeImage = await Scopes.render(frame: app.previewFrame ?? LookThumbs.fallbackFrame,
                                             state: app.lookState, mode: scopeMode,
                                             size: CGSize(width: scopeW, height: scopeH))
        }
    }

    /// Histogram of the GRADED frame — the scope reads what you'll export.
    fileprivate static func renderHistogram(frame: CIImage, state: LookState) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            let graded = LookPipeline.shared.apply(state: state, to: frame, includeSplit: false)
            let area = CIFilter.areaHistogram()
            area.inputImage = graded
            area.extent = graded.extent
            area.count = 64
            area.scale = 12
            guard let histogram = area.outputImage else { return nil }
            let display = CIFilter.histogramDisplay()
            display.inputImage = histogram
            display.height = 44
            display.highLimit = 1
            display.lowLimit = 0
            guard let image = display.outputImage else { return nil }
            return LookPipeline.shared.context.createCGImage(image, from: image.extent)
        }.value
    }
}

// MARK: - Compare mode (queue #7)

extension ApplyLookView {
    fileprivate func enterCompare() {
        wipeFraction = 0.5
        app.lookState.splitFraction = wipeFraction
        compareMode = true
        app.refreshPreviewFrame()
        app.objectWillChange.send()
        LumaHaptics.shared.tap()
        Task {
            if let url = app.selectedVideoURL,
               let d = try? await AVURLAsset(url: url).load(.duration).seconds { compareDuration = d }
        }
    }

    fileprivate func exitCompare() {
        compareMode = false
        app.lookState.splitFraction = nil
        app.refreshPreviewFrame()
        app.objectWillChange.send()
    }

    /// Wipe divider + grabber + corner labels, drag anywhere to move.
    fileprivate var compareOverlay: some View {
        GeometryReader { geo in
            ZStack {
                // Divider + knob at the wipe position.
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.7), radius: 5)
                    .position(x: geo.size.width * wipeFraction, y: geo.size.height / 2)
                Circle()
                    .fill(.black.opacity(0.75))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .overlay(
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                    )
                    .position(x: geo.size.width * wipeFraction, y: geo.size.height / 2)

                TechReadout("ORIGINAL", size: 8, color: .white.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .position(x: 52, y: 66)
                TechReadout("GRADED · \(Int(app.settings.intensity))%", size: 8,
                            color: LumaTheme.accentBright)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .position(x: geo.size.width - 74, y: 66)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        wipeFraction = min(max(drag.location.x / geo.size.width, 0.05), 0.95)
                        app.lookState.splitFraction = wipeFraction
                        app.refreshPreviewFrame()
                        app.objectWillChange.send()
                    }
            )
        }
    }

    fileprivate var compareBar: some View {
        HStack(spacing: 10) {
            Button { exitCompare() } label: {
                Text("CANCEL")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.lumaPress)
            SolidCTA(title: "Use This Grade", height: 48) {
                exitCompare()
                showExportSheet = true
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.ultraThinMaterial)
                LumaTheme.background.opacity(0.45)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    fileprivate func exportNow(spec: ExportSpec) {
        guard app.player != nil || app.selectedImage != nil else {
            app.exportError = "Pick a video or photo from your library first."
            return
        }
        isExporting = true
        Task {
            if !app.batchItems.isEmpty {
                // One grade across the whole set (queue #10).
                let done = await app.runBatchExport(spec: spec)
                isExporting = false
                if done > 0 {
                    LumaHaptics.shared.exportSuccess()
                    app.path.append(.exportComplete)
                }
            } else {
                let success = await app.exportCurrentVideo(spec: spec)
                isExporting = false
                if success {
                    LumaHaptics.shared.exportSuccess()
                    app.path.append(.exportComplete)
                }
            }
        }
    }
}

// MARK: - LUT slot chain (queue #9)

extension ApplyLookView {
    /// Conversion x Creative slot chain — the PeekLut/Lutter stacking model.
    /// Drag horizontally on a slot to set its opacity.
    private var slotChain: some View {
        HStack(spacing: 8) {
            SlotCard(kind: "SLOT 1 · CONVERSION",
                     name: app.conversionLUT?.displayName ?? "None",
                     opacity: $app.conversionOpacity,
                     isActive: app.conversionLUT != nil,
                     accented: false) {
                showConversionPicker = true
            }
            SlotCard(kind: "SLOT 2 · CREATIVE",
                     name: app.selectedLUT?.displayName ?? app.selectedLook.name,
                     opacity: $app.creativeOpacity,
                     isActive: true,
                     accented: true) { }
        }
        .padding(.horizontal, 22)
    }

    private var conversionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TechReadout("CONVERSION LUT — APPLIED FIRST", size: 9, color: LumaTheme.textMuted)
                .padding(.horizontal, 22)
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        app.conversionLUT = nil
                        showConversionPicker = false
                    } label: {
                        pickerRow(name: "None", tag: nil, selected: app.conversionLUT == nil)
                    }
                    .buttonStyle(.lumaPress)
                    // Log-target LUTs first: that's what conversion slots are for.
                    ForEach(app.lutRepository.luts.sorted {
                        ($0.isLogTarget ? 0 : 1, $0.displayName) < ($1.isLogTarget ? 0 : 1, $1.displayName)
                    }) { lut in
                        Button {
                            app.conversionLUT = lut
                            showConversionPicker = false
                        } label: {
                            pickerRow(name: lut.displayName,
                                      tag: lut.isLogTarget ? "LOG" : nil,
                                      selected: app.conversionLUT?.id == lut.id)
                        }
                        .buttonStyle(.lumaPress)
                    }
                }
                .padding(.horizontal, 22)
            }
        }
    }

    private func pickerRow(name: String, tag: String?, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? LumaTheme.accentBright : LumaTheme.textMuted)
            Text(name)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let tag {
                TechReadout(tag, size: 8, color: Color(red: 0.95, green: 0.64, blue: 0.36))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.79, green: 0.42, blue: 0.12).opacity(0.22), in: Capsule())
            }
            Spacer()
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// One slot in the chain: kind label, LUT name, opacity bar. Horizontal drag
/// sets opacity with 10% detents.
private struct SlotCard: View {
    let kind: String
    let name: String
    @Binding var opacity: Double
    let isActive: Bool
    let accented: Bool
    let onTap: () -> Void

    @State private var dragStart: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TechReadout(kind, size: 7, color: LumaTheme.textMuted)
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isActive ? .white : LumaTheme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(opacity))%")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(isActive ? LumaTheme.accentBright : LumaTheme.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(LumaTheme.accentBright)
                        .frame(width: isActive ? geo.size.width * opacity / 100 : 0)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(accented ? AnyShapeStyle(LumaTheme.accent.opacity(0.12))
                             : AnyShapeStyle(.white.opacity(0.04)),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(accented ? LumaTheme.accent.opacity(0.55) : .white.opacity(0.14),
                          lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { drag in
                    guard isActive else { return }
                    if dragStart == nil { dragStart = opacity }
                    opacity = min(max(0, (dragStart ?? opacity) + Double(drag.translation.width) / 1.4), 100)
                }
                .onEnded { _ in dragStart = nil }
        )
        .sensoryFeedback(.selection, trigger: Int(opacity / 10))
        .animation(.snappy(duration: 0.15), value: opacity)
    }
}

/// Strip-leading ORIGINAL tile: the ungraded frame, one tap away — the
/// grading-app equivalent of a reference monitor.
private struct OriginalTile: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LumaTheme.background)
                    .frame(width: 96, height: 96)
                    .overlay {
                        TechReadout("ORIG", size: 9,
                                    color: active ? LumaTheme.accentBright : LumaTheme.textMuted)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(style: StrokeStyle(lineWidth: active ? 2 : 1, dash: [5, 4]))
                        .foregroundStyle(active ? LumaTheme.accentBright : .white.opacity(0.18)))
                Text("Original")
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? .white : LumaTheme.textSecondary)
            }
        }
        .buttonStyle(.lumaPress)
    }
}

/// Strip-trailing import tile: .cube files land directly in the strip.
private struct AddLUTTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.04))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(LumaTheme.accentBright)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.18)))
                Text("Add LUT")
                    .font(.system(size: 13))
                    .foregroundStyle(LumaTheme.textSecondary)
            }
        }
        .buttonStyle(.lumaPress)
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

import SwiftUI
import AVKit

/// Video preview with the live look applied, falling back to the painted
/// scene when no real clip is selected.
struct LookPreviewSurface: View {
    @EnvironmentObject private var app: AppModel
    var radius: CGFloat = 18
    /// Hosts that carry their own bottom-leading readout stack must switch this
    /// off and place the hint themselves — otherwise two independent overlays
    /// claim the same anchor and composite on top of each other.
    var showsEmptyHint: Bool = true

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
                        if showsEmptyHint {
                            EmptyMediaHint().padding(10)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.06)))
    }
}

/// The "no clip picked yet" pill. Shared so the surface and the hosts that
/// place it inside their own readout stack render exactly one visual language.
struct EmptyMediaHint: View {
    var body: some View {
        Label("Preview — pick a clip to grade live", systemImage: "film")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
    }
}

/// The single source-resolution ladder for every RENDER SURFACE in the
/// grade/compare flow — stage, corner compare tile, scope, side-by-side panes.
/// They must all describe the same photograph: a stage showing the hero while
/// the compare tile shows a different picture is not a before/after.
///
/// `LookSwatch.referenceFrame` (photo + calibration patch band) is deliberately
/// NOT in this ladder: it exists so twelve look TILES read as twelve grades,
/// and it must never reach a surface the user is judging their image on.
enum GradeSourceFrame {
    /// Decoded once — `HeroPhoto.ciImage` re-reads the file on every access.
    private static let hero: CIImage? = HeroPhoto.golden.ciImage

    @MainActor static func current(_ app: AppModel) -> CIImage {
        app.previewFrame ?? app.selectedImage ?? hero ?? LookThumbs.fallbackFrame
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
    @State private var activeTool =
        ProcessInfo.processInfo.environment["LUMA_SEED_TOOL"] ?? "Opacity"
    @State private var showLensPaywall = false
    @State private var mediaReadout: String?
    @State private var videoAspect: CGFloat?
    /// The unified look browser (step 4) — category chips, search, favourites
    /// and import all live in the sheet now, not in the drawer.
    @State private var showLookBrowser =
        ProcessInfo.processInfo.environment["LUMA_SEED_BROWSER"] == "1"
    @State private var showLogExplainer = false
    @State private var stashedLookIntensity: Double?
    @State private var showConversionPicker = false
    /// T2.4 — side-by-side LUT compare grid.
    @State private var showCompareGrid = false
    @AppStorage("lumalook.showScope") private var showScope = false
    @AppStorage("lumalook.scopeMode") private var scopeModeRaw = ScopeMode.waveform.rawValue
    @State private var scopeImage: CGImage?
    private var scopeMode: ScopeMode { ScopeMode(rawValue: scopeModeRaw) ?? .waveform }
    /// Ungraded thumbnail behind the corner Compare tile — press-and-hold on
    /// the tile peeks the original without leaving the grade room. The FULL
    /// compare surface (wipe / flip / side-by-side + export) is BeforeAfterView,
    /// reached from the header Compare button and from Apply.
    @State private var originalThumb: CGImage?

    private var thumbStamp: String {
        "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.library.all.count)"
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
                          library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        .task(id: mediaKey) { await loadMediaReadout() }
        .task(id: mediaKey) { renderOriginalThumb() }
        .onDisappear { app.saveGradeSession() }
        .sheet(isPresented: $showLensPaywall) { PaywallView() }
        .sheet(isPresented: $showCompareGrid) { LUTCompareView() }
        // C3 fix: export failures/refusals were set on `app.exportError` but
        // never rendered here — the sheet closed and nothing happened. Same
        // capsule style as the root import toast.
        .overlay(alignment: .top) {
            if let error = app.exportError {
                Text(error)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(LumaTheme.orange.opacity(0.55), lineWidth: 1))
                    .padding(.horizontal, 30)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        withAnimation(.easeOut(duration: 0.25)) { app.exportError = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.exportError != nil)
        .onAppear { app.exportError = nil }   // never show a stale error from a previous flow
        .lumaToolSheet(isPresented: $showConversionPicker, style: .panel) {
            ScrollView {
                conversionPicker.padding(.top, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .alert("Log LUT active", isPresented: $showLogExplainer) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("This LUT was built for Log footage (flat, low-contrast source). On regular footage it can look harsh — lower the intensity, or shoot Log for the intended result.")
        }
        // A2's contract is "preview stays visible above the sheet at all times",
        // so the grade-room browser opens at MEDIUM (canvas still live and
        // undimmed) and only grows if the user drags it up.
        .lumaToolSheet(isPresented: $showLookBrowser, style: Self.lookBrowserSheetStyle) {
            LookBrowserSheet(context: .grade, intensity: $app.settings.intensity)
        }
    }

    /// Look browser as presented from the grade room: same detent ladder as
    /// `.tallPanel`, but it OPENS at medium so the fitted preview it is meant
    /// to be previewing against is never buried.
    private static let lookBrowserSheetStyle = LumaSheetStyle(
        detents: [.lumaMedium, .lumaLarge, .large],
        defaultDetent: .lumaMedium,
        undimmedUpThrough: .lumaMedium
    )

    // MARK: Media surface

    @State private var holdingOriginal = false
    @State private var eyedropping = false
    @State private var stashedIntensity: Double?

    /// True while the stage is showing the bundled hero photo rather than the
    /// user's own media.
    private var hasRealMedia: Bool {
        app.player != nil || app.selectedImage != nil
    }

    private var mediaSurface: some View {
        LookPreviewSurface(radius: 0, showsEmptyHint: false)
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
                peekOriginal(pressing)
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
            .overlay(alignment: .topTrailing) {
                if showScope {
                    scopeOverlay
                        .padding(.top, 104)
                        .padding(.trailing, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
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
                    compareTile
                }
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
            .animation(.easeOut(duration: 0.18), value: showScope)
            .overlay(alignment: .top) { topBar }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if !hasRealMedia {
                        EmptyMediaHint()
                    }
                    if holdingOriginal {
                        TechReadout("ORIGINAL", size: 11)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                            .transition(.opacity)
                    }
                    // What is on the frame right now, in one line — the same
                    // readout the compare screen carries.
                    TechReadout("\((app.selectedLUT?.displayName ?? app.selectedLook.name).uppercased()) · \(Int(app.settings.intensity))%",
                                size: 9, color: LumaTheme.accentBright)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
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

    /// C1 corner Compare tile: the ungraded frame, pressed and held to peek the
    /// original. This is the QUICK peek — deliberately gesture-only and local.
    /// The header Compare button opens BeforeAfterView, the canonical
    /// deep-compare surface (wipe / hold-to-flip / side-by-side + export).
    private var compareTile: some View {
        VStack(spacing: 0) {
            Group {
                if let originalThumb {
                    Image(decorative: originalThumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LumaTheme.surfaceStrong
                }
            }
            .frame(width: 64, height: 64)
            .clipped()
            .overlay(alignment: .bottom) {
                TechReadout("HOLD ⇢ ORIG", size: 7, color: .white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(holdingOriginal ? .white : .white.opacity(0.4),
                              lineWidth: holdingOriginal ? 2 : 1))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 40) {
        } onPressingChanged: { pressing in
            peekOriginal(pressing)
        }
        .accessibilityLabel("Hold to see the original")
    }

    /// Zeroes intensity while held and restores it on release — one stash so a
    /// second press mid-peek can never strand the grade at 0.
    private func peekOriginal(_ pressing: Bool) {
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

    /// Ungraded render of the current preview frame for the Compare tile.
    private func renderOriginalThumb() {
        // Must be the ungraded twin of whatever LookPreviewSurface is showing —
        // the tile's whole contract is "this is your frame, without the look".
        let frame = GradeSourceFrame.current(app)
        let extent = frame.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else {
            originalThumb = nil
            return
        }
        originalThumb = LookPipeline.shared.context.createCGImage(frame, from: extent)
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
            HStack(spacing: 6) {
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
                }
                // The canonical deep-compare surface. Labelled, not a bare icon,
                // so the split between "hold the corner tile to peek" and "open
                // the compare screen" is legible without discovery.
                Button {
                    LumaHaptics.shared.tap()
                    app.path.append(.beforeAfter)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 13, weight: .semibold))
                        TechReadout("COMPARE", size: 9, color: .white)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.lumaPress)
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
            slotChain

            if activeTool == "Lens" {
                lensStrip
            } else {
                lookStrip
            }

            // The dial edits the ACTIVE effect. Opacity has its own pinned row
            // above Apply, so showing the dial for it too would be two controls
            // on one value.
            if showsEffectDial {
                LumaDial(title: activeTool, value: dialBinding)
                    .padding(.horizontal, 22)
            }

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
                    FlatTool(title: "Opacity", icon: "slider.horizontal.3", selected: !showsEffectDial) {
                        activeTool = "Opacity"
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

            // Opacity sits directly above Apply — the two things every user
            // touches last, pinned in the one-handed zone.
            GradeOpacityRow(value: $app.settings.intensity)
                .padding(.horizontal, 22)

            applyRow
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

    /// "Adjust" is the legacy value LUMA_SEED_TOOL may still pass for the
    /// intensity tool; both mean "the pinned Opacity row owns this".
    private var showsEffectDial: Bool {
        activeTool != "Opacity" && activeTool != "Adjust"
    }

    // MARK: Apply — pinned, always enabled, never a dead end

    /// The library entry matching the grade currently on screen, via the one
    /// selection truth. nil only for a fully hand-built grade (Skin First
    /// preset, custom settings) that no library look describes.
    private var currentLibraryLook: LibraryLook? {
        app.library.all.first { app.isCurrent($0) }
    }

    private var applyRow: some View {
        HStack(spacing: 10) {
            favouriteButton
            SolidCTA(title: "Apply Look", height: 52) { applyAndAdvance() }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }

    /// One tap saves the look+opacity combo. For a LUT the opacity is real
    /// stored state (`defaultOpacity`), so starring at 62% brings it back at
    /// 62% from Favourites anywhere in the app.
    private var favouriteButton: some View {
        let look = currentLibraryLook
        let on = look.map { app.library.isFavourite($0.id) } ?? false
        return Button {
            guard let look else { return }
            if !on, case .lut(let file) = look.source {
                app.lutRepository.setDefaults(for: file.id,
                                              opacity: app.creativeOpacity,
                                              blend: app.creativeBlend.rawValue)
            }
            app.library.toggleFavourite(look)
            LumaHaptics.shared.tap()
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? LumaTheme.gold : .white)
                .frame(width: 56, height: 52)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                    on ? LumaTheme.gold.opacity(0.55) : .white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.lumaPress)
        .disabled(look == nil)
        .opacity(look == nil ? 0.4 : 1)
        .accessibilityLabel(on ? "Remove from favourites" : "Save this look to favourites")
    }

    /// Apply is never disabled: the current look at the current opacity is
    /// always a valid answer. With no media the forward move is the picker,
    /// not a disabled button.
    private func applyAndAdvance() {
        LumaHaptics.shared.tap()
        guard app.player != nil || app.selectedImage != nil else {
            app.path = [.selectClip]
            return
        }
        if let look = currentLibraryLook { app.library.noteUsed(look) }
        app.saveGradeSession()
        app.exportError = nil
        app.path.append(.beforeAfter)      // C2 — compare, confirm, export
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

    /// Strip id of the look that is currently applied, if it is in the strip at
    /// all. Drives both the ring and the auto-scroll — a selected tile parked
    /// off-screen reads as "nothing applied".
    private var selectedStripID: String? {
        app.library.stripLooks().first(where: { app.isCurrent($0) })?.id
    }

    private var lookStrip: some View {
        ScrollViewReader { proxy in
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
                    // The bounded library strip: recents → favourites → rest,
                    // one shared tile, one selection truth. The full library
                    // (chips, search, collections, import) is one tap away
                    // behind the All Looks tile.
                    ForEach(app.library.stripLooks()) { look in
                        LookStripTile(look: look,
                                      image: thumbs.images[look.thumbKey],
                                      selected: app.isCurrent(look)) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                app.select(look: look)
                            }
                        }
                        .id(look.id)
                        .scrollTransition(.interactive) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.9)
                                .opacity(phase.isIdentity ? 1 : 0.6)
                        }
                    }
                    // Skin First: research-tuned presets for Black & deep
                    // skin (LookSettings, no LUT — bakes cleanly).
                    ForEach(SkinFirstPreset.allCases) { preset in
                        LookThumbCell(
                            title: preset.name,
                            grade: Color(hex: preset.tintHex),
                            selected: app.selectedLUT == nil && app.settings == preset.settings,
                            badge: "SKIN",
                            image: nil
                        ) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                app.selectedLUT = nil
                                app.settings = preset.settings
                            }
                        }
                        .scrollTransition(.interactive) { content, phase in
                            content.scaleEffect(phase.isIdentity ? 1 : 0.9)
                                .opacity(phase.isIdentity ? 1 : 0.6)
                        }
                    }
                    AllLooksTile {
                        showLookBrowser = true
                        LumaHaptics.shared.tap()
                    }
                    // T2.4 — compare: same grade, different LUTs, side by side.
                    Button {
                        showCompareGrid = true
                        LumaHaptics.shared.tap()
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(LumaTheme.surface)
                                .frame(width: 96, height: 96)
                                .overlay {
                                    Image(systemName: "square.grid.2x2")
                                        .font(.system(size: 26, weight: .medium))
                                        .foregroundStyle(LumaTheme.accentBright)
                                }
                                .overlay(RoundedRectangle(cornerRadius: 16)
                                    .stroke(.white.opacity(0.08)))
                            Text("Compare")
                                .font(.system(size: 12))
                                .foregroundStyle(LumaTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.lumaPress)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 22)
            }
            .lumaEdgeFade()
            .sensoryFeedback(.selection, trigger: app.selectedLook.id)
            .sensoryFeedback(.selection, trigger: app.selectedLUT?.id)
            .onAppear {
                guard let id = selectedStripID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onChange(of: selectedStripID) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
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
            scopeImage = await Scopes.render(frame: GradeSourceFrame.current(app),
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

// MARK: - LUT slot chain (queue #9)

extension ApplyLookView {
    /// Conversion x Creative slot chain — the PeekLut/Lutter stacking model.
    /// Drag horizontally on a slot to set its opacity.
    private var slotChain: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SlotCard(kind: "SLOT 1 · CONVERSION",
                         name: app.conversionLUT?.displayName ?? "None",
                         opacity: $app.conversionOpacity,
                         isActive: app.conversionLUT != nil,
                         accented: false) {
                    showConversionPicker = true
                }
                // With a LUT loaded the slot owns the LUT's own opacity. With a
                // preset look it is LABELLED with that look, so it must drive the
                // look's strength — the same value the Opacity slider and the
                // on-frame readout show. Two numbers for one look is a bug.
                SlotCard(kind: "SLOT 2 · CREATIVE",
                         name: app.selectedLUT?.displayName ?? app.selectedLook.name,
                         opacity: app.selectedLUT != nil ? $app.creativeOpacity
                                                         : $app.settings.intensity,
                         isActive: true,
                         accented: true) {
                    // Tap the creative slot to swap the look — opens the
                    // unified browser (was a dead tap in the audit).
                    showLookBrowser = true
                    LumaHaptics.shared.tap()
                }
            }
            // Blend mode for the creative LUT slot (only when a LUT is loaded).
            if app.selectedLUT != nil {
                HStack(spacing: 6) {
                    ForEach(LUTBlendMode.allCases, id: \.self) { mode in
                        Button {
                            app.creativeBlend = mode
                            LumaHaptics.shared.tap()
                        } label: {
                            Text(mode.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(app.creativeBlend == mode ? .white : LumaTheme.textSecondary)
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(app.creativeBlend == mode ? LumaTheme.accent : LumaTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .animation(.easeOut(duration: 0.15), value: app.selectedLUT?.id)
    }

    private var conversionPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TechReadout("SOURCE FORMAT — NORMALISED FIRST", size: 9, color: LumaTheme.textMuted)
                .padding(.horizontal, 22)
            // T2.8 — built-in log profiles: the public transfer math baked to a
            // cube. No vendor files; mutually exclusive with a conversion LUT.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LogProfile.allCases, id: \.self) { profile in
                        let on = app.conversionProfile == profile
                        Button {
                            app.conversionProfile = on ? nil : profile
                            LumaHaptics.shared.tap()
                        } label: {
                            Text(profile.label)
                                .font(.system(size: 13, weight: .semibold))
                                .fixedSize()
                                .foregroundStyle(on ? .black : .white)
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(on ? AnyShapeStyle(LumaTheme.accentBright)
                                               : AnyShapeStyle(LumaTheme.surface), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
            }
            TechReadout("CONVERSION LUT — APPLIED FIRST", size: 9, color: LumaTheme.textMuted)
                .padding(.horizontal, 22)
                .padding(.top, 6)
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        app.conversionLUT = nil
                        app.conversionProfile = nil
                        showConversionPicker = false
                    } label: {
                        pickerRow(name: "None", tag: nil,
                                  selected: app.conversionLUT == nil && app.conversionProfile == nil)
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
                // An empty slot has no strength to report — an em dash matches
                // the empty track and the muted "None" title.
                Text(isActive ? "\(Int(opacity))%" : "—")
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

/// The pinned opacity row from C1/C2: label, track, mono value. Shared by the
/// grade room and the compare screen so the control that decides how strong a
/// look is looks and feels identical in both.
struct GradeOpacityRow: View {
    var title: String = "Opacity"
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100

    // Same 5-unit detents as LumaDial, so the two controls feel like one.
    private var detent: Int { Int(value / 5) }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LumaTheme.textSecondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(LumaTheme.accentBright)
            Text("\(Int(value))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.15), value: Int(value))
                .foregroundStyle(.white)
                .frame(width: 30, alignment: .trailing)
        }
        .sensoryFeedback(.selection, trigger: detent)
    }
}

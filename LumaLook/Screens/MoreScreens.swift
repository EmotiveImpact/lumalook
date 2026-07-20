import SwiftUI
import AVFoundation
import UIKit

// MARK: - 09 Filter Store

struct FilterStoreView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false

    private var featured: LookPack { PackCatalog.packs[1] }   // Cine Print Set 01

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 2) {
                        Text("LOOK STORE")
                            .font(.system(size: 17, weight: .bold))
                            .tracking(2.2)
                            .foregroundStyle(.white)
                        TechReadout("\(PackCatalog.totalLookCount) LOOKS · \(PackCatalog.packs.count) PACKS",
                                    size: 10, color: LumaTheme.textMuted)
                    }
                    HStack {
                        if !isRoot {
                            BackArrow()
                        }
                        Spacer()
                    }
                }
                .frame(height: 52)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 10)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        SectionHeader(title: "Featured Pack")

                        Button {
                            app.selectedPackID = featured.id
                            app.path.append(.filterPack)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(featured.name.uppercased())
                                            .font(.system(size: 24, weight: .heavy))
                                            .tracking(1)
                                            .lineLimit(2)
                                        Text("\(featured.looks.count) film-print looks")
                                            .font(.system(size: 14))
                                            .foregroundStyle(LumaTheme.textSecondary)
                                            .padding(.top, 2)
                                        Text(app.packStore.isInstalled(featured) ? "INSTALLED" : featured.price)
                                            .font(.system(size: 15, weight: .bold))
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 8)
                                            .background(app.packStore.isInstalled(featured)
                                                        ? AnyShapeStyle(LumaTheme.surfaceStrong)
                                                        : AnyShapeStyle(LumaTheme.accent), in: Capsule())
                                            .padding(.top, 8)
                                    }
                                    .foregroundStyle(.white)
                                    .padding(18)
                                    Spacer(minLength: 0)
                                    HeroImage(photo: featured.photo)
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
                        .buttonStyle(.lumaPress)

                        SectionHeader(title: "All Packs")

                        VStack(spacing: 0) {
                            ForEach(Array(PackCatalog.packs.enumerated()), id: \.element.id) { index, pack in
                                StoreRow(pack: pack)
                                if index < PackCatalog.packs.count - 1 {
                                    Hairline().padding(.leading, 92)
                                }
                            }
                        }

                        Text(MockData.namingDisclaimer)
                            .font(.system(size: 11))
                            .foregroundStyle(LumaTheme.textMuted)
                            .padding(.top, 8)
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
    let pack: LookPack

    var body: some View {
        Button {
            app.selectedPackID = pack.id
            app.path.append(.filterPack)
        } label: {
            HStack(spacing: 14) {
                HeroImage(photo: pack.photo, radius: 12)
                    .frame(width: 78, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(pack.looks.count) looks · \(pack.eraTag)")
                        .font(.system(size: 13))
                        .foregroundStyle(LumaTheme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if app.packStore.isInstalled(pack) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(LumaTheme.teal)
                } else {
                    Text(pack.price)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(LumaTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.lumaPress)
    }
}

struct BackArrow: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 10 Filter Pack Detail

struct FilterPackDetailView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @State private var previews: [String: CGImage] = [:]
    @State private var installing = false
    @State private var installedFlash = 0
    @State private var showPaywall = false

    /// Free, individually bought, or unlocked by Pro.
    private var unlocked: Bool { storeService.ownsPack(pack.id) }

    private var pack: LookPack {
        app.selectedPackID.flatMap(PackCatalog.pack(id:)) ?? PackCatalog.packs[0]
    }

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Hero with overlaid title.
                    ZStack(alignment: .bottomLeading) {
                        HeroImage(photo: pack.photo)
                            .frame(height: 300)
                            .overlay(LinearGradient(colors: [.clear, LumaTheme.background],
                                                    startPoint: .center, endPoint: .bottom))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pack.name.uppercased())
                                .font(.system(size: 34, weight: .heavy))
                                .tracking(2)
                            TechReadout(pack.eraTag.uppercased(), size: 10,
                                        color: .white.opacity(0.7))
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
                        Text("\(pack.looks.count) looks · every one dialable")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.top, 18)
                        Text(pack.familyLine)
                            .font(.system(size: 16))
                            .foregroundStyle(LumaTheme.textSecondary)
                            .lineSpacing(3)

                        installButton
                            .padding(.top, 8)

                        SectionHeader(title: "Looks Included")
                            .padding(.top, 14)

                        // Every look previewed through the REAL pipeline on
                        // real photography — locked or not, you always see it.
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                            ForEach(pack.looks) { look in
                                VStack(spacing: 8) {
                                    Group {
                                        if let cg = previews[look.code] {
                                            GradedThumb(image: cg,
                                                        size: CGSize(width: 104, height: 96),
                                                        radius: 14)
                                        } else {
                                            RoundedRectangle(cornerRadius: 14)
                                                .fill(LumaTheme.surfaceStrong)
                                        }
                                    }
                                    .frame(height: 96)
                                    Text(look.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                        }

                        Text(MockData.namingDisclaimer)
                            .font(.system(size: 11))
                            .foregroundStyle(LumaTheme.textMuted)
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.success, trigger: installedFlash)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task(id: pack.id) { renderPreviews() }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUMA_AUTO_INSTALL"] == "1" {
                performInstall()
            }
            #endif
        }
    }

    private func performInstall() {
        guard !app.packStore.isInstalled(pack), !installing else { return }
        installing = true
        Task {
            let count = PackInstaller.install(pack, into: app.lutRepository)
            installing = false
            if count > 0 {
                app.packStore.markInstalled(pack)
                installedFlash += 1
                // Post-install confirmation — tells the user where the looks
                // landed instead of leaving them to hunt.
                app.importToast = "\(pack.name) installed — \(count) looks in your library"
            }
        }
    }

    /// Paid packs buy through StoreKit first (C5); free/owned packs install
    /// straight away. LUMA_AUTO_INSTALL keeps bypassing purchase in DEBUG so
    /// headless verification of the bake pipeline still works.
    private func buyOrInstall() {
        if unlocked {
            performInstall()
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_AUTO_INSTALL"] == "1" {
            performInstall()
            return
        }
        #endif
        guard let product = storeService.packProducts[pack.id] else {
            // Products unavailable (offline/review): offer Pro instead.
            showPaywall = true
            return
        }
        Task {
            if await storeService.purchase(product) {
                performInstall()
            }
        }
    }

    private var displayPrice: String {
        storeService.packProducts[pack.id]?.displayPrice ?? pack.price
    }

    private var installButton: some View {
        VStack(spacing: 10) {
            Button {
                if app.packStore.isInstalled(pack) {
                    // Use now — context aware: if a project is already open,
                    // jump to the editor (the looks are live in its strip);
                    // else open the grade room, straight in when media is
                    // chosen, otherwise via Select Clip.
                    if !app.editor.clips.isEmpty {
                        app.path = [.editor]
                    } else if app.selectedVideoURL != nil || app.selectedImage != nil {
                        app.path.append(.applyLook)
                    } else {
                        app.path.append(.selectClip)
                    }
                    LumaHaptics.shared.tap()
                } else {
                    buyOrInstall()
                }
            } label: {
                HStack(spacing: 10) {
                    if installing || storeService.purchaseInFlight {
                        ProgressView().tint(.white)
                    } else if app.packStore.isInstalled(pack) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Installed — Use now")
                        Image(systemName: "arrow.right")
                    } else if unlocked {
                        Text(pack.isFree ? "Install Free" : "Install")
                    } else if pack.isProIncluded {
                        Label("Unlock with Pro", systemImage: "crown.fill")
                    } else {
                        Text("\(displayPrice) · Buy")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(app.packStore.isInstalled(pack)
                            ? AnyShapeStyle(LumaTheme.surfaceStrong)
                            : AnyShapeStyle(LumaTheme.accent),
                            in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.lumaPress)
            // Installed is now an ENABLED "Use now" door, not a dead end.
            .disabled(storeService.purchaseInFlight)

            if !unlocked && !pack.isProIncluded {
                Button {
                    showPaywall = true
                } label: {
                    Text("Or get every pack with Pro")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Renders each pack look onto the hero frame through the pipeline.
    private func renderPreviews() {
        let source = LookThumbs.fallbackFrame
        let looks = pack.looks
        Task.detached(priority: .userInitiated) {
            for look in looks {
                let state = LookState()
                if let cubeFile = look.cubeFile,
                   let url = Bundle.main.url(
                       forResource: (cubeFile as NSString).deletingPathExtension,
                       withExtension: "cube") {
                    // Measured film stock: preview through the real LUT.
                    state.lut = try? LookPipeline.shared.loadLUT(at: url)
                } else {
                    state.recipe = look.recipe
                }
                var settings = LookSettings()
                settings.intensity = 100
                state.settings = settings
                if let cg = LookPipeline.shared.gradedStill(source, state: state, maxDimension: 220) {
                    await MainActor.run { previews[look.code] = cg }
                }
            }
        }
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
                        app.select(look: LibraryLook(saved: look))
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
                                    app.select(look: LibraryLook(saved: look))
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
    @EnvironmentObject private var storeService: StoreService
    @State private var showLensPaywall = false
    @State private var tab =
        ProcessInfo.processInfo.environment["LUMA_SEED_COLORTAB"] ?? "ADJUST"
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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["ADJUST", "CURVES", "WHEELS", "HSL", "SPLIT", "EFFECTS"], id: \.self) { segment in
                        Button { tab = segment } label: {
                            Text(segment)
                                .font(.system(size: 12, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(tab == segment ? .white : LumaTheme.textSecondary)
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .background(tab == segment ? LumaTheme.accent : LumaTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
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
                    GradeSlider(title: "Sharpness", value: Binding(
                        get: { app.settings.sharpness },
                        set: { app.settings.sharpness = max(0, $0) }))
                    GradeSlider(title: "Fade", value: Binding(
                        get: { app.settings.fade },
                        set: { app.settings.fade = max(0, $0) }))
                }
                .padding(.top, 6)
            } else if tab == "CURVES" {
                CurveEditorPanel(curves: $app.settings.curves)
                    .padding(.top, 8)
            } else if tab == "WHEELS" {
                ColorWheelsPanel(wheels: $app.settings.wheels)
                    .padding(.top, 8)
            } else if tab == "HSL" {
                HSLPanel(hsl: $app.settings.hsl)
                    .padding(.top, 8)
            } else if tab == "SPLIT" {
                SplitTonePanel(tone: $app.settings.splitTone)
                    .padding(.top, 8)
            } else if tab == "EFFECTS" {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Lens")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
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
                                    app.settings.lensKind = lens.rawValue
                                    LumaHaptics.shared.tap()
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: lens.icon)
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                                            .frame(width: 62, height: 48)
                                            .background(selected ? LumaTheme.accent : LumaTheme.surface,
                                                        in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(alignment: .topTrailing) {
                                                if locked {
                                                    Image(systemName: "crown.fill")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(.black)
                                                        .padding(3)
                                                        .background(LumaTheme.gold, in: Circle())
                                                        .offset(x: 4, y: -4)
                                                }
                                            }
                                        Text(lens.label)
                                            .font(.system(size: 11))
                                            .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                                            .lineLimit(1)
                                            .frame(width: 70)
                                    }
                                }
                                .buttonStyle(.lumaPress)
                            }
                        }
                    }
                    if let lens = LensKind(rawValue: app.settings.lensKind), lens != .none {
                        Text(lens.blurb)
                            .font(.footnote)
                            .foregroundStyle(LumaTheme.textMuted)
                        GradeSlider(title: "Lens Strength", value: Binding(
                            get: { app.settings.lensAmount },
                            set: { app.settings.lensAmount = max(0, $0) }))
                    }

                    Text("Film Texture")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .padding(.top, 4)
                    GradeSlider(title: "Grain", value: Binding(
                        get: { app.settings.grain },
                        set: { app.settings.grain = max(0, $0) }))
                    GradeSlider(title: "Bloom", value: Binding(
                        get: { app.settings.bloom },
                        set: { app.settings.bloom = max(0, $0) }))
                    GradeSlider(title: "Halation", value: Binding(
                        get: { app.settings.halation },
                        set: { app.settings.halation = max(0, $0) }))
                    GradeSlider(title: "Vignette", value: Binding(
                        get: { app.settings.vignette },
                        set: { app.settings.vignette = max(0, $0) }))
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
        .sheet(isPresented: $showLensPaywall) { PaywallView() }
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

/// Projects as a NATIVE inset-grouped List (Apple-native tranche 2):
/// swipe to delete, native separators — records read as records.
struct ProjectLibraryView: View {
    @EnvironmentObject private var app: AppModel
    var isRoot: Bool = false

    var body: some View {
        LumaScreen(title: "Projects", showBack: !isRoot, scrollable: false) {
            ProjectList(store: app.store)
                .padding(.horizontal, -22)   // the List brings its own insets
        }
    }
}

private struct ProjectList: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: PersistenceStore

    var body: some View {
        List {
            Section {
                Button {
                    app.editor.startNewProject()
                    app.path.append(.editor)
                } label: {
                    Label("New Project", systemImage: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LumaTheme.accentBright)
                }
                .listRowBackground(LumaTheme.surface)
            }

            if store.projects.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34))
                            .foregroundStyle(LumaTheme.textMuted)
                        Text("No Projects Yet")
                            .font(.headline)
                            .foregroundStyle(LumaTheme.textSecondary)
                        Text("Edits auto-save here as you work.")
                            .font(.subheadline)
                            .foregroundStyle(LumaTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        Button {
                            app.editor.load(project: project)
                            app.path.append(.editor)
                        } label: {
                            HStack(spacing: 14) {
                                ProjectThumb(project: project, store: store,
                                             fallback: MockScene.allCases[index % MockScene.allCases.count])
                                    .frame(width: 92, height: 58)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text({
                                        var parts = ["\(project.updatedAt.formatted(date: .abbreviated, time: .omitted))",
                                                     timeString(project.duration),
                                                     "\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s")"]
                                        let audio = project.audioTracks?.count ?? 0
                                        if audio > 0 { parts.append("\(audio) audio") }
                                        return parts.joined(separator: " · ")
                                    }())
                                        .font(.footnote)
                                        .foregroundStyle(LumaTheme.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(LumaTheme.textMuted)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(LumaTheme.surface)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteProject(project.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("\(store.projects.count) Project\(store.projects.count == 1 ? "" : "s")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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
    @State private var canvasMode: CanvasBackgroundMode = .fill
    @State private var framePreset: FramePreset = .none

    var body: some View {
        LumaScreen(title: "Format", trailingText: "Apply", trailingAction: {
            app.editor.setFormat(format, zoom: zoom)
            app.editor.setCanvasMode(canvasMode)
            app.editor.setFramePreset(framePreset)
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

            // Canvas background: how the clip sits inside the frame (fill vs
            // fit with a background painted in the bars).
            Text("Canvas")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CanvasBackgroundMode.allCases, id: \.self) { mode in
                        Button { canvasMode = mode } label: {
                            VStack(spacing: 6) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 20, weight: .medium))
                                Text(mode.label).font(.system(size: 12))
                            }
                            .frame(width: 72, height: 62)
                            .foregroundStyle(canvasMode == mode ? .black : .white)
                            .background(canvasMode == mode ? AnyShapeStyle(LumaTheme.accentBright)
                                                           : AnyShapeStyle(LumaTheme.surface),
                                        in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Frame: a border composited over the finished picture — drawn
            // last, so nothing upstream grades or wipes across it.
            Text("Frame")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FramePreset.allCases, id: \.self) { preset in
                        Button { framePreset = preset } label: {
                            VStack(spacing: 6) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 20, weight: .medium))
                                Text(preset.label).font(.system(size: 12))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(width: 82, height: 62)
                            .foregroundStyle(framePreset == preset ? .black : .white)
                            .background(framePreset == preset ? AnyShapeStyle(LumaTheme.accentBright)
                                                             : AnyShapeStyle(LumaTheme.surface),
                                        in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
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
            canvasMode = app.editor.canvasMode
            framePreset = FramePreset(rawValue: app.editor.framePreset) ?? .none
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        if let thumb = app.editor.selectedClip?.thumbnail ?? app.editor.clips.first?.thumbnail {
            Image(decorative: thumb, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            HeroImage(photo: .coast)
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
        .sheet(isPresented: $showExportQuality) {
            exportQualitySheet
                .presentationDetents([.height(240)])
                .presentationBackground(LumaTheme.background)
        }
        .sheet(isPresented: $showAbout) {
            aboutSheet
                .presentationDetents([.medium])
                .presentationBackground(LumaTheme.background)
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
    @EnvironmentObject private var storeService: StoreService
    @State private var showPaywall = false
    @State private var showExportQuality = false
    @State private var showAbout = false
    /// Same store the export spec sheet reads on appear — changing it here
    /// really changes the default the exporter uses.
    @AppStorage("lumalook.exportSpec") private var storedSpec = ExportSpec().rawValue

    var body: some View {
        LumaScreen(title: "Settings", showBack: !isRoot, scrollable: false) {
            settingsList
                .padding(.horizontal, -22)   // the List brings its own insets
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LUMA_SEED_PAYWALL"] == "1" {
                showPaywall = true
            }
            #endif
        }
    }

    /// NATIVE inset-grouped List (Apple-native tranche 2).
    private var settingsList: some View {
        List {
            Section {
                subscriptionCard
                    .listRowBackground(LumaTheme.surface)
            }

            Section("Purchases") {
                settingsRow(icon: "creditcard", title: "Subscription",
                            value: storeService.isPro ? "Pro" : "Free") {
                    showPaywall = true
                }
                settingsRow(icon: "arrow.clockwise", title: "Restore Purchases") {
                    Task { await storeService.restorePurchases() }
                }
            }
            .listRowBackground(LumaTheme.surface)

            Section("Preferences") {
                settingsRow(icon: "4k.tv", title: "Export Quality",
                            value: ExportSpec.from(rawValue: storedSpec).resolution.rawValue) {
                    showExportQuality = true
                }
                settingsRow(icon: "globe", title: "App Language",
                            value: Locale.current.localizedString(
                                forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")
                                ?? "English") {
                    // Per-app language lives in iOS Settings — deep-link there.
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .listRowBackground(LumaTheme.surface)

            Section("About") {
                settingsRow(icon: "questionmark.circle", title: "Help & Support") {
                    let subject = "LumaLook Support".addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed) ?? "LumaLook%20Support"
                    if let url = URL(string: "mailto:emotiveimpact@gmail.com?subject=\(subject)") {
                        UIApplication.shared.open(url)
                    }
                }
                settingsRow(icon: "info.circle", title: "About LumaLook",
                            value: "v\(Self.appVersion)") {
                    showAbout = true
                }
            }
            .listRowBackground(LumaTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func settingsRow(icon: String, title: String, value: String? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LumaTheme.accentBright)
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.white)
                Spacer()
                if let value {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LumaTheme.textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Export quality

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Default export resolution — writes into the same stored ExportSpec the
    /// export sheets load, so the choice sticks everywhere (codec/fps untouched).
    private var exportQualitySheet: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export Quality")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 2)
            Text("Default resolution for every export. You can still change it per-export on the export sheet.")
                .font(.system(size: 13))
                .foregroundStyle(LumaTheme.textMuted)
                .padding(.bottom, 10)
            ForEach(ExportSpec.Resolution.allCases, id: \.rawValue) { res in
                Button {
                    var spec = ExportSpec.from(rawValue: storedSpec)
                    spec.resolution = res
                    storedSpec = spec.rawValue
                    showExportQuality = false
                } label: {
                    HStack {
                        Text(res.rawValue)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(res == .uhd4K ? "3840×2160" : "1920×1080")
                            .font(.system(size: 12))
                            .foregroundStyle(LumaTheme.textMuted)
                        Spacer()
                        if ExportSpec.from(rawValue: storedSpec).resolution == res {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(LumaTheme.accentBright)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: About

    private var aboutSheet: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LumaTheme.accent)
                .frame(width: 76, height: 76)
                .overlay(Image(systemName: "camera.filters")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white))
                .padding(.top, 30)
            Text("LumaLook")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("Version \(Self.appVersion) (\(Self.appBuild))")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LumaTheme.textSecondary)
            Text("Cinematic looks, live LUT grading and video editing.\nMade by Emotive Impact.")
                .font(.system(size: 14))
                .foregroundStyle(LumaTheme.textMuted)
                .multilineTextAlignment(.center)
            Button {
                let subject = "LumaLook Support".addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? "LumaLook%20Support"
                if let url = URL(string: "mailto:emotiveimpact@gmail.com?subject=\(subject)") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Contact — emotiveimpact@gmail.com", systemImage: "envelope")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 26)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var subscriptionCard: some View {
            // Profile / subscription card — live StoreKit 2 status (C5).
            HStack(spacing: 14) {
                Circle()
                    .fill(LumaTheme.surfaceStrong)
                    .frame(width: 58, height: 58)
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.85)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(storeService.isPro ? "LumaLook Pro" : "LumaLook Free")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(storeService.isPro ? "Unlimited Access" : "Upgrade for Every Look")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(storeService.isPro ? LumaTheme.teal : LumaTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)
                Spacer()
                Button {
                    showPaywall = true
                } label: {
                    Text(storeService.isPro ? "Manage" : "Get Pro")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(LumaTheme.accentDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
    }
}

private struct SettingsGroup: View {
    let rows: [(icon: String, title: String, value: String?, chevron: Bool)]
    var onTap: ((Int) -> Void)? = nil

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
                .contentShape(Rectangle())
                .onTapGesture { onTap?(index) }
                if index < rows.count - 1 {
                    Hairline().padding(.leading, 64)
                }
            }
        }
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}

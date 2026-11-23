import SwiftUI
import PhotosUI
import CoreImage

// MARK: - Onboarding, reworked (calm mock v2, 09-onboarding.jpg)
//
// Three steps, then the paywall once, then Home:
//   1 True to every skin  ·  2 Try a look  ·  3 Make it yours
// The paywall is the existing PaywallView, shown once as a sheet with a
// "Continue with Free" line under it, so it never becomes a hard gate.
//
// Debug: LUMA_SEED_ONBOARDING=1 shows onboarding (LumaLookApp), and
// LUMA_ONBOARDING_STEP=1|2|3 opens it on that step for screenshots.

/// First-launch onboarding. Presented full screen by `LumaLookApp`; it sets
/// `isPresented` to false when the person reaches Home.
struct OnboardingView: View {
    @EnvironmentObject private var storeService: StoreService
    @EnvironmentObject private var app: AppModel
    @Binding var isPresented: Bool

    @State private var step = 0
    @State private var showPaywall = false
    @State private var pickedIndex = 0
    @State private var restoring = false
    @State private var restoreMessage: String?

    init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    /// The five looks step 2 lets people try, in the mock's order.
    private static let looks: [OnbLook] = [
        OnbLook(code: "KD2", lookName: "KD2 · Golden Hour"),
        OnbLook(code: "LL1", lookName: "Neon Nights"),
        OnbLook(code: "AG60", lookName: "AG60 · London Rain"),
        OnbLook(code: "CN83", lookName: "CN83 · Teal & Orange"),
        OnbLook(code: "BW32", lookName: "BW32 · Documentary Grit"),
    ]

    private var currentLook: OnbLook {
        Self.looks[min(max(pickedIndex, 0), Self.looks.count - 1)]
    }

    var body: some View {
        ZStack {
            LumaTheme.ink.ignoresSafeArea()
            stepView
                .id(step)
                .transition(.opacity)
        }
        .overlay(alignment: .topTrailing) {
            if step < 2 {
                skipButton
            }
        }
        .animation(.easeOut(duration: 0.3), value: step)
        .sheet(isPresented: $showPaywall, onDismiss: { finish() }) {
            PaywallView()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    continueFreeButton
                }
        }
        .onChange(of: storeService.isPro) { _, pro in
            if pro { finish() }
        }
        .alert("Restore purchases", isPresented: restoreAlertShown) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(restoreMessage ?? "")
        }
        .onAppear {
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["LUMA_ONBOARDING_STEP"],
               let number = Int(raw) {
                step = min(max(number - 1, 0), 2)
            }
            #endif
        }
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case 0:
            OnbSkinStep(restoring: restoring,
                        onStart: { go(to: 1) },
                        onRestore: { restore() })
        case 1:
            OnbTryStep(looks: Self.looks, picked: $pickedIndex,
                       onKeep: { keepLook() })
        default:
            OnbStyleStep(look: currentLook,
                         onContinue: { openPaywall() })
        }
    }

    /// Quiet way out on the first two steps, as before: straight to Home.
    private var skipButton: some View {
        Button {
            finish()
        } label: {
            Text("Skip")
                .font(.luma(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .lumaGlassPill()
        }
        .buttonStyle(.lumaPress)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .accessibilityLabel("Skip onboarding")
    }

    /// Under the paywall: the free way on, which goes straight to Home.
    private var continueFreeButton: some View {
        Button {
            showPaywall = false
        } label: {
            Text("Continue with Free")
                .font(.luma(size: 15, weight: .medium))
                .foregroundStyle(LumaTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(Rectangle())
        }
        .background(LumaTheme.ink)
    }

    private var restoreAlertShown: Binding<Bool> {
        Binding(get: { restoreMessage != nil },
                set: { shown in if !shown { restoreMessage = nil } })
    }

    // MARK: Actions

    private func go(to newStep: Int) {
        withAnimation(.easeOut(duration: 0.3)) { step = newStep }
    }

    /// Step 2's main action: the tried look becomes the camera's look.
    private func keepLook() {
        let name = currentLook.lookName
        if let preset = MockData.looks.first(where: { $0.name == name }) {
            app.select(look: LibraryLook(builtIn: preset))
        }
        go(to: 2)
    }

    /// The paywall, once. Someone who already restored Pro goes to Home.
    private func openPaywall() {
        if storeService.isPro {
            finish()
        } else {
            showPaywall = true
        }
    }

    /// "I have an account": restore purchases; Pro goes straight to Home.
    private func restore() {
        guard !restoring else { return }
        restoring = true
        storeService.lastError = nil
        Task { @MainActor in
            await storeService.restorePurchases()
            restoring = false
            if storeService.isPro {
                finish()
            } else if let error = storeService.lastError {
                restoreMessage = error
                storeService.lastError = nil
            } else {
                restoreMessage = "No purchases were found for this Apple Account. You can carry on for free."
            }
        }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.25)) { isPresented = false }
    }
}

// MARK: - Shared pieces

/// One look step 2 can try: its stock code and its built-in name.
private struct OnbLook: Identifiable {
    let code: String
    let lookName: String
    var id: String { lookName }
    /// "Golden Hour" from "KD2 · Golden Hour".
    var title: String { LookSignature.title(in: lookName) }
    var colour: Color { LookSignature.colour(forLookNamed: lookName) }
}

/// The page dots: the current step a white bar, the others small grey dots.
private struct OnbDots: View {
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.3))
                    .frame(width: i == index ? 20 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of 3")
    }
}

/// The white capsule on step 1 ("Get started").
private struct OnbWhiteButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 16.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(LumaTheme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(hex: 0xF4F5F6), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
    }
}

/// The quiet line under a step's button ("I have an account").
private struct OnbQuietLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.luma(size: 15, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
    }
}

/// A step's detail line under its headline.
private struct OnbDetail: View {
    let text: String
    var size: CGFloat = 14

    var body: some View {
        Text(text)
            .font(.luma(size: size, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.62))
            .lineSpacing(size * 0.3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 10)
    }
}

/// Any image, filling the frame it is given and cropped to it.
private struct OnbFillImage: View {
    let image: Image

    var body: some View {
        GeometryReader { geo in
            image
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
    }
}

// MARK: - Step 1 · True to every skin

private struct OnbSkinStep: View {
    let restoring: Bool
    let onStart: () -> Void
    let onRestore: () -> Void

    private static let look = "KD2 · Golden Hour"

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                slices
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, -30)
                    .ignoresSafeArea(edges: .top)
                content
            }
            lookLabel
                .padding(.top, 4)
        }
    }

    /// One look on three people in three kinds of light.
    private var slices: some View {
        HStack(spacing: 3) {
            OnbSlice(photo: .campaign, label: "Studio flash", lookName: Self.look)
            OnbSlice(photo: .golden, label: "Daylight", lookName: Self.look)
            OnbSlice(photo: .neon, label: "Neon at night", lookName: Self.look)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("One look, KD2 Golden Hour, on three people: studio flash, daylight and neon at night")
    }

    private var lookLabel: some View {
        LookNameText("One look · KD2 Golden Hour",
                     colour: LookSignature.colour(forLookNamed: Self.look),
                     size: 12, alwaysDot: true)
            .lumaGlassPill()
            .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnbDots(index: 0)
            Text("GET THE LUMALOOK")
                .font(.luma(size: 11, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 16)
            LumaHeadline(light: "Film looks", heavy: "true to every skin.", size: 34)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            OnbDetail(text: "Every look is checked on Black and brown skin, in flash, daylight and neon.",
                      size: 15)
                .padding(.top, 14)
            OnbWhiteButton(title: "Get started", action: onStart)
                .padding(.horizontal, -4)
                .padding(.top, 26)
            Button(action: onRestore) {
                OnbQuietLabel(title: restoring ? "Checking your purchases" : "I have an account")
            }
            .disabled(restoring)
            .padding(.top, 6)
            .accessibilityHint("Restores purchases made with this Apple Account")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

/// One tall photo slice on step 1, graded, with its light written low down.
private struct OnbSlice: View {
    let photo: HeroPhoto
    let label: String
    let lookName: String

    private static let fade = LinearGradient(stops: [
        .init(color: LumaTheme.ink.opacity(0.45), location: 0),
        .init(color: LumaTheme.ink.opacity(0), location: 0.18),
        .init(color: LumaTheme.ink.opacity(0), location: 0.6),
        .init(color: LumaTheme.ink.opacity(0.9), location: 0.88),
        .init(color: LumaTheme.ink, location: 1),
    ], startPoint: .top, endPoint: .bottom)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GradedHeroImage(photo: photo, lookName: lookName)
            Self.fade
                .allowsHitTesting(false)
            Text(label)
                .font(.luma(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .shadow(color: Color.black.opacity(0.6), radius: 3, y: 1)
                .padding(.leading, 10)
                .padding(.bottom, 74)
        }
        .clipped()
    }
}

// MARK: - Step 2 · Try a look

/// A photo the person picked with "Use one of my photos".
private struct OnbPicked {
    let id = UUID()
    let ui: UIImage
    let ci: CIImage
}

private struct OnbTryStep: View {
    let looks: [OnbLook]
    @Binding var picked: Int
    let onKeep: () -> Void

    @State private var photo: OnbPicked?
    @State private var pickerItem: PhotosPickerItem?

    private var current: OnbLook {
        looks[min(max(picked, 0), looks.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
            content
        }
        .onChange(of: pickerItem) { _, item in
            load(item)
        }
    }

    private var stage: some View {
        OnbWipeStage(looks: looks, picked: picked, photo: photo)
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.black.opacity(0.5), Color.black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.5)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Text("Your shot")
                    .font(.luma(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lumaGlassPill()
                    .padding(16)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                LookNameText(current.lookName, colour: current.colour, size: 12, alwaysDot: true)
                    .lumaGlassPill()
                    .padding(16)
                    .allowsHitTesting(false)
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 34,
                                              bottomTrailingRadius: 34,
                                              style: .continuous))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnbDots(index: 1)
            LumaHeadline(light: "Try a", heavy: "look.", size: 30)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            OnbDetail(text: "Tap one. This is what the camera shows live.")
                .padding(.top, 8)
            strip
                .padding(.top, 18)
            LumaMainButton(title: "Keep \(current.title)", height: 54, cornerRadius: 27,
                           action: onKeep)
                .padding(.horizontal, -4)
                .padding(.top, 28)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                OnbQuietLabel(title: photo == nil ? "Use one of my photos" : "Use another photo")
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var strip: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(looks.indices, id: \.self) { index in
                OnbLookTile(look: looks[index], isOn: index == picked) {
                    withAnimation(.easeOut(duration: 0.2)) { picked = index }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            if let data = try? await item.loadTransferable(type: Data.self),
               let ui = UIImage(data: data),
               let ci = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                photo = OnbPicked(ui: ui, ci: ci)
            }
            pickerItem = nil
        }
    }
}

/// One look in step 2's strip: a graded portrait, its code in the look's
/// colour and its name in grey. The picked one wears the pale ring.
private struct OnbLookTile: View {
    let look: OnbLook
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                GradedHeroImage(photo: .campaign, lookName: look.lookName, radius: 12)
                    .aspectRatio(0.8, contentMode: .fit)
                    .pickedRing(isOn, cornerRadius: 12)
                LookNameText(look.code, colour: look.colour, size: 11, weight: .bold)
                    .padding(.top, 7)
                Text(look.title)
                    .font(.luma(size: 10.5, weight: .medium))
                    .foregroundStyle(isOn ? Color.white.opacity(0.7) : LumaTheme.textMuted)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
            .frame(maxWidth: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.lumaPress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
    }
}

/// The sample shot (or the person's own photo) with a straight wipe: the
/// original on the left of a white line, the picked look on the right. Drag
/// or tap anywhere to move the line. All five grades stay rendered and only
/// the picked one shows, so tapping through looks is instant.
private struct OnbWipeStage: View {
    let looks: [OnbLook]
    let picked: Int
    let photo: OnbPicked?

    @State private var split: CGFloat = 0.5

    private var pickedTitle: String {
        looks.indices.contains(picked) ? looks[picked].title : ""
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                originalLayer
                    .frame(width: size.width, height: size.height)
                gradedLayer
                    .frame(width: size.width, height: size.height)
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: max(0, size.width * split))
                            Color.black
                        }
                    }
                handle(in: size)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard size.width > 0 else { return }
                        split = min(max(drag.location.x / size.width, 0.05), 0.95)
                    }
            )
        }
        .animation(.easeOut(duration: 0.2), value: picked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your shot and \(pickedTitle), side by side")
        .accessibilityValue("\(Int(((1 - split) * 100).rounded())) percent graded")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = max(0.05, split - 0.1)
            case .decrement: split = min(0.95, split + 0.1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private var originalLayer: some View {
        if let photo {
            OnbFillImage(image: Image(uiImage: photo.ui))
        } else {
            HeroImage(photo: .party)
        }
    }

    private var gradedLayer: some View {
        ZStack {
            ForEach(looks.indices, id: \.self) { index in
                gradedImage(for: looks[index])
                    .opacity(index == picked ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func gradedImage(for look: OnbLook) -> some View {
        if let photo {
            OnbGradedPhoto(photo: photo, lookName: look.lookName)
        } else {
            GradedHeroImage(photo: .party, lookName: look.lookName)
        }
    }

    private func handle(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 2, height: size.height)
                .position(x: size.width * split, y: size.height / 2)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .position(x: size.width * split, y: size.height * 0.47)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// The person's own photo graded with one look, through the real pipeline,
/// off the main thread. Shows the ungraded photo until the grade is ready.
private struct OnbGradedPhoto: View {
    let photo: OnbPicked
    let lookName: String

    @State private var image: CGImage?

    var body: some View {
        content
            .task(id: "\(photo.id.uuidString)|\(lookName)") {
                await render()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            OnbFillImage(image: Image(decorative: image, scale: 1))
        } else {
            OnbFillImage(image: Image(uiImage: photo.ui))
        }
    }

    @MainActor
    private func render() async {
        image = nil
        let recipe = MockData.looks.first { $0.name == lookName }?.recipe ?? LookRecipe()
        let source = photo.ci
        image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let state = LookState()
            state.recipe = recipe
            var settings = LookSettings()
            settings.intensity = 100
            state.settings = settings
            return LookPipeline.shared.gradedStill(source, state: state, maxDimension: 1200)
        }.value
    }
}

// MARK: - Step 3 · Make it yours

private struct OnbStyleStep: View {
    let look: OnbLook
    let onContinue: () -> Void

    @AppStorage(LumaAppearance.sliderKey) private var sliderRaw = LumaSliderStyle.ruler.rawValue
    @AppStorage(LumaAppearance.namesKey) private var namesRaw = LumaNameStyle.colour.rawValue
    @AppStorage(LumaAppearance.buttonsKey) private var buttonsRaw = LumaMainButtonStyle.signal.rawValue
    @State private var strength: Double = 75

    private var slider: LumaSliderStyle { LumaSliderStyle(rawValue: sliderRaw) ?? .ruler }
    private var names: LumaNameStyle { LumaNameStyle(rawValue: namesRaw) ?? .colour }
    private var buttons: LumaMainButtonStyle { LumaMainButtonStyle(rawValue: buttonsRaw) ?? .signal }

    var body: some View {
        VStack(spacing: 0) {
            OnbPreviewCard(look: look, strength: $strength)
                .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 4)
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnbDots(index: 2)
            LumaHeadline(light: "Make it", heavy: "yours.", size: 30)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            OnbDetail(text: "The preview above changes as you pick. Change it any time in You › Appearance.")
                .padding(.top, 8)
            slidersRow
                .padding(.top, 18)
            namesRow
                .padding(.top, 20)
            buttonsRow
                .padding(.top, 20)
            LumaMainButton(title: "Continue", height: 54, cornerRadius: 27, action: onContinue)
                .padding(.horizontal, -4)
                .padding(.top, 32)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var slidersRow: some View {
        OnbChoiceRow(label: "Sliders") {
            OnbChip(title: "Ruler", isOn: slider == .ruler) {
                pick { sliderRaw = LumaSliderStyle.ruler.rawValue }
            }
            OnbChip(title: "Dial", isOn: slider == .dial) {
                pick { sliderRaw = LumaSliderStyle.dial.rawValue }
            }
        }
    }

    private var namesRow: some View {
        OnbChoiceRow(label: "Names") {
            OnbChip(title: "In colour", titleColour: look.colour, isOn: names == .colour) {
                pick { namesRaw = LumaNameStyle.colour.rawValue }
            }
            OnbChip(title: "Dot and code", isOn: names == .dot) {
                pick { namesRaw = LumaNameStyle.dot.rawValue }
            }
        }
    }

    private var buttonsRow: some View {
        OnbChoiceRow(label: "Buttons") {
            OnbChip(title: "Signal yellow", isOn: buttons == .signal) {
                pick { buttonsRaw = LumaMainButtonStyle.signal.rawValue }
            }
            OnbChip(title: "Quiet white", isOn: buttons == .white) {
                pick { buttonsRaw = LumaMainButtonStyle.white.rawValue }
            }
        }
    }

    private func pick(_ change: () -> Void) {
        withAnimation(.easeOut(duration: 0.2)) { change() }
    }
}

/// A small grey label over a row of chips.
private struct OnbChoiceRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.luma(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
            HStack(spacing: 8) {
                content
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        }
    }
}

/// A quiet glass chip; the picked one wears the pale ring.
private struct OnbChip: View {
    let title: String
    var titleColour: Color? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 14, weight: .semibold))
                .foregroundStyle(titleColour ?? (isOn ? Color.white : Color.white.opacity(0.92)))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(isOn ? LumaTheme.pickedRing.opacity(0.14) : Color.white.opacity(0.1),
                            in: Capsule())
                .overlay {
                    if isOn {
                        Capsule().strokeBorder(LumaTheme.pickedRing, lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Step 3's preview: a graded photo with the look's name, the strength
/// slider and an Apply pill, each drawn the way the current choices say,
/// so it changes as the person picks. The strength blends the grade over
/// the original live.
private struct OnbPreviewCard: View {
    let look: OnbLook
    @Binding var strength: Double

    var body: some View {
        ZStack(alignment: .top) {
            HeroImage(photo: .golden)
            GradedHeroImage(photo: .golden, lookName: look.lookName)
                .opacity(strength / 100)
            LinearGradient(colors: [LumaTheme.ink.opacity(0), LumaTheme.ink.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                LumaValueSlider(value: $strength)
                    .padding(.bottom, 6)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            LookNameText(look.lookName, colour: look.colour, size: 13)
            Spacer(minLength: 8)
            // A preview of the Buttons choice, not a real action.
            LumaMainPill(title: "Apply", height: 30) { }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.top, 12)
    }
}

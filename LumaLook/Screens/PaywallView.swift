import SwiftUI
import StoreKit

// MARK: - Paywall (C5)

/// Pro paywall. Pricing (StoreService.LockedPricing): $34.99 a year with a
/// 7-day free trial, $5.99 a month, or $79.99 once for Lifetime, which keeps
/// Pro and every pack, including packs released later. No WEEKLY tier,
/// matching the anti-subscription wave in the LUT niche. Presented as a sheet
/// from Settings, onboarding, premium looks, and pack purchases.
struct PaywallView: View {
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss

    private enum Plan { case yearly, monthly, lifetime }
    @State private var plan: Plan = .yearly

    /// True only when StoreKit says THIS user can still get the introductory
    /// offer on the yearly product. The CTA and badge used to promise a
    /// 7-day free trial purely from the local `Plan` enum, so a returning
    /// subscriber — or a product with no eligible offer — was shown a
    /// guarantee StoreKit would not honour.
    @State private var yearlyTrialEligible = false

    private var yearlyPrice: String {
        storeService.proYearly?.displayPrice ?? StoreService.LockedPricing.yearly
    }
    private var monthlyPrice: String {
        storeService.proMonthly?.displayPrice ?? StoreService.LockedPricing.monthly
    }
    private var lifetimePrice: String {
        storeService.proLifetime?.displayPrice ?? StoreService.LockedPricing.lifetime
    }
    /// The yearly price spread over twelve months, in the storefront's own
    /// currency once StoreKit has answered ("$2.92").
    private var yearlyPerMonth: String {
        if let product = storeService.proYearly {
            return (product.price / 12).formatted(product.priceFormatStyle)
        }
        return (StoreService.LockedPricing.yearlyAmount / 12)
            .formatted(.currency(code: "USD"))
    }

    /// The look the cover portrait wears.
    private static let coverLook = "CN93 · Luxury Campaign"

    var body: some View {
        ZStack(alignment: .top) {
            LumaTheme.ink.ignoresSafeArea()
            // A graded portrait behind the top of the sheet, fading into ink.
            GradedHeroImage(photo: .campaign, lookName: Self.coverLook)
                .frame(height: 430)
                .overlay {
                    LinearGradient(stops: [
                        .init(color: LumaTheme.ink.opacity(0.15), location: 0),
                        .init(color: LumaTheme.ink.opacity(0), location: 0.3),
                        .init(color: LumaTheme.ink.opacity(0.75), location: 0.72),
                        .init(color: LumaTheme.ink, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea(edges: .top)
                .accessibilityHidden(true)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    featureList
                    planPicker
                    purchaseButton
                    footerLinks
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                LookChip(name: Self.coverLook,
                         colour: LookSignature.colour(forLookNamed: Self.coverLook), size: 12)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(LumaTheme.edge, lineWidth: 1))
                }
                .buttonStyle(.lumaPress)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .onChange(of: storeService.isPro) { _, pro in
            if pro { dismiss() }
        }
        // Ask StoreKit whether THIS account can still use the intro offer.
        // Re-runs when products finish loading, since the subscription info
        // is nil until then.
        .task(id: storeService.proYearly?.id) {
            yearlyTrialEligible =
                await storeService.proYearly?.subscription?.isEligibleForIntroOffer ?? false
        }
    }

    /// Kicker and headline, sitting low on the cover portrait.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LumaLook Pro")
                .font(.luma(size: 14, weight: .semibold))
                .foregroundStyle(LumaTheme.signal)
            LumaHeadline(light: "Every look.", heavy: "Every pack.", size: 34)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 250)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaywallFeatureRow(text: "All \(PackCatalog.totalLookCount) looks and every new pack")
            PaywallFeatureRow(text: "Stack looks with per-slot strength")
            PaywallFeatureRow(text: "Batch export up to 10 clips")
            PaywallFeatureRow(text: "Take your grade anywhere as .cube")
        }
    }

    private var selectedProduct: Product? {
        switch plan {
        case .yearly:   return storeService.proYearly
        case .monthly:  return storeService.proMonthly
        case .lifetime: return storeService.proLifetime
        }
    }

    /// The yearly product's introductory offer, in whatever units StoreKit
    /// actually reports (a "7-day" claim hardcoded in the UI is a claim about
    /// App Store Connect configuration that the app cannot see).
    private var yearlyTrialLabel: String? {
        guard yearlyTrialEligible,
              let offer = storeService.proYearly?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        let unit: String
        switch offer.period.unit {
        case .day:   unit = n == 1 ? "Day" : "Day"
        case .week:  unit = n == 1 ? "Week" : "Week"
        case .month: unit = n == 1 ? "Month" : "Month"
        case .year:  unit = n == 1 ? "Year" : "Year"
        @unknown default: return nil
        }
        return "\(n)-\(unit) Free Trial"
    }

    private var callToAction: String {
        switch plan {
        case .yearly:
            // Only offer a trial when this user is actually eligible for one.
            return yearlyTrialLabel.map { "Start \($0)" } ?? "Subscribe Yearly"
        case .monthly:  return "Subscribe Monthly"
        case .lifetime: return "Get Lifetime Access"
        }
    }

    /// Apple requires the renewing price and cadence next to a subscription CTA.
    private var renewalNote: String? {
        switch plan {
        case .yearly:
            return yearlyTrialLabel == nil
                ? "\(yearlyPrice) per year. Cancel anytime."
                : "Then \(yearlyPrice) per year. Cancel anytime."
        case .monthly:  return "\(monthlyPrice) per month. Cancel anytime."
        case .lifetime: return "One payment. No subscription."
        }
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            PaywallPlanRow(
                title: "Yearly",
                price: "\(yearlyPrice) / year",
                detail: "\(yearlyPerMonth) a month, billed yearly",
                // The trial badge is a promise, so it shows only when StoreKit
                // says THIS account can take the offer (same rule as the CTA).
                badge: yearlyTrialLabel ?? "Best Value",
                selected: plan == .yearly
            ) { plan = .yearly }
            PaywallPlanRow(
                title: "Monthly",
                price: "\(monthlyPrice) / month",
                detail: nil,
                badge: nil,
                selected: plan == .monthly
            ) { plan = .monthly }
            PaywallPlanRow(
                title: "Lifetime",
                price: "\(lifetimePrice) once",
                detail: "Every pack, including future ones",
                badge: "Pay Once",
                selected: plan == .lifetime
            ) { plan = .lifetime }
        }
    }

    private var purchaseButton: some View {
        Button {
            Task {
                guard let product = selectedProduct else { return }
                // The result used to be assigned to state nothing read, so a
                // successful purchase left the paywall sitting there as if
                // nothing had happened.
                if await storeService.purchase(product) {
                    LumaHaptics.shared.exportSuccess()
                    dismiss()
                }
            }
        } label: {
            HStack {
                if storeService.purchaseInFlight {
                    ProgressView().tint(LumaTheme.onSignal)
                } else {
                    Text(callToAction)
                        .font(.luma(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(LumaTheme.onSignal)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(LumaTheme.signal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .disabled(storeService.purchaseInFlight || selectedProduct == nil)
        .overlay(alignment: .bottom) {
            if let note = renewalNote {
                Text(note)
                    .font(.luma(.caption))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .offset(y: 22)
            }
        }
        .padding(.bottom, 12)
    }

    private var footerLinks: some View {
        HStack(spacing: 18) {
            Button("Restore Purchases") {
                Task { await storeService.restorePurchases() }
            }
            // Reachable Terms + Privacy on the purchase surface are required
            // for auto-renewable subscriptions. Destinations live in LumaLegal
            // so this footer and Settings' ABOUT rows cannot drift apart.
            Button("Terms") { LumaLegal.open(LumaLegal.terms) }
            Button("Privacy") { LumaLegal.open(LumaLegal.privacy) }
        }
        .font(.luma(.footnote))
        .foregroundStyle(LumaTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

private struct PaywallFeatureRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LumaTheme.signal)
                .frame(width: 18)
            Text(text)
                .font(.luma(size: 15))
                .foregroundStyle(LumaTheme.textPrimary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PaywallPlanRow: View {
    let title: String
    let price: String
    /// A quieter third line: the yearly plan's monthly equivalent, or what
    /// Lifetime keeps.
    let detail: String?
    let badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.luma(size: 16, weight: .semibold))
                        .foregroundStyle(LumaTheme.textPrimary)
                    Text(price)
                        .font(.luma(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(LumaTheme.textSecondary)
                    if let detail {
                        Text(detail)
                            .font(.luma(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(LumaTheme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.luma(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? LumaTheme.onSignal : LumaTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(selected ? LumaTheme.signal : LumaTheme.raised, in: Capsule())
                }
                Circle()
                    .strokeBorder(selected ? LumaTheme.signal : LumaTheme.border, lineWidth: selected ? 6 : 1.5)
                    .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(selected ? LumaTheme.signal.opacity(0.06) : LumaTheme.panel,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? LumaTheme.signal.opacity(0.55) : LumaTheme.edge,
                              lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.lumaPress)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Locked look

/// Where a premium look was stopped, which decides how its free way out is
/// worded.
enum LockedLookContext {
    /// A file is about to leave the app: an export or a .cube.
    case export
    /// The camera, about to record or take a still.
    case camera
}

extension View {
    /// Presents `LockedLookSheet` while `lock` is non-nil. If a purchase
    /// lands, `onUnlocked` runs once the sheet has fully gone, so the caller
    /// can carry straight on with the export the user asked for instead of
    /// making them find the button again. `onUseFreeLook` is the free way
    /// out: the caller swaps in the closest free look and carries on, again
    /// once the sheet has gone.
    func lockedLookSheet(_ lock: Binding<LookLock?>,
                         context: LockedLookContext = .export,
                         onUnlocked: @escaping () -> Void,
                         onUseFreeLook: (() -> Void)? = nil) -> some View {
        modifier(LockedLookPresenter(lock: lock, context: context,
                                     onUnlocked: onUnlocked, onUseFreeLook: onUseFreeLook))
    }
}

private struct LockedLookPresenter: ViewModifier {
    @Binding var lock: LookLock?
    let context: LockedLookContext
    let onUnlocked: () -> Void
    let onUseFreeLook: (() -> Void)?
    @State private var didUnlock = false
    @State private var choseFreeLook = false

    func body(content: Content) -> some View {
        content.sheet(item: $lock, onDismiss: {
            if didUnlock {
                didUnlock = false
                choseFreeLook = false
                onUnlocked()
            } else if choseFreeLook {
                choseFreeLook = false
                onUseFreeLook?()
            }
        }) { shown in
            LockedLookSheet(lock: shown, context: context,
                            offersFreeLook: onUseFreeLook != nil,
                            onUnlocked: { didUnlock = true },
                            onUseFreeLook: { choseFreeLook = true })
                // Fitted to the three choices; it can still be pulled up if
                // a large text size needs the room.
                .presentationDetents([.height(context == .export ? 400 : 376), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.black)
        }
    }
}

/// Shown when a premium look is about to leave the app (an export, a
/// recording, a still, a .cube). The look has already graded the footage for
/// free. The sheet offers three ways on and no dead end: buy the one pack that
/// contains the look and keep it, go Pro for every look, or carry on with the
/// closest free look, keeping every other edit. It gets out of the way the
/// moment a purchase lands.
struct LockedLookSheet: View {
    let lock: LookLock
    let context: LockedLookContext
    let offersFreeLook: Bool
    let onUnlocked: () -> Void
    let onUseFreeLook: () -> Void

    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var restoring = false
    @State private var restoreFoundNothing = false
    @State private var errorMessage: String?

    private var preset: LookPreset? { MockData.looks.first { $0.name == lock.lookName } }
    /// The free look the third choice swaps in.
    private var freeLook: LookPreset? {
        preset.map(MockData.freeAlternative(to:)).flatMap { $0.isPremium ? nil : $0 }
    }
    private var isUnlocked: Bool {
        guard let preset else { return true }
        return storeService.lock(forBuiltIn: preset) == nil
    }
    private var packProduct: Product? {
        lock.pack.flatMap { storeService.packProducts[$0.id] }
    }
    private var swatch: [Color] { Self.swatch(for: preset) }

    private static func swatch(for look: LookPreset?) -> [Color] {
        let colours = look?.colours ?? []
        return colours.count >= 2 ? colours : [Color(white: 0.3), Color(white: 0.12)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 30)
                .padding(.horizontal, 22)

            Spacer(minLength: 18)

            VStack(spacing: 10) {
                if let pack = lock.pack {
                    primaryButton("Buy \(pack.name) · \(packPrice(pack))") { buyPack() }
                        .disabled(packProduct == nil || storeService.purchaseInFlight)
                        .opacity(packProduct == nil ? 0.45 : 1)
                    secondaryButton("Get Pro for every look") { showPaywall = true }
                } else {
                    primaryButton("Get Pro for every look") { showPaywall = true }
                }
                if offersFreeLook, let freeLook {
                    freeLookButton(freeLook)
                }
                if context == .export {
                    Text("Your edit is saved either way")
                        .font(.luma(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 2)
                }
                Button {
                    restore()
                } label: {
                    Group {
                        if restoring {
                            ProgressView().tint(.white)
                        } else {
                            Text(restoreFoundNothing ? "No purchases found to restore"
                                                     : "Restore Purchases")
                        }
                    }
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
                .disabled(restoring)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showPaywall, onDismiss: {
            // Bought Pro from the paywall: it closed itself, now close too.
            if isUnlocked { finish() }
        }) {
            PaywallView()
        }
        .onChange(of: isUnlocked) { _, unlocked in
            // A pack bought here (or a restore) closes the sheet directly;
            // while the paywall is up, its own dismissal finishes instead.
            if unlocked && !showPaywall { finish() }
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The look's swatch with a lock on it, beside what the look is and what
    /// it costs, so the price is the first thing read and never a surprise.
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: swatch, startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: 62, height: 62)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(context == .export ? "This edit uses" : "This shot uses")
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(lock.lookName)
                    .font(.luma(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.luma(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let pack = lock.pack {
            return "\(pack.name) · \(packPrice(pack)) · yours to keep"
        }
        return "Included with Pro"
    }

    private func packPrice(_ pack: LookPack) -> String {
        packProduct?.displayPrice ?? pack.price
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if storeService.purchaseInFlight {
                    ProgressView().tint(.black)
                } else {
                    Text(title)
                        .font(.luma(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white, in: Capsule())
        }
        .buttonStyle(.lumaPress)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.luma(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(LumaTheme.surfaceStrong, in: Capsule())
        }
        .buttonStyle(.lumaPress)
        .disabled(storeService.purchaseInFlight)
    }

    /// The free way out, on a quieter fill than the purchase buttons so it
    /// never competes with them, and naming the exact look it swaps in.
    private func freeLookButton(_ look: LookPreset) -> some View {
        Button {
            LumaHaptics.shared.tap()
            onUseFreeLook()
            dismiss()
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(LinearGradient(colors: Self.swatch(for: look),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text("\(context == .export ? "Export" : "Shoot") with \(look.name)")
                    .font(.luma(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(LumaTheme.chip, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .disabled(storeService.purchaseInFlight)
        .accessibilityHint("Swaps in a free look and keeps your other edits")
    }

    private func buyPack() {
        guard let product = packProduct else { return }
        storeService.lastError = nil
        Task {
            if await storeService.purchase(product) {
                LumaHaptics.shared.exportSuccess()
            } else if let error = storeService.lastError {
                // A cancel is silent; only a real failure says so.
                errorMessage = error
                storeService.lastError = nil
            }
        }
    }

    private func restore() {
        restoring = true
        restoreFoundNothing = false
        storeService.lastError = nil
        Task {
            await storeService.restorePurchases()
            restoring = false
            if let error = storeService.lastError {
                errorMessage = error
                storeService.lastError = nil
            } else if !isUnlocked {
                restoreFoundNothing = true
            }
        }
    }

    private func finish() {
        onUnlocked()
        dismiss()
    }
}

// MARK: - Onboarding

/// Three-page first-launch story ending in a soft paywall: the trial is one
/// tap away but "Continue with Free" is always visible — the anti-hard-gate
/// pattern every well-reviewed competitor converged on.
struct OnboardingView: View {
    @EnvironmentObject private var storeService: StoreService
    @Binding var isPresented: Bool
    @State private var page = 0
    @State private var showPaywall = false

    private struct Page {
        let photo: HeroPhoto
        let look: String
        let light: String
        let heavy: String
        let detail: String
    }

    private let pages: [Page] = [
        Page(photo: .golden, look: "KD2 · Golden Hour",
             light: "Shoot it", heavy: "graded.",
             detail: "Live looks in the viewfinder, baked into every clip and photo you take."),
        Page(photo: .neon, look: "Neon Nights",
             light: "Grade", heavy: "anything.",
             detail: "Looks and .cube LUTs on photos and video. Stack them, then compare before and after."),
        Page(photo: .gig, look: "BW32 · Documentary Grit",
             light: "Edit it", heavy: "together.",
             detail: "A multi-track timeline with music, captions, transitions and a look per clip, exported in up to 4K."),
    ]

    private var current: Page { pages[min(max(page, 0), pages.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottom) {
            LumaTheme.ink.ignoresSafeArea()

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    GradedHeroImage(photo: pages[index].photo, lookName: pages[index].look)
                        .ignoresSafeArea()
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            LinearGradient(stops: [
                .init(color: LumaTheme.ink.opacity(0), location: 0.35),
                .init(color: LumaTheme.ink.opacity(0.8), location: 0.62),
                .init(color: LumaTheme.ink, location: 0.86),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? LumaTheme.signal : Color.white.opacity(0.25))
                            .frame(width: index == page ? 20 : 6, height: 6)
                    }
                }
                .padding(.bottom, 18)
                .accessibilityHidden(true)

                LumaHeadline(light: current.light, heavy: current.heavy, size: 40)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(page)
                    .transition(.opacity)
                Text(current.detail)
                    .font(.luma(size: 16))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.bottom, 26)
                    .id("detail\(page)")
                    .transition(.opacity)

                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        showPaywall = true
                    }
                } label: {
                    let last = page == pages.count - 1
                    Text(last ? "Try LumaLook Pro" : (page == 0 ? "Get started" : "Continue"))
                        .font(.luma(size: 16, weight: .semibold))
                        .foregroundStyle(last ? LumaTheme.onSignal : LumaTheme.onLight)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(last ? LumaTheme.signal : LumaTheme.textPrimary,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.lumaPress)

                Button {
                    finish()
                } label: {
                    Text(page < pages.count - 1 ? "Skip" : "Continue with Free")
                        .font(.luma(size: 15, weight: .medium))
                        .foregroundStyle(LumaTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
            .animation(.easeOut(duration: 0.25), value: page)
        }
        .overlay(alignment: .topLeading) {
            LookChip(name: "Live · " + LookSignature.title(in: current.look),
                     colour: LookSignature.colour(forLookNamed: current.look), size: 12)
                .padding(.leading, 18)
                .padding(.top, 8)
                .animation(.easeOut(duration: 0.25), value: page)
        }
        .sheet(isPresented: $showPaywall, onDismiss: { finish() }) {
            PaywallView()
        }
        .onChange(of: storeService.isPro) { _, pro in
            if pro { finish() }
        }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.25)) { isPresented = false }
    }
}

import SwiftUI
import StoreKit

// MARK: - Paywall (C5)

/// Pro paywall. Pricing locked: $24.99/yr with a 7-day free trial or
/// $119.99 lifetime, $9.99/mo — no WEEKLY tier, matching the anti-subscription
/// wave in the LUT niche. Presented as a sheet from Settings, onboarding,
/// premium looks, and pack purchases.
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

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
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
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LumaTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.lumaPress)
            .padding(.trailing, 18)
            .padding(.top, 10)
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

    private var hero: some View {
        VStack(spacing: 14) {
            HeroImage(photo: .golden, radius: 20)
                .frame(height: 190)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LumaLook Pro")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Every look. Every pack. Every tool.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        LinearGradient(colors: [.black.opacity(0.65), .clear],
                                       startPoint: .bottom, endPoint: .top)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                }
        }
        .padding(.top, 12)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 13) {
            PaywallFeatureRow(icon: "camera.filters", title: "All Looks & Packs",
                              detail: "16 cinematic looks plus every future pack.")
            PaywallFeatureRow(icon: "square.stack.3d.up", title: "LUT Stacking",
                              detail: "Conversion and creative slots with per-slot strength.")
            PaywallFeatureRow(icon: "square.and.arrow.up.on.square", title: "Batch Export",
                              detail: "Grade once, export up to ten clips in one pass.")
            PaywallFeatureRow(icon: "cube.transparent", title: "Export Grades as .cube",
                              detail: "Take your grade to any NLE or camera app.")
        }
        .padding(18)
        .lumaCard()
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
        case .lifetime: return nil
        }
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            PaywallPlanRow(
                title: "Yearly",
                price: "\(yearlyPrice) / year",
                badge: "7-Day Free Trial",
                selected: plan == .yearly
            ) { plan = .yearly }
            PaywallPlanRow(
                title: "Monthly",
                price: "\(monthlyPrice) / month",
                badge: nil,
                selected: plan == .monthly
            ) { plan = .monthly }
            PaywallPlanRow(
                title: "Lifetime",
                price: "\(lifetimePrice) once",
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
                    ProgressView().tint(.white)
                } else {
                    Text(callToAction)
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.lumaPress)
        .disabled(storeService.purchaseInFlight || selectedProduct == nil)
        .overlay(alignment: .bottom) {
            if let note = renewalNote {
                Text(note)
                    .font(.caption)
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
        .font(.footnote)
        .foregroundStyle(LumaTheme.textSecondary)
        .padding(.top, 6)
    }
}

private struct PaywallFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LumaTheme.accentBright)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(LumaTheme.textSecondary)
            }
        }
    }
}

private struct PaywallPlanRow: View {
    let title: String
    let price: String
    let badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? LumaTheme.accentBright : LumaTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(price)
                        .font(.footnote)
                        .foregroundStyle(LumaTheme.textSecondary)
                }
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(selected ? LumaTheme.accent : LumaTheme.surface,
                                    in: Capsule())
                }
            }
            .padding(15)
            .background(selected ? LumaTheme.cardRaised : LumaTheme.card,
                        in: RoundedRectangle(cornerRadius: 15))
            // MEANINGFUL: the chosen plan. Unselected plans step down in value
            // instead of wearing a competing outline.
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(LumaTheme.accentBright, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.lumaPress)
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
        let icon: String
        let title: String
        let detail: String
    }

    private let pages: [Page] = [
        Page(photo: .golden, icon: "camera.aperture",
             title: "Shoot with Live Looks",
             detail: "Preview cinematic grades through the viewfinder and record them baked in."),
        Page(photo: .neon, icon: "cube.transparent",
             title: "Grade Anything",
             detail: "Apply looks and .cube LUTs to photos and video, stack conversion and creative slots, and compare before and after."),
        Page(photo: .night, icon: "film.stack",
             title: "Edit It Together",
             detail: "Multi-track timeline with music, overlays, transitions and per-clip looks — then export in up to 4K."),
    ]

    var body: some View {
        ZStack {
            LumaTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        onboardingPage(pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                VStack(spacing: 12) {
                    Button {
                        if page < pages.count - 1 {
                            withAnimation { page += 1 }
                        } else {
                            showPaywall = true
                        }
                    } label: {
                        Text(page < pages.count - 1 ? "Continue" : "Try LumaLook Pro")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.lumaPress)

                    Button {
                        finish()
                    } label: {
                        Text(page < pages.count - 1 ? "Skip" : "Continue with Free")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaTheme.textSecondary)
                            .frame(height: 34)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }
        }
        .sheet(isPresented: $showPaywall, onDismiss: { finish() }) {
            PaywallView()
        }
        .onChange(of: storeService.isPro) { _, pro in
            if pro { finish() }
        }
    }

    private func onboardingPage(_ page: Page) -> some View {
        VStack(spacing: 24) {
            HeroImage(photo: page.photo, radius: 24)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: page.icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(16)
                }
            VStack(spacing: 9) {
                Text(page.title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(page.detail)
                    .font(.body)
                    .foregroundStyle(LumaTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 40)
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.25)) { isPresented = false }
    }
}

import SwiftUI
import StoreKit

// MARK: - Paywall (C5)

/// Pro paywall. Pricing locked: $24.99/yr with a 7-day free trial or
/// $49.99 lifetime — no weekly/monthly tiers, matching the anti-subscription
/// wave in the LUT niche. Presented as a sheet from Settings, onboarding,
/// premium looks, and pack purchases.
struct PaywallView: View {
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss

    private enum Plan { case yearly, lifetime }
    @State private var plan: Plan = .yearly
    @State private var purchased = false

    private var yearlyPrice: String {
        storeService.proYearly?.displayPrice ?? StoreService.LockedPricing.yearly
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

    private var planPicker: some View {
        VStack(spacing: 10) {
            PaywallPlanRow(
                title: "Yearly",
                price: "\(yearlyPrice) / year",
                badge: "7-Day Free Trial",
                selected: plan == .yearly
            ) { plan = .yearly }
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
                let product = plan == .yearly ? storeService.proYearly
                                              : storeService.proLifetime
                guard let product else { return }
                purchased = await storeService.purchase(product)
            }
        } label: {
            HStack {
                if storeService.purchaseInFlight {
                    ProgressView().tint(.white)
                } else {
                    Text(plan == .yearly ? "Start 7-Day Free Trial" : "Get Lifetime Access")
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(LumaTheme.accent, in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.lumaPress)
        .disabled(storeService.purchaseInFlight
                  || (plan == .yearly ? storeService.proYearly : storeService.proLifetime) == nil)
        .overlay(alignment: .bottom) {
            if plan == .yearly {
                Text("Then \(yearlyPrice) per year. Cancel anytime.")
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
    let badge: String
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
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? .white : LumaTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(selected ? LumaTheme.accent : LumaTheme.surface,
                                in: Capsule())
            }
            .padding(15)
            .background(LumaTheme.surface.opacity(selected ? 1 : 0.55),
                        in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15)
                .stroke(selected ? LumaTheme.accentBright : .white.opacity(0.07),
                        lineWidth: selected ? 1.5 : 1))
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

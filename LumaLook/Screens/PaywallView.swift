import SwiftUI
import StoreKit

// MARK: - Paywall (C5)

/// Pro paywall. Pricing (StoreService.LockedPricing): $34.99 a year with a
/// 7-day free trial, $5.99 a month, or $79.99 once for Lifetime, which keeps
/// Pro and every pack, including packs released later. No WEEKLY tier,
/// matching the anti-subscription wave in the LUT niche. Presented as a sheet
/// from Settings, onboarding, premium looks, and pack purchases.
///
/// Calm mock v2 (08-paywall): a quiet kicker with the Pro spark, white ticks,
/// the pale picked ring on the chosen plan, and the trial or subscribe button
/// as the one main action (`LumaMainButton`, so it follows the Main buttons
/// choice). Restore, Terms and Privacy sit underneath in small grey type.
struct PaywallView: View {
    @EnvironmentObject private var storeService: StoreService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LumaAppearance.buttonsKey) private var buttonsRaw = LumaMainButtonStyle.signal.rawValue

    private enum Plan { case yearly, monthly, lifetime }
    @State private var plan: Plan = .yearly

    /// True only when StoreKit says THIS user can still get the introductory
    /// offer on the yearly product. The CTA and badge used to promise a
    /// 7-day free trial purely from the local `Plan` enum, so a returning
    /// subscriber, or a product with no eligible offer, was shown a
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
                .frame(height: 460)
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
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    featureList
                        .padding(.top, 26)
                        .padding(.horizontal, 4)
                    planPicker
                        .padding(.top, 20)
                    purchaseButton
                        .padding(.top, 14)
                    finePrint
                        .padding(.top, 12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .top) { topBar }
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

    /// The cover look's name on dark glass, and a quiet close button.
    private var topBar: some View {
        HStack {
            LookNameText(Self.coverLook,
                         colour: LookSignature.colour(forLookNamed: Self.coverLook),
                         size: 12, alwaysDot: true)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.black.opacity(0.3), in: Capsule())
                .accessibilityLabel("Look: \(Self.coverLook)")
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.black.opacity(0.25), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.lumaPress)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// Kicker and headline, sitting low on the cover portrait.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LumaTheme.signal)
                    .accessibilityHidden(true)
                Text("Lumalook Pro")
                    .font(.luma(size: 11, weight: .bold))
                    .tracking(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            LumaHeadline(light: "Every look.", heavy: "Every pack.", size: 34)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 250)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 9) {
            PaywallFeatureRow(text: "All \(PackCatalog.totalLookCount) looks and every new pack")
            PaywallFeatureRow(text: "Stack looks with a strength for each")
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
    /// actually reports ("7-day free trial"). A "7-day" claim hardcoded in
    /// the UI is a claim about App Store Connect configuration that the app
    /// cannot see.
    private var yearlyTrialLabel: String? {
        guard yearlyTrialEligible,
              let offer = storeService.proYearly?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let unit: String
        switch offer.period.unit {
        case .day:   unit = "day"
        case .week:  unit = "week"
        case .month: unit = "month"
        case .year:  unit = "year"
        @unknown default: return nil
        }
        return "\(offer.period.value)-\(unit) free trial"
    }

    private var callToAction: String {
        switch plan {
        case .yearly:
            // Only offer a trial when this user is actually eligible for one.
            return yearlyTrialLabel.map { "Start \($0)" } ?? "Subscribe yearly"
        case .monthly:  return "Subscribe monthly"
        case .lifetime: return "Get Lifetime"
        }
    }

    /// Apple requires the renewing price and cadence next to a subscription CTA.
    private var renewalNote: String {
        switch plan {
        case .yearly:
            let price = "\(yearlyPrice) a year (\(yearlyPerMonth) a month). Cancel any time."
            return yearlyTrialLabel == nil ? price : "Then \(price)"
        case .monthly:  return "\(monthlyPrice) a month. Cancel any time."
        case .lifetime: return "One payment. No subscription."
        }
    }

    private var planPicker: some View {
        VStack(spacing: 8) {
            PaywallPlanRow(
                title: "Yearly",
                detail: "\(yearlyPrice) a year · \(yearlyPerMonth) a month",
                // The trial badge is a promise, so it shows only when StoreKit
                // says THIS account can take the offer (same rule as the CTA).
                badge: yearlyTrialLabel ?? "Best value",
                selected: plan == .yearly
            ) { plan = .yearly }
            PaywallPlanRow(
                title: "Monthly",
                detail: "\(monthlyPrice) a month",
                badge: nil,
                selected: plan == .monthly
            ) { plan = .monthly }
            PaywallPlanRow(
                title: "Lifetime",
                detail: "\(lifetimePrice) once · every pack, now and later",
                badge: nil,
                selected: plan == .lifetime
            ) { plan = .lifetime }
        }
    }

    private var mainStyle: LumaMainButtonStyle {
        LumaMainButtonStyle(rawValue: buttonsRaw) ?? .signal
    }

    /// The one main action: start the trial, subscribe, or buy Lifetime.
    private var purchaseButton: some View {
        LumaMainButton(title: storeService.purchaseInFlight ? "One moment" : callToAction,
                       height: 54, cornerRadius: 27) {
            purchase()
        }
        .disabled(storeService.purchaseInFlight || selectedProduct == nil)
        .opacity(selectedProduct == nil ? 0.5 : 1)
        .overlay(alignment: .trailing) {
            if storeService.purchaseInFlight {
                ProgressView()
                    .tint(mainStyle.text)
                    .padding(.trailing, 20)
                    .allowsHitTesting(false)
            }
        }
    }

    private func purchase() {
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
    }

    /// The renewal terms, then Restore, Terms and Privacy, all quiet.
    private var finePrint: some View {
        VStack(spacing: 8) {
            Text(renewalNote)
                .font(.luma(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Restore") {
                    Task { await storeService.restorePurchases() }
                }
                .accessibilityLabel("Restore purchases")
                dot
                // Reachable Terms + Privacy on the purchase surface are
                // required for auto-renewable subscriptions. Destinations live
                // in LumaLegal so this footer and Settings' ABOUT rows cannot
                // drift apart.
                Button("Terms") { LumaLegal.open(LumaLegal.terms) }
                dot
                Button("Privacy") { LumaLegal.open(LumaLegal.privacy) }
            }
            .buttonStyle(.plain)
            .font(.luma(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private var dot: some View {
        Text("·")
            .font(.luma(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.3))
            .accessibilityHidden(true)
    }
}

private struct PaywallFeatureRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(.luma(size: 14.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 27)
    }
}

/// One plan on the paywall. The picked plan wears the pale picked ring
/// (`LumaTheme.pickedRing`) and a slightly brighter glass; the others are
/// quiet glass with an empty radio.
private struct PaywallPlanRow: View {
    let title: String
    /// The price line ("$5.99 a month").
    let detail: String
    let badge: String?
    let selected: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.luma(size: 15.5, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(LumaTheme.textPrimary)
                    Text(detail)
                        .font(.luma(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.luma(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? LumaTheme.pickedRing : LumaTheme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                radio
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: selected ? 66 : 58)
            .background(Color.white.opacity(selected ? 0.1 : 0.055), in: shape)
            .pickedRing(selected, cornerRadius: 18)
            .contentShape(shape)
        }
        .buttonStyle(.lumaPress)
        .animation(.easeOut(duration: 0.18), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var radio: some View {
        if selected {
            Circle()
                .fill(LumaTheme.pickedRing)
                .frame(width: 22, height: 22)
                .overlay(Circle().fill(LumaTheme.ink).frame(width: 8, height: 8))
                .accessibilityHidden(true)
        } else {
            Circle()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1.5)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        }
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
                // Fitted to the header, the message and the choices; it can
                // still be pulled up if a large text size needs the room.
                .presentationDetents([.height(context == .export ? 500 : 480), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(LumaTheme.panel)
        }
    }
}

/// Shown when a premium look is about to leave the app (an export, a
/// recording, a still, a .cube). The look has already graded the footage for
/// free: previewing is free, exporting needs the pack. The sheet offers the
/// pack in its own colour ("Buy After Dark"), Pro for every pack on quiet
/// glass underneath, and the agreed escape hatch, "Export without this look",
/// which swaps in the closest free look and keeps every other edit. It gets
/// out of the way the moment a purchase lands.
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

    private var preset: LookPreset? {
        guard lock.previewPackID == nil else { return nil }
        return MockData.looks.first { $0.name == lock.lookName }
    }
    /// The free look the escape hatch swaps in.
    private var freeLook: LookPreset? {
        preset.map(MockData.freeAlternative(to:)).flatMap { $0.isPremium ? nil : $0 }
    }
    /// The free look's name: a built-in for a built-in look, or the free
    /// look the camera picked for a pack it is trying on.
    private var freeLookName: String? {
        if lock.previewPackID != nil { return lock.freeLookName }
        return freeLook?.name
    }
    private var isUnlocked: Bool {
        if let packID = lock.previewPackID { return storeService.ownsPack(packID) }
        guard let preset else { return true }
        return storeService.lock(forBuiltIn: preset) == nil
    }
    private var packProduct: Product? {
        lock.pack.flatMap { storeService.packProducts[$0.id] }
    }
    /// The pack the look belongs to, for the header: the pack sold here, or a
    /// pack that only comes with Pro (After Dark) that the camera is trying on.
    private var shownPack: LookPack? {
        if let pack = lock.pack { return pack }
        guard let id = lock.previewPackID else { return nil }
        return PackCatalog.pack(id: id)
    }
    /// The look's own colour, for its name in the header.
    private var lookColour: Color {
        if let look = shownPack?.looks.first(where: { $0.name == lock.lookName }) {
            return look.signature
        }
        return LookSignature.colour(forLookNamed: lock.lookName)
    }
    private var swatch: [Color] {
        lock.previewPackID != nil ? Self.swatch(forName: lock.lookName) : Self.swatch(for: preset)
    }

    private static func swatch(for look: LookPreset?) -> [Color] {
        let colours = look?.colours ?? []
        return colours.count >= 2 ? colours : [Color(white: 0.3), Color(white: 0.12)]
    }

    /// A pack look has no hand-picked colours: its signature colour, deepened.
    private static func swatch(forName name: String) -> [Color] {
        let colour = LookSignature.colour(name: name)
        return [colour, colour.opacity(0.35)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 28)
            message
                .padding(.top, 18)
            Spacer(minLength: 18)
            actions
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Header and message

    /// The look's swatch with a lock on it, the pack it comes from, and the
    /// look's name in its own colour.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: swatch, startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: 48, height: 60)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker)
                    .font(.luma(size: 12, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                LookNameText(lock.lookName, colour: lookColour, size: 17)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// "After Dark · 5 looks", "After Dark · comes with Pro", or the Pro
    /// kicker for a built-in premium look.
    private var kicker: String {
        guard let pack = shownPack else { return "Lumalook Pro" }
        if lock.pack == nil { return "\(pack.name) · comes with Pro" }
        return "\(pack.name) · \(pack.looks.count) looks"
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 8) {
            LumaHeadline(light: headlineLight, heavy: headlineHeavy, size: 26)
                .fixedSize(horizontal: false, vertical: true)
            Text(bodyText)
                .font(.luma(size: 14))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headlineLight: String {
        context == .export ? "Previewing is free." : "Trying it on is free."
    }

    private var headlineHeavy: String {
        let verb = context == .export ? "Exporting" : "Shooting"
        return lock.pack != nil ? "\(verb) needs the pack." : "\(verb) needs Pro."
    }

    private var bodyText: String {
        let lead = context == .export ? "Your edit is saved. " : ""
        let tail = context == .export ? "and this export carries on." : "and keep shooting with this look."
        if let pack = lock.pack {
            return "\(lead)Buy \(pack.name) once and keep it, or get every pack with Pro, \(tail)"
        }
        if let pack = shownPack {
            return "\(lead)Go Pro for \(pack.name) and every other pack, \(tail)"
        }
        return "\(lead)Go Pro for this look and every other, \(tail)"
    }

    private func packPrice(_ pack: LookPack) -> String {
        packProduct?.displayPrice ?? pack.price
    }

    // MARK: Choices

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            if let pack = lock.pack {
                buyPackButton(pack)
                proButton
            } else {
                proMainButton
            }
            VStack(spacing: 0) {
                if offersFreeLook, let freeLookName {
                    withoutLookButton(freeName: freeLookName)
                }
                restoreButton
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// "Buy After Dark · $2.99" in the pack's own colour.
    private func buyPackButton(_ pack: LookPack) -> some View {
        LumaColourButton(title: "Buy \(pack.name) · \(packPrice(pack))",
                         colour: pack.colour, height: 54, fullWidth: true) {
            buyPack()
        }
        .disabled(packProduct == nil || storeService.purchaseInFlight)
        .opacity(packProduct == nil ? 0.45 : 1)
        .overlay(alignment: .trailing) {
            if storeService.purchaseInFlight {
                ProgressView()
                    .tint(.white)
                    .padding(.trailing, 20)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Pro on quiet glass, under the pack's own button.
    private var proButton: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LumaTheme.signal)
                    .accessibilityHidden(true)
                Text("Every pack with Pro")
                    .font(.luma(size: 16, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(LumaTheme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.lumaPress)
        .disabled(storeService.purchaseInFlight)
    }

    /// When the look is not sold on its own, Pro is the one purchase, so it
    /// is the main action.
    private var proMainButton: some View {
        LumaMainButton(title: shownPack.map { "Get \($0.name) with Pro" } ?? "Get Pro for every look",
                       height: 54, cornerRadius: 27) {
            showPaywall = true
        }
        .disabled(storeService.purchaseInFlight)
    }

    /// The agreed escape hatch: carry on with the closest free look, keeping
    /// every other edit. Small and grey so it never competes with buying.
    private func withoutLookButton(freeName: String) -> some View {
        Button {
            LumaHaptics.shared.tap()
            onUseFreeLook()
            dismiss()
        } label: {
            Text(context == .export ? "Export without this look" : "Shoot without this look")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(storeService.purchaseInFlight)
        .accessibilityHint("Swaps in \(freeName), a free look, and keeps your other edits")
    }

    private var restoreButton: some View {
        Button {
            restore()
        } label: {
            Group {
                if restoring {
                    ProgressView().tint(.white)
                } else {
                    Text(restoreFoundNothing ? "No purchases found to restore"
                                             : "Restore purchases")
                }
            }
            .font(.luma(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(restoring)
    }

    // MARK: Purchases

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
                    Text(last ? "Try Lumalook Pro" : (page == 0 ? "Get started" : "Continue"))
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

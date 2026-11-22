import Foundation
import StoreKit
import RevenueCat

/// RevenueCat setup. Purchases, restores and entitlements go through
/// RevenueCat once `apiKey` holds the project's public Apple key ("appl_…").
/// Public SDK keys are designed to ship inside the app, so it lives here.
///
/// While the key is empty the app talks to StoreKit directly, exactly as it
/// did before RevenueCat, so builds keep working before the dashboard exists.
/// Prices and trial eligibility always come straight from StoreKit.
enum RevenueCatConfig {
    static let apiKey = ""
    /// The entitlement every Pro product (yearly, monthly, lifetime) grants.
    static let proEntitlement = "pro"

    static var isEnabled: Bool {
        #if DEBUG
        // Local runs against LumaLook.storekit can use StoreKit directly,
        // which keeps those test purchases off the RevenueCat dashboard.
        if ProcessInfo.processInfo.environment["LUMA_STOREKIT_DIRECT"] == "1" { return false }
        #endif
        return !apiKey.isEmpty
    }
}

/// StoreKit 2 storefront (C5). Pricing approved 21 Nov 2026: Pro $34.99 a
/// year with a 7-day free trial, $5.99 a month, $79.99 Lifetime; paid packs
/// $2.99 or $3.99 and yours to keep. Deliberately no WEEKLY tier: reviewers
/// call weekly pricing a scam. The yearly plan costs about half of twelve
/// months of monthly, and Lifetime a little over two years, so each step up
/// reads as the better deal without a crossed-out price.
///
/// Every Pro product (yearly, monthly, Lifetime) opens every pack, including
/// packs released later. Every pack except After Dark is also sold one at a
/// time, so an owned pack stays owned if Pro lapses.
@MainActor
final class StoreService: ObservableObject {

    enum ProductID {
        static let proYearly = "com.emotiveimpact.lumalook.pro.yearly"
        static let proMonthly = "com.emotiveimpact.lumalook.pro.monthly"
        static let proLifetime = "com.emotiveimpact.lumalook.pro.lifetime"
        static let packPrefix = "com.emotiveimpact.lumalook.pack."
        static func pack(_ packID: String) -> String {
            packPrefix + packID
        }
    }

    /// Fallback display pricing so the paywall reads correctly even before
    /// products load (offline, review, fresh install). Real Product values
    /// replace these the moment StoreKit answers.
    enum LockedPricing {
        static let yearly = "$34.99"
        static let monthly = "$5.99"
        static let lifetime = "$79.99"
        static let trialDays = 7
        /// The yearly price as a number, for the "a month" equivalent the
        /// paywall shows before StoreKit has answered.
        static let yearlyAmount: Decimal = 34.99
    }

    @Published private(set) var proYearly: Product?
    @Published private(set) var proMonthly: Product?
    @Published private(set) var proLifetime: Product?
    @Published private(set) var packProducts: [String: Product] = [:]  // packID → product

    /// True once ANY Pro entitlement (yearly sub or lifetime) is verified.
    @Published private(set) var isPro = false
    /// Pack product IDs the user owns outright.
    @Published private(set) var ownedPackIDs: Set<String> = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var purchaseInFlight = false
    @Published var lastError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        #if DEBUG
        // UI verification seed: LUMA_SEED_PRO=1 renders the entitled state
        // (badges, Settings status) without a StoreKit transaction.
        if ProcessInfo.processInfo.environment["LUMA_SEED_PRO"] == "1" {
            isPro = true
        }
        #endif
        if RevenueCatConfig.isEnabled {
            if !Purchases.isConfigured {
                Purchases.logLevel = .warn
                Purchases.configure(withAPIKey: RevenueCatConfig.apiKey)
            }
            // RevenueCat finishes transactions itself; a second listener
            // finishing them too would fight it.
            updatesTask = Task { await listenForCustomerInfo() }
        } else {
            updatesTask = Task { await listenForTransactions() }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: Products

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        // Every paid pack is sold on its own, the film archives included;
        // After Dark comes with Pro and has no product of its own.
        let packIDs = PackCatalog.packs
            .filter { !$0.isFree && !$0.isProIncluded }
            .map { ProductID.pack($0.id) }
        let ids = [ProductID.proYearly, ProductID.proMonthly, ProductID.proLifetime] + packIDs
        do {
            let products = try await Product.products(for: ids)
            for product in products {
                switch product.id {
                case ProductID.proYearly: proYearly = product
                case ProductID.proMonthly: proMonthly = product
                case ProductID.proLifetime: proLifetime = product
                default:
                    let packID = product.id.replacingOccurrences(
                        of: "com.emotiveimpact.lumalook.pack.", with: "")
                    packProducts[packID] = product
                }
            }
        } catch {
            // Stay quiet: the paywall falls back to locked display pricing.
        }
    }

    // MARK: Entitlements

    func refreshEntitlements() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_SEED_PRO"] == "1" { return }
        #endif
        if RevenueCatConfig.isEnabled {
            // A failed fetch (offline) keeps what we last knew; RevenueCat
            // also serves its cached copy when it can't reach its servers.
            if let info = try? await Purchases.shared.customerInfo() { apply(info) }
            return
        }
        var pro = false
        var packs: Set<String> = []
        // Qualified to keep StoreKit's Transaction apart from RevenueCat's types.
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case ProductID.proYearly, ProductID.proMonthly, ProductID.proLifetime:
                pro = true
            default:
                if transaction.productID.hasPrefix("com.emotiveimpact.lumalook.pack.") {
                    packs.insert(transaction.productID.replacingOccurrences(
                        of: "com.emotiveimpact.lumalook.pack.", with: ""))
                }
            }
        }
        isPro = pro
        ownedPackIDs = packs
    }

    /// What this person owns, as RevenueCat sees it. The "pro" entitlement is
    /// the intended source, but the product IDs count too, so a dashboard
    /// that hasn't attached a product to the entitlement yet can never lock
    /// out someone who paid.
    private func apply(_ info: CustomerInfo) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUMA_SEED_PRO"] == "1" { return }
        #endif
        let owned = Set(info.nonSubscriptions.map(\.productIdentifier))
        let subscribed = !info.activeSubscriptions
            .isDisjoint(with: [ProductID.proYearly, ProductID.proMonthly])
        isPro = info.entitlements[RevenueCatConfig.proEntitlement]?.isActive == true
            || subscribed
            || owned.contains(ProductID.proLifetime)
        ownedPackIDs = Set(owned
            .filter { $0.hasPrefix(ProductID.packPrefix) }
            .map { String($0.dropFirst(ProductID.packPrefix.count)) })
    }

    /// A pack is usable if it's free, individually owned, or the user is
    /// Pro. Pro (yearly, monthly or Lifetime) opens every pack, including
    /// ones added after the purchase; a pack bought on its own is kept for
    /// good, whatever happens to Pro.
    func ownsPack(_ packID: String) -> Bool {
        guard let pack = PackCatalog.pack(id: packID) else { return false }
        return pack.isFree || isPro || ownedPackIDs.contains(packID)
    }

    // MARK: Premium looks

    /// Why a built-in look cannot leave the app for this user, or nil when it
    /// is free to export. `LookPreset.isPremium` is the single statement of
    /// "this look costs money"; the pack that sells its full version (if any)
    /// is the à la carte way in, and Pro opens everything.
    ///
    /// Previewing is never gated: a locked look still grades the footage live
    /// in the grade room, the editor and the camera. Only the moments a file
    /// leaves (export, a recording, a still, a .cube) ask for the purchase.
    func lock(forBuiltIn look: LookPreset) -> LookLock? {
        guard look.isPremium, !isPro else { return nil }
        let pack = LookLibraryStore.supersedingPack(forBuiltIn: look.name)
        if let pack, ownsPack(pack.id) { return nil }
        return LookLock(lookName: look.name, pack: pack)
    }

    /// The built-in look a stored grade resolves to (LUT grades are owned
    /// files, so only recipe grades can be locked).
    func lock(for grade: ClipGrade) -> LookLock? {
        guard grade.lutID == nil, grade.settings.intensity > 0,
              let preset = MockData.looks.first(where: { $0.name == grade.baseLookName })
        else { return nil }
        return lock(forBuiltIn: preset)
    }

    /// Library-tile form of the gate: true when picking this look would
    /// grade for free but ask for a purchase at export. Drives the small lock
    /// glyph, so the ask never arrives as a surprise.
    func isLocked(_ look: LibraryLook) -> Bool {
        switch look.source {
        case .builtIn(let preset):
            return lock(forBuiltIn: preset) != nil
        case .saved(let saved):
            return lock(for: ClipGrade(baseLookName: saved.baseLookName, lutID: saved.lutID,
                                       settings: saved.settings)) != nil
        case .lut:
            return false
        }
    }

    // MARK: Purchase

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard !purchaseInFlight else { return false }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        if RevenueCatConfig.isEnabled {
            do {
                let result = try await Purchases.shared.purchase(
                    product: StoreProduct(sk2Product: product))
                guard !result.userCancelled else { return false }
                apply(result.customerInfo)
                return true
            } catch ErrorCode.purchaseCancelledError {
                return false   // a cancel is silent
            } catch ErrorCode.paymentPendingError {
                // Ask to Buy: silent, as on the StoreKit path. The unlock
                // arrives through customerInfoStream once a parent approves.
                return false
            } catch {
                lastError = error.localizedDescription
                return false
            }
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastError = "Purchase could not be verified."
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restorePurchases() async {
        if RevenueCatConfig.isEnabled {
            do {
                apply(try await Purchases.shared.restorePurchases())
            } catch {
                lastError = error.localizedDescription
            }
            return
        }
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    // MARK: Transaction updates

    private func listenForTransactions() async {
        for await result in StoreKit.Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            await transaction.finish()
            await refreshEntitlements()
        }
    }

    /// RevenueCat pushes a fresh CustomerInfo on launch, after purchases and
    /// renewals, and when a refund or expiry lands.
    private func listenForCustomerInfo() async {
        for await info in Purchases.shared.customerInfoStream {
            apply(info)
        }
    }
}

/// A premium built-in look the user has not unlocked, and the pack (if any)
/// that sells it on its own. Drives `LockedLookSheet`.
struct LookLock: Identifiable, Equatable {
    let lookName: String
    let pack: LookPack?
    /// Set for a pack look the camera is trying on before its pack is owned
    /// (`AppModel.packPreview`): owning this pack is what unlocks it. After
    /// Dark comes only with Pro, so `pack` is nil there while this is set.
    var previewPackID: String? = nil
    /// The free look the "shoot with" choice swaps in for a pack preview.
    var freeLookName: String? = nil
    var id: String { lookName }

    static func == (a: LookLock, b: LookLock) -> Bool {
        a.lookName == b.lookName && a.pack?.id == b.pack?.id
            && a.previewPackID == b.previewPackID
    }
}

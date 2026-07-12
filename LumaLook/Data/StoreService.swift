import Foundation
import StoreKit

/// StoreKit 2 storefront (C5). Pricing locked 2026-07: Pro $24.99/yr with a
/// 7-day free trial, $49.99 lifetime, look packs $2.99–4.99. No weekly or
/// monthly tiers — the LUT niche is mid-backlash against weekly subs.
@MainActor
final class StoreService: ObservableObject {

    enum ProductID {
        static let proYearly = "com.emotiveimpact.lumalook.pro.yearly"
        static let proLifetime = "com.emotiveimpact.lumalook.pro.lifetime"
        static func pack(_ packID: String) -> String {
            "com.emotiveimpact.lumalook.pack.\(packID)"
        }
    }

    /// Fallback display pricing so the paywall reads correctly even before
    /// products load (offline, review, fresh install). Real Product values
    /// replace these the moment StoreKit answers.
    enum LockedPricing {
        static let yearly = "$24.99"
        static let lifetime = "$49.99"
        static let trialDays = 7
    }

    @Published private(set) var proYearly: Product?
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
        updatesTask = Task { await listenForTransactions() }
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
        let packIDs = PackCatalog.packs.filter { !$0.isFree }.map { ProductID.pack($0.id) }
        let ids = [ProductID.proYearly, ProductID.proLifetime] + packIDs
        do {
            let products = try await Product.products(for: ids)
            for product in products {
                switch product.id {
                case ProductID.proYearly: proYearly = product
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
        var pro = false
        var packs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            switch transaction.productID {
            case ProductID.proYearly, ProductID.proLifetime:
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

    /// A pack is usable if it's free, individually owned, or the user is
    /// Pro. Pro-included packs (the film archives) are NEVER à la carte —
    /// they exist to make the membership feel enormous.
    func ownsPack(_ packID: String) -> Bool {
        guard let pack = PackCatalog.pack(id: packID) else { return false }
        return pack.isFree || isPro || ownedPackIDs.contains(packID)
    }

    // MARK: Purchase

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard !purchaseInFlight else { return false }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
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
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    // MARK: Transaction updates

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result else { continue }
            await transaction.finish()
            await refreshEntitlements()
        }
    }
}

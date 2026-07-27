import CoreDomain
import Foundation
import StoreKit

/// StoreKit 2 purchase flow for Pro.
///
/// Entitlement is derived from `Transaction.currentEntitlements` rather than from
/// the purchase result alone, so a subscription that lapses or is refunded is
/// reflected on the next refresh — and a purchase made on another device is
/// picked up without an explicit restore.
@Observable
@MainActor
final class PaywallViewModel {

    enum ProductKind: String, CaseIterable {
        case monthly = "ioniq_pro_monthly_sub"
        case yearly = "ioniq_pro_yearly_sub"
        case lifetime = "ioniq_pro_lifetime"
    }

    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchaseInProgress: Product.ID?
    private(set) var errorMessage: String?
    private(set) var isPro = false

    private let entitlement: EntitlementRepository
    /// nonisolated so `deinit` can cancel it without hopping to the main actor.
    private nonisolated(unsafe) var updateListener: Task<Void, Never>?

    init(entitlement: EntitlementRepository) {
        self.entitlement = entitlement
        // Catches renewals, refunds, and purchases completed outside the app.
        updateListener = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
    }

    deinit { updateListener?.cancel() }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: ProductKind.allCases.map(\.rawValue))
            // Cheapest first, with lifetime last regardless of price.
            products = loaded.sorted { lhs, rhs in
                let lhsLifetime = lhs.id == ProductKind.lifetime.rawValue
                let rhsLifetime = rhs.id == ProductKind.lifetime.rawValue
                if lhsLifetime != rhsLifetime { return rhsLifetime }
                return lhs.price < rhs.price
            }
            errorMessage = products.isEmpty
                ? "No subscriptions are available right now."
                : nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshEntitlement()
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        purchaseInProgress = product.id
        errorMessage = nil
        defer { purchaseInProgress = nil }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    // Unverified means the signature failed — never grant on that.
                    errorMessage = "This purchase could not be verified."
                    return
                }
                await transaction.finish()
                await refreshEntitlement()
            case .userCancelled:
                break
            case .pending:
                errorMessage = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isPro { errorMessage = "No previous purchase found for this Apple Account." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Recomputes Pro from what StoreKit currently considers active.
    private func refreshEntitlement() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if ProductKind(rawValue: transaction.productID) != nil, transaction.revocationDate == nil {
                entitled = true
            }
        }
        isPro = entitled
        await entitlement.setPro(entitled, token: nil)
    }

    // MARK: - Presentation

    func title(for product: Product) -> String {
        switch ProductKind(rawValue: product.id) {
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .lifetime: return "Lifetime"
        case nil: return product.displayName
        }
    }

    func subtitle(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else {
            return "One-time purchase"
        }
        return "\(product.displayPrice) / \(period.unit.localizedDescription)"
    }

    /// Yearly savings versus twelve months of the monthly plan, when both exist.
    var yearlySavingsPercent: Int? {
        guard
            let monthly = products.first(where: { $0.id == ProductKind.monthly.rawValue }),
            let yearly = products.first(where: { $0.id == ProductKind.yearly.rawValue })
        else { return nil }
        let twelveMonths = monthly.price * 12
        guard twelveMonths > 0, yearly.price < twelveMonths else { return nil }
        let saved = (twelveMonths - yearly.price) / twelveMonths * 100
        return Int(truncating: saved as NSDecimalNumber)
    }
}

private extension Product.SubscriptionPeriod.Unit {
    var localizedDescription: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return "period"
        }
    }
}

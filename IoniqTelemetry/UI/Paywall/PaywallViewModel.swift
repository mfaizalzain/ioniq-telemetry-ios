import CoreDomain
import Foundation
import StoreKit

/// StoreKit 2 purchase flow for Pro.
///
/// One non-consumable, matching the Android build's single `ioniq_telemetry_pro`
/// product — buy once, keep it. Entitlement is derived from
/// `Transaction.currentEntitlements` rather than from the purchase result alone,
/// so a refund is reflected on the next refresh, and a purchase made on another
/// device is picked up without an explicit restore.
@Observable
@MainActor
final class PaywallViewModel {

    /// The App Store Connect product ID. Same string as the Play Console one.
    static let productID = "ioniq_telemetry_pro"

    private(set) var product: Product?
    private(set) var isLoading = false
    private(set) var purchaseInProgress: Product.ID?
    private(set) var errorMessage: String?
    private(set) var isPro = false

    private let entitlement: EntitlementRepository
    /// nonisolated so `deinit` can cancel it without hopping to the main actor.
    private nonisolated var updateListener: Task<Void, Never>?

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
            product = try await Product.products(for: [Self.productID]).first
            errorMessage = product == nil
                ? "Pro is not available for purchase right now."
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
            if transaction.productID == Self.productID, transaction.revocationDate == nil {
                entitled = true
            }
        }
        isPro = entitled
        await entitlement.setPro(entitled, token: nil)
    }
}

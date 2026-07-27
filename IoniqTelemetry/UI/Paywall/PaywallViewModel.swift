import CoreDomain
import Foundation
@preconcurrency import StoreKit

/// Supplies the Paywall screen with product info and purchase state.
@Observable
@MainActor
final class PaywallViewModel {

    static let productID = "ioniq_telemetry_pro"

    private(set) var product: Product?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
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

    func purchase() async {
        guard let product else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await refreshEntitlement()
            case .userCancelled:
                errorMessage = nil
            case .pending:
                errorMessage = "Waiting for approval…"
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        // Transaction.updates (listened to in init) catches everything.
        // Just refresh from the local receipt.
        await refreshEntitlement()
    }

    // MARK: - Helpers

    private func refreshEntitlement() async {
        let isPro = await entitlement.isPurchased(productID: Self.productID)
        self.isPro = isPro
    }
}

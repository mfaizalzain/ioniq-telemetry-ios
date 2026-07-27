import Combine
import CoreData
import CoreDomain
import Foundation
import StoreKit

/// StoreKit 2 purchase flow for Pro.
///
/// One non-consumable, matching the Android build's single `ioniq_telemetry_pro`
/// product — buy once, keep it. This screen owns the purchase flow only; the rule
/// for what counts as entitled lives in `EntitlementRepositoryImpl`, which the app
/// also re-runs at every launch. Deriving it in both places meant a refund was
/// honoured only if you happened to open the paywall.
@Observable
@MainActor
final class PaywallViewModel {

    /// The App Store Connect product ID. Same string as the Play Console one.
    static let productID = EntitlementRepositoryImpl.productID

    private(set) var product: Product?
    private(set) var isLoading = false
    private(set) var purchaseInProgress: Product.ID?
    private(set) var errorMessage: String?
    private(set) var isPro = false

    private let entitlement: EntitlementRepository
    private var cancellables = Set<AnyCancellable>()
    /// nonisolated so `deinit` can cancel it without hopping to the main actor.
    private nonisolated(unsafe) var updateListener: Task<Void, Never>?

    init(entitlement: EntitlementRepository) {
        self.entitlement = entitlement

        entitlement.isPro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPro = $0 }
            .store(in: &cancellables)

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
            let entitled = await refreshEntitlement()
            if !entitled { errorMessage = "No previous purchase found for this Apple Account." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Recomputes Pro from what StoreKit currently considers active. `isPro` here
    /// follows from the repository's publisher rather than being assigned twice.
    @discardableResult
    private func refreshEntitlement() async -> Bool {
        await entitlement.refreshEntitlements()
    }
}

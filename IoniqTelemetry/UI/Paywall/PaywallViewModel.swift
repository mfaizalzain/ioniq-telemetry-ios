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
    /// Set while a purchase awaits approval (bank transfer / slow payment). The
    /// `Transaction.updates` listener finishes it; this is the visible "not done
    /// yet, don't tap again" signal.
    private(set) var pendingApproval = false
    private(set) var errorMessage: String?
    private(set) var isPro = false

    private let entitlement: EntitlementRepository
    private var cancellables = Set<AnyCancellable>()

    init(entitlement: EntitlementRepository) {
        self.entitlement = entitlement

        entitlement.isPro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPro = $0 }
            .store(in: &cancellables)

    }

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
            log("load", error)
            errorMessage = error.localizedDescription
        }
        await refreshEntitlement()
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async {
        guard purchaseInProgress == nil else { return }
        purchaseInProgress = product.id
        pendingApproval = false
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
                // Not an error: the payment needs approval and will resolve through
                // Transaction.updates. Surface it as a waiting state, not a warning.
                pendingApproval = true
            @unknown default:
                break
            }
        } catch {
            log("purchase", error)
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        // A restore during an in-flight purchase would race StoreKit's transaction
        // handling — AppStore.sync() while product.purchase() is awaiting the App
        // Store sheet. Mutual exclusion, not just a disabled button.
        guard purchaseInProgress == nil else { return }
        isLoading = true
        pendingApproval = false
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            let entitled = await refreshEntitlement()
            if !entitled { errorMessage = "No previous purchase found for this Apple Account." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Diagnostics

    /// Names the concrete StoreKit case behind a failure.
    ///
    /// `localizedDescription` collapses every one of these into roughly "cannot
    /// connect to iTunes Store", which cannot distinguish a product the store has
    /// never published from a device that is offline. The cases worth recognising:
    /// `productUnavailable` means the store knows the id but will not sell it —
    /// typically an in-app purchase that has not been through review — while
    /// `notAvailableInStorefront` points at the Apple Account's region instead.
    private func log(_ stage: String, _ error: Error) {
        var detail = "\(type(of: error)): \(error)"

        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .productUnavailable:
                detail = "productUnavailable — the store will not sell this product yet"
            case .purchaseNotAllowed:
                detail = "purchaseNotAllowed — restrictions, or no Apple Account signed in"
            case .ineligibleForOffer:
                detail = "ineligibleForOffer"
            case .invalidQuantity:
                detail = "invalidQuantity"
            default:
                detail = "Product.PurchaseError: \(purchaseError)"
            }
        } else if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .notAvailableInStorefront:
                detail = "notAvailableInStorefront — not sold in this account's region"
            case .networkError(let underlying):
                detail = "networkError: \(underlying)"
            case .systemError(let underlying):
                detail = "systemError: \(underlying)"
            case .notEntitled:
                detail = "notEntitled"
            case .unsupported:
                detail = "unsupported"
            case .userCancelled:
                detail = "userCancelled"
            default:
                detail = "StoreKitError: \(storeKitError)"
            }
        }

        print("[Paywall] \(stage) failed for \(Self.productID) — \(detail)")
    }

    /// Recomputes Pro from what StoreKit currently considers active. `isPro` here
    /// follows from the repository's publisher rather than being assigned twice.
    @discardableResult
    private func refreshEntitlement() async -> Bool {
        let entitled = await entitlement.refreshEntitlements()
        if entitled { pendingApproval = false }
        return entitled
    }
}

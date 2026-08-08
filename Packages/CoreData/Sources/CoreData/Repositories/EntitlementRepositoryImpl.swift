import Combine
import CoreDomain
import Foundation
import StoreKit

/// Pro entitlement, derived from StoreKit and cached in UserDefaults.
///
/// The cache is what the UI reads at launch so Pro surfaces don't flicker off
/// while StoreKit is consulted — it is never the authority. `refreshEntitlements`
/// re-derives from `Transaction.currentEntitlements` on every start, which is what
/// picks up a refund, and a purchase made on another device, without the user
/// having to open the paywall and without trusting a flag that anything with
/// filesystem access could flip.
public final class EntitlementRepositoryImpl: EntitlementRepository, @unchecked Sendable {

    /// The App Store Connect product ID. Same string as the Play Console one.
    public static let productID = "ioniq_telemetry_pro"

    private let defaults = UserDefaults.standard
    private let isProKey = "entitlement_isPro"
    private let _isPro: CurrentValueSubject<Bool, Never>
    private var updateListener: Task<Void, Never>?

    public var isPro: AnyPublisher<Bool, Never> { _isPro.eraseToAnyPublisher() }

    public init() {
        _isPro = CurrentValueSubject(defaults.bool(forKey: isProKey))
        // Keep entitlement changes flowing even when the user never opens the
        // paywall. Purchases, refunds, and approvals can arrive after launch.
        updateListener = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result else { continue }
                if transaction.productID == Self.productID {
                    if transaction.revocationDate == nil {
                        await self.setPro(true, token: String(transaction.id))
                    } else {
                        _ = await self.refreshEntitlements()
                    }
                }
                await transaction.finish()
            }
        }
    }

    deinit { updateListener?.cancel() }

    public func setPro(_ isPro: Bool, token: String?) async {
        defaults.set(isPro, forKey: isProKey)
        if let token {
            defaults.set(token, forKey: "entitlement_token")
        }
        _isPro.value = isPro
    }

    /// Recomputes Pro from what StoreKit currently considers active.
    ///
    /// `currentEntitlements` is served from the on-device transaction store, so this
    /// is correct offline; unverified transactions are skipped rather than trusted.
    /// If StoreKit has not populated the local transaction store yet, retain a known
    /// Pro cache just like Android does after an inconclusive Play query. A temporary
    /// StoreKit gap during an app update must not turn a paid user into a free user.
    @discardableResult
    public func refreshEntitlements() async -> Bool {
        var entitled = false
        var sawVerifiedTransaction = false
        let now = Date()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            sawVerifiedTransaction = true
            let active = transaction.revocationDate == nil &&
                (transaction.expirationDate == nil || transaction.expirationDate! > now)
            if transaction.productID == Self.productID, active {
                entitled = true
            }
        }

        if !entitled, !sawVerifiedTransaction {
            // `latest` can still expose a revoked/expired transaction even when
            // currentEntitlements has removed it, allowing refunds to revoke a
            // cached grant while a genuinely empty StoreKit store remains safe.
            if let result = await Transaction.latest(for: Self.productID),
               case .verified(let transaction) = result {
                let active = transaction.revocationDate == nil &&
                    (transaction.expirationDate == nil || transaction.expirationDate! > now)
                entitled = active
            } else if defaults.bool(forKey: isProKey) {
                return true
            }
        }

        await setPro(entitled, token: nil)
        return entitled
    }
}

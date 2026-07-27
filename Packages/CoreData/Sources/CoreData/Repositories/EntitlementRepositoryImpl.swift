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

    public var isPro: AnyPublisher<Bool, Never> { _isPro.eraseToAnyPublisher() }

    public init() {
        _isPro = CurrentValueSubject(defaults.bool(forKey: isProKey))
    }

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
    @discardableResult
    public func refreshEntitlements() async -> Bool {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.productID, transaction.revocationDate == nil {
                entitled = true
            }
        }
        await setPro(entitled, token: nil)
        return entitled
    }
}

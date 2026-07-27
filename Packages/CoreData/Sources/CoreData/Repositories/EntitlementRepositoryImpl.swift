import Combine
import CoreDomain
import Foundation

/// UserDefaults-backed implementation of EntitlementRepository.
public final class EntitlementRepositoryImpl: EntitlementRepository, @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let isProKey = "entitlement_isPro"
    private let _isPro = CurrentValueSubject<Bool, Never>(false)

    public var isPro: AnyPublisher<Bool, Never> { _isPro.eraseToAnyPublisher() }

    public init() {
        _isPro.value = defaults.bool(forKey: isProKey)
    }

    public func setPro(_ isPro: Bool, token: String?) async {
        defaults.set(isPro, forKey: isProKey)
        if let token {
            defaults.set(token, forKey: "entitlement_token")
        }
        _isPro.value = isPro
    }

    public func refreshEntitlements() async {
        // On iOS, entitlements are managed via StoreKit / RevenueCat.
        // This is a lightweight UserDefaults-backed implementation;
        // integrate with StoreKit in the app layer.
        _isPro.value = defaults.bool(forKey: isProKey)
    }
}

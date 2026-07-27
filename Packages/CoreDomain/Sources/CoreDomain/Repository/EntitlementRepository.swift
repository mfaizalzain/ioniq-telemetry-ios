import Combine

public protocol EntitlementRepository: Sendable {
    /// Publisher emitting the current Pro entitlement status.
    var isPro: AnyPublisher<Bool, Never> { get }

    /// Set the Pro entitlement status.
    func setPro(_ isPro: Bool, token: String?) async

    /// Query purchases on every app start; never revoke on network error.
    func refreshEntitlements() async
}

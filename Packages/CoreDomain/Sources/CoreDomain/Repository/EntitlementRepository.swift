import Combine

public protocol EntitlementRepository: Sendable {
    /// Publisher emitting the current Pro entitlement status.
    var isPro: AnyPublisher<Bool, Never> { get }

    /// Set the Pro entitlement status.
    func setPro(_ isPro: Bool, token: String?) async

    /// Query purchases on every app start; never revoke on network error.
    ///
    /// Returns the freshly computed entitlement so a caller acting on the result
    /// immediately — the restore button reporting "no purchase found", say — reads
    /// it directly instead of racing the `isPro` publisher.
    @discardableResult
    func refreshEntitlements() async -> Bool
}

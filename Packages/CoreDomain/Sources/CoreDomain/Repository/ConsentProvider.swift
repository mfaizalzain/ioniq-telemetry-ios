import Combine

public enum ConsentStatus: String, Sendable {
    case unknown = "UNKNOWN"
    case required = "REQUIRED"
    case obtained = "OBTAINED"
    case notRequired = "NOT_REQUIRED"
}

/// Abstraction over UMP so AdGate logic is testable without Play services.
public protocol ConsentProvider: Sendable {
    /// Publisher emitting the current consent status.
    var hasConsent: AnyPublisher<Bool, Never> { get }

    /// Publisher emitting the detailed consent status.
    var status: AnyPublisher<ConsentStatus, Never> { get }

    /// Request consent from the user.
    func requestConsent() async
}

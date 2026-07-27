import Foundation

/// Turns a network error into something worth showing a driver.
///
/// Ported from Android `NetworkError.kt`, including the copy — the two builds
/// should give the same advice for the same failure.
///
/// The failures that matter here are mostly not bugs: they are a tunnel, a
/// mountain road, or a quota, and each has a different next action. Leaking
/// `URLError.cannotFindHost`'s "A server with the specified hostname could not be
/// found." into the UI names the wrong problem and suggests nothing.
public extension Error {

    /// - Parameter subject: what was being fetched ("Charger search", "Routing").
    ///   Leads the sentence.
    func userMessage(subject: String) -> String {
        if let urlError = self as? URLError {
            return Self.urlMessage(subject: subject, urlError)
        }
        // A body that doesn't match the model is a provider or version problem, not
        // something "the data couldn't be read in the correct format" helps with.
        if self is DecodingError {
            return "\(subject) returned a response this version of the app couldn't read. "
                + "This usually clears up on its own; if it doesn't, check for an app update."
        }
        // Repositories already produce driver-facing copy for their own failures.
        if let localized = self as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(subject) failed: \(localizedDescription)"
    }

    /// True for failures that are purely about not reaching the network.
    var isOfflineFailure: Bool {
        guard let urlError = self as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
             .cannotConnectToHost, .networkConnectionLost, .timedOut,
             .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func urlMessage(subject: String, _ error: URLError) -> String {
        switch error.code {
        // No route to the network at all: airplane mode, no bars, captive portal.
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
             .cannotConnectToHost, .internationalRoamingOff, .dataNotAllowed:
            return "\(subject) needs an internet connection. You appear to be offline — "
                + "this will work again once you have signal."

        // Reached the network but it stalled. On spotty mobile data this is the
        // common one, and unlike being offline it is worth trying again right away.
        case .timedOut, .networkConnectionLost:
            return "\(subject) timed out — the connection is too weak to finish the request. "
                + "Try again when you have a stronger signal."

        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "\(subject) could not establish a secure connection. This often means a "
                + "public Wi-Fi network is intercepting traffic — try mobile data."

        default:
            return "\(subject) failed — the connection dropped. Try again when you have a "
                + "stronger signal."
        }
    }
}

/// Maps an HTTP status onto the same advice Android gives.
public enum HTTPStatusMessage {
    public static func describe(subject: String, status: Int) -> String {
        switch status {
        case 401, 403:
            return "\(subject) was rejected — the API key is invalid or lacks permission for "
                + "this service. Check it under Settings → Routing."
        case 429:
            return "\(subject) hit the API rate limit for your key. Wait a minute and try "
                + "again, or check your provider's quota."
        case 500..<600:
            return "\(subject) failed — the provider's servers are having trouble. This is on "
                + "their side; try again shortly."
        default:
            return "\(subject) failed (HTTP \(status))."
        }
    }
}

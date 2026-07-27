import Foundation

/// The shared HTTP client for every remote repository.
///
/// Ported from the Android `okHttp` provider in `DataModule.kt` plus
/// `RetryInterceptor.kt`, so both platforms hit the user's own keys with the same
/// timeout and retry behaviour — a divergence here shows up as different billing
/// on their Cloud account, not just different code.
///
/// `URLSession.shared` was previously used everywhere, which meant the default
/// 60 s request timeout: on flaky cellular mid-drive the Plan screen could spin for
/// a full minute before reporting anything.
public enum NetworkSession {

    /// Idle timeout between packets — Android's `readTimeout`/`writeTimeout`.
    private static let requestTimeout: TimeInterval = 20
    /// Ceiling for the whole call including retries — Android's `callTimeout`.
    private static let resourceTimeout: TimeInterval = 45

    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        // These calls are all driver-initiated or alert-driven; none should be
        // served a stale body by the URL cache.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

// MARK: - Retry

public extension URLSession {

    /// Performs `request`, retrying the transient half of "no signal".
    ///
    /// Between towns a request does not fail cleanly — it fails because the radio
    /// dropped for a couple of seconds during a handover, and an attempt a moment
    /// later succeeds. Mirrors Android's `RetryInterceptor`, and is deliberately
    /// narrow for the same reasons:
    ///
    /// - Only transient transport errors and 5xx are retried. **429 is not**: the
    ///   caller's key is over quota, and hammering it is the one response
    ///   guaranteed to make that worse.
    /// - 5xx is retried **for GET only**. Every POST here (Places, Gemini, ORS)
    ///   bills the driver's own key per call, and a 5xx does not prove the work
    ///   did not happen — so retrying a POST can charge twice for one request.
    /// - Being plainly offline fails fast. Three DNS attempts with no network just
    ///   makes the user wait `maxAttempts`× longer to be told the same thing.
    func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        let maxAttempts = 3
        /// Doubles per attempt: 400 ms, then 800 ms.
        let backoffMs: UInt64 = 400
        let isGet = (request.httpMethod ?? "GET").uppercased() == "GET"

        var lastError: (any Error)?

        for attempt in 0 ..< maxAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: (backoffMs << (attempt - 1)) * 1_000_000)
            }
            try Task.checkCancellation()

            do {
                let (data, response) = try await data(for: request)
                guard isGet,
                      let http = response as? HTTPURLResponse,
                      (500..<600).contains(http.statusCode),
                      attempt < maxAttempts - 1
                else { return (data, response) }
                lastError = URLError(.badServerResponse)
            } catch let error as URLError where Self.isOffline(error) {
                throw error
            } catch let error as URLError where Self.isTransient(error) {
                lastError = error
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    /// Convenience for the GET call sites that build a bare URL.
    func dataWithRetry(from url: URL) async throws -> (Data, URLResponse) {
        try await dataWithRetry(for: URLRequest(url: url))
    }

    /// Genuinely no network — retrying cannot help.
    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Dropped or stalled mid-flight — the case a retry actually fixes.
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .resourceUnavailable, .requestBodyStreamExhausted:
            return true
        default:
            return false
        }
    }
}

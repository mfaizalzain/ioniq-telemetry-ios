import Foundation
import Testing
@testable import CoreData

/// Mirrors Android `RetryInterceptorTest.kt` — the retry policy is the thing that
/// decides whether a driver's own API key gets charged twice, so both builds are
/// held to the same cases.
/// `.serialized` because `StubProtocol`'s script and attempt counter are necessarily
/// global — `URLProtocol` subclasses are registered by type, not by instance — and
/// the default parallel execution had every test reading another's script.
@Suite("Network retry", .serialized)
struct NetworkRetryTests {

    // MARK: - Stub

    /// Serves a scripted sequence of outcomes and counts how many attempts were made.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        enum Outcome {
            case status(Int)
            case failure(URLError.Code)
        }

        nonisolated(unsafe) static let lock = NSLock()
        nonisolated(unsafe) static var script: [Outcome] = []
        nonisolated(unsafe) static var attempts = 0

        static func reset(_ outcomes: [Outcome]) {
            lock.withLock {
                script = outcomes
                attempts = 0
            }
        }

        static var attemptCount: Int { lock.withLock { attempts } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            let outcome: Outcome = Self.lock.withLock {
                let index = min(Self.attempts, Self.script.count - 1)
                Self.attempts += 1
                return Self.script[index]
            }

            switch outcome {
            case .status(let code):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func request(_ method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.invalid/v1/thing")!)
        request.httpMethod = method
        return request
    }

    // MARK: - Tests

    @Test("a dropped connection is retried and can succeed")
    func droppedConnectionRetries() async throws {
        StubProtocol.reset([.failure(.networkConnectionLost), .status(200)])

        let (_, response) = try await makeSession().dataWithRetry(for: request("GET"))

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(StubProtocol.attemptCount == 2)
    }

    @Test("retries are bounded and the last error is surfaced")
    func retriesAreBounded() async throws {
        StubProtocol.reset([.failure(.timedOut)])

        await #expect(throws: URLError.self) {
            try await makeSession().dataWithRetry(for: request("GET"))
        }
        #expect(StubProtocol.attemptCount == 3)
    }

    @Test("being genuinely offline fails fast instead of burning the backoff")
    func offlineFailsFast() async throws {
        StubProtocol.reset([.failure(.notConnectedToInternet)])

        await #expect(throws: URLError.self) {
            try await makeSession().dataWithRetry(for: request("GET"))
        }
        // One attempt only — three DNS tries with no network just makes the driver
        // wait longer to be told the same thing.
        #expect(StubProtocol.attemptCount == 1)
    }

    @Test("server errors are retried on GET")
    func serverErrorsRetriedOnGet() async throws {
        StubProtocol.reset([.status(503), .status(200)])

        let (_, response) = try await makeSession().dataWithRetry(for: request("GET"))

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(StubProtocol.attemptCount == 2)
    }

    @Test("server errors are not retried on POST")
    func serverErrorsNotRetriedOnPost() async throws {
        StubProtocol.reset([.status(500), .status(200)])

        // A 5xx does not prove the work didn't happen, and every POST here bills the
        // driver's own key — so this must surface the 500 rather than charge twice.
        let (_, response) = try await makeSession().dataWithRetry(for: request("POST"))

        #expect((response as? HTTPURLResponse)?.statusCode == 500)
        #expect(StubProtocol.attemptCount == 1)
    }

    @Test("rate limiting is never retried")
    func rateLimitNotRetried() async throws {
        StubProtocol.reset([.status(429)])

        let (_, response) = try await makeSession().dataWithRetry(for: request("GET"))

        #expect((response as? HTTPURLResponse)?.statusCode == 429)
        // Hammering a key that is already over quota is the one response guaranteed
        // to make it worse.
        #expect(StubProtocol.attemptCount == 1)
    }

    @Test("a successful call is passed straight through")
    func successPassesThrough() async throws {
        StubProtocol.reset([.status(200)])

        let (_, response) = try await makeSession().dataWithRetry(for: request("POST"))

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(StubProtocol.attemptCount == 1)
    }
}

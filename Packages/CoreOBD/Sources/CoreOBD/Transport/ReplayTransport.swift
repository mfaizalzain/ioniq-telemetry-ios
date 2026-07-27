import CoreDomain
import Foundation

// MARK: - Replay Transport

/// Replays a recorded OBD session so decoder work can happen at a desk instead
/// of in the vehicle.
///
/// Ported from Android `ReplayTransport.kt`. The session format is:
/// lines of `>COMMAND` followed by the raw response lines for that command.
///
/// When `send(command:timeoutMs:)` is called, the transport matches it against
/// recorded commands (cycling through multiple recorded responses for the same
/// command) and returns the recorded response.
public final class ReplayTransport: ObdTransport, @unchecked Sendable {

    // MARK: - Public properties

    public private(set) var state: ObdConnectionState = .disconnected {
        didSet { stateContinuation?.yield(state) }
    }

    public let stateStream: AsyncStream<ObdConnectionState>
    private let stateContinuation: AsyncStream<ObdConnectionState>.Continuation?

    // MARK: - Private state

    private let responses: [String: [String]]
    private var counters: [String: Int] = [:]

    // MARK: - Init

    /// - Parameter sessionText: Full session recording text (lines of `>COMMAND` / response).
    public init(sessionText: String) {
        var stateCont: AsyncStream<ObdConnectionState>.Continuation!
        stateStream = AsyncStream<ObdConnectionState> { stateCont = $0 }
        stateContinuation = stateCont
        self.responses = Self.parse(sessionText)
    }

    /// - Parameter sessionURL: Path or file URL to a session recording file.
    public convenience init(sessionFile url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(sessionText: text)
    }

    deinit {
        stateContinuation?.finish()
    }

    // MARK: - ObdTransport

    public func connect(device: ObdDevice) async throws {
        state = .connected
    }

    public func disconnect() async {
        state = .disconnected
    }

    public func send(command: String, timeoutMs: Int64) async throws -> String {
        // Simulate adapter latency
        try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms

        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if cmd.uppercased().hasPrefix("AT") {
            return "OK\r>"
        }

        guard let recorded = responses[cmd], !recorded.isEmpty else {
            return "NO DATA\r>"
        }

        // Cycle through recorded responses
        let idx = counters[cmd, default: 0]
        counters[cmd] = idx + 1
        return recorded[idx % recorded.count] + "\r>"
    }

    // MARK: - Session parsing (ported from Android ReplayTransport.kt)

    private static func parse(_ text: String) -> [String: [String]] {
        var map: [String: [String]] = [:]
        var currentCommand: String?
        var buf = ""

        func flush() {
            guard let cmd = currentCommand, !buf.isEmpty else {
                buf = ""
                return
            }
            map[cmd, default: []].append(buf.trimmingCharacters(in: .whitespacesAndNewlines))
            buf = ""
        }

        text.enumerateLines { line, _ in
            if line.hasPrefix(">") {
                flush()
                currentCommand = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if currentCommand != nil {
                buf.append(line)
                buf.append("\r")
            }
        }
        flush()
        return map
    }
}

// MARK: - Errors

public enum ReplayError: Error, LocalizedError {
    case invalidCommand

    public var errorDescription: String? {
        switch self {
        case .invalidCommand: "Invalid command — unable to decode as ASCII"
        }
    }
}

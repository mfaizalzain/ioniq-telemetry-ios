import Foundation
import CoreDomain

/// OBD transport protocol — one connection per adapter.
///
/// Ported from Android `ObdTransport.kt`. Implementations must be thread-safe
/// (the scheduler serializes all adapter access through its own loop, but
/// connect/disconnect may be called from any context).
public protocol ObdTransport: AnyObject, Sendable {

    /// Convenience: whether the transport is actively connected.
    var isConnected: Bool { get }

    /// Current connection state.
    var state: ObdConnectionState { get }

    /// Async stream of connection state transitions.
    var stateStream: AsyncStream<ObdConnectionState> { get }

    /// Open a connection to the given device.
    func connect(device: ObdDevice) async throws

    /// Close the connection and release resources.
    func disconnect() async

    /// Ask the transport to keep trying to restore a dropped link on its own,
    /// without a caller-driven retry loop.
    ///
    /// This exists for CoreBluetooth, where a `connect` on a known peripheral has
    /// no timeout: iOS holds the request and completes it whenever the adapter
    /// comes back, waking a suspended app to do it. That is the only mechanism
    /// that survives the app being suspended in a parked car — an app-level retry
    /// loop only runs while the app does.
    ///
    /// - Returns: true if a standing request is now armed, false when the
    ///   transport has no such facility and the caller should retry itself.
    func beginStandingReconnect() -> Bool

    /// Send a command and return everything received up to (and including) the
    /// ELM327 `>` prompt.
    ///
    /// - Parameters:
    ///   - command: The raw AT/ST command string (`\r` is appended by the transport).
    ///   - timeoutMs: Maximum time to wait for the complete response.
    /// - Returns: The raw adapter response including echo and prompt.
    func send(command: String, timeoutMs: Int64) async throws -> String
}

// MARK: - ELM327 Helpers

/// Character that marks the end of an ELM327 response.
public let ELM_PROMPT: Character = ">"

/// Strips echoes, prompt, and blank lines from a raw adapter response.
public func cleanResponse(raw: String, sentCommand: String? = nil) -> [String] {
    raw.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        .map { $0.replacingOccurrences(of: String(ELM_PROMPT), with: "").trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0 != sentCommand }
}

/// Converts Data response from a transport into cleaned lines.
public func parseResponse(_ data: Data, sentCommand: String? = nil) -> [String] {
    guard let raw = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8) else { return [] }
    return cleanResponse(raw: raw, sentCommand: sentCommand)
}

// MARK: - Default isConnected

extension ObdTransport {
    public var isConnected: Bool { state == .connected }

    /// WiFi and replay transports have nothing equivalent — their callers retry.
    public func beginStandingReconnect() -> Bool { false }
}

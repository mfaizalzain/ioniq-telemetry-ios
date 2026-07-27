import Foundation
import CoreDomain

/// Protocol for OBD transport implementations (BLE, WiFi, replay).
public protocol ObdTransport: AnyObject, Sendable {
    /// Current connection state stream.
    var stateStream: AsyncStream<ObdConnectionState> { get }

    /// Connect to a device. Returns success or throws on failure.
    func connect(device: ObdDevice) async throws

    /// Send a command and return the raw response string.
    func send(command: String, timeoutMs: Int64) async throws -> String

    /// Disconnect from the device.
    func disconnect() async
}

/// Character that marks the end of an ELM327 response.
public let ELM_PROMPT: Character = ">"

/// Strips echoes, prompt, and blank lines from a raw adapter response.
public func cleanResponse(raw: String, sentCommand: String? = nil) -> [String] {
    return raw.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: String(ELM_PROMPT), with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && $0 != sentCommand }
}

import Foundation

/// Protocol for ELM327 adapter communication (Bluetooth SPP / BLE / replay).
@available(macOS 10.15, iOS 13.0, *)
public protocol ObdTransport: AnyObject, Sendable {
    /// Sends a command and returns everything received up to the ELM327 '>' prompt.
    func send(_ command: String, timeoutMs: Int64) async throws -> String
}

public let elmPrompt: Character = ">"

/// Strips echoes, prompt, and blank lines from a raw adapter response.
public func cleanResponse(_ raw: String, sentCommand: String? = nil) -> [String] {
    raw.split(separator: "\r")
        .flatMap { $0.split(separator: "\n") }
        .map { $0.trimmingCharacters(in: .whitespaces)
                      .trimmingCharacters(in: CharacterSet(charactersIn: String(elmPrompt)))
                      .trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0 != sentCommand }
}

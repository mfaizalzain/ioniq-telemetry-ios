import Foundation

/// ELM327 initialization sequence.
/// ATH1 (headers on) and ATCAF0 (auto-format off) are load-bearing:
/// headers distinguish ECUs, and ISO-TP is reassembled by the app.
public final class Elm327Initializer {

    public struct InitResult: Sendable {
        public let adapterId: String
    }

    private let transport: any ObdTransport

    private let sequence: [String] = [
        "ATE0", "ATL0", "ATS0", "ATH1", "ATSP6", "ATAL", "ATCAF0", "ATST32"
    ]

    public init(transport: any ObdTransport) {
        self.transport = transport
    }

    public func initialize() async throws -> InitResult {
        let reset = try await sendWithRetry("ATZ", timeoutMs: 2_000)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let adapterId = reset.replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "unknown"

        for cmd in sequence {
            try await Task.sleep(nanoseconds: 200_000_000)
            // sendWithRetry already tolerates one miss per command. A command that
            // fails both attempts (or answers `?`) is not being applied — abort
            // rather than "succeeding" with ATH1/ATCAF0 unset and garbage telemetry
            // downstream. The old counter reset on every success, so an adapter
            // failing alternating commands never reached the abort.
            _ = try await sendWithRetry(cmd, timeoutMs: 1_000)
        }

        return InitResult(adapterId: adapterId)
    }

    private func sendWithRetry(_ cmd: String, timeoutMs: Int64) async throws -> String {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let raw = try await transport.send(command: cmd, timeoutMs: timeoutMs)
                // A '?' reply means the clone adapter did NOT apply the command —
                // count it as a failed attempt, not a pass.
                guard !isErrorResponse(raw) else {
                    lastError = Elm327Error.timeout(cmd: cmd)
                    continue
                }
                return raw
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Elm327Error.timeout(cmd: cmd)
    }
}

public enum Elm327Error: Error {
    case initFailed(cmd: String)
    case timeout(cmd: String)
}

import Foundation

/// ELM327 initialization sequence.
/// ATH1 (headers on) and ATCAF0 (auto-format off) are load-bearing:
/// headers distinguish ECUs, and ISO-TP is reassembled by the app
/// because adapter-side handling is unreliable on clone firmware.
public final class Elm327Initializer {

    public struct InitResult: Sendable {
        public let adapterId: String
    }

    private let transport: any ObdTransport

    private let sequence: [String] = [
        "ATE0",      // echo off
        "ATL0",      // linefeeds off
        "ATS0",      // spaces off
        "ATH1",      // headers ON — required to distinguish ECUs
        "ATSP6",     // protocol 6: CAN 11-bit, 500 kbps
        "ATAL",      // allow long (>7 byte) messages
        "ATCAF0",    // CAN auto-formatting OFF — app handles ISO-TP
        "ATST32"     // timeout 200 ms (0x32 * 4 ms)
    ]

    public init(transport: any ObdTransport) {
        self.transport = transport
    }

    public func initialize() async throws -> InitResult {
        var failures = 0

        let reset = try await sendWithRetry(cmd: "ATZ", timeoutMs: 2_000)
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        let lines = reset.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        let adapterId = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "unknown"

        for cmd in sequence {
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            do {
                _ = try await sendWithRetry(cmd: cmd, timeoutMs: 1_000)
                failures = 0
            } catch {
                failures += 1
                if failures >= 3 {
                    throw Elm327Error.initFailed(cmd: cmd)
                }
            }
        }

        return InitResult(adapterId: adapterId)
    }

    private func sendWithRetry(cmd: String, timeoutMs: Int64) async throws -> String {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                return try await transport.send(command: cmd, timeoutMs: timeoutMs)
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

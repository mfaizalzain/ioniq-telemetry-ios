import Foundation

/// ELM327 initialization (spec §3.2). ATH1 (headers on) and ATCAF0 (auto-format
/// off) are load-bearing: headers distinguish ECUs, and ISO-TP is reassembled by
/// the app because adapter-side handling is unreliable on clone firmware.
@available(macOS 10.15, iOS 13.0, *)
public final class Elm327Initializer: Sendable {
    public struct InitResult: Sendable {
        public let adapterId: String
    }

    private let transport: ObdTransport

    private let sequence: [String] = [
        "ATE0",      // echo off
        "ATL0",      // linefeeds off
        "ATS0",      // spaces off
        "ATH1",      // headers ON — required to distinguish ECUs
        "ATSP6",     // protocol 6: CAN 11-bit, 500 kbps
        "ATAL",      // allow long (>7 byte) messages
        "ATCAF0",    // CAN auto-formatting OFF — app handles ISO-TP
        "ATST32",    // timeout 200 ms (0x32 * 4 ms)
    ]

    public init(transport: ObdTransport) {
        self.transport = transport
    }

    public func initialize() async throws -> InitResult {
        var failures = 0

        // ATZ: 2-second timeout, retry once
        let reset: String
        do {
            reset = try await sendWithRetry("ATZ", timeoutMs: 2_000)
        } catch {
            throw InitError.commandFailed("ATZ")
        }
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1000 ms post-reset delay

        let adapterId = reset
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? "unknown"

        for cmd in sequence {
            try await Task.sleep(nanoseconds: 200_000_000) // 200 ms between commands
            do {
                _ = try await sendWithRetry(cmd, timeoutMs: 1_000)
                failures = 0
            } catch {
                failures += 1
                // Abort after three consecutive timeouts.
                if failures >= 3 {
                    throw InitError.commandFailed(cmd)
                }
            }
        }

        return InitResult(adapterId: adapterId)
    }

    private func sendWithRetry(_ cmd: String, timeoutMs: Int64) async throws -> String {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                return try await transport.send(cmd, timeoutMs: timeoutMs)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? InitError.commandFailed(cmd)
    }
}

public enum InitError: Error, Sendable {
    case commandFailed(String)
}

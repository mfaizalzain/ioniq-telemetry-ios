import Foundation

/// Discovery sweep for UDS ReadDataByIdentifier (service 0x22) across ECU addresses.
public final class PidSweeper: @unchecked Sendable {

    public enum Outcome: Sendable {
        case supported, notSupported, silent
    }

    public struct Finding: Sendable {
        public let header: String
        public let request: String
        public let outcome: Outcome
        public let raw: String?
        public var payloadHex: String? {
            guard let raw else { return nil }
            let filtered = raw.replacingOccurrences(of: "[^0-9A-Fa-f]", with: "", options: .regularExpression)
            return filtered.isEmpty ? nil : filtered
        }
    }

    private let transport: any ObdTransport
    private let recorder: ObdSessionRecorder?

    public static let discoveryProbe = "22FFFF"
    public static let defaultHeaders: [String] = (0x7A0...0x7EF).map { String(format: "%03X", $0) }
    public static let defaultIdentifiers: [String] = {
        var ids: [String] = []
        for i in 0x01...0x0C { ids.append(String(format: "2201%02X", i)) }
        for i in 0x01...0x06 { ids.append(String(format: "22B0%02X", i)) }
        ids.append("22C00B"); ids.append("22F190")
        return ids
    }()

    public init(transport: any ObdTransport, recorder: ObdSessionRecorder? = nil) {
        self.transport = transport; self.recorder = recorder
    }

    @discardableResult
    public func sweep(
        headers: [String], identifiers: [String],
        probeRequest: String = "22FFFF",
        onFinding: @Sendable (Finding) async -> Void = { _ in }
    ) async -> [String] {
        guard isReadOnly(probeRequest) else { fatalError("Probe must be 0x22: \(probeRequest)") }
        for id in identifiers { guard isReadOnly(id) else { fatalError("Refusing non-0x22: \(id)") } }

        var live: [String] = []
        for header in headers {
            guard await configureHeader(header: header) else {
                await onFinding(Finding(header: header, request: probeRequest, outcome: .silent, raw: nil)); continue
            }
            let probe = await requestFind(header: header, requestHex: probeRequest)
            await onFinding(probe)
            guard probe.outcome != .silent else { continue }
            live.append(header)
            for id in identifiers { await onFinding(await requestFind(header: header, requestHex: id)) }
        }
        return live
    }

    private func requestFind(header: String, requestHex: String) async -> Finding {
        let framed = isoTpSingleFrame(requestHex: requestHex)
        let raw = try? await transport.send(command: framed, timeoutMs: 600)
        recorder?.record(command: framed, rawResponse: raw ?? "")

        let lines = raw.map { cleanResponse(raw: $0, sentCommand: framed) } ?? []
            .filter { $0.caseInsensitiveCompare("NO DATA") != .orderedSame }
            .filter { $0 != "?" }
        let joined = lines.joined(separator: "|")
        let joinedOrNil = joined.isEmpty ? nil : joined

        let outcome: Outcome
        if joinedOrNil == nil { outcome = .silent }
        else if lines.contains(where: { $0.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains("7F") }) { outcome = .notSupported }
        else { outcome = .supported }

        return Finding(header: header, request: requestHex, outcome: outcome, raw: joinedOrNil)
    }

    private func configureHeader(header: String) async -> Bool {
        for cmd in ["ATSH\(header)", "ATFCSH\(header)", "ATFCSD300000", "ATFCSM1"] {
            do { _ = try await transport.send(command: cmd, timeoutMs: 500) }
            catch { return false }
        }
        return true
    }

    private func isReadOnly(_ hex: String) -> Bool {
        hex.count >= 2 && hex.prefix(2).caseInsensitiveCompare("22") == .orderedSame
    }
}

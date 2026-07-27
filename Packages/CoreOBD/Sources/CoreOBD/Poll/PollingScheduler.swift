import Foundation

/// Single-consumer request queue. All adapter access is serialized.
public final class PollingScheduler: @unchecked Sendable {

    private let transport: any ObdTransport
    private let recorder: ObdSessionRecorder?
    private let onPayload: @Sendable (String, Data) async -> Void
    private let onRawLine: @Sendable (String) -> Void

    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var lastRunAt: [String: Int64] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var mutedUntil: [String: Int64] = [:]
    private var currentHeader: String?

    private static let muteCooldownMs: Int64 = 30_000

    public init(
        transport: any ObdTransport,
        recorder: ObdSessionRecorder? = nil,
        onPayload: @escaping @Sendable (String, Data) async -> Void,
        onRawLine: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.recorder = recorder
        self.onPayload = onPayload
        self.onRawLine = onRawLine
    }

    public func start(requests: [RequestDef]) {
        stop()
        lock.withLock {
            lastRunAt.removeAll()
            consecutiveFailures.removeAll()
            mutedUntil.removeAll()
        }

        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let snapshot = self.lock.withLock { (self.lastRunAt, self.mutedUntil) }

                var due = requests
                    .filter { now >= (snapshot.1[$0.id] ?? 0) }
                    .filter { now - (snapshot.0[$0.id] ?? 0) >= $0.pollTier.intervalMs }
                    .sorted { $0.pollTier.priority < $1.pollTier.priority }

                if due.count > 3 {
                    let lowest = due.map(\.pollTier.priority).max() ?? 2
                    due = due.filter { $0.pollTier.priority != lowest }
                }

                for request in due.sorted(by: { $0.header < $1.header }) {
                    if Task.isCancelled { break }
                    await self.execute(request: request)
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lock.withLock { currentHeader = nil }
    }

    private func execute(request: RequestDef) async {
        lock.withLock { lastRunAt[request.id] = Int64(Date().timeIntervalSince1970 * 1000) }

        if lock.withLock({ currentHeader }) != request.header {
            guard await configureHeader(header: request.header) else {
                registerFailure(request: request)
                return
            }
            lock.withLock { currentHeader = request.header }
        }

        let framed = isoTpSingleFrame(requestHex: request.request)

        // Retry with exponential backoff
        var raw: String?
        for timeout in [300, 600, 1200] {
            do {
                raw = try await transport.send(command: framed, timeoutMs: Int64(timeout))
                break
            } catch { continue }
        }

        guard let raw else {
            registerFailure(request: request)
            return
        }

        await recorder?.record(command: framed, rawResponse: raw)

        let lines = cleanResponse(raw: raw, sentCommand: framed)
        for line in lines { onRawLine(line) }

        let responseHeader = IsoTpReassembler.responseHeaderFor(requestHeader: request.header)
        guard let payload = IsoTpReassembler.reassemble(lines: lines, responseHeader: responseHeader) else {
            registerFailure(request: request)
            return
        }

        lock.withLock { consecutiveFailures[request.id] = 0 }
        await onPayload(request.id, payload)
    }

    private func configureHeader(header: String) async -> Bool {
        for cmd in ["ATSH\(header)", "ATFCSH\(header)", "ATFCSD300000", "ATFCSM1"] {
            do {
                _ = try await transport.send(command: cmd, timeoutMs: 500)
            } catch { return false }
        }
        return true
    }

    private func registerFailure(request: RequestDef) {
        lock.withLock {
            let f = (consecutiveFailures[request.id] ?? 0) + 1
            consecutiveFailures[request.id] = f
            if f >= 3 {
                mutedUntil[request.id] = Int64(Date().timeIntervalSince1970 * 1000) + Self.muteCooldownMs
                consecutiveFailures[request.id] = 0
            }
            currentHeader = nil
        }
    }
}

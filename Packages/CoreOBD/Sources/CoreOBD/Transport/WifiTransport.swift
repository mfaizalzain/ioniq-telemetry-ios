import CoreDomain
import Foundation
import Network

// MARK: - Wi-Fi Transport

/// ELM327 Wi-Fi adapter transport using `NWConnection` (TCP on port 35000).
///
/// Most ELM327 WiFi adapters run a TCP server on port 35000. This transport
/// opens a single TCP connection, sends command bytes, and buffers the response
/// until the ELM327 `>` prompt delimiter.
public final class WifiTransport: ObdTransport, @unchecked Sendable {

    // MARK: - Constants

    private enum Constant {
        static let defaultPort: UInt16 = 35000
        static let connectPollInterval: UInt64 = 50_000_000
        /// Ceiling on a black-holed TCP connect (no SYN-ACK, no RST): without this,
        /// connect(device:) suspends forever on a dead adapter.
        static let connectTimeoutSeconds: TimeInterval = 10
    }

    // MARK: - Public properties

    public private(set) var state: ObdConnectionState = .disconnected {
        didSet { stateContinuation?.yield(state) }
    }

    public let stateStream: AsyncStream<ObdConnectionState>
    private let stateContinuation: AsyncStream<ObdConnectionState>.Continuation?

    // MARK: - Private state

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.fmz.ioniqtelemetry.wifi", qos: .userInitiated)

    private let responseLock = NSLock()
    private var responseBuffer = ""
    private var sendContinuation: CheckedContinuation<String, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Init

    public init() {
        var stateCont: AsyncStream<ObdConnectionState>.Continuation!
        stateStream = AsyncStream<ObdConnectionState> { stateCont = $0 }
        stateContinuation = stateCont
    }

    deinit {
        stateContinuation?.finish()
    }

    // MARK: - ObdTransport

    public func connect(device: ObdDevice) async throws {
        state = .connecting

        let host: String
        let port: UInt16

        if device.address.contains(":") {
            let parts = device.address.split(separator: ":")
            host = String(parts[0])
            port = parts.count > 1 ? UInt16(parts[1]) ?? Constant.defaultPort : Constant.defaultPort
        } else {
            host = device.address
            port = Constant.defaultPort
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn

        // A black-holed TCP connect would suspend connect(device:) forever without
        // this ceiling. The task resumes the pending continuation (taking it first,
        // so the state handler's `.cancelled` below is a no-op) and cancels the
        // connection.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Constant.connectTimeoutSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.takePendingConnect()?.resume(throwing: WifiError.connectTimeout)
            self?.connection?.cancel()
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            responseLock.lock()
            connectContinuation = cont
            responseLock.unlock()

            conn.stateUpdateHandler = { [weak self] nwState in
                guard let self else { return }
                switch nwState {
                case .ready:
                    self.state = .connected
                    self.receiveLoop()
                    self.takePendingConnect()?.resume()
                case .failed(let error):
                    self.state = .error
                    self.takePendingConnect()?.resume(throwing: error)
                case .cancelled:
                    // Either the timeout task already resumed (and took the
                    // continuation) or the connection was cancelled externally —
                    // resolve any still-pending continuation.
                    self.takePendingConnect()?.resume(throwing: WifiError.connectFailed)
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }
    }

    public func disconnect() async {
        connection?.cancel()
        connection = nil

        // Take + resume under the lock so a concurrent onChunk cannot double-resume
        // the same continuation (the old code read/cleared it without the lock).
        takePendingSend()?.resume(throwing: WifiError.disconnected)
        takePendingConnect()?.resume(throwing: WifiError.disconnected)

        state = .disconnected
    }

    public func send(command: String, timeoutMs: Int64) async throws -> String {
        guard let conn = connection, case .connected = state else {
            throw WifiError.notConnected
        }

        let payload = Data((command + "\r").utf8)

        return try await withThrowingTaskGroup(of: String.self) { group in
            // Timeout task: clear and resume the pending send so a late adapter
            // response cannot double-resume it or leak into the next request. If the
            // send already completed, takePendingSend() is a no-op and this task
            // still throws so the group returns promptly.
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                self?.takePendingSend()?.resume(throwing: WifiError.sendTimeout)
                throw WifiError.sendTimeout
            }

            // Send task
            group.addTask { [weak self] in
                guard let self else { throw WifiError.disconnected }

                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.responseLock.lock()
                    self.responseBuffer = ""
                    self.sendContinuation = cont
                    self.responseLock.unlock()

                    conn.send(content: payload, completion: .contentProcessed({ error in
                        if let error {
                            self.takePendingSend()?.resume(throwing: error)
                        }
                    }))
                }
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func takePendingSend() -> CheckedContinuation<String, Error>? {
        responseLock.lock()
        defer { responseLock.unlock() }
        let c = sendContinuation
        sendContinuation = nil
        return c
    }

    private func takePendingConnect() -> CheckedContinuation<Void, Error>? {
        responseLock.lock()
        defer { responseLock.unlock() }
        let c = connectContinuation
        connectContinuation = nil
        return c
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        guard let conn = connection else { return }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.state = .error
                self.takePendingSend()?.resume(throwing: error)
                return
            }

            if let data, !data.isEmpty {
                self.onChunk(data)
            }

            // A graceful close reports isComplete = true. Recursing regardless left
            // us busy-looping on a dead connection that never flips state.
            if !isComplete, case .connected = self.state {
                self.receiveLoop()
            }
        }
    }

    private func onChunk(_ bytes: Data) {
        guard let chunk = String(data: bytes, encoding: .ascii) else { return }
        responseLock.lock()
        defer { responseLock.unlock() }

        responseBuffer.append(chunk)
        if responseBuffer.contains(ELM_PROMPT) {
            let full = responseBuffer
            responseBuffer = ""
            let cont = sendContinuation
            sendContinuation = nil
            cont?.resume(returning: full)
        }
    }
}

// MARK: - Errors

public enum WifiError: Error, LocalizedError {
    case connectFailed
    case connectTimeout
    case notConnected
    case disconnected
    case sendTimeout

    public var errorDescription: String? {
        switch self {
        case .connectFailed:   "Wi-Fi connection failed"
        case .connectTimeout:  "Wi-Fi connection timed out"
        case .notConnected:    "Not connected"
        case .disconnected:    "Disconnected"
        case .sendTimeout:     "Send timed out"
        }
    }
}

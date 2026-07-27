import Foundation
import CoreDomain

/// Owns the transport, initializer, scheduler, and decoder, exposing a single
/// telemetry stream. Held by the connected-car service.
@MainActor
public final class ObdManager {

    public typealias TransportFactory = @Sendable (String) async throws -> any ObdTransport

    // MARK: - Public state

    public private(set) var telemetry: VehicleTelemetry = VehicleTelemetry()
    public private(set) var connectionState: ObdConnectionState = .disconnected

    /// Why the last `loadProfile` call failed, if it did. Surfaced in Settings so
    /// a bad profile id is visible instead of silently decoding nothing.
    public private(set) var lastProfileError: String?

    public var onTelemetryUpdated: (@Sendable (VehicleTelemetry) -> Void)?
    public var onConnectionStateChanged: (@Sendable (ObdConnectionState) -> Void)?
    public var onRawLine: (@Sendable (String) -> Void)?

    // MARK: - Internal

    // Immutable and Sendable, so the off-actor polling callback can reach them
    // without `nonisolated(unsafe)`. `activeProfile` stays main-actor isolated —
    // the scheduler closure captures the profile it was built with instead.
    private let decoder = DecoderEngine()
    private let assembler = TelemetryAssembler()
    private var activeProfile: DecoderProfile

    public let recorder: ObdSessionRecorder

    private var transport: (any ObdTransport)?
    private var scheduler: PollingScheduler?
    private var stateWatchTask: Task<Void, Never>?
    private let transportFactory: TransportFactory

    // MARK: - Init

    public init(
        transportFactory: @escaping TransportFactory,
        sessionDirectory: URL,
        defaultProfile: DecoderProfile? = nil
    ) {
        self.transportFactory = transportFactory
        self.recorder = ObdSessionRecorder(directory: sessionDirectory)
        self.activeProfile = defaultProfile ?? DecoderProfile(
            profileId: "ioniq5_2022_77kwh",
            displayName: "Ioniq 5 (77.4 kWh)",
            usableCapacityKwh: 74.0,
            requests: []
        )
    }

    // MARK: - Profile loading

    public func loadProfile(profileId: String) {
        loadProfile(profileId: profileId, from: ProfileParser.resourceBundle)
    }

    public func loadProfile(profileId: String, from bundle: Bundle) {
        guard let assetName = Ioniq5Constants.decoderProfileAsset(for: profileId) else {
            lastProfileError = "Unknown vehicle profile '\(profileId)' — keeping \(activeProfile.profileId)."
            return
        }

        guard let url = bundle.url(forResource: assetName, withExtension: "json") else {
            lastProfileError = "Profile asset \(assetName).json is missing from the bundle."
            return
        }
        do {
            activeProfile = try ProfileParser.parse(data: Data(contentsOf: url))
            lastProfileError = nil
        } catch {
            lastProfileError = "Profile \(assetName).json could not be parsed: \(error.localizedDescription)"
        }
    }

    // MARK: - Connection lifecycle

    public func connect(device: ObdDevice) async -> Result<Void, Error> {
        await disconnect()

        let t: any ObdTransport
        do {
            t = try await transportFactory(device.address)
        } catch {
            updateConnectionState(.error)
            return .failure(error)
        }
        transport = t
        updateConnectionState(.connecting)

        do {
            try await t.connect(device: device)
        } catch {
            updateConnectionState(.error)
            await disconnect()
            return .failure(error)
        }

        updateConnectionState(.initializing)

        do {
            _ = try await Elm327Initializer(transport: t).initialize()
        } catch {
            updateConnectionState(.error)
            await disconnect()
            return .failure(error)
        }

        updateConnectionState(.connected)

        stateWatchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let t = self.transport else { break }
                let st = t.state
                if st == .disconnected || st == .error {
                    await self.handleTransportDrop(isError: st == .error)
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        let profile = activeProfile
        let s = newScheduler(transport: t, profile: profile)
        scheduler = s
        s.start(requests: profile.requests)

        return .success(())
    }

    private func newScheduler(transport: any ObdTransport, profile: DecoderProfile) -> PollingScheduler {
        return PollingScheduler(
            transport: transport,
            recorder: recorder,
            onPayload: { [weak self] requestId, payload in
                guard let self else { return }
                guard let request = profile.requests.first(where: { $0.id == requestId }) else { return }
                let decoder = self.decoder
                let signals = decoder.decode(payload: Data(payload), signals: request.signals)
                Task { @MainActor in
                    self.telemetry = self.assembler.merge(
                        current: self.telemetry,
                        signals: signals,
                        now: Date()
                    )
                    self.onTelemetryUpdated?(self.telemetry)
                }
            },
            onRawLine: { [weak self] line in
                Task { @MainActor in
                    self?.onRawLine?(line)
                }
            }
        )
    }

    private func handleTransportDrop(isError: Bool) async {
        scheduler?.stop()
        scheduler = nil
        updateConnectionState(isError ? .error : .disconnected)
    }

    // MARK: - Polling control

    public func withPollingPaused<T: Sendable>(_ block: @Sendable () async throws -> T) async rethrows -> T {
        let t = transport
        let wasRunning = scheduler != nil
        scheduler?.stop()
        scheduler = nil
        defer {
            if wasRunning, let t {
                let s = newScheduler(transport: t, profile: activeProfile)
                scheduler = s
                s.start(requests: activeProfile.requests)
            }
        }
        return try await block()
    }

    @discardableResult
    public func sweepPids(
        headers: [String] = PidSweeper.defaultHeaders,
        identifiers: [String] = PidSweeper.defaultIdentifiers,
        onFinding: @escaping @Sendable (PidSweeper.Finding) async -> Void = { _ in }
    ) async -> [String] {
        let t = transport
        return await withPollingPaused {
            guard let t else { return [] }
            return await PidSweeper(transport: t, recorder: recorder).sweep(
                headers: headers,
                identifiers: identifiers,
                onFinding: onFinding
            )
        }
    }

    public func sendRaw(command: String) async -> String {
        guard let t = transport else { return "Not connected" }
        do {
            return try await t.send(command: command, timeoutMs: 3000)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    public func disconnect() async {
        stateWatchTask?.cancel()
        stateWatchTask = nil
        scheduler?.stop()
        scheduler = nil
        await transport?.disconnect()
        transport = nil
        updateConnectionState(.disconnected)
    }

    private func updateConnectionState(_ state: ObdConnectionState) {
        connectionState = state
        onConnectionStateChanged?(state)
    }
}

import Combine
import CoreDomain

/// App-wide telemetry holder. ConnectedCarService pushes OBD output here;
/// everything else (phone UI, CarPlay) reads this single publisher.
public final class TelemetryRepositoryImpl: TelemetryRepository, @unchecked Sendable {
    private let _state = CurrentValueSubject<VehicleTelemetry, Never>(VehicleTelemetry())
    private let _connectionState = CurrentValueSubject<ObdConnectionState, Never>(.disconnected)

    public var state: AnyPublisher<VehicleTelemetry, Never> { _state.eraseToAnyPublisher() }
    public var connectionState: AnyPublisher<ObdConnectionState, Never> { _connectionState.eraseToAnyPublisher() }

    public init() {}

    public func update(_ telemetry: VehicleTelemetry) {
        _state.value = telemetry
    }

    public func setConnectionState(_ state: ObdConnectionState) {
        _connectionState.value = state
    }

    public func startScanning() {
        _connectionState.value = .scanning
    }

    public func stopScanning() {
        if _connectionState.value == .scanning {
            _connectionState.value = .disconnected
        }
    }

    public func connect(to device: ObdDevice) {
        _connectionState.value = .connecting
    }

    public func disconnect() {
        _connectionState.value = .disconnected
        _state.value = VehicleTelemetry()
    }
}

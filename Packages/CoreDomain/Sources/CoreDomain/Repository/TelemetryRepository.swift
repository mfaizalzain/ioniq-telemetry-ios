import Combine

/// Single source of truth for live telemetry, backed by ConnectedCarService.
public protocol TelemetryRepository: Sendable {
    /// Current vehicle telemetry state.
    var state: AnyPublisher<VehicleTelemetry, Never> { get }

    /// Current OBD connection state.
    var connectionState: AnyPublisher<ObdConnectionState, Never> { get }

    /// Start scanning for OBD adapters.
    func startScanning()

    /// Stop scanning for OBD adapters.
    func stopScanning()

    /// Connect to a specific OBD device.
    func connect(to device: ObdDevice)

    /// Disconnect from the current OBD device.
    func disconnect()
}

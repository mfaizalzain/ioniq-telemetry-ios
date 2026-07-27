import CoreBluetooth
import CoreDomain
import Foundation

/// BLE transport for ELM327 adapters (Vgate iCar Pro, LELink, OBDLink CX, …).
///
/// iOS has no Bluetooth Classic SPP for non-MFi accessories, so BLE GATT is the
/// only Bluetooth path. Adapters expose a write characteristic and a notify
/// characteristic, usually in one of three well-known services (see
/// `knownServiceUUIDs`); clones with custom UUIDs are handled by falling back to
/// the first service that contains a usable write/notify pair.
///
/// `ObdDevice.address` holds the `CBPeripheral.identifier` UUID string. iOS never
/// exposes the hardware MAC, and that identifier is stable per device+app install,
/// so it is what gets persisted for reconnection.
///
/// All CoreBluetooth work happens on a private serial queue. Public methods are
/// async and hop onto it, so callers may invoke them from any context.
///
/// Ported from Android BleTransport.kt.
public final class BleTransport: NSObject, ObdTransport, @unchecked Sendable {

    // MARK: - Errors

    public enum BleError: LocalizedError {
        case bluetoothUnavailable(CBManagerState)
        case invalidDeviceAddress(String)
        case deviceNotFound
        case connectFailed(String)
        case noUsableCharacteristics
        case notConnected
        case disconnected
        case sendTimeout

        public var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable(let s):
                switch s {
                case .poweredOff: return "Bluetooth is turned off."
                case .unauthorized: return "Bluetooth permission was denied for this app."
                case .unsupported: return "This device does not support Bluetooth LE."
                default: return "Bluetooth is unavailable."
                }
            case .invalidDeviceAddress(let a): return "Not a valid adapter identifier: \(a)"
            case .deviceNotFound: return "Adapter not found. Make sure it is powered and in range."
            case .connectFailed(let m): return "Could not connect to the adapter: \(m)"
            case .noUsableCharacteristics: return "Adapter does not expose a usable serial service."
            case .notConnected: return "Not connected to an adapter."
            case .disconnected: return "The adapter disconnected."
            case .sendTimeout: return "The adapter stopped responding."
            }
        }
    }

    // MARK: - Known ELM327 BLE services

    /// Probed in order; anything else falls back to a generic write/notify search.
    nonisolated(unsafe) static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "FFE0"),                                   // HM-10 / Vgate iCar Pro
        CBUUID(string: "FFF0"),                                   // LELink and similar
        CBUUID(string: "18F0"),                                   // OBDLink CX
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")    // Nordic UART
    ]

    /// How long to scan for the adapter before giving up.
    private static let discoveryTimeout: TimeInterval = 12
    /// How long to wait for GATT connect + service/characteristic discovery.
    private static let setupTimeout: TimeInterval = 15
    /// How long to wait for Bluetooth to reach `poweredOn` after init.
    private static let powerOnTimeout: TimeInterval = 5

    // MARK: - State

    private let queue = DispatchQueue(label: "com.fmz.ioniqtelemetry.ble", qos: .userInitiated)
    private let lock = NSLock()

    /// All of the following are guarded by `lock`.
    private var _state: ObdConnectionState = .disconnected
    private var stateContinuations: [UUID: AsyncStream<ObdConnectionState>.Continuation] = [:]
    private var responseBuffer = ""
    private var pendingSend: CheckedContinuation<String, any Error>?
    private var pendingStage: CheckedContinuation<Void, any Error>?
    private var targetIdentifier: UUID?

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var selectedServiceIsKnown = false
    private var pendingServiceCount = 0

    public var state: ObdConnectionState {
        lock.withLock { _state }
    }

    public var stateStream: AsyncStream<ObdConnectionState> {
        AsyncStream { continuation in
            let key = UUID()
            let current: ObdConnectionState = lock.withLock {
                stateContinuations[key] = continuation
                return _state
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.stateContinuations.removeValue(forKey: key) }
            }
        }
    }

    // MARK: - Init

    public override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: queue)
    }

    deinit {
        let conts = lock.withLock { () -> [AsyncStream<ObdConnectionState>.Continuation] in
            let values = Array(stateContinuations.values)
            stateContinuations.removeAll()
            return values
        }
        conts.forEach { $0.finish() }
    }

    // MARK: - ObdTransport

    public func connect(device: ObdDevice) async throws {
        await disconnect()
        setState(.connecting)

        do {
            try await waitForPoweredOn()

            guard let identifier = UUID(uuidString: device.address) else {
                throw BleError.invalidDeviceAddress(device.address)
            }

            let target = try await resolvePeripheral(identifier: identifier)
            target.delegate = self
            lock.withLock { peripheral = target }

            try await withStageTimeout(Self.setupTimeout) {
                self.centralManager.connect(target, options: nil)
            }

            try await withStageTimeout(Self.setupTimeout) {
                target.discoverServices(nil)
            }

            guard writeCharacteristicSnapshot != nil, let notify = notifyCharacteristicSnapshot else {
                throw BleError.noUsableCharacteristics
            }
            target.setNotifyValue(true, for: notify)

            setState(.connected)
        } catch {
            await disconnect()
            setState(.error)
            throw error
        }
    }

    public func disconnect() async {
        let (target, stage, send) = lock.withLock { () -> (CBPeripheral?, CheckedContinuation<Void, any Error>?, CheckedContinuation<String, any Error>?) in
            let p = peripheral
            let st = pendingStage
            let sd = pendingSend
            pendingStage = nil
            pendingSend = nil
            peripheral = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            selectedServiceIsKnown = false
            pendingServiceCount = 0
            targetIdentifier = nil
            responseBuffer = ""
            return (p, st, sd)
        }

        centralManager.stopScan()
        if let target {
            if let notify = target.services?.flatMap({ $0.characteristics ?? [] }).first(where: { $0.isNotifying }) {
                target.setNotifyValue(false, for: notify)
            }
            centralManager.cancelPeripheralConnection(target)
        }
        stage?.resume(throwing: BleError.disconnected)
        send?.resume(throwing: BleError.disconnected)

        setState(.disconnected)
    }

    public func send(command: String, timeoutMs: Int64) async throws -> String {
        let (target, characteristic) = lock.withLock { (peripheral, writeCharacteristic) }
        guard let target, let characteristic, target.state == .connected else {
            throw BleError.notConnected
        }

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let chunkSize = target.maximumWriteValueLength(for: writeType)
        let payload = Data((command + "\r").utf8)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 0)) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.takePendingSend()?.resume(throwing: BleError.sendTimeout)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            let alreadyPending = lock.withLock { () -> Bool in
                guard pendingSend == nil else { return true }
                pendingSend = cont
                responseBuffer = ""
                return false
            }
            // The scheduler serializes commands; a second concurrent send is a caller bug.
            guard !alreadyPending else {
                cont.resume(throwing: BleError.notConnected)
                return
            }

            for offset in stride(from: 0, to: payload.count, by: max(chunkSize, 1)) {
                let chunk = payload[offset ..< min(offset + chunkSize, payload.count)]
                target.writeValue(Data(chunk), for: characteristic, type: writeType)
            }
        }
    }

    // MARK: - Connection helpers

    private var writeCharacteristicSnapshot: CBCharacteristic? { lock.withLock { writeCharacteristic } }
    private var notifyCharacteristicSnapshot: CBCharacteristic? { lock.withLock { notifyCharacteristic } }

    private func waitForPoweredOn() async throws {
        let deadline = Date().addingTimeInterval(Self.powerOnTimeout)
        while Date() < deadline {
            switch centralManager.state {
            case .poweredOn: return
            case .unknown, .resetting: try await Task.sleep(nanoseconds: 200_000_000)
            default: throw BleError.bluetoothUnavailable(centralManager.state)
            }
        }
        throw BleError.bluetoothUnavailable(centralManager.state)
    }

    /// Returns a already-known peripheral if iOS still has it cached, otherwise
    /// scans until one with a matching identifier shows up.
    private func resolvePeripheral(identifier: UUID) async throws -> CBPeripheral {
        if let known = centralManager.retrievePeripherals(withIdentifiers: [identifier]).first {
            return known
        }

        lock.withLock { targetIdentifier = identifier }
        defer {
            centralManager.stopScan()
            lock.withLock { targetIdentifier = nil }
        }

        try await withStageTimeout(Self.discoveryTimeout) {
            // Nil services: ELM327 clones frequently omit their service UUIDs
            // from the advertisement packet, so filtering by UUID misses them.
            self.centralManager.scanForPeripherals(withServices: nil, options: nil)
        }

        guard let found = lock.withLock({ peripheral }) else { throw BleError.deviceNotFound }
        return found
    }

    /// Runs `action` and suspends until a delegate callback resumes the stage
    /// continuation, or the timeout elapses.
    private func withStageTimeout(_ seconds: TimeInterval, _ action: @escaping () -> Void) async throws {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.takePendingStage()?.resume(throwing: BleError.deviceNotFound)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            lock.withLock { pendingStage = cont }
            action()
        }
    }

    private func takePendingStage() -> CheckedContinuation<Void, any Error>? {
        lock.withLock {
            let c = pendingStage
            pendingStage = nil
            return c
        }
    }

    private func takePendingSend() -> CheckedContinuation<String, any Error>? {
        lock.withLock {
            let c = pendingSend
            pendingSend = nil
            return c
        }
    }

    private func setState(_ newState: ObdConnectionState) {
        let conts = lock.withLock { () -> [AsyncStream<ObdConnectionState>.Continuation] in
            guard _state != newState else { return [] }
            _state = newState
            return Array(stateContinuations.values)
        }
        conts.forEach { $0.yield(newState) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleTransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .poweredOn else { return }
        // Radio went away underneath us — tear down so ObdManager can react.
        takePendingStage()?.resume(throwing: BleError.bluetoothUnavailable(central.state))
        takePendingSend()?.resume(throwing: BleError.disconnected)
        setState(.error)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let matched = lock.withLock { () -> Bool in
            guard let target = targetIdentifier, peripheral.identifier == target else { return false }
            self.peripheral = peripheral
            return true
        }
        guard matched else { return }
        central.stopScan()
        takePendingStage()?.resume()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        takePendingStage()?.resume()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        takePendingStage()?.resume(throwing: BleError.connectFailed(error?.localizedDescription ?? "unknown"))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        lock.withLock {
            self.peripheral = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            selectedServiceIsKnown = false
            pendingServiceCount = 0
            responseBuffer = ""
        }
        takePendingStage()?.resume(throwing: BleError.disconnected)
        takePendingSend()?.resume(throwing: BleError.disconnected)
        setState(error == nil ? .disconnected : .error)
    }
}

// MARK: - CBPeripheralDelegate

extension BleTransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            takePendingStage()?.resume(throwing: BleError.connectFailed(error.localizedDescription))
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            takePendingStage()?.resume(throwing: BleError.noUsableCharacteristics)
            return
        }
        // Probe every service and pick the best write/notify pair once they have
        // all reported back — a known ELM327 service wins over a generic one.
        lock.withLock { pendingServiceCount = services.count }
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let characteristics = error == nil ? (service.characteristics ?? []) : []
        let write = characteristics.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
        let notify = characteristics.first {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        let isKnown = Self.knownServiceUUIDs.contains(service.uuid)

        enum Outcome { case pending, ready, noneUsable }
        var outcome = Outcome.pending

        let stage = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            if let write, let notify, writeCharacteristic == nil || (isKnown && !selectedServiceIsKnown) {
                writeCharacteristic = write
                notifyCharacteristic = notify
                selectedServiceIsKnown = isKnown
            }
            pendingServiceCount = max(pendingServiceCount - 1, 0)
            guard pendingServiceCount == 0, let c = pendingStage else { return nil }
            outcome = writeCharacteristic == nil ? .noneUsable : .ready
            pendingStage = nil
            return c
        }

        switch outcome {
        case .pending: break
        case .ready: stage?.resume()
        case .noneUsable: stage?.resume(throwing: BleError.noUsableCharacteristics)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value,
              let text = String(data: value, encoding: .ascii) else { return }

        let complete = lock.withLock { () -> String? in
            guard pendingSend != nil else { return nil }
            responseBuffer.append(text)
            guard responseBuffer.contains(ELM_PROMPT) else { return nil }
            let full = responseBuffer
            responseBuffer = ""
            return full
        }
        guard let complete else { return }
        takePendingSend()?.resume(returning: complete)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let error else { return }
        takePendingSend()?.resume(throwing: error)
    }
}

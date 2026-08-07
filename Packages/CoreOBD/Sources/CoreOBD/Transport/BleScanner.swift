import Combine
import CoreBluetooth
import CoreDomain
import Foundation

/// Discovers nearby BLE OBD adapters so the user can pick one to pair with.
///
/// iOS gives no MAC address, so `ObdDevice.address` carries the
/// `CBPeripheral.identifier` UUID — stable for this device+app install, and the
/// value `BleTransport` uses to reconnect via `retrievePeripherals(withIdentifiers:)`.
///
/// Advertisements arrive continuously while scanning; results are deduplicated by
/// identifier and republished on the main queue for SwiftUI.
public final class BleScanner: NSObject, @unchecked Sendable {

    /// A discovered adapter plus its signal strength, for sorting by proximity.
    public struct Discovery: Sendable, Identifiable, Equatable {
        public let device: ObdDevice
        public let rssi: Int
        public var id: String { device.address }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.fmz.ioniqtelemetry.ble.scan", qos: .userInitiated)
    private var centralManager: CBCentralManager!
    private var discovered: [String: Discovery] = [:]
    private var wantsScan = false

    private let _devices = CurrentValueSubject<[Discovery], Never>([])
    private let _isScanning = CurrentValueSubject<Bool, Never>(false)

    /// Adapters seen so far, strongest signal first.
    public var devices: AnyPublisher<[Discovery], Never> {
        _devices.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    public var isScanning: AnyPublisher<Bool, Never> {
        _isScanning.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Non-nil when the radio is in a state that blocks scanning.
    ///
    /// Written on the CoreBluetooth queue (centralManagerDidUpdateState) and read on
    /// the main thread by the UI — a plain stored property would race. Both sides go
    /// through the lock.
    private var _unavailableReason: String?
    public var unavailableReason: String? {
        lock.withLock { _unavailableReason }
    }

    public override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - Control

    /// Begins scanning. Safe to call before Bluetooth finishes powering on — the
    /// scan starts as soon as the radio is ready.
    public func start() {
        lock.withLock {
            wantsScan = true
            discovered.removeAll()
        }
        _devices.send([])
        guard centralManager.state == .poweredOn else { return }
        beginScan()
    }

    public func stop() {
        lock.withLock { wantsScan = false }
        centralManager.stopScan()
        _isScanning.send(false)
    }

    private func beginScan() {
        // Nil services: ELM327 clones routinely omit their service UUIDs from the
        // advertisement, so filtering by UUID would hide most adapters.
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        _isScanning.send(true)
    }

    /// Adapters iOS already knows about — shown immediately, before any scan
    /// results arrive, so a previously paired adapter is reconnectable offline.
    public func knownAdapters(identifiers: [String]) -> [ObdDevice] {
        let uuids = identifiers.compactMap(UUID.init(uuidString:))
        guard !uuids.isEmpty else { return [] }
        return centralManager.retrievePeripherals(withIdentifiers: uuids).map {
            ObdDevice(
                name: $0.name ?? "OBD Adapter",
                address: $0.identifier.uuidString,
                type: .ble,
                isPaired: true
            )
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleScanner: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            lock.withLock { _unavailableReason = nil }
            if lock.withLock({ wantsScan }) { beginScan() }
        case .poweredOff:
            lock.withLock { _unavailableReason = "Bluetooth is turned off." }
            _isScanning.send(false)
        case .unauthorized:
            lock.withLock { _unavailableReason = "Bluetooth permission was denied for this app." }
            _isScanning.send(false)
        case .unsupported:
            lock.withLock { _unavailableReason = "This device does not support Bluetooth LE." }
            _isScanning.send(false)
        default:
            lock.withLock { _unavailableReason = nil }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Unnamed peripherals are almost never OBD adapters and would flood the list.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advertisedName, !name.isEmpty else { return }

        let discovery = Discovery(
            device: ObdDevice(name: name, address: peripheral.identifier.uuidString, type: .ble),
            rssi: RSSI.intValue
        )

        let snapshot = lock.withLock { () -> [Discovery] in
            discovered[discovery.id] = discovery
            return discovered.values.sorted { $0.rssi > $1.rssi }
        }
        _devices.send(snapshot)
    }
}

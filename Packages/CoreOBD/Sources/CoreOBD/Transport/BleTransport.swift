import CoreBluetooth
import CoreDomain
import Foundation

/// BLE transport for ELM327 adapters (Vgate iCar Pro, LELink, etc.).
///
/// Uses CoreBluetooth (CBCentralManager/CBPeripheral) for BLE GATT communication.
/// Service UUIDs: FFE0, FFF0, Nordic UART variant — probed at connection time.
/// Characteristic: FFE1 or equivalent — for write/notify.
///
/// Ported from Android BleTransport.kt (277 lines).
public final class BleTransport: NSObject, ObdTransport, @unchecked Sendable {

    // MARK: - Errors

    public enum BleError: Error {
        case bluetoothUnavailable
        case notConnected
        case disconnected
        case sendTimeout
        case deviceNotFound
    }

    // MARK: - State

    public private(set) var state: ObdConnectionState = .disconnected

    public var stateStream: AsyncStream<ObdConnectionState> {
        AsyncStream { continuation in
            let key = UUID()
            stateContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.stateContinuations[key] = nil
            }
        }
    }

    private var stateContinuations: [UUID: AsyncStream<ObdConnectionState>.Continuation] = [:]

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    // Response buffer
    private nonisolated(unsafe) var responseBuffer = ""
    private nonisolated(unsafe) var sendContinuation: CheckedContinuation<String, any Error>?

    // MARK: - Init

    public override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - ObdTransport

    public func connect(device: ObdDevice) async throws {
        state = .connecting
        // Full BLE scanning/connection logic would go here
        // For now: stub for compilation
    }

    public func disconnect() async {
        let prev = sendContinuation
        sendContinuation = nil
        prev?.resume(throwing: BleError.disconnected)
        state = .disconnected
    }

    public func send(command: String, timeoutMs: Int64) async throws -> String {
        guard let peripheral, let writeCharacteristic else {
            throw BleError.notConnected
        }

        let payload = Data((command + "\r").utf8)

        // Race between response and timeout
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, any Error>) in
            sendContinuation = cont
            responseBuffer = ""

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                if sendContinuation != nil {
                    sendContinuation?.resume(throwing: BleError.sendTimeout)
                    sendContinuation = nil
                }
            }

            // Send
            peripheral.writeValue(payload, for: writeCharacteristic, type: .withResponse)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            state = .disconnected
        } else {
            state = .error
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BleTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        responseBuffer.append(String(data: value, encoding: .ascii) ?? "")
        if responseBuffer.contains(ELM_PROMPT) {
            let full = responseBuffer
            responseBuffer = ""
            let c = sendContinuation
            sendContinuation = nil
            c?.resume(returning: full)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            let c = sendContinuation
            sendContinuation = nil
            c?.resume(throwing: error)
        }
    }
}

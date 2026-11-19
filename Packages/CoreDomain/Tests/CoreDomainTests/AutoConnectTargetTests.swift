import CoreDomain
import Foundation
import Testing

/// The BLE/WiFi split decides whether auto-connect can do anything at all: only a
/// BLE adapter is stored as a peripheral UUID, and only a UUID can be handed to
/// Core Bluetooth as a standing connect.
@Suite("AutoConnectTarget adapter classification")
struct AutoConnectTargetTests {

    @Test("A BLE adapter's saved UUID becomes the identifier to arm")
    func bleIdentifierIsParsed() {
        let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        #expect(AutoConnectTarget.peripheralIdentifier(forSavedAddress: uuid.uuidString) == uuid)
        #expect(AutoConnectTarget.supportsWakeUp(uuid.uuidString))
    }

    @Test("A WiFi adapter is never armed")
    func wifiAddressIsRejected() {
        #expect(AutoConnectTarget.peripheralIdentifier(forSavedAddress: "192.168.0.10:35000") == nil)
        #expect(!AutoConnectTarget.supportsWakeUp("192.168.0.10:35000"))
        #expect(!AutoConnectTarget.supportsWakeUp("elm327.local"))
    }

    @Test("No saved adapter means nothing to arm")
    func emptyAddressIsRejected() {
        #expect(AutoConnectTarget.peripheralIdentifier(forSavedAddress: nil) == nil)
        #expect(AutoConnectTarget.peripheralIdentifier(forSavedAddress: "") == nil)
        #expect(!AutoConnectTarget.supportsWakeUp(nil))
    }
}

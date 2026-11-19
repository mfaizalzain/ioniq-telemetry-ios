import Foundation

/// Which saved adapters iOS can be asked to wake the app for.
///
/// A BLE adapter is stored as its `CBPeripheral.identifier` UUID, which is what
/// Core Bluetooth needs to hold a standing connect. A WiFi ELM327 is stored as a
/// host or `host:port` — reachable only while the app is running, so trying to
/// "arm" one would be a promise the platform cannot keep. Keeping the decision in
/// one place means the transport factory, the auto-connect arming and the Settings
/// copy can never disagree about which kind of adapter is saved.
public enum AutoConnectTarget {

    /// The peripheral identifier to arm for a saved adapter address, or nil when
    /// this adapter cannot be woken automatically.
    public static func peripheralIdentifier(forSavedAddress address: String?) -> UUID? {
        guard let address, !address.isEmpty else { return nil }
        return UUID(uuidString: address)
    }

    /// True when the saved adapter supports unattended wake-up.
    public static func supportsWakeUp(_ address: String?) -> Bool {
        peripheralIdentifier(forSavedAddress: address) != nil
    }
}

import Foundation
import Security

/// Keychain-backed storage for the user's API credentials.
///
/// These are the user's own billable keys (Google Cloud, OpenRouteService, Gemini,
/// Open Charge Map). In UserDefaults they sat in a plaintext plist inside the app
/// container, which is readable from an unencrypted device backup and from a
/// jailbroken device. The Keychain is encrypted at rest and its contents are not
/// carried in an unencrypted backup.
///
/// This is deliberately *not* a statement about the app's own JSON backup export,
/// which still contains the keys on purpose — losing them on restore is the most
/// annoying possible outcome, and that file is the user's to protect.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than `WhenUnlocked`: occupancy alerts
/// and route replanning run during a drive with the phone locked, and they need the
/// key to make their calls.
enum KeychainStore {

    /// Namespaced so these entries can't collide with anything else the app stores.
    private static let service = "com.fmz.IoniqTelemetry.apikeys"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Writes, or deletes the entry entirely when `value` is nil or empty — so a
    /// cleared key field leaves nothing behind.
    ///
    /// Returns success only when the write actually landed. The old version dropped
    /// every non-`errSecItemNotFound` status, so a key the user just typed could
    /// silently fail to persist (locked device, `errSecInteractionNotAllowed`) and
    /// come back missing on the next launch. Callers surface the failure rather than
    /// pretending the write happened.
    @discardableResult
    static func write(_ value: String?, account: String) -> Result<Void, KeychainError> {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
                ? .success(())
                : .failure(KeychainError(status: status, operation: "delete"))
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Update first; SecItemAdd fails with errSecDuplicateItem on an existing entry.
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
            return addStatus == errSecSuccess
                ? .success(())
                : .failure(KeychainError(status: addStatus, operation: "add"))
        }
        return status == errSecSuccess
            ? .success(())
            : .failure(KeychainError(status: status, operation: "update"))
    }
}

enum KeychainError: Error, CustomStringConvertible {
    case osStatus(OSStatus, operation: String)

    init(status: OSStatus, operation: String) {
        self = .osStatus(status, operation: operation)
    }

    var description: String {
        if case .osStatus(let status, let operation) = self {
            return "Keychain \(operation) failed with OSStatus \(status)"
        }
        return "Keychain operation failed"
    }
}

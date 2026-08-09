import Foundation
import Security

/// A minimal Keychain wrapper for a single secret string (the session token).
/// The Keychain — not UserDefaults — is the right home for a bearer token: it
/// is encrypted at rest, excluded from device backups by the accessibility
/// class below, and not readable from a plist dump. This is the docs/10 (G9)
/// hardening item.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available after the
/// first unlock following a boot (so a relaunch/background refresh can read
/// it) but never migrated to a new device via encrypted backup — a stolen
/// backup carries no session token.
struct KeychainStore {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) {
        let data = Data(value.utf8)
        // Upsert: try to update an existing item, else add a fresh one.
        let updated = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

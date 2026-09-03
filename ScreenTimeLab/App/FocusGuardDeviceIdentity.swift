import Foundation
import Security

enum FocusGuardDeviceIdentityError: Error {
    case keychain(OSStatus)
    case invalidStoredIdentifier
}

/// Stable per-installation device identity. It is deliberately separate from
/// Screen Time tokens and from the account identifier.
enum FocusGuardDeviceIdentity {
    private static let service = "com.focusguard.apple.device"
    private static let account = "stable-device-id"

    static func loadOrCreate() throws -> UUID {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8),
                  let identifier = UUID(uuidString: value) else {
                throw FocusGuardDeviceIdentityError.invalidStoredIdentifier
            }
            return identifier
        }
        guard status == errSecItemNotFound else {
            throw FocusGuardDeviceIdentityError.keychain(status)
        }

        let identifier = UUID()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(identifier.uuidString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // A concurrent launch won the insert. Read its value rather than
            // creating a second identity.
            return try loadOrCreate()
        }
        guard addStatus == errSecSuccess else {
            throw FocusGuardDeviceIdentityError.keychain(addStatus)
        }
        return identifier
    }
}

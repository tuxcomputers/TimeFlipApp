import Foundation
import Security

enum TimeFlipDevicePasswordStoreError: Error {
    case keychain(OSStatus)
}

/// Keychain-backed storage for the TimeFlip device password, kept separate from the plaintext
/// preferences file so the rotated password isn't stored in the clear.
final class TimeFlipDevicePasswordStore: @unchecked Sendable {
    static let shared = TimeFlipDevicePasswordStore()

    private let service: String
    private let account: String

    init(
        service: String = "\(AppIdentifiers.subsystem).device.password",
        account: String = "timeflip-device"
    ) {
        self.service = service
        self.account = account
    }

    func loadPassword() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TimeFlipDevicePasswordStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func savePassword(_ password: String?) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                return
            }
            throw TimeFlipDevicePasswordStoreError.keychain(status)
        }

        let data = Data(password.utf8)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw TimeFlipDevicePasswordStoreError.keychain(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw TimeFlipDevicePasswordStoreError.keychain(addStatus)
        }
    }
}

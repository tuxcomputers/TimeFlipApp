#if canImport(Security)
import Foundation
import Security

/// The login Keychain, as a `SecretStore`.
///
/// **This is the `SecItem` code that used to be in both `DevicePINStore` and `GoogleTokenStore`**, written twice
/// with the same four queries and the same three status rules. Candidate 3 of
/// `docs/architecture-review-2026-09.md`; what those two keep is their own naming and their own meaning.
///
/// **Per user and per machine**, which falls out of the Keychain rather than being arranged: a login Keychain
/// belongs to one account on one Mac, so a database copied to a second machine arrives with no secret and asks for
/// a sign-in or meets a cube on the vendor default, which is the honest answer in both cases.
///
/// **Still not unit tested, and still for the right reason.** CI has no Keychain and a test that reached the
/// developer's own would be writing to the machine it runs on. The difference candidate 3 makes is that this is now
/// the *only* thing in that position: everything above it takes a `SecretStore` and is tested against an in-memory
/// one, where before the untestable half and the testable half were the same file.
package struct KeychainSecretStore: SecretStore {
    package init() {}

    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// **Add-then-update rather than delete-then-add.** Deleting first leaves a window with no secret at all, and a
    /// crash inside it would lose a working credential to save a new one.
    ///
    /// **Read back before answering `true`.** It matters most for the cube's PIN: what follows a `true` is a cube
    /// being left on that PIN, so a write believed on the strength of a status code alone would be a cube nobody
    /// can log into.
    @discardableResult
    package func store(service: String, account: String, label: String, secret: String) -> Bool {
        let query = query(service: service, account: account)
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // Available once the Mac has been unlocked, and never synced to iCloud: this secret is one machine's,
            // and a copy of it elsewhere is a copy of the ability to act with it.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        return lookUp(service: service, account: account) == .found(secret)
    }

    package func lookUp(service: String, account: String) -> SecretLookup {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            // A success that yielded something unreadable is not an absent secret either. `errSecDecode` names the
            // shape of the problem: the item is there and its contents make no sense.
            return .unavailable(errSecDecode)
        }
        return .found(secret)
    }

    @discardableResult
    package func clear(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
#endif

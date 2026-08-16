import Foundation
import Security

/// Where the refresh token lives: the login Keychain, and nowhere else.
///
/// **Not the database.** Every other thing this app knows is in SQLite, and the first design rule says the database is
/// the source of truth -- but that rule is about facts the app reasons over, and a refresh token is not one. It is a
/// credential that can act on somebody's Google account until it is revoked, the database file is readable by anything
/// running as that user, and the app's own privacy policy says the tokens are Keychain-held. So this is the deliberate
/// exception, and it is the same one the archive made (`Archive/TimeFlipApp/GoogleOAuthKeychainStore.swift`).
///
/// **Per user and per machine**, which falls out of the Keychain rather than being arranged: a login Keychain belongs
/// to one account on one Mac, so a database copied to a second machine arrives with no token and asks for a sign-in,
/// which is the right answer.
enum GoogleTokenStore {
    /// Keyed by the bundle identifier so a developer build and a release build do not fight over one item.
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "au.com.tux.facet") + ".google"
    }

    private static let account = "refresh-token"

    /// Stores the token, replacing whatever was there.
    ///
    /// **Add-then-update rather than delete-then-add.** Deleting first leaves a window with no token at all, and a
    /// crash inside it would lose a working connection to save a new one.
    @discardableResult
    static func save(refreshToken: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(refreshToken.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        // Available once the Mac has been unlocked, and never synced to iCloud: this token is one machine's, and a
        // copy of it appearing on another device is a copy of the ability to act on the account.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// The stored token, or `nil` when there is none.
    static func refreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Forgets it, which is half of signing out. The other half is the identity in the `google_account` row.
    ///
    /// **`true` when there was nothing to delete**, because the caller asked for there to be no token and there is
    /// none. Reporting failure would make a second sign-out look broken.
    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

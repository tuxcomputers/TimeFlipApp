import Foundation
import Security

/// Where a cube's PIN lives: the login Keychain, and nowhere else in an ordinary build.
///
/// **This is the store the previous app had and this one did not**, and its absence is the whole reason a release
/// build used to leave every cube on the public vendor default: setting a PIN is only safe once there is somewhere
/// durable to keep it, and a PIN the app cannot write down locks the cube out of every app including this one.
/// `Archive/TimeFlipApp/TimeFlipDevicePasswordStore.swift` is the same decision, kept for the same reason.
///
/// **Not the database, for the reason `GoogleTokenStore` is not.** The first design rule says the database is the
/// source of truth, and that rule is about facts the app reasons over; a credential is not one. The database file is
/// readable by anything running as this user, it is switched between production and test
/// (`scripts/switch-database.sh`), and a test run rebuilds it from the DDL -- and a cube does not know which database
/// is in play, so a PIN kept in one is a PIN a database swap loses.
///
/// **Per user and per machine**, which falls out of the Keychain rather than being arranged: a login Keychain belongs
/// to one account on one Mac. A cube carried to a second machine is met by an app that knows only the vendor default,
/// which is the honest answer -- and the recovery is the one the vendor gave it, taking the batteries out.
///
/// **Deliberately not unit tested**, as `GoogleTokenStore` is not: CI has no Keychain, and a test that reached the
/// developer's own would be writing to the machine it runs on. What is tested is every decision around it
/// (`DevicePINRules`, `DevicePINSource`), and what says the item itself works is a device run.
enum DevicePINStore {
    /// Keyed by the bundle identifier so a developer build and a release build do not fight over one item, and
    /// suffixed so the cube's PIN and the Google refresh token are two items rather than one overwritten by turns.
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "au.com.tux.facet") + ".device"
    }

    private static let account = "device-pin"

    /// Stores the PIN, replacing whatever was there. Answers whether the Keychain now holds it.
    ///
    /// **Add-then-update rather than delete-then-add**, matching `GoogleTokenStore`: deleting first leaves a window
    /// with no PIN at all, and a crash inside it would lose the only record of a cube's credential.
    ///
    /// **Read back before it answers `true`**, which is `CLAUDE.md`'s rule about a write that reports success and did
    /// not happen. It matters more here than anywhere: what follows a `true` is a cube being left on this PIN, so a
    /// write believed on the strength of a status code would be a cube nobody can log into.
    @discardableResult
    static func save(pin: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(pin.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // Available once the Mac has been unlocked, and never synced to iCloud: this PIN is one machine's, and a
            // copy of it elsewhere is a copy of the ability to take the cube over.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return false }
        return lookUp() == .found(pin)
    }

    /// What the Keychain said when asked for the PIN. **Three answers, not two**, for `GoogleTokenStore.Lookup`'s
    /// reason: "there is no PIN" and "the Keychain would not answer" have opposite remedies, and collapsing them
    /// would have the app rotate a cube that already has a perfectly good PIN it simply could not read.
    enum Lookup: Equatable {
        case found(String)
        /// `errSecItemNotFound`: nothing is stored, which is what a cube nobody has paired yet looks like.
        case missing
        /// Any other status. The item may be sitting there perfectly well; this process could not read it.
        case unavailable(OSStatus)
    }

    static func lookUp() -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = item as? Data, let pin = String(data: data, encoding: .utf8) else {
            // A success that yielded something unreadable is not an absent PIN either. `errSecDecode` names the shape
            // of the problem: the item is there and its contents make no sense.
            return .unavailable(errSecDecode)
        }
        return .found(pin)
    }

    /// The stored PIN, or `nil` when there is none **or when it could not be read**.
    ///
    /// Kept for the callers that cannot act on the difference -- presenting a PIN is one, there being nothing to
    /// present either way. Anything deciding whether to *write* asks `lookUp`, so that "we could not check" does not
    /// reach it as "there is nothing there".
    static func pin() -> String? {
        guard case let .found(pin) = lookUp() else { return nil }
        return pin
    }

    /// Forgets it. **`true` when there was nothing to delete**, for `GoogleTokenStore.clear`'s reason: the caller
    /// asked for there to be no PIN and there is none.
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

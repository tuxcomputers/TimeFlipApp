import Foundation

/// Where the refresh token lives: the login Keychain on a Mac, the login keyring on Linux, and nowhere else.
///
/// **Not the database.** Every other thing this app knows is in SQLite, and the first design rule says the database
/// is the source of truth -- but that rule is about facts the app reasons over, and a refresh token is not one. It
/// is a credential that can act on somebody's Google account until it is revoked, the database file is readable by
/// anything running as that user, and the app's own privacy policy says the tokens are Keychain-held. So this is the
/// deliberate exception, and it is the same one the archive made (`GoogleOAuthKeychainStore.swift`).
///
/// **Per user and per machine**, which falls out of the store rather than being arranged: a login Keychain belongs
/// to one account on one Mac, so a database copied to a second machine arrives with no token and asks for a
/// sign-in, which is the right answer.
///
/// **What is left here after candidate 3 is the naming and the meaning.** The `SecItem` calls and the `secret-tool`
/// branch have gone to `KeychainSecretStore` and `SecretToolStore`, which is where the duplication was: this file
/// and `DevicePINStore` held the same four queries, the same three status rules and the same three-case answer
/// type, written twice with the comment on `unavailable` copied word for word.
package struct GoogleTokenStore {
    private let secrets: SecretStore

    /// **No default, deliberately.** A default would be this type choosing an implementation, which is the thing
    /// the platform-blindness rule forbids; requiring it is what pushes the choice out to the composition root.
    package init(secrets: SecretStore) {
        self.secrets = secrets
    }

    /// Keyed by the bundle identifier so a developer build and a release build do not fight over one item.
    /// Internal rather than private so a test can address the same item this store does: the value depends on
    /// `Bundle.main`, which is not the app bundle under `swift test`, so a literal here would be a different item.
    var service: String {
        (Bundle.main.bundleIdentifier ?? "au.com.tux.facet") + ".google"
    }

    let account = "refresh-token"

    /// Stores the token, replacing whatever was there.
    @discardableResult
    package func save(refreshToken: String) -> Bool {
        secrets.store(
            service: service,
            account: account,
            label: "Facet: Google refresh token",
            secret: refreshToken
        )
    }

    /// What the store said when asked for the token. **Three answers, not two.**
    ///
    /// "There is no token" and "the store would not answer" are different facts with opposite remedies: the first is
    /// fixed by signing in, the second by working out why the item cannot be read, and offering a sign-in for the
    /// second throws away a working connection to solve a problem it does not have.
    ///
    /// This used to be one `guard` that returned `nil` for both, which is the "nothing fails silently" rule broken
    /// in the place it costs most: `.missing` and `.unavailable` arrived at the App tab as the same words.
    package func lookUp() -> SecretLookup {
        secrets.lookUp(service: service, account: account)
    }

    /// The stored token, or `nil` when there is none or it could not be read. For the callers that cannot act on
    /// the difference.
    package func refreshToken() -> String? {
        guard case let .found(token) = lookUp() else { return nil }
        return token
    }

    /// Forgets it. **`true` when there was nothing to delete**: the caller asked for there to be no token, and
    /// there is none.
    @discardableResult
    package func clear() -> Bool {
        secrets.clear(service: service, account: account)
    }
}

import Foundation

/// Where a cube's PIN lives: the login Keychain on a Mac, the login keyring on Linux, and nowhere else in an
/// ordinary build.
///
/// **This is the store the previous app had and this one did not**, and its absence is the whole reason a release
/// build used to leave every cube on the public vendor default: setting a PIN is only safe once there is somewhere
/// durable to keep it, and a PIN the app cannot write down locks the cube out of every app including this one.
/// `TimeFlipDevicePasswordStore.swift` is the same decision, kept for the same reason.
///
/// **Not the database, for the reason `GoogleTokenStore` is not.** The first design rule says the database is the
/// source of truth, and that rule is about facts the app reasons over; a credential is not one. The database file is
/// readable by anything running as this user, it is switched between production and test
/// (`scripts/switch-database.sh`), and a test run rebuilds it from the DDL -- and a cube does not know which database
/// is in play, so a PIN kept in one is a PIN a database swap loses.
///
/// **Per user and per machine**, which falls out of the store rather than being arranged: a login Keychain belongs
/// to one account on one Mac. A cube carried to a second machine is met by an app that knows only the vendor
/// default, which is the honest answer -- and the recovery is the one the vendor gave it, taking the batteries out.
///
/// **What is left here after candidate 3 is the naming and the meaning**, which is all this ever really was. The
/// `SecItem` calls and the `secret-tool` branch have gone to `KeychainSecretStore` and `SecretToolStore`, so this is
/// now testable against an in-memory store where before its own doc had to say it was "deliberately not unit
/// tested". What cannot be tested is the Keychain itself, and that is one file rather than this one.
package struct DevicePINStore {
    private let secrets: SecretStore

    package init(secrets: SecretStore = SecretStores.platform) {
        self.secrets = secrets
    }

    /// Keyed by the bundle identifier so two builds do not fight over one item, and suffixed so the cube's PIN and
    /// the Google refresh token are two items rather than one overwritten by turns.
    /// Internal rather than private so a test can address the same item this store does: the value depends on
    /// `Bundle.main`, which is not the app bundle under `swift test`, so a literal here would be a different item.
    var service: String {
        (Bundle.main.bundleIdentifier ?? "au.com.tux.facet") + ".device"
    }

    let account = "device-pin"

    /// Stores the PIN, replacing whatever was there. Answers whether the store now holds it.
    ///
    /// The read-back that makes a `true` mean something is the store's, and both real ones do it. It matters more
    /// here than anywhere: what follows a `true` is a cube being left on this PIN.
    @discardableResult
    package func save(pin: String) -> Bool {
        secrets.store(service: service, account: account, label: "Facet: TimeFlip cube PIN", secret: pin)
    }

    /// What the store said when asked for the PIN. **Three answers, not two**: "there is no PIN" and "the store
    /// would not answer" have opposite remedies, and collapsing them would have the app rotate a cube that already
    /// has a perfectly good PIN it simply could not read.
    package func lookUp() -> SecretLookup {
        secrets.lookUp(service: service, account: account)
    }

    /// The stored PIN, or `nil` when there is none **or when it could not be read**.
    ///
    /// Kept for the callers that cannot act on the difference -- presenting a PIN is one, there being nothing to
    /// present either way. Anything deciding whether to *write* asks `lookUp`, so that "we could not check" does not
    /// reach it as "there is nothing there".
    package func pin() -> String? {
        guard case let .found(pin) = lookUp() else { return nil }
        return pin
    }

    /// Forgets it. **`true` when there was nothing to delete**: the caller asked for there to be no PIN and there
    /// is none.
    @discardableResult
    package func clear() -> Bool {
        secrets.clear(service: service, account: account)
    }
}

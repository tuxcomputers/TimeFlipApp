import Foundation

/// Which PINs pairing presents to a cube, and whether the cube that answered needs a PIN of its own.
///
/// The whole policy, in one place, because it was three expressions inside a closure in
/// `ApplicationDelegate.onDeviceSelectedForPairing` -- unreachable by any test, which is how it came
/// to guess four passwords in a dev build and rotate the PIN of a cube that had done nothing to
/// deserve it.
///
/// **Pairing is the only place a password is guessed at all.** Connecting to a device already paired
/// presents the stored password and fails if it is rejected, because being paired means the app is
/// meant to know the answer (see `ApplicationDelegate.startDeviceEvents`).
enum PairingPasswordRules {

    /// The two candidates, in order: the vendor default, then the stored password.
    ///
    /// Two, always, and the same two in every build. A developer build differs in exactly two narrow
    /// ways, and neither adds a password to try: **where** the current PIN is stored (`config.json`'s
    /// `PIN` rather than the Keychain -- see `AppState.loadDevicePassword`), and **what** a new PIN is
    /// set to (the fixed `DeveloperMode.devicePassword` rather than random digits -- see
    /// `TimeFlipBLEDevice.rotateDevicePassword`).
    ///
    /// That constant can still arrive here as `storedPassword`, and legitimately: when `config.json`
    /// names no PIN it stands in as the stored one, so a dev build can reach a cube on either of the two
    /// values a dev cube is ever left on. What it must never be is a candidate *in addition* to a real
    /// stored PIN, which is what it was until 2026-08-11 -- a third guess that let a dev build into a
    /// cube whose PIN the app had no record of, and made "the stored PIN" mean two different things.
    ///
    /// They are the two states a cube in front of this app can be in:
    ///
    /// - On the **vendor default**: new to this app, or power-cycled, since pulling the battery
    ///   reverts the PIN to `000000` (measured 2026-08-11).
    /// - On the **stored password**: the same cube, paired before and since forgotten.
    ///
    /// If neither is accepted, pairing fails. There is deliberately no third guess: a cube on some
    /// other PIN is one neither this app nor its user can name, and trying to find it by search would
    /// be a lockout dressed up as a feature.
    ///
    /// Deduplicated, so a stored password that *is* the default is presented once rather than twice --
    /// a second attempt would cost a whole connect round trip to learn nothing.
    static func candidates(storedPassword: String) -> [String] {
        let ordered = [TimeFlipConstants.defaultPassword, storedPassword]
        var seen: Set<String> = []
        return ordered.filter { seen.insert($0).inserted }
    }

    /// Whether a cube reached with `passwordUsed` should be given a PIN of its own.
    ///
    /// Only the cube that answered to the vendor default. One that answered to the stored password
    /// already holds the PIN on record, so rotating it would change a device PIN nobody asked to
    /// change and overwrite a stored password that was already correct; the pairing is simply
    /// remembered again instead.
    static func rotatesPassword(passwordUsed: String) -> Bool {
        passwordUsed == TimeFlipConstants.defaultPassword
    }
}

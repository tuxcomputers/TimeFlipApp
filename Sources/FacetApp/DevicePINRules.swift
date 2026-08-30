import Foundation

/// When a cube's PIN is changed, what it is changed to, and where the answer is kept.
///
/// **Why a cube's PIN is changed at all**: the vendor default is public and printed in the protocol spec, so a cube
/// left on it is one that anybody within a few metres can take over. The archive rotated on pairing, emulating the
/// vendor's own app, and the reasoning survives inspection.
///
/// **The decisions are here and the storage is not** (`DevicePINStore`, `DevicePINSource`), which is the split every
/// rules type in this app keeps: what should happen can be tested with no Keychain, no file and no cube, and all
/// three of those are things `swift test` does not have.
enum DevicePINRules {
    /// Whether a cube that let the app in on `accepted` should be given a PIN of its own.
    ///
    /// **The vendor default and nothing else.** A cube on any other PIN is on one this app put there and wrote down,
    /// so rotating it again would spend a command and a second login to replace a known value with another known
    /// value. A cube on `000000` is either new here or has had its batteries out (measured 2026-08-11), and both are
    /// the state this exists to get it out of.
    ///
    /// **Massaged from `DeviceLoginRules.rotation`**, which asked whether the cube was already on the PIN this build
    /// sets. That question had a right answer only while the target was a fixed constant: a production build now
    /// picks a fresh random PIN each time, so "is it already on the target" would be false for ever and rotate a
    /// perfectly good cube on every connect.
    static func rotates(from accepted: String) -> Bool {
        accepted == DeviceLoginRules.defaultPIN
    }

    /// The PIN a cube is rotated **to**, which is where the developer gate is asked and the only place it matters.
    ///
    /// - **A developer build sets `123456`**, fixed rather than random so a dev cube's PIN is always known and
    ///   typeable if anything goes wrong. It is the archive's own dev PIN, so the hardware this app is tested against
    ///   is very likely already sitting on it.
    /// - **Any other build sets six random digits**, which is the whole point of the exercise: a PIN nobody can guess
    ///   is the only kind worth setting, and it is only safe to set one once there is somewhere durable to keep it.
    ///   That is `DevicePINStore`, and it is why this build can do what the last one would not.
    ///
    /// **Never the vendor default**, however the digits fall: rotating a cube from `000000` to `000000` is a command
    /// and a confirming login spent to change nothing, and it would leave the cube exactly as exposed as it was.
    static func target(isDeveloperMode: Bool = DeveloperMode.isDeveloperMode) -> String {
        var generator = SystemRandomNumberGenerator()
        return target(isDeveloperMode: isDeveloperMode, using: &generator)
    }

    /// The same, against a generator a test can hand in, so "six digits and never the default" is checkable rather
    /// than asserted about a value nobody can predict.
    static func target<G: RandomNumberGenerator>(isDeveloperMode: Bool, using generator: inout G) -> String {
        guard !isDeveloperMode else { return developerPIN }
        var pin = randomPIN(using: &generator)
        // **A loop rather than one draw**, for the one draw in a million that comes up as the vendor default. It
        // cannot spin for long, there being 999,999 other answers.
        while pin == DeviceLoginRules.defaultPIN { pin = randomPIN(using: &generator) }
        return pin
    }

    /// The one PIN a developer build ever puts on a cube.
    ///
    /// **It also stands in as the stored PIN when neither store has one** (`DevicePINSource.stored`), which is the
    /// other half of it being fixed: with nothing written down, a dev build can still reach a cube on either
    /// `000000` or this, the only two values a dev cube is ever left on.
    ///
    /// **A stand-in for a stored PIN, never a candidate alongside one.** That distinction is the archive's and it
    /// cost it a real bug: offered as an extra guess it let a dev build into a cube whose PIN the app had no record
    /// of, and made "the stored PIN" mean two different things (fixed 2026-08-11).
    static let developerPIN = "123456"

    /// Where a rotated PIN is written, which is not the same question in the two builds.
    ///
    /// - **A developer build writes both**: the Keychain, and `config.json` beside it. The file is what makes a dev
    ///   cube's PIN readable by a person -- for a scripted check, or for whoever has to log into it by hand -- and
    ///   the Keychain is what a production build will have, so writing both keeps the path a dev build exercises the
    ///   same path a release build takes.
    /// - **Any other build writes the Keychain**, and the file only when the Keychain would not take it. That
    ///   fallback is what makes a failed Keychain write recoverable rather than a cube nobody can log into again:
    ///   the PIN is on the hardware either way, so the only question is whether this app can still name it.
    static func destinations(isDeveloperMode: Bool) -> [Destination] {
        isDeveloperMode ? [.keychain, .configFile] : [.keychain]
    }

    /// Where a PIN can be kept.
    enum Destination: Equatable {
        case keychain
        case configFile
    }

    /// The order the stored PINs are presented in, given what each store holds.
    ///
    /// **The file goes first when it has one, in both builds**, which reads backwards for a production build and is
    /// the point of the fallback: in a release build the file only ever holds a PIN because the Keychain refused
    /// one, so the file's is the *newer* of the two and the Keychain's is what the cube was called before it. A
    /// developer build reads the same order for a different reason -- the file is the one a person edits, so it is
    /// the one that should win.
    ///
    /// **Deduplicated**, so the ordinary case where both stores agree presents one PIN and not the same PIN twice.
    /// Each candidate costs a whole connect (`BluetoothRadio`), which is a long way to go to learn nothing.
    ///
    /// **Three candidates are possible now, where there were only ever two.** That is the disagreement case and only
    /// that case: the two stores hold different PINs, which happens after a Keychain write that failed, and the app
    /// genuinely does not know which of the two the cube is on. `DevicePINSource.reconcile` is what puts the two
    /// back together the next time one of them is proved.
    static func readOrder(configFile: String?, keychain: String?, isDeveloperMode: Bool) -> [String] {
        var seen: Set<String> = []
        var order = [configFile, keychain]
            .compactMap { $0 }
            .filter { DeviceLoginRules.isWellFormed($0) && seen.insert($0).inserted }
        // The stand-in, and only with nothing written down at all: see `developerPIN`.
        if order.isEmpty, isDeveloperMode { order = [developerPIN] }
        return order
    }

    /// What to do once the cube has proved which PIN it is on, given what the two stores hold.
    ///
    /// **This is the self-healing half of the fallback**, and it can only run on an answer from the cube: a PIN in a
    /// file and a PIN in the Keychain disagreeing says nothing about which one the hardware took, and promoting the
    /// wrong one would overwrite the app's only record of the right one. So nothing moves until a login proves it.
    ///
    /// - The accepted PIN is not the file's: nothing to do. Either the Keychain was right all along, or the cube is
    ///   on something else entirely and neither store should be touched.
    /// - The accepted PIN is the file's and the Keychain already holds it: nothing to promote, and the file is dealt
    ///   with by the same rule as below.
    /// - The accepted PIN is the file's and the Keychain does not hold it: promote it, and **only once the Keychain
    ///   has taken it** does the file stop being needed -- a developer build keeps it, being where a person looks,
    ///   and any other build removes it, the fallback having served its purpose.
    static func reconciliation(
        accepted: String, configFile: String?, keychain: String?, isDeveloperMode: Bool
    ) -> Reconciliation {
        guard let configFile, accepted == configFile else { return .nothingToDo }
        let promotes = keychain != accepted
        // **The file is cleared only in a build that is not the developer's**, and only when the Keychain is holding
        // the value: clearing it while the promotion failed would throw away the last copy of a live PIN.
        return Reconciliation(promotesToKeychain: promotes, clearsConfigFileOnSuccess: !isDeveloperMode)
    }

    /// What a reconciliation should do about the two stores.
    struct Reconciliation: Equatable {
        /// Whether the Keychain should be given the PIN the cube just accepted.
        var promotesToKeychain: Bool
        /// Whether the file's copy goes once the Keychain holds it.
        var clearsConfigFileOnSuccess: Bool

        /// The stores already agree, or the accepted PIN came from neither of them.
        static let nothingToDo = Reconciliation(promotesToKeychain: false, clearsConfigFileOnSuccess: false)
    }

    private static func randomPIN<G: RandomNumberGenerator>(using generator: inout G) -> String {
        (0 ..< DeviceLoginRules.length)
            .map { _ in String(Int.random(in: 0 ... 9, using: &generator)) }
            .joined()
    }
}

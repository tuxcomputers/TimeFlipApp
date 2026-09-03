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
    /// **Massaged from `DeviceLoginRules.rotation`**, which asked whether the cube was already on the PIN this app
    /// sets. That question had a right answer only while the target was a fixed constant: the target is a fresh
    /// random PIN each time, so "is it already on the target" would be false for ever and rotate a perfectly good
    /// cube on every connect.
    static func rotates(from accepted: String) -> Bool {
        accepted == DeviceLoginRules.defaultPIN
    }

    /// The PIN a cube is rotated **to**: six random digits.
    ///
    /// A PIN nobody can guess is the only kind worth setting, and it is only safe to set one once there is somewhere
    /// durable to keep it. That is `DevicePINStore`, and it is why this build can do what the last one would not.
    ///
    /// **Never the vendor default**, however the digits fall: rotating a cube from `000000` to `000000` is a command
    /// and a confirming login spent to change nothing, and it would leave the cube exactly as exposed as it was.
    static func target() -> String {
        var generator = SystemRandomNumberGenerator()
        return target(using: &generator)
    }

    /// The same, against a generator a test can hand in, so "six digits and never the default" is checkable rather
    /// than asserted about a value nobody can predict.
    static func target<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var pin = randomPIN(using: &generator)
        // **A loop rather than one draw**, for the one draw in a million that comes up as the vendor default. It
        // cannot spin for long, there being 999,999 other answers.
        while pin == DeviceLoginRules.defaultPIN { pin = randomPIN(using: &generator) }
        return pin
    }

    /// Where a rotated PIN is written: **the Keychain**, and `config.json` only when the Keychain will not take it.
    ///
    /// That fallback is what makes a failed Keychain write recoverable rather than a cube nobody can log into again:
    /// the PIN is on the hardware either way, so the only question is whether this app can still name it. It is
    /// applied by `DevicePINSource.record` rather than listed here, this being where a PIN is *meant* to go.
    static let destinations: [Destination] = [.keychain]

    /// Where a PIN can be kept.
    enum Destination: Equatable {
        case keychain
        case configFile
    }

    /// The order the stored PINs are presented in, given what each store holds.
    ///
    /// **Both stores, the file first**, which reads backwards until you know what the file means: it only ever holds
    /// a PIN because the Keychain refused one, so the file's is the *newer* of the two and the Keychain's is what the
    /// cube was called before it.
    ///
    /// **Deduplicated**, so the ordinary case where both stores agree presents one PIN and not the same PIN twice.
    /// Each candidate costs a whole connect (`BluetoothRadio`), which is a long way to go to learn nothing.
    ///
    /// **Two candidates only in the disagreement case**: the stores hold different PINs, which happens after a
    /// Keychain write that failed, and the app genuinely does not know which of the two the cube is on.
    /// `DevicePINSource.reconcile` is what puts them back together the next time one is proved.
    ///
    /// **Nothing stands in when both stores are empty.** `DeviceLoginRules.reconnectCandidates` appends the vendor
    /// default whatever this returns, so a cube nothing is known about is still reachable on `000000` -- and a guess
    /// offered alongside a stored PIN is the archive's own bug, which let a build into a cube whose PIN the app had
    /// no record of and made "the stored PIN" mean two things (fixed 2026-08-11).
    static func readOrder(configFile: String?, keychain: String?) -> [String] {
        var seen: Set<String> = []
        return [configFile, keychain]
            .compactMap { $0 }
            .filter { DeviceLoginRules.isWellFormed($0) && seen.insert($0).inserted }
    }

    /// What a launch should do about the two stores, before any cube has answered.
    ///
    /// **Three answers, and only one of them needs the cube.**
    ///
    /// - **They agree.** The Keychain is provably holding the value already, so the file's copy is redundant on the
    ///   spot -- there is nothing for a cube to settle, and it is removed rather than left as a live credential in a
    ///   plain file for ever.
    /// - **They differ.** Neither this app nor anything else can say which one the hardware took, so nothing moves
    ///   until a login proves one (`reconciliation`).
    /// - **The file names nothing**, which is the ordinary state: the file is only written when the Keychain
    ///   refuses.
    ///
    /// **The agreeing case is the one this was missing.** `storesDisagree` was the whole of the launch check, so a
    /// launch whose file and Keychain matched never asked again -- and it can get there whenever the promotion works
    /// and the clearing fails. The file then went on holding a live PIN that nothing was ever going to remove.
    static func launchAction(configFile: String?, keychain: String?) -> LaunchAction {
        guard let configFile, !configFile.isEmpty else { return .nothing }
        guard configFile == keychain else { return .askTheCube }
        return .clearConfigFile
    }

    /// What a launch does about the two stores.
    enum LaunchAction: Equatable {
        /// Nothing to settle: the file names no PIN at all.
        case nothing
        /// They agree, so there is no reason to keep a second copy in the clear.
        case clearConfigFile
        /// They disagree, and only the cube can say which is right.
        case askTheCube
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
    ///   has taken it** does the file stop being needed, the fallback having served its purpose.
    static func reconciliation(accepted: String, configFile: String?, keychain: String?) -> Reconciliation {
        guard let configFile, accepted == configFile else { return .nothingToDo }
        let promotes = keychain != accepted
        // **Cleared only when the Keychain is holding the value**: clearing it while the promotion failed would throw
        // away the last copy of a live PIN.
        return Reconciliation(promotesToKeychain: promotes, clearsConfigFileOnSuccess: true)
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

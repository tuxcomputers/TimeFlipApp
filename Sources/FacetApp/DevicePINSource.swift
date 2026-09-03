import Foundation

/// The two places a cube's PIN can be, asked and written as one thing.
///
/// **Two stores, because one of them can refuse.** The Keychain is where a PIN belongs (`DevicePINStore`), and
/// `config.json` beside it is what the app falls back to when the Keychain will not take a write. Without that
/// fallback a refused Keychain write would leave the cube on a PIN nothing can name, recoverable only by taking its
/// batteries out.
///
/// **The decisions are `DevicePINRules`' and the doing is here**, which is what lets every one of them be tested
/// with no Keychain, no file and no cube. What this adds on top is the order things happen in and a row for each,
/// because a PIN that quietly failed to be written down is the one failure this app cannot recover from on its own.
///
/// **Every dependency is injectable**, so the paths that matter -- a Keychain that refuses, a file that refuses, the
/// two stores disagreeing -- are ordinary tests rather than something only a device run can reach. The defaults are
/// the real ones.
/// **`@MainActor`, as `DevicePairingRecorder` is**: everything here logs, and `DebugLog.record` is main-actor
/// isolated. The callers are the radio's callbacks and the launch sequence, both of which are already there.
@MainActor
struct DevicePINSource {
    var keychainLookUp: () -> DevicePINStore.Lookup = { DevicePINStore.lookUp() }
    var keychainSave: (String) -> Bool = { DevicePINStore.save(pin: $0) }
    /// The file, used only as the fallback above.
    var configFile: DeveloperConfigFile = .atStandardPath
    var debugLog: DebugLog?

    /// The PINs this app holds for a cube, in the order they should be presented.
    ///
    /// **Read at the moment they are needed and never held**, which is the first rule in `CLAUDE.md` applied to the
    /// two stores that are not the database: a launch that reads them once would present a PIN a later rotation had
    /// already replaced.
    func stored() -> [String] {
        DevicePINRules.readOrder(configFile: configFile.pin(), keychain: keychainPIN())
    }

    /// Writes down a PIN a cube has just proved it is on. Answers where it landed.
    ///
    /// **Called only after the cube has taken it and logged in with it** (`DeviceLogin.confirmationAnswered`), which
    /// is the one order that is safe: `0x30` has no read-back, so a PIN written down before the confirming login
    /// would be this app's record of something the hardware may have refused.
    ///
    /// **The Keychain refusing is not the end of it.** The file is written in that case, which is the whole of the
    /// fallback: the PIN is on the cube either way, and the only question is whether this app can still name it.
    /// `reconcile` is what puts that right on a later launch.
    @discardableResult
    func record(_ pin: String) -> Recorded {
        var written: Set<DevicePINRules.Destination> = []
        for destination in DevicePINRules.destinations where write(pin, to: destination) {
            written.insert(destination)
        }
        // **The fallback**: the Keychain would not take it, so the file has to.
        if !written.contains(.keychain), write(pin, to: .configFile) {
            written.insert(.configFile)
            debugLog?.record(.pin, "The Keychain would not take the new PIN, so it is in the config file instead")
        }
        let recorded = Recorded(destinations: written)
        debugLog?.record(
            .pin,
            recorded.isRecorded
                ? "The new PIN is written down in \(recorded.described)"
                : "THE NEW PIN IS WRITTEN DOWN NOWHERE -- the cube is on a PIN this app cannot name"
        )
        return recorded
    }

    /// Puts the two stores back together, once a cube has proved which PIN it is on.
    ///
    /// **This is the fallback healing itself, and it runs at launch** rather than on every login: the disagreement it
    /// exists for is written by a failed Keychain write and read by the next launch, so once a launch has settled it
    /// there is nothing left to ask until something writes again.
    ///
    /// **Nothing moves without the cube's answer.** Two stores disagreeing says nothing about which PIN the hardware
    /// took, and promoting the wrong one would overwrite the app's only record of the right one. So this takes the
    /// PIN a login was accepted on, and acts only when it is the file's.
    @discardableResult
    func reconcile(accepted: String) -> Reconciled {
        let decision = DevicePINRules.reconciliation(
            accepted: accepted, configFile: configFile.pin(), keychain: keychainPIN()
        )
        guard decision.promotesToKeychain || decision.clearsConfigFileOnSuccess else { return .nothingHappened }
        var promoted = false
        if decision.promotesToKeychain {
            promoted = keychainSave(accepted)
            debugLog?.record(
                .pin,
                promoted
                    ? "The PIN the cube answered to is now in the Keychain as well"
                    : "The Keychain still will not take the PIN the cube answered to, so the config file keeps it"
            )
            guard promoted else { return Reconciled(promoted: false, clearedConfigFile: false) }
        }
        // **Cleared only once the Keychain is holding it**, which is what makes this safe to do at all: the file was
        // the only record a moment ago.
        guard decision.clearsConfigFileOnSuccess else { return Reconciled(promoted: promoted, clearedConfigFile: false) }
        let cleared = configFile.clearPIN()
        debugLog?.record(
            .pin,
            cleared
                ? "The config file no longer needs to hold the PIN, so it does not"
                : "The config file would not give up its copy of the PIN"
        )
        return Reconciled(promoted: promoted, clearedConfigFile: cleared)
    }

    /// Settles what a launch can settle about the two stores, and says whether the cube still has to answer.
    ///
    /// **Two of the three cases need no cube at all.** A file naming nothing is the ordinary state; a file naming
    /// exactly what the Keychain holds is a redundant copy, taken away here and now, the Keychain having already
    /// proved it holds the same string. Only a real disagreement waits for a login, because only the cube can say
    /// which of two PINs it took.
    ///
    /// **Called once, at launch**, which is where the state it looks for comes from: the file is written by a failed
    /// Keychain write and read by the next launch.
    @discardableResult
    func settleAtLaunch() -> LaunchOutcome {
        switch DevicePINRules.launchAction(configFile: configFile.pin(), keychain: keychainPIN()) {
        case .nothing:
            return .nothingToSettle
        case .clearConfigFile:
            let cleared = configFile.clearPIN()
            debugLog?.record(
                .pin,
                cleared
                    ? "The Keychain already holds the PIN the config file names, so the file no longer needs to"
                    : "The config file would not give up its copy of a PIN the Keychain already holds"
            )
            return cleared ? .clearedARedundantCopy : .nothingToSettle
        case .askTheCube:
            debugLog?.record(.pin, "The Keychain and the config file name different PINs, so the next login settles it")
            return .awaitingTheCube
        }
    }

    /// What a launch made of the two stores.
    enum LaunchOutcome: Equatable {
        case nothingToSettle
        /// A release build took the file's copy away, the Keychain holding the same value.
        case clearedARedundantCopy
        /// They disagree: `reconcile` is armed until a login proves one of them.
        case awaitingTheCube
    }

    private func keychainPIN() -> String? {
        switch keychainLookUp() {
        case let .found(pin): return pin
        case .missing: return nil
        case let .unavailable(status):
            // **Said out loud, because it is not the same as there being no PIN.** A Keychain that will not answer
            // leaves the app presenting one fewer candidate than it has, and the failure that follows is a cube
            // refusing a PIN nobody knew was missing.
            debugLog?.record(.pin, "The Keychain would not say whether it holds a PIN for the cube (status \(status))")
            return nil
        }
    }

    private func write(_ pin: String, to destination: DevicePINRules.Destination) -> Bool {
        switch destination {
        case .keychain:
            return keychainSave(pin)
        case .configFile:
            return configFile.record(pin: pin)
        }
    }

    /// Where a PIN ended up.
    struct Recorded: Equatable {
        var destinations: Set<DevicePINRules.Destination>

        /// Whether anything at all holds it. `false` is the one state this app cannot recover from on its own, and
        /// the caller says so to the user rather than only to the log.
        var isRecorded: Bool { !destinations.isEmpty }

        /// Whether the file is holding it *instead of* the Keychain, which is the fallback in use.
        var isFallback: Bool { !destinations.contains(.keychain) && destinations.contains(.configFile) }

        var described: String {
            destinations
                .map { $0 == .keychain ? "the Keychain" : "the config file" }
                .sorted()
                .joined(separator: " and ")
        }
    }

    /// What a reconciliation actually did.
    struct Reconciled: Equatable {
        var promoted: Bool
        var clearedConfigFile: Bool

        static let nothingHappened = Reconciled(promoted: false, clearedConfigFile: false)
    }
}

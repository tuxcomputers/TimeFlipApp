import Foundation

/// What the app does when the radio says something, as opposed to what a window draws about it.
///
/// **These reactions were in `SettingsWindowController`, and most of them are not a window's.** A paired app
/// follows its cube whether or not anybody opens Settings, so the reconnect loop's backoff, the rotated PIN
/// being written down, the pairing rows and the low-battery warning all had to keep working with nothing on
/// screen. They did, by being reached through a controller that happens to be constructed at launch. That is
/// the coupling candidate 8 of `docs/architecture-review-2026-09.md` names, and this is the core module the
/// owner chose to answer it with (2026-09-11).
///
/// **Drawing is deliberately not here.** Every method ends by calling `changed`, and a surface with nothing on
/// screen simply has none set. That is the same split `ManualClock` uses: this decides and records, the caller
/// repaints whatever it has.
///
/// **It is fed rather than subscribed.** `BluetoothRadio`'s callbacks are one slot each, so both this and a
/// window cannot register for the same one. The adapter that owns the radio calls the methods below and then
/// does its own pane work, which keeps the ordering explicit at the one place that knows both.
@MainActor
package final class CubeReports {
    private let settings: SettingStore?
    private let devicePINs: DevicePINStore?
    private let debugLog: DebugLog?

    /// Told about every login outcome and every drop, which is the whole of what backing off is.
    package weak var reconnect: DeviceReconnector?

    /// Told to think again when a charge arrives. **Nothing about the charge is written down**: it has no row
    /// and is not going to get one, being a fact about the live connection rather than about the app's setup.
    package weak var lowBattery: LowBatteryWatch?

    /// Where the one thing this has to say out loud goes. `nil` where nothing can be shown.
    package var dialogues: DialoguePresenter?

    /// Called after anything that moved a row, so a surface can redraw from the table. `nil` means nobody is
    /// looking, which is an ordinary state and not a failure: the write still happens and the redraw is skipped.
    package var changed: (@MainActor () -> Void)?

    package init(settings: SettingStore?, devicePINs: DevicePINStore?, debugLog: DebugLog?) {
        self.settings = settings
        self.devicePINs = devicePINs
        self.debugLog = debugLog
    }

    private var recorder: DevicePairingRecorder? {
        settings.map { DevicePairingRecorder(settings: $0, debugLog: debugLog) }
    }

    // MARK: - the PIN

    /// The cube is on a new PIN and this app has to keep it.
    ///
    /// **The cube has already proved it by logging in with it** (`DeviceLogin.confirmationAnswered`), so a
    /// failure here is the app losing a PIN the cube already has rather than a change that did not happen. That
    /// is the one fault this app cannot put right on its own, which is why the PIN is offered to two stores
    /// before it is given up on, and why somebody is told when both refuse.
    package func pinChanged(to pin: String) {
        guard let devicePINs else { return }
        // The write happens on its own line rather than inside a logging call: `debugLog?.record(...)` is
        // optional chaining, so with no logger its argument is never evaluated and the PIN would go unrecorded
        // in exactly the build that has no log to notice.
        let recorded = DevicePINSource(keychain: devicePINs, debugLog: debugLog).record(pin)
        guard !recorded.isRecorded else { return }
        dialogues?.tell(Dialogue(
            title: "The TimeFlip PIN could not be saved",
            message: "The device has been given a new PIN, and neither the Keychain nor this app's "
                + "config file would take a copy of it -- so Facet cannot log in to it again.\n\n"
                + "Take the batteries out of the TimeFlip and put them back. That returns it to its factory PIN, "
                + "and pairing again will set a new one.",
            isWarning: true
        ))
    }

    // MARK: - the link

    /// One attempt to reach a cube has ended, however it ended.
    ///
    /// - Parameter device: what the radio found, or `nil` where the attempt named nothing.
    package func loginEnded(_ outcome: DeviceLoginOutcome, with device: ScannedDevice?) {
        // **Told either way, and before the recording.** A failure is what starts the next attempt, so the loop
        // has to hear about the ones that did not work.
        reconnect?.noteOutcome(outcome)
        // **Only a login that got all the way through writes anything.** A refused PIN, a device that turned out
        // not to be a TimeFlip and a cube that stopped answering all leave the table exactly as it was: the app
        // does not know which cube it was talking to, or knows it cannot open it, and a `paired` row written
        // anyway would send the next launch looking for a device it cannot log into.
        guard outcome == .loggedIn, let device, let settings, let recorder else { return }
        // **The table is what decides which of the two this is**, read at this moment. Both are a PIN accepted by
        // a cube, and they are different claims about the app: pairing gains a device, reconnecting reaches the
        // one it already has. A login to the cube named in `device_uuid` cannot be a new pairing, whoever started
        // it, and a login to any other cube is a pairing even if the user got there from a tab already showing one.
        let alreadyPaired = settings.flag("paired", field: "paired") == true
            && settings.string("device_uuid", field: "uuid") == device.id.value
        if alreadyPaired {
            recorder.recordReconnection(with: device)
        } else {
            recorder.recordPairing(with: device)
        }
        changed?()
    }

    /// The link ended by itself or was let go of. `reason` is what goes in the row.
    package func connectionDropped(because reason: String) {
        recorder?.recordConnectionLost(because: reason)
        changed?()
        // **After the row is down, not before.** The loop's first act is to ask whether the app is already
        // connected and it reads that from the radio, but the row is what a tab draws, and a reconnect that
        // succeeded before the drop was written down would leave `connected` false under a live link.
        reconnect?.noteDropped()
    }

    // MARK: - what the cube says about itself

    /// The four Device Information strings, which arrive after the login rather than with it.
    package func deviceInfoArrived(_ info: DeviceInfo) {
        recorder?.recordInfo(info)
        changed?()
    }

    /// A charge reading. Nothing is written down; the warning is told to think again.
    package func chargeArrived() {
        lowBattery?.reconsider(because: "a charge arrived")
        changed?()
    }

    /// The cube saying what it is called, which is the one confirmation a rename ever gets.
    ///
    /// **Only for the cube this app is paired to**, read from the table at this moment. Every connection reports
    /// a name, including the one that proves a factory reset and any made to a device that turns out to be
    /// somebody else's, and writing one of those into `device_name` would rename the pairing after a cube it is
    /// not to.
    package func nameArrived(_ name: String, from id: DeviceHandle) {
        guard let settings, let recorder else { return }
        guard settings.string("device_uuid", field: "uuid") == id.value else {
            debugLog?.record(.pair, "Ignoring the name \(name): it is not the cube this app is paired to")
            return
        }
        // **A report is not automatically newer than what is on record**, and the one case where it is older is
        // the one that matters: macOS re-reads the GAP name only on connecting, so the connection after a rename
        // can still be handing out the name the cube was renamed away from. Adopting that would undo the rename
        // on the tab and in the row the scan filter is built from, and put it back a connection later.
        switch DevicePairingRules.adoption(
            of: name,
            current: settings.string("device_name", field: "name"),
            previouslyKnown: settings.string("device_name", field: "previous_name")
        ) {
        case .unchanged:
            return
        case .stale:
            debugLog?.record(
                .pair,
                "The cube reports the name it had before the rename, which macOS is a connection behind on, so the record stands"
            )
            return
        case .adopt:
            break
        }
        guard recorder.recordName(name, because: "the cube said so on connecting") else { return }
        changed?()
    }
}

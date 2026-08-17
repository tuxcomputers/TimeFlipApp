import Foundation

/// Keeps a paired app's cube reachable: reaches for it at launch, and keeps reaching whenever the link goes.
///
/// **A paired app is meant to be talking to its device, and until now nothing made that true.** Pairing left the app
/// connected and the next launch left it deaf: `paired` said there was a cube, `connection.connected` said it was not
/// reachable, and there was no way to make it so, because the Scan button is not on show while paired
/// (`DevicePairingRules.showsScanControls`). Forget Device was the only way out of that, which is a control for giving a
/// device up being the only way to get one back.
///
/// **It decides nothing** -- `DeviceReconnectRules` does, and `BluetoothRadio.reach` does the radio work. What is here is
/// the loop: when to ask, what to do with the answer, and the one piece of state a loop needs, which is how many times
/// running it has failed.
///
/// **Every value comes out of the table at the moment it is used**, which is the first rule in `CLAUDE.md` and matters
/// more here than almost anywhere else in the app: this thing runs unattended for hours. `paired` is read per attempt, so
/// forgetting a device stops the loop without anything having to tell it; `device_uuid` is read per attempt, so pairing a
/// different cube redirects it; the two names the scan filters on are read per attempt, so a rename lands on the next
/// try. Nothing is carried from launch, and nothing is remembered between attempts except the failure count.
///
/// **Massaged from `ApplicationDelegate`'s reconnect path.** What is kept is the shape and the reasons: retry while
/// paired, back off, never touch the pairing on a failure, and treat a drop as the beginning of the next attempt rather
/// than as an ending. What is not kept is the archive's candidate loop -- it scanned, built a list of every cube in the
/// room eligible by name, and tried each in turn to find out which one was its own. This app reconnects by identifier, so
/// there is nothing to work out: `device_uuid` names the cube, and a reach gets that one or nothing. See
/// `DeviceLoginRules.reconnectCandidates` for what that also means about which PINs may be presented.
@MainActor
final class DeviceReconnector {
    private let radio: BluetoothRadio
    private let settings: SettingStore
    private let debugLog: DebugLog?

    /// The stored PIN, asked for rather than held, because `config.json` is a file a developer edits by hand and what it
    /// says is only the answer at the moment a login needs one.
    private let storedPIN: () -> String?

    /// The PIN a cube should end up on, or `nil` to leave it on whichever one let the app in.
    private let rotatingTo: String?

    /// How many attempts have failed in a row. The only thing this object remembers, and the backoff is a function of it.
    private var failures = 0

    private var next: Timer?

    init(
        radio: BluetoothRadio,
        settings: SettingStore,
        debugLog: DebugLog?,
        storedPIN: @escaping () -> String?,
        rotatingTo: String? = nil
    ) {
        self.radio = radio
        self.settings = settings
        self.debugLog = debugLog
        self.storedPIN = storedPIN
        self.rotatingTo = rotatingTo
    }

    /// Starts following the device, if there is one to follow.
    ///
    /// **Called at launch, and it is not conditional on anything the caller knows.** Whether this app has a device is a
    /// question for the table, asked here, so a launch does not have to work out whether to bother.
    func follow() {
        guard settings.flag("paired", field: "paired") == true else {
            debugLog?.record(.pair, "Nothing paired, so there is no cube to follow")
            return
        }
        debugLog?.record(.pair, "Paired, so going to look for the cube")
        attempt()
    }

    /// Reaches for the cube, or stands down until something changes.
    private func attempt() {
        next?.invalidate()
        next = nil

        let isPaired = settings.flag("paired", field: "paired") == true
        guard DeviceReconnectRules.shouldAttempt(
            isPaired: isPaired,
            isConnected: radio.connectedDevice != nil,
            isScanning: radio.isScanning,
            isReaching: radio.isReaching,
            isResetting: radio.isResetting
        ) else {
            // **Said only when there was a pairing to act on.** An unpaired app standing down is not an event, and this
            // runs on every drop and every failed attempt: a line each time would be the loop's own noise burying the
            // rows that say what the cube did.
            if isPaired {
                debugLog?.record(.pair, "Not reaching for the cube: the radio is busy with something else")
            }
            return
        }
        guard let id = DeviceReconnectRules.target(from: settings.string("device_uuid", field: "uuid")) else {
            debugLog?.record(.pair, "Paired, but `device_uuid` names no device, so there is nothing to reach for")
            return
        }
        radio.reach(
            id,
            presenting: DeviceLoginRules.reconnectCandidates(stored: storedPIN()),
            rotatingTo: rotatingTo,
            remembered: settings.string("device_name", field: "name"),
            previouslyKnown: settings.string("device_name", field: "previous_name")
        )
    }

    /// What came of an attempt to reach a device, whoever started it.
    ///
    /// **Told about every login, not only its own**, and that is deliberate: a device the user paired by hand from the
    /// Device tab is a device this loop is now responsible for, so the count that governs the backoff has to include it.
    /// The alternative is a loop that has to be told which attempts are its own, which is a second copy of a question the
    /// radio already answers.
    func noteOutcome(_ outcome: DeviceLoginOutcome) {
        guard outcome != .loggedIn else {
            // **Reset on the way in, not on the way out.** The next drop starts its own retries from two seconds,
            // because a cube that has just been connected to is plainly in the room -- and carrying an old count over
            // would have a cube that flickers once waiting half a minute to be picked up.
            if failures > 0 {
                debugLog?.record(.pair, "The cube answered, so the backoff starts again from nothing")
            }
            failures = 0
            return
        }
        guard settings.flag("paired", field: "paired") == true else { return }
        scheduleAttempt()
    }

    /// The link went away on its own: out of range, switched off, batteries out.
    ///
    /// **The pairing is untouched**, which is the archive's rule and the row's own description: going out of range does
    /// not change which device this app is paired to. So this is the start of the next attempt rather than an ending.
    func noteDropped() {
        guard settings.flag("paired", field: "paired") == true else { return }
        debugLog?.record(.pair, "The cube went away; it is still this app's device, so it will be looked for again")
        scheduleAttempt()
    }

    private func scheduleAttempt() {
        let delay = DeviceReconnectRules.delay(afterFailures: failures)
        failures += 1
        debugLog?.record(.pair, "Looking for the cube again in \(Int(delay))s (attempt \(failures + 1))")
        next?.invalidate()
        next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.attempt() }
        }
        // `.common`, so the app does not stop reaching for its cube because a menu is being held open.
        if let next { RunLoop.main.add(next, forMode: .common) }
    }
}

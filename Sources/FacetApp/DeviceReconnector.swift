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

    /// Whether the app is timing by hand, asked of whatever owns that rather than copied here.
    ///
    /// **A closure, so there is one answer and not two.** Manual mode is `ManualMode`'s to say; a `Bool` set on this
    /// object at the moment the offer was answered would be a second copy of it, free to disagree the moment anything
    /// else turns the mode off -- which pairing a cube does. That is the exact fault `CLAUDE.md`'s first rule is about.
    private let isTimingByHand: () -> Bool

    /// How many attempts have failed in a row. The backoff is a function of it.
    private var failures = 0

    /// Whether this launch has ever reached the cube, which is the whole of what decides between retrying quietly and
    /// asking. See `ManualModeOffer`.
    private var offer = ManualModeOffer()

    /// Whether the question is on screen right now. Nothing may attempt a connection until it is answered.
    private var isAwaitingAnswer = false

    private var next: Timer?

    /// Asked when a launch that has never reached its cube gives up on an attempt: the reason, and a closure to report
    /// the answer through.
    ///
    /// **`nil` means no offer**, and the loop then behaves exactly as it did before there was one -- retrying on the
    /// backoff for ever. That is what a test gets by default, and it is the honest fallback for a build with nowhere
    /// to put a dialog: an app that stopped trying and had no way to say so would simply look broken.
    var onCubeNotFound: ((String, @escaping (ManualModeAnswer) -> Void) -> Void)?

    init(
        radio: BluetoothRadio,
        settings: SettingStore,
        debugLog: DebugLog?,
        storedPIN: @escaping () -> String?,
        rotatingTo: String? = nil,
        isTimingByHand: @escaping () -> Bool = { false }
    ) {
        self.radio = radio
        self.settings = settings
        self.debugLog = debugLog
        self.storedPIN = storedPIN
        self.rotatingTo = rotatingTo
        self.isTimingByHand = isTimingByHand
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
            isResetting: radio.isResetting,
            isAwaitingAnswer: isAwaitingAnswer,
            isTimingByHand: isTimingByHand()
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
            // Settles the offer for the rest of the launch: from here on a drop is a cube that went away rather than
            // one that was never there, and those are retried quietly for ever.
            offer.recordConnected()
            return
        }
        guard settings.flag("paired", field: "paired") == true else { return }
        switch offer.recordFailedAttempt() {
        case .keepTrying: scheduleAttempt()
        case .ask: ask(because: ManualModeOffer.reason(for: outcome))
        }
    }

    /// Stops, and asks whether to look again or to time by hand.
    ///
    /// **Reached only by a launch that has never reached its cube, on the first failed attempt.** How long that
    /// attempt took is not decided here and deliberately not timed here either: reaching a cube at launch is a scan,
    /// and `BluetoothRadio.timeoutSeconds` already ends a fruitless one at ten seconds, reporting `.unreachable`. A
    /// second clock in this file would be a second answer to "how long do we look for", free to disagree with the one
    /// the radio is actually keeping.
    ///
    /// **Nothing is scheduled on the way in.** The attempt that just failed ends here rather than in `scheduleAttempt`,
    /// so no timer is left running behind the dialog -- which is half of what stops somebody coming back to an app
    /// that quietly carried on. The other half is the gate in `attempt`.
    private func ask(because reason: String) {
        // **Asked once a launch, and never again once the answer was manual mode.** Nothing should reach this in that
        // state -- no attempt is made, so no outcome comes back to fail -- but an offer reappearing after somebody has
        // said to get on without the device would be the app asking them to decide again, and standing down here is
        // what makes "the radio is ignored from now on" true of every path rather than of the ones thought of.
        guard !isTimingByHand() else {
            debugLog?.record(.mode, "Timing by hand, so the offer is not put up again this launch")
            return
        }
        guard let onCubeNotFound else {
            // No presenter, so there is nobody to ask. Retrying is the only thing left that is not giving up silently.
            scheduleAttempt()
            return
        }
        isAwaitingAnswer = true
        debugLog?.record(.mode, "Offering manual mode: \(reason)")
        onCubeNotFound(reason) { [weak self] answer in
            guard let self else { return }
            self.isAwaitingAnswer = false
            switch answer {
            case .retry:
                // The backoff goes back to the start, so the next attempt begins two seconds out rather than at
                // whatever the count had climbed to. Retry is somebody standing there having just asked for it.
                self.failures = 0
                self.debugLog?.record(.mode, "Retry chosen; looking for the cube again")
                self.attempt()
            case .switchToManualMode:
                // **Nothing is scheduled and nothing is set here.** Manual mode is turned on by whoever owns it, in
                // the presenter's own answer handler; what this object does is stop, and the gate in `attempt` is what
                // keeps it stopped -- so the mode and the loop cannot come to disagree about whether the app is
                // looking for a cube.
                self.debugLog?.record(.mode, "Manual mode chosen; this launch reaches for no cube on its own again")
            }
        }
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
        // **Manual mode ends the loop for the rest of the launch, and it ends it here as well as at `attempt`.**
        // The gate down there is what stops an attempt happening; this is what stops one being *arranged*, which is a
        // different fault and a visible one: a drop would otherwise write "Looking for the cube again in 8s" and then
        // quietly stand down eight seconds later, so the log would describe an app still hunting for a cube it has
        // been told to stop hunting for. Two callers reach this -- a link that went away and an attempt that failed --
        // and neither is a reason to start again once somebody has said to get on without the device.
        //
        // **The way back out is a restart or forgetting the device**, deliberately, and neither needs anything here:
        // the mode is per-launch and in memory, so a relaunch works it out again from `paired`, and forgetting turns
        // it on for the honest reason that nothing is paired -- after which pairing turns it off and this loop is a
        // loop again.
        guard !isTimingByHand() else {
            debugLog?.record(.pair, "Timing by hand, so the cube is not being looked for again this launch")
            return
        }
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

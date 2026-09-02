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
/// than as an ending. The archive's candidate loop is kept too, and it took a hardware run to find out it had to be:
/// it scanned, built a list of every cube in the room eligible by name, and tried each in turn to find out which one
/// was its own. Reaching by identifier alone looked like a simplification this app could afford and is not one --
/// neither identifier available is unique to a cube -- so the loop lives in `BluetoothRadio.reach` now, and what
/// arrives here is its single answer. See `DeviceLoginRules.reconnectCandidates` for which PINs may be presented.
@MainActor
final class DeviceReconnector {
    private let radio: BluetoothRadio
    private let settings: SettingStore
    private let debugLog: DebugLog?

    /// The PINs this app holds for the cube, asked for rather than held: they live in the Keychain and in a file a
    /// developer edits by hand (`DevicePINSource`), and what they say is only the answer at the moment a login needs
    /// one. There can be two, and `DeviceLoginRules.candidates` says when.
    private let storedPINs: () -> [String]

    /// The PIN a cube on the vendor default should end up on, asked for **per attempt**.
    ///
    /// **A closure rather than a value, and that is not symmetry with the line above.** A release build picks six
    /// random digits each time (`DevicePINRules.target`), so a target captured once would put the same PIN on every
    /// cube this launch ever met, and on the same cube twice after a battery change.
    private let rotatingTo: () -> String?

    /// How many attempts have failed in a row. The backoff is a function of it.
    private var failures = 0

    /// Whether this launch has ever reached the cube, which is the whole of what decides between retrying quietly and
    /// asking. See `CubeNotFoundOffer`.
    private var offer = CubeNotFoundOffer()

    /// Whether somebody has told this launch to stop looking.
    ///
    /// Whether this launch has been told to get on without the cube it is paired to.
    ///
    /// **Two things read it, and they are two consequences of one decision rather than two facts.** This loop stops
    /// arranging attempts, and `ManualTimerRules.isManualMode` reports the app as its own clock. Keeping them one
    /// flag is what stops them disagreeing: a launch that had given up hunting while still refusing to time by hand
    /// is exactly the state somebody complained about, and it existed because the second half was missing.
    ///
    /// **Still not the same question as whether the app has a device.** The cube is on record throughout: nothing
    /// here writes `paired`, and forgetting the device stays a separate act with a different meaning.
    ///
    /// **One-way, and it dies with the process.** Nothing sets it back, so a restart is what looks for the cube
    /// again -- which is what the dialog says. `CubeNotFoundOffer` deliberately does not model it, its own note
    /// saying this is about whether an attempt may run at all.
    private(set) var hasGivenUpOnCube = false

    /// Whether the question is on screen right now. Nothing may attempt a connection until it is answered.
    private var isAwaitingAnswer = false

    private var next: Timer?

    /// Asked when a launch that has never reached its cube gives up on an attempt: the reason, and a closure to report
    /// the answer through.
    ///
    /// **`nil` means no offer**, and the loop then behaves exactly as it did before there was one -- retrying on the
    /// backoff for ever. That is what a test gets by default, and it is the honest fallback for a build with nowhere
    /// to put a dialog: an app that stopped trying and had no way to say so would simply look broken.
    var onCubeNotFound: ((String, @escaping (CubeNotFoundAnswer) -> Void) -> Void)?

    /// Called the moment this launch is told to time by hand, so whatever draws intermittently is redrawn.
    ///
    /// **The one thing a derived answer still needs.** Nothing has to be *told* what the app now is, since every
    /// surface reads `ManualTimerRules.isManualMode` when it next asks -- but two of them only ask on a tick that
    /// does not run in this state. The menu bar repaints while something is being timed and nothing is; the Faces tab
    /// repaints on a flip and there is no cube to flip. So this is a redraw, not a notification of state.
    var onGaveUpOnCube: (() -> Void)?

    /// Called when the answer is to quit. `nil` leaves the launch as it was, which is what a test wants.
    ///
    /// **Injected rather than calling `NSApp` here**, so this type stays testable without AppKit and the app keeps
    /// one way out: `main.swift` wires this to the same terminate the menu bar's Quit uses, so the quit sequence
    /// runs exactly as it does from anywhere else.
    var onQuitRequested: (() -> Void)?

    init(
        radio: BluetoothRadio,
        settings: SettingStore,
        debugLog: DebugLog?,
        storedPINs: @escaping () -> [String],
        rotatingTo: @escaping () -> String? = { nil }
    ) {
        self.radio = radio
        self.settings = settings
        self.debugLog = debugLog
        self.storedPINs = storedPINs
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

        let isCubePaired = settings.flag("paired", field: "paired") == true
        guard DeviceReconnectRules.shouldAttempt(
            isCubePaired: isCubePaired,
            isCubeConnected: radio.connectedDevice != nil,
            isScanning: radio.isScanning,
            isReachingForCube: radio.isReachingForCube,
            isFactoryResetRunning: radio.isFactoryResetRunning,
            isAwaitingAnswer: isAwaitingAnswer,
            hasGivenUpOnCube: hasGivenUpOnCube
        ) else {
            // **Said only when there was a pairing to act on.** An unpaired app standing down is not an event, and this
            // runs on every drop and every failed attempt: a line each time would be the loop's own noise burying the
            // rows that say what the cube did.
            if isCubePaired {
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
            presenting: DeviceLoginRules.reconnectCandidates(stored: storedPINs()),
            rotatingTo: rotatingTo(),
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
        case .ask: ask(because: CubeNotFoundOffer.reason(for: outcome))
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
        // **Asked once a launch, and never again once the answer was to stop.** Nothing should reach this in that
        // state -- no attempt is arranged, so no outcome comes back to fail -- but the question reappearing after
        // somebody has said to get on without the device would be the app asking them to decide again, and standing
        // down here is what makes "this launch has stopped" true of every path rather than of the ones thought of.
        guard !hasGivenUpOnCube else {
            debugLog?.record(.mode, "This launch was told to time by hand, so the offer is not put up again")
            return
        }
        guard let onCubeNotFound else {
            // No presenter, so there is nobody to ask. Retrying is the only thing left that is not giving up silently.
            scheduleAttempt()
            return
        }
        isAwaitingAnswer = true
        // **The wording is the log's own and does not track the dialog's.** What is being offered is a choice about
        // whether to keep looking; the scripted suite matches this string, and it names the moment rather than the
        // button. See `CubeNotFoundAlert` for what the buttons now say.
        debugLog?.record(.mode, "Offering manual mode: \(reason)")
        onCubeNotFound(reason) { [weak self] answer in
            guard let self else { return }
            self.isAwaitingAnswer = false
            switch answer {
            case .rescan:
                // The backoff goes back to the start, so the next attempt begins two seconds out rather than at
                // whatever the count had climbed to. Retry is somebody standing there having just asked for it.
                self.failures = 0
                // **And the last scan's results go, now rather than when the next scan clears them.** `reach` does
                // start a scan and a scan does empty the list, so this is not what makes Retry look again -- what it
                // does is make the moment visible: the list a Settings window is showing goes empty as the button is
                // pressed, and the log says where the retry began rather than leaving it to be inferred from the
                // scan row after it. Retry was once a shortcut to a peripheral the failed attempt had already torn
                // down, which failed in eight milliseconds on hardware (2026-08-23) and reported "nothing answered"
                // about a cube on the desk. That shortcut is gone from `reach` entirely.
                self.radio.forgetWhatWasFound()
                self.debugLog?.record(.mode, "Rescan chosen; looking for the cube again")
                self.attempt()
            case .timeByHand:
                // **One flag, and it is what both halves of the answer read.** This loop arranges nothing further,
                // and the app is its own clock from here, because `ManualTimerRules.isManualMode` asks this same
                // question rather than being handed a mode. The pairing is untouched: the cube is still on record and
                // a new launch will look for it.
                self.hasGivenUpOnCube = true
                self.debugLog?.record(.mode, "Time by hand chosen; this launch times from the app and looks for no cube again")
                // After the flag, so anything that reads back during the redraw gets the new answer.
                self.onGaveUpOnCube?()
            case .quit:
                // Nothing is set and nothing is written, so the next launch puts the same question up. The log row
                // goes first because there is no after.
                self.debugLog?.record(.mode, "Quit chosen at the device offer; nothing about the pairing is changed")
                self.onQuitRequested?()
            }
        }
    }

    /// The link went away on its own: out of range, switched off, batteries out.
    ///
    /// **The pairing is untouched**, which is the archive's rule and the row's own description: going out of range does
    /// not change which device this app is paired to. So this is the start of the next attempt rather than an ending.
    func noteDropped() {
        guard settings.flag("paired", field: "paired") == true else { return }
        debugLog?.record(.pair, "The cube went away; it is still paired here, so it will be looked for again")
        scheduleAttempt()
    }

    private func scheduleAttempt() {
        // **An app with no device arranges nothing**, and this is checked here as well as at `attempt`. The gate down
        // there is what stops an attempt happening; this is what stops one being *arranged*, which is a different
        // fault and a visible one: a drop would otherwise write "Looking for the cube again in 8s" and then quietly
        // stand down eight seconds later, so the log would describe an app still hunting for a cube it no longer has.
        // Two callers reach this -- a link that went away and an attempt that failed -- and neither is a reason to
        // start again for a device that has since been forgotten.
        //
        // **Read from the table here, which is what makes forgetting a device take effect at once.** It was a copy of
        // a mode decided at startup, so a forget left this loop chasing a cube the app had given up and only a restart
        // stopped it.
        guard settings.flag("paired", field: "paired") == true else {
            debugLog?.record(.pair, "Nothing is paired, so the cube is not being looked for again")
            return
        }
        // **And nothing is arranged once somebody has said to stop.** Same fault, different reason: a drop would
        // otherwise write "Looking for the cube again in 8s" and then stand down eight seconds later at the gate in
        // `attempt`, so the log would describe an app still hunting for a cube it was asked to leave alone.
        guard !hasGivenUpOnCube else {
            debugLog?.record(.pair, "This launch was told to stop looking, so the cube is not being looked for again")
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

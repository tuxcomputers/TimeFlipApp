import Foundation

/// Telling the cube what the app's device settings say, on a link coming up and whenever the cube asks.
///
/// **The gap this closes.** Every row of the Device tab's Settings section writes to the cube when somebody moves
/// it, and nothing ever wrote them again. So a cube that lost a setting -- a factory reset, a flat battery, the
/// vendor's app -- kept whatever it fell back to, while the table went on claiming the value it was last given. Two
/// answers to one question, which is the fault the first rule in `CLAUDE.md` exists for, and the cube is the half
/// nobody was checking.
///
/// **The archive did both halves and this app did neither.** `TimeFlipBLEDevice.initializeSession` reconciled the
/// auto-pause delay on every connect, and `reconcileSystemState` answered the cube outright when it said it had lost
/// its time, its auto-pause, its LED brightness or its blink period. Massaged rather than copied: the archive
/// compared against a `snapshotState` it kept in memory, and this reads the tables at the moment each command is
/// built.
///
/// **What can be compared is compared, and what cannot is sent.** That split is the vendor spec's, not a preference:
///
/// - **Auto-pause** (`0x05`) and the **double-tap registers** (`0x16`) have read-backs, and the cube reports both of
///   them unasked as part of every login. So the app can see a disagreement, and only a disagreement is worth a
///   write.
/// - **LED brightness** (`0x09`) and the **blink period** (`0x0A`) have no read command at all, so there is nothing
///   to compare against and never will be. They go out on every link, which is exactly what `FaceColourSync` does
///   with `0x11` and for the same reason: the only alternative is a note the app writes to itself about what it last
///   sent, and that is the second copy the first rule forbids.
/// - **The clock** (`0x08`) is set by the login on every connection already, so this only answers the cube asking
///   for it mid-session.
///
/// **Nothing is remembered about what the cube holds.** The comparisons are made against what the cube has just
/// said, at the moment it says it, and the value written is read from the table when the command is built.
@MainActor
final class DeviceSettingsSync {
    /// One thing the cube can be told.
    enum Setting: Equatable {
        case autoPause
        case ledBrightness
        case blinkInterval
        case doubleTap
        case clock
    }

    /// What the tables say the cube should be set to, read at the moment a command is built and never held.
    struct Stored: Equatable {
        var autoPauseMinutes: Int
        var ledBrightnessPercent: Int
        var ledBlinkSeconds: Int
        var doubleTap: DoubleTapParameters
        var isDoubleTapEnabled: Bool

        /// What the cube should be reporting for its double-tap registers, which is not the same as what is stored:
        /// disabling the gesture is faked by sending `window` 0, the hardware having no switch for it
        /// (`DoubleTapRules.asSent`).
        var doubleTapAsSent: DoubleTapParameters {
            DoubleTapRules.asSent(doubleTap, isEnabled: isDoubleTapEnabled)
        }
    }

    /// Sends one command and reports whether the cube took it. Handed in rather than held, so the whole sequence can
    /// be driven in a test with no radio -- `FaceColourSync`'s arrangement, for its reason.
    private let send: (Data, @escaping (Bool) -> Void) -> Void
    private let isCubeConnected: () -> Bool
    private let stored: () -> Stored
    private let now: () -> Date
    private let debugLog: DebugLog?

    /// How long after answering the cube about one setting to ignore it asking for that one again.
    ///
    /// **`FaceColourSync`'s number and its reason**, applied per setting: a cube that is failing to hold its settings
    /// says so on every notification and on every re-read, and each answer here is a flash write. The requests are
    /// collapsed into one answer and the next half-minute of asking is counted rather than obeyed.
    static let cooldownSeconds = FaceColourSync.cooldownSeconds

    private var queue: [(setting: Setting, reason: String)] = []
    private var isSending = false
    private var answeredAt: [Setting: Date] = [:]
    private var suppressed: [Setting: Int] = [:]

    /// Whether the login has finished asking the cube its own questions.
    ///
    /// **Measured, and it is `FaceColourSync`'s measurement**: the `0x17` read the login still has out at that point
    /// does not set `isCommandInFlight`, so a command sent before this would be written over an exchange already in
    /// the air. Everything queued before it waits.
    private var isLinkSettled = false

    /// What `isCubeConnected` said when the last opening send went out, so a callback that fires twice on one
    /// connection does not send the LED pair twice.
    private var wasCubeConnected = false

    init(
        send: @escaping (Data, @escaping (Bool) -> Void) -> Void,
        isCubeConnected: @escaping () -> Bool,
        stored: @escaping () -> Stored,
        now: @escaping () -> Date = Date.init,
        debugLog: DebugLog?
    ) {
        self.send = send
        self.isCubeConnected = isCubeConnected
        self.stored = stored
        self.now = now
        self.debugLog = debugLog
    }

    /// The login has finished, so the cube can be told things.
    ///
    /// **The two LED values go out on every connection**, for the reason at the top: nothing can read them back, so
    /// there is no such thing as knowing whether the cube still has them. The other two are already on their way if
    /// the cube's own answers disagreed with the tables, those answers having arrived during the login.
    func linkSettled() {
        isLinkSettled = true
        let isConnected = isCubeConnected()
        guard isConnected, !wasCubeConnected else {
            debugLog?.record(
                .command,
                isConnected
                    ? "The login settled again on a cube already told its settings, so nothing is sent"
                    : "The login settled on a cube that is no longer connected, so there is nothing to tell"
            )
            run()
            return
        }
        wasCubeConnected = true
        queue(.ledBrightness, because: "the cube connected and nothing can read this back")
        queue(.blinkInterval, because: "the cube connected and nothing can read this back")
        run()
    }

    /// What the cube says it is doing, which carries the auto-pause delay it is actually set to.
    ///
    /// **Arrives on every login and after every command this app reads back**, so a disagreement is noticed at the
    /// first moment it can be. A cube that agrees costs nothing: the comparison is two integers.
    func cubeReported(status: DeviceCommandRules.Status) {
        let wanted = stored().autoPauseMinutes
        guard status.autoPauseMinutes != wanted else { return }
        queue(
            .autoPause,
            because: "the cube says its auto-pause is \(status.autoPauseMinutes)m and the table says \(wanted)m"
        )
        run()
    }

    /// What the cube says its double-tap registers are, read by the login on every connection.
    ///
    /// **Compared against what should be on it**, which is not what is stored: the gesture is disabled by sending
    /// `window` 0, so a cube with the gesture off should report the zeroed form rather than the values the tab shows.
    func cubeReported(doubleTap reported: DoubleTapParameters) {
        let wanted = stored().doubleTapAsSent
        guard reported != wanted else { return }
        queue(.doubleTap, because: "the cube says its double tap is \(reported.described) and the table says \(wanted.described)")
        run()
    }

    /// The cube saying it has lost something (`DeviceSystemStateRules.CubeSyncState`).
    ///
    /// **Answered per setting, and only for the ones this app is the record of.** A cube asking for its task
    /// parameters is asking for something nothing in this app has ever set, and saying so is more honest than
    /// silence -- it is the one request here that cannot be answered at all.
    func cubeAsked(for sync: DeviceSystemStateRules.CubeSyncState) {
        guard let setting = Self.setting(for: sync) else {
            if sync == .taskParametersRequired {
                debugLog?.record(
                    .command,
                    "The cube wants its task parameters, which this app has never set, so there is nothing to send"
                )
            }
            return
        }
        // **Counted rather than answered while the login is still talking**, which is when this cube does most of
        // its asking: `linkSettled` is a moment away, and what it sends covers most of what is being asked for.
        guard isLinkSettled else {
            suppressed[setting, default: 0] += 1
            debugLog?.record(
                .command,
                "The cube asked for a setting while the login was still talking, so the link coming up answers it"
            )
            return
        }
        if let answered = answeredAt[setting], now().timeIntervalSince(answered) < Self.cooldownSeconds {
            suppressed[setting, default: 0] += 1
            return
        }
        if let count = suppressed[setting], count > 0 {
            debugLog?.record(.command, "Collapsed \(count) repeat requests from the cube into this one")
            suppressed[setting] = 0
        }
        answeredAt[setting] = now()
        queue(setting, because: "the cube asked for it")
        run()
    }

    /// The link went. Drops whatever was still queued for a cube that is no longer there.
    ///
    /// **Not left to fail one command at a time**, and the run is stood down as well as emptied: a command out when
    /// the link goes is never completed, so `step` is never called back and a flag left true would make `run` return
    /// early for the rest of the launch. That is `FaceColourSync.linkEnded`'s hard-won note, and it applies here
    /// unchanged.
    func linkEnded() {
        if !queue.isEmpty {
            debugLog?.record(.command, "The link went, so \(queue.count) setting(s) still to send are dropped")
            queue.removeAll()
        }
        answeredAt.removeAll()
        suppressed.removeAll()
        isLinkSettled = false
        wasCubeConnected = false
        isSending = false
    }

    /// Which setting a request is about, or `nil` for one nothing here can answer.
    static func setting(for sync: DeviceSystemStateRules.CubeSyncState) -> Setting? {
        switch sync {
        case .timeRequired: return .clock
        case .autoPauseRequired: return .autoPause
        case .ledBrightnessRequired: return .ledBrightness
        case .blinkIntervalRequired: return .blinkInterval
        // **Face colours are not here on purpose**: they are `FaceColourSync`'s, which answers that request itself
        // and knows how to pace twelve writes. Two answers to one request would be two runs of commands.
        case .faceColoursRequired, .taskParametersRequired, .ok, .factoryReset, .unknown: return nil
        }
    }

    private func queue(_ setting: Setting, because reason: String) {
        guard isCubeConnected() else {
            debugLog?.record(.command, "No cube connected, so \(reason) tells it nothing")
            return
        }
        // **Never two entries for one setting**: the value is read when the command is built, so a second entry would
        // send the same value twice.
        guard !queue.contains(where: { $0.setting == setting }) else { return }
        queue.append((setting: setting, reason: reason))
    }

    private func run() {
        // Nothing goes out until the login has finished its own questions. See `isLinkSettled`.
        guard isLinkSettled, !isSending, !queue.isEmpty else { return }
        isSending = true
        step()
    }

    /// One setting, then whatever is behind it.
    ///
    /// **The value is read here**, at the moment this command is built, which is `CLAUDE.md`'s rule read literally: a
    /// setting queued a second ago and edited since goes out as what it is now.
    private func step() {
        guard let next = queue.first else {
            isSending = false
            return
        }
        queue.removeFirst()
        let held = stored()
        let command = Self.command(for: next.setting, from: held, now: now())
        debugLog?.record(.command, "Telling the cube \(Self.describe(next.setting, from: held)) (\(next.reason))")
        send(command) { [weak self] took in
            guard let self else { return }
            // **"Took" means different things for different commands, and the log says which.** Auto-pause, the
            // registers and the clock are read back by `DeviceLogin.send` before it answers; the two LED values
            // cannot be, so for those this is the cube taking the bytes and nothing more.
            self.debugLog?.record(
                .command,
                took
                    ? "The cube took \(Self.describe(next.setting, from: held))"
                    : "The cube would not take \(Self.describe(next.setting, from: held))"
            )
            self.step()
        }
    }

    private static func command(for setting: Setting, from stored: Stored, now: Date) -> Data {
        switch setting {
        case .autoPause: return DeviceCommandRules.autoPause(stored.autoPauseMinutes)
        case .ledBrightness: return DeviceCommandRules.ledBrightness(stored.ledBrightnessPercent)
        case .blinkInterval: return DeviceCommandRules.ledBlink(stored.ledBlinkSeconds)
        case .doubleTap: return DoubleTapRules.command(for: stored.doubleTapAsSent)
        case .clock: return DeviceCommandRules.setTime(UInt64(max(0, now.timeIntervalSince1970)))
        }
    }

    private static func describe(_ setting: Setting, from stored: Stored) -> String {
        switch setting {
        case .autoPause: return "auto-pause \(stored.autoPauseMinutes)m"
        case .ledBrightness: return "LED brightness \(stored.ledBrightnessPercent)%"
        case .blinkInterval: return "blink period \(stored.ledBlinkSeconds)s"
        case .doubleTap: return "double tap \(stored.doubleTapAsSent.described)"
        case .clock: return "the time"
        }
    }
}

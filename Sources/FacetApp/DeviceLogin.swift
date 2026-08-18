import CoreBluetooth
import Foundation

/// One connected cube, from a live link to a verdict on a PIN, and then to a PIN of the app's own choosing.
///
/// **A conversation, not a session.** It discovers the characteristics a login needs, writes the PIN, reads what the
/// cube says about it, sets a new one if there is one to set, and reports. It does not decide which PIN to send
/// (`DeviceLoginRules.candidates`), what to change it to (`DeviceLoginRules.rotation`, from a target handed in), what
/// an answer means (`DeviceLoginRules.verdict`), or where a new PIN is written down (`DeveloperConfigFile`, through
/// the caller); and it connects and disconnects nothing (`BluetoothRadio`, which owns the central manager because
/// CoreBluetooth insists one object does).
///
/// **It outlives the login, deliberately.** Once a PIN is accepted this stays the peripheral's delegate, so anything
/// the cube says afterwards still reaches the trace. Without that, the first thing to notice an unsolicited
/// notification would be whichever feature went looking for one, and the bytes before it would be gone.
///
/// **Reading what the cube says it is happens there, after the verdict.** The four Device Information strings the
/// Device tab shows are not part of a login and cannot change one -- a cube that answers none of them is logged in
/// exactly the same -- so they are read once the outcome is out and reported separately. The reason
/// they are read *here* rather than by some object of their own is CoreBluetooth's, not a preference:
/// `CBPeripheral.delegate` is one delegate, this is it, and a second reader would have to take it away mid-connection.
///
/// **Massaged from `TimeFlipBLEDevice`'s probe.** The archive's `probeConnect` / `probeDiscoverTimeFlipCharacteristics`
/// / `probeAttemptLogin` are the same four steps in the same order, and its central insight is kept: verify a
/// candidate on a connection of its own before letting it near anything the app depends on. What is not kept is the
/// shape -- five continuations, a parallel `ProbeSession` mirror of every piece of live state, and a `Task`-based
/// watchdog per step, all inside a 2,481-line class that was also the event source, the history reader and the
/// settings writer. The steps here are the delegate callbacks themselves, in order, with one deadline over the lot.
///
/// **`rotateDevicePassword` is massaged in the same way**: same command, same order, and the same insight kept, that
/// the only proof a cube took a new PIN is a login with it. What changes is that it is no longer a separate `async`
/// method the app remembers to call after connecting -- setting the PIN is part of reaching a cube, so it is two more
/// steps of this exchange rather than a second one that could be skipped.
@MainActor
final class DeviceLogin: NSObject {
    /// How long the whole exchange gets, from a live connection to a verdict, including setting a new PIN.
    ///
    /// One deadline rather than one per step, because a cube that stops answering stops answering: which step it was
    /// on is a thing for the log to say, not a thing to give its own budget to. Generous against the archive's
    /// measurements, where the whole of connect-and-link never exceeded 5.4 seconds and setting a PIN and confirming
    /// it added 236-266ms on top (n=6, `Archive/TimeFlipApp/MockTimeFlipDevice.swift`).
    static let timeoutSeconds: TimeInterval = 15

    /// How long the Device Information reads get, once the login is over.
    ///
    /// **Its own deadline rather than a share of the login's**, because it starts after the login's has been put
    /// down. Shorter than the login's, too: these are four plain reads on an established link with no command channel
    /// and no password in the way, so a cube that has not answered in ten seconds is not going to.
    static let infoTimeoutSeconds: TimeInterval = 10

    /// Where the exchange has got to, and so what an arriving value is the answer to.
    ///
    /// **The command result characteristic answers every question**, so without this a value on it is unattributable:
    /// the same three bytes mean "your PIN was right", "your command worked" and "your new PIN was right" depending
    /// only on what was asked last. It replaces the single flag this class had when a login was the whole exchange.
    private enum Step {
        /// Waiting for the cube's verdict on the PIN presented on connecting.
        case presenting
        /// Waiting for what the cube makes of the `0x30` that sets a new one.
        case setting
        /// Waiting for the verdict on the new PIN, presented as a real login.
        case confirming
    }

    private let peripheral: CBPeripheral
    private let pin: String
    private let rotatingTo: String?
    private let debugLog: DebugLog?
    /// Whether a successful login should go on to follow the cube: ask what it is, and subscribe to its charge.
    ///
    /// **Off for a reset confirmation**, which is the one login that is not the app reaching a device: it exists only
    /// to prove a wipe, the link is dropped the instant it succeeds, and asking a cube being given up what it is spends
    /// four round trips on an answer nothing will record -- and puts `Asking the cube what it is` in the log at the
    /// exact moment the app is letting go, which reads as the opposite of what happened. A battery subscription on
    /// that link is the same waste one step worse: it would be taken out again milliseconds later.
    ///
    /// **It was `readsDeviceInfo`**, and the rename is what the flag always meant. Reading the four strings was
    /// simply the only thing a kept connection did at the time.
    private let staysWithTheCube: Bool

    private let rotated: (String) -> Void
    private let reported: (DeviceInfo) -> Void
    /// Called with each battery percentage the cube reports, whether asked for or pushed. Raw, exactly as the byte
    /// arrived: what to *show* for a run of readings is `BatteryRules`' judgement and not a delegate's.
    private let battery: (Int) -> Void
    /// Called with each face the cube reports, whether asked for or pushed. Raw, exactly as the byte arrived: what
    /// counts as a face is `DeviceFaceRules`' judgement, not a delegate's.
    private let face: (Int) -> Void
    /// Called with whatever the cube last said about its own state, however that answer was drawn out -- the ask on
    /// connecting, or the read-back of a command. Raw: what to make of it is the radio's and the menu's business.
    private let status: (DeviceCommandRules.Status) -> Void
    private let finished: (DeviceLoginOutcome) -> Void

    private var deadline: Timer?
    private var isFinished = false
    private var password: CBCharacteristic?
    private var commandResult: CBCharacteristic?
    private var command: CBCharacteristic?
    private var step: Step?
    /// The PIN being set, from the moment the cube is asked to take it. Held because the confirmation presents it
    /// again and the caller is told it only once the cube has proved it.
    private var newPIN: String?

    /// The factory reset, which is a phase of its own for the same reason the Device Information reads are: it runs
    /// long after the login is over, on a connection this object is still the delegate of.
    private var isResetting = false
    private var resetDeadline: Timer?
    private var resetReported: ((Bool) -> Void)?

    /// The command that has been written and not yet settled, and what to tell about it. See `send`.
    private var pendingCommand: ((Bool) -> Void)?
    /// How that command is read back, or `nil` for one the spec gives no way to read back.
    private var pendingReadBack: DeviceCommandRules.ReadBack?
    /// Who is waiting on a plain question about the cube's state. See `askStatus`.
    private var pendingStatus: ((DeviceCommandRules.Status?) -> Void)?
    /// Whether the question has been sent, so an acknowledgement is the question's rather than the command's. The two
    /// arrive on the same characteristic and are otherwise indistinguishable.
    private var isReadingBack = false
    private var commandDeadline: Timer?

    /// The Device Information phase, which runs after the login and has nothing to do with `Step`.
    ///
    /// **Kept apart from the login's state on purpose.** `Step` exists because one characteristic answers three
    /// different questions and a value on it is otherwise unattributable; these four each have a characteristic of
    /// their own, so what an arriving value is the answer to is simply which one it came from. Sharing `Step` would
    /// have meant inventing an ambiguity the hardware does not have.
    private var isReadingInfo = false
    /// The battery phase, which follows the Device Information one and then never ends: the subscription stays up for
    /// as long as the connection does, so the last thing this object does is go on receiving.
    private var isFollowingBattery = false
    /// The listening phase, which subscribes to everything the cube can push. Never ends.
    private var isListening = false
    /// Whether a `0x17` is out and its answer still expected.
    private var isAskingAboutTaps = false
    private var tapDeadline: Timer?
    /// The characteristics asked for and not yet answered. Built from what discovery actually found rather than from
    /// the four that were asked for, so a cube missing one does not leave this waiting on a read nobody will answer.
    private var awaitingInfo: Set<CBUUID> = []
    private var info = DeviceInfo()
    private var infoDeadline: Timer?

    /// - Parameters:
    ///   - pin: the PIN to present on this connection.
    ///   - rotatingTo: what to set the cube's PIN to once it has let the app in, or `nil` to leave it as it is.
    ///     Handed in rather than read here, for the reason `BluetoothRadio` gives about deciding nothing.
    ///   - rotated: called with the new PIN at the moment the cube has proved it took it, and before the outcome is
    ///     reported. That order is the point of it: the app must have written the PIN down before anything downstream
    ///     acts on a connection that now depends on knowing it.
    ///   - reported: called with what the cube says it is, once the Device Information reads have come back or given
    ///     up. **After the outcome, not before**, which is the opposite order to `rotated` and deliberately so: the
    ///     PIN is something the login changed and must be written down before anything acts on it, while this is
    ///     something the cube already was and nothing downstream is waiting on.
    ///   - battery: called with each percentage the cube reports, for as long as the connection lasts. Called many
    ///     times rather than once, which is what makes it unlike `reported`: the charge is something the cube goes on
    ///     saying, and the first call is the app's own read rather than something the cube volunteered.
    ///   - face: called with each face the cube reports, on the same terms as `battery` and for the same reason -- the
    ///     first call is the read this login makes, and every one after it is a flip.
    ///   - status: called whenever the cube says what state it is in -- once on connecting, and again every time a
    ///     command is read back. Unlike the two above, the cube never volunteers this: nothing is pushed when a
    ///     double tap pauses it, so what arrives here is only ever an answer to a question this app asked.
    init(
        peripheral: CBPeripheral,
        pin: String,
        rotatingTo: String?,
        debugLog: DebugLog?,
        staysWithTheCube: Bool = true,
        rotated: @escaping (String) -> Void,
        reported: @escaping (DeviceInfo) -> Void,
        battery: @escaping (Int) -> Void = { _ in },
        face: @escaping (Int) -> Void = { _ in },
        status: @escaping (DeviceCommandRules.Status) -> Void = { _ in },
        finished: @escaping (DeviceLoginOutcome) -> Void
    ) {
        self.peripheral = peripheral
        self.pin = pin
        self.rotatingTo = rotatingTo
        self.debugLog = debugLog
        self.staysWithTheCube = staysWithTheCube
        self.rotated = rotated
        self.reported = reported
        self.battery = battery
        self.face = face
        self.status = status
        self.finished = finished
        super.init()
    }

    /// Starts the exchange on a peripheral that is already connected.
    func begin() {
        peripheral.delegate = self
        deadline?.invalidate()
        deadline = Timer(timeInterval: Self.timeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.debugLog?.record(.login, "The cube stopped answering part way through the login")
                self?.finish(.timedOut)
            }
        }
        if let deadline { RunLoop.main.add(deadline, forMode: .common) }
        // Only the TimeFlip service. Anything else the cube exposes belongs to whatever reads it, and asking for
        // everything here would be several round trips spent in front of the one answer somebody is waiting for --
        // which is why Device Information is discovered separately once the verdict is out (`readDeviceInfo`), and
        // why battery will be too.
        discoverServices([TimeFlipUUIDs.service])
    }

    private func finish(_ outcome: DeviceLoginOutcome) {
        guard !isFinished else { return }
        isFinished = true
        step = nil
        deadline?.invalidate()
        deadline = nil
        finished(outcome)
        // **Only once the verdict is out, and never in front of it.** A cube that will not say what it is is still a
        // cube the app reached, so nothing about these four reads is allowed to delay a pairing, colour an outcome or
        // fail one. Putting them here rather than inside `loggedIn` also covers both ways a login succeeds -- with a
        // new PIN set and without.
        if outcome == .loggedIn, staysWithTheCube { readDeviceInfo() }
    }

    // MARK: - putting the cube back to the factory

    /// Sends `0xFF`, and reports whether the cube took the write.
    ///
    /// **The acknowledgement is the whole answer, and that is the archive's measurement rather than a shortcut.**
    /// `DeviceLoginRules.factoryReset` records what it found: the cube reboots without writing a fresh command result,
    /// so the characteristic still holds the previous command's bytes and reading it would be reading somebody else's
    /// answer. `.withResponse` is therefore doing real work here -- it is the only evidence that exists.
    ///
    /// **What it does not tell you is whether the erase completed.** The write landing means the cube heard the
    /// command; the archive confirmed the rest out of band, by waiting for the device to come back on the vendor PIN
    /// (`ApplicationDelegate.factoryResetConfirmDeadline`). This app has no reconnect loop to do that in, so what it
    /// does instead is refuse to throw away the one thing that would be needed to find a cube whose wipe silently
    /// failed -- see `DevicePairingRecorder.recordFactoryReset`.
    func factoryReset(_ reported: @escaping (Bool) -> Void) {
        guard let command else {
            debugLog?.record(.pair, "This cube has no command characteristic, so it cannot be reset")
            reported(false)
            return
        }
        isResetting = true
        resetReported = reported
        resetDeadline?.invalidate()
        resetDeadline = Timer(timeInterval: Self.infoTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.debugLog?.record(.pair, "The cube never acknowledged the reset command")
                self?.finishReset(false)
            }
        }
        if let resetDeadline { RunLoop.main.add(resetDeadline, forMode: .common) }
        let payload = Data([DeviceLoginRules.factoryReset])
        debugLog?.record(.pair, "Sending the factory reset command")
        write(payload, to: command, type: .withResponse)
    }

    // MARK: - telling the cube to do something

    /// Sends one command, reads back whether it took, and reports **that**.
    ///
    /// **The read-back is here rather than at the call site, so no caller can forget it** -- which is the rule in
    /// `CLAUDE.md`: a command the cube can be asked about is read back before it is believed. `DeviceCommandRules
    /// .readBack(for:)` says which question confirms which command, and for a command the spec gives no read for it
    /// answers `nil` -- in which case what is reported is the acknowledgement, and the log says so in those words
    /// rather than claiming a confirmation nobody made.
    ///
    /// **An acknowledgement is weaker evidence than it looks**, which is why it is not the answer on its own.
    /// `.withResponse` says the bytes reached the device at the ATT layer, and the cube refuses commands until a PIN
    /// has been accepted -- *after* the write has already succeeded. So a command can be acknowledged and have done
    /// nothing.
    ///
    /// **One at a time.** A second command sent while the first is still out would take the first's acknowledgement
    /// for its own, both arriving on the same characteristic with nothing to tell them apart -- and the read-back
    /// makes that worse, since a `0x10` answer carries no echoed command byte either. The refusal is reported rather
    /// than queued: what to do about a busy cube is the caller's question.
    func send(_ payload: Data, then reported: @escaping (Bool) -> Void) {
        guard let command else {
            debugLog?.record(.command, "This cube has no command characteristic, so there is nothing to send to")
            reported(false)
            return
        }
        guard !isBusy else {
            debugLog?.record(.command, "A command is already out; not sending another over the top of it")
            reported(false)
            return
        }
        pendingCommand = reported
        pendingReadBack = DeviceCommandRules.readBack(for: payload)
        isReadingBack = false
        armCommandDeadline()
        // The bytes themselves go into the trace as `ble-tx` by `write`, so what this row adds is why they went.
        debugLog?.record(.command, "Sending \(BLETrace.describe(payload))")
        write(payload, to: command, type: .withResponse)
    }

    /// Asks the cube what state it is in (`0x10`), and reports what it says.
    ///
    /// **The same exchange as a read-back with the command left off**, because that is what it is: the question is
    /// written, its acknowledgement is waited for, and only then is the answer read. The waiting matters as much here
    /// as it does there -- a `0x10` reply carries no echoed command byte, and the characteristic it arrives on
    /// frequently holds the previous command's reply, so a value read at any other moment is somebody else's.
    ///
    /// `nil` for a cube that would not answer, which is a different thing from a cube that answered "unlocked".
    func askStatus(then answered: @escaping (DeviceCommandRules.Status?) -> Void) {
        guard let command else {
            debugLog?.record(.command, "This cube has no command characteristic, so there is nothing to ask")
            answered(nil)
            return
        }
        guard !isBusy else {
            debugLog?.record(.command, "A command is already out; not asking about state over the top of it")
            answered(nil)
            return
        }
        pendingStatus = answered
        // The acknowledgement about to arrive is this question's, not a command's.
        isReadingBack = true
        armCommandDeadline()
        debugLog?.record(.command, "Asking the cube what state it is in")
        write(DeviceCommandRules.status, to: command, type: .withResponse)
    }

    /// Whether an exchange is already out. Both kinds share one slot deliberately: they use the same characteristic
    /// and the same acknowledgement, so two at once could not be told apart.
    private var isBusy: Bool { pendingCommand != nil || pendingStatus != nil }

    private func armCommandDeadline() {
        commandDeadline?.invalidate()
        commandDeadline = Timer(timeInterval: Self.infoTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.debugLog?.record(
                    .command,
                    self.isReadingBack
                        ? "The cube never said whether the command took"
                        : "The cube never acknowledged the command"
                )
                self.finishExchange(took: false, status: nil)
            }
        }
        if let commandDeadline { RunLoop.main.add(commandDeadline, forMode: .common) }
    }

    /// The command was acknowledged. Either ask the cube whether it took, or stop here if nothing can ask.
    private func acknowledgedCommand(_ landed: Bool) {
        guard landed else {
            debugLog?.record(.command, "The cube would not take the command")
            finishExchange(took: false, status: nil)
            return
        }
        guard let readBack = pendingReadBack, let command else {
            // Said in these words on purpose. The three commands with no read command in the spec (`0x09`, `0x0A`,
            // `0x11`) end here for good, and a row reading "confirmed" would be a claim nobody is in a position to
            // make -- see the read-back matrix in `docs/timeflip.md`.
            debugLog?.record(.command, "The cube took the write; nothing can read this command back")
            finishExchange(took: true, status: nil)
            return
        }
        isReadingBack = true
        armCommandDeadline()
        debugLog?.record(.command, "Asking whether it took: \(BLETrace.describe(readBack.request))")
        write(readBack.request, to: command, type: .withResponse)
    }

    /// The read-back question was acknowledged, so its answer is the next thing on the command result.
    ///
    /// **Read only now, and never earlier.** A `0x10` answer carries no echoed command byte to identify it, and that
    /// characteristic frequently holds the previous command's reply, so the only thing that makes the value
    /// trustworthy is that it is read after this question's own acknowledgement.
    private func askedForConfirmation(_ landed: Bool) {
        guard landed, let commandResult else {
            debugLog?.record(.command, "The cube would not take the question")
            finishExchange(took: false, status: nil)
            return
        }
        read(commandResult)
    }

    /// What the cube said, whether it was asked to confirm a command or simply asked what state it is in.
    ///
    /// **Parsed in one place, whichever question brought it here**, so the state the app holds and the verdict on a
    /// command are read from the same bytes by the same rule rather than by two that could come to differ.
    private func answered(_ value: Data?) {
        let status = DeviceCommandRules.status(from: value)
        guard let readBack = pendingReadBack else {
            // **What the cube is does not get written down here**, though this is where the bytes are read. Saying it
            // is `BluetoothRadio.received(status:)`'s job and only its job: it holds the answer, and it records it
            // only when it is news. Both of us said it for a while, so one ask produced two identical rows and a log
            // read as though the cube had been asked twice.
            //
            // What is left is the case the radio never hears about. An answer that was not one reports no status at
            // all, so nothing downstream would mention it, and a question that went unanswered is worth a row.
            if status == nil {
                debugLog?.record(.command, "That was not an answer about the cube's state")
            }
            finishExchange(took: status != nil, status: status)
            return
        }
        let took = readBack.took(value)
        debugLog?.record(.command, took ? "The cube confirms it took" : "The cube says it did NOT take")
        finishExchange(took: took, status: status)
    }

    /// Ends whichever exchange was out, and tells whoever was waiting.
    ///
    /// **Both completions are cleared before either is called.** A caller told about one command is free to send the
    /// next from inside that call -- the lock sequence does exactly that -- and a slot still holding the finished
    /// exchange would refuse it as "already busy".
    private func finishExchange(took: Bool, status: DeviceCommandRules.Status?) {
        commandDeadline?.invalidate()
        commandDeadline = nil
        isReadingBack = false
        pendingReadBack = nil
        let reportCommand = pendingCommand
        let reportStatus = pendingStatus
        pendingCommand = nil
        pendingStatus = nil
        // Whatever the cube just said about its state is worth having whichever question drew it out, so this fires
        // for a read-back as well as for a plain ask.
        if let status { self.status(status) }
        reportCommand?(took)
        reportStatus?(status)
    }

    private func finishReset(_ sent: Bool) {
        guard isResetting else { return }
        isResetting = false
        resetDeadline?.invalidate()
        resetDeadline = nil
        let reported = resetReported
        resetReported = nil
        reported?(sent)
    }

    // MARK: - what the cube says it is

    /// Asks the cube for the Device Information service, once the login is over and the link is established.
    ///
    /// **This object is still the peripheral's delegate**, which is what makes reading after the login possible at
    /// all: `BluetoothRadio` holds it for exactly as long as the connection lasts, precisely so traffic that arrives
    /// after the verdict still has somewhere to land.
    ///
    /// **`begin` asked for the TimeFlip service alone and this asks for a second one**, rather than the two being
    /// discovered together at the start. That is the same reasoning `begin` gives, now paid off: a login that waited
    /// on a service it does not need would spend round trips in front of the only answer anybody is waiting for.
    private func readDeviceInfo() {
        isReadingInfo = true
        infoDeadline?.invalidate()
        infoDeadline = Timer(timeInterval: Self.infoTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.debugLog?.record(.info, "The cube stopped answering part way through saying what it is")
                self?.reportDeviceInfo()
            }
        }
        if let infoDeadline { RunLoop.main.add(infoDeadline, forMode: .common) }
        debugLog?.record(.info, "Asking the cube what it is")
        discoverServices([TimeFlipUUIDs.deviceInformation])
    }

    /// Hands over what arrived, whether that is four values, some of them, or none.
    ///
    /// **Reported even when it is empty**, so the caller can say so in the log rather than being left unable to tell
    /// a cube with no Device Information service from a read still in flight. What is *written down* is a separate
    /// question, and `DevicePairingRecorder.recordInfo` is where it is answered.
    private func reportDeviceInfo() {
        guard isReadingInfo else { return }
        isReadingInfo = false
        awaitingInfo = []
        infoDeadline?.invalidate()
        infoDeadline = nil
        debugLog?.record(
            .info,
            info.isEmpty
                ? "The cube said nothing about what it is"
                : "The cube says it is \(info.manufacturer ?? "?") \(info.model ?? "?"),"
                    + " hardware \(info.hardware ?? "?"), firmware \(info.firmware ?? "?")"
        )
        reported(info)
        // **Both ways out of the info phase come through here**, the four answers arriving and the deadline giving up
        // on them, which is why the charge is asked for from this one place: a cube with no Device Information service
        // still has a battery, and hanging the subscription off the success path would leave that cube's Battery row
        // reading "Unknown" for the whole connection.
        followBattery()
    }

    /// Files one answered read, and reports the lot once nothing is outstanding.
    private func received(_ value: Data?, for uuid: CBUUID) {
        guard awaitingInfo.remove(uuid) != nil else { return }
        let text = DeviceInfoRules.reported(value)
        switch uuid {
        case TimeFlipUUIDs.manufacturerName: info.manufacturer = text
        case TimeFlipUUIDs.modelNumber: info.model = text
        case TimeFlipUUIDs.hardwareRevision: info.hardware = text
        case TimeFlipUUIDs.firmwareRevision: info.firmware = text
        default: break
        }
        if awaitingInfo.isEmpty { reportDeviceInfo() }
    }

    // MARK: - what charge is left in it

    /// Asks the cube for its charge, and then asks it to keep saying.
    ///
    /// **A read and a subscription, in that order, and both are needed.** `docs/TimeFlip2 BLE Protocol v4.3.md` gives
    /// Battery Level (`0x2A19`) as read *and* notify, and the archived app's own traffic says why neither alone is
    /// enough: across eleven days on real hardware it made 13 battery reads and received 2,847 values, so almost
    /// everything arrives unasked -- but every one of those was a value the cube had **changed to**. It pushes on
    /// change and only on change (not one of the 2,834 unsolicited values repeated the level already held), so a
    /// subscription on its own leaves the app with nothing to show until the charge next moves, and the gaps between
    /// moves ran to over an hour. The read is what puts a figure on screen the moment a cube is reached; the
    /// subscription is what keeps it true afterwards, for nothing, with no polling anywhere.
    ///
    /// **No deadline on it**, unlike the Device Information reads. Nothing downstream is waiting on this to finish --
    /// there is no "finished" for a subscription that stays up as long as the link does -- so a timer here would have
    /// nothing to end. What a cube that never answers leaves behind is a Battery row reading "Unknown" and the two
    /// rows below saying which step it stopped at, which is the whole of what a deadline could have told anybody.
    private func followBattery() {
        isFollowingBattery = true
        debugLog?.record(.battery, "Asking the cube for its charge")
        discoverServices([TimeFlipUUIDs.batteryService])
    }

    // MARK: - hearing everything else it says

    /// Subscribes to every characteristic the cube can push, whether or not anything in this app reads it.
    ///
    /// **Because a cube can only be measured while somebody is listening.** CoreBluetooth delivers a notification
    /// only on a characteristic that has been subscribed to, so an app that subscribes to what its features need
    /// hears exactly what it already expected, and everything else the device volunteers is not "ignored" -- it is
    /// never sent at all, and leaves no trace that it could have been. This app currently reads the charge and
    /// nothing else, so without this the cube's faces, its double taps and its system state would all be invisible
    /// until the feature that wanted them was built, at which point their behaviour would have to be discovered from
    /// scratch. The trace is worth more than the quiet: `docs/timeflip2-firmware-observations.md` is entirely made of
    /// things nobody set out to measure.
    ///
    /// **By property, not by a list of UUIDs.** Everything whose `properties` carry `.notify` is subscribed to, so a
    /// characteristic this app has never heard of is subscribed to as well -- which is the point, and is more than a
    /// hardcoded list could do. `TimeFlipUUIDs.name(for:)` falls back to the bare UUID, so an unnamed one in the log
    /// is a genuine finding rather than a gap.
    ///
    /// **The archive subscribed to five and this subscribes to whatever there is**, which is the same instinct one
    /// step further: it listed faces, double tap, system state, events data and battery because it had a feature for
    /// each. What is kept is its reason for logging every arrival at the top of the delegate callback, before any
    /// dispatch, so a value nothing handles is still recorded rather than dropped a few lines later.
    private func listenToTheCube() {
        guard let service = peripheral.services?.first(where: { $0.uuid == TimeFlipUUIDs.service }) else { return }
        isListening = true
        // Everything, rather than the three the login needed: this is the phase whose job is to find out what there
        // is, and asking for a list would be assuming the answer.
        discoverCharacteristics(nil, of: service)
    }

    /// Subscribes to each one that says it can notify, and says so when a cube offers none.
    private func listen(to service: CBService, error: Error?) {
        guard error == nil else { return }
        let pushable = (service.characteristics ?? []).filter { $0.properties.contains(.notify) }
        guard !pushable.isEmpty else {
            debugLog?.record(.login, "Nothing on the TimeFlip service can notify, so there is nothing to listen to")
            return
        }
        for characteristic in pushable { subscribe(to: characteristic) }
        askWhichFaceIsUp(on: service)
        // The state question follows this one rather than sitting beside it -- see `askWhatStateItIsIn`.
        askWhatMakesADoubleTap()
    }

    /// Asks the cube which face it is resting on.
    ///
    /// **A read on top of the subscription, and both are needed** -- the same shape as the charge, for the same
    /// measured reason. A GATT subscription yields the *next* value and never the current one, and a cube that is not
    /// touched does not flip, so a subscription on its own leaves the app with no face at all until somebody moves the
    /// cube. That can be hours, and for all of them the tab would be showing nothing while the cube sat there knowing
    /// the answer. The read is what puts a face on screen at the moment the link comes up; the subscription taken out
    /// a few lines above is what keeps it true afterwards.
    ///
    /// **`R, N` is the vendor's own answer**, in `docs/TimeFlip2 BLE Protocol v4.3.md`'s characteristic table, and the
    /// archive read it at connect on exactly this reasoning. The round trip is in the evidence database:
    /// `read request faces` answered with `faces -> 02`.
    ///
    /// **No deadline**, matching the battery: nothing downstream waits on it, and a cube that never answers leaves the
    /// tab drawing what it drew before, plus the request itself in the trace.
    private func askWhichFaceIsUp(on service: CBService) {
        guard let faces = service.characteristics?.first(where: { $0.uuid == TimeFlipUUIDs.faces }) else {
            debugLog?.record(.face, "This cube has no faces characteristic, so there is no face to ask about")
            return
        }
        debugLog?.record(.face, "Asking the cube which face is up")
        read(faces)
    }

    /// Asks the cube what its accelerometer is set to (`0x17`), and writes the answer down.
    ///
    /// **A read, and only a read.** Nothing is compared against `double_tap_settings` and nothing is written back:
    /// that row is what the app would like the cube to be on, this is what it is actually running, and the two are
    /// different facts. Until something sends `0x16` they have no reason to agree, and pretending otherwise would be
    /// the app inventing a claim about hardware nobody has checked.
    ///
    /// **Worth asking on every connection** because it is the only explanation of a physical behaviour: the cube
    /// pauses its own tracking on a double tap, unconditionally, with no command to disable it
    /// (`Archive/Tests/Methods.md` Method 22), so how hard a knock has to be is the whole of what decides whether a
    /// desk being bumped stops somebody's timer.
    private func askWhatMakesADoubleTap() {
        guard let command else { return }
        isAskingAboutTaps = true
        tapDeadline?.invalidate()
        tapDeadline = Timer(timeInterval: Self.infoTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isAskingAboutTaps else { return }
                self.isAskingAboutTaps = false
                self.debugLog?.record(.tap, "The cube never said what its double-tap registers are")
                // Still asked. A cube that will not talk about its accelerometer may perfectly well answer about its
                // lock, and this is the one question the dropdown cannot draw itself without.
                self.askWhatStateItIsIn()
            }
        }
        if let tapDeadline { RunLoop.main.add(tapDeadline, forMode: .common) }
        write(Data([DoubleTapRules.read]), to: command, type: .withResponse)
    }

    /// Asks the cube whether it is locked and whether it is paused, once the link is up.
    ///
    /// **Because nothing else will ever say.** The cube pushes a face and a charge unasked, but it never volunteers
    /// its lock or pause state -- not when a double tap pauses it, not when auto-pause fires, and not when the
    /// vendor's app changes it. So the only way the app can know is to ask, and the only moments it can ask usefully
    /// are when the link comes up and after a command of its own.
    ///
    /// **This is what makes the Lock item on the dropdown honest.** Without it a freshly connected app would have to
    /// guess which way the item should read, and the guess it would have to make -- unlocked -- is exactly wrong for
    /// the cube this app itself locked on the way out last time.
    ///
    /// **Sent after the double-tap question has finished, not beside it.** Both write to the command characteristic
    /// and both wait for an answer on the command result, and neither an acknowledgement nor a `0x10` answer carries
    /// anything saying which question it belongs to -- so two in flight is two answers nobody can attribute. The face
    /// read above is safe to fire alongside them only because it has a characteristic of its own.
    private func askWhatStateItIsIn() {
        askStatus { _ in }
    }

    /// What the cube answered `0x17` with.
    ///
    /// A value that is not an answer to *this* question is logged and waited past rather than treated as a failure:
    /// the command result characteristic is shared, it now notifies as well as answering reads, and finding 2 in
    /// `docs/timeflip2-firmware-observations.md` is that it frequently holds somebody else's reply.
    private func taps(answered value: Data?) {
        guard let parameters = DoubleTapRules.parameters(from: value) else {
            debugLog?.record(.tap, "That was not an answer about double taps, so it is being waited past")
            return
        }
        isAskingAboutTaps = false
        tapDeadline?.invalidate()
        tapDeadline = nil
        debugLog?.record(.tap, "The cube's double tap is set to \(parameters.described)")
        askWhatStateItIsIn()
    }

    // MARK: - the PIN this app puts on it

    /// Runs once the cube has accepted a PIN: either the exchange is over, or there is a new PIN to set.
    private func loggedIn() {
        debugLog?.record(.login, "PIN accepted")
        guard let newPIN = DeviceLoginRules.rotation(from: pin, to: rotatingTo) else {
            debugLog?.record(
                .pin,
                rotatingTo == nil
                    ? "This build sets no PIN, so the cube keeps the one it accepted"
                    : "The cube is already on the PIN this build sets, so it is left alone"
            )
            finish(.loggedIn)
            return
        }
        guard let command else {
            // The service was there and the login worked, so this is a cube with a TimeFlip service that has no
            // command characteristic on it -- worth saying rather than failing over, since the link is fine and
            // everything the login promised has happened.
            debugLog?.record(.pin, "The cube has no command characteristic, so its PIN cannot be changed")
            finish(.loggedIn)
            return
        }
        self.newPIN = newPIN
        step = .setting
        // The value goes in the log as well as in the trace beneath it. It is the one thing here that cannot be
        // recovered from anywhere else if the write down the line fails, and a PIN somebody can read off a terminal
        // is the difference between a cube to reconnect and a cube to take the batteries out of.
        debugLog?.record(.pin, "Setting the cube's PIN to \(newPIN)")
        let payload = Data([DeviceLoginRules.setPIN]) + Data(newPIN.utf8)
        write(payload, to: command, type: .withResponse)
    }

    /// The cube's answer to `0x30`, which is read for the record and then not judged.
    ///
    /// **Nothing is concluded from these bytes, deliberately.** The vendor spec says nothing about what `0x30`
    /// answers, and finding 2 in `docs/timeflip2-firmware-observations.md` is that this characteristic is frequently
    /// not updated at all -- so a `02` here may be the cube agreeing, or it may be the login verdict still sitting in
    /// the characteristic from thirty milliseconds ago. Reading it costs one round trip and puts the real answer in
    /// the trace where a future measurement can be made from it; **the proof is the login that follows**, which is
    /// the archive's decision and the right one: a command's own acknowledgement is not evidence that the cube will
    /// honour it, and a PIN is exactly the value where believing that would be unrecoverable.
    private func settingAnswered() {
        guard let password, let newPIN else {
            finish(.newPINRefused)
            return
        }
        step = .confirming
        debugLog?.record(.pin, "Presenting \(newPIN), so the cube has to prove it took it")
        let data = Data(newPIN.utf8)
        write(data, to: password, type: .withResponse)
    }

    /// The verdict on the new PIN, which is what makes it the cube's PIN as far as this app is concerned.
    private func confirmationAnswered(_ value: Data?) {
        guard let newPIN, DeviceLoginRules.verdict(for: value) == .accepted else {
            // Not recorded, because it is not known to be true. The cube is on one of two PINs and both of them are
            // presented on the next attempt, which is what makes ending here safe rather than a lockout.
            debugLog?.record(.pin, "The cube would not log in with the new PIN, so it is not being recorded")
            finish(.newPINRefused)
            return
        }
        debugLog?.record(.pin, "The cube is now on \(newPIN)")
        rotated(newPIN)
        finish(.loggedIn)
    }
}


// MARK: - talking to it

/// Every request this class makes of the cube goes through one of these, and every one of them writes a `ble-tx` row
/// on the way past.
///
/// **Wrappers rather than a rule to remember**, which is the difference between a trace that is complete and one that
/// is complete until somebody adds a read. Before these existed the log held four `ble-tx` rows against twenty-two
/// inbound ones, because writes were traced at their call sites and reads, subscriptions and discoveries were not
/// traced at all -- so the log recorded the cube's half of a conversation whose other half was invisible.
extension DeviceLogin {
    func discoverServices(_ uuids: [CBUUID]) {
        debugLog?.discovering(services: uuids)
        peripheral.discoverServices(uuids)
    }

    /// `nil` asks for every characteristic the service has, which is what the listening phase wants: the point there
    /// is to find whatever the cube offers, including anything the spec does not mention.
    func discoverCharacteristics(_ uuids: [CBUUID]?, of service: CBService) {
        debugLog?.discovering(characteristics: uuids, of: service.uuid)
        peripheral.discoverCharacteristics(uuids, for: service)
    }

    func read(_ characteristic: CBCharacteristic) {
        debugLog?.requested(characteristic.uuid)
        peripheral.readValue(for: characteristic)
    }

    func subscribe(to characteristic: CBCharacteristic) {
        debugLog?.subscribing(true, to: characteristic.uuid)
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func write(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        debugLog?.transmitted(data, to: characteristic.uuid, type: type)
        peripheral.writeValue(data, for: characteristic, type: type)
    }
}

// `@preconcurrency`, for the reason given on `BluetoothRadio`'s conformance: the manager is created with
// `queue: .main`, so these arrive on the main thread, and a `CBPeripheral` has no value form to carry across.
extension DeviceLogin: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Traced before it is acted on, like every inbound thing here.
        debugLog?.discovered(services: peripheral.services?.map(\.uuid) ?? [], error: error)
        // The login's discovery, the Device Information one and the battery one land in the same callback, and which
        // is which is not in the arguments: `peripheral.services` accumulates, so by the third call it holds all
        // three. The phase is what tells them apart, and they are checked first so a late failure cannot be read as a
        // login that never happened. The phases run in sequence and never overlap, which is what lets one flag each
        // be enough.
        if isFollowingBattery {
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == TimeFlipUUIDs.batteryService })
            else {
                debugLog?.record(
                    .battery,
                    error.map { "Looking for the Battery service failed: \($0.localizedDescription)" }
                        ?? "This cube has no Battery service, so there is no charge to report"
                )
                isFollowingBattery = false
                listenToTheCube()
                return
            }
            discoverCharacteristics([TimeFlipUUIDs.batteryLevel], of: service)
            return
        }
        if isReadingInfo {
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == TimeFlipUUIDs.deviceInformation })
            else {
                debugLog?.record(
                    .info,
                    error.map { "Looking for the Device Information service failed: \($0.localizedDescription)" }
                        ?? "This cube has no Device Information service"
                )
                reportDeviceInfo()
                return
            }
            discoverCharacteristics(TimeFlipUUIDs.deviceInformationCharacteristics, of: service)
            return
        }
        if let error {
            debugLog?.record(.login, "Service discovery failed: \(error.localizedDescription)")
            finish(.unreachable)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == TimeFlipUUIDs.service }) else {
            // **This is what tells a TimeFlip from anything else that answered the scan**, and it is a better test
            // than the name the filter used to get here: names are chosen by people and this is the hardware saying
            // what it is.
            debugLog?.record(.login, "No TimeFlip service on this device")
            finish(.notATimeFlip)
            return
        }
        discoverCharacteristics(
            [TimeFlipUUIDs.password, TimeFlipUUIDs.commandResult, TimeFlipUUIDs.command], of: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        debugLog?.discovered(
            characteristics: (service.characteristics ?? []).map(\.uuid), of: service.uuid, error: error
        )
        // **Before the login's branch below**, which is the one that writes a PIN: the listening phase asks the
        // TimeFlip service for its characteristics a second time, and without this that answer would be read as a
        // login starting over.
        if isListening, service.uuid == TimeFlipUUIDs.service {
            listen(to: service, error: error)
            return
        }
        if service.uuid == TimeFlipUUIDs.batteryService {
            guard error == nil,
                  let characteristic = service.characteristics?
                      .first(where: { $0.uuid == TimeFlipUUIDs.batteryLevel })
            else {
                debugLog?.record(
                    .battery,
                    error.map { "Battery discovery failed: \($0.localizedDescription)" }
                        ?? "The Battery service has no level characteristic"
                )
                isFollowingBattery = false
                listenToTheCube()
                return
            }
            // The pull, then the push. Both are queued on the same connection and CoreBluetooth serialises them, so
            // the order here is the order they happen: a figure now, and every change to it after that.
            read(characteristic)
            subscribe(to: characteristic)
            listenToTheCube()
            return
        }
        if service.uuid == TimeFlipUUIDs.deviceInformation {
            if let error {
                debugLog?.record(.info, "Device Information discovery failed: \(error.localizedDescription)")
                reportDeviceInfo()
                return
            }
            // Only the four that are actually there. A cube exposing three of them answers three reads and reports
            // three values, rather than the whole lot timing out behind one that was never going to arrive.
            let wanted = Set(TimeFlipUUIDs.deviceInformationCharacteristics)
            let present = (service.characteristics ?? []).filter { wanted.contains($0.uuid) }
            awaitingInfo = Set(present.map(\.uuid))
            guard !present.isEmpty else {
                debugLog?.record(.info, "The Device Information service has none of the four values")
                reportDeviceInfo()
                return
            }
            for characteristic in present { read(characteristic) }
            return
        }
        if let error {
            debugLog?.record(.login, "Characteristic discovery failed: \(error.localizedDescription)")
            finish(.unreachable)
            return
        }
        for characteristic in service.characteristics ?? [] {
            // The properties go in the log because they are the answer to "why did that write do nothing": a
            // characteristic that turns out not to be writable is invisible otherwise.
            debugLog?.record(
                .login,
                "Found characteristic \(TimeFlipUUIDs.name(for: characteristic.uuid))"
                    + " (properties 0x\(String(characteristic.properties.rawValue, radix: 16)))"
            )
            switch characteristic.uuid {
            case TimeFlipUUIDs.password: password = characteristic
            case TimeFlipUUIDs.commandResult: commandResult = characteristic
            case TimeFlipUUIDs.command: command = characteristic
            default: break
            }
        }
        // The command characteristic is not in this guard, and that is the difference between what a login needs and
        // what setting a PIN needs: a cube without it can still be reached, and `loggedIn` says so at the point the
        // PIN would have been set.
        guard let password, commandResult != nil else {
            debugLog?.record(.login, "The TimeFlip service is missing the characteristics a login needs")
            finish(.notATimeFlip)
            return
        }
        let data = Data(pin.utf8)
        debugLog?.record(.login, "Presenting a PIN")
        // `.withResponse`, so a write that the cube refused is distinguishable from one it took. The verdict is read
        // only once that acknowledgement arrives, since reading before the cube has processed the write is how a
        // stale command result gets mistaken for an answer.
        step = .presenting
        write(data, to: password, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        debugLog?.acknowledged(characteristic.uuid, error: error)
        // Both of these run long after the login, when `step` is nil, so they are asked before the guard below that
        // would otherwise discard the acknowledgement they are waiting on.
        if isAskingAboutTaps, characteristic.uuid == TimeFlipUUIDs.command, let commandResult {
            guard error == nil else {
                isAskingAboutTaps = false
                debugLog?.record(.tap, "The cube would not take the question about double taps")
                return
            }
            read(commandResult)
            return
        }
        if isResetting, characteristic.uuid == TimeFlipUUIDs.command {
            finishReset(error == nil)
            return
        }
        // Also long after the login, and above the guard for the same reason. Last of the three, so a reset or a
        // question about taps cannot have its acknowledgement taken by a command that happened to be out.
        if isBusy, characteristic.uuid == TimeFlipUUIDs.command {
            if isReadingBack {
                askedForConfirmation(error == nil)
            } else {
                acknowledgedCommand(error == nil)
            }
            return
        }
        guard let step else { return }
        // The reason is already in the row above; what matters here is that the cube never took the write, so there
        // is nothing to read an answer from. Which step it happened on decides what it means: a refused PIN write is
        // a link that has gone, while a refused command or confirmation is a PIN that did not get set.
        if error != nil {
            finish(step == .presenting ? .unreachable : .newPINRefused)
            return
        }
        // Every step reads the same characteristic for its answer; what differs is where the write went.
        let awaited = step == .setting ? TimeFlipUUIDs.command : TimeFlipUUIDs.password
        guard characteristic.uuid == awaited, let commandResult else { return }
        read(commandResult)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // **Logged before anything is made of it, and logged whatever it is.** This is the single point every
        // inbound byte passes through, so a value this app has no handler for is recorded here rather than dropped
        // silently a few lines down -- which is the archive's reasoning at its own version of this line, and half of
        // what makes the trace worth having. The other half is `listenToTheCube`: a characteristic nobody subscribed
        // to is not ignored, it is never delivered.
        debugLog?.received(characteristic.value, from: characteristic.uuid, error: error)
        // **The one value that arrives both ways**: the read this app asked for on connecting, and every notification
        // the cube sends afterwards. They are indistinguishable here and do not need to be told apart -- a percentage
        // is a percentage however it got here, and `BluetoothRadio` judges a run of them rather than each one.
        if characteristic.uuid == TimeFlipUUIDs.batteryLevel {
            guard error == nil, let level = characteristic.value?.first else {
                debugLog?.record(
                    .battery,
                    error.map { "The charge could not be read: \($0.localizedDescription)" }
                        ?? "The cube answered with no charge in it"
                )
                return
            }
            battery(Int(level))
            return
        }
        // **The other value that arrives both ways**, and on the same terms as the charge: the read this login makes
        // on connecting, and every flip afterwards. Which of the two it is does not matter here -- a face is a face
        // however it got here.
        if characteristic.uuid == TimeFlipUUIDs.faces {
            guard error == nil, let up = DeviceFaceRules.face(from: characteristic.value) else {
                debugLog?.record(
                    .face,
                    error.map { "The face could not be read: \($0.localizedDescription)" }
                        // The bytes themselves are already in the trace above, so what is worth saying here is that
                        // they were not a face this app will draw -- which is a different thing from silence.
                        ?? "The cube named no face this app recognises"
                )
                return
            }
            face(up)
            return
        }
        if isAskingAboutTaps, characteristic.uuid == TimeFlipUUIDs.commandResult, error == nil {
            taps(answered: characteristic.value)
            return
        }
        // The answer to "did it take". Asked for above the login's own guard for the same reason the taps question is:
        // it runs long after the login, when `step` is nil.
        if isReadingBack, characteristic.uuid == TimeFlipUUIDs.commandResult {
            answered(error == nil ? characteristic.value : nil)
            return
        }
        // Asked for before the login's own answer, because these have a characteristic each and so are attributable
        // on sight -- there is no `Step` to consult and nothing to disambiguate. An error is filed as an absence: the
        // cube did not say, which is the same thing to everyone downstream as a cube that had nothing to say.
        if isReadingInfo, awaitingInfo.contains(characteristic.uuid) {
            if let error {
                debugLog?.record(
                    .info,
                    "\(TimeFlipUUIDs.name(for: characteristic.uuid)) could not be read: \(error.localizedDescription)"
                )
            }
            received(error == nil ? characteristic.value : nil, for: characteristic.uuid)
            return
        }
        guard let step, characteristic.uuid == TimeFlipUUIDs.commandResult else { return }
        if error != nil {
            finish(step == .presenting ? .unreachable : .newPINRefused)
            return
        }
        switch step {
        case .presenting: presentationAnswered(characteristic.value)
        case .setting: settingAnswered()
        case .confirming: confirmationAnswered(characteristic.value)
        }
    }

    /// The verdict on the PIN this connection presented.
    private func presentationAnswered(_ value: Data?) {
        step = nil
        switch DeviceLoginRules.verdict(for: value) {
        case .accepted:
            loggedIn()
        case .rejected:
            debugLog?.record(.login, "PIN refused")
            finish(.wrongPIN)
        case .unreadable:
            // **Not counted as a refusal.** A cube that answered with something else has not said no, and treating
            // this as a wrong PIN would spend the next candidate on a question the cube never heard. It is also the
            // shape a stale command result takes (finding 2 in `docs/timeflip2-firmware-observations.md`), which is
            // the one case where the bytes in front of you belong to somebody else's command.
            debugLog?.record(.login, "The cube's answer to the PIN could not be read")
            finish(.timedOut)
        }
    }

    /// Whether the cube took a subscription, for every characteristic and not only the ones a feature reads.
    ///
    /// **A refused subscription and a characteristic that never changes are identical from here**: both are silence.
    /// Without this row a charge that stopped arriving would be indistinguishable from a charge that had not moved,
    /// and the app would go on showing a figure nobody could date.
    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        debugLog?.notifying(characteristic.uuid, isNotifying: characteristic.isNotifying, error: error)
    }

    /// Traffic that arrives once the login is over: a notification the cube sent unasked, or a read some later
    /// feature asked for. Nothing is done with it here beyond putting it in the trace, which is the point.
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        debugLog?.record(.login, "The cube now reports its name as \"\(peripheral.name ?? "")\"")
    }
}

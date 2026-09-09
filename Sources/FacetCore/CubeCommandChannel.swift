import Foundation

/// The command characteristic's one queue, and the read-back discipline that decides whether an answer on it is
/// this exchange's answer at all.
///
/// **One characteristic answers three different questions, which is the whole reason this exists.** A command, a
/// plain `0x10` question about the cube's state, and the `0x17` double-tap read all write to the command
/// characteristic and are answered on the command result, so two exchanges out at once cannot be told apart. What
/// this holds is therefore not a queue of writes but a queue of whole write-and-await exchanges: the hazard is a
/// second write going out before the first one's *reply* has been read.
///
/// **Moved out of `DeviceLogin` on 2026-09-09** (candidate 1 of `docs/architecture-review-2026-09.md`,
/// `handover-mac.md` item 15). It is a faithful extraction rather than a rewrite: every message, every ordering and
/// every guard below was already in that file, and the two measured traps it enforces are unchanged. What the move
/// buys is that all of it is now reachable without CoreBluetooth, which `DeviceLoginRulesTests` records as
/// impossible before it: a `CBPeripheral` cannot be built outside CoreBluetooth, so ~170 lines of the most
/// safety-critical sequencing in the app had no unit test and could not be given one.
///
/// **The transport is closures, which is the seam this codebase already uses for exactly this.** `CubeLock`,
/// `FaceColourSync` and `DeviceSettingsSync` each take `(Data, @escaping (Bool) -> Void) -> Void` and are tested to
/// 1,454 lines over 21 command sequences with no cube; the two modules that owned the channel took a
/// `CBPeripheral` instead and had no tests at all. This is the same seam, one layer down.
///
/// **What it deliberately does not own.** The double-tap read and the factory reset are exchanges too, and they
/// occupy this channel, but their characteristics and their deadlines live with the login. So they are asked about
/// through `isOtherExchangeInFlight` rather than moved, and whoever ends one calls `startNextIfIdle`.
@MainActor
package final class CubeCommandChannel {
    /// How long an exchange may go unanswered before it is given up on.
    ///
    /// Ten seconds, which is `DeviceLogin.infoTimeoutSeconds` and was the value this used there.
    package static let timeoutSeconds: TimeInterval = 10

    /// Writes to the command characteristic, with response. The acknowledgement comes back as `acknowledged`.
    private let transmit: (Data) -> Void
    /// Reads the command result characteristic. The value comes back as `resultArrived`.
    private let readResult: () -> Void
    /// Whatever the cube said about its own state, whichever question drew it out.
    private let status: (DeviceCommandRules.Status) -> Void
    /// Whether a double-tap read or a factory reset is occupying this channel. See the type's last paragraph.
    private let isOtherExchangeInFlight: () -> Bool
    /// How a payload is described in a log row. Injected because `BLETrace` is AppKit-side and does not move.
    private let describe: (Data) -> String
    private let debugLog: DebugLog?

    /// The command that has been written and not yet settled, and what to tell about it.
    private var pendingCommand: ((Bool) -> Void)?
    /// How that command is read back, or `nil` for one the spec gives no way to read back.
    private var pendingReadBack: DeviceCommandRules.ReadBack?
    /// Who is waiting on a plain question about the cube's state.
    private var pendingStatus: ((DeviceCommandRules.Status?) -> Void)?
    /// Whether the question has been sent, so an acknowledgement is the question's rather than the command's. The
    /// two arrive on the same characteristic and are otherwise indistinguishable.
    private var isReadingBack = false

    /// Exchanges waiting their turn, in the order they were asked for.
    ///
    /// **Waiting, not refused.** This channel used to answer `false` to anything arriving while it was busy, which
    /// made the caller believe the cube had declined. With twelve face colours going out on every connect that
    /// window is most of a second at the moment a user is most likely to press something: measured 2026-08-28, the
    /// scripted suite pressed Unlock 350ms after a link came up, both its commands were refused, and the run
    /// reported the cube would not unlock.
    ///
    /// **Nothing here survives the link going.** A queued exchange whose channel is discarded is released with its
    /// completion uncalled, which is what already happens to one in flight. Callers that hold state across a send
    /// must reset it when the link ends rather than wait for a completion that is not coming
    /// (`FaceColourSync.linkEnded`).
    private var waiting: [(describe: String, begin: () -> Void)] = []

    /// Held in its own object so it is invalidated when this goes away: a `@MainActor` class's `deinit` cannot
    /// touch the class's own non-Sendable properties. Same shape as `HistoryTimer.TimerHolder`, for that reason.
    private final class TimerHolder {
        var timer: Timer?

        deinit {
            timer?.invalidate()
        }
    }

    private let holder = TimerHolder()

    /// What the deadline in flight was armed with, and `nil` while nothing is out. Reported so the arming can be
    /// asserted without waiting ten seconds for it.
    package private(set) var scheduledSeconds: TimeInterval?

    package init(
        transmit: @escaping (Data) -> Void,
        readResult: @escaping () -> Void,
        status: @escaping (DeviceCommandRules.Status) -> Void = { _ in },
        isOtherExchangeInFlight: @escaping () -> Bool = { false },
        describe: @escaping (Data) -> String = { _ in "the command" },
        debugLog: DebugLog? = nil
    ) {
        self.transmit = transmit
        self.readResult = readResult
        self.status = status
        self.isOtherExchangeInFlight = isOtherExchangeInFlight
        self.describe = describe
        self.debugLog = debugLog
    }

    // MARK: - what a caller asks for

    /// Whether an exchange is already out on the command characteristic.
    ///
    /// **All three kinds count, and the third was missing until 2026-08-28.** A command, a plain question about the
    /// state, and the double-tap read all write to the same characteristic and are answered on the same one, so two
    /// at once could not be told apart. Only the first two set a `pending` slot, so a command sent during a `0x17`
    /// read sailed past this and was written over the top of it. Nothing refused it and nothing said so.
    package var isCommandInFlight: Bool {
        isOwnExchangeInFlight || isOtherExchangeInFlight()
    }

    /// An exchange *this* channel is running, as against one of the two it only knows about.
    ///
    /// The distinction matters exactly once, in `acknowledged`: a write acknowledgement arriving while a factory
    /// reset is out belongs to the reset, and the login has already dealt with it by then. Guarding on the composite
    /// there would be answering for somebody else's exchange.
    private var isOwnExchangeInFlight: Bool {
        pendingCommand != nil || pendingStatus != nil
    }

    /// Whether a value on the command result is this channel's to read.
    ///
    /// Reported so the login's delegate can keep asking the questions in the order it always has: the double-tap
    /// read is offered the value first, then this, then the login's own `Step`.
    package var isAwaitingResult: Bool { isReadingBack }

    /// Sends a command and reports whether the cube took it.
    ///
    /// `then` is called with `true` only where the cube's own answer says so, or where the command has no read-back
    /// defined and the write itself is all the evidence there is. It is never called from the write landing alone
    /// for a command that can be asked about.
    package func send(_ payload: Data, then reported: @escaping (Bool) -> Void) {
        enqueue("the command \(describe(payload))") { [weak self] in
            guard let self else {
                reported(false)
                return
            }
            self.pendingCommand = reported
            self.pendingReadBack = DeviceCommandRules.readBack(for: payload)
            self.isReadingBack = false
            self.armDeadline()
            // The bytes themselves go into the trace as `ble-tx` by the transport, so what this row adds is why
            // they went.
            self.debugLog?.record(.command, "Sending \(self.describe(payload))")
            self.transmit(payload)
        }
    }

    /// Asks the cube what state it is in (`0x10`), and reports what it says.
    ///
    /// **The same exchange as a read-back with the command left off**, because that is what it is: the question is
    /// written, its acknowledgement is waited for, and only then is the answer read. The waiting matters as much
    /// here as it does there. A `0x10` reply carries no echoed command byte, and the characteristic it arrives on
    /// frequently holds the previous command's reply, so a value read at any other moment is somebody else's.
    ///
    /// `nil` for a cube that would not answer, which is a different thing from a cube that answered "unlocked".
    package func askStatus(then answered: @escaping (DeviceCommandRules.Status?) -> Void) {
        enqueue("the question about the state of the cube") { [weak self] in
            guard let self else {
                answered(nil)
                return
            }
            self.pendingStatus = answered
            // The acknowledgement about to arrive is this question's, not a command's.
            self.isReadingBack = true
            self.armDeadline()
            self.debugLog?.record(.command, "Asking the cube what state it is in")
            self.transmit(DeviceCommandRules.status)
        }
    }

    // MARK: - what the transport reports

    /// A write to the command characteristic was acknowledged, or refused.
    ///
    /// **Which of the two things it acknowledges is `isReadingBack`**, and nothing else can tell them apart: the
    /// command and the question that asks whether the command took are both writes to the same characteristic.
    package func acknowledged(landed: Bool) {
        guard isOwnExchangeInFlight else { return }
        if isReadingBack {
            askedForConfirmation(landed)
        } else {
            acknowledgedCommand(landed)
        }
    }

    /// A value arrived on the command result characteristic.
    ///
    /// Ignored unless this channel is the one waiting for it, which is what keeps a reply meant for the double-tap
    /// read or for the login's own `Step` from being taken as a verdict on a command.
    package func resultArrived(_ value: Data?) {
        guard isReadingBack else { return }
        answered(value)
    }

    /// The deadline elapsed.
    ///
    /// **Package rather than private so a test can take the place of the run loop**, which is the pattern
    /// `HistoryTimer.fire`, `WriteDebounce.fire` and `LowBatteryWatch.fire` all use. On Linux a `@MainActor`
    /// swift-testing test does not run on the main thread, so a `Timer` on `RunLoop.main` never fires and a suite
    /// that waited on one would fail with nothing to show for it.
    package func fire() {
        debugLog?.record(
            .command,
            isReadingBack
                ? "The cube never said whether the command took"
                : "The cube never acknowledged the command"
        )
        finishExchange(took: false, status: nil)
    }

    /// Begins the next exchange, if there is one and nothing is out.
    ///
    /// **Package because the two exchanges this channel does not own have to be able to call it.** A factory reset
    /// or a double-tap read ending is exactly as much a reason to start the next thing as a command ending.
    package func startNextIfIdle() {
        guard !isCommandInFlight, !waiting.isEmpty else { return }
        waiting.removeFirst().begin()
    }

    /// Drops everything queued and anything in flight, without calling a completion.
    ///
    /// The link going is not an answer, and reporting one would be worse than reporting nothing: a caller told
    /// `false` cannot tell "the cube refused" from "there is no cube", and those have opposite remedies. This
    /// matches what already happened to an exchange in flight when its `DeviceLogin` was discarded.
    package func linkEnded() {
        holder.timer?.invalidate()
        holder.timer = nil
        scheduledSeconds = nil
        isReadingBack = false
        pendingReadBack = nil
        pendingCommand = nil
        pendingStatus = nil
        waiting.removeAll()
    }

    // MARK: - the sequence itself

    /// Puts an exchange in the queue and starts it if the channel is free.
    ///
    /// **One way in, so there is no path that skips the queue.** Every caller of the command characteristic goes
    /// through here, including the login's own questions: one that wrote directly would be exactly the fault this
    /// exists to remove.
    private func enqueue(_ what: String, _ begin: @escaping () -> Void) {
        waiting.append((describe: what, begin: begin))
        if isCommandInFlight {
            debugLog?.record(
                .command,
                "The command channel is busy, so \(what) waits its turn, \(waiting.count) in the queue"
            )
        }
        startNextIfIdle()
    }

    private func armDeadline() {
        holder.timer?.invalidate()
        let timer = Timer(timeInterval: Self.timeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fire()
            }
        }
        holder.timer = timer
        scheduledSeconds = Self.timeoutSeconds
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The command was acknowledged. Either ask the cube whether it took, or stop here if nothing can ask.
    private func acknowledgedCommand(_ landed: Bool) {
        guard landed else {
            debugLog?.record(.command, "The cube would not take the command")
            finishExchange(took: false, status: nil)
            return
        }
        guard let readBack = pendingReadBack else {
            // Said in these words on purpose. The commands with no read command in the spec (`0x09`, `0x0A`, `0x11`
            // and the rename, `0x15`) end here for good, and a row reading "confirmed" would be a claim nobody is
            // in a position to make -- see the read-back matrix in `docs/timeflip.md`. For `0x15` it is measured as
            // well as absent from the spec: the command result is never updated for it at all (finding 2,
            // `docs/timeflip2-firmware-observations.md`).
            debugLog?.record(.command, "The cube took the write; nothing can read this command back")
            finishExchange(took: true, status: nil)
            return
        }
        isReadingBack = true
        armDeadline()
        debugLog?.record(.command, "Asking whether it took: \(describe(readBack.request))")
        transmit(readBack.request)
    }

    /// The read-back question was acknowledged, so its answer is the next thing on the command result.
    ///
    /// **Read only now, and never earlier.** A `0x10` answer carries no echoed command byte to identify it, and
    /// that characteristic frequently holds the previous command's reply, so the only thing that makes the value
    /// trustworthy is that it is read after this question's own acknowledgement.
    private func askedForConfirmation(_ landed: Bool) {
        guard landed else {
            debugLog?.record(.command, "The cube would not take the question")
            finishExchange(took: false, status: nil)
            return
        }
        readResult()
    }

    /// What the cube said, whether it was asked to confirm a command or simply asked what state it is in.
    ///
    /// **Parsed in one place, whichever question brought it here**, so the state the app holds and the verdict on a
    /// command are read from the same bytes by the same rule rather than by two that could come to differ.
    private func answered(_ value: Data?) {
        let status = DeviceCommandRules.status(from: value)
        guard let readBack = pendingReadBack else {
            // **What the cube is does not get written down here**, though this is where the bytes are read. Saying
            // it is `BluetoothRadio.received(status:)`'s job and only its job: it holds the answer, and it records
            // it only when it is news. Both of them said it for a while, so one ask produced two identical rows and
            // a log read as though the cube had been asked twice.
            //
            // What is left is the case the radio never hears about. An answer that was not one reports no status at
            // all, so nothing downstream would mention it, and a question that went unanswered is worth a row.
            if status == nil {
                debugLog?.record(.command, "That was not an answer about the state of the cube")
            }
            finishExchange(took: status != nil, status: status)
            return
        }
        let took = readBack.took(value)
        // **The answer in words where the command can put it in words**, which today is `0x16` and `0x05`. A verdict
        // on its own is enough for the caller and not enough for whoever reads the row afterwards: a refusal that
        // names the registers the cube is actually on is the disagreement itself, where a bare NOT leaves them to go
        // hunting for it. Nothing is appended for a command with no interpretation, and nothing for bytes that were
        // not an answer.
        let said = readBack.described(value).map { ": \($0)" } ?? ""
        debugLog?.record(.command, (took ? "The cube confirms it took" : "The cube says it did NOT take") + said)
        finishExchange(took: took, status: status)
    }

    /// Ends whichever exchange was out, and tells whoever was waiting.
    ///
    /// **Both completions are cleared before either is called.** A caller told about one command is free to send the
    /// next from inside that call -- the lock sequence does exactly that -- and a slot still holding the finished
    /// exchange would refuse it as "already busy".
    private func finishExchange(took: Bool, status: DeviceCommandRules.Status?) {
        holder.timer?.invalidate()
        holder.timer = nil
        scheduledSeconds = nil
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
        startNextIfIdle()
    }
}

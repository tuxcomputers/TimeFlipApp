import Foundation

/// Stopping the cube and starting it again: the lock, and the plain pause underneath it.
///
/// **One place that knows the order**, because there are several ways in -- the dropdown's Lock item, the quit, and
/// both halves of the status item's right-hand gesture -- and the order is not arbitrary in any of them. Written
/// twice it would be two answers to one question, which is the fault the first rule in `CLAUDE.md` exists to prevent.
///
/// `lock` and `resume` are the pair the dropdown and the quit use; `togglePause` is the single click, which stops the
/// cube without locking it. What each of them reads to decide, and where it reads it from, is explained on each.
///
/// Every command goes out through `send`, so every one of them is read back before it is believed (see the read-back
/// rule in `CLAUDE.md`). What this adds on top is the sequencing and the setting.
@MainActor
final class CubeLock {
    /// Where `pause_on_lock` is read from, at the step that needs it.
    private let settings: SettingStore?

    /// Sends one command and reports whether the cube confirmed it took. `BluetoothRadio.send`, handed in rather than
    /// held, so this can be driven through both sequences in a test with no radio.
    private let send: (Data, @escaping (Bool) -> Void) -> Void

    /// Whether there is a live link to send anything down.
    private let isConnected: () -> Bool

    /// Whether the cube is counting or stopped, **read from `device_event` at the moment it is needed**.
    ///
    /// The app already knows this without asking: `HistoryIngestor` brings the cube's own record of the day into
    /// `device_event`, and a paused stretch arrives there as an interval the cube filed for `Side + 128`. So the open
    /// segment's `paused` is the cube's own account of what it is doing, and it is the same answer both surfaces draw
    /// their play/pause glyph from (`TimingReadout.Reading.deviceIsPaused`).
    ///
    /// `nil` for a cube with no open segment to read -- one that has been reset and not yet flipped, say.
    private let isPaused: () -> Bool?

    /// Whether the cube is locked.
    ///
    /// **A different source from `isPaused`, because the protocol gives no other.** A history frame carries an event
    /// number, a face, a start and a duration, and the face byte is where pause rides; there is no lock bit anywhere
    /// in it and no `locked` column in `device_event`. `0x10` is the only read the vendor defines, so this is
    /// `BluetoothRadio.cubeStatus` -- read when the link comes up and refreshed by the read-back of every command the
    /// app sends. It has no back door to go stale through: the cube offers no gesture that locks itself, unlike
    /// pause, which a double tap or auto-pause changes with nothing said.
    private let isLocked: () -> Bool?

    /// Whether starting the cube is refused right now, which is exactly "the category on show has spent its budget".
    ///
    /// **The enforcement, as opposed to the courtesy.** `PauseMenuRules` greys the item and routes the click to
    /// nothing, which is what stops it looking like a control that is simply broken; this is what makes the limit
    /// hard, because it catches every caller including ones that never asked the router. Both are needed and they are
    /// not the same thing.
    ///
    /// **Pausing is never refused**, only starting: a limit that trapped somebody into recording time would be the
    /// opposite of what it is for. So this is asked of a resume and nothing else.
    private func startingIsRefused() -> Bool {
        guard isLimitReached() else { return false }
        debugLog?.record(.command, "The cube is left stopped: the category on show has spent its daily limit")
        return true
    }

    /// Whether the category on show has spent its `daily_limit`, read at the moment it matters.
    ///
    /// **Set after construction**, because `DailyLimitWatch` is built from things that are built after this. A `var`
    /// rather than an `init` parameter for the same reason `QuitSequence.cubeLock` is one.
    var isLimitReached: () -> Bool = { false }

    private let debugLog: DebugLog?

    init(
        settings: SettingStore?,
        isConnected: @escaping () -> Bool,
        send: @escaping (Data, @escaping (Bool) -> Void) -> Void,
        isPaused: @escaping () -> Bool? = { nil },
        isLocked: @escaping () -> Bool? = { nil },
        debugLog: DebugLog?
    ) {
        self.settings = settings
        self.isConnected = isConnected
        self.send = send
        self.isPaused = isPaused
        self.isLocked = isLocked
        self.debugLog = debugLog
    }

    /// Stops the cube counting, or starts it again -- whichever it is not doing now.
    ///
    /// **Which way to flip comes out of `device_event`, not out of a fresh question to the cube.** The app already
    /// holds the cube's own account of what it is doing: `HistoryIngestor` brings the history in on every tick and on
    /// every flip, and a paused stretch arrives as the interval the cube filed for `Side + 128`. Asking `0x10` first
    /// would be a second answer to a question already answered, which is the fault the first rule in `CLAUDE.md`
    /// exists to prevent -- and it would be the *worse* of the two answers to act on, because it is not the one the
    /// menu bar and the Faces tab drew their glyph from. A gesture whose direction can disagree with the symbol
    /// sitting next to it is a gesture nobody can aim.
    ///
    /// **The read-back is untouched by this.** `send` still confirms the result against `0x10` before it is believed,
    /// per the read-back rule; what is taken from the table is only which command to send.
    ///
    /// **A locked cube is left alone**, which is the archive's rule and rests on a measurement rather than on taste:
    /// a locked cube reports itself paused whatever its pause byte says, so nothing sent here could be read back
    /// afterwards and there would be no way to tell what was actually done. The way out is the lock, not this.
    ///
    /// **A cube with no open segment is paused rather than refused.** That is a cube which has recorded nothing yet --
    /// reset and not yet flipped -- so there is no record to read a direction out of, and of the two ways to be wrong,
    /// stopping a cube nobody is timing on costs nothing and is undone by clicking again. The read-back is what turns
    /// the guess into an answer, and the history fetch that follows puts it in the table.
    ///
    /// Returns whether anything was sent. `false` means `finished` will not be called.
    @discardableResult
    func togglePause(then finished: @escaping (Bool) -> Void) -> Bool {
        setPause(!(isPaused() ?? false), then: finished)
    }

    /// Stops the cube or starts it **in a named direction**, rather than by flipping whatever it is doing.
    ///
    /// **What the toggle is built from, and what the app uses when it is not a gesture.** A click means "the other
    /// one", so it has to read the cube's state first; a pause the app forces already knows which way it wants, and
    /// reading the state to work out a direction it was told would be a chance to get it wrong. The guards, the
    /// command and the read-back are the same either way, which is why they live here once.
    ///
    /// Returns whether anything was sent. `false` means `finished` will not be called.
    @discardableResult
    func setPause(_ wanted: Bool, then finished: @escaping (Bool) -> Void) -> Bool {
        guard isConnected() else {
            debugLog?.record(.command, "No cube connected, so there is nothing to pause or resume")
            return false
        }
        guard isLocked() != true else {
            debugLog?.record(.command, "The cube is locked, so pausing it means nothing; unlock it first")
            return false
        }
        // **Every path that could start the cube comes through here**, which is what makes this the enforcement rather
        // than one more place that happens to check. Reported live on 2026-08-27: a single click on the status item's
        // right half sent `06 02` against a spent budget, because the router only ever asked the limit about the app's
        // own clock and a cube leaves that idle.
        guard !(wanted == false && startingIsRefused()) else { return false }
        send(DeviceCommandRules.pause(wanted)) { [weak self] took in
            self?.debugLog?.record(
                .command,
                took
                    ? (wanted ? "The cube is paused" : "The cube is running")
                    : (wanted ? "The cube would not pause" : "The cube would not resume")
            )
            finished(took)
        }
        return true
    }

    /// Stops the cube: pauses it, then locks it.
    ///
    /// **Pause first, and that order is the protocol's rather than a preference.** Lock "freezes TimeFlip to count
    /// time on the last active facet" (`docs/TimeFlip2 BLE Protocol v4.3.md`, Tab. 1's footnote), so a cube that is
    /// locked and not paused goes on recording against whatever face was up, for as long as it sits there with
    /// nobody watching. There is a second reason to send it in this order and it is the one that cannot be worked
    /// around: **a locked cube reports itself paused whatever its pause byte says**, so a pause sent after a lock
    /// could never be confirmed -- the read-back would answer "paused" either way.
    ///
    /// **`pause_on_lock` gates the pause and nothing else**, read here rather than anywhere earlier. On, this pauses
    /// and then locks; off, it locks. The lock is the point of the gesture and happens either way, from both of the
    /// places that ask for it -- a double click on the right half of the status item, and quit.
    ///
    /// It used to gate the whole sequence, so turning the setting off turned the lock off with it and the app
    /// answered a double click by doing nothing at all, saying only `pause_on_lock is off, so the cube is left as it
    /// is`. The name is about pausing *on* lock: it says whether locking also stops the clock, not whether locking
    /// happens.
    ///
    /// Returns whether anything was sent. `false` means `finished` will not be called and there is nothing to wait
    /// for, which is what lets the quit answer `.terminateNow` from the same fact rather than a second opinion.
    @discardableResult
    func lock(then finished: @escaping (Bool) -> Void) -> Bool {
        guard isConnected() else {
            debugLog?.record(.command, "No cube connected, so there is nothing to pause or lock")
            return false
        }
        // **An unreadable row counts as off**, which is not the seeded default and is deliberate. It now costs the
        // pause rather than the whole gesture: a launch that cannot read its own settings still locks, because that
        // is what was asked for, and simply does not take the extra liberty of stopping the clock as well.
        // `LaunchMode.decided` chooses its fallback the same way.
        guard settings?.flag("pause_on_lock", field: "enabled") == true else {
            debugLog?.record(.command, "pause_on_lock is off, so the cube is locked without pausing it")
            send(DeviceCommandRules.lock(true)) { [weak self] locked in
                self?.debugLog?.record(.command, locked ? "The cube is locked" : "The cube would not lock")
                finished(locked)
            }
            return true
        }
        // **Sent whatever the cube is already doing, and that is not free.** `0x06 0x01` is not idempotent: measured
        // on hardware 2026-08-12, the cube mints a `device_event` per write (see the archive's
        // `MenuBarController.limitWriteSentAtEventNumber`). The app now *does* have an answer about the cube's pause
        // state -- `BluetoothRadio.cubeStatus` -- but it is only as fresh as the last question, and a double tap or
        // auto-pause changes it with nothing said, so skipping the write on the strength of it would be acting on a
        // claim about hardware nobody has checked this second. One spurious event is the cheaper wrong answer.
        send(DeviceCommandRules.pause(true)) { [weak self] paused in
            self?.debugLog?.record(.command, paused ? "The cube is paused" : "The cube would not pause")
            // **The lock goes out either way.** A pause that did not take is a reason to want the lock more, not
            // less: locking still stops the cube changing face behind everybody's back, and giving up here would let
            // one failure cost both steps.
            self?.send(DeviceCommandRules.lock(true)) { locked in
                self?.debugLog?.record(.command, locked ? "The cube is locked" : "The cube would not lock")
                finished(locked)
            }
        }
        return true
    }

    /// Starts it again: unlocks, then resumes.
    ///
    /// **Unlock first, which is the mirror of the reason lock goes last.** A locked cube reports itself paused
    /// whatever its pause byte says, so a resume sent while it is still locked could not be confirmed: the read-back
    /// would answer "paused" and the app would report a failure that may or may not have happened.
    ///
    /// **Not gated on `pause_on_lock`.** That setting says what *locking* does, and refusing to undo a lock because
    /// the setting that made it has since been turned off would strand somebody's cube in the one state this app can
    /// otherwise not get it out of.
    @discardableResult
    func resume(then finished: @escaping (Bool) -> Void) -> Bool {
        guard isConnected() else {
            debugLog?.record(.command, "No cube connected, so there is nothing to unlock")
            return false
        }
        send(DeviceCommandRules.lock(false)) { [weak self] unlocked in
            guard let self else { return }
            self.debugLog?.record(.command, unlocked ? "The cube is unlocked" : "The cube would not unlock")
            // **The unlock happens whatever the limit says, and the resume does not.**
            //
            // A spent `daily_limit` is meant to be hard, and it is only as hard as the set of paths that can send
            // `0x06 0x02`. This was one of them and nothing gated it: a double click on the status item's right half
            // unlocks, which resumes, so the way round a limit was to lock the cube and unlock it again. Measured on
            // 2026-08-27 -- `The cube is unlocked`, `Sending 06 02`, `The cube is running`, and `DailyLimitWatch`
            // stopping it again two seconds later, the app plainly arguing with itself.
            //
            // **Unlocking is never refused**, which is the other half. Refusing it would strand the cube in the one
            // state this app cannot otherwise get it out of, and the limit is about recording time rather than about
            // holding somebody's hardware shut. So a spent budget leaves it unlocked and stopped, which is exactly
            // what the limit means, and every other way to start it again is already refused.
            guard !self.startingIsRefused() else {
                finished(unlocked)
                return
            }
            // **The resume goes out either way otherwise, for the mirror of the reason the lock does.** A cube left
            // paused and unlocked is a cube that quietly records nothing while somebody flips it, which is worse than
            // a lock they can see. If the unlock failed the resume cannot be confirmed either, and that is what it
            // reports.
            self.send(DeviceCommandRules.pause(false)) { running in
                self.debugLog?.record(.command, running ? "The cube is running" : "The cube would not resume")
                finished(unlocked && running)
            }
        }
        return true
    }
}

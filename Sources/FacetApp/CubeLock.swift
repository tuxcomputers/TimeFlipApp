import Foundation

/// Locking the cube, and the way back.
///
/// **One place that knows the order**, because there are now two ways in -- the dropdown's Lock item and the quit --
/// and the order is not arbitrary in either. Written twice it would be two answers to one question, which is the
/// fault the first rule in `CLAUDE.md` exists to prevent.
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

    private let debugLog: DebugLog?

    init(
        settings: SettingStore?,
        isConnected: @escaping () -> Bool,
        send: @escaping (Data, @escaping (Bool) -> Void) -> Void,
        debugLog: DebugLog?
    ) {
        self.settings = settings
        self.isConnected = isConnected
        self.send = send
        self.debugLog = debugLog
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
    /// **Gated on `pause_on_lock`**, read here rather than anywhere earlier. The whole sequence is gated and not just
    /// the pause: it is the setting that says what locking from the app means, and with it off the app does not lock
    /// from either of the two places it can.
    ///
    /// Returns whether anything was sent. `false` means `finished` will not be called and there is nothing to wait
    /// for, which is what lets the quit answer `.terminateNow` from the same fact rather than a second opinion.
    @discardableResult
    func lock(then finished: @escaping (Bool) -> Void) -> Bool {
        guard isConnected() else {
            debugLog?.record(.command, "No cube connected, so there is nothing to pause or lock")
            return false
        }
        // **An unreadable row counts as off**, which is not the seeded default and is deliberate. Of the two ways to
        // be wrong, leaving the cube running is visible in its own history and undone by flipping it; locking one is
        // recoverable only from the dropdown or the vendor's app, and a launch that cannot read its own settings is
        // not one to be handing a lock. `ManualMode.startIfNoDeviceIsPaired` chooses its fallback the same way.
        guard settings?.flag("pause_on_lock", field: "enabled") == true else {
            debugLog?.record(.command, "pause_on_lock is off, so the cube is left as it is")
            return false
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
            self?.debugLog?.record(.command, unlocked ? "The cube is unlocked" : "The cube would not unlock")
            // **The resume goes out either way, for the mirror of the reason the lock does.** A cube left paused and
            // unlocked is a cube that quietly records nothing while somebody flips it, which is worse than a lock
            // they can see. If the unlock failed the resume cannot be confirmed either, and that is what it reports.
            self?.send(DeviceCommandRules.pause(false)) { running in
                self?.debugLog?.record(.command, running ? "The cube is running" : "The cube would not resume")
                finished(unlocked && running)
            }
        }
        return true
    }
}

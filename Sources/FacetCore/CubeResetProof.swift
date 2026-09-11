import Foundation

/// Proving a factory reset actually happened, which the cube will not simply tell you.
///
/// **`0xFF` is the one command with no read-back possible by nature.** The cube reboots, and a rebooted cube
/// does not write a fresh command result, so the only proof available is functional: the wipe returns it to the
/// vendor PIN, so logging in on that PIN and nothing else is what says the wipe took. `docs/timeflip.md` has
/// the matrix and puts `0xFF` in the same row as `0x30`.
///
/// **Only the vendor default is ever presented, and that is the whole design.** Offering the app's stored PIN
/// as well would let a cube that ignored the command log in and be counted as proof, which is precisely the
/// mistake this sequence exists to avoid.
///
/// **The link is dropped here rather than waited for, and that is a measured correction.** The archive assumed
/// a reset severs the connection and waited for the disconnect to start proving. On this firmware it does not:
/// a reset on 2026-08-17 was acknowledged and the link stayed up for the whole 104 seconds somebody watched it,
/// so nothing was ever tried and a wipe that had really happened went unconfirmed (finding 6,
/// `docs/timeflip2-firmware-observations.md`). Letting go covers both firmwares: a cube that does sever the
/// link is handled anyway, and one that does not is let go of regardless.
///
/// **In the core since 2026-09-11, and it had never had a test.** It lived in `BluetoothRadio` wound through
/// the connect machinery, so exercising it needed a real cube and a real reset. Nothing above is CoreBluetooth:
/// the three things it needs from a platform are handed in as closures, which is `DeviceSettingsSync`'s and
/// `FaceColourSync`'s arrangement and for the same reason.
@MainActor
package final class CubeResetProof {
    /// How long to keep trying the vendor PIN before giving up on the proof.
    package static let windowSeconds: TimeInterval = 120

    /// How long to wait between attempts. The cube is rebooting, so the first few will not answer.
    package static let retrySeconds: TimeInterval = 3

    private let scheduler: Scheduler
    private let sendReset: (@escaping (Bool) -> Void) -> Void
    private let letGo: (String) -> Void
    private let tryVendorPIN: () -> Void
    private let debugLog: DebugLog?

    private var reported: ((FactoryResetOutcome) -> Void)?
    private var deadline: ScheduledWake?
    private var nextAttempt: ScheduledWake?

    /// Whether a proof is in flight. Callers gate on this: a reach or a connect started underneath one would
    /// take the link the proof is using.
    package var isRunning: Bool { reported != nil }

    /// - Parameter sendReset: writes `0xFF` and answers whether the cube took the write.
    /// - Parameter letGo: drops the link, given the reason to log. Called twice in a full run: once because the
    ///   cube is being reset, and once because the proof is over, whichever way it went.
    /// - Parameter tryVendorPIN: begins one login attempt presenting `DeviceLoginRules.defaultPIN` and nothing
    ///   else. Its outcome comes back through `loginEnded`.
    package init(
        scheduler: Scheduler,
        sendReset: @escaping (@escaping (Bool) -> Void) -> Void,
        letGo: @escaping (String) -> Void,
        tryVendorPIN: @escaping () -> Void,
        debugLog: DebugLog?
    ) {
        self.scheduler = scheduler
        self.sendReset = sendReset
        self.letGo = letGo
        self.tryVendorPIN = tryVendorPIN
        self.debugLog = debugLog
    }

    /// Sends the reset and begins proving it. `reported` is called exactly once, whatever happens.
    package func begin(then reported: @escaping (FactoryResetOutcome) -> Void) {
        // **Armed before the command goes, not after it.** The drop that follows is part of the reset, and a
        // window opened afterwards would not cover an answer that arrived while it was being opened.
        self.reported = reported
        deadline?.cancel()
        deadline = scheduler.wake(in: Self.windowSeconds) { [weak self] in
            guard let self else { return }
            debugLog?.record(
                .pair,
                "The cube never came back on the vendor PIN within \(Int(Self.windowSeconds))s,"
                    + " so the reset is not confirmed"
            )
            finish(.notConfirmed)
        }

        sendReset { [weak self] sent in
            guard let self else { return }
            guard sent else {
                debugLog?.record(.pair, "The cube would not take the reset command")
                finish(.notSent)
                return
            }
            debugLog?.record(.pair, "Reset sent; letting go of the link so the cube can be met again")
            letGo("the cube is being reset")
            waitThenTryAgain()
        }
    }

    /// What one attempt at the vendor PIN came to. **Anything but a login is "not back yet"**, not a failure:
    /// the cube may still be rebooting, and the window is what decides when to give up.
    package func loginEnded(_ outcome: DeviceLoginOutcome) {
        guard isRunning else { return }
        guard outcome == .loggedIn else {
            debugLog?.record(.pair, "Not back yet (\(outcome)); trying again")
            waitThenTryAgain()
            return
        }
        debugLog?.record(.pair, "The cube let the app in on the vendor PIN, so the wipe took")
        finish(.confirmed)
    }

    /// The link went while a proof was running, which is the cube rebooting rather than a device going away.
    ///
    /// **Answered by trying again rather than by giving up.** A cube that severs the link on `0xFF` and one that
    /// holds it open are both expected (finding 6), so this is the same wait as any other attempt that did not
    /// end in a login. The caller logs what it saw; this decides what to do about it.
    package func linkDropped() {
        guard isRunning else { return }
        waitThenTryAgain()
    }

    /// Gives up on a proof still in flight without reporting: the window closed on this app's terms rather than
    /// the cube's, which is a quit or the device being forgotten.
    package func abandon() {
        deadline?.cancel()
        deadline = nil
        nextAttempt?.cancel()
        nextAttempt = nil
        reported = nil
    }

    private func waitThenTryAgain() {
        guard isRunning else { return }
        nextAttempt?.cancel()
        nextAttempt = scheduler.wake(in: Self.retrySeconds) { [weak self] in
            guard let self, isRunning else { return }
            debugLog?.record(.pair, "Trying the vendor PIN, to see whether the cube was really wiped")
            tryVendorPIN()
        }
    }

    /// Ends the proof one way or the other, and says so exactly once.
    private func finish(_ outcome: FactoryResetOutcome) {
        guard let reported else { return }
        self.reported = nil
        deadline?.cancel()
        deadline = nil
        nextAttempt?.cancel()
        nextAttempt = nil
        debugLog?.record(.pair, "Reset: \(outcome)")
        // **Let go either way.** A confirmed reset leaves a pristine cube the app has been told to give up, and
        // an unconfirmed one leaves a device the app must not go on holding as though nothing had been asked.
        letGo("the reset is over")
        reported(outcome)
    }
}

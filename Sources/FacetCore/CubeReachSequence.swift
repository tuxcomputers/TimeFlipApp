import Foundation

/// Going to find a cube this app already knows, and asking every device that could be it.
///
/// **Reaching is a scan, not a lookup, and that is the whole shape.** No identifier this app can see is unique
/// to a cube (finding 8, `docs/timeflip2-firmware-observations.md`), so the stored handle orders the devices a
/// scan found rather than choosing one, and what actually identifies this app's cube is the PIN it set on it.
/// A reach therefore ends by running out of devices to ask.
///
/// **Collect, then try, taken whole from the archive.** The rebuild once tried each device as it was
/// discovered, which reads as the faster answer and puts three things inside one another: a connect stops the
/// scan, stopping the scan ends the reach, and ending the reach runs a dialog from inside the half-finished
/// connect. Measured 2026-08-23: the offer came up two seconds into a launch saying nothing answered, and the
/// Retry made from inside that dialog was overwritten by the tail of the connect it had interrupted, leaving
/// the app scanning for ten seconds and then silent for the rest of the launch.
///
/// **Arriving first is not a reason to be tried first.** Devices advertise in whatever order they happen to, so
/// acting on the first one is how a colleague's cube gets asked and this app's own is never reached at all.
/// `DeviceScanRules.reachOrder` is what decides, and it is shared with the list a person reads.
///
/// **In the core since 2026-09-13**, the last of candidate 1's five clusters. Nothing here is CoreBluetooth:
/// the three things it needs from a platform arrive as closures, which is `CubeResetProof`'s arrangement and
/// for the same reason. What the adapter keeps is the scan itself and the connect.
@MainActor
package final class CubeReachSequence {
    /// The wait before each candidate, which is measured rather than cautious.
    ///
    /// Connecting to a peripheral while the previous attempt's teardown is still running fails in milliseconds
    /// and says nothing about the cube: the archive measured it and this app measured it again at eight
    /// milliseconds (finding 8). Without the pause a queue of five cubes would refuse all five in under a tenth
    /// of a second and none of it would mean anything.
    package static let settleSeconds: TimeInterval = 1

    private let scheduler: Scheduler
    private let tryThis: (DeviceHandle, [String], String?) -> Void
    private let scanAgain: () -> Void
    private let finished: (DeviceHandle?, DeviceLoginOutcome) -> Void
    private let debugLog: DebugLog?

    /// One run at finding a cube: which one is worth trying first, which PINs are left, and what to leave it on.
    private struct Target {
        /// `device_uuid`, a **hint and never a gate**: worth trying first when it turns up, worth nothing when
        /// it does not.
        let preferred: DeviceHandle?
        let candidates: [String]
        let rotatingTo: String?
        /// Eligible devices seen this scan and not yet tried, in the order they will be tried.
        var queue: [DeviceHandle] = []
        /// Tried this reach, so a device advertising repeatedly is not tried twice in one pass. **Not remembered
        /// beyond it**: the next scan starts over, so a cube that refused for a passing reason is picked up again
        /// rather than needing a restart.
        var tried: Set<DeviceHandle> = []
        /// Whether anything refused, which is what tells "nothing was in range" from "none of them was ours".
        var anyRefused = false
        /// Whether the remembered handle turning up may still cut the scan window short. False once it has, so
        /// the second look runs its full window: two scans is the most a reach ever does.
        var mayEndEarly = true
        /// Whether the window that just ended was cut short by that. If the shortcut turns out to have been
        /// wrong, this is what says there is a proper look still owed before the answer is "nothing is here".
        var windowWasCutShort = false
    }

    private var target: Target?
    private var settleThenConnect: ScheduledWake?

    package var isRunning: Bool { target != nil }

    /// The handle this reach was asked for, for a caller that has to name something when it ends.
    package var preferred: DeviceHandle? { target?.preferred }

    /// - Parameter tryThis: begins one login attempt on this device with these PINs. Its outcome comes back
    ///   through `candidateEnded`.
    /// - Parameter scanAgain: opens a second scan window, for the one case that earns one: the shortcut below
    ///   having turned out to be wrong.
    /// - Parameter finished: the reach is over and nobody is left to ask. Called exactly once per reach.
    package init(
        scheduler: Scheduler,
        tryThis: @escaping (DeviceHandle, [String], String?) -> Void,
        scanAgain: @escaping () -> Void,
        finished: @escaping (DeviceHandle?, DeviceLoginOutcome) -> Void,
        debugLog: DebugLog?
    ) {
        self.scheduler = scheduler
        self.tryThis = tryThis
        self.scanAgain = scanAgain
        self.finished = finished
        self.debugLog = debugLog
    }

    package func begin(preferring preferred: DeviceHandle?, candidates: [String], rotatingTo: String?) {
        target = Target(preferred: preferred, candidates: candidates, rotatingTo: rotatingTo)
    }

    /// A scan window has closed. Puts what it found into the order they will be asked in, and starts asking.
    ///
    /// **Devices already tried this reach are dropped**, so a second window after the shortcut was paid for does
    /// not ask the same cube again.
    package func scanEnded(
        found: [ScannedDevice],
        remembered: String?,
        previouslyKnown: String?,
        isBusy: @escaping () -> Bool = { false }
    ) {
        guard target != nil else { return }
        let order = DeviceScanRules.reachOrder(
            found, preferring: target!.preferred, remembered: remembered, previouslyKnown: previouslyKnown
        )
        target!.queue = order.filter { !target!.tried.contains($0) }
        debugLog?.record(.login, "\(target!.queue.count) device(s) to ask, in the order they will be asked")
        tryNext(isBusy: isBusy)
    }

    /// Whether a device just advertised is worth cutting the scan window short for.
    ///
    /// **Only the remembered handle is**, because nothing a later advertisement could add would go ahead of it,
    /// and holding the window open past that point costs the rest of the window for nothing. Measured
    /// 2026-08-09: a cube was in the scan results at 23:54:43.5 and not acted on until 23:55:14.2, thirty-one
    /// seconds spent waiting for a window that had already found its answer.
    ///
    /// **It is a shortcut and it is treated as one.** That handle is not unique to a cube, so the device it
    /// names can turn out not to be this app's at all, and the room is then owed a proper look before the answer
    /// may be "nothing is here". Answers `true` once per reach at most.
    package func shouldCutTheWindowShort(for device: ScannedDevice) -> Bool {
        guard target != nil, target!.mayEndEarly, device.id == target!.preferred else { return false }
        target!.mayEndEarly = false
        target!.windowWasCutShort = true
        return true
    }

    /// One candidate's login has ended, however it ended.
    ///
    /// **A reach is not over because one candidate refused.** The PIN is what identifies this app's cube, so a
    /// refusal answers "is this one mine?" with no, and the next device with the name gets asked.
    /// - Parameter isBusy: whether something else has taken the link, asked at the moment the settle wait ends
    ///   rather than now. That is a fact about the radio and the one thing this hands back down.
    package func candidateEnded(_ outcome: DeviceLoginOutcome, isBusy: @escaping () -> Bool = { false }) {
        guard target != nil else { return }
        if outcome == .loggedIn {
            target = nil
            settleThenConnect?.cancel()
            settleThenConnect = nil
            return
        }
        if outcome == .wrongPIN { target!.anyRefused = true }
        tryNext(isBusy: isBusy)
    }

    /// Ends a reach that cannot go on, naming why. **Says which of the two answers it is**: "none of them was
    /// ours" is not "nothing was there", and they are different problems, one a cube out of range and the other
    /// cubes in range this app cannot open.
    package func giveUp(because reason: String) {
        guard let ending = target else { return }
        target = nil
        settleThenConnect?.cancel()
        settleThenConnect = nil
        let outcome: DeviceLoginOutcome = ending.anyRefused ? .wrongPIN : .unreachable
        debugLog?.record(
            .login,
            ending.anyRefused
                ? "\(reason): \(ending.tried.count) device(s) with the name, none took the PIN"
                : "\(reason): nothing with the name answered"
        )
        finished(ending.preferred, outcome)
    }

    /// Drops a reach without reporting: the window closing, or another device being chosen. Not an outcome,
    /// because nobody is waiting for one.
    package func abandon() {
        target = nil
        settleThenConnect?.cancel()
        settleThenConnect = nil
    }

    /// Starts the next queued candidate after the settle wait, or decides the reach is over.
    ///
    /// **Private, so a caller cannot advance the queue twice.** `scanEnded` and `candidateEnded` each end in one
    /// of these, and a caller that also called it would skip a device without anything failing.
    private func tryNext(isBusy: @escaping () -> Bool) {
        guard target != nil, !isBusy() else { return }
        guard !target!.queue.isEmpty else {
            // **The shortcut was wrong, so the shortcut is paid for.** The window was cut short because the
            // remembered handle turned up, and that device has now refused this app's PIN, so it was not this
            // app's cube and the rest of the room has never been looked at. Saying nothing is here would be
            // saying it about a scan that stopped after one answer.
            if target!.windowWasCutShort {
                target!.windowWasCutShort = false
                debugLog?.record(.login, "The remembered device did not take the PIN, so looking at what else is there")
                scanAgain()
                return
            }
            giveUp(because: "every device with the name has been tried")
            return
        }
        let id = target!.queue.removeFirst()
        target!.tried.insert(id)
        let candidates = target!.candidates
        let rotatingTo = target!.rotatingTo
        settleThenConnect = scheduler.wake(in: Self.settleSeconds) { [weak self] in
            guard let self, target != nil, !isBusy() else { return }
            debugLog?.record(.login, "Trying \(id.value), \(target!.queue.count) more with the name behind it")
            tryThis(id, candidates, rotatingTo)
        }
    }
}

import AppKit

/// What the app does on its way out.
///
/// One step so far: the segment still running is closed, at the moment the app ends. Without it the row stays
/// open, and the next launch's first click closes it having measured every second since -- including the hours
/// the app was not running. That is not a stale duration in a row, it is a wrong entry in somebody's tracked
/// time, because closing a segment is what creates the entry.
///
/// **`applicationWillTerminate` rather than the Quit menu item**, so it covers every graceful end rather than
/// the one the app itself offers: an Apple Events quit, a logout, a restart. The menu item goes through
/// `NSApp.terminate` and so through here as well.
///
/// **Two steps now**: the open segment is closed, and the cube is let go of.
///
/// The second arrived with the connection outliving the Settings window. A link that ends when a window closes needs
/// nothing here; one that belongs to the app has to be given back by the app, and the `connection` row has to say so
/// -- otherwise the last thing written before the process ends is `connected`, and the next launch reads a cube that
/// nothing is holding.
///
/// **Three steps now**, and the first of them happens before the other two: the cube is paused and then locked while
/// the link is still up, and only then is the segment closed and the link given back.
///
/// That split is why this is two delegate methods rather than one. Pausing and locking are BLE writes, and a write
/// needs a round trip the process will not be alive for if it is started from `applicationWillTerminate` -- so they run
/// in `applicationShouldTerminate`, which is allowed to say "not yet" and answer later. The archive reached the same
/// arrangement for the same reason.
///
/// Each step reads what it needs at the step that needs it, not at launch.
@MainActor
final class QuitSequence: NSObject, NSApplicationDelegate {
    /// How long the cube gets to be paused and locked before the app quits anyway.
    ///
    /// **Shorter than the two writes' own deadlines put together, deliberately.** `DeviceLogin.send` gives each write
    /// ten seconds, so a cube that has gone quiet mid-quit would otherwise hold the app open for twenty while somebody
    /// watches a menu bar that will not go away. Five seconds is comfortably more than the pair costs on a live link
    /// (each is one acknowledged write) and short enough that a failed quit still feels like a quit.
    static let deviceSeconds: TimeInterval = 5

    private let deviceEvents: DeviceEventRecorder
    private let debugLog: DebugLog?

    /// Drops any live connection and records the quit, answering whether there was one to drop.
    ///
    /// **A closure rather than the radio itself**, because the radio is made on the first scan and lives behind the
    /// Settings window controller: this runs at a moment when there may never have been one. It is set after that
    /// controller exists (see `main.swift`), which is also why it is a variable rather than an initialiser argument.
    var letGoOfTheDevice: (() -> Bool)?

    /// Stopping the cube on the way out. Set after the radio exists, for the same reason `letGoOfTheDevice` is a
    /// closure: this object is built before it and outlives every window. `nil` in a build that never had a radio,
    /// which quits without touching anything.
    var cubeLock: CubeLock?

    /// Stops the app being held open for ever by a cube that went quiet part way through.
    private var deviceDeadline: Timer?

    /// What to call once the cube has nothing left to say, held while the two writes are out. `nil` once it has been
    /// called, which is what makes the deadline and the last acknowledgement safe to race.
    private var quitFinished: (() -> Void)?

    init(deviceEvents: DeviceEventRecorder, debugLog: DebugLog?) {
        self.deviceEvents = deviceEvents
        self.debugLog = debugLog
        super.init()
    }

    /// Pauses and locks the cube, then lets the quit proceed.
    ///
    /// **Pause first, then lock, and that order is the protocol's rather than a preference.** Lock "freezes TimeFlip
    /// to count time on the last active facet" (`docs/TimeFlip2 BLE Protocol v4.3.md`, Tab. 1's footnote): a cube that
    /// is locked and not paused goes on recording against whatever face was up, for as long as it sits there with
    /// nobody watching. Pausing first is what stops a closed laptop turning into eight hours of "Meeting".
    ///
    /// **Gated on `pause_on_lock`**, which `CubeLock` reads at the step that needs it.
    ///
    /// **`applicationShouldTerminate` rather than `applicationWillTerminate`**, because these are BLE writes: the
    /// process does not outlive `willTerminate` long enough for a round trip, so a pause started there would be a
    /// command that never left. This method may answer late, which is exactly what that needs.
    ///
    /// **The answer is derived from what the step actually did**, rather than decided here and then acted on
    /// separately. Two expressions of "is there anything to send" is the sort of pair that comes to disagree, and the
    /// disagreement here is the worst kind available: `.terminateLater` with nothing running behind it is an app that
    /// never quits, and a reply sent before this method returns is one that quits twice.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let started = pauseAndLockTheCube { NSApp.reply(toApplicationShouldTerminate: true) }
        return started ? .terminateLater : .terminateNow
    }

    /// Pauses the cube, locks it, and reports when there is nothing left to wait for.
    ///
    /// Returns whether anything was sent. `false` means `finished` will **not** be called and there is nothing to
    /// wait for -- which is what lets the delegate above answer `.terminateNow` from the same fact rather than from a
    /// second opinion about it. `true` means `finished` is called exactly once: by the sequence finishing, or by the
    /// deadline, whichever gets there first.
    ///
    /// Separate from the delegate method so it can be driven without terminating anything, which is the same split
    /// `run(at:)` has and for the same reason.
    ///
    /// **The order, the setting and the read-backs are `CubeLock`'s**, not this method's. The dropdown's Lock item
    /// does the same thing for a different reason, and two expressions of "what locking the cube means" would be free
    /// to disagree about the one part of it that is not obvious -- that a locked cube reports itself paused, so the
    /// pause has to be confirmed before the lock is sent. What is this method's is the deadline: quitting is the only
    /// caller that cannot afford to wait.
    @discardableResult
    func pauseAndLockTheCube(then finished: @escaping () -> Void) -> Bool {
        guard let cubeLock else {
            debugLog?.record(.quit, "Quit: nothing to send to, so the cube is left as it is")
            return false
        }
        // Held rather than captured, so the deadline and the sequence race for it instead of both firing: whichever
        // gets here first takes it and leaves `nil` behind. The same shape as `DeviceLogin.finishExchange`.
        quitFinished = finished
        deviceDeadline?.invalidate()
        deviceDeadline = Timer(timeInterval: Self.deviceSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.debugLog?.record(
                    .quit,
                    "Quit: the cube did not finish answering within \(Int(Self.deviceSeconds))s, so quitting anyway"
                )
                self?.letTheQuitProceed()
            }
        }
        if let deviceDeadline { RunLoop.main.add(deviceDeadline, forMode: .common) }

        let started = cubeLock.lock { [weak self] stopped in
            self?.debugLog?.record(
                .quit,
                stopped ? "Quit: the cube is paused and locked" : "Quit: the cube was not left locked"
            )
            self?.letTheQuitProceed()
        }
        guard started else {
            // Nothing went out, so nothing is coming back. The deadline is taken down and the completion dropped
            // rather than called: the delegate above has not asked to delay the quit yet, and replying to a
            // termination nobody deferred is a reply for the next quit to trip over.
            deviceDeadline?.invalidate()
            deviceDeadline = nil
            quitFinished = nil
            return false
        }
        return true
    }

    /// Says there is nothing left to wait for, once and only once.
    private func letTheQuitProceed() {
        deviceDeadline?.invalidate()
        deviceDeadline = nil
        let finished = quitFinished
        quitFinished = nil
        finished?()
    }

    func applicationWillTerminate(_ notification: Notification) {
        run(at: Date())
    }

    /// The sequence itself, with the moment passed in so it can be asserted without terminating anything.
    ///
    /// Reported either way. A quit that found nothing open and a quit whose steps never ran leave the same
    /// table behind, and telling those apart later is the difference between "there was nothing to do" and
    /// "this never fired".
    func run(at moment: Date) {
        // **The app's own segments, and only those.** A cube's open row is refused by the recorder and left as it
        // is, because the cube keeps timing after this process has gone and its own history is what will say how
        // long that stretch ran -- see `DeviceEventRecorder.closeOpenSegment`. So the second line covers both
        // "nothing was running" and "what is running is the cube's", which are the same thing from here: neither is
        // this app's to close.
        if let closed = deviceEvents.closeOpenSegment(at: moment) {
            debugLog?.record(.quit, "Quit: closed the open segment, device_event \(closed.deviceEventID)")
        } else {
            debugLog?.record(.quit, "Quit: there was no segment of this app to close")
        }
        // **After the segment, not before.** Closing it is what turns the session into an entry, and it is done from
        // the app's own rows rather than from anything the cube says -- so a link dropped first cannot cost anything,
        // and a link dropped second cannot delay it either.
        guard let letGoOfTheDevice else { return }
        // **Called on its own line, and not inside the logging call.** `debugLog?.record(...)` is optional chaining,
        // so with no logger the argument is never evaluated and the step would silently not happen -- in a build
        // with the developer flag off, which is every build that matters. Caught by a test with `debugLog: nil`.
        let dropped = letGoOfTheDevice()
        debugLog?.record(.quit, dropped ? "Quit: dropped the connection to the device" : "Quit: no device was connected")
    }
}

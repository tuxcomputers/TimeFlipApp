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
    /// Where `pause_on_lock` is read from, at the step that needs it. The store rather than the value, deliberately:
    /// a launch that read this at startup would act on an answer somebody may have changed since.
    private let settings: SettingStore?
    private let debugLog: DebugLog?

    /// Drops any live connection and records the quit, answering whether there was one to drop.
    ///
    /// **A closure rather than the radio itself**, because the radio is made on the first scan and lives behind the
    /// Settings window controller: this runs at a moment when there may never have been one. It is set after that
    /// controller exists (see `main.swift`), which is also why it is a variable rather than an initialiser argument.
    var letGoOfTheDevice: (() -> Bool)?

    /// Whether there is a live link to send anything down. Set from the radio, for the same reason `letGoOfTheDevice`
    /// is a closure: this object is built before the radio and outlives every window.
    var isDeviceConnected: (() -> Bool)?

    /// Sends one command to the cube and reports whether it took the write.
    var sendToTheDevice: ((Data, @escaping (Bool) -> Void) -> Void)?

    /// Stops the app being held open for ever by a cube that went quiet part way through.
    private var deviceDeadline: Timer?

    /// What to call once the cube has nothing left to say, held while the two writes are out. `nil` once it has been
    /// called, which is what makes the deadline and the last acknowledgement safe to race.
    private var quitFinished: (() -> Void)?

    init(deviceEvents: DeviceEventRecorder, settings: SettingStore? = nil, debugLog: DebugLog?) {
        self.deviceEvents = deviceEvents
        self.settings = settings
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
    /// **Gated on `pause_on_lock`**, which is read here rather than anywhere earlier -- see below.
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
    /// second opinion about it. `true` means `finished` is called exactly once: by the second acknowledgement, or by
    /// the deadline, whichever gets there first.
    ///
    /// Separate from the delegate method so it can be driven without terminating anything, which is the same split
    /// `run(at:)` has and for the same reason.
    ///
    /// **`pause_on_lock` is read here, at the step that needs it**, which is `CLAUDE.md`'s own worked example of the
    /// source-of-truth rule: not at launch, not passed down the call chain, but asked of the table at the moment the
    /// answer is about to be acted on. Somebody who changes it on the App tab and quits gets the answer they just set.
    ///
    /// **The whole step is gated, not just the pause**, which is the archive's reading of its own setting: quitting is
    /// one of the two ways the app locks the cube, so the setting that governs "pause whenever the app locks" governs
    /// whether the quit locks at all. With it off, quitting touches the cube in no way -- which is what somebody
    /// wanting the cube to go on tracking by itself while the app is shut has asked for.
    @discardableResult
    func pauseAndLockTheCube(then finished: @escaping () -> Void) -> Bool {
        guard let sendToTheDevice, isDeviceConnected?() == true else {
            debugLog?.record(.quit, "Quit: no cube connected, so there is nothing to pause or lock")
            return false
        }
        // **An unreadable row counts as off**, which is not the seeded default and is deliberate. Of the two ways to
        // be wrong, leaving the cube running is visible in its own history and undone by flipping it; locking a cube
        // is not, because nothing in this app sends `0x04 0x02` -- a lock this app applied by accident can only be
        // lifted from the vendor's app or by a factory reset. `ManualMode.startIfNoDeviceIsPaired` chooses its
        // fallback the same way and for the same reason: take the failure somebody can get out of.
        guard settings?.flag("pause_on_lock", field: "enabled") == true else {
            debugLog?.record(.quit, "Quit: pause_on_lock is off, so the cube is left as it is")
            return false
        }
        // Held rather than captured, so the deadline and the last acknowledgement race for it instead of both firing:
        // whichever gets here first takes it and leaves `nil` behind. The same shape as `DeviceLogin.finishCommand`,
        // and it is what makes `letTheQuitProceed` safe to call twice.
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

        // **Sent whatever the cube is already doing, and that is not free.** The archive guarded its pause on the app
        // believing the cube was running, because `0x06 0x01` is *not* idempotent: measured on hardware 2026-08-12,
        // the cube mints a `device_event` per write, and four identical writes inside one second left four events and
        // stranded a row unfinalised (see the archive's `MenuBarController.limitWriteSentAtEventNumber`). This app
        // cannot make that check honestly -- it has no reading of the cube's pause state, and inventing one would be
        // the second answer `CLAUDE.md` forbids -- so it sends once per quit and accepts that quitting an
        // already-paused cube costs one spurious event. What would settle it properly is a status request
        // (`DeviceCommandRules.status`), whose answer says whether pause mode is already on.
        sendToTheDevice(DeviceCommandRules.pause(true)) { [weak self] paused in
            guard let self else { return }
            self.debugLog?.record(
                .quit,
                paused ? "Quit: the cube took the pause" : "Quit: the cube did not take the pause"
            )
            // **The lock goes out either way.** A pause that was refused is a reason to want the lock more, not less:
            // locking still stops the cube changing face behind everybody's back, and the two failures have different
            // causes. Giving up here would mean one dropped write costing both steps.
            sendToTheDevice(DeviceCommandRules.lock(true)) { [weak self] locked in
                self?.debugLog?.record(
                    .quit,
                    locked ? "Quit: the cube took the lock" : "Quit: the cube did not take the lock"
                )
                self?.letTheQuitProceed()
            }
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
        if let closed = deviceEvents.closeOpenSegment(at: moment) {
            debugLog?.record(.quit, "Quit: closed the open segment, device_event \(closed.deviceEventID)")
        } else {
            debugLog?.record(.quit, "Quit: nothing was being timed")
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

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
/// It is where the rest of the quit steps belong as they arrive -- pausing the cube before letting go of it -- and
/// each of them reads what it needs at the step that needs it, not at launch.
@MainActor
final class QuitSequence: NSObject, NSApplicationDelegate {
    private let deviceEvents: DeviceEventRecorder
    private let debugLog: DebugLog?

    /// Drops any live connection and records the quit, answering whether there was one to drop.
    ///
    /// **A closure rather than the radio itself**, because the radio is made on the first scan and lives behind the
    /// Settings window controller: this runs at a moment when there may never have been one. It is set after that
    /// controller exists (see `main.swift`), which is also why it is a variable rather than an initialiser argument.
    var letGoOfTheDevice: (() -> Bool)?

    init(deviceEvents: DeviceEventRecorder, debugLog: DebugLog?) {
        self.deviceEvents = deviceEvents
        self.debugLog = debugLog
        super.init()
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

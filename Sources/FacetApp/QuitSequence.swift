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
/// It is where the rest of the quit steps belong as they arrive -- pausing the cube, letting go of the radio --
/// and each of them reads what it needs at the step that needs it, not at launch.
@MainActor
final class QuitSequence: NSObject, NSApplicationDelegate {
    private let deviceEvents: DeviceEventRecorder
    private let debugLog: DebugLog?

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
    }
}

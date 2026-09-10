import AppKit
import FacetCore

/// The macOS end of stopping: `NSApplicationDelegate` translated into the two questions `QuitSequence` answers.
///
/// **Six lines of the 186 were ever AppKit, and this is them.** The rest is the app's most consequential
/// ordering: pause before lock because a locked cube keeps counting, a five second deadline chosen against
/// `DeviceLogin.send`'s ten, the race between that deadline and the completion, and closing the segment a crash
/// would otherwise leave open. All of it is now in `FacetCore` where a second platform can reach it, which is the
/// point: a GTK app that exits without running it leaves a wrong entry in somebody's tracked time.
///
/// **`applicationShouldTerminate` rather than `applicationWillTerminate` for the cube**, and the reason is
/// measured rather than stylistic: the pause and the lock are BLE writes, and the process does not outlive
/// `willTerminate` long enough for a round trip, so a command started there would never leave. This method is
/// allowed to answer late, which is exactly what that needs.
///
/// **The reply is derived from what the step did**, never decided separately. Two expressions of "is there
/// anything to send" is the sort of pair that comes to disagree, and the disagreement available here is the worst
/// kind: `.terminateLater` with nothing running behind it is an app that never quits, and a reply sent before this
/// method returns is one that quits twice.
@MainActor
final class QuitDelegate: NSObject, NSApplicationDelegate {
    let sequence: QuitSequence

    init(sequence: QuitSequence) {
        self.sequence = sequence
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let started = sequence.pauseAndLockTheCube { NSApp.reply(toApplicationShouldTerminate: true) }
        return started ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        sequence.run(at: Date())
    }
}

import Foundation

/// Holds a write back until the value stops moving, and lets whoever needs to go first take it out of the way.
///
/// **What it is for is a stepper, not a keystroke.** A held arrow repeats every 0.1s stepping by 1 and every 0.3s
/// stepping by 5 (`StepperHoldRules`), so a control wired straight to the radio would put a command on the wire for
/// every tick of a hold -- and `DeviceLogin.send` refuses a second command while the first is still out, so most of
/// them would be dropped and the one that landed would be whichever tick happened to win. Waiting for the value to
/// settle sends the number somebody stopped on, once.
///
/// **`cancel` is not tidying up, it is the fix for a measured bug.** The archive found that a control which writes
/// immediately -- the double-tap Disable box -- has to cancel a pending debounced write first, because that pending
/// one carries values worked out before the flag flipped, so letting it land afterwards quietly undoes the toggle
/// (`docs/timeflip.md`, the debouncing section). Anything that writes at once takes the queue out of the way first.
///
/// A class rather than a rules enum, unlike most of this app's small pieces, because the thing being modelled is a
/// timer and there is nothing to decide: what is worth testing is that many calls become one, and that a cancel
/// stops the one that was coming.
@MainActor
package final class WriteDebounce {
    /// How long the value has to stand still before it is sent.
    ///
    /// **Half a second, which is chosen against the stepper rather than picked for feel.** The fastest a held arrow
    /// can move is one tick per 0.1s and the slowest is one per 0.3s, so this clears the slower cadence with room to
    /// spare: a hold of any length is one write, at the number the arrow was let go on.
    static let interval: TimeInterval = 0.5

    private let scheduler: Scheduler
    private let interval: TimeInterval
    private var wake: ScheduledWake?
    /// The write that is waiting to go out, held rather than captured so that the wake's body can take it on its
    /// own. Cleared by `cancel` along with the wake, and by the body before it runs.
    private var pending: (@MainActor () -> Void)?

    /// - Parameter scheduler: what does the waiting. The core does not know whether that is a run loop, a GTK
    ///   timeout or a test calling it by hand, which is the whole of `Scheduler`.
    /// - Parameter interval: how long to wait. Defaults to the real one; a test passes something small when the
    ///   interval itself is what is being asserted on.
    package init(scheduler: Scheduler, interval: TimeInterval = WriteDebounce.interval) {
        self.scheduler = scheduler
        self.interval = interval
    }

    /// Whether a write is waiting to go out. What `cancel` is about, and what a test asserts on.
    var isPending: Bool { wake != nil }

    /// Puts this write in the queue, displacing whatever was already there.
    ///
    /// The previous one is dropped rather than also sent: two writes to the same registers are not two facts, they
    /// are one value passed through on its way to where it stopped.
    package func schedule(_ write: @escaping @MainActor () -> Void) {
        cancel()
        pending = write
        // The wake is dropped and the write taken *before* it runs, so a `schedule` made from inside the write
        // is a new pending one rather than something this call then clears.
        wake = scheduler.wake(in: interval) { [weak self] in
            guard let self else { return }
            self.wake = nil
            let write = self.pending
            self.pending = nil
            write?()
        }
    }

    /// Drops a pending write without sending it. Safe to call when there is none.
    package func cancel() {
        wake?.cancel()
        wake = nil
        // Cleared with the wake, not merely released with it. The write held here carries values worked out
        // before whatever is cancelling it, which is the measured bug this method exists for, so a wake that
        // somehow still runs must find nothing rather than the write that was called off.
        pending = nil
    }
}

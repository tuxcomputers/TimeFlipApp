import FacetCore
import Foundation

/// The macOS slot in the clock's square: a `Timer` on `RunLoop.main`.
///
/// **`.common`, for the reason every timer in this app used before this type existed.** The default run loop mode
/// stops dead while a menu is tracking, and this app is a menu bar item with a settings window that can have one
/// open over it, so a wake arranged in the default mode does not happen while somebody is holding a menu down.
/// That decision was repeated at all six call sites and is now made once, here, which is what a port is for.
@MainActor
final class RunLoopScheduler: Scheduler {
    /// A tenth of the interval is what `mayGroup` buys on this platform, which is the number `HistoryTimer`
    /// carried before the port existed and the reason it gave: nothing on that arm needs to land on the second,
    /// and letting the system group the wake stops it waking the machine for one fetch alone.
    static let grouping = 0.1

    func wake(
        in seconds: TimeInterval,
        repeating: Bool,
        mayGroup: Bool,
        _ tick: @escaping @MainActor () -> Void
    ) -> ScheduledWake {
        let timer = Timer(timeInterval: seconds, repeats: repeating) { _ in
            MainActor.assumeIsolated { tick() }
        }
        if mayGroup { timer.tolerance = seconds * Self.grouping }
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopWake(timer: timer)
    }
}

/// **The timer is held here rather than by the caller**, so that a module which drops its handle without
/// cancelling behaves the same as it did before this port existed: the run loop keeps the timer alive, and a
/// repeating one goes on ticking into a closure whose `self` is already weak. Changing that was not part of
/// moving to a port, and doing it silently would have been a behaviour change hiding inside a refactor.
@MainActor
private final class RunLoopWake: ScheduledWake {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    /// `Timer.invalidate` is idempotent and is a no-op on a one-shot that has already fired, which is what lets
    /// `ScheduledWake` promise a `cancel` nobody has to guard.
    func cancel() {
        timer.invalidate()
    }
}

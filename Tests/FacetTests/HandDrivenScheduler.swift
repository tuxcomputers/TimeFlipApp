@testable import FacetCore
import Foundation

/// A `Scheduler` whose wakes happen when the test says so, and never otherwise.
///
/// **This is what lets any of these suites run on Linux at all.** A `@MainActor` swift-testing test does not run on
/// the main thread there, so a `RunLoop.main` timer never fires and every wait timed out (measured 2026-09-09,
/// `docs/linux-port.md`). Driving the tick directly removes the run loop from the question rather than widening a
/// window until it usually passes.
///
/// **It also removes a whole class of flake, and that was measured too.** The waiting this replaced was not naive:
/// it spun the run loop and polled for the condition rather than sleeping a fixed span, precisely because a fixed
/// wait is a claim about how busy the machine is. On 2026-08-25 the timer behind
/// `WriteDebounceTests.testAWriteAfterOneHasGoneOutIsItsOwn` had not fired inside an 80ms window on a loaded CI
/// runner, the second `schedule` cancelled it exactly as it is meant to, one write arrived where two were expected,
/// and CI failed on a debounce that was working perfectly.
///
/// **So nothing driven by this says a real timer ever fires**, and that is worth stating rather than implying. What
/// it skips is `Timer` and `RunLoop`, which is the part with no decisions in it. On the Mac the scripted suite is
/// what covers the real ones.
///
/// **It replaced six `fire()` methods**, one per module, each internal purely so a test could take the place of the
/// run loop. Those were the port trying to exist: with a real one, three modules that had never been testable at
/// all are driven the same way as the three that were.
@MainActor
final class HandDrivenScheduler: Scheduler {
    /// Every wake arranged and not yet cancelled, oldest first.
    private(set) var wakes: [Wake] = []

    /// How many wakes have been arranged since this was made, cancelled or not. What a test asserts on when the
    /// question is whether something armed a timer, rather than what the timer then did.
    private(set) var arranged = 0

    var isEmpty: Bool { wakes.isEmpty }

    func wake(
        in seconds: TimeInterval,
        repeating: Bool,
        _ tick: @escaping @MainActor () -> Void
    ) -> ScheduledWake {
        arranged += 1
        let wake = Wake(seconds: seconds, repeating: repeating, tick: tick, scheduler: self)
        wakes.append(wake)
        return wake
    }

    /// Fires the wake that is waiting, and **throws if there is not exactly one**.
    ///
    /// The single-wake case is nearly every test, and checking the count here rather than at each call site is
    /// what stops a test quietly passing because it drove a different timer than the one it meant to.
    ///
    /// **Throwing rather than recording an issue**, because this helper is used from both suites: `Issue.record`
    /// belongs to swift-testing and `DeviceReconnectorTests` and `QuitSequenceTests` are XCTest. An error is what
    /// both understand, and a silent no-op is what `CLAUDE.md` rules out.
    func tick() throws {
        guard wakes.count == 1 else { throw Fault.notExactlyOneWake(found: wakes.count) }
        fire(wakes[0])
    }

    enum Fault: Error, CustomStringConvertible {
        case notExactlyOneWake(found: Int)

        var description: String {
            switch self {
            case let .notExactlyOneWake(found):
                "expected exactly one wake to be waiting, found \(found)"
            }
        }
    }

    /// Fires every wake waiting, oldest first, once each.
    ///
    /// The list is copied before anything runs, so a tick that arranges the next wake (which is how a one-shot
    /// repeats itself, and how `DeviceReconnector` backs off) does not extend the run it is inside.
    func tickAll() {
        let waiting = wakes
        for wake in waiting { fire(wake) }
    }

    /// Fires one wake and takes it off the list unless it repeats.
    ///
    /// A one-shot goes before its body runs, matching `Timer`, which invalidates a non-repeating timer before
    /// calling it: a body that arms a fresh wake must be arming a new one rather than re-arming this.
    private func fire(_ wake: Wake) {
        if !wake.repeating { remove(wake) }
        wake.tick()
    }

    fileprivate func remove(_ wake: Wake) {
        wakes.removeAll { $0 === wake }
    }

    @MainActor
    final class Wake: ScheduledWake {
        /// What the module asked for. Asserted on where the interval is itself the decision, as in the reconnect
        /// backoff, where getting the sequence right is the whole of what the module does.
        let seconds: TimeInterval
        let repeating: Bool
        let tick: @MainActor () -> Void
        private weak var scheduler: HandDrivenScheduler?

        init(
            seconds: TimeInterval,
            repeating: Bool,
            tick: @escaping @MainActor () -> Void,
            scheduler: HandDrivenScheduler
        ) {
            self.seconds = seconds
            self.repeating = repeating
            self.tick = tick
            self.scheduler = scheduler
        }

        func cancel() {
            scheduler?.remove(self)
        }
    }
}

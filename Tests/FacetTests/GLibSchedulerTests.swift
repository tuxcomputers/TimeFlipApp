#if canImport(CGtk)
import CGtk
import Foundation
import Testing
@testable import FacetCore
@testable import FacetLinux

/// Covers `GLibScheduler`, the Linux slot in the clock's square.
///
/// **Driven rather than waited on.** Every test here turns the default main context by hand with
/// `g_main_context_iteration` until the wake it arranged has fired or the deadline is up, so nothing sleeps
/// and nothing depends on how loaded the machine is. That is also the reason `Package.swift` gives `CGtk` to
/// the test target: without it there is no way to turn the loop, and this file could only have been checked by
/// running the app and watching.
///
/// **Why the timings are milliseconds.** The wake being on time is GLib's business and not this file's -- what
/// is being checked is that the port is wired to it correctly: that a wake fires at all, that a repeat repeats,
/// that a cancel stops it, and that `cancel` is safe on a handle whose source has already gone. The intervals
/// are as short as they can be without the deadline becoming a coin toss.
///
/// **What no test here can catch, said plainly**: whether the wakes land on the context `gtk_main` runs. They
/// are on the default main context, which is the one it runs, and the default is what both this file and
/// `MenuBar` reach without naming -- but a test that turns the loop itself proves the source works, not that
/// anybody is turning it in the app. `main.swift` composing the scheduler is what settles that.
///
/// **`.serialized`, and it is the one suite in the package that needs it.** There is a single default main
/// context per process and every test here turns it, so run in parallel each dispatches whichever sources
/// happen to be ready -- other tests' included -- and spends its deadline waiting to acquire a context another
/// thread is holding. All nine passed that way, but the first took 1.8 seconds to see a wake set for 0.01,
/// which is the contention showing rather than a slow machine.
@Suite(.serialized) @MainActor
struct GLibSchedulerTests {
    /// Turns the main context until `until` answers true, or the deadline passes. Answers whether it did.
    ///
    /// **`false` for may-block**, so a context with nothing ready returns at once rather than parking the
    /// thread until a source is due -- which would make a test that expects *no* wake wait out its own
    /// deadline in one call and report nothing useful.
    private func turn(untilTrue until: () -> Bool, within seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if until() { return true }
            g_main_context_iteration(nil, 0)
        }
        return until()
    }

    @Test func testAOneShotWakeFires() {
        var ticks = 0
        let scheduler = GLibScheduler()

        _ = scheduler.wake(in: 0.01) { ticks += 1 }

        #expect(turn(untilTrue: { ticks > 0 }))
        #expect(ticks == 1)
    }

    @Test func testAOneShotDoesNotFireASecondTime() {
        // `G_SOURCE_REMOVE` is a `0` returned from the callback, which is a number rather than a name because
        // it is a macro; getting it the wrong way round would leave every deadline in the app repeating for
        // ever, and the reconnect backoff would stop backing off.
        var ticks = 0
        let scheduler = GLibScheduler()

        _ = scheduler.wake(in: 0.01) { ticks += 1 }
        _ = turn(untilTrue: { ticks > 0 })
        _ = turn(untilTrue: { ticks > 1 }, within: 0.2)

        #expect(ticks == 1)
    }

    @Test func testARepeatingWakeKeepsFiring() {
        var ticks = 0
        let scheduler = GLibScheduler()

        let wake = scheduler.wake(in: 0.01, repeating: true) { ticks += 1 }
        defer { wake.cancel() }

        #expect(turn(untilTrue: { ticks >= 3 }))
    }

    @Test func testCancellingBeforeItFiresStopsIt() {
        // The one that matters most: `DeviceReconnector` cancels its backoff the moment a cube answers, and a
        // cancel that did nothing would have the app scanning again on top of a live connection.
        var ticks = 0
        let scheduler = GLibScheduler()

        let wake = scheduler.wake(in: 0.05) { ticks += 1 }
        wake.cancel()

        #expect(turn(untilTrue: { ticks > 0 }, within: 0.3) == false)
    }

    @Test func testCancellingARepeatStopsIt() {
        var ticks = 0
        let scheduler = GLibScheduler()

        let wake = scheduler.wake(in: 0.01, repeating: true) { ticks += 1 }
        _ = turn(untilTrue: { ticks >= 2 })
        wake.cancel()
        let after = ticks

        _ = turn(untilTrue: { ticks > after }, within: 0.2)
        #expect(ticks == after)
    }

    @Test func testCancellingAFiredOneShotIsSafe() {
        // `ScheduledWake` promises a `cancel` no caller has to guard, and this platform is where that promise
        // costs something: `g_source_remove` on an identifier GLib has reclaimed logs a critical, and GLib
        // reuses identifiers -- so the careless version could remove a source belonging to something else.
        var ticks = 0
        let scheduler = GLibScheduler()

        let wake = scheduler.wake(in: 0.01) { ticks += 1 }
        #expect(turn(untilTrue: { ticks > 0 }))

        wake.cancel()
        wake.cancel()

        #expect(ticks == 1)
    }

    @Test func testCancellingFromInsideTheTickIsSafe() {
        // What a module tidying up after itself looks like, and it is `WriteDebounce`'s shape exactly. The
        // handle is cleared before the tick runs for this reason: at the moment the closure is called, the
        // one-shot's source is already on its way out.
        var ticks = 0
        let scheduler = GLibScheduler()
        var handle: ScheduledWake?

        handle = scheduler.wake(in: 0.01) {
            ticks += 1
            handle?.cancel()
        }

        #expect(turn(untilTrue: { ticks > 0 }))
        #expect(ticks == 1)
    }

    @Test func testAGroupedWakeStillFires() {
        // `mayGroup` picks `g_timeout_add_seconds`, which is a different source rather than a hint, so it is
        // its own path through `wake` and needs its own check. One second, because that is the shortest
        // interval that source has.
        var ticks = 0
        let scheduler = GLibScheduler()

        _ = scheduler.wake(in: 1, repeating: false, mayGroup: true) { ticks += 1 }

        #expect(turn(untilTrue: { ticks > 0 }, within: 4))
    }

    @Test func testAGroupedWakeUnderASecondIsNotRoundedToNothing() {
        // `g_timeout_add_seconds(0, ...)` fires as fast as the loop turns, which would turn a sub-second wake
        // into a busy loop rather than a wake. Grouping is permission and not an instruction, so the
        // millisecond source answers instead -- and the caller still gets one tick rather than hundreds.
        var ticks = 0
        let scheduler = GLibScheduler()

        _ = scheduler.wake(in: 0.05, repeating: false, mayGroup: true) { ticks += 1 }

        #expect(turn(untilTrue: { ticks > 0 }))
        _ = turn(untilTrue: { ticks > 1 }, within: 0.2)
        #expect(ticks == 1)
    }
}
#endif

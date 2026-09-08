@testable import FacetCore
import Foundation
import Testing

/// Covers `HistoryTimer`: the interval it waits, and its re-reading the setting on every timeout.
///
/// The timeout is driven by calling `fire()` rather than by waiting for a run loop, so the re-arming is
/// asserted in milliseconds instead of minutes. What that skips is `Timer` itself, which is the part with no
/// decisions in it.
@Suite @MainActor
final class HistoryTimerTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var built: HistoryTimer?
    private var timeouts = 0

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    deinit {
        // **The timer stops itself, which is why this does not stop it.** The `tearDown` this replaces
        // called `built?.stop()`, and a `deinit` cannot: it is never isolated. It does not need to
        // either -- `HistoryTimer` keeps its `Timer` in a `TimerHolder` whose own `deinit` invalidates
        // it, a shape that type adopted for exactly this reason and says so. Releasing this instance
        // releases the timer, which invalidates the `Timer`, so the `stop()` was belt and braces rather
        // than the thing that did the stopping.
        database.remove()
    }

    /// Built on first use rather than in `setUpWithError`, which is not main-actor isolated: the timeout closure
    /// captures this test case, and handing that to a `@MainActor` initialiser from there is a data race as far
    /// as the compiler is concerned.
    private var timer: HistoryTimer {
        if let built { return built }
        let created = HistoryTimer(settings: settings, debugLog: nil) { self.timeouts += 1 }
        built = created
        return created
    }

    @discardableResult
    private func setInterval(_ seconds: Int) -> Bool {
        database.execute(
            "UPDATE setting SET setting_value = '{\"seconds\":\(seconds)}' "
                + "WHERE setting_name = 'fetch_history_interval_seconds';"
        )
    }

    // MARK: - what it waits

    @Test func testItStartsOnWhateverTheSettingSays() {
        #expect(setInterval(45))

        timer.start()

        #expect(timer.scheduledSeconds == 45)
    }

    @Test func testTheSeededValueIsWhatADevBuildWaits() {
        // `011_setting.sql` seeds 10, deliberately below the production floor: fast polling while working on
        // it. Read from the real DDL rather than written by the test, so this fails if the seed changes.
        timer.start()

        #expect(timer.scheduledSeconds == TimeInterval(HistoryTimer.defaultSeconds))
    }

    @Test func testStoppingForgetsEverything() {
        timer.start()

        timer.stop()

        #expect(timer.scheduledSeconds == nil, "start() reads the setting again rather than resuming a value")
    }

    // MARK: - stopping while there is nothing to ask

    /// A timer whose "is there anything to follow" answer this test controls, standing in for an open segment and a
    /// connected cube.
    /// A flag the test moves and an escaping closure reads.
    ///
    /// **A plain `var` captured directly warns**, and the warning has a point: `hasSomethingToFollow` escapes, so
    /// the capture and the later mutation are two different things reaching the same storage, and nothing in the
    /// types says that is safe. It works today because all of this is one synchronous main-actor sequence. A
    /// reference makes the sharing the declaration rather than the coincidence.
    private final class Flag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private func timer(following: @escaping @MainActor () -> Bool) -> HistoryTimer {
        let created = HistoryTimer(
            settings: settings, debugLog: nil, hasSomethingToFollow: following
        ) { self.timeouts += 1 }
        built = created
        return created
    }

    @Test func testATimeoutWithNothingToFollowStopsRatherThanRearming() {
        // Pausing closes the open segment, so a paused app with no cube has nothing to ask and nothing to grow. It
        // used to go on waking every interval to discover that.
        let anything = Flag(true)
        let timer = timer(following: { anything.value })
        timer.start()
        #expect(timer.scheduledSeconds != nil)

        anything.value = false
        timer.fire()

        #expect(timeouts == 0, "the work is not done either -- there is nothing to do")
        #expect(timer.scheduledSeconds == nil, "and no next timeout was armed")
    }

    @Test func testItDoesNotStartWhileThereIsNothingToFollow() {
        let timer = timer(following: { false })

        timer.start()

        #expect(timer.scheduledSeconds == nil)
    }

    @Test func testItComesBackWhenSomethingIsBeingTimedAgain() {
        // `resumeIfStopped` is called from `onTimingChanged`, the funnel every path that starts timing already uses.
        let anything = Flag(false)
        let timer = timer(following: { anything.value })
        timer.start()
        #expect(timer.scheduledSeconds == nil)

        anything.value = true
        timer.resumeIfStopped()

        #expect(timer.scheduledSeconds == TimeInterval(HistoryTimer.defaultSeconds))
    }

    @Test func testResumingAnAlreadyRunningTimerLeavesItAlone() {
        // It is called on every timing change, most of which happen while it is already running. Re-arming there
        // would push the next timeout back each time, so a busy session would fetch history less often than a quiet
        // one.
        #expect(setInterval(45))
        let timer = timer(following: { true })
        timer.start()

        #expect(setInterval(30))
        timer.resumeIfStopped()

        #expect(timer.scheduledSeconds == 45, "still on the interval it was armed with")
    }

    // MARK: - reading it again on every timeout

    @Test func testATimeoutAsksAndThenRearms() {
        #expect(setInterval(30))
        timer.start()

        timer.fire()

        #expect(timeouts == 1)
        #expect(timer.scheduledSeconds == 30, "still waiting the same interval")
    }

    @Test func testAnIntervalChangedWhileWaitingAppliesAtTheNextTimeout() {
        #expect(setInterval(30))
        timer.start()
        #expect(timer.scheduledSeconds == 30, "precondition")

        // Changed by something else entirely -- another connection, or a hand-edited row. Nothing tells the
        // timer, which is the point: it asks again every time it fires.
        #expect(setInterval(120))
        timer.fire()

        #expect(timer.scheduledSeconds == 120)
    }

    @Test func testTheWorkHappensBeforeTheNextIntervalIsRead() {
        // Asking first is what stops a slow fetch and a short interval overlapping: the wait is measured from
        // the end of the work rather than the start of it.
        #expect(setInterval(30))
        var observed: TimeInterval?
        var timer: HistoryTimer?
        timer = HistoryTimer(settings: settings, debugLog: nil) { observed = timer?.scheduledSeconds }
        defer { timer?.stop() }
        timer?.start()
        #expect(setInterval(120))

        timer?.fire()

        #expect(observed == 30, "the work ran while the interval it was waiting was still the old one")
        #expect(timer?.scheduledSeconds == 120, "and the new one was read afterwards")
    }

    // MARK: - the bounds

    @Test func testAMissingRowFallsBackRatherThanSwitchingTheTimerOff() {
        // With a cube paired, not asking for history means not recording time. A malformed row is a worse
        // reason to stop than to use the value the schema seeds.
        #expect(HistoryTimer.interval(fromSeconds: nil) == TimeInterval(HistoryTimer.defaultSeconds))
    }

    @Test func testTheRowIsWhatTheTimerRunsAt() {
        // **One floor, where there were two.** A minute was applied to a build without the developer flag and a
        // second to a build with it, so the seeded 10 meant one cadence on a developer's machine and another
        // everywhere else. There is one build now, and the row is the answer.
        #expect(HistoryTimer.interval(fromSeconds: 10) == 10)
        #expect(HistoryTimer.interval(fromSeconds: 120) == 120)
    }

    @Test func testZeroCannotSpinTheTimer() {
        #expect(HistoryTimer.interval(fromSeconds: 0) == 1)
        #expect(HistoryTimer.interval(fromSeconds: -30) == 1)
    }

    @Test func testAnHourIsTheFarEnd() {
        #expect(HistoryTimer.interval(fromSeconds: 86_400) == 3_600)
        #expect(HistoryTimer.interval(fromSeconds: 3_600) == 3_600)
    }
}

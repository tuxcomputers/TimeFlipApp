@testable import FacetApp
import Foundation
import XCTest

/// Covers `HistoryTimer`: the interval it waits, and its re-reading the setting on every timeout.
///
/// The timeout is driven by calling `fire()` rather than by waiting for a run loop, so the re-arming is
/// asserted in milliseconds instead of minutes. What that skips is `Timer` itself, which is the part with no
/// decisions in it.
@MainActor
final class HistoryTimerTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    private var built: HistoryTimer?
    private var timeouts = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    override func tearDown() {
        built?.stop()
        built = nil
        settings = nil
        database.remove()
        super.tearDown()
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

    func testItStartsOnWhateverTheSettingSays() {
        XCTAssertTrue(setInterval(45))

        timer.start()

        XCTAssertEqual(timer.scheduledSeconds, 45)
    }

    func testTheSeededValueIsWhatADevBuildWaits() {
        // `011_setting.sql` seeds 10, deliberately below the production floor: fast polling while working on
        // it. Read from the real DDL rather than written by the test, so this fails if the seed changes.
        timer.start()

        XCTAssertEqual(timer.scheduledSeconds, TimeInterval(HistoryTimer.defaultSeconds))
    }

    func testStoppingForgetsEverything() {
        timer.start()

        timer.stop()

        XCTAssertNil(timer.scheduledSeconds, "start() reads the setting again rather than resuming a value")
    }

    // MARK: - stopping while there is nothing to ask

    /// A timer whose "is there anything to follow" answer this test controls, standing in for an open segment and a
    /// connected cube.
    private func timer(following: @escaping @MainActor () -> Bool) -> HistoryTimer {
        let created = HistoryTimer(
            settings: settings, debugLog: nil, hasSomethingToFollow: following
        ) { self.timeouts += 1 }
        built = created
        return created
    }

    func testATimeoutWithNothingToFollowStopsRatherThanRearming() {
        // Pausing closes the open segment, so a paused app with no cube has nothing to ask and nothing to grow. It
        // used to go on waking every interval to discover that.
        var anything = true
        let timer = timer(following: { anything })
        timer.start()
        XCTAssertNotNil(timer.scheduledSeconds)

        anything = false
        timer.fire()

        XCTAssertEqual(timeouts, 0, "the work is not done either -- there is nothing to do")
        XCTAssertNil(timer.scheduledSeconds, "and no next timeout was armed")
    }

    func testItDoesNotStartWhileThereIsNothingToFollow() {
        let timer = timer(following: { false })

        timer.start()

        XCTAssertNil(timer.scheduledSeconds)
    }

    func testItComesBackWhenSomethingIsBeingTimedAgain() {
        // `resumeIfStopped` is called from `onTimingChanged`, the funnel every path that starts timing already uses.
        var anything = false
        let timer = timer(following: { anything })
        timer.start()
        XCTAssertNil(timer.scheduledSeconds)

        anything = true
        timer.resumeIfStopped()

        XCTAssertEqual(timer.scheduledSeconds, TimeInterval(HistoryTimer.defaultSeconds))
    }

    func testResumingAnAlreadyRunningTimerLeavesItAlone() {
        // It is called on every timing change, most of which happen while it is already running. Re-arming there
        // would push the next timeout back each time, so a busy session would fetch history less often than a quiet
        // one.
        XCTAssertTrue(setInterval(45))
        let timer = timer(following: { true })
        timer.start()

        XCTAssertTrue(setInterval(30))
        timer.resumeIfStopped()

        XCTAssertEqual(timer.scheduledSeconds, 45, "still on the interval it was armed with")
    }

    // MARK: - reading it again on every timeout

    func testATimeoutAsksAndThenRearms() {
        XCTAssertTrue(setInterval(30))
        timer.start()

        timer.fire()

        XCTAssertEqual(timeouts, 1)
        XCTAssertEqual(timer.scheduledSeconds, 30, "still waiting the same interval")
    }

    func testAnIntervalChangedWhileWaitingAppliesAtTheNextTimeout() {
        XCTAssertTrue(setInterval(30))
        timer.start()
        XCTAssertEqual(timer.scheduledSeconds, 30, "precondition")

        // Changed by something else entirely -- another connection, or a hand-edited row. Nothing tells the
        // timer, which is the point: it asks again every time it fires.
        XCTAssertTrue(setInterval(120))
        timer.fire()

        XCTAssertEqual(timer.scheduledSeconds, 120)
    }

    func testTheWorkHappensBeforeTheNextIntervalIsRead() {
        // Asking first is what stops a slow fetch and a short interval overlapping: the wait is measured from
        // the end of the work rather than the start of it.
        XCTAssertTrue(setInterval(30))
        var observed: TimeInterval?
        var timer: HistoryTimer?
        timer = HistoryTimer(settings: settings, debugLog: nil) { observed = timer?.scheduledSeconds }
        defer { timer?.stop() }
        timer?.start()
        XCTAssertTrue(setInterval(120))

        timer?.fire()

        XCTAssertEqual(observed, 30, "the work ran while the interval it was waiting was still the old one")
        XCTAssertEqual(timer?.scheduledSeconds, 120, "and the new one was read afterwards")
    }

    // MARK: - the bounds

    func testAMissingRowFallsBackRatherThanSwitchingTheTimerOff() {
        // With a cube paired, not asking for history means not recording time. A malformed row is a worse
        // reason to stop than to use the value the schema seeds.
        XCTAssertEqual(
            HistoryTimer.interval(fromSeconds: nil, isDeveloperBuild: true),
            TimeInterval(HistoryTimer.defaultSeconds)
        )
        XCTAssertEqual(
            HistoryTimer.interval(fromSeconds: nil, isDeveloperBuild: false),
            TimeInterval(HistoryTimer.productionMinimumSeconds),
            "the seeded default is a developer's value, so a shipped build floors it"
        )
    }

    func testAShippedBuildFloorsSubMinutePolling() {
        XCTAssertEqual(HistoryTimer.interval(fromSeconds: 10, isDeveloperBuild: false), 60)
        XCTAssertEqual(HistoryTimer.interval(fromSeconds: 10, isDeveloperBuild: true), 10)
    }

    func testZeroCannotSpinTheTimer() {
        XCTAssertEqual(HistoryTimer.interval(fromSeconds: 0, isDeveloperBuild: true), 1)
        XCTAssertEqual(HistoryTimer.interval(fromSeconds: -30, isDeveloperBuild: true), 1)
        XCTAssertEqual(HistoryTimer.interval(fromSeconds: 0, isDeveloperBuild: false), 60)
    }

    func testAnHourIsTheFarEnd() {
        XCTAssertEqual(HistoryTimer.interval(fromSeconds: 86_400, isDeveloperBuild: true), 3_600)
        XCTAssertEqual(HistoryTimer.interval(fromSeconds: 3_600, isDeveloperBuild: false), 3_600)
    }
}

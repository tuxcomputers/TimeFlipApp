@testable import FacetApp
import AppKit
import XCTest

/// The watch that turns a spent `daily_limit` into a stopped clock, and the refusal that keeps it stopped.
///
/// `DailyLimitEnforcement` is where the decisions are tested; this is about what the app does with them, and about
/// the thing that makes the limit testable at all with no cube on the desk: **in manual mode the app is the clock**,
/// so stopping the device is the app's own pause path.
@MainActor
final class DailyLimitWatchTests: XCTestCase {
    private let window = Date(timeIntervalSince1970: 1_700_000_000)

    private func category(_ id: Int, limit: Int) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: "Break",
            iconName: nil,
            colourID: 0,
            colour: nil,
            usesWhiteLines: false,
            dailyLimitMinutes: limit,
            isActive: true
        )
    }

    /// A watch reading a reading the test controls, and counting the stops it asks for.
    private func watch(
        reading: @escaping () -> TimingReadout.Reading,
        stopped: @escaping () -> Void = {}
    ) -> DailyLimitWatch {
        DailyLimitWatch(
            timing: reading,
            windowStart: { _ in self.window },
            debugLog: nil,
            stopTiming: stopped
        )
    }

    func testTheClockIsStoppedWhenTheBudgetIsSpent() {
        // The whole feature in one check: 5 minutes of limit, 5 minutes recorded, and the app stops itself.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 5), state: .running, seconds: 300)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 1)
        XCTAssertTrue(watch.isReached)
    }

    func testAClockShortOfTheLimitIsLeftRunning() {
        // 20 seconds short, which is where the archive's checklist staged its crossing and where this app's
        // scripted check stages it too.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 5), state: .running, seconds: 280)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0)
        XCTAssertFalse(watch.isReached)
    }

    func testACategoryWithNoLimitIsNeverStopped() {
        // `daily_limit = 0` is no limit at all, so a whole day against it is not a crossing.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 0), state: .running, seconds: 86_400)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0)
        XCTAssertFalse(watch.isReached)
    }

    func testItDoesNotStopTheSameSessionTwice() {
        // Once stopped, the reading comes back paused, and a second stop would start it again -- `togglePause` being
        // a toggle. This is the case that makes the latch matter here rather than only in the rules.
        var stops = 0
        var state = TimingState.running
        let watch = watch(
            reading: { TimingReadout.Reading(category: self.category(7, limit: 5), state: state, seconds: 300) },
            stopped: {
                stops += 1
                state = .paused
            }
        )

        watch.check(at: window)
        watch.check(at: window)
        watch.check(at: window)

        XCTAssertEqual(stops, 1, "the clock is stopped once, not on every tick after it")
    }

    func testStartingItAgainOverTheLimitStopsItAgain() {
        // The limit is hard: picking the category back up does not buy more time, it is stopped on the next tick.
        var stops = 0
        var state = TimingState.running
        let watch = watch(
            reading: { TimingReadout.Reading(category: self.category(7, limit: 5), state: state, seconds: 300) },
            stopped: {
                stops += 1
                state = .paused
            }
        )

        watch.check(at: window)
        state = .running
        watch.check(at: window)

        XCTAssertEqual(stops, 2)
    }

    func testNothingBeingTimedIsNotACrossing() {
        var stops = 0
        let watch = watch(reading: { .idle }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0)
        XCTAssertFalse(watch.isReached)
    }

    func testARaisedLimitLiftsTheRefusalWithoutStartingTheClock() {
        // Raising the limit on the Categories tab is answered immediately -- but in manual mode nothing starts
        // timing on its own. The user gets their Resume back; they do not get time recorded while they were away.
        var stops = 0
        var limit = 5
        var state = TimingState.running
        let watch = DailyLimitWatch(
            timing: { TimingReadout.Reading(category: self.category(7, limit: limit), state: state, seconds: 300) },
            windowStart: { _ in self.window },
            debugLog: nil,
            stopTiming: {
                stops += 1
                state = .paused
            }
        )

        watch.check(at: window)
        XCTAssertTrue(watch.isReached)
        XCTAssertEqual(state, .paused)

        limit = 10
        watch.check(at: window)

        XCTAssertFalse(watch.isReached, "the refusal is lifted")
        // The clock is the user's to start. `stopTiming` is the only thing this watch can call, so the proof that
        // nothing resumed on their behalf is that the session is still stopped and was stopped exactly once.
        XCTAssertEqual(state, .paused, "nothing started the clock on the user's behalf")
        XCTAssertEqual(stops, 1)
    }

    // MARK: - the refusal every path asks

    func testAResumeIsRefusedWhileTheLimitIsSpent() {
        // Paused and over the limit: the one combination that cannot be clicked out of.
        XCTAssertFalse(ManualTimerRules.isClickable(.paused, isLimitReached: true))
    }

    func testPausingIsNeverRefused() {
        // Stopping stays available throughout. A limit that trapped somebody into recording time would be the
        // opposite of what it is for.
        XCTAssertTrue(ManualTimerRules.isClickable(.running, isLimitReached: true))
    }

    func testTheOrdinaryCasesAreUnchanged() {
        XCTAssertTrue(ManualTimerRules.isClickable(.paused, isLimitReached: false))
        XCTAssertTrue(ManualTimerRules.isClickable(.running, isLimitReached: false))
        XCTAssertFalse(ManualTimerRules.isClickable(.idle, isLimitReached: false))
        XCTAssertFalse(ManualTimerRules.isClickable(.idle, isLimitReached: true))
    }

    func testTheStatusItemsRightHalfBecomesANoOp() {
        // The archive exercised the refusal through this half rather than the menu item, precisely because the menu
        // item is disabled and clicking it proves nothing.
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: false, timing: .paused, isLimitReached: true), .ignore
        )
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: false, timing: .paused, isLimitReached: false), .togglePause
        )
    }

    func testTheLeftHalfStillOpensTheMenu() {
        // Quit is only reachable through the menu, so no state may take the left half away.
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: true, timing: .paused, isLimitReached: true), .showMenu
        )
    }

    func testTheDropdownItemStillReadsResumeWhileItIsRefused() {
        // It says what clicking would do, and it will not do it. A dead item claiming something else is on offer
        // would be worse than a dead one telling the truth.
        XCTAssertEqual(ManualTimerRules.pauseMenuTitle(for: .paused), "Resume")
    }
}

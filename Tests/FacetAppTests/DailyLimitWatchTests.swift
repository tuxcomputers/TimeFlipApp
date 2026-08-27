@testable import FacetApp
import AppKit
import XCTest

/// The watch that turns a spent `daily_limit` into a stopped clock, and the refusal that keeps it stopped.
///
/// `DailyLimitEnforcement` is where the decisions are tested; this is about what the app does with them, and about
/// the thing that makes the limit testable at all with no cube on the desk: **in manual mode the app is the clock**,
/// so stopping the device is the app's own pause path.
///
/// **Every reading here says `isCounting` as well as `state`, and that is not boilerplate.** `state` is about *this
/// app's* clock and answers `.idle` for a cube however busy it is; `isCounting` is whether the figure is moving, which
/// is the question the watch actually has to ask. These fixtures said only the first until run 116 found a cube five
/// seconds from its limit sitting there for 68 seconds with the tick never started.
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
        let reading = TimingReadout.Reading(category: category(7, limit: 5), state: .running, seconds: 300, isCounting: true)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 1)
        XCTAssertTrue(watch.isLimitReached)
    }

    func testAClockShortOfTheLimitIsLeftRunning() {
        // 20 seconds short, which is where the archive's checklist staged its crossing and where this app's
        // scripted check stages it too.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 5), state: .running, seconds: 280, isCounting: true)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0)
        XCTAssertFalse(watch.isLimitReached)
    }

    func testACategoryWithNoLimitIsNeverStopped() {
        // `daily_limit = 0` is no limit at all, so a whole day against it is not a crossing.
        var stops = 0
        let reading = TimingReadout.Reading(category: category(7, limit: 0), state: .running, seconds: 86_400, isCounting: true)
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0)
        XCTAssertFalse(watch.isLimitReached)
    }

    func testItDoesNotStopTheSameSessionTwice() {
        // Once stopped, the reading comes back paused, and a second stop would start it again -- `togglePause` being
        // a toggle. This is the case that makes the latch matter here rather than only in the rules.
        var stops = 0
        var state = TimingState.running
        let watch = watch(
            reading: { TimingReadout.Reading(category: self.category(7, limit: 5), state: state, seconds: 300, isCounting: state == .running) },
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
            reading: { TimingReadout.Reading(category: self.category(7, limit: 5), state: state, seconds: 300, isCounting: state == .running) },
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

    func testACubeIsStoppedEvenThoughTheAppsOwnClockIsIdle() {
        // **The shape run 116 found, and the one every fixture above is the wrong shape for.** A cube produces a
        // reading that is `.idle` and counting at the same time: the app runs no session of its own while it follows
        // one, so `state` says idle however busy the cube is, and `isCounting` is the only thing that says the figure
        // is moving. Asking `state == .running` meant the tick never started, and a cube five seconds from its limit
        // sat on it for 68 seconds with nothing sent.
        var stops = 0
        let reading = TimingReadout.Reading(
            category: category(7, limit: 5),
            state: .idle,
            seconds: 300,
            isCounting: true,
            cubeFace: 1,
            deviceIsPaused: false
        )
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 1, "a cube over its limit is stopped, whatever the app's own clock is doing")
        XCTAssertTrue(watch.isLimitReached)
    }

    func testACubeShortOfTheLimitIsLeftRunning() {
        var stops = 0
        let reading = TimingReadout.Reading(
            category: category(7, limit: 5),
            state: .idle,
            seconds: 280,
            isCounting: true,
            cubeFace: 1,
            deviceIsPaused: false
        )
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0)
    }

    func testAPausedCubeIsNotStoppedAgain() {
        // A stopped cube is not counting, which is the same answer the app's own paused clock gives -- so the one
        // question covers both and there is no mode to tell apart.
        var stops = 0
        let reading = TimingReadout.Reading(
            category: category(7, limit: 5),
            state: .idle,
            seconds: 300,
            isCounting: false,
            cubeFace: 1,
            deviceIsPaused: true
        )
        let watch = watch(reading: { reading }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0, "nothing counting means nothing that can cross a limit")
    }

    func testNothingBeingTimedIsNotACrossing() {
        var stops = 0
        let watch = watch(reading: { .idle }, stopped: { stops += 1 })

        watch.check(at: window)

        XCTAssertEqual(stops, 0)
        XCTAssertFalse(watch.isLimitReached)
    }

    func testARaisedLimitLiftsTheRefusalWithoutStartingTheClock() {
        // Raising the limit on the Categories tab is answered immediately -- but in manual mode nothing starts
        // timing on its own. The user gets their Resume back; they do not get time recorded while they were away.
        var stops = 0
        var limit = 5
        var state = TimingState.running
        let watch = DailyLimitWatch(
            timing: { TimingReadout.Reading(category: self.category(7, limit: limit), state: state, seconds: 300, isCounting: state == .running) },
            windowStart: { _ in self.window },
            debugLog: nil,
            stopTiming: {
                stops += 1
                state = .paused
            }
        )

        watch.check(at: window)
        XCTAssertTrue(watch.isLimitReached)
        XCTAssertEqual(state, .paused)

        limit = 10

        // **No second `check` here, deliberately, and this test used to have one.** With it, this passed while the
        // app was broken: stopping the clock stands the tick down, so the real app never gets another `check` and the
        // refusal it asks about was answered from the last one for the rest of the launch (run 15, 2026-08-16). The
        // raised limit has to be answered by the ask itself.
        XCTAssertFalse(watch.isLimitReached, "the refusal is lifted")
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

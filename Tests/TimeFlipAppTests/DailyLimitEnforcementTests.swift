@testable import TimeFlipApp
import XCTest

/// The hard `daily_limit`: the pause it sends when a category spends its budget, the refusal to send
/// the unpause afterwards, and the flip-away/flip-back handling that follows from pause being a
/// property of the cube while a limit is a property of a category.
///
/// `MenuBarController` owns the figures and the wire; every decision is here, which is what lets the
/// awkward sequences be tested without a radio -- the crossing, the stale total in the seconds after
/// a pause, a double tap starting the cube again, and a relaunch onto an already-paused cube.
final class DailyLimitEnforcementTests: XCTestCase {
    private let window = Date(timeIntervalSince1970: 1_700_000_000)
    private let breakCategory = 7
    private let meetingCategory = 8

    // MARK: - The comparison itself

    func testTheLimitIsReachedOnTheMinuteNotAfterIt() {
        // A 60-minute limit is spent at 60:00. Drawn from the same call as the menu bar's red
        // duration, so the colour and the pause cannot disagree by a second.
        XCTAssertTrue(DailyLimitEnforcement.isReached(totalSeconds: 3600, limitMinutes: 60))
        XCTAssertFalse(DailyLimitEnforcement.isReached(totalSeconds: 3599, limitMinutes: 60))
    }

    func testNoLimitIsNeverReached() {
        // `daily_limit = 0` is "no limit" in the schema, so no total spends it.
        XCTAssertFalse(DailyLimitEnforcement.isReached(totalSeconds: 86_400, limitMinutes: 0))
        XCTAssertNil(DailyLimitEnforcement.secondsUntilReached(totalSeconds: 0, limitMinutes: 0))
    }

    func testSecondsUntilReachedIsWhatIsLeftOfTheBudget() {
        XCTAssertEqual(DailyLimitEnforcement.secondsUntilReached(totalSeconds: 3540, limitMinutes: 60), 60)
        // Already spent: nothing to wait for, so no timer to arm.
        XCTAssertNil(DailyLimitEnforcement.secondsUntilReached(totalSeconds: 3600, limitMinutes: 60))
    }

    // MARK: - Crossing the limit

    func testReachingTheLimitPausesTheCube() {
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3599, paused: false), .none)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertTrue(enforcement.isReachedForCurrentCategory)
    }

    func testACubeAlreadyPausedAtTheCrossingIsLeftAlone() {
        // Nothing to send: the user pausing a second before the limit lands leaves the cube in the
        // state the limit wanted. The claim is still taken, which is what a later flip away lifts.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: true), .none)
        XCTAssertTrue(enforcement.isPausedByLimit)
    }

    func testTheStaleTotalRightAfterAPauseDoesNotUndoIt() {
        // The regression the latch exists for. Pausing stops the live segment counting, and that
        // segment is not a `time_entry` until the pause's own history fetch ingests it -- so for a
        // moment the tracked figure reads *under* the limit. Without the latch this is a `.resume`,
        // undoing the pause on the strength of a total the app knows is incomplete.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 2400, paused: true), .none)
        XCTAssertTrue(enforcement.isReachedForCurrentCategory)
    }

    func testADoubleTapOnTheCubePutsThePauseStraightBack() {
        // The one path no refusal can reach: the cube's own double tap pauses and unpauses it in
        // firmware and only tells the app afterwards. So it is answered rather than refused -- the
        // history frame reports it running, and the pause goes out again.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: true), .none)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
    }

    // MARK: - Flipping off the spent face, and back

    func testFlippingToACategoryWithBudgetResumesTheCube() {
        // Pause belongs to the cube, a limit to a category: leaving it paused would spend one
        // category's budget and stop the day's tracking with it.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, paused: true), .resume)
        XCTAssertFalse(enforcement.isReachedForCurrentCategory)
        XCTAssertFalse(enforcement.isPausedByLimit)
    }

    func testFlippingBackToTheSpentFacePausesItAgain() {
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, paused: true), .resume)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
    }

    func testACategoryWithNoLimitOfItsOwnIsNeverHeld() {
        // The common case for the face someone flips to: no limit set, so nothing to spend.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 0, total: 86_400, paused: true), .resume)
    }

    func testAPauseTheUserAskedForIsNotLiftedByAFlip() {
        // Only a pause of this type's own making is lifted. Auto-resuming the user's would make
        // Pause a control that undoes itself on the next flip of the cube.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 600, paused: true), .none)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, paused: true), .none)
        XCTAssertFalse(enforcement.isPausedByLimit)
    }

    func testIdleDoesNotResumeAndDoesNotForgetWhatIsSpent() {
        // No category on show is not the same as a category with budget: there is nothing to
        // measure, so nothing is sent, and what has been spent stays spent for the flip back.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: nil, limit: 0, total: 0, paused: true), .none)
        XCTAssertFalse(enforcement.isReachedForCurrentCategory)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: true), .none)
        XCTAssertTrue(enforcement.isReachedForCurrentCategory)
    }

    // MARK: - Clearing the hold

    func testTheDayBoundaryClearsEveryLatch() {
        // `daily_reset_time` starts the budgets again, so the window carrying the latches is what
        // releases them -- no separate reset path to remember to call.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        let tomorrow = window.addingTimeInterval(86_400)
        XCTAssertEqual(
            enforcement.evaluate(
                categoryID: breakCategory,
                limitMinutes: 60,
                totalSeconds: 0,
                isPaused: true,
                windowStart: tomorrow
            ),
            .resume
        )
        XCTAssertFalse(enforcement.isReachedForCurrentCategory)
    }

    func testRaisingTheLimitReleasesTheCategoryTheSameDay() {
        // The one thing a stale total cannot imitate, and so what the latch stores the limit for: an
        // edit on the Categories tab is a deliberate act and is answered immediately.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 90, total: 3600, paused: true), .resume)
        XCTAssertFalse(enforcement.isReachedForCurrentCategory)
    }

    func testClearingTheLimitReleasesTheCategoryToo() {
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: false), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 0, total: 3600, paused: true), .resume)
    }

    func testLoweringTheLimitBelowWhatIsSpentHoldsItAgain() {
        // The edit is answered, and the new number is what answers: 30 minutes is spent by an hour.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 90, total: 3600, paused: false), .none)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 30, total: 3600, paused: false), .pause)
    }

    // MARK: - Across a relaunch

    func testARelaunchOntoAPausedCubeOnASpentFaceAdoptsThePause() {
        // The claim is in memory and the cube's pause is not, so a relaunch finds a paused cube and
        // no idea who paused it. A spent category and a paused cube is exactly the state this type
        // produces, so it takes it back -- which is what lets the first flip away lift it.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, paused: true), .none)
        XCTAssertTrue(enforcement.isPausedByLimit)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, paused: true), .resume)
    }

    private func evaluate(
        _ enforcement: inout DailyLimitEnforcement,
        category: Int?,
        limit: Int,
        total: TimeInterval,
        paused: Bool
    ) -> DailyLimitAction {
        enforcement.evaluate(
            categoryID: category,
            limitMinutes: limit,
            totalSeconds: total,
            isPaused: paused,
            windowStart: window
        )
    }
}

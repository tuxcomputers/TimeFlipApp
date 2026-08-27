@testable import FacetApp
import XCTest

/// The hard `daily_limit`: the pause it sends when a category spends its budget, the refusal to send the unpause
/// afterwards, and the flip-away/flip-back handling that follows from pause being a property of the cube while a limit
/// is a property of a category.
///
/// **Every one of these runs without a radio**, which is the point of the split: the decision is `DailyLimitEnforcement`
/// and the sending is somebody else's, so the awkward sequences are all reachable here -- the crossing, the stale total
/// in the seconds after a pause, a double tap starting the cube again, and a relaunch onto an already paused cube.
///
/// Carried over from `Archive/TimeFlipAppTests/DailyLimitEnforcementTests.swift`. The cases are the archive's and are
/// kept as they stand: each one names a sequence that happened on a real desk, and re-deriving that list would cost
/// the same again.
final class DailyLimitEnforcementTests: XCTestCase {
    private let window = Date(timeIntervalSince1970: 1_700_000_000)
    private let breakCategory = 7
    private let meetingCategory = 8

    // MARK: - the comparison itself

    func testTheLimitIsReachedOnTheMinuteNotAfterIt() {
        // A 60-minute limit is spent at 60:00. Drawn from the same call as the menu bar's red duration will be, so the
        // colour and the pause cannot disagree by a second.
        XCTAssertTrue(DailyLimitEnforcement.isLimitReached(totalSeconds: 3600, dailyLimitMinutes: 60))
        XCTAssertFalse(DailyLimitEnforcement.isLimitReached(totalSeconds: 3599, dailyLimitMinutes: 60))
    }

    func testNoLimitIsNeverReached() {
        // `daily_limit = 0` is "no limit" in the schema, so no total spends it.
        XCTAssertFalse(DailyLimitEnforcement.isLimitReached(totalSeconds: 86_400, dailyLimitMinutes: 0))
        XCTAssertNil(DailyLimitEnforcement.secondsUntilReached(totalSeconds: 0, dailyLimitMinutes: 0))
    }

    func testSecondsUntilReachedIsWhatIsLeftOfTheBudget() {
        XCTAssertEqual(DailyLimitEnforcement.secondsUntilReached(totalSeconds: 3540, dailyLimitMinutes: 60), 60)
        // Already spent: nothing to wait for, so no timer to arm.
        XCTAssertNil(DailyLimitEnforcement.secondsUntilReached(totalSeconds: 3600, dailyLimitMinutes: 60))
    }

    // MARK: - crossing the limit

    func testReachingTheLimitPausesTheCube() {
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3599, isCounting: true), .none)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertTrue(isLimitReached(enforcement, category: breakCategory, limit: 60, total: 3600))
    }

    func testACubeAlreadyPausedAtTheCrossingIsLeftAlone() {
        // Nothing to send: the user pausing a second before the limit lands leaves the cube in the state the limit
        // wanted. The claim is still taken, which is what a later flip away lifts.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: false), .none)
        XCTAssertTrue(enforcement.isLimitHoldingPause)
    }

    func testTheStaleTotalRightAfterAPauseDoesNotUndoIt() {
        // The regression the latch exists for. Pausing stops the live segment counting, and that segment is not a
        // `time_entry` until the pause's own history is ingested -- so for a moment the tracked figure reads *under*
        // the limit. Without the latch this is a `.resume`, undoing the pause on the strength of a total the app knows
        // is incomplete.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 2400, isCounting: false), .none)
        XCTAssertTrue(isLimitReached(enforcement, category: breakCategory, limit: 60, total: 2400))
    }

    func testADoubleTapOnTheCubePutsThePauseStraightBack() {
        // The one path no refusal can reach: the cube's own double tap pauses and unpauses it in firmware and only
        // tells the app afterwards. So it is answered rather than refused -- the history frame reports it running, and
        // the pause goes out again.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: false), .none)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
    }

    // MARK: - flipping off the spent face, and back

    func testAPauseThatSurvivesOntoABudgetedCategoryIsLifted() {
        // Pause belongs to the cube, a limit to a category: leaving it paused would spend one category's budget and
        // stop the day's tracking with it.
        //
        // The state this models -- paused, on a category with budget -- is **not** what a flip produces on real
        // hardware, where the firmware resumes the cube itself (see the type doc, measured 2026-08-12). It is what an
        // edit produces: the limit raised or cleared while the cube sits paused on the face that spent it, so nothing
        // physical has lifted the pause and this type's own `.resume` is the only thing that will.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, isCounting: false), .resume)
        XCTAssertFalse(isLimitReached(enforcement, category: meetingCategory, limit: 60, total: 120))
        XCTAssertFalse(enforcement.isLimitHoldingPause)
    }

    func testTheFirmwareLiftingThePauseDropsTheClaimOnIt() {
        // What a flip actually looks like: the cube arrives on the new face already running. Nothing is sent, and the
        // claim must not outlive the pause it was about.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertTrue(enforcement.isLimitHoldingPause, "precondition: this type placed the pause")

        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 0, total: 120, isCounting: true), .none)
        XCTAssertFalse(
            enforcement.isLimitHoldingPause,
            "the firmware resumed the cube on the flip, so there is no longer a pause of this type's to claim"
        )
    }

    func testTheUsersOwnPauseIsNotUndoneAfterALimitPauseWasLiftedByAFlip() {
        // The sequence the stale claim broke, all of it reachable in a few seconds on the desk: spend a limit, flip
        // away (firmware resumes), then pause deliberately on the new face. That pause is the user's, and a limit that
        // had not noticed losing its own would send `.resume` on the next frame and take it away again.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 0, total: 120, isCounting: true), .none)

        XCTAssertEqual(
            evaluate(&enforcement, category: meetingCategory, limit: 0, total: 180, isCounting: false), .none,
            "the user paused this; nothing here asked for it and nothing here undoes it"
        )
    }

    func testFlippingBackToTheSpentFacePausesItAgain() {
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, isCounting: false), .resume)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
    }

    func testACategoryWithNoLimitOfItsOwnIsNeverHeld() {
        // The common case for the face someone flips to: no limit set, so nothing to spend.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 0, total: 86_400, isCounting: false), .resume)
    }

    func testAPauseTheUserAskedForIsNotLiftedByAFlip() {
        // Only a pause of this type's own making is lifted. Auto-resuming the user's would make Pause a control that
        // undoes itself on the next flip of the cube.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 600, isCounting: false), .none)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, isCounting: false), .none)
        XCTAssertFalse(enforcement.isLimitHoldingPause)
    }

    func testIdleDoesNotResumeAndDoesNotForgetWhatIsSpent() {
        // No category on show is not the same as a category with budget: there is nothing to measure, so nothing is
        // sent, and what has been spent stays spent for the flip back.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: nil, limit: 0, total: 0, isCounting: false), .none)
        XCTAssertFalse(isLimitReached(enforcement, category: nil, limit: 0, total: 0))
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: false), .none)
        XCTAssertTrue(isLimitReached(enforcement, category: breakCategory, limit: 60, total: 3600))
    }

    // MARK: - clearing the hold

    func testTheDayBoundaryClearsEveryLatch() {
        // `daily_reset_time` starts the budgets again, so the window carrying the latches is what releases them -- no
        // separate reset path to remember to call.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        let tomorrow = window.addingTimeInterval(86_400)
        XCTAssertEqual(
            enforcement.evaluate(
                categoryID: breakCategory,
                dailyLimitMinutes: 60,
                totalSeconds: 0,
                isCounting: false,
                windowStart: tomorrow
            ),
            .resume
        )
        XCTAssertFalse(
            enforcement.isLimitReached(
                categoryID: breakCategory, dailyLimitMinutes: 60, totalSeconds: 0, windowStart: tomorrow
            )
        )
    }

    func testRaisingTheLimitReleasesTheCategoryTheSameDay() {
        // The one thing a stale total cannot imitate, and so what the latch stores the limit for: an edit on the
        // Categories tab is a deliberate act and is answered immediately.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 90, total: 3600, isCounting: false), .resume)
        XCTAssertFalse(isLimitReached(enforcement, category: breakCategory, limit: 90, total: 3600))
    }

    func testARaisedLimitIsAnsweredWithNoFurtherEvaluate() {
        // **The bug run 15 found, in the smallest form that shows it.** Every other case here raises the limit and
        // then calls `evaluate` again, which is what a running tick would do -- but the tick stands down the moment
        // the limit stops the clock, so in the app there is no second `evaluate`. Nothing below calls one: the latch
        // is set, the limit is raised on the Categories tab, and the refusal is asked the way the dropdown, the status
        // item's right half and `togglePause` ask it.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertTrue(isLimitReached(enforcement, category: breakCategory, limit: 60, total: 3600))

        XCTAssertFalse(
            isLimitReached(enforcement, category: breakCategory, limit: 90, total: 3600),
            "raising the limit to 90 lifts the refusal, without waiting for a tick that is not coming back"
        )
        // And the latch still does its job for the limit it was actually taken at: a total that has dipped under it
        // because the closing segment is not a `time_entry` yet does not read as budget.
        XCTAssertTrue(isLimitReached(enforcement, category: breakCategory, limit: 60, total: 2400))
    }

    func testALoweredLimitStillHoldsWithNoFurtherEvaluate() {
        // The other direction of the same ask, which must not be released by the edit alone: 30 minutes is spent by
        // an hour, so the refusal survives the latch being dropped for disagreeing.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertTrue(isLimitReached(enforcement, category: breakCategory, limit: 30, total: 3600))
    }

    func testClearingTheLimitReleasesTheCategoryToo() {
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: true), .pause)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 0, total: 3600, isCounting: false), .resume)
    }

    func testLoweringTheLimitBelowWhatIsSpentHoldsItAgain() {
        // The edit is answered, and the new number is what answers: 30 minutes is spent by an hour.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 90, total: 3600, isCounting: true), .none)
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 30, total: 3600, isCounting: true), .pause)
    }

    // MARK: - across a relaunch

    func testARelaunchOntoAPausedCubeOnASpentFaceAdoptsThePause() {
        // The claim is in memory and the cube's pause is not, so a relaunch finds a paused cube and no idea who paused
        // it. A spent category and a paused cube is exactly the state this type produces, so it takes it back -- which
        // is what lets the first flip away lift it.
        var enforcement = DailyLimitEnforcement()
        XCTAssertEqual(evaluate(&enforcement, category: breakCategory, limit: 60, total: 3600, isCounting: false), .none)
        XCTAssertTrue(enforcement.isLimitHoldingPause)
        XCTAssertEqual(evaluate(&enforcement, category: meetingCategory, limit: 60, total: 120, isCounting: false), .resume)
    }

    private func evaluate(
        _ enforcement: inout DailyLimitEnforcement,
        category: Int?,
        limit: Int,
        total: TimeInterval,
        isCounting: Bool
    ) -> DailyLimitAction {
        enforcement.evaluate(
            categoryID: category,
            dailyLimitMinutes: limit,
            totalSeconds: total,
            isCounting: isCounting,
            windowStart: window
        )
    }

    /// The refusal, asked the way the app asks it: a question about now, not a flag left over from a tick.
    private func isLimitReached(
        _ enforcement: DailyLimitEnforcement,
        category: Int?,
        limit: Int,
        total: TimeInterval
    ) -> Bool {
        enforcement.isLimitReached(
            categoryID: category,
            dailyLimitMinutes: limit,
            totalSeconds: total,
            windowStart: window
        )
    }
}

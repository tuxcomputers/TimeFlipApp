@testable import TimeFlipApp
import Foundation
import XCTest

/// Covers `TimingSession`: what is being timed, whether it is running, and how long for.
///
/// The clock is injected, so elapsed time is asserted rather than waited for. This is the type that exists
/// to be the only answer to "are we recording?", so the cases below are mostly about it not drifting from
/// itself: a pause that banks what was run, a resume that does not lose it, and a toggle that does nothing
/// when there is nothing to toggle.
@MainActor
final class TimingSessionTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func session() -> TimingSession {
        TimingSession(now: { self.clock })
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    func testNothingIsTimedToBeginWith() {
        let session = session()

        XCTAssertNil(session.categoryID)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.elapsed, 0)
    }

    func testStartingRunsTheClock() {
        let session = session()

        session.start(categoryID: 7)
        advance(30)

        XCTAssertEqual(session.categoryID, 7)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.elapsed, 30)
    }

    func testPausingBanksWhatHasRunAndStopsCounting() {
        let session = session()
        session.start(categoryID: 7)
        advance(30)

        session.togglePause()
        advance(120)

        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.elapsed, 30, "the two minutes since the pause are not recorded")
    }

    func testResumingKeepsWhatWasAlreadyBanked() {
        let session = session()
        session.start(categoryID: 7)
        advance(30)
        session.togglePause()
        advance(120)

        session.togglePause()
        advance(10)

        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.elapsed, 40, "30 before the pause plus 10 after, and nothing from the gap")
    }

    func testSeveralPausesAccumulate() {
        let session = session()
        session.start(categoryID: 7)
        for _ in 0 ..< 3 {
            advance(10)
            session.togglePause()
            advance(60)
            session.togglePause()
        }

        XCTAssertEqual(session.elapsed, 30)
    }

    func testStartingAnotherCategoryStartsFromZero() {
        let session = session()
        session.start(categoryID: 7)
        advance(45)

        session.start(categoryID: 9)

        XCTAssertEqual(session.categoryID, 9)
        XCTAssertEqual(session.elapsed, 0, "a new session, not a continuation of the last one")
        XCTAssertTrue(session.isRunning)
    }

    func testStartingTheSameCategoryAgainAlsoStartsFromZero() {
        // One path for picking a category, whatever was running. The alternative -- treating a re-pick as a
        // resume -- is a second meaning for the same click, decided by state the user cannot see.
        let session = session()
        session.start(categoryID: 7)
        advance(45)

        session.start(categoryID: 7)

        XCTAssertEqual(session.elapsed, 0)
    }

    func testStartingAgainWhilePausedRuns() {
        let session = session()
        session.start(categoryID: 7)
        session.togglePause()
        XCTAssertFalse(session.isRunning, "precondition")

        session.start(categoryID: 9)

        XCTAssertTrue(session.isRunning, "picking a category means time that category, never leave it stopped")
    }

    func testTogglingWithNothingPickedDoesNothing() {
        let session = session()

        session.togglePause()

        XCTAssertFalse(session.isRunning, "a session against no category is not a thing to have")
        XCTAssertNil(session.categoryID)
        XCTAssertEqual(session.elapsed, 0)
    }
}

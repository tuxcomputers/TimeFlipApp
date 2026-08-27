@testable import FacetApp
import XCTest

/// Covers `StatusItemClickRouter`: which half of the status item means what, and when the right half means
/// anything at all.
///
/// Tested at this seam for the reason the archived router recorded about itself: the same decisions lived as
/// nested `guard`s inside an `@objc` click handler, and reaching them needed a real status item, a real click and
/// a real window server -- so they were only ever verified by hand.
final class StatusItemClickRouterTests: XCTestCase {
    func testTheLeftHalfOpensTheMenu() {
        for timingState in [TimingState.idle, .running, .paused] {
            // In every timingState, because it is the only route to Quit. Nothing about the clock may take that away.
            XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: true, timingState: timingState), .showMenu)
        }
    }

    func testTheRightHalfPausesAndResumes() {
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: false, timingState: .running), .togglePause)
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: false, timingState: .paused), .togglePause)
    }

    func testTheRightHalfDoesNothingWithNoClockAndNoCube() {
        // Inert rather than falling through to the menu: a right half that quietly did the left half's job would be
        // a merge nobody would notice had happened.
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: false, timingState: .idle), .ignore)
    }

    // MARK: - with a cube on the other end

    func testASingleClickPausesTheCube() {
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: false, timingState: .idle, isCubeConnected: true, clickCount: 1),
            .toggleCubePause
        )
    }

    func testADoubleClickLocksTheCube() {
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: false, timingState: .idle, isCubeConnected: true, clickCount: 2),
            .toggleCubeLock
        )
    }

    func testAThirdClickDoesNotLandBackOnThePause() {
        // `>= 2` rather than `== 2`. A click held down and repeated would otherwise alternate between locking the
        // cube and pausing it, which is two commands nobody asked for.
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: false, timingState: .idle, isCubeConnected: true, clickCount: 3),
            .toggleCubeLock
        )
    }

    func testTheLeftHalfStillOpensTheMenuHoweverManyClicks() {
        // A double click on the left is two menus, not a lock. The gesture belongs to the right half alone, and the
        // left one keeps being the only route to Quit.
        for clicks in 1...3 {
            XCTAssertEqual(
                StatusItemClickRouter.action(
                    isLeftSide: true, timingState: .idle, isCubeConnected: true, clickCount: clicks
                ),
                .showMenu,
                "\(clicks) clicks on the left half"
            )
        }
    }

    func testAPairedCubeInAnotherRoomIsNotACube() {
        // The connection, not the pairing, matching `CubeLockRules.isEnabled`: a command needs a live link, and a
        // gesture that sent one into nothing would be a control that does nothing and says nothing about why.
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: false, timingState: .idle, isCubeConnected: false, clickCount: 2),
            .ignore
        )
    }

    // MARK: - which of the two the right half is acting on

    func testARunningManualSessionIsNotTakenOverByACube() {
        // The app's own clock is asked about first, in the order `TimingReadout` itself reads them -- so the half
        // cannot come to act on the cube while the item beside it draws a manual session.
        XCTAssertEqual(
            StatusItemClickRouter.action(isLeftSide: false, timingState: .running, isCubeConnected: true),
            .togglePause
        )
    }

    func testASpentDailyLimitDoesNotFallThroughToTheCube() {
        // The refusal has to hold. Falling through would mean the same click, in the same place, resuming the cube
        // instead -- which is the enforcement undone by clicking a second time.
        XCTAssertEqual(
            StatusItemClickRouter.action(
                isLeftSide: false, timingState: .paused, isCubeConnected: true, isLimitReached: true
            ),
            .ignore
        )
    }

    func testItAsksTheSameQuestionTheDropdownAsks() {
        // Not a second opinion about when pausing is possible. The previous app had the right half taught about
        // manual mode and the menu item beside it not, leaving a dead Pause above a live one, and nothing failed.
        for timingState in [TimingState.idle, .running, .paused] {
            XCTAssertEqual(
                StatusItemClickRouter.action(isLeftSide: false, timingState: timingState) == .togglePause,
                ManualTimerRules.isClickable(timingState),
                "the half and the menu item have to agree about \(timingState)"
            )
            // And with a cube connected as well: the cube's gestures are what the half does *instead of* the app's
            // own pause, never on top of it.
            XCTAssertEqual(
                StatusItemClickRouter.action(isLeftSide: false, timingState: timingState, isCubeConnected: true)
                    == .togglePause,
                ManualTimerRules.isClickable(timingState),
                "a connected cube changed what the half means about \(timingState)"
            )
        }
    }

    // MARK: - a spent limit, with a cube on the other end

    func testASingleClickWillNotStartACubeOnASpentLimit() {
        // **Reported live on 2026-08-27**, and it was a considered exemption that went stale rather than an oversight:
        // this used to say the limit was about the app's own clock only, because the limit was not enforced against a
        // cube at all. Once `DailyLimitWatch` began enforcing it, the exemption became the way round it -- a click
        // started the cube and the watch stopped it again two seconds later.
        XCTAssertEqual(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                isCubePaused: true,
                isLimitReached: true
            ),
            .ignore
        )
    }

    func testASingleClickWillStillStopACubeOnASpentLimit() {
        // Stopping stays available throughout. A limit that trapped somebody into recording time would be the
        // opposite of what it is for, which is `ManualTimerRules`' rule applied to the cube.
        XCTAssertEqual(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                isCubePaused: false,
                isLimitReached: true
            ),
            .toggleCubePause
        )
    }

    func testADoubleClickStillReachesTheLockOnASpentLimit() {
        // The lock is not the limit's business, and unlocking is the one way out of a timingState this app cannot otherwise
        // reach. `CubeLock.resume` unlocks and leaves the cube stopped, so the gesture stays live and starts nothing.
        XCTAssertEqual(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                isCubePaused: true,
                isLimitReached: true,
                clickCount: 2
            ),
            .toggleCubeLock
        )
    }

    func testACubeWithBudgetIsUnaffected() {
        XCTAssertEqual(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                isCubePaused: true,
                isLimitReached: false
            ),
            .toggleCubePause
        )
    }
}

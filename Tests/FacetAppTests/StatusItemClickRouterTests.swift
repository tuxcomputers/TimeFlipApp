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
        for state in [TimingState.idle, .running, .paused] {
            // In every state, because it is the only route to Quit. Nothing about the clock may take that away.
            XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: true, timing: state), .showMenu)
        }
    }

    func testTheRightHalfPausesAndResumes() {
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: false, timing: .running), .togglePause)
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: false, timing: .paused), .togglePause)
    }

    func testTheRightHalfDoesNothingWithNoClockToStop() {
        // Inert rather than falling through to the menu: a right half that quietly did the left half's job would be
        // a merge nobody would notice had happened.
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: false, timing: .idle), .ignore)
    }

    func testItAsksTheSameQuestionTheDropdownAsks() {
        // Not a second opinion about when pausing is possible. The previous app had the right half taught about
        // manual mode and the menu item beside it not, leaving a dead Pause above a live one, and nothing failed.
        for state in [TimingState.idle, .running, .paused] {
            XCTAssertEqual(
                StatusItemClickRouter.action(isLeftSide: false, timing: state) == .togglePause,
                ManualTimerRules.isClickable(state),
                "the half and the menu item have to agree about \(state)"
            )
        }
    }
}

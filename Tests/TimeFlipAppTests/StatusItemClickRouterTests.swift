@testable import TimeFlipApp
import XCTest

/// Covers `StatusItemClickRouter`: which half of the status item means what.
///
/// One rule at present, tested anyway, for the reason the archived router recorded about itself: the
/// same decisions lived as nested `guard`s inside an `@objc` click handler, and reaching them needed
/// a real status item, a real click and a real window server -- so they were only ever verified by
/// hand. This is the seam that stops that happening again as the rules arrive.
final class StatusItemClickRouterTests: XCTestCase {
    func testTheLeftHalfOpensTheMenu() {
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: true), .showMenu)
    }

    func testTheRightHalfDoesNothingYet() {
        // Inert rather than falling through to the menu: pause will live here, and a right half that
        // quietly did the left half's job would be a merge nobody would notice had happened.
        XCTAssertEqual(StatusItemClickRouter.action(isLeftSide: false), .ignore)
    }
}

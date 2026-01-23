@testable import TimeFlipApp
import XCTest

final class AppIdentifiersTests: XCTestCase {
    func testSubsystemIsNonEmpty() {
        XCTAssertFalse(AppIdentifiers.subsystem.isEmpty)
    }

    func testStatusItemTitleIsHumanReadable() {
        XCTAssertEqual(AppIdentifiers.statusItemTitle, "TimeFlip")
    }
}

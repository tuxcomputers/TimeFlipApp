@testable import FacetApp
import AppKit
import XCTest

/// Covers `DatabaseBadge`: what each environment looks like in the menu bar.
///
/// Worth pinning down rather than eyeballing, because the badge's whole job is to be right in the
/// case nobody looks at -- an ordinary production launch is the one that gets seen daily, and the two
/// that must not be mistaken for it are the ones that hardly ever appear.
final class DatabaseBadgeTests: XCTestCase {
    func testProductionIsUnremarkable() {
        let badge = DatabaseBadge.forEnvironment(.production)

        XCTAssertEqual(badge.text, "PROD")
        XCTAssertEqual(badge.color, .labelColor, "the ordinary text colour, so it reads in either appearance")
        XCTAssertEqual(badge.spokenDescription, "production database")
    }

    func testATestDatabaseIsRed() {
        let badge = DatabaseBadge.forEnvironment(.test)

        XCTAssertEqual(badge.text, "TEST")
        XCTAssertEqual(badge.color, .systemRed)
        XCTAssertEqual(badge.spokenDescription, "test database")
    }

    func testAnUnreadableDatabaseSaysSoRatherThanSayingProduction() {
        let badge = DatabaseBadge.forEnvironment(nil)

        XCTAssertNotEqual(badge.text, "PROD", "claiming production for an unknown database is the one wrong answer")
        XCTAssertEqual(badge.text, "DB?")
        XCTAssertEqual(badge.color, .systemRed)
        XCTAssertEqual(badge.spokenDescription, "database unknown")
    }

    func testTheTwoStatesWorthNoticingDoNotLookLikeTheOrdinaryOne() {
        let ordinary = DatabaseBadge.forEnvironment(.production)
        for badge in [DatabaseBadge.forEnvironment(.test), DatabaseBadge.forEnvironment(nil)] {
            XCTAssertNotEqual(badge.color, ordinary.color)
            XCTAssertNotEqual(badge.text, ordinary.text)
        }
    }
}

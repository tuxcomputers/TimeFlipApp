import XCTest
@testable import TimeFlipApp

final class CategoryNameNormalizationTests: XCTestCase {
    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(ActivityLibrary.normalizeCategoryName("  Meeting  "), "Meeting")
    }

    func testCollapsesInternalRunsOfSpacesToOne() {
        XCTAssertEqual(ActivityLibrary.normalizeCategoryName("Client    work"), "Client work")
    }

    func testCollapsesTabsAndNewlinesToo() {
        XCTAssertEqual(ActivityLibrary.normalizeCategoryName("Client\t\n work"), "Client work")
    }

    func testLeavesAnAlreadyTidyNameAlone() {
        XCTAssertEqual(ActivityLibrary.normalizeCategoryName("Client work"), "Client work")
    }

    func testWhitespaceOnlyBecomesEmptySoSaveStaysDisabled() {
        XCTAssertEqual(ActivityLibrary.normalizeCategoryName("   "), "")
    }

    func testKeepsTicketStylePunctuation() {
        // Normalizing deliberately does not filter characters. The face-name sanitizer that did
        // (and would have made this "ACME123") went with the UserDefaults blob it policed, so the
        // contrast it used to be asserted against is gone; the requirement it protected is not.
        XCTAssertEqual(ActivityLibrary.normalizeCategoryName(" ACME-123 "), "ACME-123")
    }
}

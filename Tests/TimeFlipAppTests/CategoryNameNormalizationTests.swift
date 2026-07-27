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

    func testKeepsPunctuationThatSanitizeActivityNameWouldStrip() {
        // The reason this is not sanitizeActivityName: ticket-style names have to survive intact.
        XCTAssertEqual(ActivityLibrary.normalizeCategoryName(" ACME-123 "), "ACME-123")
        XCTAssertEqual(ActivityLibrary.sanitizeActivityName("ACME-123"), "ACME123")
    }
}

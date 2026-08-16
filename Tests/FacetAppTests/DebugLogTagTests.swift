@testable import FacetApp
import XCTest

/// Covers `DebugLog.Tag`'s padding, which is the one thing about it that can break by adding a case.
///
/// The console prefix is right-padded to the longest tag's width so lines stay aligned however they interleave
/// (see the debug-print rule in `CLAUDE.md`). The width is derived rather than written down, so a new case
/// re-pads every existing tag -- and this is what says so, instead of it being noticed by eye later.
final class DebugLogTagTests: XCTestCase {
    func testEveryTagBracketsToTheSameWidth() {
        let widths = Set(DebugLog.Tag.allCases.map(\.bracketed.count))

        XCTAssertEqual(widths.count, 1, "one width, so columns line up: \(DebugLog.Tag.allCases.map(\.bracketed))")
    }

    func testTheWidthIsTheLongestTagAndNothingWider() {
        let longest = DebugLog.Tag.allCases.map(\.rawValue.count).max() ?? 0

        // Brackets plus the name, so nothing is padded further than it needs to be.
        XCTAssertEqual(DebugLog.Tag.click.bracketed.count, longest + 2)
        XCTAssertEqual(DebugLog.Tag.allCases.first { $0.rawValue.count == longest }?.bracketed.contains(" "), false)
    }

    func testATagReadsAsItsOwnName() {
        // The console prefix and the row's `tag` column are the same value, so there is one list rather than
        // two that can disagree.
        XCTAssertTrue(DebugLog.Tag.history.bracketed.hasPrefix("[history"))
        XCTAssertEqual(DebugLog.Tag.history.rawValue, "history")
    }
}

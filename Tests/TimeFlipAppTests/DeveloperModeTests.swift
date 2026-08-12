@testable import TimeFlipApp
import XCTest

/// Covers the shape of a dev-only debug line, which the root `CLAUDE.md` states as a convention: a
/// zero-padded 24-hour local time, then the tag's name bracketed and padded to a common width so
/// console lines align however they interleave.
///
/// The padding is derived from the longest case rather than written down, so what needs guarding is
/// that adding a case cannot quietly leave the others mismatched.
final class DeveloperModeTests: XCTestCase {
    func testTheDevFlagIsOn() {
        XCTAssertTrue(DeveloperMode.isEnabled)
    }

    func testEveryTagBracketsToTheSameWidth() {
        let widths = Set(DeveloperMode.DebugTag.allCases.map(\.bracketed.count))
        XCTAssertEqual(
            widths.count, 1,
            "tags must pad to one width, so a new case re-pads the rest rather than breaking alignment: "
                + DeveloperMode.DebugTag.allCases.map(\.bracketed).joined(separator: " ")
        )
    }

    func testTheWidthIsTheLongestTagPlusItsBrackets() {
        let longest = DeveloperMode.DebugTag.allCases.map(\.rawValue.count).max() ?? 0
        for tag in DeveloperMode.DebugTag.allCases {
            XCTAssertEqual(tag.bracketed.count, longest + 2, "\(tag.rawValue) should pad to the longest tag")
            XCTAssertTrue(tag.bracketed.hasPrefix("[\(tag.rawValue)"), "the name comes first, padding after")
            XCTAssertTrue(tag.bracketed.hasSuffix("]"))
        }
    }

    func testTheLongestTagIsNotPadded() {
        // The one case that should come out flush, which is what proves the padding is measured rather
        // than a fixed number that happens to be big enough today.
        let longest = DeveloperMode.DebugTag.allCases.max { $0.rawValue.count < $1.rawValue.count }
        XCTAssertEqual(longest?.bracketed, longest.map { "[\($0.rawValue)]" })
    }
}

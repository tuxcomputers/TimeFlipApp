@testable import TimeFlipApp
import XCTest

/// Covers `ReportView.formattedDuration`, the Report tab's figures.
///
/// The format follows "Show seconds in the menu bar" so a span never reads one way in the menu bar
/// and another way here. `MenuBarController.formattedDuration` is the shape being matched.
@MainActor
final class ReportDurationFormatTests: XCTestCase {
    private func formatted(_ seconds: TimeInterval, showingSeconds: Bool = false) -> String {
        ReportView.formattedDuration(seconds, showingSeconds: showingSeconds)
    }

    // MARK: - H:MM

    func testHoursAndMinutes() {
        XCTAssertEqual(formatted(4 * 3_600 + 55 * 60), "4:55")
    }

    func testMinutesKeepTwoDigitsButHoursDoNot() {
        // Matching the menu bar: "1:23", not "01:23".
        XCTAssertEqual(formatted(3_600 + 7 * 60), "1:07")
    }

    func testDoubleDigitHoursAreNotTruncated() {
        XCTAssertEqual(formatted(12 * 3_600 + 23 * 60), "12:23")
    }

    func testHoursAreNeverDropped() {
        // "0:07" rather than "7", which would be ambiguous against the hours in the rows beside it.
        XCTAssertEqual(formatted(7 * 60), "0:07")
    }

    // MARK: - H:MM:SS

    func testSecondsAreShownWhenTheSettingIsOn() {
        XCTAssertEqual(formatted(3 * 3_600 + 54 * 60 + 24, showingSeconds: true), "3:54:24")
    }

    func testSecondsPadToTwoDigits() {
        XCTAssertEqual(formatted(3_600 + 60 + 5, showingSeconds: true), "1:01:05")
    }

    // MARK: - the short entry that prompted this

    func testASubMinuteTotalIsIndistinguishableFromZeroWithoutSeconds() {
        // A real 7-second Break entry read as "0:00" during verification, which is exactly what a
        // category opened and left would read as. Turning seconds on is what tells them apart.
        XCTAssertEqual(formatted(7), "0:00")
        XCTAssertEqual(formatted(7, showingSeconds: true), "0:00:07")
    }

    func testZeroIsStillZeroWithSecondsOn() {
        XCTAssertEqual(formatted(0, showingSeconds: true), "0:00:00")
    }

    // MARK: - rounding

    func testFractionalSecondsRoundRatherThanTruncate() {
        // duration_seconds is REAL, so a total can carry a fraction. 59.6s is nearer a minute than
        // nothing, and truncating would report it as 0:00:59.
        XCTAssertEqual(formatted(59.6, showingSeconds: true), "0:01:00")
        XCTAssertEqual(formatted(59.6), "0:01")
    }
}

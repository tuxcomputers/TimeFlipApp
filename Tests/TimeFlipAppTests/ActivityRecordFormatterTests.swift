@testable import TimeFlipApp
import XCTest

// swiftlint:disable number_separator
final class ActivityRecordFormatterTests: XCTestCase {
    func testISO8601FormatterOmitsFractionalSeconds() {
        let integerDate = Date(timeIntervalSince1970: 0) // baseline check for exact layout
        let integerFormatted = ActivityRecordFormatter.iso8601.string(from: integerDate)
        XCTAssertEqual(integerFormatted, "1970-01-01T00:00:00Z")

        let fractionalDate = Date(timeIntervalSince1970: 0.789) // fractional seconds should be dropped
        let fractionalFormatted = ActivityRecordFormatter.iso8601.string(from: fractionalDate)
        XCTAssertFalse(fractionalFormatted.contains("."))
    }

    func testSheetsTimestampUsesSpaceAndSpecifiedTimezone() throws {
        // Build a date in UTC and render it in a fixed +01:00 timezone.
        var components = DateComponents()
        components.year = 2024
        components.month = 10
        components.day = 29
        components.hour = 15
        components.minute = 29
        components.second = 35
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        let oneHour = try XCTUnwrap(TimeZone(secondsFromGMT: 3_600))
        let formatted = ActivityRecordFormatter.sheetsTimestamp(from: date, timeZone: oneHour)

        // 15:29:35 UTC should render as 16:29:35 in +01:00.
        XCTAssertEqual(formatted, "2024-10-29 16:29:35")
        XCTAssertFalse(formatted.contains("T"))
        XCTAssertFalse(formatted.contains("Z"))
    }
}
// swiftlint:enable number_separator

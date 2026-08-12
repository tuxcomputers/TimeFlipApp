@testable import TimeFlipApp
import XCTest

final class ActivityRecordFormatterTests: XCTestCase {
    func testISO8601FormatterOmitsFractionalSeconds() {
        let integerDate = Date(timeIntervalSince1970: 0) // baseline check for exact layout
        let integerFormatted = ActivityRecordFormatter.iso8601.string(from: integerDate)
        XCTAssertEqual(integerFormatted, "1970-01-01T00:00:00Z")

        let fractionalDate = Date(timeIntervalSince1970: 0.789) // fractional seconds should be dropped
        let fractionalFormatted = ActivityRecordFormatter.iso8601.string(from: fractionalDate)
        XCTAssertFalse(fractionalFormatted.contains("."))
    }
}

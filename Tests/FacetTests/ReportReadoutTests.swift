@testable import FacetCore
import Foundation
import Testing

/// What a picked range comes to, with no window.
///
/// **The boundary is the thing worth pinning.** A report's day is the app's day, not the calendar's, so the figures
/// depend on a setting somebody can change on another tab while the report is on screen -- and the totals and the
/// entries behind them have to be summed over the *same* boundary or a column of figures does not add up to the
/// number above it. That was one private method on the Mac with no test of its own.
@Suite @MainActor
final class ReportReadoutTests {
    private let database: TemporaryDatabase
    private var connection: DatabaseConnection!
    private var settings: SettingStore!
    private var entries: TimeEntryStore!
    private var readout: ReportReadout!

    /// Noon on a Wednesday, so a day's boundary in either direction is unambiguous.
    private let noon = Date(timeIntervalSince1970: 1_786_622_400)

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        connection = database.connection()
        settings = SettingStore(connection: connection)
        entries = TimeEntryStore(connection: connection)
        readout = ReportReadout(entries: entries, settings: settings)
    }

    deinit {
        database.remove()
    }

    @Test func testTheBoundaryComesFromTheTableRatherThanFromMidnight() throws {
        #expect(settings.write("daily_reset_time", field: "hour", 4))
        #expect(settings.write("daily_reset_time", field: "minute", 30))

        let window = readout.bounds(start: noon, end: nil)

        let components = Calendar.current.dateComponents([.hour, .minute], from: window.start)
        #expect(components.hour == 4)
        #expect(components.minute == 30)
    }

    @Test func testOneDayRunsFromOneResetToTheNext() {
        let window = readout.bounds(start: noon, end: nil)

        // A one-day report shows exactly what the menu bar showed on that day, which is what makes the app's day the
        // right unit rather than the calendar's.
        #expect(window.end.timeIntervalSince(window.start) == 24 * 60 * 60)
    }

    @Test func testAChangedResetMovesTheAnswerWithNothingHavingToBeTold() throws {
        let before = readout.bounds(start: noon, end: nil).start
        #expect(settings.write("daily_reset_time", field: "hour", 6))

        let after = readout.bounds(start: noon, end: nil).start

        // Read at the point of use, so the App tab changing the row while a report is on screen is simply what the
        // next read finds.
        #expect(after != before)
    }

    @Test func testTheEntriesBehindATotalAreSummedOverTheSameBoundaryAsTheTotal() throws {
        #expect(settings.write("daily_reset_time", field: "hour", 4))

        let forTotals = readout.bounds(start: noon, end: nil)
        let forEntries = readout.bounds(start: noon, end: nil)

        // One place answers both, which is what stops a column of figures disagreeing with the number above it.
        #expect(forTotals == forEntries)
    }

    @Test func testSecondsAreASettingReadNowAndDefaultToBeingShown() throws {
        #expect(readout.showsSeconds, "a report without seconds is a figure that looks rounded")

        #expect(settings.write("display_seconds", field: "enabled", false))

        #expect(!readout.showsSeconds)
    }

    @Test func testARangeWithNothingRecordedInItAnswersNoCategoriesRatherThanZeroes() {
        #expect(readout.totals(start: noon, end: nil).isEmpty)
    }
}

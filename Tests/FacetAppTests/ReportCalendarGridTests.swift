@testable import FacetApp
import XCTest

/// Covers the month arithmetic behind the Report tab's calendars.
///
/// Every test pins its own `Calendar`, never the machine's: where a month's first day sits in the week depends on the
/// locale's first weekday, and a suite that inherited the machine's would pass or fail depending on who ran it.
final class ReportCalendarGridTests: XCTestCase {
    /// A Monday-first calendar in UTC, which is what en_GB gives.
    private var mondayFirst: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private var sundayFirst: Calendar {
        var calendar = mondayFirst
        calendar.firstWeekday = 1
        return calendar
    }

    private func day(_ text: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    private func text(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - the grid

    func testTheGridIsAlwaysSixWeeks() {
        let calendar = mondayFirst
        // A month needs five or six depending on where it starts, and a grid that changed height between months would
        // move everything under it as you page.
        for month in ["2026-02-01", "2026-08-01", "2026-05-01"] {
            let days = ReportCalendarGrid.days(forMonthContaining: day(month, calendar: calendar), calendar: calendar)
            XCTAssertEqual(days.count, 42, month)
        }
    }

    func testTheGridStartsOnTheLocalesFirstWeekday() {
        // 1 August 2026 is a Saturday. Monday-first, the grid opens on Monday 27 July.
        let monday = mondayFirst
        let days = ReportCalendarGrid.days(forMonthContaining: day("2026-08-15", calendar: monday), calendar: monday)
        XCTAssertEqual(text(days[0], calendar: monday), "2026-07-27")

        // Sunday-first, it opens a day earlier.
        let sunday = sundayFirst
        let other = ReportCalendarGrid.days(forMonthContaining: day("2026-08-15", calendar: sunday), calendar: sunday)
        XCTAssertEqual(text(other[0], calendar: sunday), "2026-07-26")
    }

    func testThePaddingDaysAreRealDatesRatherThanBlanks() {
        // What lets the range emphasis run across a month boundary instead of stopping at the edge of the grid, and
        // gives a screen reader something to read for a padding cell.
        let calendar = mondayFirst
        let days = ReportCalendarGrid.days(forMonthContaining: day("2026-08-15", calendar: calendar), calendar: calendar)
        XCTAssertEqual(text(days[0], calendar: calendar), "2026-07-27")
        XCTAssertEqual(text(days[41], calendar: calendar), "2026-09-06")
        XCTAssertEqual(
            Set(days).count, 42,
            "every cell is a different day: a repeat would mean a daylight-saving step landed twice"
        )
    }

    func testTheGridCrossesADaylightSavingChangeWithoutRepeatingADay() {
        // The clocks go forward in the UK on 29 March 2026. Adding days through `Calendar` is what keeps each cell on
        // its own date; adding 86,400 seconds would not.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        let days = ReportCalendarGrid.days(forMonthContaining: day("2026-03-15", calendar: calendar), calendar: calendar)
        XCTAssertEqual(Set(days.map { text($0, calendar: calendar) }).count, 42)
    }

    // MARK: - the weekday headings

    func testTheHeadingsStartAtTheLocalesFirstWeekdayAndAreTwoLetters() {
        // `shortWeekdaySymbols` is Sunday-first whatever the calendar's own first weekday, so it has to be rotated to
        // match the columns the grid draws. Cut to two characters, which is what the system calendar shows: the
        // alternatives were measured and both worse (the ambiguous S/M/T/W/T/F/S, and a ragged mix in en_GB).
        let symbols = ReportCalendarGrid.weekdaySymbols(calendar: mondayFirst, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(symbols, ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"])

        let sunday = ReportCalendarGrid.weekdaySymbols(calendar: sundayFirst, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(sunday, ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"])
    }

    // MARK: - paging

    func testAMonthOutsideTheRangeCannotBeReached() throws {
        // What stops the calendar paging into a month where everything is greyed out.
        let calendar = mondayFirst
        let allowed = day("2026-06-10", calendar: calendar) ... day("2026-08-14", calendar: calendar)
        let august = day("2026-08-15", calendar: calendar)

        XCTAssertNil(
            ReportCalendarGrid.month(movedFrom: august, by: 1, within: allowed, calendar: calendar),
            "September holds no selectable day"
        )
        let july = ReportCalendarGrid.month(movedFrom: august, by: -1, within: allowed, calendar: calendar)
        XCTAssertEqual(text(try XCTUnwrap(july), calendar: calendar), "2026-07-01")
    }

    func testTheMonthHoldingTheLastSelectableDayIsReachable() throws {
        // Whole months are compared rather than instants: most of August sits beyond the 14th, and August is still a
        // month somebody can page to.
        let calendar = mondayFirst
        let allowed = day("2026-06-10", calendar: calendar) ... day("2026-08-14", calendar: calendar)
        let july = day("2026-07-05", calendar: calendar)

        let moved = ReportCalendarGrid.month(movedFrom: july, by: 1, within: allowed, calendar: calendar)
        XCTAssertEqual(text(try XCTUnwrap(moved), calendar: calendar), "2026-08-01")
    }

    func testAMonthTheBoundsHaveMovedOutOfReachIsPulledBackIn() {
        // The To calendar's lower bound follows the start date, so a calendar showing June when the start moves to
        // August must not be left displaying a month it can no longer reach.
        let calendar = mondayFirst
        let allowed = day("2026-08-01", calendar: calendar) ... day("2026-08-14", calendar: calendar)

        let pulled = ReportCalendarGrid.displayableMonth(
            for: day("2026-06-15", calendar: calendar),
            within: allowed,
            calendar: calendar
        )
        XCTAssertEqual(text(pulled, calendar: calendar), "2026-08-01")
    }

    // MARK: - comparisons

    func testTwoInstantsOnOneDayAreTheSameDayWhateverTheTime() {
        // What the emphasis and selection comparisons rely on: both sides carry a time of day that has nothing to do
        // with the question.
        let calendar = mondayFirst
        let morning = day("2026-08-14", calendar: calendar)
        let evening = morning.addingTimeInterval(20 * 60 * 60)
        XCTAssertTrue(ReportCalendarGrid.isSameDay(morning, evening, calendar: calendar))
        XCTAssertTrue(ReportCalendarGrid.isSameMonth(morning, day("2026-08-31", calendar: calendar), calendar: calendar))
        XCTAssertFalse(ReportCalendarGrid.isSameMonth(morning, day("2026-09-01", calendar: calendar), calendar: calendar))
    }
}

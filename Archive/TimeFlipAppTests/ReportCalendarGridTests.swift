@testable import TimeFlipApp
import XCTest

// swiftlint:disable line_length
/// Covers `ReportCalendarGrid`, the arithmetic behind the Report tab's hand-drawn calendars.
///
/// These are the parts that would otherwise only be checkable by looking at a rendered month: where
/// a month's first day lands in the week, and which months the arrows can still reach. Calendars are
/// pinned per test rather than taken from the machine, so a run in a Sunday-first locale asserts the
/// same things as one in a Monday-first locale.
final class ReportCalendarGridTests: XCTestCase {
    private func makeCalendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// Monday-first, as en_GB.
    private var mondayFirst: Calendar { makeCalendar(firstWeekday: 2) }
    /// Sunday-first, as en_US.
    private var sundayFirst: Calendar { makeCalendar(firstWeekday: 1) }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private func ymd(_ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - the grid

    func testTheGridIsAlwaysSixWholeWeeks() {
        // A fixed height stops the totals underneath shifting as you page between a five-week and a
        // six-week month.
        let calendar = mondayFirst
        for month in 1...12 {
            let days = ReportCalendarGrid.days(forMonthContaining: date(2026, month, 1, calendar: calendar), calendar: calendar)
            XCTAssertEqual(days.count, 42, "month \(month) should still be a 6x7 grid")
        }
    }

    func testTheGridStartsOnTheLocalesFirstWeekday() {
        // 1 Aug 2026 is a Saturday, so a Monday-first grid opens on Mon 27 Jul.
        let calendar = mondayFirst
        let days = ReportCalendarGrid.days(forMonthContaining: date(2026, 8, 15, calendar: calendar), calendar: calendar)

        XCTAssertEqual(ymd(days[0], calendar), "2026-07-27")
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 2, "first cell is a Monday")
    }

    func testASundayFirstLocaleGetsADifferentGrid() {
        // The same month, opening on Sun 26 Jul instead -- the locale's week start is honoured
        // rather than a Monday being baked in.
        let calendar = sundayFirst
        let days = ReportCalendarGrid.days(forMonthContaining: date(2026, 8, 15, calendar: calendar), calendar: calendar)

        XCTAssertEqual(ymd(days[0], calendar), "2026-07-26")
        XCTAssertEqual(calendar.component(.weekday, from: days[0]), 1, "first cell is a Sunday")
    }

    func testTheGridRunsContinuouslyWithNoGaps() {
        // Padding cells are real adjacent-month dates, not blanks, so an emphasised range crossing a
        // month boundary stays unbroken and every cell has a date for VoiceOver to read.
        let calendar = mondayFirst
        let days = ReportCalendarGrid.days(forMonthContaining: date(2026, 8, 15, calendar: calendar), calendar: calendar)

        for (earlier, later) in zip(days, days.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: earlier, to: later).day
            XCTAssertEqual(gap, 1, "\(ymd(earlier, calendar)) -> \(ymd(later, calendar)) should be consecutive")
        }
    }

    func testAMonthStartingOnTheFirstWeekdayIsNotPaddedByAWholeWeek() {
        // June 2026 starts on a Monday. A Monday-first grid must open on the 1st itself, not back up
        // seven days -- the classic off-by-a-week in this arithmetic.
        let calendar = mondayFirst
        let days = ReportCalendarGrid.days(forMonthContaining: date(2026, 6, 10, calendar: calendar), calendar: calendar)

        XCTAssertEqual(ymd(days[0], calendar), "2026-06-01")
    }

    // MARK: - month navigation

    func testTheForwardArrowStopsAtTheMonthHoldingTheLastSelectableDay() {
        // The whole reason this calendar is hand-drawn: the system one pages into months where
        // nothing can be picked.
        let calendar = mondayFirst
        let allowed = date(2026, 1, 1, calendar: calendar)...date(2026, 8, 8, calendar: calendar)

        let forward = ReportCalendarGrid.month(movedFrom: date(2026, 8, 8, calendar: calendar), by: 1, within: allowed, calendar: calendar)

        XCTAssertNil(forward, "September holds no selectable day, so it cannot be reached")
    }

    func testTheMonthHoldingTheBoundIsItselfReachable() {
        // August is reachable from July even though most of August lies beyond the 8th -- the test
        // is by month, not by instant.
        let calendar = mondayFirst
        let allowed = date(2026, 1, 1, calendar: calendar)...date(2026, 8, 8, calendar: calendar)

        let forward = ReportCalendarGrid.month(movedFrom: date(2026, 7, 15, calendar: calendar), by: 1, within: allowed, calendar: calendar)

        XCTAssertEqual(forward.map { ymd($0, calendar) }, "2026-08-01")
    }

    func testTheBackArrowStopsAtTheMonthHoldingTheEarliestSelectableDay() {
        let calendar = mondayFirst
        let allowed = date(2026, 8, 5, calendar: calendar)...date(2026, 8, 8, calendar: calendar)

        let back = ReportCalendarGrid.month(movedFrom: date(2026, 8, 5, calendar: calendar), by: -1, within: allowed, calendar: calendar)

        XCTAssertNil(back, "July holds no selectable day either")
    }

    func testNavigationCrossesAYearBoundary() {
        let calendar = mondayFirst
        let allowed = date(2025, 1, 1, calendar: calendar)...date(2026, 8, 8, calendar: calendar)

        let back = ReportCalendarGrid.month(movedFrom: date(2026, 1, 15, calendar: calendar), by: -1, within: allowed, calendar: calendar)

        XCTAssertEqual(back.map { ymd($0, calendar) }, "2025-12-01")
    }

    // MARK: - keeping the displayed month reachable

    func testADisplayedMonthBeyondTheBoundsIsPulledBackInside() {
        // The To calendar's lower bound follows the start date, so it can move out from under a
        // month already on show. That month must not be left displayed and unreachable.
        let calendar = mondayFirst
        let allowed = date(2026, 8, 5, calendar: calendar)...date(2026, 8, 8, calendar: calendar)

        let shown = ReportCalendarGrid.displayableMonth(for: date(2026, 3, 2, calendar: calendar), within: allowed, calendar: calendar)

        XCTAssertEqual(ymd(shown, calendar), "2026-08-01")
    }

    func testADisplayedMonthAfterTheBoundsIsPulledBackToTheLatestMonth() {
        // The symmetric case to the one above: a selection past the upper bound (e.g. the From
        // calendar left displaying a future month once "today" moves backwards under it) must clamp
        // down to the latest reachable month, not just the earliest.
        let calendar = mondayFirst
        let allowed = date(2026, 8, 5, calendar: calendar)...date(2026, 8, 8, calendar: calendar)

        let shown = ReportCalendarGrid.displayableMonth(for: date(2026, 12, 25, calendar: calendar), within: allowed, calendar: calendar)

        XCTAssertEqual(ymd(shown, calendar), "2026-08-01")
    }

    func testAnInRangeSelectionKeepsItsOwnMonth() {
        let calendar = mondayFirst
        let allowed = date(2026, 1, 1, calendar: calendar)...date(2026, 8, 8, calendar: calendar)

        let shown = ReportCalendarGrid.displayableMonth(for: date(2026, 4, 17, calendar: calendar), within: allowed, calendar: calendar)

        XCTAssertEqual(ymd(shown, calendar), "2026-04-01")
    }

    // MARK: - headings

    func testWeekdayHeadingsAreOrderedFromTheLocalesFirstWeekday() {
        let mondaySymbols = ReportCalendarGrid.weekdaySymbols(calendar: mondayFirst, locale: Locale(identifier: "en_GB"))
        let sundaySymbols = ReportCalendarGrid.weekdaySymbols(calendar: sundayFirst, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(mondaySymbols.count, 7)
        XCTAssertEqual(mondaySymbols.first, "Mo")
        XCTAssertEqual(sundaySymbols.first, "Su")
        XCTAssertEqual(Set(mondaySymbols), Set(sundaySymbols), "same seven days, rotated")
    }
}
// swiftlint:enable line_length

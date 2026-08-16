@testable import TimeFlipApp
import XCTest

/// Covers `ReportDateRange`, which turns the Report tab's two pickers into the instant range its
/// query runs over. Fixed to a UTC calendar so the boundaries are arithmetic rather than whatever
/// zone the test machine sits in.
final class ReportDateRangeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - one day

    func testAStartWithNoEndCoversThatSingleDay() {
        // The common case, and the reason the end is optional: pick a day, get that day.
        let bounds = ReportDateRange.bounds(
            start: date(2026, 8, 8),
            end: nil,
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )

        XCTAssertEqual(bounds.start, date(2026, 8, 8, 3, 0))
        XCTAssertEqual(bounds.end, date(2026, 8, 9, 3, 0), "the day runs to the next reset, not to midnight")
    }

    func testTheDayStartsAtTheConfiguredResetTimeNotMidnight() {
        // A single-day report has to match what the menu bar showed that day, and the menu bar's
        // day is the daily_reset_time one.
        let bounds = ReportDateRange.bounds(
            start: date(2026, 8, 8),
            end: nil,
            resetHour: 5,
            resetMinute: 30,
            calendar: calendar
        )

        XCTAssertEqual(bounds.start, date(2026, 8, 8, 5, 30))
        XCTAssertEqual(bounds.end, date(2026, 8, 9, 5, 30))
    }

    func testTheTimeOfDayOnThePickedDateIsIgnored() {
        // The pickers show a date but carry whatever time `Date()` seeded them with; that must not
        // shift the window.
        let earlyInTheDay = ReportDateRange.bounds(
            start: date(2026, 8, 8, 0, 5),
            end: nil,
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )
        let lateInTheDay = ReportDateRange.bounds(
            start: date(2026, 8, 8, 23, 55),
            end: nil,
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )

        XCTAssertEqual(earlyInTheDay.start, lateInTheDay.start)
        XCTAssertEqual(earlyInTheDay.end, lateInTheDay.end)
    }

    // MARK: - a range

    func testAnEndDateExtendsTheRangeThroughThatWholeDay() {
        let bounds = ReportDateRange.bounds(
            start: date(2026, 8, 1),
            end: date(2026, 8, 8),
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )

        XCTAssertEqual(bounds.start, date(2026, 8, 1, 3, 0))
        XCTAssertEqual(
            bounds.end, date(2026, 8, 9, 3, 0),
            "the last day is included in full, so the range ends at the reset after it"
        )
    }

    func testAnEndOnTheSameDayAsTheStartIsStillOneWholeDay() {
        let bounds = ReportDateRange.bounds(
            start: date(2026, 8, 8),
            end: date(2026, 8, 8),
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )

        XCTAssertEqual(bounds.start, date(2026, 8, 8, 3, 0))
        XCTAssertEqual(bounds.end, date(2026, 8, 9, 3, 0))
    }

    func testAnEndBeforeTheStartFallsBackToTheSingleStartDay() {
        // Unreachable through the UI (the end picker's lower bound is the start day), but an
        // inverted range would report nothing at all, whereas the start alone already means one day.
        let bounds = ReportDateRange.bounds(
            start: date(2026, 8, 8),
            end: date(2026, 8, 1),
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )

        XCTAssertEqual(bounds.start, date(2026, 8, 8, 3, 0))
        XCTAssertEqual(bounds.end, date(2026, 8, 9, 3, 0))
        XCTAssertLessThan(bounds.start, bounds.end, "the range is never inverted")
    }

    // MARK: - the future is not selectable

    func testTodayIsSelectableWhateverTimeOfDayTheBindingCarries() {
        // The bound is the *end* of today, not the start: a day cell carries whatever time the
        // picker's binding holds, so a bound at 00:00 would grey out today itself for an afternoon
        // binding -- the one day most reports want.
        let latest = ReportDateRange.latestSelectableDay(now: date(2026, 8, 8, 14, 30), calendar: calendar)

        XCTAssertGreaterThan(latest, date(2026, 8, 8, 23, 59), "the whole of today is in range")
        XCTAssertLessThan(latest, date(2026, 8, 9, 0, 0), "but tomorrow is not")
    }

    func testTheBoundDoesNotMoveWithTheTimeOfDay() {
        let earlyInTheDay = ReportDateRange.latestSelectableDay(now: date(2026, 8, 8, 0, 1), calendar: calendar)
        let lateInTheDay = ReportDateRange.latestSelectableDay(now: date(2026, 8, 8, 23, 59), calendar: calendar)

        XCTAssertEqual(earlyInTheDay, lateInTheDay, "the last selectable day is a date, not a moving now")
    }

    func testTheBoundLeavesAValidRangeForAStartOnTheSameDay() {
        // What the To picker builds: startOfDay(start) ... latestSelectableDay. A ClosedRange traps
        // when its upper bound is below its lower one, so today-as-start must still form one.
        let now = date(2026, 8, 8, 14, 30)
        let latest = ReportDateRange.latestSelectableDay(now: now, calendar: calendar)
        let earliestEnd = calendar.startOfDay(for: now)

        XCTAssertLessThanOrEqual(earliestEnd, latest, "picking today as the start must not invert the end's range")
    }

    // MARK: - a day boundary crossing daylight saving

    /// The fixed UTC `calendar` above makes every other test's arithmetic deterministic, but it
    /// can't exercise a real DST transition -- the production call site (`ReportView.reload()`)
    /// uses `Calendar.current`, which does observe one. `bounds`' `calendar.date(byAdding: .day,
    /// value: 1, ...)` is Calendar-based day arithmetic, not a fixed `+86400` seconds -- exactly the
    /// distinction that only shows up crossing a transition.
    func testTheDayBoundaryIsCorrectAcrossASpringForwardTransition() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        // 2026's US spring-forward is 2026-03-08 (clocks jump 2am -> 3am), so the app-day starting
        // at the 3am reset on 2026-03-07 is the one that loses an hour to it.
        var startComponents = DateComponents()
        startComponents.year = 2026
        startComponents.month = 3
        startComponents.day = 7
        startComponents.hour = 12
        let start = try XCTUnwrap(eastern.date(from: startComponents))

        let bounds = ReportDateRange.bounds(start: start, end: nil, resetHour: 3, resetMinute: 0, calendar: eastern)

        XCTAssertEqual(
            eastern.dateComponents([.month, .day, .hour], from: bounds.start),
            DateComponents(month: 3, day: 7, hour: 3),
            "the reset hour reads the same on the wall clock regardless of the zone's offset"
        )
        XCTAssertEqual(
            eastern.dateComponents([.month, .day, .hour], from: bounds.end),
            DateComponents(month: 3, day: 8, hour: 3),
            "the reset hour reads the same on the wall clock regardless of the zone's offset"
        )
        XCTAssertEqual(
            bounds.end.timeIntervalSince(bounds.start), 23 * TimeConstants.secondsPerHour,
            "this app-day is genuinely 23 hours long; a fixed +86400s bug would read 24h here"
        )
    }

    // MARK: - dayStart

    func testDayStartPutsTheBoundaryOnThePickedDate() {
        // Unlike DailyCategoryTotals.computeWindowStart, which walks back to the most recent
        // boundary at or before a moment, this names the boundary on the date it is given -- a
        // report of the 8th starts on the 8th even when asked for at 1am.
        let start = ReportDateRange.dayStart(
            of: date(2026, 8, 8, 1, 0),
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )

        XCTAssertEqual(start, date(2026, 8, 8, 3, 0))
    }
}

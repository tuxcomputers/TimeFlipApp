@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the Report tab's calendars and the pane holding the pair: what a day cell draws, what a click reports, and
/// what one calendar does to the other.
///
/// No window and no database. The cells are read out of the view rather than looked at, which is the only way a fill
/// behind a number is checkable at all -- `ReportDayCell.style` is what `draw` reads, so asserting on it is asserting
/// on what is painted.
@MainActor
final class ReportCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func cells(of calendar: ReportCalendar) -> [ReportDayCell] {
        descendants(of: calendar).compactMap { $0 as? ReportDayCell }
    }

    private func cell(_ day: String, in view: ReportCalendar) -> ReportDayCell? {
        cells(of: view).first { $0.accessibilityIdentifier().hasSuffix(day) }
    }

    private func made(
        title: String = "From",
        name: String = "from",
        selection: String = "2026-08-14 09:00",
        allowed: (String, String) = ("2000-01-01 00:00", "2026-08-14 23:59"),
        emphasised: (String, String)? = nil
    ) -> ReportCalendar {
        let selected = at(selection)
        let span = emphasised.map { at($0.0) ... at($0.1) } ?? selected ... selected
        return ReportCalendar(
            title: title,
            name: name,
            selection: selected,
            allowed: at(allowed.0) ... at(allowed.1),
            emphasised: span,
            metrics: ReportCalendarMetrics(cellSize: 30),
            calendar: calendar,
            locale: Locale(identifier: "en_GB")
        )
    }

    // MARK: - the grid

    func testEveryDayOfTheGridIsACellNamedByItsDate() {
        // A script presses a day by date rather than by position, which is what makes a step readable and what stops
        // it addressing the wrong cell when the month it lands on starts on a different weekday.
        let view = made()

        XCTAssertEqual(cells(of: view).count, 42)
        XCTAssertNotNil(cell("2026-08-14", in: view))
        XCTAssertNotNil(cell("2026-07-27", in: view), "the padding days are real dates, and pressable if in range")
    }

    func testADayIsNamedInFullForAScreenReader() {
        // "Friday, 14 August 2026" says which cell this is without the surrounding grid, which a screen reader has no
        // way to convey.
        let view = made()
        XCTAssertEqual(cell("2026-08-14", in: view)?.accessibilityLabel(), "Friday, 14 August 2026")
    }

    func testClickingADayReportsThatDayOutward() {
        // The calendar draws and reports; what a picked day means is the pane's.
        let view = made()
        var picked: [Date] = []
        view.onSelect = { picked.append($0) }

        cell("2026-08-11", in: view)?.performClick(nil)

        XCTAssertEqual(picked, [at("2026-08-11 00:00")])
    }

    // MARK: - what a cell draws

    func testTheSelectedDayIsTheOnlySolidOne() {
        let view = made(selection: "2026-08-14 09:00")
        let selected = cells(of: view).filter(\.style.isSelected)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.accessibilityIdentifier(), "report-from-2026-08-14")
    }

    func testTheWholeSpanIsDrawnBoldAndTintedNotJustItsEnds() {
        // The point of the pair: the selection reads as one range in both calendars rather than as two unrelated
        // highlighted days.
        let view = made(selection: "2026-08-10 09:00", emphasised: ("2026-08-10 00:00", "2026-08-13 00:00"))

        let emphasised = cells(of: view).filter(\.style.isEmphasised).map { $0.accessibilityIdentifier() }
        XCTAssertEqual(emphasised, [
            "report-from-2026-08-10",
            "report-from-2026-08-11",
            "report-from-2026-08-12",
            "report-from-2026-08-13",
        ])
    }

    func testOnlyTheSpansOwnEndsAreRounded() {
        // Not where a *row* ends: the archive tried that and the corners met as a notch running down both edges, so
        // the fill read as a stack of pills rather than one span.
        let view = made(selection: "2026-08-10 09:00", emphasised: ("2026-08-10 00:00", "2026-08-13 00:00"))

        XCTAssertEqual(cell("2026-08-10", in: view)?.style.isRangeStart, true)
        XCTAssertEqual(cell("2026-08-10", in: view)?.style.isRangeEnd, false)
        XCTAssertEqual(cell("2026-08-12", in: view)?.style.isRangeStart, false)
        XCTAssertEqual(cell("2026-08-12", in: view)?.style.isRangeEnd, false)
        XCTAssertEqual(cell("2026-08-13", in: view)?.style.isRangeEnd, true)
    }

    func testADayOutsideTheRangeIsDrawnDimAndRefusesTheClick() {
        // Dimmed and disabled rather than clickable and then rejected: there is no error state for a selection the
        // screen never allowed.
        let view = made(allowed: ("2026-08-10 00:00", "2026-08-14 23:59"))

        let outside = cell("2026-08-09", in: view)
        XCTAssertEqual(outside?.style.isSelectable, false)
        XCTAssertEqual(outside?.isEnabled, false)
        XCTAssertEqual(cell("2026-08-11", in: view)?.isEnabled, true)
    }

    func testADayOnTheBoundIsSelectableWhateverTimeTheBoundCarries() {
        // The bounds are day-granular questions carried on instants that hold a time: a lower bound of 16:00 must not
        // grey out its own day.
        let view = made(selection: "2026-08-14 09:00", allowed: ("2026-08-10 16:00", "2026-08-14 23:59"))
        XCTAssertEqual(cell("2026-08-10", in: view)?.style.isSelectable, true)
    }

    func testADayFromTheMonthEitherSideIsMarkedAsSuch() {
        // Real, just not the month being read, so it draws in a lighter colour than the days around it.
        let view = made(selection: "2026-08-14 09:00")
        XCTAssertEqual(cell("2026-07-27", in: view)?.style.isInMonth, false)
        XCTAssertEqual(cell("2026-08-14", in: view)?.style.isInMonth, true)
    }

    // MARK: - paging

    func testTheMonthArrowStopsAtTheLastMonthHoldingASelectableDay() throws {
        // The whole reason these are drawn by hand: a date bound governs which days can be *selected*, not which
        // month is *displayed*, so a stock picker pages into a fully greyed-out month.
        let view = made(selection: "2026-08-14 09:00", allowed: ("2026-07-01 00:00", "2026-08-14 23:59"))

        let next = try XCTUnwrap(descendants(of: view).first { $0.accessibilityIdentifier() == "report-from-next-month" } as? NSButton)
        let previous = try XCTUnwrap(descendants(of: view).first { $0.accessibilityIdentifier() == "report-from-previous-month" } as? NSButton)
        XCTAssertFalse(next.isEnabled, "September holds no selectable day")
        XCTAssertTrue(previous.isEnabled)

        previous.performClick(nil)
        XCTAssertNotNil(cell("2026-07-15", in: view), "and the grid moved to it")
        XCTAssertFalse(previous.isEnabled, "which is now the far end")
    }

    func testPagingSaysWhichMonthItLandedOn() {
        let view = made(selection: "2026-08-14 09:00", allowed: ("2026-07-01 00:00", "2026-08-14 23:59"))
        var shown: [Date] = []
        view.onShowMonth = { shown.append($0) }

        (descendants(of: view).first { $0.accessibilityIdentifier() == "report-from-previous-month" } as? NSButton)?
            .performClick(nil)

        XCTAssertEqual(shown, [at("2026-07-01 00:00")])
    }

    func testAMonthPagedToIsAbandonedWhenTheBoundsMoveOutOfReach() {
        // The To calendar's lower bound follows the start date, so a calendar showing July when the start moves to
        // August must not be left drawing a month it can no longer reach.
        let view = made(name: "to", selection: "2026-08-14 09:00", allowed: ("2026-07-01 00:00", "2026-08-14 23:59"))
        (descendants(of: view).first { $0.accessibilityIdentifier() == "report-to-previous-month" } as? NSButton)?
            .performClick(nil)
        XCTAssertNotNil(cell("2026-07-15", in: view))

        view.show(
            selection: at("2026-08-14 09:00"),
            allowed: at("2026-08-01 00:00") ... at("2026-08-14 23:59"),
            emphasised: at("2026-08-14 09:00") ... at("2026-08-14 09:00"),
            metrics: ReportCalendarMetrics(cellSize: 30)
        )

        XCTAssertNil(cell("2026-07-15", in: view), "pulled back to a month it can reach")
        XCTAssertNotNil(cell("2026-08-15", in: view))
    }
}

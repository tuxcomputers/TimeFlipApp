@testable import FacetApp
import AppKit
import XCTest

/// Covers the Report tab itself: the pair of calendars, what one does to the other, and how they are sized.
@MainActor
final class ReportPaneTests: XCTestCase {
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

    /// A pane whose "today" is pinned, so what it draws does not depend on the day the suite is run.
    private func pane(now: String = "2026-08-14 09:00") -> ReportPane {
        ReportPane(now: { self.at(now) }, calendar: calendar, locale: Locale(identifier: "en_GB"))
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func cell(_ day: String, in view: ReportCalendar) -> ReportDayCell? {
        descendants(of: view).compactMap { $0 as? ReportDayCell }.first {
            $0.accessibilityIdentifier().hasSuffix(day)
        }
    }

    // MARK: - what it opens as

    func testItOpensOnTodayWithNoEndSet() {
        // The report somebody opening this tab is most likely to want, and the only one they can ask for in no clicks
        // at all.
        let pane = pane()

        XCTAssertEqual(pane.start, at("2026-08-14 09:00"))
        XCTAssertNil(pane.end)
    }

    func testTheEndCalendarSaysWhatAnUnsetEndMeans() {
        // Rather than looking like a second date somebody forgot to choose.
        let subtitles = descendants(of: pane().toCalendar)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(subtitles.contains(ReportRangeRules.unsetEndSubtitle), "\(subtitles)")
        XCTAssertFalse(
            descendants(of: pane().fromCalendar)
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains(ReportRangeRules.unsetEndSubtitle),
            "the From calendar has nothing to say about itself"
        )
    }

    func testBothCalendarsRefuseTomorrow() {
        // A time recorder, not a time planner.
        let pane = pane()
        XCTAssertEqual(cell("2026-08-15", in: pane.fromCalendar)?.isEnabled, false)
        XCTAssertEqual(cell("2026-08-15", in: pane.toCalendar)?.isEnabled, false)
        XCTAssertEqual(cell("2026-08-14", in: pane.fromCalendar)?.isEnabled, true)
    }

    // MARK: - picking

    func testPickingAStartMovesTheEndCalendarsFloorToIt() {
        // The bound is what makes an inverted range unreachable rather than rejected.
        let pane = pane()

        cell("2026-08-10", in: pane.fromCalendar)?.performClick(nil)

        XCTAssertEqual(pane.start, at("2026-08-10 00:00"))
        XCTAssertEqual(cell("2026-08-09", in: pane.toCalendar)?.isEnabled, false)
        XCTAssertEqual(cell("2026-08-10", in: pane.toCalendar)?.isEnabled, true)
    }

    func testPickingAnEndDrawsTheSpanBoldInBothCalendars() {
        // The whole reason the span is passed to each of them rather than to the one owning that end of it.
        let pane = pane()
        cell("2026-08-10", in: pane.fromCalendar)?.performClick(nil)

        cell("2026-08-13", in: pane.toCalendar)?.performClick(nil)

        XCTAssertEqual(pane.end, at("2026-08-13 00:00"))
        for calendar in [pane.fromCalendar!, pane.toCalendar!] {
            XCTAssertEqual(cell("2026-08-11", in: calendar)?.style.isEmphasised, true, calendar.title)
            XCTAssertEqual(cell("2026-08-14", in: calendar)?.style.isEmphasised, false, calendar.title)
        }
    }

    func testAStartMovedPastTheEndCarriesItAlong() {
        let pane = pane()
        cell("2026-08-05", in: pane.fromCalendar)?.performClick(nil)
        cell("2026-08-07", in: pane.toCalendar)?.performClick(nil)

        cell("2026-08-12", in: pane.fromCalendar)?.performClick(nil)

        XCTAssertEqual(pane.end, at("2026-08-12 00:00"), "rather than being stranded behind the start")
    }

    func testAChangedRangeIsReportedOutward() {
        // Nothing consumes the range yet; the window writes down what was picked, so a step driving the app can see
        // the click land.
        let pane = pane()
        var reported: [(Date, Date?)] = []
        pane.onRangeChange = { reported.append(($0, $1)) }

        cell("2026-08-10", in: pane.fromCalendar)?.performClick(nil)
        cell("2026-08-12", in: pane.toCalendar)?.performClick(nil)

        XCTAssertEqual(reported.map(\.0), [at("2026-08-10 00:00"), at("2026-08-10 00:00")])
        XCTAssertEqual(reported.map(\.1), [nil, at("2026-08-12 00:00")])
    }

    // MARK: - layout

    func testTheCalendarsShareTheTabAndSpanItsWidth() {
        // The rule in CLAUDE.md, on this tab: the content is inset by the tab's own padding and nothing more. The pair
        // is what spans it, half each, rather than each box sizing to the grid inside it -- the cell size is rounded
        // down to fit, so grid-width boxes would stop short of the right-hand edge.
        let pane = pane()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
        pane.autoresizingMask = [.width, .height]
        pane.frame = content.bounds
        content.addSubview(pane)
        content.layoutSubtreeIfNeeded()

        let from = content.convert(pane.fromCalendar.bounds, from: pane.fromCalendar)
        let to = content.convert(pane.toCalendar.bounds, from: pane.toCalendar)
        XCTAssertEqual(from.minX, ReportPane.Layout.padding, accuracy: 0.5)
        XCTAssertEqual(to.maxX, 640 - ReportPane.Layout.padding, accuracy: 0.5)
        XCTAssertEqual(from.width, to.width, accuracy: 0.5, "half each")
        XCTAssertEqual(to.minX - from.maxX, ReportPane.Layout.calendarSpacing, accuracy: 0.5)
    }

    func testTheCellsAreResizedWithTheWindow() {
        // Every size inside a calendar comes from the cell, and the cell comes from the width this tab is given: a
        // resize that left 17pt digits in a 28pt cell is what deriving them all from one number prevents.
        let pane = pane()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
        pane.autoresizingMask = [.width, .height]
        pane.frame = content.bounds
        content.addSubview(pane)
        content.layoutSubtreeIfNeeded()
        let wide = cell("2026-08-14", in: pane.fromCalendar)?.frame.width

        content.frame = NSRect(x: 0, y: 0, width: 460, height: 500)
        content.layoutSubtreeIfNeeded()
        let narrow = cell("2026-08-14", in: pane.fromCalendar)?.frame.width

        XCTAssertEqual(wide, ReportCalendarMetrics.fitting(tabWidth: 640).cellSize)
        XCTAssertEqual(narrow, ReportCalendarMetrics.fitting(tabWidth: 460).cellSize)
        XCTAssertLessThan(try XCTUnwrap(narrow), try XCTUnwrap(wide))
    }

    // MARK: - the clock moving under it

    func testARefreshTakesTodayFromTheClockRatherThanFromWhenTheTabWasBuilt() {
        // A Settings window can be left open across midnight. Nothing here is read from the table, but today moves,
        // and today is what both calendars are bounded by.
        var now = at("2026-08-14 23:00")
        let pane = ReportPane(now: { now }, calendar: calendar, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(cell("2026-08-15", in: pane.fromCalendar)?.isEnabled, false)

        now = at("2026-08-15 00:30")
        pane.refresh()

        XCTAssertEqual(cell("2026-08-15", in: pane.fromCalendar)?.isEnabled, true)
    }
}

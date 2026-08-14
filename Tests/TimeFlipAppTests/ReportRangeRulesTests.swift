@testable import TimeFlipApp
import XCTest

/// Covers what the Report tab's two calendars may offer each other.
///
/// The point of these is that an inverted range is **unreachable**, not rejected: the To calendar cannot go before
/// the start, so there is no error state for one anywhere in the tab.
final class ReportRangeRulesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
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

    // MARK: - how far forward either calendar goes

    func testBothCalendarsStopAtTheEndOfToday() {
        // A time recorder, not a time planner: a future date could only ever answer "nothing tracked", which is
        // indistinguishable from a real day on which nothing was.
        //
        // The *end* of today rather than the start of it, which is the part that matters: a day cell carries whatever
        // time the selection holds, so a bound at 00:00 would grey out today itself for an afternoon selection.
        let latest = ReportRangeRules.latestSelectableDay(now: at("2026-08-14 09:30"), calendar: calendar)

        XCTAssertEqual(latest, at("2026-08-14 23:59").addingTimeInterval(59))
        XCTAssertTrue(ReportRangeRules.allowedStarts(latest: latest).contains(at("2026-08-14 15:00")))
        XCTAssertFalse(ReportRangeRules.allowedStarts(latest: latest).contains(at("2026-08-15 00:00")))
    }

    func testTheStartCalendarHasNoFloor() {
        // History goes back as far as it goes back.
        let latest = ReportRangeRules.latestSelectableDay(now: at("2026-08-14 09:30"), calendar: calendar)
        XCTAssertTrue(ReportRangeRules.allowedStarts(latest: latest).contains(at("2019-01-01 00:00")))
    }

    // MARK: - what the end calendar may offer

    func testTheEndCannotReachADayBeforeTheStart() {
        let latest = ReportRangeRules.latestSelectableDay(now: at("2026-08-14 09:30"), calendar: calendar)
        let allowed = ReportRangeRules.allowedEnds(start: at("2026-08-10 16:00"), latest: latest, calendar: calendar)

        XCTAssertFalse(allowed.contains(at("2026-08-09 23:00")))
        XCTAssertTrue(
            allowed.contains(at("2026-08-10 00:30")),
            "the start's own day is offered from its beginning, whatever time the start itself carries"
        )
        XCTAssertTrue(allowed.contains(at("2026-08-14 12:00")))
    }

    func testAStartFromTheFutureDoesNotInvertTheEndsRange() {
        // Not a case the screen can produce -- its own bound stops it -- but a `ClosedRange` whose upper bound sits
        // under its lower one traps at runtime, so a start arriving from a clock that moved backwards would crash the
        // tab rather than draw oddly.
        let latest = ReportRangeRules.latestSelectableDay(now: at("2026-08-14 09:30"), calendar: calendar)
        let allowed = ReportRangeRules.allowedEnds(start: at("2027-01-01 00:00"), latest: latest, calendar: calendar)

        XCTAssertLessThanOrEqual(allowed.lowerBound, allowed.upperBound)
        XCTAssertEqual(allowed.lowerBound, latest)
    }

    // MARK: - the span both of them draw

    func testTheSpanIsTheSelectedDayAloneWhileTheEndIsUnset() {
        // An unset end is not a missing value: it is "report this one day", said in one click.
        let span = ReportRangeRules.emphasised(start: at("2026-08-10 16:00"), end: nil)
        XCTAssertEqual(span.lowerBound, at("2026-08-10 16:00"))
        XCTAssertEqual(span.upperBound, at("2026-08-10 16:00"))
    }

    func testTheSpanRunsFromTheEarlierEndToTheLaterOne() {
        // Ordered here rather than trusted from the caller: this is passed to *both* calendars, and a range built the
        // wrong way round would trap.
        let span = ReportRangeRules.emphasised(start: at("2026-08-12 09:00"), end: at("2026-08-10 09:00"))
        XCTAssertEqual(span.lowerBound, at("2026-08-10 09:00"))
        XCTAssertEqual(span.upperBound, at("2026-08-12 09:00"))
    }

    // MARK: - what one calendar does to the other

    func testAStartMovingPastTheEndCarriesItAlong() {
        // The end calendar's bound stops a *new* end landing before the start; this is the start moving forward under
        // an end already chosen, which would otherwise strand it behind.
        let carried = ReportRangeRules.endCarriedForward(start: at("2026-08-20 00:00"), end: at("2026-08-12 00:00"))
        XCTAssertEqual(carried, at("2026-08-20 00:00"))
    }

    func testAStartMovingBackLeavesTheEndWhereItIs() {
        let kept = ReportRangeRules.endCarriedForward(start: at("2026-08-01 00:00"), end: at("2026-08-12 00:00"))
        XCTAssertEqual(kept, at("2026-08-12 00:00"))
    }

    func testAnEndThatWasNeverSetStaysUnset() {
        // Silently turning a one-day report into a range because the start moved would be the screen changing the
        // question.
        XCTAssertNil(ReportRangeRules.endCarriedForward(start: at("2026-08-20 00:00"), end: nil))
    }

    func testAPickedEndIsNeverBeforeTheStart() {
        let chosen = ReportRangeRules.endChosen(at("2026-08-01 00:00"), start: at("2026-08-10 00:00"))
        XCTAssertEqual(chosen, at("2026-08-10 00:00"))
    }
}

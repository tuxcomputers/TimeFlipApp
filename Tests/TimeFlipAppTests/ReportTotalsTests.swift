@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers what a picked range comes to: the boundary it is measured against, the read that sums it, and the list that
/// draws the answer.
///
/// Against a real database, because the sum is a statement rather than a decision: what is being asserted is that the
/// clipping and the grouping in that SQL do what the range means.
@MainActor
final class ReportTotalsTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var connection: DatabaseConnection!
    private var entries: TimeEntryStore!
    private var categories: CategoryStore!

    /// UTC, so an epoch in a statement and a wall-clock hour in a rule are the same instant whoever runs this.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        connection = database.connection()
        entries = TimeEntryStore(connection: connection)
        categories = CategoryStore(connection: connection)
    }

    override func tearDown() {
        entries = nil
        categories = nil
        connection = nil
        database.remove()
        super.tearDown()
    }

    private func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private var written = 0

    /// An entry of `duration` seconds beginning at `start`, filed under `category`.
    ///
    /// Written straight in, both rows, so a test can choose the instant and the length exactly. `start_epoch` is where
    /// a stretch sits in time -- `started_at` is local text and nothing compares it -- so that is what these set.
    private func entry(_ category: String, start: String, duration: Double) throws {
        written += 1
        let categoryID = try XCTUnwrap(categories.matching(name: category).first?.id)
        let epoch = Int(at(start).timeIntervalSince1970)
        XCTAssertTrue(database.execute(
            """
            INSERT INTO device_event (
                event_number, event_type_id, device_face, start_time, timezone_id,
                start_epoch, duration_seconds, paused, finalised, processed
            ) VALUES (
                \(epoch + written), 1, 8, '\(start)', 0, \(epoch), \(duration), 0, 1, 1
            );
            INSERT INTO time_entry (device_event_id, category_id, started_at, ended_at, duration_seconds)
            VALUES (
                (SELECT MAX(device_event_id) FROM device_event), \(categoryID), '\(start)', '\(start)', \(duration)
            );
            """
        ))
    }

    /// The bounds the app uses for a picked range, at the seeded 3AM reset.
    private func bounds(_ start: String, _ end: String?) -> (start: Date, end: Date) {
        ReportRangeRules.bounds(
            start: at(start),
            end: end.map(at),
            resetHour: 3,
            resetMinute: 0,
            calendar: calendar
        )
    }

    // MARK: - the boundary

    func testARangeRunsFromTheResetOnTheFirstDayToTheResetAfterTheLast() {
        // The user's own example: 5 August to 7 August is the 5th at 3AM to the 8th at 3AM.
        let range = bounds("2026-08-05 00:00", "2026-08-07 00:00")

        XCTAssertEqual(range.start, at("2026-08-05 03:00"))
        XCTAssertEqual(range.end, at("2026-08-08 03:00"))
    }

    func testOneDayIsThatDaysOwnTwentyFourHours() {
        // Which is what makes a one-day report the same figure the menu bar showed on that day.
        let range = bounds("2026-08-05 00:00", nil)

        XCTAssertEqual(range.start, at("2026-08-05 03:00"))
        XCTAssertEqual(range.end, at("2026-08-06 03:00"))
    }

    func testTheDayIsTheOneNamedByTheCellRatherThanTheOneContainingIt() {
        // The part that is easy to get wrong: a calendar cell carries midnight, which with a 3AM reset sits inside the
        // *previous* app-day. Asking which day contains it would report the day before the one that was clicked.
        XCTAssertEqual(
            ReportRangeRules.dayStart(of: at("2026-08-05 00:00"), resetHour: 3, resetMinute: 0, calendar: calendar),
            at("2026-08-05 03:00")
        )
        XCTAssertEqual(
            DayWindow.start(at: at("2026-08-05 00:00"), resetHour: 3, resetMinute: 0, calendar: calendar),
            at("2026-08-04 03:00"),
            "which is the other question, and the right answer to it"
        )
    }

    func testTheBoundaryFollowsTheSettingRatherThanBeingFixedAtThree() {
        let range = ReportRangeRules.bounds(
            start: at("2026-08-05 00:00"),
            end: nil,
            resetHour: 6,
            resetMinute: 30,
            calendar: calendar
        )
        XCTAssertEqual(range.start, at("2026-08-05 06:30"))
        XCTAssertEqual(range.end, at("2026-08-06 06:30"))
    }

    func testADayAcrossADaylightSavingChangeIsStillOneWallClockDay() {
        // The clocks go forward in the UK at 01:00 on 29 March 2026, so the app-day that *contains* the change is the
        // one starting at 3AM on the 28th: 23 hours long. Through `Calendar`, both ends still land at 3AM local; on
        // seconds arithmetic the closing boundary would drift to 4AM.
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let formatter = DateFormatter()
        formatter.calendar = london
        formatter.timeZone = london.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let range = ReportRangeRules.bounds(
            start: formatter.date(from: "2026-03-28 00:00")!,
            end: nil,
            resetHour: 3,
            resetMinute: 0,
            calendar: london
        )

        XCTAssertEqual(formatter.string(from: range.start), "2026-03-28 03:00")
        XCTAssertEqual(formatter.string(from: range.end), "2026-03-29 03:00")
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 23 * 60 * 60, "a short day, correctly")
    }

    // MARK: - the sum

    func testEveryCategoryWithTimeInTheRangeIsTotalled() throws {
        try entry("Break", start: "2026-08-05 09:00", duration: 600)
        try entry("Break", start: "2026-08-06 09:00", duration: 300)
        try entry("Meeting", start: "2026-08-07 14:00", duration: 1_800)

        let range = bounds("2026-08-05 00:00", "2026-08-07 00:00")
        let totals = entries.totals(from: range.start, to: range.end)

        // Biggest first: what the time went on is the question, so the answer leads.
        XCTAssertEqual(totals.map(\.name), ["Meeting", "Break"])
        XCTAssertEqual(totals.map(\.seconds), [1_800, 900])
    }

    func testACategoryWithNothingInTheRangeIsAbsentRatherThanZero() throws {
        try entry("Break", start: "2026-08-05 09:00", duration: 600)

        let range = bounds("2026-08-05 00:00", nil)
        let totals = entries.totals(from: range.start, to: range.end)

        XCTAssertEqual(totals.map(\.name), ["Break"], "a page of 0:00 rows would bury the answer")
    }

    func testTimeOutsideTheRangeIsNotCounted() throws {
        // Before the reset on the picked day is the day before, and this is the case that a midnight boundary would
        // get wrong: 01:00 on the 5th belongs to the 4th.
        try entry("Break", start: "2026-08-05 01:00", duration: 600)

        let range = bounds("2026-08-05 00:00", nil)

        XCTAssertTrue(entries.totals(from: range.start, to: range.end).isEmpty)
        let dayBefore = bounds("2026-08-04 00:00", nil)
        XCTAssertEqual(entries.totals(from: dayBefore.start, to: dayBefore.end).map(\.seconds), [600])
    }

    func testAStretchAcrossTheBoundaryIsSplitBetweenTheTwoReports() throws {
        // Half an hour either side of the 3AM reset. Clipped rather than counted whole in both, or the two days would
        // add up to more than was recorded.
        try entry("Break", start: "2026-08-06 02:30", duration: 3_600)

        let first = bounds("2026-08-05 00:00", nil)
        let second = bounds("2026-08-06 00:00", nil)

        XCTAssertEqual(entries.totals(from: first.start, to: first.end).map(\.seconds), [1_800])
        XCTAssertEqual(entries.totals(from: second.start, to: second.end).map(\.seconds), [1_800])
    }

    func testARowCarriesWhatItNeedsToBeDrawn() throws {
        // One read rather than a query per row: the name, the icon and the colour come with the figure.
        try entry("Meeting", start: "2026-08-05 09:00", duration: 60)

        let range = bounds("2026-08-05 00:00", nil)
        let total = try XCTUnwrap(entries.totals(from: range.start, to: range.end).first)

        XCTAssertEqual(total.name, "Meeting")
        XCTAssertEqual(total.iconName, "ic_meeting", "the seeded icon, resolved from icon_id")
        XCTAssertNotNil(total.colour, "and the seeded colour, resolved from colour_id")
    }

    func testARetiredCategorysTimeStillCounts() throws {
        // A retired row is kept precisely so its history resolves: the time was spent, whatever the category's state
        // is now.
        try entry("Break", start: "2026-08-05 09:00", duration: 600)
        let breakID = try XCTUnwrap(categories.matching(name: "Break").first?.id)
        XCTAssertTrue(database.execute("UPDATE category SET active = 0 WHERE category_id = \(breakID);"))

        let range = bounds("2026-08-05 00:00", nil)
        XCTAssertEqual(entries.totals(from: range.start, to: range.end).map(\.name), ["Break"])
    }

    func testAStillRunningSegmentContributesNothing() {
        // It is not an entry yet. `time_entry` is what the app counts, written when a segment closes, so a clock
        // running right now shows on the Faces tab and arrives here when it stops.
        let epoch = Int(at("2026-08-05 09:00").timeIntervalSince1970)
        XCTAssertTrue(database.execute(
            """
            INSERT INTO device_event (
                event_number, event_type_id, device_face, start_time, timezone_id,
                start_epoch, duration_seconds, paused, finalised
            ) VALUES (\(epoch), 1, 8, '2026-08-05 09:00', 0, \(epoch), 600, 0, 0);
            """
        ))

        let range = bounds("2026-08-05 00:00", nil)
        XCTAssertTrue(entries.totals(from: range.start, to: range.end).isEmpty)
    }

    // MARK: - the entries behind a total

    func testTheEntriesUnderACategoryAreEarliestFirst() throws {
        try entry("Break", start: "2026-08-13 14:00", duration: 300)
        try entry("Break", start: "2026-08-13 09:00", duration: 600)
        try entry("Meeting", start: "2026-08-13 11:00", duration: 60)

        let range = bounds("2026-08-13 00:00", nil)
        let breakID = try XCTUnwrap(categories.matching(name: "Break").first?.id)
        let records = entries.entries(categoryID: breakID, from: range.start, to: range.end)

        XCTAssertEqual(records.map(\.start), [at("2026-08-13 09:00"), at("2026-08-13 14:00")])
        XCTAssertEqual(records.map(\.seconds), [600, 300], "and each ends where its duration says")
        XCTAssertEqual(records.map(\.end), [at("2026-08-13 09:10"), at("2026-08-13 14:05")])
    }

    func testOnlyTheAskedForCategorysEntriesComeBack() throws {
        try entry("Break", start: "2026-08-13 09:00", duration: 600)
        try entry("Meeting", start: "2026-08-13 11:00", duration: 60)

        let range = bounds("2026-08-13 00:00", nil)
        let meetingID = try XCTUnwrap(categories.matching(name: "Meeting").first?.id)

        XCTAssertEqual(
            entries.entries(categoryID: meetingID, from: range.start, to: range.end).map(\.seconds),
            [60]
        )
    }

    func testTheEntriesAddUpToTheTotalOnTheHeading() throws {
        // The pair has to agree: a column of figures that does not sum to the number above it reads as a bug in one of
        // them. Both are clipped the same way, which is what makes it true even across a boundary.
        try entry("Break", start: "2026-08-13 09:00", duration: 600)
        try entry("Break", start: "2026-08-14 02:30", duration: 3_600)

        let range = bounds("2026-08-13 00:00", nil)
        let breakID = try XCTUnwrap(categories.matching(name: "Break").first?.id)
        let total = try XCTUnwrap(entries.totals(from: range.start, to: range.end).first)
        let records = entries.entries(categoryID: breakID, from: range.start, to: range.end)

        XCTAssertEqual(records.map(\.seconds).reduce(0, +), total.seconds)
        XCTAssertEqual(
            records.last?.end, at("2026-08-14 03:00"),
            "the stretch across the reset shows the part inside the range, not the whole of itself"
        )
    }

    // MARK: - the list

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func total(_ name: String, seconds: TimeInterval, id: Int = 1) -> CategoryTotal {
        CategoryTotal(
            categoryID: id,
            name: name,
            iconName: nil,
            colour: .red,
            usesWhiteLines: false,
            seconds: seconds
        )
    }

    func testTheListDrawsARowPerCategoryWithItsTime() {
        let list = ReportTotalsList()

        list.show([total("Meeting", seconds: 3_900, id: 2), total("Break", seconds: 900)], showingSeconds: false)

        let figures = descendants(of: list)
            .compactMap { view -> String? in
                guard view.accessibilityIdentifier().hasSuffix("-duration") else { return nil }
                return (view as? NSTextField)?.stringValue
            }
        XCTAssertEqual(figures, ["1:05", "0:15"])
    }

    func testTheFiguresCarrySecondsWhenTheSettingSays() {
        // The same setting the menu bar's figure obeys, and it earns its keep here: at H:MM every total under a minute
        // reads 0:00, which is indistinguishable from a category that was opened and left.
        let list = ReportTotalsList()

        list.show([total("Break", seconds: 45)], showingSeconds: true)

        let figure = descendants(of: list)
            .first { $0.accessibilityIdentifier().hasSuffix("-duration") }
            .flatMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(figure, "0:00:45")
    }

    func testASumIsRoundedRatherThanTruncated() {
        // A static historical sum, unlike the menu bar's live figure: 59.6 seconds reads as a minute rather than one
        // second short of what was logged.
        let list = ReportTotalsList()

        list.show([total("Break", seconds: 59.6)], showingSeconds: false)

        let figure = descendants(of: list)
            .first { $0.accessibilityIdentifier().hasSuffix("-duration") }
            .flatMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(figure, "0:01")
    }

    func testAnEmptyRangeSaysSoRatherThanDrawingAnEmptyTable() {
        let list = ReportTotalsList()
        list.show([total("Break", seconds: 900)], showingSeconds: false)

        list.show([], showingSeconds: false)

        let labels = descendants(of: list).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(labels, ["No time recorded in this range."])
    }
}

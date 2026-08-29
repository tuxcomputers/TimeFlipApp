@testable import FacetApp
import AppKit
import XCTest

/// Time recorded yesterday turning up under a range picked on the Report tab, and time outside it staying out.
///
/// **Driven through the tab rather than through the sum.** What the range comes to is `ReportTotalsTests`, against the
/// same database and in far more detail; what this adds is the path between the two calendars and the figures under
/// them -- a day picked, the bounds worked out against the reset the table holds, the read, and the list drawing the
/// answer. Each of those has a test; a figure is only right when all four agree.
///
/// **Against a real database, with the rows written straight in.** A total is a statement about what is stored, so the
/// only honest way to ask for one is to store something. Both rows go in, `device_event` and `time_entry`, because the
/// sum joins them: an entry with no segment behind it is not time the app would ever have recorded.
@MainActor
final class ReportTabAddsUpThePickedRangeTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var categories: CategoryStore!
    private var controller: SettingsWindowController!
    /// Bumped per row so two segments never collide on `event_number`, which the cube numbers and the table keeps unique.
    private var written = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            _ = try database.bootstrap()
            let connection = database.connection()
            categories = CategoryStore(connection: connection)
            let settings = SettingStore(connection: connection)
            controller = SettingsWindowController(
                debugLog: nil,
                categories: categories,
                faces: FaceStore(connection: connection),
                entries: TimeEntryStore(connection: connection),
                settings: settings
            )
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            controller?.stopTicking()
            controller = nil
            categories = nil
            database.remove()
        }
        super.tearDown()
    }

    /// The Report tab, shown the way the window shows it.
    private func reportPane() throws -> ReportPane {
        controller.select(.report)
        return try XCTUnwrap(controller.panes.selectedTabViewItem?.view as? ReportPane)
    }

    /// Comes back to the tab, which is what asks for the totals again.
    ///
    /// **Away and back, because selecting the tab already on show is not a change**: the tab view's delegate fires on
    /// a change, and `pane.refresh()` hangs off that. Calling `select(.report)` twice looks like the same act and is
    /// the one thing that would leave the figures where they were -- so this goes somewhere else first, exactly as
    /// somebody looking at another tab and coming back does.
    private func lookAway(andBackTo pane: ReportPane) {
        controller.select(.faces)
        controller.select(.report)
        XCTAssertTrue(controller.panes.selectedTabViewItem?.view === pane, "the same pane should have come back")
    }

    /// **Midday, and local, on a day counted back from today.** The obvious reading of "an hour twenty four hours ago"
    /// is `Date().addingTimeInterval(-86_400)`, and it makes this test fail for three hours a day: the range is
    /// measured against the daily reset the table seeds at 3AM, so on a run at 1AM an entry exactly a day old sits
    /// before yesterday's boundary and the range honestly does not cover it. Midday is inside the day whichever hour
    /// the suite runs at.
    private func midday(daysAgo days: Int) -> Date {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -days, to: midnight)!.addingTimeInterval(12 * 60 * 60)
    }

    private func startOfDay(daysAgo days: Int) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: Date()))!
    }

    /// An hour of Meeting, beginning at `start`, written as the pair of rows the app would have written.
    ///
    /// `start_epoch` is where a stretch sits in time and is what the sum reads; `started_at` is local text that
    /// nothing compares. Face 2 is the one the DDL seeds with Meeting, so the segment describes a cube doing what
    /// the entry says it did.
    private func anHourOfMeeting(startingAt start: Date) throws {
        written += 1
        let categoryID = try XCTUnwrap(categories.matching(name: "Meeting").first?.id)
        let epoch = Int(start.timeIntervalSince1970)
        XCTAssertTrue(database.execute(
            """
            INSERT INTO device_event (
                event_number, event_type_id, device_face, start_time, timezone_id,
                start_epoch, duration_seconds, paused, finalised, processed
            ) VALUES (
                \(epoch + written), 1, 2, '\(start)', 0, \(epoch), 3600, 0, 1, 1
            );
            INSERT INTO time_entry (device_event_id, category_id, started_at, ended_at, duration_seconds)
            VALUES (
                (SELECT MAX(device_event_id) FROM device_event), \(categoryID), '\(start)', '\(start)', 3600
            );
            """
        ))
    }

    /// What the tab is drawing against Meeting, in seconds, or zero when the range holds none of it.
    ///
    /// **Read off what the list was shown**, rather than asking the store the same question a second time: the point
    /// of driving the tab is that the figure on screen is the one being asserted.
    private func meetingSeconds(on pane: ReportPane) -> Double {
        pane.totalsList.shownTotals.first { $0.name == "Meeting" }?.seconds ?? 0
    }

    func testAnHourRecordedYesterdayShowsUpOnceTheRangeCoversIt() throws {
        let pane = try reportPane()
        pane.selectStart(startOfDay(daysAgo: 1))
        pane.selectEnd(startOfDay(daysAgo: 0))
        let before = meetingSeconds(on: pane)

        try anHourOfMeeting(startingAt: midday(daysAgo: 1))
        // Asked again the way the window asks: coming back to the tab refreshes it, since today moves and the entries
        // grow while somebody is looking elsewhere.
        lookAway(andBackTo: pane)

        XCTAssertEqual(
            meetingSeconds(on: pane) - before, 3600, accuracy: 0.5,
            "an hour recorded yesterday should be an hour more under a range that covers yesterday"
        )
    }

    func testAnHourOutsideTheRangeIsNotAddedIn() throws {
        // **What makes the test above mean anything.** A tab that ignored the range entirely, or bounds worked out
        // against the wrong day, would pass it: the figure would go up by an hour because an hour was recorded. This
        // is the same act three days back, which the same range must not pick up.
        let pane = try reportPane()
        pane.selectStart(startOfDay(daysAgo: 1))
        pane.selectEnd(startOfDay(daysAgo: 0))
        let before = meetingSeconds(on: pane)

        try anHourOfMeeting(startingAt: midday(daysAgo: 3))
        lookAway(andBackTo: pane)

        XCTAssertEqual(meetingSeconds(on: pane), before, "time from outside the picked range was counted")
    }

    func testWideningTheRangeBackwardsPicksItUp() throws {
        // And the other half: the hour is genuinely there, and it is the range that was keeping it out. Without this
        // the test above would also pass on a tab that showed nothing at all.
        let pane = try reportPane()
        try anHourOfMeeting(startingAt: midday(daysAgo: 3))
        pane.selectStart(startOfDay(daysAgo: 1))
        pane.selectEnd(startOfDay(daysAgo: 0))
        let narrow = meetingSeconds(on: pane)

        pane.selectStart(startOfDay(daysAgo: 4))
        pane.selectEnd(startOfDay(daysAgo: 0))

        XCTAssertEqual(meetingSeconds(on: pane) - narrow, 3600, accuracy: 0.5)
    }
}

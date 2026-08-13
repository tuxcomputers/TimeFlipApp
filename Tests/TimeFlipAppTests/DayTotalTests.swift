@testable import TimeFlipApp
import Foundation
import XCTest

/// Covers `TimeEntryStore` and `DayTotal` against a real database: how much time a category has today, summed
/// from the rows and topped up with the segment still running.
///
/// The whole point is that nothing accumulates. Every figure here is re-derived, so the tests write rows and ask
/// rather than driving a sequence of events.
@MainActor
final class DayTotalTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var connection: DatabaseConnection!
    private var entries: TimeEntryStore!
    private var events: DeviceEventRecorder!
    private var faces: FaceStore!
    private var total: DayTotal!

    /// 2026-08-13 09:00:00 UTC, and every offset below is from it. Whole seconds, so `start_epoch` is exact.
    private let noon = Date(timeIntervalSince1970: 1_786_600_000)

    /// Break, which face 8 is seeded with.
    private let breakID = 1
    /// Meeting, which face 2 is seeded with.
    private let meetingID = 2

    private var written = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        connection = database.connection()
        entries = TimeEntryStore(connection: connection)
        faces = FaceStore(connection: connection)
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: nil,
            debugLog: nil
        )
        total = DayTotal(settings: SettingReader(connection: connection), entries: entries, events: events, faces: faces)
    }

    override func tearDown() {
        total = nil
        events = nil
        faces = nil
        entries = nil
        connection = nil
        database.remove()
        super.tearDown()
    }

    /// A recorded stretch: the `device_event` it came from, and the `time_entry` that counts it.
    private func record(category: Int, face: Int, from offset: TimeInterval, seconds: Double, open: Bool = false) {
        written += 1
        let start = Int(noon.timeIntervalSince1970 + offset)
        XCTAssertTrue(database.execute(
            """
            INSERT INTO device_event (
                event_number, event_type_id, device_face, start_time, timezone_id,
                start_epoch, duration_seconds, paused, finalised
            ) VALUES (
                \(start + written), 1, \(face), '2026-08-13T00:00:00', 0,
                \(start), \(seconds), 0, \(open ? 0 : 1)
            );
            """
        ))
        guard !open else { return }
        let id = Int(database.string("SELECT MAX(device_event_id) FROM device_event;") ?? "0") ?? 0
        XCTAssertTrue(database.execute(
            """
            INSERT INTO time_entry (
                category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds
            ) VALUES (
                \(category), \(id), '2026-08-13T00:00:00', 0, '2026-08-13T00:00:00', 0, \(seconds)
            );
            """
        ))
    }

    /// The window every test below sits inside: `daily_reset_time` moved well clear of `noon`.
    private func windowStart() -> Date {
        total.windowStart(at: noon)
    }

    // MARK: - the recorded part

    func testACategoryWithNothingRecordedHasNoTime() {
        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 0)
    }

    func testEveryStretchOfTheCategoryAddsUp() {
        record(category: breakID, face: 8, from: -3_600, seconds: 600)
        record(category: breakID, face: 8, from: -1_800, seconds: 900)

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 1_500)
    }

    func testTimeIsSummedByCategoryAndNotByFace() {
        // The same category on two different faces, which manual mode's rotation produces as a matter of course:
        // consecutive stretches of one category deliberately land on different faces.
        record(category: breakID, face: 13, from: -3_600, seconds: 600)
        record(category: breakID, face: 14, from: -1_800, seconds: 300)

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 900)
    }

    func testAnotherCategorysTimeIsNotCounted() {
        record(category: breakID, face: 8, from: -3_600, seconds: 600)
        record(category: meetingID, face: 2, from: -1_800, seconds: 900)

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 600)
        XCTAssertEqual(total.seconds(categoryID: meetingID, at: noon), 900)
    }

    func testAStretchFromBeforeTheWindowIsClippedToIt() {
        // An hour of it either side of the boundary.
        let start = windowStart()
        let seconds = entriesAcross(boundary: start, category: breakID)

        XCTAssertEqual(seconds, 3_600, "only the part inside today counts")
    }

    private func entriesAcross(boundary: Date, category: Int) -> TimeInterval {
        let offset = boundary.timeIntervalSince(noon) - 3_600
        record(category: category, face: 8, from: offset, seconds: 7_200)
        return total.seconds(categoryID: category, at: noon)
    }

    func testYesterdaysTimeIsNotTodaysTotal() {
        record(category: breakID, face: 8, from: windowStart().timeIntervalSince(noon) - 7_200, seconds: 600)

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 0)
    }

    // MARK: - the part still running

    func testTheOpenSegmentIsAddedOnTop() throws {
        record(category: breakID, face: 8, from: -3_600, seconds: 600)
        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: 13))
        events.startSegment(face: 13, at: noon.addingTimeInterval(-120))

        // 600 recorded, plus two minutes of the stretch still running.
        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 720)
    }

    func testTheOpenSegmentCountsTowardsWhicheverCategoryItsFaceHolds() throws {
        XCTAssertTrue(faces.assign(categoryID: meetingID, toFace: 13))
        events.startSegment(face: 13, at: noon.addingTimeInterval(-60))

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 0)
        XCTAssertEqual(total.seconds(categoryID: meetingID, at: noon), 60)
    }

    func testTheOpenSegmentIsNotCountedTwiceOnceItIsRecorded() throws {
        // What stops the double count: the live part is added *because* it has no entry yet. Closing it gives it
        // one, and the figure then comes entirely from the recorded side.
        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: 13))
        events.startSegment(face: 13, at: noon.addingTimeInterval(-300))
        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 300, "precondition: the live part")

        // Close it and record it, as the two modules do together.
        let recorder = TimeEntryRecorder(
            connection: connection,
            settings: SettingReader(connection: connection),
            faces: faces,
            debugLog: nil
        )
        let closed = try XCTUnwrap(events.closeOpenSegment(at: noon))
        recorder.consider(deviceEventID: closed.deviceEventID)

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 300, "the same 300, from the entry now")
    }

    func testAPausedOpenSegmentIsNotCounted() {
        // A cube reports paused stretches of its own. Time not spent is never counted, whether it is recorded or
        // still open.
        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: 13))
        record(category: breakID, face: 13, from: -600, seconds: 600, open: true)
        XCTAssertTrue(database.execute("UPDATE device_event SET paused = 1 WHERE finalised = 0;"))

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 0)
    }

    func testAnOpenSegmentRunningSinceBeforeTheWindowCountsFromTheBoundary() {
        XCTAssertTrue(faces.assign(categoryID: breakID, toFace: 13))
        let start = windowStart()
        events.startSegment(face: 13, at: start.addingTimeInterval(-1_800))

        XCTAssertEqual(
            total.seconds(categoryID: breakID, at: start.addingTimeInterval(600)), 600,
            "the half hour before the reset belongs to yesterday"
        )
    }

    // MARK: - the window it is summed over

    func testTheResetTimeIsReadWhenTheTotalIsAsked() {
        // Recorded two hours before noon. With the day starting at 03:00 that is inside today; move the reset to
        // an hour before noon and the same stretch is yesterday's.
        record(category: breakID, face: 8, from: -7_200, seconds: 600)
        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 600, "precondition")

        let hour = Calendar.current.component(.hour, from: noon.addingTimeInterval(-3_600))
        let minute = Calendar.current.component(.minute, from: noon.addingTimeInterval(-3_600))
        XCTAssertTrue(database.execute(
            "UPDATE setting SET setting_value = '{\"hour\":\(hour),\"minute\":\(minute)}' "
                + "WHERE setting_name = 'daily_reset_time';"
        ))

        XCTAssertEqual(total.seconds(categoryID: breakID, at: noon), 0, "read again, so the window moved")
    }
}

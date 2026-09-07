@testable import FacetCore
import Foundation
import Testing

/// Covers `TimeEntryStore` and `DayTotal` against a real database: how much time a category has today, summed
/// from the rows and topped up with the segment still running.
///
/// The whole point is that nothing accumulates. Every figure here is re-derived, so the tests write rows and ask
/// rather than driving a sequence of events.
@Suite @MainActor
final class DayTotalTests {
    private let database: TemporaryDatabase
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

    init() throws {
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
        total = DayTotal(settings: SettingStore(connection: connection), entries: entries, events: events, faces: faces)
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored
        // properties by hand is what the old `MainActor.assumeIsolated` block was for; the
        // instance is discarded whole here, so removing the directory is all that is left.
        // The database connection closes after the file is unlinked rather than before, which
        // both platforms allow.
        database.remove()
    }

    /// A recorded stretch: the `device_event` it came from, and the `time_entry` that counts it.
    private func record(category: Int, face: Int, from offset: TimeInterval, seconds: Double, open: Bool = false) {
        written += 1
        let start = Int(noon.timeIntervalSince1970 + offset)
        #expect(
            database.execute(
            """
            INSERT INTO device_event (
                event_number, event_type_id, device_face, start_time, timezone_id,
                start_epoch, duration_seconds, paused, finalised
            ) VALUES (
                \(start + written), 1, \(face), '2026-08-13T00:00:00', 0,
                \(start), \(seconds), 0, \(open ? 0 : 1)
            );
            """
        )
        )
        guard !open else { return }
        let id = Int(database.string("SELECT MAX(device_event_id) FROM device_event;") ?? "0") ?? 0
#expect(
    database.execute(
            """
            INSERT INTO time_entry (
                category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds
            ) VALUES (
                \(category), \(id), '2026-08-13T00:00:00', 0, '2026-08-13T00:00:00', 0, \(seconds)
            );
            """
        )
)
    }

    /// The window every test below sits inside: `daily_reset_time` moved well clear of `noon`.
    private func windowStart() -> Date {
        total.windowStart(at: noon)
    }

    // MARK: - the recorded part

    @Test func testACategoryWithNothingRecordedHasNoTime() {
        #expect(total.seconds(categoryID: breakID, at: noon) == 0)
    }

    @Test func testEveryStretchOfTheCategoryAddsUp() {
        record(category: breakID, face: 8, from: -3_600, seconds: 600)
        record(category: breakID, face: 8, from: -1_800, seconds: 900)

        #expect(total.seconds(categoryID: breakID, at: noon) == 1_500)
    }

    @Test func testTimeIsSummedByCategoryAndNotByFace() {
        // The same category on two different faces, which manual mode's rotation produces as a matter of course:
        // consecutive stretches of one category deliberately land on different faces.
        record(category: breakID, face: 13, from: -3_600, seconds: 600)
        record(category: breakID, face: 14, from: -1_800, seconds: 300)

        #expect(total.seconds(categoryID: breakID, at: noon) == 900)
    }

    @Test func testAnotherCategorysTimeIsNotCounted() {
        record(category: breakID, face: 8, from: -3_600, seconds: 600)
        record(category: meetingID, face: 2, from: -1_800, seconds: 900)

        #expect(total.seconds(categoryID: breakID, at: noon) == 600)
        #expect(total.seconds(categoryID: meetingID, at: noon) == 900)
    }

    @Test func testAStretchFromBeforeTheWindowIsClippedToIt() {
        // An hour of it either side of the boundary.
        let start = windowStart()
        let seconds = entriesAcross(boundary: start, category: breakID)

        #expect(seconds == 3_600, "only the part inside today counts")
    }

    private func entriesAcross(boundary: Date, category: Int) -> TimeInterval {
        let offset = boundary.timeIntervalSince(noon) - 3_600
        record(category: category, face: 8, from: offset, seconds: 7_200)
        return total.seconds(categoryID: category, at: noon)
    }

    @Test func testYesterdaysTimeIsNotTodaysTotal() {
        record(category: breakID, face: 8, from: windowStart().timeIntervalSince(noon) - 7_200, seconds: 600)

        #expect(total.seconds(categoryID: breakID, at: noon) == 0)
    }

    // MARK: - the part still running

    @Test func testTheOpenSegmentIsAddedOnTop() throws {
        record(category: breakID, face: 8, from: -3_600, seconds: 600)
        #expect(faces.assign(categoryID: breakID, toFace: 13))
        events.startSegment(face: 13, at: noon.addingTimeInterval(-120))

        // 600 recorded, plus two minutes of the stretch still running.
        #expect(total.seconds(categoryID: breakID, at: noon) == 720)
    }

    @Test func testTheOpenSegmentCountsTowardsWhicheverCategoryItsFaceHolds() throws {
        #expect(faces.assign(categoryID: meetingID, toFace: 13))
        events.startSegment(face: 13, at: noon.addingTimeInterval(-60))

        #expect(total.seconds(categoryID: breakID, at: noon) == 0)
        #expect(total.seconds(categoryID: meetingID, at: noon) == 60)
    }

    @Test func testTheOpenSegmentIsNotCountedTwiceOnceItIsRecorded() throws {
        // What stops the double count: the live part is added *because* it has no entry yet. Closing it gives it
        // one, and the figure then comes entirely from the recorded side.
        #expect(faces.assign(categoryID: breakID, toFace: 13))
        events.startSegment(face: 13, at: noon.addingTimeInterval(-300))
        #expect(total.seconds(categoryID: breakID, at: noon) == 300, "precondition: the live part")

        // Close it and record it, as the two modules do together.
        let recorder = TimeEntryRecorder(
            connection: connection,
            settings: SettingStore(connection: connection),
            faces: faces,
            debugLog: nil
        )
        let closed = try #require(events.closeOpenSegment(at: noon))
        recorder.consider(deviceEventID: closed.deviceEventID)

#expect(total.seconds(categoryID: breakID, at: noon) == 300, "the same 300, from the entry now")
    }

    @Test func testAPausedOpenSegmentIsNotCounted() {
        // A cube reports paused stretches of its own. Time not spent is never counted, whether it is recorded or
        // still open.
        #expect(faces.assign(categoryID: breakID, toFace: 13))
        record(category: breakID, face: 13, from: -600, seconds: 600, open: true)
        #expect(database.execute("UPDATE device_event SET paused = 1 WHERE finalised = 0;"))

        #expect(total.seconds(categoryID: breakID, at: noon) == 0)
    }

    // MARK: - whether the figure is moving

    @Test func testACubesOpenSegmentIsCounting() {
        // **The question the menu bar and the Faces tab tick on.** A cube's stretch counts here exactly as the app's
        // own does: the elapsed part of the figure is worked out from `start_epoch` and this machine's clock either
        // way, so the number moves and the surfaces drawing it have to keep up.
        #expect(faces.assign(categoryID: meetingID, toFace: 5))
        record(category: meetingID, face: 5, from: -120, seconds: 120, open: true)

        #expect(total.isCounting(categoryID: meetingID))
        #expect(total.seconds(categoryID: meetingID, at: noon) == 120, "and this is the figure that is moving")
        #expect(
            total.seconds(categoryID: meetingID, at: noon.addingTimeInterval(30)) == 150,
            "thirty seconds later, without a row being written"
        )
    }

    @Test func testAPausedCubeIsNotCounting() {
        // Time not spent never counts, so there is nothing for a tick to keep up with either.
        #expect(faces.assign(categoryID: meetingID, toFace: 5))
        record(category: meetingID, face: 5, from: -120, seconds: 120, open: true)
        #expect(database.execute("UPDATE device_event SET paused = 1 WHERE finalised = 0;"))

        #expect(!(total.isCounting(categoryID: meetingID)))
    }

    @Test func testNothingOpenIsNotCounting() {
        record(category: breakID, face: 8, from: -3_600, seconds: 600)

        #expect(!(total.isCounting(categoryID: breakID)), "600 recorded, and none of it still running")
    }

    @Test func testAnotherCategorysOpenSegmentIsNotThisOnesToCount() {
        // The same rule the figure follows: what is open counts towards whichever category its face holds, and
        // towards no other.
        #expect(faces.assign(categoryID: meetingID, toFace: 13))
        events.startSegment(face: 13, at: noon.addingTimeInterval(-60))

        #expect(total.isCounting(categoryID: meetingID))
        #expect(!(total.isCounting(categoryID: breakID)))
    }

    @Test func testAnOpenSegmentRunningSinceBeforeTheWindowCountsFromTheBoundary() {
        #expect(faces.assign(categoryID: breakID, toFace: 13))
        let start = windowStart()
        events.startSegment(face: 13, at: start.addingTimeInterval(-1_800))

        #expect(
            total.seconds(categoryID: breakID, at: start.addingTimeInterval(600)) == 600,
            "the half hour before the reset belongs to yesterday"
        )
    }

    // MARK: - when a category was last used

    @Test func testACategoryThatHasNeverRecordedTimeHasNoLastUse() {
        #expect(entries.lastUsed(categoryID: breakID) == nil)
    }

    @Test func testTheLastUseIsTheEndOfTheLastStretch() {
        record(category: breakID, face: 8, from: -7_200, seconds: 600)
        record(category: breakID, face: 8, from: -3_600, seconds: 900)

        // The end, not the start: "last used" is when the using stopped. The later stretch began an hour before
        // `noon` and ran for fifteen minutes.
        #expect(entries.lastUsed(categoryID: breakID) == noon.addingTimeInterval(-3_600 + 900))
    }

    @Test func testAnotherCategorysTimeIsNotItsLastUse() {
        record(category: meetingID, face: 2, from: -600, seconds: 60)

        #expect(entries.lastUsed(categoryID: breakID) == nil)
    }

    @Test func testTheLastUseIgnoresTheDayWindowEntirely() {
        // Unlike a total, this is not a question about today: a category retired last year still says when it was
        // last used.
        record(category: breakID, face: 8, from: -400_000, seconds: 600)

        #expect(entries.lastUsed(categoryID: breakID) == noon.addingTimeInterval(-400_000 + 600))
    }

    // MARK: - the window it is summed over

    @Test func testTheResetTimeIsReadWhenTheTotalIsAsked() {
        // Recorded two hours before noon. With the day starting at 03:00 that is inside today; move the reset to
        // an hour before noon and the same stretch is yesterday's.
        record(category: breakID, face: 8, from: -7_200, seconds: 600)
        #expect(total.seconds(categoryID: breakID, at: noon) == 600, "precondition")

        let hour = Calendar.current.component(.hour, from: noon.addingTimeInterval(-3_600))
        let minute = Calendar.current.component(.minute, from: noon.addingTimeInterval(-3_600))
        #expect(
            database.execute( "UPDATE setting SET setting_value = '{\"hour\":\(hour),\"minute\":\(minute)}' " + "WHERE setting_name = 'daily_reset_time';" )
        )

        #expect(total.seconds(categoryID: breakID, at: noon) == 0, "read again, so the window moved")
    }
}

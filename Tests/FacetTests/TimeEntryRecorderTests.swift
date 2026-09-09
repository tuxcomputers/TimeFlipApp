@testable import FacetCore
import Foundation
import Testing

/// Covers `TimeEntryRecorder` against a real database: which finished segments count as tracked time, what the
/// row it writes says, and the two modules working together.
///
/// `TimeEntryRulesTests` covers the decisions. This is about them being carried out against real rows -- and
/// about the question that made the pair of app faces necessary: **which category a finished segment is filed
/// under when the next one has already started.**
@Suite @MainActor
final class TimeEntryRecorderTests {
    private let database: TemporaryDatabase
    private var connection: DatabaseConnection!
    private var faces: FaceStore!
    private var categories: CategoryStore!
    private var entries: TimeEntryRecorder!
    private var events: DeviceEventRecorder!

    /// No fractional part, so `start_epoch` is exactly this.
    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        connection = database.connection()
        faces = FaceStore(connection: connection)
        categories = CategoryStore(connection: connection)
        entries = TimeEntryRecorder(
            connection: connection,
            settings: SettingStore(connection: connection),
            faces: faces,
            debugLog: nil
        )
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: entries,
            debugLog: nil
        )
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored properties by hand
        // is what the old `MainActor.assumeIsolated` block was for; the instance is discarded whole here, so
        // removing the directory is all that is left. `database` is a `let` for the same reason -- a
        // non-isolated `deinit` may read that where it could not read a `@MainActor var`.
        database.remove()
    }

    private func setBlip(_ seconds: Int) {
        #expect(database.execute(
            "UPDATE setting SET setting_value = '{\"seconds\":\(seconds)}' WHERE setting_name = 'blip_time';"
        ))
    }

    private func categoryID(named name: String) throws -> Int {
        try #require(categories.matching(name: name).first?.id)
    }

    /// Counts the segments this test has written, so each gets its own event number: `UN1_device_event` is a
    /// unique index over `(event_number, start_epoch)`, and these all start in the same second.
    private var written = 0

    /// A finished segment on a face, written straight in so a test can choose its duration exactly.
    private func finishedSegment(face: Int, duration: Double, paused: Bool = false, finalised: Bool = true) -> Int {
        written += 1
        let epoch = Int(moment.timeIntervalSince1970)
        #expect(database.execute(
            """
            INSERT INTO device_event (
                event_number, event_type_id, device_face, start_time, timezone_id,
                start_epoch, duration_seconds, paused, finalised
            ) VALUES (
                \(epoch + written), 1, \(face), '2026-08-13T00:00:00', 0,
                \(epoch), \(duration), \(paused ? 1 : 0), \(finalised ? 1 : 0)
            );
            """
        ))
        return Int(database.string("SELECT MAX(device_event_id) FROM device_event;") ?? "0") ?? 0
    }

    private func entryColumn(_ name: String, forSegment deviceEventID: Int) -> String? {
        database.string("SELECT \(name) FROM time_entry WHERE device_event_id = \(deviceEventID);")
    }

    private func processed(_ deviceEventID: Int) -> String? {
        database.string("SELECT processed FROM device_event WHERE device_event_id = \(deviceEventID);")
    }

    // MARK: - what counts

    @Test func testAFinishedSegmentBecomesAnEntry() throws {
        let segment = finishedSegment(face: 8, duration: 300)

        let outcome = entries.consider(deviceEventID: segment)

        // Face 8 is seeded with Break, so that is what the time is filed under.
        let breakID = try categoryID(named: "Break")
        #expect(outcome == .created(timeEntryID: 1, categoryID: breakID))
        #expect(entryColumn("duration_seconds", forSegment: segment) == "300.0")
        #expect(processed(segment) == "1", "the question has been answered, so it stops being asked")
    }

    @Test func testASegmentUnderTheBlipThresholdIsSkippedAndNotAskedAgain() {
        setBlip(5)
        let segment = finishedSegment(face: 8, duration: 3)

        let outcome = entries.consider(deviceEventID: segment)

        #expect(outcome == .ignored(.blip(shorterThan: 5)))
        #expect(database.string("SELECT COUNT(*) FROM time_entry;") == "0")
        #expect(processed(segment) == "1", "marked, so the eligible set drains instead of growing a tail")
    }

    @Test func testASegmentExactlyAsLongAsTheThresholdIsKept() {
        setBlip(5)
        let segment = finishedSegment(face: 8, duration: 5)

        // "Ignore flips under five" -- and five is not under five.
        #expect(entries.consider(deviceEventID: segment) != .ignored(.blip(shorterThan: 5)))
        #expect(database.string("SELECT COUNT(*) FROM time_entry;") == "1")
    }

    @Test func testTheThresholdIsReadWhenTheQuestionIsAsked() {
        setBlip(30)
        let short = finishedSegment(face: 8, duration: 10)
        #expect(entries.consider(deviceEventID: short) == .ignored(.blip(shorterThan: 30)))

        // Changed by something else entirely, between one segment and the next. Nothing tells this module.
        setBlip(5)
        let same = finishedSegment(face: 8, duration: 10)

        #expect(entries.consider(deviceEventID: same) == .created(timeEntryID: 1, categoryID: 1))
    }

    @Test func testAPausedStretchIsNeverCounted() {
        let segment = finishedSegment(face: 8, duration: 600, paused: true)

        #expect(entries.consider(deviceEventID: segment) == .ignored(.paused))
        #expect(database.string("SELECT COUNT(*) FROM time_entry;") == "0")
        #expect(processed(segment) == "1", "no entry, ever, so the answer is final")
    }

    @Test func testAnOpenSegmentIsNotCountedAndIsLeftToBeAskedAgain() {
        let segment = finishedSegment(face: 8, duration: 60, finalised: false)

        #expect(entries.consider(deviceEventID: segment) == .ignored(.stillRunning))
        #expect(processed(segment) == "0", "not marked: the segment has not finished, so the question is not answered yet")
    }

    @Test func testASegmentIsNeverCountedTwice() {
        let segment = finishedSegment(face: 8, duration: 300)
        let first = entries.consider(deviceEventID: segment)

        let second = entries.consider(deviceEventID: segment)

        #expect(first == .created(timeEntryID: 1, categoryID: 1))
        #expect(second == .alreadyRecorded(timeEntryID: 1))
        #expect(database.string("SELECT COUNT(*) FROM time_entry;") == "1")
    }

    @Test func testAnIdForNoSegmentIsReportedRatherThanGuessedAt() {
        #expect(entries.consider(deviceEventID: 999) == .noSuchSegment)
    }

    // MARK: - what the entry says

    @Test func testTheEntrySpansTheSegmentAndCarriesItsZone() throws {
        let segment = finishedSegment(face: 8, duration: 3_600)

        entries.consider(deviceEventID: segment)

        // start + duration, back through the local calendar: a reporter gives a start and a length, never an
        // end. An hour later, in whatever zone the machine is in.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        #expect(entryColumn("started_at", forSegment: segment) == formatter.string(from: moment))
        #expect(entryColumn("ended_at", forSegment: segment) == formatter.string(from: moment.addingTimeInterval(3_600)))
        // Both ends carry the segment's own zone, because nothing here could know it changed part way through.
        #expect(entryColumn("start_timezone_id", forSegment: segment) == "0")
        #expect(entryColumn("end_timezone_id", forSegment: segment) == "0")
    }

    @Test func testAnUnassignedFaceIsStillCounted() {
        // Face 1 is seeded Unassigned. An entry against it is visible and can be corrected; a dropped entry is
        // time gone.
        let segment = finishedSegment(face: 1, duration: 300)

        #expect(entries.consider(deviceEventID: segment) == .created(timeEntryID: 1, categoryID: 0))
    }

    // MARK: - what a previous launch left open

    @Test func testAStrandedAppSegmentIsClosedKeepingTheDurationItAlreadyHad() throws {
        // A launch that ended without its quit sequence. The last duration written is the last moment anything
        // knows the segment was running, so recomputing it to now would record every hour the app was closed --
        // which is how a 14-second session came back as 39 minutes.
        let stranded = finishedSegment(face: ManualFace.first, duration: 40, finalised: false)

        let closed = events.closeSegmentsStrandedOnAppFaces()

        #expect(closed == [stranded])
        #expect(database.string("SELECT finalised FROM device_event WHERE device_event_id = \(stranded);") == "1")
        #expect(database.string("SELECT duration_seconds FROM device_event WHERE device_event_id = \(stranded);") == "40.0", "short by at most one history interval, rather than wrong by however long the app was shut")
    }

    @Test func testAStrandedAppSegmentBecomesTrackedTime() throws {
        let stranded = finishedSegment(face: ManualFace.first, duration: 40, finalised: false)
        #expect(faces.assign(categoryID: try categoryID(named: "Break"), toFace: ManualFace.first))

        events.closeSegmentsStrandedOnAppFaces()

        #expect(entryColumn("duration_seconds", forSegment: stranded) == "40.0")
        #expect(processed(stranded) == "1")
    }

    @Test func testADevicesOpenSegmentIsLeftAlone() {
        // A cube keeps timing whether this app is running or not, so its open segment is not stranded: it is
        // still being timed, and the duration the device reports will cover the time the app was closed.
        let cube = finishedSegment(face: 4, duration: 300, finalised: false)

        #expect(events.closeSegmentsStrandedOnAppFaces() == [])

        #expect(database.string("SELECT finalised FROM device_event WHERE device_event_id = \(cube);") == "0")
        #expect(database.string("SELECT COUNT(*) FROM time_entry;") == "0")
    }

    @Test func testEveryStrandedAppSegmentIsClosed() {
        // More than one open row is a fault in itself; a startup that fixed only the newest would leave the rest
        // to be found by the next close-out, having grown in the meantime.
        let first = finishedSegment(face: 13, duration: 10, finalised: false)
        let second = finishedSegment(face: 14, duration: 20, finalised: false)

        #expect(Set(events.closeSegmentsStrandedOnAppFaces()) == Set([first, second]))
        #expect(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;") == "0")
    }

    @Test func testAStartupWithNothingStrandedDoesNothing() {
        _ = finishedSegment(face: ManualFace.first, duration: 60)

        #expect(events.closeSegmentsStrandedOnAppFaces() == [], "the ordinary case, after a clean quit")
        #expect(database.string("SELECT COUNT(*) FROM time_entry;") == "0", "and nothing is re-counted")
    }

    // MARK: - the two modules together

    @Test func testClosingASegmentIsWhatRaisesTheQuestion() throws {
        // Nothing calls the time entry side directly here: recording and then closing a segment is all it takes.
        events.startSegment(face: ManualFace.first, at: moment)
        #expect(faces.assign(categoryID: try categoryID(named: "Break"), toFace: ManualFace.first))

        events.closeOpenSegment(at: moment.addingTimeInterval(300))

        #expect(database.string("SELECT COUNT(*) FROM time_entry;") == "1")
        #expect(database.string("SELECT duration_seconds FROM time_entry;") == "300.0")
    }

    @Test func testASwitchOfCategoryFilesTheFinishedStretchUnderTheCategoryItWasTimed() throws {
        // The race the pair of app faces exists to remove. Timing Break, then switching to Meeting: the closed
        // segment must be Break's, and it must stay Break's however late anything reads it.
        let breakID = try categoryID(named: "Break")
        let meetingID = try categoryID(named: "Meeting")

        let firstFace = ManualFace.next(after: events.latestFace(in: ManualFace.all))
        #expect(faces.assign(categoryID: breakID, toFace: firstFace))
        let first = try #require(events.startSegment(face: firstFace, at: moment))

        // The switch, in the order `SettingsWindowController.startTiming` does it.
        let switchedAt = moment.addingTimeInterval(600)
        let secondFace = ManualFace.next(after: events.latestFace(in: ManualFace.all))
        events.closeOpenSegment(at: switchedAt)
        #expect(faces.assign(categoryID: meetingID, toFace: secondFace))
        let second = try #require(events.startSegment(face: secondFace, at: switchedAt))

        #expect(secondFace != firstFace, "the new category goes on a different face")
        #expect(entryColumn("category_id", forSegment: first.deviceEventID) == "\(breakID)")
        #expect(entryColumn("duration_seconds", forSegment: first.deviceEventID) == "600.0")

        // And the face the finished segment named still holds Break, so re-asking now gives the same answer --
        // which is what makes a conversion that happens later than the close safe.
        #expect(faces.categoryID(forFace: firstFace) == breakID)
        events.closeOpenSegment(at: switchedAt.addingTimeInterval(60))
        #expect(entryColumn("category_id", forSegment: second.deviceEventID) == "\(meetingID)")
    }

    @Test func testResumingStaysOnTheSameFaceAndKeepsTheCategory() throws {
        let breakID = try categoryID(named: "Break")
        let face = ManualFace.next(after: events.latestFace(in: ManualFace.all))
        #expect(faces.assign(categoryID: breakID, toFace: face))
        events.startSegment(face: face, at: moment)

        // Pause, then resume: rotating exists to stop a face's category changing under a finished segment, and
        // resuming does not change it.
        events.closeOpenSegment(at: moment.addingTimeInterval(120))
        events.startSegment(face: events.latestFace(in: ManualFace.all) ?? face, at: moment.addingTimeInterval(180))
        events.closeOpenSegment(at: moment.addingTimeInterval(240))

        #expect(database.string("SELECT COUNT(DISTINCT device_face) FROM device_event;") == "1")
        #expect(database.string("SELECT COUNT(*) FROM time_entry WHERE category_id = \(breakID);") == "2", "two stretches of the same category, both counted")
        #expect(database.string("SELECT SUM(duration_seconds) FROM time_entry;") == "180.0")
    }
}

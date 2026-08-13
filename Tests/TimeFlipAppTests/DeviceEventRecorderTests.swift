@testable import TimeFlipApp
import Foundation
import XCTest

/// Covers `DeviceEventRecorder` against a real database built from the real DDL: the rows it writes, and what
/// recording one segment does to the rows already there.
///
/// `DeviceEventRulesTests` covers the decisions. This is about the writing carrying them out -- the columns
/// landing where they should, the close-out actually closing, and the pair being what identifies a segment
/// once a unique index has a say in it.
@MainActor
final class DeviceEventRecorderTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var recorder: DeviceEventRecorder!

    /// No fractional part, so `start_epoch` is exactly this.
    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        let connection = database.connection()
        recorder = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            debugLog: nil
        )
    }

    override func tearDown() {
        recorder = nil
        database.remove()
        super.tearDown()
    }

    private func segment(
        eventNumber: Int = 10,
        face: Int = 4,
        at offset: TimeInterval = 0,
        duration: TimeInterval = 30,
        isPaused: Bool = false
    ) -> DeviceEventSegment {
        DeviceEventSegment(
            eventNumber: eventNumber,
            face: face,
            startedAt: moment.addingTimeInterval(offset),
            durationSeconds: duration,
            isPaused: isPaused
        )
    }

    private func column(_ name: String, ofRow rowID: Int) -> String? {
        database.string("SELECT \(name) FROM device_event WHERE device_event_id = \(rowID);")
    }

    private var rowCount: String? {
        database.string("SELECT COUNT(*) FROM device_event;")
    }

    // MARK: - the row it writes

    func testEveryColumnComesFromTheSegment() throws {
        let outcome = try XCTUnwrap(recorder.record(segment(eventNumber: 7, face: 9, duration: 42)))

        XCTAssertEqual(column("event_number", ofRow: outcome.deviceEventID), "7")
        XCTAssertEqual(column("device_face", ofRow: outcome.deviceEventID), "9")
        XCTAssertEqual(column("duration_seconds", ofRow: outcome.deviceEventID), "42.0")
        XCTAssertEqual(column("start_epoch", ofRow: outcome.deviceEventID), "1786600000")
        XCTAssertEqual(column("paused", ofRow: outcome.deviceEventID), "0")
        XCTAssertEqual(column("finalised", ofRow: outcome.deviceEventID), "0", "the newest segment is the open one")
        XCTAssertEqual(
            column("processed", ofRow: outcome.deviceEventID), "0",
            "conversion is the time entry side's flag, and this module never touches it"
        )
    }

    func testTheEventTypeIsResolvedByNameFromTheReferenceTable() throws {
        let flip = try XCTUnwrap(recorder.record(segment(eventNumber: 1)))
        let pause = try XCTUnwrap(recorder.record(segment(eventNumber: 2, at: 60, isPaused: true)))

        // By name, so a renumbered seed cannot silently retype every event: 1 is face_flip, 2 is pause in
        // `001_event_type.sql`, and these assert the join rather than the numbers.
        XCTAssertEqual(
            database.string(
                "SELECT event_name FROM event_type JOIN device_event USING (event_type_id) "
                    + "WHERE device_event_id = \(flip.deviceEventID);"
            ),
            "face_flip"
        )
        XCTAssertEqual(
            database.string(
                "SELECT event_name FROM event_type JOIN device_event USING (event_type_id) "
                    + "WHERE device_event_id = \(pause.deviceEventID);"
            ),
            "pause"
        )
        XCTAssertEqual(column("paused", ofRow: pause.deviceEventID), "1")
    }

    func testTheStartTimeIsLocalWholeSecondsWithItsZoneAsAForeignKey() throws {
        let outcome = try XCTUnwrap(recorder.record(segment()))

        // The shape the previous app wrote, because its rows are still in the database this one opens.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(column("start_time", ofRow: outcome.deviceEventID), formatter.string(from: moment))

        // A real zone rather than the seeded Unknown fallback, resolved get-or-create by `TimezoneStore`.
        XCTAssertEqual(
            database.string(
                "SELECT timezone_name FROM timezone JOIN device_event USING (timezone_id) "
                    + "WHERE device_event_id = \(outcome.deviceEventID);"
            ),
            TimeZone.current.identifier
        )
    }

    func testAFaceTheTableRefusesIsReportedRatherThanReturnedAsARow() {
        // `CHECK (device_face BETWEEN 1 AND 13)`. Face 0 is a caller's mistake, and the point of the check is
        // that it cannot become a row -- so the report has to say so rather than hand back an id.
        XCTAssertNil(recorder.record(segment(face: 0)))
        XCTAssertEqual(rowCount, "0")
    }

    // MARK: - what it does to the rows already there

    func testANewerSegmentClosesTheOneThatWasOpen() throws {
        let first = try XCTUnwrap(recorder.record(segment(eventNumber: 10)))

        let second = try XCTUnwrap(recorder.record(segment(eventNumber: 11, at: 60)))

        XCTAssertEqual(second.closedRows, 1)
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1", "no longer what is happening")
        XCTAssertEqual(column("finalised", ofRow: second.deviceEventID), "0")
        XCTAssertTrue(second.isOpen)
        XCTAssertEqual(rowCount, "2")
    }

    func testOnlyOneRowIsEverOpen() throws {
        for index in 0 ..< 5 {
            _ = recorder.record(segment(eventNumber: 10 + index, at: TimeInterval(index) * 60))
        }

        XCTAssertEqual(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;"), "1")
        XCTAssertEqual(rowCount, "5")
    }

    func testARowStrandedOpenByAnEarlierFaultIsClosedToo() throws {
        // Two rows claiming to be live is the fault the previous app could leave behind. The close-out asks
        // "which rows are open?" rather than tracking which one should be, so an old stranding is swept up
        // by the next segment rather than needing a repair pass of its own.
        let first = try XCTUnwrap(recorder.record(segment(eventNumber: 10)))
        let second = try XCTUnwrap(recorder.record(segment(eventNumber: 11, at: 60)))
        XCTAssertTrue(database.execute("UPDATE device_event SET finalised = 0 WHERE device_event_id = \(first.deviceEventID);"))

        let third = try XCTUnwrap(recorder.record(segment(eventNumber: 12, at: 120)))

        XCTAssertEqual(third.closedRows, 2, "both the stranded row and the one that really was live")
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1")
        XCTAssertEqual(column("finalised", ofRow: second.deviceEventID), "1")
        XCTAssertEqual(column("finalised", ofRow: third.deviceEventID), "0")
    }

    func testASegmentArrivingOutOfOrderIsRecordedClosedAndLeavesTheLiveOneAlone() throws {
        let live = try XCTUnwrap(recorder.record(segment(eventNumber: 10, at: 60)))

        let late = try XCTUnwrap(recorder.record(segment(eventNumber: 9)))

        XCTAssertEqual(column("finalised", ofRow: late.deviceEventID), "1")
        XCTAssertEqual(late.closedRows, 0)
        XCTAssertFalse(late.isOpen)
        XCTAssertEqual(column("finalised", ofRow: live.deviceEventID), "0", "still the segment in progress")
    }

    func testASegmentTheTableRefusesLeavesTheLiveRowLive() throws {
        // Why the two statements are one transaction. Closing the open row comes first, so a refused insert
        // would otherwise leave a closed row where the live segment was and nothing live at all -- and no
        // later write can tell that from two ordinary finished segments.
        let live = try XCTUnwrap(recorder.record(segment(eventNumber: 10)))

        XCTAssertNil(recorder.record(segment(eventNumber: 11, face: 99, at: 60)))

        XCTAssertEqual(column("finalised", ofRow: live.deviceEventID), "0", "the close-out went back with the insert")
        XCTAssertEqual(rowCount, "1")
    }

    // MARK: - the same segment arriving again

    func testTheOpenSegmentGrowingUpdatesItsRowRatherThanAddingOne() throws {
        let first = try XCTUnwrap(recorder.record(segment(eventNumber: 10, duration: 30)))

        let again = try XCTUnwrap(recorder.record(segment(eventNumber: 10, duration: 95)))

        XCTAssertEqual(again.deviceEventID, first.deviceEventID)
        XCTAssertFalse(again.wasInserted)
        XCTAssertTrue(again.isOpen, "still the newest thing on record")
        XCTAssertEqual(column("duration_seconds", ofRow: first.deviceEventID), "95.0")
        XCTAssertEqual(rowCount, "1", "one segment, one row, however many times it is reported")
    }

    func testAFinishedSegmentBeingResentIsUpdatedWithoutBeingReopened() throws {
        let first = try XCTUnwrap(recorder.record(segment(eventNumber: 10, duration: 30)))
        let live = try XCTUnwrap(recorder.record(segment(eventNumber: 11, at: 60)))

        let resent = try XCTUnwrap(recorder.record(segment(eventNumber: 10, duration: 60)))

        XCTAssertEqual(resent.deviceEventID, first.deviceEventID)
        XCTAssertFalse(resent.isOpen)
        XCTAssertEqual(column("duration_seconds", ofRow: first.deviceEventID), "60.0", "the reporter's account wins")
        XCTAssertEqual(column("finalised", ofRow: live.deviceEventID), "0", "the live row is untouched by a re-send")
        XCTAssertEqual(rowCount, "2")
    }

    func testTwoSegmentsInOneSecondAreTwoRows() throws {
        // `start_epoch` alone is not identity: the epoch is whole seconds, and a quick flip across a face on
        // the way to another really does share one with what follows it.
        let first = try XCTUnwrap(recorder.record(segment(eventNumber: 72, duration: 0)))
        let second = try XCTUnwrap(recorder.record(segment(eventNumber: 73, duration: 0)))

        XCTAssertNotEqual(first.deviceEventID, second.deviceEventID)
        XCTAssertEqual(rowCount, "2")
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1", "the second one took over inside the same second")
        XCTAssertEqual(column("finalised", ofRow: second.deviceEventID), "0")
    }

    func testAReusedEventNumberAfterADeviceResetIsANewRow() throws {
        // `event_number` alone is not identity either: a reset restarts the counter, so a number already in
        // the table arrives again for a completely different segment. Matched on the pair, it inserts.
        let old = try XCTUnwrap(recorder.record(segment(eventNumber: 1)))

        let afterReset = try XCTUnwrap(recorder.record(segment(eventNumber: 1, at: 3_600)))

        XCTAssertNotEqual(afterReset.deviceEventID, old.deviceEventID)
        XCTAssertTrue(afterReset.wasInserted)
        XCTAssertTrue(afterReset.isOpen, "the epoch decides, so a low counter after a reset is still the newest")
    }

    // MARK: - segments the app is timing itself

    func testAStartedSegmentTakesTheUnixEpochAsItsEventNumber() throws {
        let outcome = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: moment))

        // What the previous app used: `MockTimeFlipDevice` seeded its counter from
        // `UInt32(now.timeIntervalSince1970)`, so the first number it handed out was the epoch second itself.
        XCTAssertEqual(column("event_number", ofRow: outcome.deviceEventID), "1786600000")
        XCTAssertEqual(column("start_epoch", ofRow: outcome.deviceEventID), "1786600000")
        XCTAssertEqual(column("device_face", ofRow: outcome.deviceEventID), "13")
        XCTAssertEqual(column("duration_seconds", ofRow: outcome.deviceEventID), "0.0", "it has only just begun")
        XCTAssertTrue(outcome.isOpen)
    }

    func testTwoSegmentsStartedInsideOneSecondAreTwoRows() throws {
        // The pair `(event_number, start_epoch)` is a row's identity, so reusing the epoch for both would have
        // made the second click silently overwrite the first. The number derives from the table, so the second
        // takes the next one up -- exactly what the old counter's increment did.
        let first = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: moment))
        let second = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: moment))

        XCTAssertNotEqual(second.deviceEventID, first.deviceEventID)
        XCTAssertEqual(column("event_number", ofRow: second.deviceEventID), "1786600001")
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1", "the second one took over")
        XCTAssertEqual(rowCount, "2")
    }

    func testTheEventNumberIsNotRememberedBetweenRecorders() throws {
        _ = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: moment))

        // A second recorder, standing in for the next launch: it allocates from the table, so it cannot hand
        // out a number an earlier launch already used.
        let connection = database.connection()
        let relaunched = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            debugLog: nil
        )
        let second = try XCTUnwrap(relaunched.startSegment(face: ManualFace.id, at: moment))

        XCTAssertEqual(column("event_number", ofRow: second.deviceEventID), "1786600001")
    }

    func testClosingTheOpenSegmentWorksOutHowLongItRan() throws {
        let started = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: moment))

        let closed = try XCTUnwrap(recorder.closeOpenSegment(at: moment.addingTimeInterval(95)))

        XCTAssertEqual(closed.deviceEventID, started.deviceEventID)
        XCTAssertFalse(closed.isOpen)
        XCTAssertEqual(closed.closedRows, 1)
        // The app is the reporter in manual mode, so nothing else can say how long the stretch ran.
        XCTAssertEqual(column("duration_seconds", ofRow: started.deviceEventID), "95.0")
        XCTAssertEqual(column("finalised", ofRow: started.deviceEventID), "1")
    }

    func testClosingWithNothingOpenIsNotAFailure() {
        XCTAssertNil(recorder.closeOpenSegment(at: moment), "the ordinary state of a first click")
        XCTAssertEqual(rowCount, "0")
    }

    func testAClockThatWentBackwardsClosesAtZeroRatherThanBeingRefused() throws {
        let started = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: moment))

        let closed = try XCTUnwrap(recorder.closeOpenSegment(at: moment.addingTimeInterval(-60)))

        // `CHECK (duration_seconds >= 0)` would refuse a negative, which would leave the row open for good.
        XCTAssertEqual(column("duration_seconds", ofRow: closed.deviceEventID), "0.0")
        XCTAssertEqual(column("finalised", ofRow: started.deviceEventID), "1")
    }

    func testASwitchOfCategoryIsOneClosedSegmentAndOneOpenOne() throws {
        // The click's own sequence, which is `SettingsWindowController.startTiming`: one moment for the whole
        // gesture, so the two segments meet rather than overlapping or leaving a gap nobody timed.
        let first = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: moment))
        let switchedAt = moment.addingTimeInterval(300)

        recorder.closeOpenSegment(at: switchedAt)
        let second = try XCTUnwrap(recorder.startSegment(face: ManualFace.id, at: switchedAt))

        XCTAssertEqual(column("duration_seconds", ofRow: first.deviceEventID), "300.0")
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1")
        XCTAssertEqual(column("start_epoch", ofRow: second.deviceEventID), "1786600300", "it begins where the other ended")
        XCTAssertEqual(column("finalised", ofRow: second.deviceEventID), "0")
        XCTAssertEqual(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;"), "1")
    }

    // MARK: - across a launch

    func testWhatIsOnRecordIsReadFromTheTableRatherThanRemembered() throws {
        let first = try XCTUnwrap(recorder.record(segment(eventNumber: 10)))

        // A second recorder on its own connection, standing in for the next launch: it has been told nothing
        // about what the first one wrote, which is the whole reason the high-water mark is a query.
        let connection = database.connection()
        let relaunched = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            debugLog: nil
        )

        let second = try XCTUnwrap(relaunched.record(segment(eventNumber: 11, at: 60)))

        XCTAssertEqual(second.closedRows, 1, "it found the open row without being told about it")
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1")
    }
}

@testable import FacetApp
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
            // nil, so these are about `device_event` alone: what closing a row means for tracked time is
            // `TimeEntryRecorderTests`, including the two of them together.
            timeEntries: nil,
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
        let outcome = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))

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
        let first = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))
        let second = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))

        XCTAssertNotEqual(second.deviceEventID, first.deviceEventID)
        XCTAssertEqual(column("event_number", ofRow: second.deviceEventID), "1786600001")
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1", "the second one took over")
        XCTAssertEqual(rowCount, "2")
    }

    func testTheEventNumberIsNotRememberedBetweenRecorders() throws {
        _ = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))

        // A second recorder, standing in for the next launch: it allocates from the table, so it cannot hand
        // out a number an earlier launch already used.
        let connection = database.connection()
        let relaunched = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            // nil, so these are about `device_event` alone: what closing a row means for tracked time is
            // `TimeEntryRecorderTests`, including the two of them together.
            timeEntries: nil,
            debugLog: nil
        )
        let second = try XCTUnwrap(relaunched.startSegment(face: ManualFace.first, at: moment))

        XCTAssertEqual(column("event_number", ofRow: second.deviceEventID), "1786600001")
    }

    func testClosingTheOpenSegmentWorksOutHowLongItRan() throws {
        let started = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))

        let closed = try XCTUnwrap(recorder.closeOpenSegment(at: moment.addingTimeInterval(95)))

        XCTAssertEqual(closed.deviceEventID, started.deviceEventID)
        XCTAssertFalse(closed.isOpen)
        XCTAssertEqual(closed.closedRows, 1)
        // The app is the reporter in manual mode, so nothing else can say how long the stretch ran.
        XCTAssertEqual(column("duration_seconds", ofRow: started.deviceEventID), "95.0")
        XCTAssertEqual(column("finalised", ofRow: started.deviceEventID), "1")
    }

    func testAClosedSegmentIsWholeSecondsAndEndsWhereTheNextOneStarts() throws {
        // Whole seconds because that is all the device can report, and the difference of the two stamps rather
        // than a rounding of the interval: the next segment's `start_epoch` truncates the same moment, so this
        // is what makes one segment end exactly where the next begins instead of overlapping it by a second.
        let started = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))
        let switchedAt = moment.addingTimeInterval(95.803)

        let closed = try XCTUnwrap(recorder.closeOpenSegment(at: switchedAt))
        let next = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: switchedAt))

        XCTAssertEqual(column("duration_seconds", ofRow: closed.deviceEventID), "95.0")
        let startEpoch = try XCTUnwrap(column("start_epoch", ofRow: started.deviceEventID).flatMap { Int($0) })
        XCTAssertEqual(
            column("start_epoch", ofRow: next.deviceEventID).flatMap { Int($0) }, startEpoch + 95,
            "the fraction is dropped once, not twice"
        )
    }

    func testAReportedDurationIsStoredWhole() throws {
        // A cube's frames carry integer seconds, so this is a source that is not one. Nearest, and the column
        // never holds a fraction whoever wrote it.
        let outcome = try XCTUnwrap(recorder.record(segment(duration: 41.6)))

        XCTAssertEqual(column("duration_seconds", ofRow: outcome.deviceEventID), "42.0")
    }

    func testRefreshingGrowsTheOpenSegmentWithoutClosingIt() throws {
        // What the history timer's timeout ends in: the same segment, running longer. One row, not one per
        // interval, because `record` recognises the identity read back off the row as the same event.
        let started = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))

        let first = try XCTUnwrap(recorder.refreshOpenSegment(at: moment.addingTimeInterval(10)))
        let second = try XCTUnwrap(recorder.refreshOpenSegment(at: moment.addingTimeInterval(20)))

        XCTAssertEqual(first.deviceEventID, started.deviceEventID)
        XCTAssertEqual(second.deviceEventID, started.deviceEventID)
        XCTAssertFalse(second.wasInserted)
        XCTAssertTrue(second.isOpen, "the segment is still what is happening")
        XCTAssertEqual(column("duration_seconds", ofRow: started.deviceEventID), "20.0")
        XCTAssertEqual(rowCount, "1")
    }

    func testRefreshingLeavesTheRestOfTheRowAsItWas() throws {
        let started = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))
        let before = column("start_time", ofRow: started.deviceEventID)

        recorder.refreshOpenSegment(at: moment.addingTimeInterval(45))

        XCTAssertEqual(column("event_number", ofRow: started.deviceEventID), "1786600000")
        XCTAssertEqual(column("device_face", ofRow: started.deviceEventID), "13")
        XCTAssertEqual(
            column("start_time", ofRow: started.deviceEventID), before,
            "the start is rebuilt from the row's own second, so it is written back unchanged"
        )
    }

    func testRefreshingWithNothingOpenDoesNothing() throws {
        // Every timeout while nothing is being timed, which is most of them.
        let closed = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))
        recorder.closeOpenSegment(at: moment.addingTimeInterval(30))

        XCTAssertNil(recorder.refreshOpenSegment(at: moment.addingTimeInterval(300)))

        XCTAssertEqual(column("duration_seconds", ofRow: closed.deviceEventID), "30.0", "a finished segment is finished")
        XCTAssertEqual(rowCount, "1")
    }

    func testRefreshingOnlyEverTouchesTheOpenSegment() throws {
        let finished = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))
        let switchedAt = moment.addingTimeInterval(60)
        recorder.closeOpenSegment(at: switchedAt)
        let live = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: switchedAt))

        recorder.refreshOpenSegment(at: switchedAt.addingTimeInterval(15))

        XCTAssertEqual(column("duration_seconds", ofRow: live.deviceEventID), "15.0")
        XCTAssertEqual(column("duration_seconds", ofRow: finished.deviceEventID), "60.0", "untouched")
    }

    func testClosingWithNothingOpenIsNotAFailure() {
        XCTAssertNil(recorder.closeOpenSegment(at: moment), "the ordinary state of a first click")
        XCTAssertEqual(rowCount, "0")
    }

    func testAClockThatWentBackwardsClosesAtZeroRatherThanBeingRefused() throws {
        let started = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))

        let closed = try XCTUnwrap(recorder.closeOpenSegment(at: moment.addingTimeInterval(-60)))

        // `CHECK (duration_seconds >= 0)` would refuse a negative, which would leave the row open for good.
        XCTAssertEqual(column("duration_seconds", ofRow: closed.deviceEventID), "0.0")
        XCTAssertEqual(column("finalised", ofRow: started.deviceEventID), "1")
    }

    func testASwitchOfCategoryIsOneClosedSegmentAndOneOpenOne() throws {
        // The click's own sequence, which is `SettingsWindowController.startTiming`: one moment for the whole
        // gesture, so the two segments meet rather than overlapping or leaving a gap nobody timed.
        let first = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: moment))
        let switchedAt = moment.addingTimeInterval(300)

        recorder.closeOpenSegment(at: switchedAt)
        let second = try XCTUnwrap(recorder.startSegment(face: ManualFace.first, at: switchedAt))

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
            // nil, so these are about `device_event` alone: what closing a row means for tracked time is
            // `TimeEntryRecorderTests`, including the two of them together.
            timeEntries: nil,
            debugLog: nil
        )

        let second = try XCTUnwrap(relaunched.record(segment(eventNumber: 11, at: 60)))

        XCTAssertEqual(second.closedRows, 1, "it found the open row without being told about it")
        XCTAssertEqual(column("finalised", ofRow: first.deviceEventID), "1")
    }
    // MARK: - where the app is up to, which is two different questions

    func testWithNoRowsAtAllBothMarksAreEmpty() {
        XCTAssertEqual(recorder.newestOnRecord(), .none)
        XCTAssertEqual(recorder.newestFromTheCube(), .none)
    }

    func testTheNewestRowIsTheNewestRowWhicheverFaceItIsOn() {
        // What `record` needs: whether an arriving segment supersedes what is open, over the whole table.
        recorder.record(segment(eventNumber: 4, face: 8, at: 0))
        recorder.startSegment(face: ManualFace.first, at: moment.addingTimeInterval(600))

        XCTAssertEqual(recorder.newestOnRecord().startEpoch, Int(moment.timeIntervalSince1970) + 600)
    }

    func testTheCubesPositionIgnoresTheAppsOwnSegments() {
        // **The bug this split exists for.** A manual segment carries the epoch as its event number, because nothing
        // issued it one -- so read the newest row of any kind and "where is the cube's history up to" is answered with
        // about 1.8 billion, a number no cube can reach. Every refresh then re-streams the lot and the cheap check can
        // never match.
        recorder.record(segment(eventNumber: 4, face: 8, at: 0))
        recorder.startSegment(face: ManualFace.first, at: moment.addingTimeInterval(600))

        let mark = recorder.newestFromTheCube()

        XCTAssertEqual(mark.eventNumber, 4)
        XCTAssertEqual(mark.startEpoch, Int(moment.timeIntervalSince1970))
    }

    func testTheCubesPositionIsEmptyWhileOnlyTheAppHasTimedAnything() {
        // A launch that has only ever timed by hand has no cube position at all, which is what sends the next fetch
        // back to the beginning rather than to a manual segment's epoch.
        recorder.startSegment(face: ManualFace.first, at: moment)

        XCTAssertEqual(recorder.newestFromTheCube(), .none)
        XCTAssertNotEqual(recorder.newestOnRecord(), .none)
    }

    func testTheHighestFaceACubeCanReportStillCounts() {
        // The boundary, so the filter cannot drift onto face 11 or 13 without a test noticing.
        recorder.record(segment(eventNumber: 7, face: ManualFace.highestDeviceFace, at: 0))

        XCTAssertEqual(recorder.newestFromTheCube().eventNumber, 7)
    }

    func testWithinOneSecondTheHigherEventNumberWins() {
        // Two segments sharing a second, which the previous app's production database holds several of. The pair is
        // what identifies a segment, so the mark has to name the later of the two rather than either.
        recorder.record(segment(eventNumber: 4, face: 8, at: 0))
        recorder.record(segment(eventNumber: 5, face: 8, at: 0))

        XCTAssertEqual(recorder.newestFromTheCube().eventNumber, 5)
    }

}

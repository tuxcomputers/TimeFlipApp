@testable import FacetCore
import Foundation
import Testing

/// Covers `DeviceEventRecorder` against a real database built from the real DDL: the rows it writes, and what
/// recording one segment does to the rows already there.
///
/// `DeviceEventRulesTests` covers the decisions. This is about the writing carrying them out -- the columns
/// landing where they should, the close-out actually closing, and the pair being what identifies a segment
/// once a unique index has a say in it.
@Suite @MainActor
final class DeviceEventRecorderTests {
    private let database: TemporaryDatabase
    private var recorder: DeviceEventRecorder!

    /// No fractional part, so `start_epoch` is exactly this.
    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    init() throws {
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

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored properties by hand
        // is what the old `MainActor.assumeIsolated` block was for; the instance is discarded whole here, so
        // removing the directory is all that is left. `database` is a `let` for the same reason -- a
        // non-isolated `deinit` may read that where it could not read a `@MainActor var`.
        database.remove()
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

    @Test func testEveryColumnComesFromTheSegment() throws {
        let outcome = try #require(recorder.record(segment(eventNumber: 7, face: 9, duration: 42)))

        #expect(column("event_number", ofRow: outcome.deviceEventID) == "7")
        #expect(column("device_face", ofRow: outcome.deviceEventID) == "9")
        #expect(column("duration_seconds", ofRow: outcome.deviceEventID) == "42.0")
        #expect(column("start_epoch", ofRow: outcome.deviceEventID) == "1786600000")
        #expect(column("paused", ofRow: outcome.deviceEventID) == "0")
        #expect(column("finalised", ofRow: outcome.deviceEventID) == "0", "the newest segment is the open one")
        #expect(column("processed", ofRow: outcome.deviceEventID) == "0", "conversion is the time entry side's flag, and this module never touches it")
    }

    @Test func testTheEventTypeIsResolvedByNameFromTheReferenceTable() throws {
        let flip = try #require(recorder.record(segment(eventNumber: 1)))
        let pause = try #require(recorder.record(segment(eventNumber: 2, at: 60, isPaused: true)))

        // By name, so a renumbered seed cannot silently retype every event: 1 is face_flip, 2 is pause in
        // `001_event_type.sql`, and these assert the join rather than the numbers.
        #expect(database.string(
                "SELECT event_name FROM event_type JOIN device_event USING (event_type_id) "
                    + "WHERE device_event_id = \(flip.deviceEventID);"
            ) == "face_flip")
        #expect(database.string(
                "SELECT event_name FROM event_type JOIN device_event USING (event_type_id) "
                    + "WHERE device_event_id = \(pause.deviceEventID);"
            ) == "pause")
        #expect(column("paused", ofRow: pause.deviceEventID) == "1")
    }

    @Test func testTheStartTimeIsLocalWholeSecondsWithItsZoneAsAForeignKey() throws {
        let outcome = try #require(recorder.record(segment()))

        // The shape the previous app wrote, because its rows are still in the database this one opens.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        #expect(column("start_time", ofRow: outcome.deviceEventID) == formatter.string(from: moment))

        // A real zone rather than the seeded Unknown fallback, resolved get-or-create by `TimezoneStore`.
        //
        // **Compared through `timezone_lookup` rather than against the raw identifier**, because the two are
        // different strings whenever the machine's zone is one of the 151 legacy aliases: a runner on `GMT`
        // stores the canonical `Etc/GMT`, and `Cuba` would store `America/Havana`. That is `TimezoneStore`
        // doing exactly what its doc comment says -- Foundation canonicalises none of them -- so it is not
        // something for this test to object to. `DebugLogTests` had it right and this did not.
        //
        // Found on 2026-09-09 by the first CI run this branch ever had: green on two machines in
        // Australia/Brisbane, red on a UTC runner, and reproducible anywhere with `TZ=GMT swift test`.
        let storedZone = database.string(
            "SELECT timezone_name FROM timezone JOIN device_event USING (timezone_id) "
                + "WHERE device_event_id = \(outcome.deviceEventID);"
        )
        #expect(storedZone != "Unknown", "the seeded fallback means the zone was never resolved at all")
        #expect(
            storedZone == database.string(
                "SELECT timezone_name FROM timezone WHERE timezone_id = "
                    + "(SELECT timezone_id FROM timezone_lookup "
                    + "WHERE timezone_name = '\(TimeZone.current.identifier)');"
            ),
            "the row should carry whatever canonical zone this machine's own zone resolves to"
        )
    }

    @Test func testAFaceTheTableRefusesIsReportedRatherThanReturnedAsARow() {
        // `CHECK (device_face BETWEEN 1 AND 13)`. Face 0 is a caller's mistake, and the point of the check is
        // that it cannot become a row -- so the report has to say so rather than hand back an id.
        #expect(recorder.record(segment(face: 0)) == nil)
        #expect(rowCount == "0")
    }

    // MARK: - what it does to the rows already there

    @Test func testANewerSegmentClosesTheOneThatWasOpen() throws {
        let first = try #require(recorder.record(segment(eventNumber: 10)))

        let second = try #require(recorder.record(segment(eventNumber: 11, at: 60)))

        #expect(second.closedRows == 1)
        #expect(column("finalised", ofRow: first.deviceEventID) == "1", "no longer what is happening")
        #expect(column("finalised", ofRow: second.deviceEventID) == "0")
        #expect(second.isOpen)
        #expect(rowCount == "2")
    }

    @Test func testOnlyOneRowIsEverOpen() throws {
        for index in 0 ..< 5 {
            _ = recorder.record(segment(eventNumber: 10 + index, at: TimeInterval(index) * 60))
        }

        #expect(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;") == "1")
        #expect(rowCount == "5")
    }

    @Test func testARowStrandedOpenByAnEarlierFaultIsClosedToo() throws {
        // Two rows claiming to be live is the fault the previous app could leave behind. The close-out asks
        // "which rows are open?" rather than tracking which one should be, so an old stranding is swept up
        // by the next segment rather than needing a repair pass of its own.
        let first = try #require(recorder.record(segment(eventNumber: 10)))
        let second = try #require(recorder.record(segment(eventNumber: 11, at: 60)))
        #expect(database.execute("UPDATE device_event SET finalised = 0 WHERE device_event_id = \(first.deviceEventID);"))

        let third = try #require(recorder.record(segment(eventNumber: 12, at: 120)))

        #expect(third.closedRows == 2, "both the stranded row and the one that really was live")
        #expect(column("finalised", ofRow: first.deviceEventID) == "1")
        #expect(column("finalised", ofRow: second.deviceEventID) == "1")
        #expect(column("finalised", ofRow: third.deviceEventID) == "0")
    }

    @Test func testASegmentArrivingOutOfOrderIsRecordedClosedAndLeavesTheLiveOneAlone() throws {
        let live = try #require(recorder.record(segment(eventNumber: 10, at: 60)))

        let late = try #require(recorder.record(segment(eventNumber: 9)))

        #expect(column("finalised", ofRow: late.deviceEventID) == "1")
        #expect(late.closedRows == 0)
        #expect(!late.isOpen)
        #expect(column("finalised", ofRow: live.deviceEventID) == "0", "still the segment in progress")
    }

    @Test func testASegmentTheTableRefusesLeavesTheLiveRowLive() throws {
        // Why the two statements are one transaction. Closing the open row comes first, so a refused insert
        // would otherwise leave a closed row where the live segment was and nothing live at all -- and no
        // later write can tell that from two ordinary finished segments.
        let live = try #require(recorder.record(segment(eventNumber: 10)))

        #expect(recorder.record(segment(eventNumber: 11, face: 99, at: 60)) == nil)

        #expect(column("finalised", ofRow: live.deviceEventID) == "0", "the close-out went back with the insert")
        #expect(rowCount == "1")
    }

    // MARK: - the same segment arriving again

    @Test func testTheOpenSegmentGrowingUpdatesItsRowRatherThanAddingOne() throws {
        let first = try #require(recorder.record(segment(eventNumber: 10, duration: 30)))

        let again = try #require(recorder.record(segment(eventNumber: 10, duration: 95)))

        #expect(again.deviceEventID == first.deviceEventID)
        #expect(!again.wasInserted)
        #expect(again.isOpen, "still the newest thing on record")
        #expect(column("duration_seconds", ofRow: first.deviceEventID) == "95.0")
        #expect(rowCount == "1", "one segment, one row, however many times it is reported")
    }

    @Test func testAFinishedSegmentBeingResentIsUpdatedWithoutBeingReopened() throws {
        let first = try #require(recorder.record(segment(eventNumber: 10, duration: 30)))
        let live = try #require(recorder.record(segment(eventNumber: 11, at: 60)))

        let resent = try #require(recorder.record(segment(eventNumber: 10, duration: 60)))

        #expect(resent.deviceEventID == first.deviceEventID)
        #expect(!resent.isOpen)
        #expect(column("duration_seconds", ofRow: first.deviceEventID) == "60.0", "the reporter's account wins")
        #expect(column("finalised", ofRow: live.deviceEventID) == "0", "the live row is untouched by a re-send")
        #expect(rowCount == "2")
    }

    @Test func testTwoSegmentsInOneSecondAreTwoRows() throws {
        // `start_epoch` alone is not identity: the epoch is whole seconds, and a quick flip across a face on
        // the way to another really does share one with what follows it.
        let first = try #require(recorder.record(segment(eventNumber: 72, duration: 0)))
        let second = try #require(recorder.record(segment(eventNumber: 73, duration: 0)))

        #expect(first.deviceEventID != second.deviceEventID)
        #expect(rowCount == "2")
        #expect(column("finalised", ofRow: first.deviceEventID) == "1", "the second one took over inside the same second")
        #expect(column("finalised", ofRow: second.deviceEventID) == "0")
    }

    @Test func testAReusedEventNumberAfterADeviceResetIsANewRow() throws {
        // `event_number` alone is not identity either: a reset restarts the counter, so a number already in
        // the table arrives again for a completely different segment. Matched on the pair, it inserts.
        let old = try #require(recorder.record(segment(eventNumber: 1)))

        let afterReset = try #require(recorder.record(segment(eventNumber: 1, at: 3_600)))

        #expect(afterReset.deviceEventID != old.deviceEventID)
        #expect(afterReset.wasInserted)
        #expect(afterReset.isOpen, "the epoch decides, so a low counter after a reset is still the newest")
    }

    // MARK: - segments the app is timing itself

    @Test func testAStartedSegmentTakesTheUnixEpochAsItsEventNumber() throws {
        let outcome = try #require(recorder.startSegment(face: ManualFace.first, at: moment))

        // What the previous app used: `MockTimeFlipDevice` seeded its counter from
        // `UInt32(now.timeIntervalSince1970)`, so the first number it handed out was the epoch second itself.
        #expect(column("event_number", ofRow: outcome.deviceEventID) == "1786600000")
        #expect(column("start_epoch", ofRow: outcome.deviceEventID) == "1786600000")
        #expect(column("device_face", ofRow: outcome.deviceEventID) == "13")
        #expect(column("duration_seconds", ofRow: outcome.deviceEventID) == "0.0", "it has only just begun")
        #expect(outcome.isOpen)
    }

    @Test func testTwoSegmentsStartedInsideOneSecondAreTwoRows() throws {
        // The pair `(event_number, start_epoch)` is a row's identity, so reusing the epoch for both would have
        // made the second click silently overwrite the first. The number derives from the table, so the second
        // takes the next one up -- exactly what the old counter's increment did.
        let first = try #require(recorder.startSegment(face: ManualFace.first, at: moment))
        let second = try #require(recorder.startSegment(face: ManualFace.first, at: moment))

        #expect(second.deviceEventID != first.deviceEventID)
        #expect(column("event_number", ofRow: second.deviceEventID) == "1786600001")
        #expect(column("finalised", ofRow: first.deviceEventID) == "1", "the second one took over")
        #expect(rowCount == "2")
    }

    @Test func testTheEventNumberIsNotRememberedBetweenRecorders() throws {
        _ = try #require(recorder.startSegment(face: ManualFace.first, at: moment))

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
        let second = try #require(relaunched.startSegment(face: ManualFace.first, at: moment))

        #expect(column("event_number", ofRow: second.deviceEventID) == "1786600001")
    }

    @Test func testClosingTheOpenSegmentWorksOutHowLongItRan() throws {
        let started = try #require(recorder.startSegment(face: ManualFace.first, at: moment))

        let closed = try #require(recorder.closeOpenSegment(at: moment.addingTimeInterval(95)))

        #expect(closed.deviceEventID == started.deviceEventID)
        #expect(!closed.isOpen)
        #expect(closed.closedRows == 1)
        // The app is the reporter in manual mode, so nothing else can say how long the stretch ran.
        #expect(column("duration_seconds", ofRow: started.deviceEventID) == "95.0")
        #expect(column("finalised", ofRow: started.deviceEventID) == "1")
    }

    @Test func testAClosedSegmentIsWholeSecondsAndEndsWhereTheNextOneStarts() throws {
        // Whole seconds because that is all the device can report, and the difference of the two stamps rather
        // than a rounding of the interval: the next segment's `start_epoch` truncates the same moment, so this
        // is what makes one segment end exactly where the next begins instead of overlapping it by a second.
        let started = try #require(recorder.startSegment(face: ManualFace.first, at: moment))
        let switchedAt = moment.addingTimeInterval(95.803)

        let closed = try #require(recorder.closeOpenSegment(at: switchedAt))
        let next = try #require(recorder.startSegment(face: ManualFace.first, at: switchedAt))

        #expect(column("duration_seconds", ofRow: closed.deviceEventID) == "95.0")
        let startEpoch = try #require(column("start_epoch", ofRow: started.deviceEventID).flatMap { Int($0) })
        #expect(column("start_epoch", ofRow: next.deviceEventID).flatMap { Int($0) } == startEpoch + 95, "the fraction is dropped once, not twice")
    }

    @Test func testAReportedDurationIsStoredWhole() throws {
        // A cube's frames carry integer seconds, so this is a source that is not one. Nearest, and the column
        // never holds a fraction whoever wrote it.
        let outcome = try #require(recorder.record(segment(duration: 41.6)))

        #expect(column("duration_seconds", ofRow: outcome.deviceEventID) == "42.0")
    }

    @Test func testRefreshingGrowsTheOpenSegmentWithoutClosingIt() throws {
        // What the history timer's timeout ends in: the same segment, running longer. One row, not one per
        // interval, because `record` recognises the identity read back off the row as the same event.
        let started = try #require(recorder.startSegment(face: ManualFace.first, at: moment))

        let first = try #require(recorder.refreshOpenSegment(at: moment.addingTimeInterval(10)))
        let second = try #require(recorder.refreshOpenSegment(at: moment.addingTimeInterval(20)))

        #expect(first.deviceEventID == started.deviceEventID)
        #expect(second.deviceEventID == started.deviceEventID)
        #expect(!second.wasInserted)
        #expect(second.isOpen, "the segment is still what is happening")
        #expect(column("duration_seconds", ofRow: started.deviceEventID) == "20.0")
        #expect(rowCount == "1")
    }

    @Test func testRefreshingLeavesTheRestOfTheRowAsItWas() throws {
        let started = try #require(recorder.startSegment(face: ManualFace.first, at: moment))
        let before = column("start_time", ofRow: started.deviceEventID)

        recorder.refreshOpenSegment(at: moment.addingTimeInterval(45))

        #expect(column("event_number", ofRow: started.deviceEventID) == "1786600000")
        #expect(column("device_face", ofRow: started.deviceEventID) == "13")
        #expect(column("start_time", ofRow: started.deviceEventID) == before, "the start is rebuilt from the row's own second, so it is written back unchanged")
    }

    @Test func testRefreshingWithNothingOpenDoesNothing() throws {
        // Every timeout while nothing is being timed, which is most of them.
        let closed = try #require(recorder.startSegment(face: ManualFace.first, at: moment))
        recorder.closeOpenSegment(at: moment.addingTimeInterval(30))

        #expect(recorder.refreshOpenSegment(at: moment.addingTimeInterval(300)) == nil)

        #expect(column("duration_seconds", ofRow: closed.deviceEventID) == "30.0", "a finished segment is finished")
        #expect(rowCount == "1")
    }

    @Test func testRefreshingOnlyEverTouchesTheOpenSegment() throws {
        let finished = try #require(recorder.startSegment(face: ManualFace.first, at: moment))
        let switchedAt = moment.addingTimeInterval(60)
        recorder.closeOpenSegment(at: switchedAt)
        let live = try #require(recorder.startSegment(face: ManualFace.first, at: switchedAt))

        recorder.refreshOpenSegment(at: switchedAt.addingTimeInterval(15))

        #expect(column("duration_seconds", ofRow: live.deviceEventID) == "15.0")
        #expect(column("duration_seconds", ofRow: finished.deviceEventID) == "60.0", "untouched")
    }

    @Test func testRefreshingLeavesACubesOwnSegmentAlone() throws {
        // **`duration_seconds` on a cube's row is the history's to write and nobody else's.** The same tick that
        // fires this asks the cube for its history, and what comes back is the device's own measurement of the
        // stretch; growing the row from this machine's clock first would overwrite that with a guess, and the two
        // part company the moment the cube has been paused, locked, or timing while the app was shut.
        let live = try #require(recorder.record(
                DeviceEventSegment(eventNumber: 9, face: 3, startedAt: moment, durationSeconds: 40, isPaused: false)
            ))
        #expect(live.isOpen, "precondition: the cube is timing")

        #expect(recorder.refreshOpenSegment(at: moment.addingTimeInterval(600)) == nil)

        #expect(column("duration_seconds", ofRow: live.deviceEventID) == "40.0", "what the cube last reported")
        #expect(column("finalised", ofRow: live.deviceEventID) == "0", "and still open")
    }

    @Test func testClosingLeavesACubesOwnSegmentAlone() throws {
        // The quit sequence closes whatever is open on its way out, which is right for a segment this app is
        // measuring and wrong for one the cube is: it wrote a wall-clock duration over the device's own figure,
        // finalised the row, and handed the stretch on as tracked time -- while the cube went on timing that face.
        let live = try #require(recorder.record(
                DeviceEventSegment(eventNumber: 9, face: 3, startedAt: moment, durationSeconds: 40, isPaused: false)
            ))

        #expect(recorder.closeOpenSegment(at: moment.addingTimeInterval(600)) == nil)

        #expect(column("duration_seconds", ofRow: live.deviceEventID) == "40.0")
        #expect(column("finalised", ofRow: live.deviceEventID) == "0")
    }

    @Test func testClosingWithNothingOpenIsNotAFailure() {
        #expect(recorder.closeOpenSegment(at: moment) == nil, "the ordinary state of a first click")
        #expect(rowCount == "0")
    }

    @Test func testAClockThatWentBackwardsClosesAtZeroRatherThanBeingRefused() throws {
        let started = try #require(recorder.startSegment(face: ManualFace.first, at: moment))

        let closed = try #require(recorder.closeOpenSegment(at: moment.addingTimeInterval(-60)))

        // `CHECK (duration_seconds >= 0)` would refuse a negative, which would leave the row open for good.
        #expect(column("duration_seconds", ofRow: closed.deviceEventID) == "0.0")
        #expect(column("finalised", ofRow: started.deviceEventID) == "1")
    }

    @Test func testASwitchOfCategoryIsOneClosedSegmentAndOneOpenOne() throws {
        // The click's own sequence, which is `SettingsWindowController.startTiming`: one moment for the whole
        // gesture, so the two segments meet rather than overlapping or leaving a gap nobody timed.
        let first = try #require(recorder.startSegment(face: ManualFace.first, at: moment))
        let switchedAt = moment.addingTimeInterval(300)

        recorder.closeOpenSegment(at: switchedAt)
        let second = try #require(recorder.startSegment(face: ManualFace.first, at: switchedAt))

        #expect(column("duration_seconds", ofRow: first.deviceEventID) == "300.0")
        #expect(column("finalised", ofRow: first.deviceEventID) == "1")
        #expect(column("start_epoch", ofRow: second.deviceEventID) == "1786600300", "it begins where the other ended")
        #expect(column("finalised", ofRow: second.deviceEventID) == "0")
        #expect(database.string("SELECT COUNT(*) FROM device_event WHERE finalised = 0;") == "1")
    }

    // MARK: - across a launch

    @Test func testWhatIsOnRecordIsReadFromTheTableRatherThanRemembered() throws {
        let first = try #require(recorder.record(segment(eventNumber: 10)))

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

        let second = try #require(relaunched.record(segment(eventNumber: 11, at: 60)))

        #expect(second.closedRows == 1, "it found the open row without being told about it")
        #expect(column("finalised", ofRow: first.deviceEventID) == "1")
    }
    // MARK: - where the app is up to, which is two different questions

    @Test func testWithNoRowsAtAllBothMarksAreEmpty() {
        #expect(recorder.newestOnRecord() == .none)
        #expect(recorder.newestFromTheCube() == .none)
    }

    @Test func testTheNewestRowIsTheNewestRowWhicheverFaceItIsOn() {
        // What `record` needs: whether an arriving segment supersedes what is open, over the whole table.
        recorder.record(segment(eventNumber: 4, face: 8, at: 0))
        recorder.startSegment(face: ManualFace.first, at: moment.addingTimeInterval(600))

        #expect(recorder.newestOnRecord().startEpoch == Int(moment.timeIntervalSince1970) + 600)
    }

    @Test func testTheCubesPositionIgnoresTheAppsOwnSegments() {
        // **The bug this split exists for.** A manual segment carries the epoch as its event number, because nothing
        // issued it one -- so read the newest row of any kind and "where is the cube's history up to" is answered with
        // about 1.8 billion, a number no cube can reach. Every refresh then re-streams the lot and the cheap check can
        // never match.
        recorder.record(segment(eventNumber: 4, face: 8, at: 0))
        recorder.startSegment(face: ManualFace.first, at: moment.addingTimeInterval(600))

        let mark = recorder.newestFromTheCube()

        #expect(mark.eventNumber == 4)
        #expect(mark.startEpoch == Int(moment.timeIntervalSince1970))
    }

    @Test func testTheCubesPositionIsEmptyWhileOnlyTheAppHasTimedAnything() {
        // A launch that has only ever timed by hand has no cube position at all, which is what sends the next fetch
        // back to the beginning rather than to a manual segment's epoch.
        recorder.startSegment(face: ManualFace.first, at: moment)

        #expect(recorder.newestFromTheCube() == .none)
        #expect(recorder.newestOnRecord() != .none)
    }

    @Test func testTheHighestFaceACubeCanReportStillCounts() {
        // The boundary, so the filter cannot drift onto face 11 or 13 without a test noticing.
        recorder.record(segment(eventNumber: 7, face: ManualFace.highestDeviceFace, at: 0))

        #expect(recorder.newestFromTheCube().eventNumber == 7)
    }

    @Test func testWithinOneSecondTheHigherEventNumberWins() {
        // Two segments sharing a second, which the previous app's production database holds several of. The pair is
        // what identifies a segment, so the mark has to name the later of the two rather than either.
        recorder.record(segment(eventNumber: 4, face: 8, at: 0))
        recorder.record(segment(eventNumber: 5, face: 8, at: 0))

        #expect(recorder.newestFromTheCube().eventNumber == 5)
    }

}

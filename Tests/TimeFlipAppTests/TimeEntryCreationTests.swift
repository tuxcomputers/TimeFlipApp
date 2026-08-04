@testable import TimeFlipApp
import SQLite3
import XCTest

/// Covers `AppDataStore.createTimeEntriesForFinalisedEvents`, which runs at the end of every
/// `recordDeviceEvent` and turns finalised, unpaused, unconverted segments into `time_entry` rows.
///
/// Written against the real database rather than a stub because what is being tested is largely
/// SQL: a join to `face` for the category, arithmetic for `ended_at`, and the interaction with
/// `UN1_time_entry`. A fake store would only test the fake.
@MainActor
final class TimeEntryCreationTests: XCTestCase {
    private var databaseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        databaseURL = AppDataStore.testDatabaseURL()
        AppDataStore.resetForTests(at: databaseURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - reading back

    private struct Entry {
        let categoryName: String
        let deviceEventID: Int64
        let startedAt: String
        let endedAt: String
        let duration: Double
    }

    private func entries() -> [Entry] {
        var rows: [Entry] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return rows
        }
        let sql = """
        SELECT c.category_name, te.device_event_id, te.started_at, te.ended_at, te.duration_seconds
        FROM time_entry te
        JOIN category c ON c.category_id = te.category_id
        ORDER BY te.time_entry_id;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Entry(
                    categoryName: String(cString: sqlite3_column_text(stmt, 0)),
                    deviceEventID: sqlite3_column_int64(stmt, 1),
                    startedAt: String(cString: sqlite3_column_text(stmt, 2)),
                    endedAt: String(cString: sqlite3_column_text(stmt, 3)),
                    duration: sqlite3_column_double(stmt, 4)
                ))
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return rows
    }

    private func scalar(_ sql: String) -> Int64 {
        var value: Int64 = -1
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return value
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            value = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return value
    }

    /// Face 2 is seeded to `Meeting` and face 8 to `Break` (`database/008_face.sql`), which is what
    /// lets these tests assert a category name rather than just "some category".
    private func record(_ store: AppDataStore, event: UInt32, face: UInt8, at epoch: TimeInterval, duration: TimeInterval, paused: Bool = false) {
        store.recordDeviceEvent(
            eventNumber: event,
            deviceFace: face,
            startedAt: Date(timeIntervalSince1970: epoch),
            durationSeconds: duration,
            isPaused: paused
        )
    }

    // MARK: - the conversion itself

    func testAFinalisedSegmentBecomesATimeEntryAgainstItsFacesCategory() {
        let store = AppDataStore(databaseURL: databaseURL)
        // The first event is the live segment and stays open. The second closes it out, and it is
        // that close-out -- not the insert -- that makes the first one convertible.
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        XCTAssertTrue(entries().isEmpty, "the newest segment is still open, so nothing to record yet")

        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)

        let rows = entries()
        XCTAssertEqual(rows.count, 1, "only the closed-out segment converts; the new one is now the open live frame")
        XCTAssertEqual(rows.first?.categoryName, "Meeting", "face 2 is seeded to Meeting")
        XCTAssertEqual(rows.first?.duration, 600)
    }

    func testEndedAtIsStartPlusDuration() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 2, at: 1_700_000_600, duration: 60)

        let row = entries().first
        // Both are local time with no offset, per database/CLAUDE.md, so they can be compared to
        // each other directly -- 600 seconds apart whatever zone the test machine is in.
        XCTAssertEqual(
            secondsBetween(row?.startedAt, row?.endedAt), 600,
            "ended_at should be started_at + duration_seconds"
        )
    }

    func testAPausedSegmentNeverBecomesATimeEntry() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600, paused: true)
        record(store, event: 2, face: 2, at: 1_700_000_600, duration: 60)
        record(store, event: 3, face: 8, at: 1_700_000_660, duration: 60)

        let rows = entries()
        XCTAssertEqual(rows.count, 1, "the pause is not tracked time; only the face_flip converts")
        XCTAssertEqual(rows.first?.duration, 60)
        // processed means "has a time entry", so a pause keeps 0 rather than being marked dealt with.
        XCTAssertEqual(
            scalar("SELECT processed FROM device_event WHERE event_number = 1;"), 0,
            "a paused segment is left unprocessed, because it will never have an entry to point at"
        )
    }

    func testConvertedSegmentsAreMarkedProcessed() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)

        XCTAssertEqual(scalar("SELECT processed FROM device_event WHERE event_number = 1;"), 1)
        XCTAssertEqual(
            scalar("SELECT processed FROM device_event WHERE event_number = 2;"), 0,
            "still the open live segment, so nothing has been done with it yet"
        )
    }

    func testRunningAgainCreatesNothingFurther() {
        // The conversion runs on every recordDeviceEvent, so it re-examines the same rows
        // constantly. A second pass producing a second entry would double every day's totals.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        XCTAssertEqual(entries().count, 1)

        // Re-ingesting the same two segments, which is what a repeated history fetch does.
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        record(store, event: 3, face: 2, at: 1_700_000_900, duration: 120)

        let rows = entries()
        XCTAssertEqual(rows.count, 2, "one per closed-out segment, no matter how often they are re-ingested")
        XCTAssertEqual(Set(rows.map(\.deviceEventID)).count, 2, "and never two entries for one event")
    }

    func testAnEntryOrphanedByAMissedProcessedUpdateIsRepairedRatherThanDuplicated() {
        // The insert and the processed update are two statements with no transaction around them.
        // A crash in between leaves an entry whose event still reads processed = 0; the next run
        // must mark it rather than try to insert a second entry (which UN1_time_entry would reject
        // and take the whole statement down with it).
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        XCTAssertEqual(entries().count, 1)

        execute("UPDATE device_event SET processed = 0 WHERE event_number = 1;")
        XCTAssertEqual(scalar("SELECT processed FROM device_event WHERE event_number = 1;"), 0)

        record(store, event: 3, face: 2, at: 1_700_000_900, duration: 120)

        XCTAssertEqual(entries().count, 2, "the orphan is not duplicated")
        XCTAssertEqual(
            scalar("SELECT processed FROM device_event WHERE event_number = 1;"), 1,
            "and its flag is put back rather than left wrong forever"
        )
    }

    func testTheCheckIsStampedEvenWhenNothingConverts() {
        // time_entry_check answers "is this running at all?", which a stamp written only on success
        // could not: a sweep that found nothing looks identical to one that never ran.
        let store = AppDataStore(databaseURL: databaseURL)
        execute("UPDATE setting SET setting_value = json_set(setting_value, '$.last_check', '2000-01-01T00:00:00') WHERE setting_name = 'time_entry_check';")

        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        XCTAssertTrue(entries().isEmpty, "the only segment is still open")

        XCTAssertNotEqual(
            stringScalar("SELECT json_extract(setting_value, '$.last_check') FROM setting WHERE setting_name = 'time_entry_check';"),
            "2000-01-01T00:00:00",
            "the check ran, so it should say so even though it created nothing"
        )
    }

    // MARK: - blips

    private func setBlipTime(_ seconds: Int) {
        execute("UPDATE setting SET setting_value = json_set(setting_value, '$.seconds', \(seconds)) WHERE setting_name = 'blip_time';")
    }

    func testASegmentShorterThanBlipTimeGetsNoEntryAndIsMarkedProcessed() {
        // Turning the cube to the face you want drags it across the others and the device reports
        // each pass-over as a real segment. Marking it processed is what keeps it out of every later
        // pass; leaving it unprocessed would grow a permanent tail of rows nothing can ever resolve.
        let store = AppDataStore(databaseURL: databaseURL)
        setBlipTime(5)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 2)
        record(store, event: 2, face: 8, at: 1_700_000_002, duration: 300)

        XCTAssertTrue(entries().isEmpty, "a 2 second pass-over is not time spent on that face")
        XCTAssertEqual(
            scalar("SELECT processed FROM device_event WHERE event_number = 1;"), 1,
            "and it is marked dealt with, so it stops being re-examined"
        )
    }

    func testASegmentExactlyAtBlipTimeIsKept() {
        // The label reads "ignore flips under N", so N itself is not under N. Worth pinning: an
        // off-by-one here silently discards a whole second of real activity at the boundary.
        let store = AppDataStore(databaseURL: databaseURL)
        setBlipTime(5)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 5)
        record(store, event: 2, face: 8, at: 1_700_000_005, duration: 300)

        XCTAssertEqual(entries().count, 1)
        XCTAssertEqual(entries().first?.duration, 5)
    }

    func testZeroBlipTimeConvertsEverything() {
        // 0 is the off switch, the same way auto_pause_minutes uses it. A zero-length segment is the
        // real test: with the filter off even that has to become an entry.
        let store = AppDataStore(databaseURL: databaseURL)
        setBlipTime(0)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 0)
        record(store, event: 2, face: 8, at: 1_700_000_001, duration: 300)

        XCTAssertEqual(entries().count, 1, "nothing is shorter than zero, so nothing is filtered")
        XCTAssertEqual(entries().first?.duration, 0)
    }

    func testASkippedBlipIsNotReportedAsABrokenRecord() {
        // The collision this design has to avoid. A skipped blip is processed = 1 with no entry,
        // which is exactly the shape of the defect the sweep hunts for -- so the blip test has to
        // come first, or every pass-over would be reported as data corruption.
        let store = AppDataStore(databaseURL: databaseURL)
        setBlipTime(5)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 2)
        record(store, event: 2, face: 8, at: 1_700_000_002, duration: 300)

        withAppStyleLogSink(store) {
            XCTAssertEqual(store.sweepTimeEntries(trigger: .launch), 0, "nothing to convert, nothing to repair")
        }
        XCTAssertEqual(
            scalar("SELECT COUNT(*) FROM debug_log WHERE message LIKE '%REPAIRED%';"), 0,
            "a blip is not a broken record"
        )
    }

    func testLoweringBlipTimeConvertsPreviouslySkippedSegments() {
        // Skipped blips stay NOT IN time_entry, and the sweep ignores processed, so a lower
        // threshold picks them up with no migration. That is the whole reason for filtering at the
        // entry rather than refusing to record the device_event: the data is still there.
        let store = AppDataStore(databaseURL: databaseURL)
        setBlipTime(5)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 4)
        record(store, event: 2, face: 8, at: 1_700_000_004, duration: 300)
        XCTAssertTrue(entries().isEmpty)

        setBlipTime(3)
        XCTAssertEqual(store.sweepTimeEntries(trigger: .launch), 1)
        XCTAssertEqual(entries().first?.duration, 4)
    }

    // MARK: - the sweep, which is a different job

    func testTheSweepFindsAnEventMarkedProcessedThatHasNoEntry() {
        // The defect the sweep exists for. The normal path scopes itself to processed = 0 so it can
        // run on every event for almost nothing, which means a row wrongly marked done is invisible
        // to it -- permanently, and with its time missing from every total, and with nothing
        // anywhere reporting it. Only a pass that ignores the flag can find one.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        XCTAssertEqual(entries().count, 1)

        // Event 1 lied about: flag set, entry deleted. Exactly the state a half-finished write or a
        // botched hand-edit would leave.
        execute("DELETE FROM time_entry;")
        execute("UPDATE device_event SET processed = 1 WHERE event_number = 1;")

        XCTAssertEqual(store.sweepTimeEntries(trigger: .launch), 1, "the sweep should find and convert it")
        XCTAssertEqual(entries().first?.duration, 600)
    }

    func testTheNormalPathCannotSeeThatBrokenRecord() {
        // The other half of the pair above: proving the scoping really is what hides it, so the
        // sweep is answering a real gap rather than duplicating work already done.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        execute("DELETE FROM time_entry;")
        execute("UPDATE device_event SET processed = 1 WHERE event_number = 1;")

        // recordDeviceEvent runs the processed = 0 path, and event 1 is not in it.
        record(store, event: 3, face: 2, at: 1_700_000_900, duration: 120)

        let converted = entries().map(\.duration)
        XCTAssertFalse(converted.contains(600), "the normal path trusts the flag, so it skips the broken row")
        XCTAssertTrue(converted.contains(300), "while still converting the segment that just closed out")
    }

    // MARK: - logging must not happen while the store's queue is held

    /// Regression test for a crash on launch (2026-08-03, exit status 5).
    ///
    /// `DeveloperMode.debugPrint` runs `logSink`, the app points `logSink` at
    /// `AppDataStore.recordDebugLog`, and that takes the store's serial queue. So a `debugPrint`
    /// issued from inside `queue.sync` re-enters a serial queue and traps. The conversion did
    /// exactly that, and died on the first entry it created against a real database.
    ///
    /// Every other test here missed it because `logSink` is only wired in
    /// `applicationDidFinishLaunching`, so under `swift test` it is nil and `debugPrint` never
    /// reaches the database. Twelve passing tests and a crash on the first real launch. These two
    /// wire the sink the way the app does, which is the only thing that makes the hazard reachable.
    private func withAppStyleLogSink(_ store: AppDataStore, _ body: () -> Void) {
        let previousSink = DeveloperMode.logSink
        let previousDebugSetting = DeveloperMode.isDebugSettingEnabled
        DeveloperMode.isDebugSettingEnabled = true
        DeveloperMode.logSink = { [weak store] tag, message in
            store?.recordDebugLog(tag: tag.rawValue, message: message)
        }
        defer {
            DeveloperMode.logSink = previousSink
            DeveloperMode.isDebugSettingEnabled = previousDebugSetting
        }
        body()
    }

    func testConvertingWithTheAppsLogSinkAttachedDoesNotDeadlock() {
        let store = AppDataStore(databaseURL: databaseURL)
        withAppStyleLogSink(store) {
            record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
            record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        }
        XCTAssertEqual(entries().count, 1, "reaching this line at all is most of the test")
        XCTAssertGreaterThan(
            scalar("SELECT COUNT(*) FROM debug_log WHERE tag = 'time-entry';"), 0,
            "and the message really did go through the sink, so the hazard was genuinely exercised"
        )
    }

    func testSweepingWithTheAppsLogSinkAttachedDoesNotDeadlock() {
        // The launch path specifically: sweepTimeEntries runs straight after the sink is wired in
        // applicationDidFinishLaunching, which is where the crash actually happened.
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        execute("DELETE FROM time_entry;")
        execute("UPDATE device_event SET processed = 1;")

        withAppStyleLogSink(store) {
            XCTAssertEqual(store.sweepTimeEntries(trigger: .launch), 1)
        }
        XCTAssertGreaterThan(
            scalar("SELECT COUNT(*) FROM debug_log WHERE tag = 'time-entry' AND message LIKE '%REPAIRED%';"), 0,
            "the repair line is the one the crashing launch was mid-way through writing"
        )
    }

    // MARK: - the face-remap trigger

    /// Two closed-out segments on different faces, plus a third left open as the live frame.
    /// Durations are distinct so an entry can be identified by the segment it came from:
    /// 600s on face 2 (`Meeting`), 300s on face 8 (`Break`), 120s still running on face 2.
    private func recordTwoClosedSegments(_ store: AppDataStore) {
        record(store, event: 1, face: 2, at: 1_700_000_000, duration: 600)
        record(store, event: 2, face: 8, at: 1_700_000_600, duration: 300)
        record(store, event: 3, face: 2, at: 1_700_000_900, duration: 120)
    }

    /// Faces 2 and 8 are seeded `locked = 1`, and a locked face refuses reassignment. Unlocking is
    /// setup, not the thing under test.
    private func remap(_ store: AppDataStore, face: UInt8, to categoryName: String) -> Int64 {
        let categoryID = scalar("SELECT category_id FROM category WHERE category_name = '\(categoryName)';")
        execute("UPDATE face SET locked = 0 WHERE face_id = \(face);")
        store.updateFaceCategory(faceID: face, categoryID: Int(categoryID))
        return categoryID
    }

    func testRemappingAFaceWithNothingOutstandingRecordsNoExtraTime() {
        // The sweep runs on every remap, so the common case is that it finds nothing. If it logged
        // time anyway, every trip to the Faces tab would inflate the day's totals.
        let store = AppDataStore(databaseURL: databaseURL)
        recordTwoClosedSegments(store)
        let before = entries()
        XCTAssertEqual(before.count, 2, "both closed-out segments already converted; the third is still open")

        _ = remap(store, face: 2, to: "Break")

        let after = entries()
        XCTAssertEqual(after.count, 2, "nothing was outstanding, so nothing should have been added")
        XCTAssertEqual(after.map(\.deviceEventID), before.map(\.deviceEventID))
        XCTAssertEqual(after.map(\.duration), before.map(\.duration))
    }

    func testRemappingOneFaceStillConvertsAnotherFacesMissingEntry() {
        // The sweep is not scoped to the face being changed. A segment on some other face that
        // never got converted is just as missing, and this is the moment something is finally
        // looking, so it gets picked up too -- against its own face's category, which no remap
        // here has touched.
        let store = AppDataStore(databaseURL: databaseURL)
        recordTwoClosedSegments(store)

        // Face 8's segment loses its entry and goes back to pending.
        execute("DELETE FROM time_entry WHERE duration_seconds = 300;")
        execute("UPDATE device_event SET processed = 0 WHERE event_number = 2;")
        XCTAssertEqual(entries().count, 1)

        _ = remap(store, face: 2, to: "Unassigned")

        let recovered = entries().first { $0.duration == 300 }
        XCTAssertNotNil(recovered, "face 8's missing entry should have been created even though face 2 was the one changing")
        XCTAssertEqual(recovered?.categoryName, "Break", "face 8 is still Break; only face 2 was remapped")
        XCTAssertEqual(entries().count, 2)
    }

    func testAMissingEntryForTheFaceBeingRemappedTakesTheOldCategory() {
        // The reason the sweep runs *before* the write. An entry records the category the face was
        // mapped to when the segment happened, and that mapping is the row about to change, so a
        // segment still waiting would be recorded against a category the user was not on at the
        // time. Converting first is what pins it to the truth it was earned under.
        let store = AppDataStore(databaseURL: databaseURL)
        recordTwoClosedSegments(store)

        // Face 2's own segment loses its entry and goes back to pending.
        execute("DELETE FROM time_entry WHERE duration_seconds = 600;")
        execute("UPDATE device_event SET processed = 0 WHERE event_number = 1;")

        let breakID = remap(store, face: 2, to: "Break")

        let recovered = entries().first { $0.duration == 600 }
        XCTAssertEqual(
            recovered?.categoryName, "Meeting",
            "the 600s segment was spent while face 2 meant Meeting, so it stays Meeting"
        )
        XCTAssertEqual(
            scalar("SELECT category_id FROM face WHERE face_id = 2;"), breakID,
            "and the remap itself still went through"
        )
        // The open segment on face 2 has not been converted yet, so when it eventually is, it will
        // pick up Break. That is correct: it is still running, under the new meaning of the face.
        XCTAssertNil(entries().first { $0.duration == 120 })
    }

    // MARK: - helpers

    private func execute(_ sql: String) {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }

    private func stringScalar(_ sql: String) -> String {
        var value = ""
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return value
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW,
           let text = sqlite3_column_text(stmt, 0) {
            value = String(cString: text)
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return value
    }

    private func secondsBetween(_ start: String?, _ end: String?) -> Int? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let start, let end,
              let from = formatter.date(from: start), let to = formatter.date(from: end) else { return nil }
        return Int(to.timeIntervalSince(from))
    }
}

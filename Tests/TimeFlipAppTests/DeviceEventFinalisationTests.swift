@testable import TimeFlipApp
import SQLite3
import XCTest

/// Covers which `device_event` row `AppDataStore.recordDeviceEvent` treats as the live segment, and
/// so which rows get `finalised = 1` behind it.
///
/// `start_epoch` is the ordering source of truth, but it is whole seconds, and events genuinely
/// arrive inside one -- a daily limit's pause lands about a second after the flip that triggered it,
/// and the cube mints an event per pause write. Measured on real hardware 2026-08-12: events 72
/// (the flip) through 76 all shared one second, and with the epoch as the only test the close-out
/// never fired again after 72, leaving it permanently claiming to be the live segment. A row stuck
/// that way is never converted, conversion wanting `finalised = 1`, so with a duration worth keeping
/// it would have been lost.
///
/// Written against the real database rather than a stub, as `TimeEntryCreationTests` is and for the
/// same reason: what is under test is the SQL and the in-memory high-water mark beside it.
@MainActor
final class DeviceEventFinalisationTests: XCTestCase {
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

    private func record(
        _ store: AppDataStore,
        event: UInt32,
        face: UInt8 = 8,
        at epoch: TimeInterval,
        duration: TimeInterval,
        paused: Bool = false
    ) {
        store.recordDeviceEvent(
            eventNumber: event,
            deviceFace: face,
            startedAt: Date(timeIntervalSince1970: epoch),
            durationSeconds: duration,
            isPaused: paused
        )
    }

    /// `event_number` -> `finalised`, so a failure names the event rather than a row id.
    private func finalisedByEvent() -> [Int: Int] {
        var result: [Int: Int] = [:]
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return result
        }
        var stmt: OpaquePointer?
        let sql = "SELECT event_number, finalised FROM device_event ORDER BY device_event_id;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                result[Int(sqlite3_column_int64(stmt, 0))] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return result
    }

    // MARK: - several events inside one second

    func testAnEventInTheSameSecondClosesOutTheOneBeforeIt() {
        let store = AppDataStore(databaseURL: databaseURL)
        let sameSecond: TimeInterval = 1_700_000_000
        // The shape a limit pause makes: the flip arrives, then the pause the app sent in response,
        // then the pause segment the cube goes on to report -- all stamped the same second.
        record(store, event: 72, at: sameSecond, duration: 0)
        record(store, event: 73, at: sameSecond, duration: 0, paused: true)
        record(store, event: 74, at: sameSecond, duration: 12, paused: true)

        XCTAssertEqual(
            finalisedByEvent(), [72: 1, 73: 1, 74: 0],
            "only the highest event number in the second is live; the epoch alone cannot tell them apart"
        )
    }

    func testTheLiveRowStaysOpenWhileItsDurationGrows() {
        let store = AppDataStore(databaseURL: databaseURL)
        let sameSecond: TimeInterval = 1_700_000_000
        record(store, event: 72, at: sameSecond, duration: 0)
        record(store, event: 73, at: sameSecond, duration: 5, paused: true)
        // The cube re-reports its current segment on every refresh, with a longer duration each time.
        record(store, event: 73, at: sameSecond, duration: 90, paused: true)

        XCTAssertEqual(
            finalisedByEvent(), [72: 1, 73: 0],
            "re-reporting the live row must not close it, nor reopen the one behind it"
        )
    }

    func testResendingAnEarlierEventFromTheSameSecondDoesNotReopenIt() {
        let store = AppDataStore(databaseURL: databaseURL)
        let sameSecond: TimeInterval = 1_700_000_000
        record(store, event: 72, at: sameSecond, duration: 0)
        record(store, event: 73, at: sameSecond, duration: 5, paused: true)
        // A gap probe hands back event 72 again, long after it stopped being current. Its epoch still
        // equals the newest on record, which is exactly what used to mark it live a second time.
        record(store, event: 72, at: sameSecond, duration: 0)

        XCTAssertEqual(
            finalisedByEvent(), [72: 1, 73: 0],
            "a settled row re-sent from the live second is still settled"
        )
    }

    // MARK: - the epoch still decides across seconds

    func testALaterSecondClosesOutEverythingBefore() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 10, at: 1_700_000_000, duration: 30)
        record(store, event: 11, at: 1_700_000_030, duration: 60)

        XCTAssertEqual(finalisedByEvent(), [10: 1, 11: 0])
    }

    func testAResetCounterInALaterSecondBecomesTheLiveSegment() {
        let store = AppDataStore(databaseURL: databaseURL)
        // A factory reset restarts the counter, so the newest event carries the *lower* number. The
        // epoch has to win here, or the pre-reset history would go on claiming to be current.
        record(store, event: 500, at: 1_700_000_000, duration: 30)
        record(store, event: 1, at: 1_700_000_060, duration: 10)

        XCTAssertEqual(
            finalisedByEvent(), [500: 1, 1: 0],
            "the event number is only a tie-break within one second, never an override of the epoch"
        )
    }

    func testAnOlderSecondArrivingLateIsInsertedAlreadyClosed() {
        let store = AppDataStore(databaseURL: databaseURL)
        record(store, event: 10, at: 1_700_000_060, duration: 30)
        // Out of chronological order, which a gap probe can do: it cannot be the live segment.
        record(store, event: 9, at: 1_700_000_000, duration: 15)

        XCTAssertEqual(finalisedByEvent(), [10: 0, 9: 1])
    }

    // MARK: - the flag drives conversion, which is the reason it matters

    func testAStrandedRowWouldNotConvertWhichIsWhatTheTieBreakProtects() {
        let store = AppDataStore(databaseURL: databaseURL)
        let sameSecond: TimeInterval = 1_700_000_000
        // Face 2 is seeded to Meeting (database/008_face.sql). A real duration, unpaused, so the only
        // thing standing between this row and a time_entry is whether it was ever finalised.
        record(store, event: 72, face: 2, at: sameSecond, duration: 600)
        record(store, event: 73, face: 8, at: sameSecond, duration: 30, paused: true)

        XCTAssertEqual(finalisedByEvent()[72], 1, "precondition: the tie-break closed it out")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        var converted: Int64 = -1
        let sql = """
        SELECT COUNT(*) FROM time_entry te
        JOIN device_event de ON de.device_event_id = te.device_event_id
        WHERE de.event_number = 72;
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            converted = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        XCTAssertEqual(converted, 1, "a closed-out unpaused segment converts; a stranded one never would")
    }
}

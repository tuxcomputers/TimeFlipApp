@testable import TimeFlipApp
import SQLite3
import XCTest

/// Closing off a manual session's last segment.
///
/// Every other segment in `device_event` is closed by the frame that follows it. A manual session
/// has no frame after its last one -- the app is going away -- so without this the segment the user
/// was timing when they quit stays open and never becomes a `time_entry`. For a cube that would
/// self-heal on the next flip; for someone in manual mode, who may have no device at all, nothing
/// is coming.
final class ManualSegmentCloseTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ManualSegmentCloseTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("appdata.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Writes a manual segment and leaves it open, which is what the periodic fetch does while a
    /// manual session runs.
    @discardableResult
    private func openManualSegment(
        on store: AppDataStore,
        eventNumber: UInt32 = 1_786_000_000,
        durationSoFar: TimeInterval = 60,
        isPaused: Bool = false
    ) -> AppDataStore {
        store.recordDeviceEvent(
            eventNumber: eventNumber,
            deviceFace: TimeFlipConstants.manualFaceID,
            startedAt: start,
            durationSeconds: durationSoFar,
            isPaused: isPaused
        )
        return store
    }

    private func row(_ store: AppDataStore, column: String) -> Double? {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT \(column) FROM device_event WHERE device_face = \(TimeFlipConstants.manualFaceID) ORDER BY device_event_id DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return nil
        }
        let value = sqlite3_column_double(stmt, 0)
        sqlite3_finalize(stmt)
        return value
    }

    private func timeEntryCount() -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM time_entry;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return -1
        }
        let count = Int(sqlite3_column_int64(stmt, 0))
        sqlite3_finalize(stmt)
        return count
    }

    // MARK: - Quitting

    func testTheOpenSegmentIsLeftOpenUntilSomethingClosesIt() {
        // The state a manual session is in the whole time it runs, and the reason this method has
        // to exist: nothing else is going to finalise this row.
        let store = AppDataStore(databaseURL: dbURL)
        openManualSegment(on: store)
        XCTAssertEqual(row(store, column: "finalised"), 0)
    }

    func testQuittingFinalisesTheSegment() {
        let store = AppDataStore(databaseURL: dbURL)
        openManualSegment(on: store)

        XCTAssertTrue(store.closeOpenManualSegment(endingAt: start.addingTimeInterval(300)))
        XCTAssertEqual(row(store, column: "finalised"), 1)
    }

    func testQuittingGivesTheSegmentItsRealDuration() {
        // The open row is only as current as the last periodic fetch left it, so on a quit it is up
        // to `fetch_history_interval_seconds` short of the truth.
        let store = AppDataStore(databaseURL: dbURL)
        openManualSegment(on: store, durationSoFar: 60)

        store.closeOpenManualSegment(endingAt: start.addingTimeInterval(305))
        XCTAssertEqual(row(store, column: "duration_seconds"), 305)
    }

    func testTheClosedSegmentBecomesATimeEntry() {
        // "And all that entails": finalising is only half of it, the row has to be converted too.
        let store = AppDataStore(databaseURL: dbURL)
        openManualSegment(on: store)
        XCTAssertEqual(timeEntryCount(), 0)

        store.closeOpenManualSegment(endingAt: start.addingTimeInterval(600))
        XCTAssertEqual(timeEntryCount(), 1)
    }

    func testAPausedSegmentIsClosedButMakesNoEntry() {
        // Consistent with every other paused segment: closed off like any other row, and never
        // converted, because a pause is not time spent on the category.
        let store = AppDataStore(databaseURL: dbURL)
        openManualSegment(on: store, isPaused: true)

        XCTAssertTrue(store.closeOpenManualSegment(endingAt: start.addingTimeInterval(300)))
        XCTAssertEqual(row(store, column: "finalised"), 1)
        XCTAssertEqual(timeEntryCount(), 0)
    }

    func testClosingTwiceIsHarmless() {
        // Quit runs it, and so does the next launch. The second finds nothing open and says so.
        let store = AppDataStore(databaseURL: dbURL)
        openManualSegment(on: store)

        XCTAssertTrue(store.closeOpenManualSegment(endingAt: start.addingTimeInterval(120)))
        XCTAssertFalse(store.closeOpenManualSegment(endingAt: start.addingTimeInterval(240)))
        XCTAssertEqual(row(store, column: "duration_seconds"), 120, "the second call must not extend a closed segment")
    }

    // MARK: - A run that never reached the quit handler

    func testALeftoverSegmentKeepsTheDurationItWasWrittenWith() {
        // A crash or force quit. When it actually stopped is unknowable, so the honest answer is the
        // last duration written to it -- anything from the clock now would be invented, and after an
        // overnight crash it would be invented by hours.
        let store = AppDataStore(databaseURL: dbURL)
        openManualSegment(on: store, durationSoFar: 90)

        XCTAssertTrue(store.closeOpenManualSegment(endingAt: nil))
        XCTAssertEqual(row(store, column: "finalised"), 1)
        XCTAssertEqual(row(store, column: "duration_seconds"), 90)
    }

    // MARK: - Leaving a real device's rows alone

    func testACubesOpenSegmentIsNotTouched() {
        // A real segment is closed by the frame after it, and this must not step in front of that:
        // the cube's live row grows on every refresh, and finalising it here would freeze it at
        // whatever it happened to read at launch.
        let store = AppDataStore(databaseURL: dbURL)
        store.recordDeviceEvent(
            eventNumber: 139,
            deviceFace: 2,
            startedAt: start,
            durationSeconds: 45,
            isPaused: false
        )

        XCTAssertFalse(store.closeOpenManualSegment(endingAt: start.addingTimeInterval(600)))

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        _ = sqlite3_prepare_v2(db, "SELECT finalised, duration_seconds FROM device_event WHERE device_face = 2;", -1, &stmt, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(stmt, 0), 0, "the cube's live row must stay open")
        XCTAssertEqual(sqlite3_column_double(stmt, 1), 45, "and keep its duration")
        sqlite3_finalize(stmt)
    }
}

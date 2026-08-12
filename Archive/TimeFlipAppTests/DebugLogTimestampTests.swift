@testable import TimeFlipApp
import Foundation
import SQLite3
import XCTest

/// `debug_log.logged_at` records milliseconds, and the other timestamp columns deliberately do not.
///
/// Guards a precision that is easy to lose by accident -- one shared formatter used to write all three
/// columns, and reverting `recordDebugLog` to it would compile, pass every other test, and only show
/// up the next time someone tried to time a device operation from the log.
final class DebugLogTimestampTests: XCTestCase {
    private var databaseURL: URL!

    override func setUp() {
        super.setUp()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TimeFlipDebugLogTimestampTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("appdata.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func loggedAtValues() -> [String] {
        var values: [String] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return values
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT logged_at FROM debug_log ORDER BY debug_log_id;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                values.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        return values
    }

    func testLoggedAtCarriesMillisecondsAndNoUTCOffset() throws {
        let store = AppDataStore(databaseURL: databaseURL)
        // .500 rather than a round second, so a formatter that silently truncated would be visible.
        let moment = Date(timeIntervalSince1970: 1_700_000_000.5)
        XCTAssertTrue(store.recordDebugLog(tag: "test", message: "hello", loggedAt: moment))

        let logged = try XCTUnwrap(loggedAtValues().first)
        XCTAssertTrue(
            logged.hasSuffix(".500"),
            "expected a millisecond fraction, got \(logged)"
        )
        // Local time with no offset/Z suffix, per database/CLAUDE.md -- the zone lives in timezone_id.
        XCTAssertFalse(logged.hasSuffix("Z"), "should be local time, not UTC-marked: \(logged)")
        XCTAssertNil(logged.range(of: "+"), "should carry no UTC offset: \(logged)")
        XCTAssertEqual(logged.count, "yyyy-MM-ddTHH:mm:ss.SSS".count, "unexpected shape: \(logged)")
    }

    func testTwoEntriesInsideOneSecondAreDistinguishable() throws {
        let store = AppDataStore(databaseURL: databaseURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000.100)
        store.recordDebugLog(tag: "test", message: "first", loggedAt: base)
        store.recordDebugLog(tag: "test", message: "second", loggedAt: base.addingTimeInterval(0.250))

        let values = loggedAtValues()
        XCTAssertEqual(values.count, 2)
        // The whole point: the gap between two sub-second events is now recoverable from the log.
        XCTAssertNotEqual(values[0], values[1], "two events 250ms apart must not collapse to one stamp")
        XCTAssertTrue(values[0] < values[1], "string ordering must still follow time order")
    }

    /// Python's `datetime.fromisoformat` parses this shape, which is what `session_setup.py`'s
    /// heartbeat-recency check relies on. Asserted here as the Swift-side half of that contract.
    func testFormatIsFractionalISO8601() throws {
        let store = AppDataStore(databaseURL: databaseURL)
        store.recordDebugLog(tag: "test", message: "x", loggedAt: Date(timeIntervalSince1970: 1_700_000_000.123))

        let logged = try XCTUnwrap(loggedAtValues().first)
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        parser.timeZone = .current
        parser.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertNotNil(parser.date(from: logged), "should round-trip through an ISO 8601 parser: \(logged)")
    }

    /// device_event.start_time stays at whole seconds: it sits beside start_epoch, an INTEGER of whole
    /// seconds that is the real ordering and uniqueness key, and the two must not disagree.
    func testDeviceEventStartTimeStaysAtWholeSeconds() throws {
        let store = AppDataStore(databaseURL: databaseURL)
        store.recordDeviceEvent(
            eventNumber: 1,
            deviceFace: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.500),
            durationSeconds: 60,
            isPaused: false
        )

        var startTime: String?
        var db: OpaquePointer?
        if sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT start_time FROM device_event LIMIT 1;", -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW {
                startTime = String(cString: sqlite3_column_text(stmt, 0))
            }
            sqlite3_finalize(stmt)
            sqlite3_close(db)
        }

        let value = try XCTUnwrap(startTime)
        XCTAssertFalse(value.contains("."), "device_event.start_time should stay second-resolution: \(value)")
    }
}

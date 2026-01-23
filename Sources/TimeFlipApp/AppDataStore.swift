import Foundation
import OSLog
import SQLite3

struct DeviceEventRecord {
    let id: Int64?
    let eventNumber: UInt32
    let facetID: UInt8
    let startedAt: Date
    let duration: TimeInterval
    let isPaused: Bool
    let activityName: String
}

enum IntegrationTarget: String {
    case calendar
    case sheets
    case local
}

// Cursor status for delivery targets.
struct IntegrationEventCursorStatus {
    let lastSentID: Int64?
    let attempts: Int
    let lastError: String?
    let lastSuccessID: Int64?
    let updatedAt: Date?
}

protocol IntegrationEventCursorStore {
    func loadEventCursor(target: IntegrationTarget, identifier: String) -> Int64?
    func saveEventCursor(target: IntegrationTarget, identifier: String, lastSentEventID: Int64)
    func recordEventFailure(target: IntegrationTarget, identifier: String, error: String)
    func loadEventCursorStatus(target: IntegrationTarget, identifier: String) -> IntegrationEventCursorStatus?
}

// SQLite-backed application data (cursor + integration queue).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AppDataStore: IntegrationEventCursorStore {
    private let db: OpaquePointer?
    private let dbURL: URL
    private let queue = DispatchQueue(label: "com.timeflip.appdatastore")
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "app-data-store")

    init(databaseURL: URL? = nil) {
        let url = databaseURL ?? AppDataStore.defaultDatabaseURL()
        self.dbURL = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            db = nil
            return
        }
        db = handle
        createTablesIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Logbook (event-number keyed)

    func append(_ event: DeviceEventRecord) {
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO logbook (
            event_number, facet_id, started_at_s, duration_s, is_paused, activity_name, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, COALESCE(?, strftime('%s','now')));
        """
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(event.eventNumber))
                sqlite3_bind_int(stmt, 2, Int32(event.facetID))
                sqlite3_bind_double(stmt, 3, event.startedAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 4, event.duration)
                sqlite3_bind_int(stmt, 5, event.isPaused ? 1 : 0)
                sqlite3_bind_text(stmt, 6, event.activityName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
                _ = sqlite3_step(stmt)
                logger.debug("logbook_append ev=\(event.eventNumber, privacy: .public) facet=\(event.facetID, privacy: .public) dur=\(event.duration, privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    func loadEvents(after logbookID: Int64?, limit: Int) -> [DeviceEventRecord] {
        guard let db else { return [] }
        var items: [DeviceEventRecord] = []
        let sql = """
        SELECT rowid, event_number, facet_id, started_at_s, duration_s, is_paused, activity_name
        FROM logbook
        WHERE rowid > ?
        ORDER BY rowid ASC
        LIMIT ?;
        """
        let cutoff = logbookID ?? 0
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, cutoff)
                sqlite3_bind_int(stmt, 2, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let rowid = sqlite3_column_int64(stmt, 0)
                    let eventNumber = UInt32(sqlite3_column_int64(stmt, 1))
                    let facet = UInt8(sqlite3_column_int(stmt, 2))
                    let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                    let duration = sqlite3_column_double(stmt, 4)
                    let paused = sqlite3_column_int(stmt, 5) == 1
                    guard let activityCString = sqlite3_column_text(stmt, 6) else { continue }
                    let activity = String(cString: activityCString)
                    items.append(
                        DeviceEventRecord(
                            id: rowid,
                            eventNumber: eventNumber,
                            facetID: facet,
                            startedAt: started,
                            duration: duration,
                            isPaused: paused,
                            activityName: activity
                        )
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return items
    }

    /// Fetch events whose interval overlaps the provided cutoff (started_at + duration > cutoff).
    func loadEvents(overlappingSince cutoff: Date) -> [DeviceEventRecord] {
        guard let db else { return [] }
        var items: [DeviceEventRecord] = []
        let sql = """
        SELECT rowid, event_number, facet_id, started_at_s, duration_s, is_paused, activity_name
        FROM logbook
        WHERE (started_at_s + duration_s) > ?
        ORDER BY rowid ASC;
        """
        let cutoffSeconds = cutoff.timeIntervalSince1970
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoffSeconds)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let rowid = sqlite3_column_int64(stmt, 0)
                    let eventNumber = UInt32(sqlite3_column_int64(stmt, 1))
                    let facet = UInt8(sqlite3_column_int(stmt, 2))
                    let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                    let duration = sqlite3_column_double(stmt, 4)
                    let paused = sqlite3_column_int(stmt, 5) == 1
                    guard let activityCString = sqlite3_column_text(stmt, 6) else { continue }
                    let activity = String(cString: activityCString)
                    items.append(
                        DeviceEventRecord(
                            id: rowid,
                            eventNumber: eventNumber,
                            facetID: facet,
                            startedAt: started,
                            duration: duration,
                            isPaused: paused,
                            activityName: activity
                        )
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return items
    }

    /// Fetch the most recent event with the given event_number from the logbook, if present.
    func loadEvent(eventNumber: UInt32) -> DeviceEventRecord? {
        guard let db else { return nil }
        let sql = """
        SELECT rowid, event_number, facet_id, started_at_s, duration_s, is_paused, activity_name
        FROM logbook
        WHERE event_number = ?
        ORDER BY rowid DESC
        LIMIT 1;
        """
        var record: DeviceEventRecord?
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(eventNumber))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let rowid = sqlite3_column_int64(stmt, 0)
                    let eventNumber = UInt32(sqlite3_column_int64(stmt, 1))
                    let facet = UInt8(sqlite3_column_int(stmt, 2))
                    let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                    let duration = sqlite3_column_double(stmt, 4)
                    let paused = sqlite3_column_int(stmt, 5) == 1
                    guard let activityCString = sqlite3_column_text(stmt, 6) else { return }
                    let activity = String(cString: activityCString)
                    record = DeviceEventRecord(
                        id: rowid,
                        eventNumber: eventNumber,
                        facetID: facet,
                        startedAt: started,
                        duration: duration,
                        isPaused: paused,
                        activityName: activity
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return record
    }

    func purgeEvents(throughLogbookID logbookID: Int64) {
        guard let db else { return }
        let sql = "DELETE FROM logbook WHERE rowid <= ?;"
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, logbookID)
                _ = sqlite3_step(stmt)
                logger.debug("logbook_purge through_rowid=\(logbookID, privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }
    // MARK: - Event-number cursors

    func loadEventCursor(target: IntegrationTarget, identifier: String) -> Int64? {
        guard let db else { return nil }
        let sql = """
        SELECT last_sent_ev FROM integration_event_cursors
        WHERE target = ? AND identifier = ?
        LIMIT 1;
        """
        var result: Int64?
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, target.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, identifier, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let ev = sqlite3_column_int64(stmt, 0)
                    if ev > 0 { result = ev }
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    func saveEventCursor(target: IntegrationTarget, identifier: String, lastSentEventID: Int64) {
        guard let db else { return }
        let sql = """
        INSERT INTO integration_event_cursors (
            target,
            identifier,
            last_sent_ev,
            last_success_ev,
            attempts,
            last_error,
            updated_at
        )
        VALUES (?, ?, ?, ?, 0, NULL, ?)
        ON CONFLICT(target, identifier)
        DO UPDATE SET
            last_sent_ev = MAX(integration_event_cursors.last_sent_ev, excluded.last_sent_ev),
            last_success_ev = MAX(
                COALESCE(integration_event_cursors.last_success_ev, 0),
                excluded.last_success_ev
            ),
            attempts = 0,
            last_error = NULL,
            updated_at = excluded.updated_at;
        """
        let now = Date().timeIntervalSince1970
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, target.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, identifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, sqlite3_int64(lastSentEventID))
                sqlite3_bind_int64(stmt, 4, sqlite3_int64(lastSentEventID))
                sqlite3_bind_double(stmt, 5, now)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func recordEventFailure(target: IntegrationTarget, identifier: String, error: String) {
        guard let db else { return }
        let sql = """
        INSERT INTO integration_event_cursors (target, identifier, attempts, last_error, updated_at)
        VALUES (?, ?, 1, ?, ?)
        ON CONFLICT(target, identifier)
        DO UPDATE SET attempts = integration_event_cursors.attempts + 1,
                      last_error = excluded.last_error,
                      updated_at = excluded.updated_at;
        """
        let now = Date().timeIntervalSince1970
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, target.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, identifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, error, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 4, now)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func purgeAllEvents() {
        guard let db else { return }
        queue.sync {
            _ = sqlite3_exec(db, "DELETE FROM logbook;", nil, nil, nil)
        }
    }

    func clearEventCursors() {
        guard let db else { return }
        let sql = "DELETE FROM integration_event_cursors;"
        queue.sync {
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    func loadEventCursorStatus(target: IntegrationTarget, identifier: String) -> IntegrationEventCursorStatus? {
        guard let db else { return nil }
        let sql = """
        SELECT last_sent_ev, attempts, last_error, last_success_ev, updated_at
        FROM integration_event_cursors
        WHERE target = ? AND identifier = ?
        LIMIT 1;
        """
        var status: IntegrationEventCursorStatus?
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, target.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, identifier, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let lastSent = sqlite3_column_int64(stmt, 0)
                    let attempts = Int(sqlite3_column_int(stmt, 1))
                    let lastError = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
                    let lastSuccess = sqlite3_column_int64(stmt, 3)
                    let updated = sqlite3_column_double(stmt, 4)
                    status = IntegrationEventCursorStatus(
                        lastSentID: lastSent > 0 ? lastSent : nil,
                        attempts: attempts,
                        lastError: lastError,
                        lastSuccessID: lastSuccess > 0 ? lastSuccess : nil,
                        updatedAt: updated > 0 ? Date(timeIntervalSince1970: updated) : nil
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return status
    }

    // MARK: - Helpers

    private func createTablesIfNeeded() {
        guard let db else { return }
        if schemaMigrationNeeded(db: db) {
            logger.notice("Dropping incompatible app data schema; rebuilding")
            let dropSQL = """
            DROP TABLE IF EXISTS integration_queue;
            DROP TABLE IF EXISTS sessions_queue;
            DROP TABLE IF EXISTS integration_cursors;
            DROP TABLE IF EXISTS history_cursor;
            DROP TABLE IF EXISTS session_state;
            DROP TABLE IF EXISTS logbook;
            DROP TABLE IF EXISTS local_sink;
            DROP TABLE IF EXISTS integration_event_cursors;
            """
            sqlite3_exec(db, dropSQL, nil, nil, nil)
        }
        let logbookSQL = """
        CREATE TABLE IF NOT EXISTS logbook (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_number INTEGER,
            facet_id INTEGER NOT NULL,
            started_at_s REAL NOT NULL,
            duration_s REAL NOT NULL,
            is_paused INTEGER NOT NULL,
            activity_name TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """
        let eventCursorSQL = """
        CREATE TABLE IF NOT EXISTS integration_event_cursors (
            target TEXT NOT NULL,
            identifier TEXT NOT NULL,
            last_sent_ev INTEGER,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            last_success_ev INTEGER,
            updated_at REAL,
            PRIMARY KEY (target, identifier)
        );
        """
        sqlite3_exec(db, logbookSQL, nil, nil, nil)
        sqlite3_exec(db, eventCursorSQL, nil, nil, nil)
    }

    static func defaultDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TimeFlip", isDirectory: true)
            .appendingPathComponent("appdata.sqlite")
    }

    /// Test-only helper to reset the persisted database.
    static func resetForTests(at url: URL = testDatabaseURL()) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Test-only helper to get an isolated database URL that won't clobber user data.
    static func testDatabaseURL() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("TimeFlipTests", isDirectory: true)
        return base.appendingPathComponent("appdata.sqlite")
    }

    private func schemaMigrationNeeded(db: OpaquePointer) -> Bool {
        let expectedLogbook = [
            "id", "event_number", "facet_id", "started_at_s", "duration_s", "is_paused", "activity_name", "created_at"
        ]
        let expectedEventCursors = [
            "target", "identifier", "last_sent_ev", "attempts", "last_error", "last_success_ev", "updated_at"
        ]

        func columns(of table: String) -> [String] {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            var cols: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    cols.append(String(cString: name))
                }
            }
            return cols
        }

        let logbookCols = columns(of: "logbook")
        if logbookCols != expectedLogbook { return true }
        let cursorCols = columns(of: "integration_event_cursors")
        if cursorCols != expectedEventCursors { return true }
        return false
    }

}

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
    /// True if some other identifier already has a cursor for this target — i.e. integrations
    /// were previously delivering to a different calendar/sheet, and this one is a switch rather
    /// than the very first setup (which should still see the existing backlog).
    func hasCursor(target: IntegrationTarget, excludingIdentifier identifier: String) -> Bool
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
        runDatabaseDDL()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Logbook (event-number keyed)

    @discardableResult
    func append(_ event: DeviceEventRecord) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT OR REPLACE INTO logbook (
            event_number, facet_id, started_at_s, duration_s, is_paused, activity_name, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, COALESCE(?, strftime('%s','now')));
        """
        var success = false
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("logbook_append prepare failed ev=\(event.eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(event.eventNumber))
            sqlite3_bind_int(stmt, 2, Int32(event.facetID))
            sqlite3_bind_double(stmt, 3, event.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, event.duration)
            sqlite3_bind_int(stmt, 5, event.isPaused ? 1 : 0)
            sqlite3_bind_text(stmt, 6, event.activityName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
                logger.debug("logbook_append ev=\(event.eventNumber, privacy: .public) facet=\(event.facetID, privacy: .public) dur=\(event.duration, privacy: .public)")
            } else {
                logger.error("logbook_append failed ev=\(event.eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
        return success
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

    /// The highest logbook rowid currently stored, or nil if the logbook is empty.
    func maxLogbookRowID() -> Int64? {
        guard let db else { return nil }
        var result: Int64?
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT MAX(rowid) FROM logbook;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                    result = sqlite3_column_int64(stmt, 0)
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
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

    func hasCursor(target: IntegrationTarget, excludingIdentifier identifier: String) -> Bool {
        guard let db else { return false }
        let sql = """
        SELECT 1 FROM integration_event_cursors
        WHERE target = ? AND identifier != ?
        LIMIT 1;
        """
        var found = false
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, target.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, identifier, -1, SQLITE_TRANSIENT)
                found = sqlite3_step(stmt) == SQLITE_ROW
            }
            sqlite3_finalize(stmt)
        }
        return found
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

    /// Runs every `.sql` file bundled under the `Database` resource directory, in filename order
    /// (hence the numeric prefixes on each file, e.g. `001_device_events.sql`). Adding, removing,
    /// or editing a `.sql` file in `database/` at the repo root is all that's needed to change the
    /// schema — this method never needs to change.
    private func runDatabaseDDL() {
        guard let db else { return }
        guard let directory = AppDataStore.resolveDatabaseDirectory() else {
            logger.error("Could not locate bundled Database DDL directory")
            return
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "sql" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            logger.error("Could not list Database DDL directory: \(error.localizedDescription, privacy: .public)")
            return
        }
        for file in files {
            guard let sql = try? String(contentsOf: file, encoding: .utf8) else {
                logger.error("Could not read DDL file \(file.lastPathComponent, privacy: .public)")
                continue
            }
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                logger.error("DDL file \(file.lastPathComponent, privacy: .public) failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
        }
    }

    /// Swift Bundler flattens this target's SwiftPM resources into the packaged app's
    /// `Contents/Resources` (see `ActivityIconLoader.resolveURL`) — check `Bundle.main` first to
    /// match that layout, and fall back to `Bundle.module` for `swift run`/`swift test`.
    private static func resolveDatabaseDirectory() -> URL? {
        Bundle.main.url(forResource: "Database", withExtension: nil)
            ?? Bundle.module.url(forResource: "Database", withExtension: nil)
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


}

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

    // The highest device_events.start_epoch seen so far, loaded once at startup with a single
    // MAX() query and kept up to date in memory from then on. recordDeviceEvent uses it to choose
    // UPDATE vs INSERT itself instead of relying on ON CONFLICT DO UPDATE -- that path still
    // consumes an AUTOINCREMENT id on every update, leaving permanent gaps in device_events_id.
    // start_epoch (not event_number) is the ordering source of truth: event_number is a counter
    // maintained on the device itself, and a device-side reset can make it restart from a low
    // number while this table already holds higher event_number values from before the reset --
    // comparing event_number magnitudes would then treat a brand new event as older than history
    // it's actually superseding. -1 means "no rows yet" (MAX(start_epoch) is NULL on an empty
    // table) -- every real epoch value compares greater than -1, so the empty-table case always
    // takes the insert path without needing Optional handling at every comparison site.
    private var maxKnownStartEpoch: Int64 = -1

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
        loadMaxKnownStartEpoch()
    }

    /// Seeds `maxKnownStartEpoch` from whatever `device_events` rows already exist on disk, so
    /// the update-vs-insert and finalised logic in `recordDeviceEvent` is correct across app
    /// restarts, not just within this process's lifetime. Leaves it at -1 (see property comment)
    /// when the table is empty and `MAX(start_epoch)` comes back NULL.
    private func loadMaxKnownStartEpoch() {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(start_epoch) FROM device_events;", -1, &stmt, nil) == SQLITE_OK else {
            logger.error("loadMaxKnownStartEpoch prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            sqlite3_finalize(stmt)
            return
        }
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            maxKnownStartEpoch = sqlite3_column_int64(stmt, 0)
        } else {
            maxKnownStartEpoch = -1
        }
        sqlite3_finalize(stmt)
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

    // MARK: - Device events (new schema; timing segments -- facet flips and pauses)

    /// Records a `device_events` row for a timing segment from the device's history stream.
    /// `event_number` is `UNIQUE` and remains the row's lookup key for update-in-place
    /// re-ingestion of a frame already seen (e.g. after a reconnect, or the device's still-open
    /// last frame growing in duration -- see docs/operation-spec.md §2). Update-vs-insert is
    /// decided by comparing `start_epoch` (derived from `startedAt`) against `maxKnownStartEpoch`
    /// (an in-memory scalar loaded once at startup via `SELECT MAX(start_epoch)`) rather than by
    /// comparing `event_number` magnitudes -- `event_number` is a counter maintained on the device
    /// itself, and a device-side reset can make it restart from a low number while this table
    /// already holds higher event_number values from before the reset, which would make a
    /// genuinely new event look older than history it's actually superseding. `start_epoch` is
    /// derived from the device's own timestamp and doesn't reset, so it's safe to compare
    /// directly. This is also not done via `ON CONFLICT DO UPDATE`, because that path still burns
    /// an AUTOINCREMENT id on every update and leaves permanent gaps in `device_events_id`.
    ///
    /// - `startEpoch > maxKnownStartEpoch` (a new high-water mark): any previously-open row is
    ///   closed out (`finalised` set to 1 wherever it isn't already), the new row is inserted with
    ///   `finalised = 0` (it's now the in-progress segment -- always the last frame in a history
    ///   dump, per docs/timeflip.md §5), and `maxKnownStartEpoch` advances to `startEpoch`.
    /// - `startEpoch == maxKnownStartEpoch`: this is that same in-progress segment growing in
    ///   duration; updated in place with `finalised = 0`.
    /// - `startEpoch < maxKnownStartEpoch`: a later event already superseded this one, so it's
    ///   updated in place with `finalised = 1`.
    ///
    /// `processed` is a separate flag (time_entry creation) and is never touched here.
    @discardableResult
    func recordDeviceEvent(
        eventNumber: UInt32,
        deviceFace: UInt8,
        startedAt: Date,
        durationSeconds: TimeInterval,
        isPaused: Bool
    ) -> Bool {
        guard let db else { return false }
        let eventType = isPaused ? "pause" : "facet_flip"
        var success = false
        queue.sync {
            let startEpoch = Int64(startedAt.timeIntervalSince1970)
            let isNewMax = startEpoch > maxKnownStartEpoch

            if isNewMax {
                if sqlite3_exec(db, "UPDATE device_events SET finalised = 1 WHERE finalised != 1;", nil, nil, nil) != SQLITE_OK {
                    logger.error("device_events close-out failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                }

                let sql = """
                INSERT INTO device_events (
                    event_number, event_type_id, device_face, start_time, start_time_timezone, start_epoch, duration_seconds, is_paused, finalised
                ) VALUES (
                    ?, (SELECT event_type_id FROM event_type WHERE event_name = ?), ?, ?, ?, ?, ?, ?, 0
                );
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    logger.error("device_events insert prepare failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                    sqlite3_finalize(stmt)
                    return
                }
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(eventNumber))
                sqlite3_bind_text(stmt, 2, eventType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(deviceFace))
                sqlite3_bind_text(stmt, 4, AppDataStore.localTimeFormatter.string(from: startedAt), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, TimeZone.current.identifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 6, startEpoch)
                sqlite3_bind_double(stmt, 7, durationSeconds)
                sqlite3_bind_int(stmt, 8, isPaused ? 1 : 0)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = true
                    maxKnownStartEpoch = startEpoch
                    logger.debug("device_events ev=\(eventNumber, privacy: .public) face=\(deviceFace, privacy: .public) dur=\(durationSeconds, privacy: .public) paused=\(isPaused, privacy: .public) finalised=false inserted=true")
                } else {
                    logger.error("device_events insert failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                }
                sqlite3_finalize(stmt)
            } else {
                let finalised = startEpoch == maxKnownStartEpoch ? false : true
                let sql = """
                UPDATE device_events SET
                    event_type_id = (SELECT event_type_id FROM event_type WHERE event_name = ?),
                    device_face = ?,
                    start_time = ?,
                    start_time_timezone = ?,
                    start_epoch = ?,
                    duration_seconds = ?,
                    is_paused = ?,
                    finalised = ?
                WHERE event_number = ?;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    logger.error("device_events update prepare failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                    sqlite3_finalize(stmt)
                    return
                }
                sqlite3_bind_text(stmt, 1, eventType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(deviceFace))
                sqlite3_bind_text(stmt, 3, AppDataStore.localTimeFormatter.string(from: startedAt), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, TimeZone.current.identifier, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 5, startEpoch)
                sqlite3_bind_double(stmt, 6, durationSeconds)
                sqlite3_bind_int(stmt, 7, isPaused ? 1 : 0)
                sqlite3_bind_int(stmt, 8, finalised ? 1 : 0)
                sqlite3_bind_int64(stmt, 9, sqlite3_int64(eventNumber))
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = true
                    logger.debug("device_events ev=\(eventNumber, privacy: .public) face=\(deviceFace, privacy: .public) dur=\(durationSeconds, privacy: .public) paused=\(isPaused, privacy: .public) finalised=\(finalised, privacy: .public) inserted=false")
                } else {
                    logger.error("device_events update failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                }
                sqlite3_finalize(stmt)
            }

        }
        return success
    }

    /// Development-only consistency check: re-derives `MAX(start_epoch)` directly from the
    /// database and compares it against the in-memory `maxKnownStartEpoch` this class has been
    /// incrementally maintaining. A mismatch means that tracking has drifted from the DB -- e.g. a
    /// row was written outside `recordDeviceEvent`, or a write silently failed -- and needs
    /// investigating, so it's printed loudly rather than tucked away in the OS log.
    ///
    /// Callers should invoke this once after a batch of `recordDeviceEvent` calls (e.g. once per
    /// history refresh), not after every individual call -- history processing can call
    /// `recordDeviceEvent` many times per batch, and re-deriving MAX() from the DB that often is
    /// both wasteful and noisy.
    func verifyMaxKnownStartEpochConsistency() {
        guard DeveloperMode.isEnabled else { return }
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(start_epoch) FROM device_events;", -1, &stmt, nil) == SQLITE_OK else {
            logger.error("verifyMaxKnownStartEpochConsistency prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            sqlite3_finalize(stmt)
            return
        }
        var dbMax: Int64 = -1
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            dbMax = sqlite3_column_int64(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if dbMax == maxKnownStartEpoch {
            DeveloperMode.debugPrint(.devCheck, "device_events max_start_epoch OK: in_memory=\(maxKnownStartEpoch) db=\(dbMax)")
        } else {
            DeveloperMode.debugPrint(.devCheck, """
            ############################################################
            MISMATCH: device_events max(start_epoch) drifted from the in-memory tracker!
            in-memory maxKnownStartEpoch = \(maxKnownStartEpoch)
            SELECT MAX(start_epoch) FROM device_events = \(dbMax)
            ############################################################
            """)
            logger.fault("device_events max_start_epoch MISMATCH in_memory=\(self.maxKnownStartEpoch, privacy: .public) db=\(dbMax, privacy: .public)")
        }
    }

    // MARK: - Settings (generic key/value JSON store)

    /// Reads and JSON-decodes a `setting` row's value, or `nil` if the row is missing or its
    /// value isn't a JSON object -- every `setting_value` is a JSON object by convention, see
    /// `database/009_setting.sql`.
    private func loadSettingJSON(name: String) -> [String: Any]? {
        guard let db else { return nil }
        var result: [String: Any]?
        let sql = "SELECT setting_value FROM setting WHERE setting_name = ?;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("setting lookup prepare failed name=\(name, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
                let json = String(cString: text)
                if let data = json.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result = object
                } else {
                    logger.error("setting name=\(name, privacy: .public) value is not a JSON object: \(json, privacy: .public)")
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// How often `HistoryIngestor` should re-fetch device history on a repeating timer (the
    /// `fetch_history_interval_seconds` setting, seeded to `10`; see `database/009_setting.sql`).
    /// Falls back to the seeded default if the row is missing or malformed.
    func loadFetchHistoryIntervalSeconds() -> TimeInterval {
        guard let seconds = loadSettingJSON(name: "fetch_history_interval_seconds")?["seconds"] as? Int else {
            return 10
        }
        return TimeInterval(seconds)
    }

    /// Whether locking the device via the app should also pause it first if it isn't already
    /// paused (the `pause_on_lock` setting, seeded to `true`; see `database/009_setting.sql`).
    /// Falls back to the seeded default if the row is missing or malformed.
    func loadPauseOnLockEnabled() -> Bool {
        guard let enabled = loadSettingJSON(name: "pause_on_lock")?["enabled"] as? Bool else {
            return true
        }
        return enabled
    }

    /// Whether the menu bar duration display includes seconds (the `display_seconds` setting,
    /// seeded to `true`; see `database/009_setting.sql`). Falls back to the seeded default if the
    /// row is missing or malformed.
    func loadDisplaySecondsEnabled() -> Bool {
        guard let enabled = loadSettingJSON(name: "display_seconds")?["enabled"] as? Bool else {
            return true
        }
        return enabled
    }

    /// Battery percentage at or below which the device is considered low on battery (the
    /// `low_battery_level` setting, seeded to `5`; see `database/009_setting.sql`). Falls back to
    /// the seeded default if the row is missing or malformed.
    func loadLowBatteryLevelPercent() -> Int {
        guard let percent = loadSettingJSON(name: "low_battery_level")?["percent"] as? Int else {
            return 5
        }
        return percent
    }

    /// Whether dev-only debug messages (`DeveloperMode.debugPrint`) are actually emitted to the
    /// terminal (the `debug` setting's `enabled` field, seeded to `true`; see
    /// `database/009_setting.sql`). Falls back to the seeded default if the row is missing or
    /// malformed. Lets a user turn terminal logging off (or back on) by editing this setting
    /// directly, without needing a rebuild -- see docs/TODO-devmode.md.
    func loadDebugEnabled() -> Bool {
        guard let enabled = loadSettingJSON(name: "debug")?["enabled"] as? Bool else {
            return true
        }
        return enabled
    }

    // MARK: - Device notifications (point-in-time, non-timing device events)

    /// Local-time-without-offset formatter matching the `<name>`/`<name>_timezone` column
    /// convention in `database/CLAUDE.md` (e.g. `2026-07-16T09:30:00`).
    private static let localTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()


    /// Records a point-in-time device notification (double tap, battery level, system state,
    /// device info, event log — see `TimeFlipEvent.deviceNotification`) so what the device sends
    /// and how often can be inspected later in `device_notifications`.
    @discardableResult
    func recordDeviceNotification(eventType: String, payload: String?, occurredAt: Date = Date()) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT INTO device_notifications (event_type_id, start_time, start_time_timezone, start_epoch, payload)
        VALUES ((SELECT event_type_id FROM event_type WHERE event_name = ?), ?, ?, ?, ?);
        """
        var success = false
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("device_notifications prepare failed event_type=\(eventType, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, eventType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, AppDataStore.localTimeFormatter.string(from: occurredAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, TimeZone.current.identifier, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(occurredAt.timeIntervalSince1970))
            if let payload {
                sqlite3_bind_text(stmt, 5, payload, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
                logger.debug("device_notifications event_type=\(eventType, privacy: .public) payload=\(payload ?? "nil", privacy: .public)")
            } else {
                logger.error("device_notifications insert failed event_type=\(eventType, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
        return success
    }

    /// Records one `DeveloperMode.debugPrint` message into `debug_log`, alongside printing it to
    /// the terminal, so a test session can be reconstructed from the database afterward -- see
    /// `DeveloperMode.logSink`, wired up once in `ApplicationDelegate.applicationDidFinishLaunching`.
    @discardableResult
    func recordDebugLog(tag: String, message: String, loggedAt: Date = Date()) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT INTO debug_log (logged_at, logged_at_timezone, tag, message)
        VALUES (?, ?, ?, ?);
        """
        var success = false
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("debug_log prepare failed tag=\(tag, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, AppDataStore.localTimeFormatter.string(from: loggedAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, TimeZone.current.identifier, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, tag, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, message, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
            } else {
                logger.error("debug_log insert failed tag=\(tag, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
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

    /// Both SwiftPM's own resource bundling and Swift Bundler's packaging flatten the `Database`
    /// resource directory's *contents* into the bundle root alongside every other resource (see
    /// `ActivityIconLoader.resolveURL`) — there's never an actual `Database` subdirectory to look
    /// up by name, in the packaged app or under `swift run`/`swift test`. Probe for a real DDL
    /// file by name (its containing directory is the resource root) rather than testing
    /// `resourceURL` for nil — `Bundle.main` always has *some* resource directory (e.g. the test
    /// host's), so a nil check alone wouldn't fall through to `Bundle.module` when it's wrong one.
    private static func resolveDatabaseDirectory() -> URL? {
        (Bundle.main.url(forResource: "001_event_type", withExtension: "sql")
            ?? Bundle.module.url(forResource: "001_event_type", withExtension: "sql"))?
            .deletingLastPathComponent()
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

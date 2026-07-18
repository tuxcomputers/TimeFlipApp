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
    /// were previously delivering to a different calendar, and this one is a switch rather
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
        // Only the real default path is symlink-managed (production.sqlite/test.sqlite), and only
        // under Developer Mode -- an explicit databaseURL means a caller (unit tests) wants an
        // isolated file of its own, and an end-user (non-dev-mode) build has no use for the
        // production/test split at all, so it just gets a plain appdata.sqlite file as before.
        if databaseURL == nil, DeveloperMode.isEnabled {
            AppDataStore.ensureDatabaseSymlink(at: url)
        }
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

    /// Looks up an existing `device_events` row by the exact `(event_number, start_epoch)` pair --
    /// the composite key `recordDeviceEvent` uses to recognize "I've already recorded this exact
    /// segment" (see that function's doc comment for why neither column alone is safe to use).
    /// Returns the row's `device_events_id`, or `nil` if no row matches both columns.
    private func selectDeviceEventsRowID(eventNumber: UInt32, startEpoch: Int64) -> Int64? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT device_events_id FROM device_events WHERE event_number = ? AND start_epoch = ?;",
            -1, &stmt, nil
        ) == SQLITE_OK else {
            logger.error("device_events rowid lookup prepare failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(eventNumber))
        sqlite3_bind_int64(stmt, 2, startEpoch)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Records a `device_events` row for a timing segment from the device's history stream.
    /// Matching -- "have I already recorded this exact segment?" -- is done on the composite
    /// `(event_number, start_epoch)` pair (via `selectDeviceEventsRowID`), not on either column
    /// alone:
    /// - `event_number` alone isn't safe: it's a counter maintained on the device itself, and a
    ///   device-side reset (e.g. a battery pull, or a reset from the official app) can make it
    ///   restart from a low number that an old row already used for a completely different,
    ///   long-past segment. Matching on `event_number` alone would then either silently overwrite
    ///   that unrelated old row, or (with `event_number` as a lone `UNIQUE` column) block the
    ///   new, legitimate segment from being inserted at all.
    /// - `start_epoch` alone isn't safe either: the device only reports whole-second timestamps
    ///   (`docs/TimeFlip2 BLE Protocol v4.3.md`'s 0x07/0x08 and the flip-timestamp field are both
    ///   "number of seconds", no finer resolution), so two genuinely different segments -- e.g. a
    ///   quick flip across a facet while searching for the right one, see the `blip_time` setting
    ///   -- can legitimately share the same `start_epoch` second.
    /// The combination of both is what's actually unique: the only way two different real segments
    /// collide on `(event_number, start_epoch)` is an exact coincidence of both a device reset AND
    /// the reused event_number landing in the same wall-clock second as the old segment it
    /// collides with -- vanishingly unlikely in practice. `UN1_device_events` enforces this as a
    /// composite unique index (not a lone `UNIQUE` on `event_number`), so a genuinely new segment
    /// can always be inserted even when its `event_number` has been reused after a reset.
    ///
    /// Ordering ("is this new segment newer than anything recorded so far?") is a separate
    /// question from matching, and is still decided purely by comparing `start_epoch` against
    /// `maxKnownStartEpoch` (an in-memory scalar loaded once at startup via
    /// `SELECT MAX(start_epoch)`) -- never `event_number`, for the same device-reset reason above.
    /// This is also not done via `ON CONFLICT DO UPDATE`, because that path still burns an
    /// AUTOINCREMENT id on every update and leaves permanent gaps in `device_events_id`.
    ///
    /// - A row already exists for `(event_number, start_epoch)`: this is a re-ingestion of a
    ///   segment already recorded -- either the still-open live frame growing in duration, or an
    ///   already-closed frame being resent. Updated in place; `finalised` is `0` only if
    ///   `start_epoch == maxKnownStartEpoch` (it's still the newest thing on record), else `1`.
    /// - No existing row, and `start_epoch > maxKnownStartEpoch` (a new high-water mark): any
    ///   previously-open row is closed out (`finalised` set to `1` wherever it isn't already), and
    ///   the new row is inserted with `finalised = 0` (it's now the in-progress segment -- always
    ///   the last frame in a history dump, per `docs/timeflip.md` §5). `maxKnownStartEpoch`
    ///   advances to `startEpoch`.
    /// - No existing row, but `start_epoch <= maxKnownStartEpoch`: a segment never seen before,
    ///   arriving out of chronological order (unusual, but not fatal) -- inserted already
    ///   `finalised = 1`, since it can't be the current live segment.
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

            if let existingRowID = selectDeviceEventsRowID(eventNumber: eventNumber, startEpoch: startEpoch) {
                let finalised = startEpoch == maxKnownStartEpoch ? false : true
                let sql = """
                UPDATE device_events SET
                    event_type_id = (SELECT event_type_id FROM event_type WHERE event_name = ?),
                    device_face = ?,
                    start_time = ?,
                    start_time_timezone = ?,
                    duration_seconds = ?,
                    is_paused = ?,
                    finalised = ?
                WHERE device_events_id = ?;
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
                sqlite3_bind_double(stmt, 5, durationSeconds)
                sqlite3_bind_int(stmt, 6, isPaused ? 1 : 0)
                sqlite3_bind_int(stmt, 7, finalised ? 1 : 0)
                sqlite3_bind_int64(stmt, 8, existingRowID)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = true
                    logger.debug("device_events ev=\(eventNumber, privacy: .public) face=\(deviceFace, privacy: .public) dur=\(durationSeconds, privacy: .public) paused=\(isPaused, privacy: .public) finalised=\(finalised, privacy: .public) inserted=false")
                } else {
                    logger.error("device_events update failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                }
                sqlite3_finalize(stmt)
            } else {
                let isNewMax = startEpoch > maxKnownStartEpoch
                if isNewMax {
                    if sqlite3_exec(db, "UPDATE device_events SET finalised = 1 WHERE finalised != 1;", nil, nil, nil) != SQLITE_OK {
                        logger.error("device_events close-out failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                    }
                }

                let sql = """
                INSERT INTO device_events (
                    event_number, event_type_id, device_face, start_time, start_time_timezone, start_epoch, duration_seconds, is_paused, finalised
                ) VALUES (
                    ?, (SELECT event_type_id FROM event_type WHERE event_name = ?), ?, ?, ?, ?, ?, ?, ?
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
                sqlite3_bind_int(stmt, 9, isNewMax ? 0 : 1)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = true
                    if isNewMax { maxKnownStartEpoch = startEpoch }
                    logger.debug("device_events ev=\(eventNumber, privacy: .public) face=\(deviceFace, privacy: .public) dur=\(durationSeconds, privacy: .public) paused=\(isPaused, privacy: .public) finalised=\(!isNewMax, privacy: .public) inserted=true")
                } else {
                    logger.error("device_events insert failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
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

    /// Which physical database file this is -- `"production"` or `"test"` (the `db_type` setting;
    /// see `database/009_setting.sql`). Set once when a database file is first created and never
    /// changed afterward; see `Tests/Interactive/README.md` for the test-database-switching
    /// workflow this backs. Falls back to `"production"` if the row is missing or malformed.
    func loadDbType() -> String {
        loadSettingJSON(name: "db_type")?["type"] as? String ?? "production"
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

    /// LED brightness percent (the `led_settings` setting's `brightness` field, seeded to `50`;
    /// see `database/009_setting.sql`). Falls back to the seeded default if the row is missing or
    /// malformed.
    func loadLEDBrightnessPercent() -> UInt8 {
        guard let percent = loadSettingJSON(name: "led_settings")?["brightness"] as? Int else {
            return 50
        }
        return UInt8(max(1, min(100, percent)))
    }

    /// LED blink interval in seconds (the `led_settings` setting's `blink_interval` field, seeded
    /// to `15`; see `database/009_setting.sql`). Falls back to the seeded default if the row is
    /// missing or malformed.
    func loadLEDBlinkIntervalSeconds() -> UInt8 {
        guard let seconds = loadSettingJSON(name: "led_settings")?["blink_interval"] as? Int else {
            return 15
        }
        return UInt8(max(5, min(60, seconds)))
    }

    /// Persists a new LED brightness percent to the `led_settings` row, leaving `blink_interval`
    /// untouched.
    func saveLEDBrightnessPercent(_ percent: UInt8) {
        saveSettingJSON(name: "led_settings", merging: ["brightness": Int(percent)])
    }

    /// Persists a new LED blink interval (seconds) to the `led_settings` row, leaving
    /// `brightness` untouched.
    func saveLEDBlinkIntervalSeconds(_ seconds: UInt8) {
        saveSettingJSON(name: "led_settings", merging: ["blink_interval": Int(seconds)])
    }

    /// Double-tap accelerometer register values (the `double_tap_settings` setting's
    /// `clickThreshold`/`limit`/`latency`/`window` fields; see `database/009_setting.sql`). Falls
    /// back to `DoubleTapParameters.default` -- itself, and per-field, if the row or an individual
    /// field is missing or malformed.
    func loadDoubleTapParameters() -> DoubleTapParameters {
        let fallback = DoubleTapParameters.default
        guard let json = loadSettingJSON(name: "double_tap_settings") else { return fallback }
        func byte(_ key: String, default defaultValue: UInt8) -> UInt8 {
            guard let value = json[key] as? Int else { return defaultValue }
            return UInt8(max(0, min(255, value)))
        }
        return DoubleTapParameters(
            clickThreshold: byte("clickThreshold", default: fallback.clickThreshold),
            limit: byte("limit", default: fallback.limit),
            latency: byte("latency", default: fallback.latency),
            window: byte("window", default: fallback.window)
        )
    }

    /// Whether double-tap detection is enabled (the `double_tap_settings` setting's `enabled`
    /// field, seeded to `true`; see `database/009_setting.sql`). Falls back to the seeded default
    /// if the row is missing or malformed.
    func loadDoubleTapEnabled() -> Bool {
        guard let enabled = loadSettingJSON(name: "double_tap_settings")?["enabled"] as? Bool else {
            return true
        }
        return enabled
    }

    /// Persists new double-tap accelerometer register values to the `double_tap_settings` row,
    /// leaving `enabled` untouched.
    func saveDoubleTapParameters(_ params: DoubleTapParameters) {
        saveSettingJSON(name: "double_tap_settings", merging: [
            "clickThreshold": Int(params.clickThreshold),
            "limit": Int(params.limit),
            "latency": Int(params.latency),
            "window": Int(params.window)
        ])
    }

    /// Persists a new enabled flag to the `double_tap_settings` row, leaving the accelerometer
    /// register values untouched.
    func saveDoubleTapEnabled(_ enabled: Bool) {
        saveSettingJSON(name: "double_tap_settings", merging: ["enabled": enabled])
    }

    /// Reads a `setting` row's current JSON value, merges `updates` into it, and writes the
    /// result back -- the row always already exists (seeded by `009_setting.sql`), so this is a
    /// plain `UPDATE`, not an upsert.
    private func saveSettingJSON(name: String, merging updates: [String: Any]) {
        guard let db else { return }
        var current = loadSettingJSON(name: name) ?? [:]
        for (key, value) in updates { current[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: current),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("saveSettingJSON encode failed name=\(name, privacy: .public)")
            return
        }
        let sql = "UPDATE setting SET setting_value = ? WHERE setting_name = ?;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("saveSettingJSON prepare failed name=\(name, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, name, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("saveSettingJSON exec failed name=\(name, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
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
        AppDataStore.runDatabaseDDL(on: db, logger: logger)
    }

    /// Runs every `.sql` file bundled under the `Database` resource directory, in filename order,
    /// against an arbitrary open handle -- shared by the instance's own `runDatabaseDDL()` above
    /// and by `ensureTestDatabaseExists(alongside:)`, which seeds a fresh `test.sqlite` without an
    /// `AppDataStore` instance of its own to seed it through.
    private static func runDatabaseDDL(on db: OpaquePointer, logger: Logger?) {
        guard let directory = resolveDatabaseDirectory() else {
            logger?.error("Could not locate bundled Database DDL directory")
            return
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "sql" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            logger?.error("Could not list Database DDL directory: \(error.localizedDescription, privacy: .public)")
            return
        }
        for file in files {
            guard let sql = try? String(contentsOf: file, encoding: .utf8) else {
                logger?.error("Could not read DDL file \(file.lastPathComponent, privacy: .public)")
                continue
            }
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                logger?.error("DDL file \(file.lastPathComponent, privacy: .public) failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
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

    /// Makes sure `appdata.sqlite` is a symlink to `production.sqlite`, not a plain file, so
    /// `scripts/use-test-database.sh`/`scripts/use-production-database.sh` can repoint it at
    /// `test.sqlite` for a testing session without touching real data (see
    /// `Tests/Interactive/README.md`). A no-op if it's already a symlink, whatever it currently
    /// points at -- this only ever runs the one-time migration for a plain file (an install from
    /// before this symlink scheme existed, or a fresh install with no database yet). Also ensures
    /// `test.sqlite` exists and is already seeded with `db_type: "test"`, every time this runs --
    /// so both database files are present together from the moment the symlink scheme is set up
    /// (or re-set-up after `run.sh --clean`), rather than `test.sqlite` only coming into being the
    /// first time a testing session actually switches to it. Internal (not private) so
    /// `AppDataStoreTests` can exercise it directly against a temp directory, independent of the
    /// `DeveloperMode.isEnabled` gate at its one production call site (`init`).
    static func ensureDatabaseSymlink(at url: URL) {
        let fileManager = FileManager.default
        let productionURL = url.deletingLastPathComponent().appendingPathComponent("production.sqlite")
        // destinationOfSymbolicLink(atPath:) throws for anything that isn't a symlink (missing
        // path, or a plain file) -- success alone is enough to confirm the migration already
        // happened, regardless of which file it currently resolves to.
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil {
            if fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: productionURL.path) {
                // Pre-existing real database from before this symlink scheme -- preserve it as
                // production.sqlite rather than let sqlite3_open silently create an empty file at
                // the symlink target below.
                try? fileManager.moveItem(at: url, to: productionURL)
            }
            if !fileManager.fileExists(atPath: url.path) {
                try? fileManager.createSymbolicLink(at: url, withDestinationURL: productionURL)
            }
        }
        ensureTestDatabaseExists(alongside: productionURL)
    }

    /// Creates and fully seeds `test.sqlite` next to `production.sqlite`, with its `db_type`
    /// overridden to `"test"`, if it doesn't already exist. A no-op otherwise -- an existing
    /// `test.sqlite`'s accumulated state is never reset just because this runs again.
    private static func ensureTestDatabaseExists(alongside productionURL: URL) {
        let testURL = productionURL.deletingLastPathComponent().appendingPathComponent("test.sqlite")
        guard !FileManager.default.fileExists(atPath: testURL.path) else { return }
        var handle: OpaquePointer?
        guard sqlite3_open(testURL.path, &handle) == SQLITE_OK, let handle else { return }
        defer { sqlite3_close(handle) }
        runDatabaseDDL(on: handle, logger: nil)
        sqlite3_exec(handle, "UPDATE setting SET setting_value = '{\"type\":\"test\"}' WHERE setting_name = 'db_type';", nil, nil, nil)
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

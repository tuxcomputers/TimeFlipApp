import Foundation
import OSLog
import SQLite3

/// A `time_entry` row reduced to what a daily total needs: which category the time counts against,
/// when it began, and how long it ran. `startedAt` comes from the joined `device_event.start_epoch`
/// rather than `time_entry.started_at`, which is local text carrying no offset.
struct TimeEntryRecord {
    let categoryID: Int
    let startedAt: Date
    let duration: TimeInterval
}

/// Which segment a `device_event` row is, in the only terms that identify one: the device's own
/// event number for it, plus the `start_epoch` saying which run of that counter it belongs to.
///
/// Both halves are needed because the number alone is ambiguous. A factory reset restarts the
/// counter at 1, so the same number names a different segment in each generation -- production holds
/// four of them, with event 3 appearing in three. `start_epoch` is what tells them apart, which is
/// why `UN1_device_event` is a composite index over the pair rather than a `UNIQUE` on the number.
struct RecordedEvent: Equatable {
    let eventNumber: UInt32
    /// Whole seconds since 1970, matching `device_event.start_epoch` -- the device reports whole
    /// seconds and nothing finer (`docs/TimeFlip2 BLE Protocol v4.3.md`).
    let startEpoch: Int64

    /// Whether a frame the device has just reported is the segment this row already holds, rather
    /// than a different segment that happens to reuse its number after a reset.
    ///
    /// Comparing the number alone would call a post-reset event 10 the same thing as a pre-reset
    /// event 10 and skip the fetch that would bring the intervening events in.
    func isSameSegment(as entry: TimeFlipHistoryEntry) -> Bool {
        guard let eventNumber = entry.eventNumber else { return false }
        return eventNumber == self.eventNumber
            && Int64(entry.startedAt.timeIntervalSince1970) == startEpoch
    }
}

/// What set a `time_entry` sweep going. Carried only so the debug log can say why a sweep ran:
/// the sweep itself behaves identically whichever it is, because it works out what needs doing by
/// asking the database rather than by being told.
///
/// Adding a case is how a new trigger joins in. Nothing coordinates them, and nothing needs to:
/// sweeping when there is nothing to convert costs one query, so a trigger that fires too often is
/// wasteful rather than wrong, and one that never fires only delays the work to the next trigger.
enum TimeEntrySweepTrigger: String {
    /// A face is about to be remapped to a different category, and the sweep runs **before** the
    /// remap. The one trigger where the ordering is load-bearing rather than incidental: an entry
    /// records the category the face was mapped to at the time, and that mapping is what is about
    /// to change, so anything still unconverted has to be converted while the old mapping is still
    /// the truth. See `updateFaceCategory`.
    case faceCategoryChange = "face-category-change"
    /// A batch of history finished ingesting. A backstop: `recordDeviceEvent` already converts as
    /// it goes, so this normally finds nothing, and is here to catch a row some future path
    /// finalises without going through it.
    case historyIngest = "history-ingest"
    /// App launch, which catches anything a previous run left unconverted, whether through a crash
    /// or through simply not having had this code yet.
    case launch = "launch"
}

/// A row from the `colour` reference table (`database/005_colour.sql`). `deviceHex` is the
/// "#rrggbb" LED value, `nil` for the `None` colour.
struct ColourRecord: Equatable, Sendable {
    let id: Int
    let name: String
    let deviceHex: String?
    /// `true` when the device drawn in this colour should take white inner lines and a white icon,
    /// because it is dark enough that black ones disappear into it. The outer outline stays black
    /// either way. Set per colour in `database/005_colour.sql` so it can be retuned by editing the
    /// row rather than by changing code.
    let usesWhiteLines: Bool
}

/// A row from the `icon` reference table (`database/004_icon.sql`).
struct IconRecord: Equatable, Sendable, Identifiable {
    let id: Int
    /// The asset name (e.g. `ic_meeting`) -- see `ActivityIconLoader`. `icon_id` 0 is the `None`
    /// sentinel, whose name is not an asset at all.
    let name: String
}

/// A row from the `category` table (`database/007_category.sql`).
struct CategoryRecord: Equatable, Sendable, Identifiable {
    let id: Int
    let name: String
    let iconID: Int
    let colourID: Int
    /// `false` once the category has been retired -- it stays in the table so historical
    /// `time_entry` rows keep resolving, but drops out of the assignment lists.
    var isActive: Bool
    /// Tracked time allowed against this category per day, in whole minutes (`0` = no limit).
    var dailyLimitMinutes: Int

    /// A copy with one field replaced, so a view holding a loaded list can reflect an edit it just
    /// wrote to the database without re-reading the table.
    func with(
        name: String? = nil,
        iconID: Int? = nil,
        colourID: Int? = nil,
        isActive: Bool? = nil,
        dailyLimitMinutes: Int? = nil
    ) -> CategoryRecord {
        CategoryRecord(
            id: id,
            name: name ?? self.name,
            iconID: iconID ?? self.iconID,
            colourID: colourID ?? self.colourID,
            isActive: isActive ?? self.isActive,
            dailyLimitMinutes: dailyLimitMinutes ?? self.dailyLimitMinutes
        )
    }

    /// Display order for the Categories tab: names that are entirely a number come first in
    /// numeric order, then everything else as text. A plain text sort interleaves them by digit --
    /// 1, 10, 11, 2, 20, 3 -- which reads as broken the moment categories are numbered.
    ///
    /// The text comparison is `localizedStandardCompare`, the same Finder-style ordering that sorts
    /// "ABC-2" before "ABC-10", so names with a number buried in them come out sensibly too.
    ///
    /// A name too long to fit an `Int` falls back to being treated as text -- an overflowed number
    /// is not a number this can order.
    static func displayOrder(_ lhs: CategoryRecord, _ rhs: CategoryRecord) -> Bool {
        switch (Int(lhs.name), Int(rhs.name)) {
        case let (lhsValue?, rhsValue?) where lhsValue != rhsValue:
            return lhsValue < rhsValue
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            // Either both are text, or both are the same number written differently ("1" / "01").
            // localizedStandardCompare compares digit runs numerically, so that second case comes
            // back .orderedSame and drops through to the id tiebreak below.
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // Duplicate names are a legitimate outcome of the create flow, so break the tie on id
            // rather than leaving two equal elements to an unstable sort.
            return lhs.id < rhs.id
        }
    }
}

// SQLite-backed application data.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AppDataStore {
    private let db: OpaquePointer?
    private let dbURL: URL
    private let queue = DispatchQueue(label: "com.timeflip.appdatastore")
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "app-data-store")

    // The highest device_event.start_epoch seen so far, loaded once at startup with a single
    // MAX() query and kept up to date in memory from then on. recordDeviceEvent uses it to choose
    // UPDATE vs INSERT itself instead of relying on ON CONFLICT DO UPDATE -- that path still
    // consumes an AUTOINCREMENT id on every update, leaving permanent gaps in device_event_id.
    // start_epoch (not event_number) is the ordering source of truth: event_number is a counter
    // maintained on the device itself, and a device-side reset can make it restart from a low
    // number while this table already holds higher event_number values from before the reset --
    // comparing event_number magnitudes would then treat a brand new event as older than history
    // it's actually superseding. -1 means "no rows yet" (MAX(start_epoch) is NULL on an empty
    // table) -- every real epoch value compares greater than -1, so the empty-table case always
    // takes the insert path without needing Optional handling at every comparison site.
    private var maxKnownStartEpoch: Int64 = -1

    // The `timezone.timezone_id` of the device's current IANA time zone, resolved once at startup
    // (get-or-create, see `resolveTimezoneID`) and bound into every date/time row's
    // `<name>_timezone_id` foreign key. Cached because the zone identifier changes only if the OS's
    // zone changes mid-session (a physical move, not DST — DST stays within the same IANA id).
    private var currentTimezoneID: Int64 = 0

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
        // Enforce foreign keys. SQLite defaults this OFF and it's per-connection (not stored in the
        // file), so the schema's REFERENCES clauses are otherwise inert. Enabling it keeps local
        // behaviour aligned with the eventual remote server (which enforces FKs) and catches orphans
        // early. Set before runDatabaseDDL() so seed inserts are validated -- which requires the DDL
        // files to be ordered parent-before-child (e.g. 006_project precedes 007_category).
        sqlite3_exec(handle, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        runDatabaseDDL()
        // Resolve the current time zone's id now (after the DDL has created/seeded nothing for it --
        // it's get-or-create), so every date/time insert below can bind a valid FK. Must run before
        // any recordDeviceEvent/recordDeviceNotification/recordDebugLog call (all of which happen
        // after init completes).
        currentTimezoneID = resolveTimezoneID(TimeZone.current.identifier)
        loadMaxKnownStartEpoch()
    }

    /// Seeds `maxKnownStartEpoch` from whatever `device_event` rows already exist on disk, so
    /// the update-vs-insert and finalised logic in `recordDeviceEvent` is correct across app
    /// restarts, not just within this process's lifetime. Leaves it at -1 (see property comment)
    /// when the table is empty and `MAX(start_epoch)` comes back NULL.
    private func loadMaxKnownStartEpoch() {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(start_epoch) FROM device_event;", -1, &stmt, nil) == SQLITE_OK else {
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

    /// Get-or-create the `timezone` row for an IANA identifier and return its `timezone_id`.
    /// Called once at startup (from `init`, before any concurrent access) for the current zone; the
    /// date/time tables reference the result via their `<name>_timezone_id` foreign key instead of
    /// storing the identifier text on every row. Returns `0` on failure — no real row has id `0`
    /// (the table is unseeded and autoincrements from 1), so a write binding `0` fails its FK check
    /// rather than silently pointing at a wrong zone.
    private func resolveTimezoneID(_ identifier: String) -> Int64 {
        guard let db else { return 0 }
        var sel: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT timezone_id FROM timezone WHERE timezone_name = ?;", -1, &sel, nil) == SQLITE_OK {
            sqlite3_bind_text(sel, 1, identifier, -1, SQLITE_TRANSIENT)
            if sqlite3_step(sel) == SQLITE_ROW {
                let id = sqlite3_column_int64(sel, 0)
                sqlite3_finalize(sel)
                return id
            }
        }
        sqlite3_finalize(sel)
        var ins: OpaquePointer?
        defer { sqlite3_finalize(ins) }
        guard sqlite3_prepare_v2(db, "INSERT INTO timezone (timezone_name) VALUES (?);", -1, &ins, nil) == SQLITE_OK else {
            logger.error("resolveTimezoneID prepare failed for \(identifier, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return 0
        }
        sqlite3_bind_text(ins, 1, identifier, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(ins) == SQLITE_DONE else {
            logger.error("resolveTimezoneID insert failed for \(identifier, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return 0
        }
        return sqlite3_last_insert_rowid(db)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Device events (new schema; timing segments -- face flips and pauses)

    /// Looks up an existing `device_event` row by the exact `(event_number, start_epoch)` pair --
    /// the composite key `recordDeviceEvent` uses to recognize "I've already recorded this exact
    /// segment" (see that function's doc comment for why neither column alone is safe to use).
    /// Returns the row's `device_event_id`, or `nil` if no row matches both columns.
    private func selectDeviceEventsRowID(eventNumber: UInt32, startEpoch: Int64) -> Int64? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT device_event_id FROM device_event WHERE event_number = ? AND start_epoch = ?;",
            -1, &stmt, nil
        ) == SQLITE_OK else {
            logger.error("device_event rowid lookup prepare failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(eventNumber))
        sqlite3_bind_int64(stmt, 2, startEpoch)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Records a `device_event` row for a timing segment from the device's history stream.
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
    ///   quick flip across a face while searching for the right one, see the `blip_time` setting
    ///   -- can legitimately share the same `start_epoch` second.
    /// The combination of both is what's actually unique: the only way two different real segments
    /// collide on `(event_number, start_epoch)` is an exact coincidence of both a device reset AND
    /// the reused event_number landing in the same wall-clock second as the old segment it
    /// collides with -- vanishingly unlikely in practice. `UN1_device_event` enforces this as a
    /// composite unique index (not a lone `UNIQUE` on `event_number`), so a genuinely new segment
    /// can always be inserted even when its `event_number` has been reused after a reset.
    ///
    /// Ordering ("is this new segment newer than anything recorded so far?") is a separate
    /// question from matching, and is still decided purely by comparing `start_epoch` against
    /// `maxKnownStartEpoch` (an in-memory scalar loaded once at startup via
    /// `SELECT MAX(start_epoch)`) -- never `event_number`, for the same device-reset reason above.
    /// This is also not done via `ON CONFLICT DO UPDATE`, because that path still burns an
    /// AUTOINCREMENT id on every update and leaves permanent gaps in `device_event_id`.
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
        let eventType = isPaused ? "pause" : "face_flip"
        var success = false
        var conversion = ConversionOutcome()
        queue.sync {
            let startEpoch = Int64(startedAt.timeIntervalSince1970)

            if let existingRowID = selectDeviceEventsRowID(eventNumber: eventNumber, startEpoch: startEpoch) {
                let finalised = startEpoch == maxKnownStartEpoch ? false : true
                let sql = """
                UPDATE device_event SET
                    event_type_id = (SELECT event_type_id FROM event_type WHERE event_name = ?),
                    device_face = ?,
                    start_time = ?,
                    timezone_id = ?,
                    duration_seconds = ?,
                    paused = ?,
                    finalised = ?
                WHERE device_event_id = ?;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    logger.error("device_event update prepare failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                    sqlite3_finalize(stmt)
                    return
                }
                sqlite3_bind_text(stmt, 1, eventType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(deviceFace))
                sqlite3_bind_text(stmt, 3, AppDataStore.localTimeFormatter.string(from: startedAt), -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 4, currentTimezoneID)
                sqlite3_bind_double(stmt, 5, durationSeconds)
                sqlite3_bind_int(stmt, 6, isPaused ? 1 : 0)
                sqlite3_bind_int(stmt, 7, finalised ? 1 : 0)
                sqlite3_bind_int64(stmt, 8, existingRowID)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = true
                    logger.debug("device_event ev=\(eventNumber, privacy: .public) face=\(deviceFace, privacy: .public) dur=\(durationSeconds, privacy: .public) paused=\(isPaused, privacy: .public) finalised=\(finalised, privacy: .public) inserted=false")
                } else {
                    logger.error("device_event update failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                }
                sqlite3_finalize(stmt)
            } else {
                let isNewMax = startEpoch > maxKnownStartEpoch
                if isNewMax {
                    if sqlite3_exec(db, "UPDATE device_event SET finalised = 1 WHERE finalised != 1;", nil, nil, nil) != SQLITE_OK {
                        logger.error("device_event close-out failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                    }
                }

                let sql = """
                INSERT INTO device_event (
                    event_number, event_type_id, device_face, start_time, timezone_id, start_epoch, duration_seconds, paused, finalised
                ) VALUES (
                    ?, (SELECT event_type_id FROM event_type WHERE event_name = ?), ?, ?, ?, ?, ?, ?, ?
                );
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    logger.error("device_event insert prepare failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                    sqlite3_finalize(stmt)
                    return
                }
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(eventNumber))
                sqlite3_bind_text(stmt, 2, eventType, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(deviceFace))
                sqlite3_bind_text(stmt, 4, AppDataStore.localTimeFormatter.string(from: startedAt), -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 5, currentTimezoneID)
                sqlite3_bind_int64(stmt, 6, startEpoch)
                sqlite3_bind_double(stmt, 7, durationSeconds)
                sqlite3_bind_int(stmt, 8, isPaused ? 1 : 0)
                sqlite3_bind_int(stmt, 9, isNewMax ? 0 : 1)
                if sqlite3_step(stmt) == SQLITE_DONE {
                    success = true
                    if isNewMax { maxKnownStartEpoch = startEpoch }
                    logger.debug("device_event ev=\(eventNumber, privacy: .public) face=\(deviceFace, privacy: .public) dur=\(durationSeconds, privacy: .public) paused=\(isPaused, privacy: .public) finalised=\(!isNewMax, privacy: .public) inserted=true")
                } else {
                    logger.error("device_event insert failed ev=\(eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                }
                sqlite3_finalize(stmt)
            }
            conversion = createTimeEntriesForFinalisedEvents()
        }
        // Outside the lock: see ConversionOutcome for why this cannot happen where it is produced.
        emit(conversion)
        return success
    }

    /// Turns newly finalised segments into `time_entry` rows. The normal path, run at the end of
    /// every `recordDeviceEvent`, which is where finalising actually happens and happens three
    /// different ways: the in-place update flipping a row's `finalised` to 1, the close-out
    /// `UPDATE ... WHERE finalised != 1` when a newer segment arrives, and an out-of-order segment
    /// inserted already finalised. Rather than hooking each, this asks the question they all lead
    /// to, so a fourth path added later cannot forget to call it.
    ///
    /// **Must be called on `queue`**, and is, from inside `recordDeviceEvent`'s `queue.sync`. It
    /// deliberately does not take the lock itself: `queue` is serial, so re-entering would deadlock.
    ///
    /// Scoped by `processed = 0`, which is what makes it cheap enough to run on every event: the
    /// flag is a marker of work already done, so skipping those rows skips almost the whole table.
    /// The cost of trusting the flag is that a row wrongly marked is invisible here, and that is
    /// exactly what `sweepTimeEntries(trigger:)` exists to find.
    private func createTimeEntriesForFinalisedEvents() -> ConversionOutcome {
        convertEligibleEvents(extraConditions: "AND de.processed = 0", label: "finalised")
    }

    /// Finds and fixes `device_event` rows that should have a `time_entry` and do not, **including
    /// ones already marked `processed`**.
    ///
    /// A different job from `createTimeEntriesForFinalisedEvents`, despite converting the same way.
    /// That one trusts `processed` so it can run constantly for almost nothing; this one ignores it
    /// on purpose, because a row marked done with no entry to show for it is a broken record, and
    /// the only way to find one is to look where the flag says not to. Its time is otherwise
    /// missing from every total, silently and permanently -- nothing else would ever notice.
    ///
    /// Safe to call from anywhere, as often as anything likes: it asks the database what is wrong
    /// rather than being told, so a caller needs to know only that *something* happened, never
    /// which rows. Firing when there is nothing to fix costs one query. That is what lets the
    /// trigger list grow without any of the triggers having to coordinate.
    ///
    /// Returns how many entries it created, which for this function is a defect count rather than
    /// a throughput figure: anything above zero means something upstream failed to convert a row it
    /// should have, and the debug log names each one.
    @discardableResult
    func sweepTimeEntries(trigger: TimeEntrySweepTrigger) -> Int {
        var outcome = ConversionOutcome()
        queue.sync {
            outcome = convertEligibleEvents(extraConditions: "", label: "sweep/\(trigger.rawValue)")
        }
        emit(outcome)
        return outcome.created
    }

    /// What a conversion pass did, carried back out of the lock so it can be logged from outside.
    ///
    /// **The messages cannot be logged where they are produced.** `DeveloperMode.debugPrint` runs
    /// `logSink`, which the app points at `recordDebugLog`, which takes `queue` -- so logging from
    /// inside `queue.sync` re-enters a serial queue and traps. It did: the app died on launch with
    /// exit status 5 immediately after the first entry was created (2026-08-03).
    ///
    /// The unit suite could not have caught it. `logSink` is only wired in
    /// `applicationDidFinishLaunching`, so under `swift test` it is nil and `debugPrint` returns
    /// without touching the database. Twelve passing tests and a crash on the first real launch.
    private struct ConversionOutcome {
        var created = 0
        var messages: [String] = []
    }

    /// `blip_time` in seconds, read **while `queue` is already held**.
    ///
    /// Deliberately not `loadBlipTimeSeconds()`, which goes through `loadSettingJSON` and takes the
    /// queue: calling that from inside the lock would re-enter a serial queue and trap, the same way
    /// logging from in here did. Clamped like the public loader, so a hand-edited row cannot make
    /// the conversion discard more than the App tab is willing to set.
    private func blipTimeSecondsLocked() -> Int {
        guard let db else { return TimeFlipConstants.defaultBlipTimeSeconds }
        var seconds = TimeFlipConstants.defaultBlipTimeSeconds
        var stmt: OpaquePointer?
        let sql = "SELECT json_extract(setting_value, '$.seconds') FROM setting WHERE setting_name = 'blip_time';"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW,
           sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            seconds = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        return max(
            TimeFlipConstants.minBlipTimeSeconds,
            min(TimeFlipConstants.maxBlipTimeSeconds, seconds)
        )
    }

    /// Logs a pass's messages. Call **after** `queue.sync` has returned, never inside it.
    private func emit(_ outcome: ConversionOutcome) {
        for message in outcome.messages {
            DeveloperMode.debugPrint(.timeEntry, message)
        }
    }

    /// The conversion both paths share, differing only in how much of the table they look at.
    /// **Must be called on `queue`.**
    ///
    /// The base test is `paused = 0`, `finalised = 1`, and not already in `time_entry`. Membership
    /// of `time_entry` is the single source of truth for whether an event has been converted, and
    /// `UN1_time_entry` enforces it, so `processed` records the outcome rather than deciding it and
    /// is allowed to be wrong. `extraConditions` is how the cheap path narrows that to rows the
    /// flag has not already claimed.
    ///
    /// A paused segment is never converted and so keeps `processed = 0` for as long as it exists.
    /// The flag means "the conversion has dealt with this", a pause is never something it deals
    /// with, and there is nothing to mark.
    ///
    /// **Blips are skipped, not merged.** A segment shorter than `blip_time` is the cube being
    /// turned past a face rather than time spent on it, so it gets no entry and is marked
    /// `processed = 1` -- which is what keeps the eligible set draining instead of growing a
    /// permanent tail of rows every pass has to re-examine. The `time_entry` insert happens after
    /// this test, so a skipped blip can never be mistaken for the "marked processed with no entry"
    /// defect the sweep hunts for.
    ///
    /// The spec once called for merging a blip's duration into the following segment instead. That
    /// is deliberately not done: it needs a `duration_seconds` this data does not reliably have (a
    /// segment the next event proves ran three seconds can be stored as `0.0`, see production
    /// `device_event` 28), and losing a handful of seconds per pass-over is the cheaper mistake.
    ///
    /// One consequence worth knowing. **Lowering `blip_time` makes previously-skipped segments
    /// convert**, since they are still `NOT IN time_entry` and the sweep ignores `processed` -- and
    /// they will be reported as REPAIRED, because from here that is indistinguishable from the real
    /// defect. Raising it changes nothing: entries already made stay made.
    private func convertEligibleEvents(extraConditions: String, label: String) -> ConversionOutcome {
        var outcome = ConversionOutcome()
        guard let db else { return outcome }

        let blipTimeSeconds = blipTimeSecondsLocked()

        // Row by row rather than one INSERT ... SELECT, so each conversion can be logged against
        // the event it came from. At these volumes the difference is unmeasurable, and a log line
        // naming the event and face is worth more than the lower statement count.
        let selectSQL = """
        SELECT de.device_event_id, de.event_number, de.device_face, de.start_time, de.timezone_id,
               de.start_epoch, de.duration_seconds, de.processed, f.category_id
        FROM device_event de
        JOIN face f ON f.face_id = de.device_face
        WHERE de.paused = 0
          AND de.finalised = 1
          AND de.device_event_id NOT IN (SELECT device_event_id FROM time_entry)
          \(extraConditions)
        ORDER BY de.device_event_id;
        """
        struct Convertible {
            let deviceEventID: Int64
            let eventNumber: Int64
            let deviceFace: Int32
            let startTime: String
            let timezoneID: Int64
            let startEpoch: Int64
            let durationSeconds: Double
            let wasMarkedProcessed: Bool
            let categoryID: Int64
        }
        var pending: [Convertible] = []
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK {
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                pending.append(Convertible(
                    deviceEventID: sqlite3_column_int64(selectStmt, 0),
                    eventNumber: sqlite3_column_int64(selectStmt, 1),
                    deviceFace: sqlite3_column_int(selectStmt, 2),
                    startTime: String(cString: sqlite3_column_text(selectStmt, 3)),
                    timezoneID: sqlite3_column_int64(selectStmt, 4),
                    startEpoch: sqlite3_column_int64(selectStmt, 5),
                    durationSeconds: sqlite3_column_double(selectStmt, 6),
                    wasMarkedProcessed: sqlite3_column_int(selectStmt, 7) == 1,
                    categoryID: sqlite3_column_int64(selectStmt, 8)
                ))
            }
        } else {
            logger.error("time_entry select failed (\(label, privacy: .public)): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            outcome.messages.append("\(label): select failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(selectStmt)

        var skippedAsBlips: [Int64] = []
        for row in pending {
            // 0 disables the filter, so nothing is ever short enough. Strictly less than, so a
            // segment exactly as long as the threshold is kept -- the setting reads "ignore flips
            // under N", and a 5-second segment is not under 5.
            if blipTimeSeconds > 0, row.durationSeconds < Double(blipTimeSeconds) {
                skippedAsBlips.append(row.deviceEventID)
                // Only on the first pass to see it. Marking it processed below is what stops this
                // repeating, since every later pass finds it already flagged.
                if !row.wasMarkedProcessed {
                    outcome.messages.append(
                        "\(label): skipped ev=\(row.eventNumber) face=\(row.deviceFace) dur=\(row.durationSeconds)s -- under blip_time=\(blipTimeSeconds)s"
                    )
                }
                continue
            }
            // `ended_at` is start + duration converted back to local time, carrying the segment's
            // start zone: the device reports a start and a length, never an end, so nothing here
            // could tell us the zone changed mid-segment. The bound value is an integer because
            // duration is REAL while the column stores whole seconds.
            let insertSQL = """
            INSERT INTO time_entry (
                category_id, device_event_id, started_at, start_timezone_id, ended_at, end_timezone_id, duration_seconds
            ) VALUES (
                ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%S', ?, 'unixepoch', 'localtime'), ?, ?
            );
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("time_entry insert prepare failed ev=\(row.eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                continue
            }
            sqlite3_bind_int64(stmt, 1, row.categoryID)
            sqlite3_bind_int64(stmt, 2, row.deviceEventID)
            sqlite3_bind_text(stmt, 3, row.startTime, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, row.timezoneID)
            sqlite3_bind_int64(stmt, 5, row.startEpoch + Int64(row.durationSeconds))
            sqlite3_bind_int64(stmt, 6, row.timezoneID)
            sqlite3_bind_double(stmt, 7, row.durationSeconds)
            if sqlite3_step(stmt) == SQLITE_DONE {
                outcome.created += 1
                // A row already marked processed had no entry, which nothing upstream should ever
                // leave behind. Logged loudly and separately, because it is a defect report rather
                // than a routine conversion.
                if row.wasMarkedProcessed {
                    logger.error("time_entry REPAIRED ev=\(row.eventNumber, privacy: .public): marked processed with no entry")
                    outcome.messages.append(
                        "\(label): REPAIRED ev=\(row.eventNumber) face=\(row.deviceFace) dur=\(row.durationSeconds)s -- was marked processed with no entry"
                    )
                } else {
                    outcome.messages.append(
                        "\(label): created ev=\(row.eventNumber) face=\(row.deviceFace) dur=\(row.durationSeconds)s cat=\(row.categoryID)"
                    )
                }
            } else {
                logger.error("time_entry insert failed ev=\(row.eventNumber, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                outcome.messages.append("\(label): insert failed ev=\(row.eventNumber): \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        }

        // Skipped blips are marked too, so they stop being re-examined. Done as one statement over
        // the ids collected above rather than by re-deriving the duration test in SQL, so the rule
        // lives in exactly one place.
        if !skippedAsBlips.isEmpty {
            let ids = skippedAsBlips.map(String.init).joined(separator: ",")
            if sqlite3_exec(db, "UPDATE device_event SET processed = 1 WHERE device_event_id IN (\(ids));", nil, nil, nil) != SQLITE_OK {
                logger.error("blip processed update failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                outcome.messages.append("\(label): blip processed update failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Driven off `time_entry` rather than off what this pass just inserted, so an event whose
        // flag an interrupted run never set is brought back into step here.
        let markProcessed = """
        UPDATE device_event SET processed = 1
        WHERE processed = 0
          AND device_event_id IN (SELECT device_event_id FROM time_entry);
        """
        if sqlite3_exec(db, markProcessed, nil, nil, nil) != SQLITE_OK {
            logger.error("device_event processed update failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            outcome.messages.append("\(label): processed update failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        // Stamped whether or not anything was created: it records when the check last ran, and one
        // that found nothing still ran. Stamping only on success would make "working, nothing to
        // do" indistinguishable from "not running at all", which is the question this row exists to
        // answer.
        let stamp = """
        UPDATE setting
        SET setting_value = json_set(setting_value, '$.last_check', strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime'))
        WHERE setting_name = 'time_entry_check';
        """
        if sqlite3_exec(db, stamp, nil, nil, nil) != SQLITE_OK {
            logger.error("time_entry_check stamp failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
        }

        if outcome.created > 0 {
            logger.notice("time_entry \(label, privacy: .public) created=\(outcome.created, privacy: .public)")
        }
        return outcome
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
        guard sqlite3_prepare_v2(db, "SELECT MAX(start_epoch) FROM device_event;", -1, &stmt, nil) == SQLITE_OK else {
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
            DeveloperMode.debugPrint(.devCheck, "device_event max_start_epoch OK: in_memory=\(maxKnownStartEpoch) db=\(dbMax)")
        } else {
            DeveloperMode.debugPrint(.devCheck, """
            ############################################################
            MISMATCH: device_event max(start_epoch) drifted from the in-memory tracker!
            in-memory maxKnownStartEpoch = \(maxKnownStartEpoch)
            SELECT MAX(start_epoch) FROM device_event = \(dbMax)
            ############################################################
            """)
            logger.fault("device_event max_start_epoch MISMATCH in_memory=\(self.maxKnownStartEpoch, privacy: .public) db=\(dbMax, privacy: .public)")
        }
    }

    // MARK: - Settings (generic key/value JSON store)

    /// Reads and JSON-decodes a `setting` row's value, or `nil` if the row is missing or its
    /// value isn't a JSON object -- every `setting_value` is a JSON object by convention, see
    /// `database/011_setting.sql`.
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

    /// All rows of the `colour` reference table (`database/005_colour.sql`), ordered by
    /// `colour_id`. Drives the face colour picker; see `ActivityLibrary.colorOptions(from:)`.
    func loadColours() -> [ColourRecord] {
        guard let db else { return [] }
        var results: [ColourRecord] = []
        let sql = "SELECT colour_id, colour_name, device_hex, white_lines FROM colour ORDER BY colour_id;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("colour load prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(stmt, 0))
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let hex = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let usesWhiteLines = sqlite3_column_int64(stmt, 3) != 0
                results.append(ColourRecord(id: id, name: name, deviceHex: hex, usesWhiteLines: usesWhiteLines))
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    /// Each physical face paired with the category it is assigned to, keyed by `face_id`
    /// (`database/008_face.sql`). Unlike `loadCategories`, this keeps `category_id` 0: a face
    /// assigned to the `Unassigned` sentinel still has to resolve to something to display.
    func loadFaceCategories() -> [UInt8: CategoryRecord] {
        guard let db else { return [:] }
        var results: [UInt8: CategoryRecord] = [:]
        let sql = """
        SELECT f.face_id, c.category_id, c.category_name, c.icon_id, c.colour_id, c.active, c.daily_limit
        FROM face f
        JOIN category c ON c.category_id = f.category_id
        ORDER BY f.face_id;
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("face category load prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let faceID = UInt8(truncatingIfNeeded: sqlite3_column_int64(stmt, 0))
                let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                results[faceID] = CategoryRecord(
                    id: Int(sqlite3_column_int64(stmt, 1)),
                    name: name,
                    iconID: Int(sqlite3_column_int64(stmt, 3)),
                    colourID: Int(sqlite3_column_int64(stmt, 4)),
                    isActive: sqlite3_column_int64(stmt, 5) != 0,
                    dailyLimitMinutes: Int(sqlite3_column_int64(stmt, 6))
                )
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    /// Which faces are locked, keyed by `face_id` (`database/008_face.sql`). A locked face is one
    /// the user wants to keep permanently, so its category can't be reassigned by accident.
    func loadFaceLocks() -> [UInt8: Bool] {
        guard let db else { return [:] }
        var results: [UInt8: Bool] = [:]
        let sql = "SELECT face_id, locked FROM face ORDER BY face_id;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("face lock load prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let faceID = UInt8(truncatingIfNeeded: sqlite3_column_int64(stmt, 0))
                results[faceID] = sqlite3_column_int64(stmt, 1) != 0
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    /// Locks or unlocks a face -- the lock control on the Faces tab. Same `face_id` guard as
    /// `updateFaceCategory`, for the same reason.
    func updateFaceLocked(faceID: UInt8, locked: Bool) {
        guard let db else { return }
        let sql = """
        UPDATE face SET locked = ?
        WHERE face_id = ? AND face_id BETWEEN \(TimeFlipConstants.minFaceID) AND \(TimeFlipConstants.maxFaceID);
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("face lock update prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, locked ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, Int64(faceID))
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("face lock update exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// All rows of the `icon` reference table (`database/004_icon.sql`), ordered by `icon_id`.
    /// Drives the Categories tab's icon grid, which skips the `None` sentinel at id 0.
    func loadIcons() -> [IconRecord] {
        guard let db else { return [] }
        var results: [IconRecord] = []
        let sql = "SELECT icon_id, icon_name FROM icon ORDER BY icon_id;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("icon load prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(stmt, 0))
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                results.append(IconRecord(id: id, name: name))
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    /// All real (`category_id >= 1`, excluding the `Unassigned` sentinel at id 0) rows of the
    /// `category` table (`database/007_category.sql`). Both active and inactive ones -- the
    /// Categories tab lists each in its own section, so splitting this into two queries would just
    /// mean reading the same small table twice.
    ///
    /// Ordered by `CategoryRecord.displayOrder` rather than in SQL: the ordering needs a numeric
    /// pass over names that are numbers, which SQLite can only express as a pile of CASE/GLOB
    /// clauses that are harder to read and impossible to unit test.
    func loadCategories() -> [CategoryRecord] {
        guard let db else { return [] }
        var results: [CategoryRecord] = []
        let sql = """
        SELECT c.category_id, c.category_name, c.icon_id, c.colour_id, c.active, c.daily_limit
        FROM category c
        WHERE c.category_id >= 1;
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category load prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(stmt, 0))
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let iconID = Int(sqlite3_column_int64(stmt, 2))
                let colourID = Int(sqlite3_column_int64(stmt, 3))
                let isActive = sqlite3_column_int64(stmt, 4) != 0
                let dailyLimitMinutes = Int(sqlite3_column_int64(stmt, 5))
                results.append(CategoryRecord(
                    id: id,
                    name: name,
                    iconID: iconID,
                    colourID: colourID,
                    isActive: isActive,
                    dailyLimitMinutes: dailyLimitMinutes
                ))
            }
            sqlite3_finalize(stmt)
        }
        return results.sorted(by: CategoryRecord.displayOrder)
    }

    /// Assigns a category to a physical face -- the Faces tab's category list. See
    /// `database/008_face.sql`.
    ///
    /// The `face_id` guard keeps the write to the 12 real faces, so the `unassignedFaceID`
    /// sentinel (face `0`, what `currentFaceID` reads before the device has reported a face)
    /// can't create a thirteenth row.
    ///
    /// A locked face is refused here as well as in the UI. Locking exists to stop a face being
    /// reassigned by accident, and a guard the UI alone enforces is one a stale view can walk past.
    ///
    /// **Sweeps first, and the order is the whole point.** A `time_entry` records the category the
    /// face was mapped to *when the segment happened* (`docs/operation-spec.md` § 3), and the only
    /// place that mapping is written down is this row, which is about to change. Any segment still
    /// waiting to be converted would be converted against the new category and recorded as time
    /// spent on something the user was not doing. Converting everything pending before the write
    /// closes that window: afterwards the entries are already made and carry the old category, and
    /// only segments that happen from now on take the new one.
    func updateFaceCategory(faceID: UInt8, categoryID: Int) {
        guard let db else { return }
        sweepTimeEntries(trigger: .faceCategoryChange)
        let sql = """
        UPDATE face SET category_id = ?
        WHERE face_id = ? AND locked = 0
          AND face_id BETWEEN \(TimeFlipConstants.minFaceID) AND \(TimeFlipConstants.maxFaceID);
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("face category update prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(categoryID))
            sqlite3_bind_int64(stmt, 2, Int64(faceID))
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("face category update exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Sets `colour_id` directly on a category -- the Categories tab's own colour picker. The
    /// `category_id >= 1` guard means the `Unassigned` category (`category_id 0`) is never given
    /// a colour. See `database/007_category.sql`.
    func updateCategoryColour(categoryID: Int, colourID: Int) {
        guard let db else { return }
        let sql = "UPDATE category SET colour_id = ? WHERE category_id = ? AND category_id >= 1;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category colour update prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(colourID))
            sqlite3_bind_int64(stmt, 2, Int64(categoryID))
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("category colour update exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Sets `daily_limit` (whole minutes, `0` = no limit) on a category -- the Categories tab's own
    /// daily-limit field. Same `category_id >= 1` guard as `updateCategoryColour`: the
    /// `Unassigned` sentinel never carries a limit. See `database/007_category.sql`.
    ///
    /// Nothing reads this value yet -- it is stored for a limit-tracking feature still to be
    /// built (see `docs/TODO-features-under-development.md`).
    func updateCategoryDailyLimit(categoryID: Int, minutes: Int) {
        guard let db else { return }
        let sql = "UPDATE category SET daily_limit = ? WHERE category_id = ? AND category_id >= 1;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category daily limit update prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, minutes)))
            sqlite3_bind_int64(stmt, 2, Int64(categoryID))
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("category daily limit update exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Every category carrying this name, best match first: the active one if there is any, then
    /// the retired ones oldest first. At most one can be active (`UN1_category`), so this is one
    /// row plus however many retired namesakes have built up behind it.
    ///
    /// `findCategory(named:)` answers the same question with `LIMIT 1`, which is all most callers
    /// want. This exists because the create flow has to know when there is more than one retired
    /// row to reinstate: with only the first, it would offer to bring one back and silently pick.
    func findCategories(named name: String) -> [CategoryRecord] {
        guard let db, !name.isEmpty else { return [] }
        var results: [CategoryRecord] = []
        let sql = """
        SELECT category_id, category_name, icon_id, colour_id, active, daily_limit
        FROM category
        WHERE category_name = ? COLLATE NOCASE
        ORDER BY active DESC, category_id ASC;
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category find-all prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(CategoryRecord(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    name: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                    iconID: Int(sqlite3_column_int64(stmt, 2)),
                    colourID: Int(sqlite3_column_int64(stmt, 3)),
                    isActive: sqlite3_column_int64(stmt, 4) != 0,
                    dailyLimitMinutes: Int(sqlite3_column_int64(stmt, 5))
                ))
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    /// The category carrying this name, if any. Matched `COLLATE NOCASE`: someone typing
    /// "meeting" when "Meeting" exists has made exactly the mistake this lookup is meant to catch,
    /// so case is not what should distinguish them.
    ///
    /// Unlike `loadCategories` this does not exclude `category_id` 0 -- typing "Unassigned" is a
    /// collision with the sentinel and needs reporting rather than silently failing to insert.
    func findCategory(named name: String) -> CategoryRecord? {
        guard let db, !name.isEmpty else { return nil }
        var result: CategoryRecord?
        // An active row always wins, then the oldest. Only one active row can hold a name
        // (`UN1_category`), but inactive namesakes may sit alongside it, and answering with one of
        // those would have the tab offer to reinstate a category whose name is already taken --
        // which the index then refuses. Ordering also makes the answer stable, since the callers
        // act on whichever row comes back.
        let sql = """
        SELECT category_id, category_name, icon_id, colour_id, active, daily_limit
        FROM category
        WHERE category_name = ? COLLATE NOCASE
        ORDER BY active DESC, category_id ASC
        LIMIT 1;
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category find prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = CategoryRecord(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    name: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                    iconID: Int(sqlite3_column_int64(stmt, 2)),
                    colourID: Int(sqlite3_column_int64(stmt, 3)),
                    isActive: sqlite3_column_int64(stmt, 4) != 0,
                    dailyLimitMinutes: Int(sqlite3_column_int64(stmt, 5))
                )
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// Inserts a category, active, with the `None` icon and colour and no daily limit, and returns
    /// its new `category_id` -- `nil` if nothing was inserted. The caller is expected to have
    /// trimmed the name; an empty one is rejected here rather than stored.
    ///
    /// The id is read back from the insert rather than left to the caller to look up by name,
    /// because a name is not a key here: creating a second category with a name an inactive one
    /// already holds is a legitimate outcome (see `findCategory(named:)`'s callers), and a
    /// name lookup afterwards would find that older row instead of this one.
    ///
    /// A plain insert: whether the name is already taken is settled by the caller via
    /// `findCategory(named:)` before getting here, and a duplicate name is a legitimate outcome
    /// once the user has been told and chosen it. The `WHERE NOT EXISTS` guard on the seed inserts
    /// in `database/007_category.sql` is there to make re-running the DDL idempotent -- it is not
    /// an operational pattern to copy into runtime writes.
    @discardableResult
    func createCategory(name: String) -> Int? {
        guard let db, !name.isEmpty else { return nil }
        var newCategoryID: Int?
        let sql = "INSERT INTO category (category_name, icon_id, colour_id) VALUES (?, 0, 0);"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category create prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_DONE {
                // Read inside the same queue hop as the step, so no other write on this connection
                // can move the last-insert rowid in between.
                if sqlite3_changes(db) > 0 {
                    newCategoryID = Int(sqlite3_last_insert_rowid(db))
                }
            } else {
                logger.error("category create exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
        return newCategoryID
    }

    /// Renames a category. Every table that references it does so by `category_id`, so the new
    /// name shows up wherever that history is displayed with nothing to backfill -- including for
    /// periods before the rename, which is what the confirmation on the Categories tab warns
    /// about. Same `category_id >= 1` guard as the other category writers: the `Unassigned`
    /// sentinel keeps its name. See `database/007_category.sql`.
    func updateCategoryName(categoryID: Int, name: String) {
        guard let db, !name.isEmpty else { return }
        let sql = "UPDATE category SET category_name = ? WHERE category_id = ? AND category_id >= 1;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category rename prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(categoryID))
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("category rename exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Sets `icon_id` on a category -- the Categories tab's own icon grid. Same
    /// `category_id >= 1` guard as the other category writers, so the `Unassigned` sentinel keeps
    /// the `None` icon. See `database/007_category.sql`.
    func updateCategoryIcon(categoryID: Int, iconID: Int) {
        guard let db else { return }
        let sql = "UPDATE category SET icon_id = ? WHERE category_id = ? AND category_id >= 1;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category icon update prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(iconID))
            sqlite3_bind_int64(stmt, 2, Int64(categoryID))
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("category icon update exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Sets `active` on a category -- the Categories tab's own Active checkbox. Same
    /// `category_id >= 1` guard as the other category writers: the `Unassigned` sentinel is
    /// always active and must never be retired. See `database/007_category.sql`.
    ///
    /// **Retiring also takes the category off every face holding it**, putting those faces back on
    /// the `Unassigned` sentinel. Retiring removes a category from every list that offers one, so a
    /// face left pointing at a retired row goes on showing it -- on the Faces tab, on the device's
    /// LED and in the menu bar -- as a category the user can no longer pick and cannot clear except
    /// by assigning something else over it.
    ///
    /// **A locked face refuses the retire outright**, rather than being cleared with the rest. The
    /// lock says this face keeps what it has, and clearing it would be the app overriding that on
    /// the user's behalf. Unlocking is a deliberate act on the Faces tab, so the order is theirs to
    /// choose: unlock the face, then retire. The Categories tab disables the Active box for exactly
    /// this case, so nothing reaches this refusal through the UI -- it is the backstop a stale view
    /// could otherwise walk past, the same one `updateFaceCategory` keeps for the same reason.
    ///
    /// The sweep before the clear is the load-bearing ordering `updateFaceCategory` documents: a
    /// `time_entry` records the category the face was mapped to when the segment happened, so
    /// anything still unconverted has to be converted while the old mapping is still the truth.
    /// It only runs when there is actually a face to clear, since otherwise no mapping changes.
    ///
    /// Reinstating does **not** put the category back on the face it came off. Nothing records
    /// which face that was, and re-assigning is one click on the Faces tab.
    ///
    /// Returns whether the row now holds the requested state, which either direction can refuse.
    /// Reinstating fails when `UN1_category`, which allows only one *active* category per name,
    /// would be broken by a retired row coming back under a name an active one has since taken;
    /// retiring fails on the locked face above. The caller has to know, because the Categories tab
    /// patches its loaded list rather than re-reading, and patching a write that was refused would
    /// leave the checkbox showing a state the row is not in.
    @discardableResult
    func updateCategoryActive(categoryID: Int, isActive: Bool) -> Bool {
        guard let db else { return false }
        let held = isActive ? [] : facesAssigned(to: categoryID)
        let lockedFaces = held.filter(\.isLocked).map(\.faceID)
        guard lockedFaces.isEmpty else {
            let faces = lockedFaces.map(String.init).joined(separator: ", ")
            let label = lockedFaces.count == 1 ? "face" : "faces"
            DeveloperMode.debugPrint(.faceClear, "Category \(categoryID) not retired: locked \(label) \(faces) still holds it")
            return false
        }
        let facesToClear = held.map(\.faceID)
        if !facesToClear.isEmpty {
            sweepTimeEntries(trigger: .faceCategoryChange)
        }
        var succeeded = false
        let sql = "UPDATE category SET active = ? WHERE category_id = ? AND category_id >= 1;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("category active update prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, isActive ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, Int64(categoryID))
            if sqlite3_step(stmt) == SQLITE_DONE {
                succeeded = true
            } else {
                logger.error("category active update exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
        // Only once the retire itself took: clearing faces for a category still marked active would
        // leave the user with a blank face and the category exactly where it was.
        if succeeded, !facesToClear.isEmpty {
            clearFaces(assignedTo: categoryID)
            let faces = facesToClear.map(String.init).joined(separator: ", ")
            let label = facesToClear.count == 1 ? "face" : "faces"
            DeveloperMode.debugPrint(.faceClear, "Category \(categoryID) retired: \(label) \(faces) back to Unassigned")
        }
        return succeeded
    }

    /// Which faces currently hold a category, and whether each is locked (`database/008_face.sql`).
    /// Read before a retire, which needs all three answers from it: a locked face refuses the retire
    /// outright, no face at all means the clear and its sweep are skipped, and the ids name the
    /// faces in the debug line either way.
    ///
    /// The `category_id >= 1` guard matches the writers: id 0 is the `Unassigned` sentinel a cleared
    /// face lands on, which is never itself retired, so "which faces hold it" is not a question with
    /// anything to do here.
    private func facesAssigned(to categoryID: Int) -> [(faceID: UInt8, isLocked: Bool)] {
        guard let db, categoryID >= 1 else { return [] }
        var faces: [(faceID: UInt8, isLocked: Bool)] = []
        let sql = "SELECT face_id, locked FROM face WHERE category_id = ? ORDER BY face_id;"
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("face assignment load prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(categoryID))
            while sqlite3_step(stmt) == SQLITE_ROW {
                faces.append((
                    faceID: UInt8(truncatingIfNeeded: sqlite3_column_int64(stmt, 0)),
                    isLocked: sqlite3_column_int64(stmt, 1) != 0
                ))
            }
            sqlite3_finalize(stmt)
        }
        return faces
    }

    /// Puts every face holding `categoryID` back on the `Unassigned` sentinel. Only ever called from
    /// `updateCategoryActive`, which documents why this happens at all and why the sweep runs first.
    ///
    /// No `locked` clause is needed, because there is nothing for it to exclude: a locked face makes
    /// the caller refuse the retire before it gets here, so every face this can reach is unlocked.
    private func clearFaces(assignedTo categoryID: Int) {
        guard let db, categoryID >= 1 else { return }
        let sql = """
        UPDATE face SET category_id = \(TimeFlipConstants.unassignedCategoryID)
        WHERE category_id = ?;
        """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("face clear prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_int64(stmt, 1, Int64(categoryID))
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("face clear exec failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// How often `HistoryIngestor` should re-fetch device history on a repeating timer (the
    /// `fetch_history_interval_seconds` setting, seeded to `10`; see `database/011_setting.sql`).
    /// Falls back to the seeded default if the row is missing or malformed.
    /// The App tab edits this in whole minutes, so anything below a minute can only have come from
    /// the seed default or a hand-edited row. Sub-minute polling is a developer convenience -- it
    /// makes history arrive quickly while testing -- so it is honoured while developer mode is on
    /// and floored at one minute otherwise. Enforced here rather than by rewriting the row, so the
    /// stored value survives untouched and a developer's 10s keeps working.
    func loadFetchHistoryIntervalSeconds() -> TimeInterval {
        guard let seconds = loadSettingJSON(name: "fetch_history_interval_seconds")?["seconds"] as? Int else {
            return TimeInterval(TimeFlipConstants.defaultFetchHistoryIntervalSeconds)
        }
        guard !DeveloperMode.isEnabled else { return TimeInterval(seconds) }
        return TimeInterval(max(TimeFlipConstants.minFetchHistoryIntervalSeconds, seconds))
    }

    /// How short a segment has to be before it counts as a blip rather than tracked time (the
    /// `blip_time` setting, seeded to 5; see `database/011_setting.sql`). Falls back to the seeded
    /// default if the row is missing or malformed, and clamps, so a hand-edited value cannot make
    /// the app discard more than the App tab is willing to set.
    func loadBlipTimeSeconds() -> Int {
        guard let seconds = loadSettingJSON(name: "blip_time")?["seconds"] as? Int else {
            return TimeFlipConstants.defaultBlipTimeSeconds
        }
        return max(
            TimeFlipConstants.minBlipTimeSeconds,
            min(TimeFlipConstants.maxBlipTimeSeconds, seconds)
        )
    }

    /// Whether locking the device via the app should also pause it first if it isn't already
    /// paused (the `pause_on_lock` setting, seeded to `true`; see `database/011_setting.sql`).
    /// Falls back to the seeded default if the row is missing or malformed.
    func loadPauseOnLockEnabled() -> Bool {
        guard let enabled = loadSettingJSON(name: "pause_on_lock")?["enabled"] as? Bool else {
            return true
        }
        return enabled
    }

    /// Which physical database file this is -- `"production"` or `"test"` (the `db_type` setting;
    /// see `database/011_setting.sql`). Set once when a database file is first created and never
    /// changed afterward; see `Tests/CLAUDE.md` for the test-database-switching
    /// workflow this backs. Falls back to `"production"` if the row is missing or malformed.
    func loadDbType() -> String {
        loadSettingJSON(name: "db_type")?["type"] as? String ?? "production"
    }

    /// Local date-time formatter for the `connection` setting's timestamps, matching the
    /// `db-type`/`debug` convention of local time with no UTC offset (see
    /// `DeveloperMode.debugPrint`) and the seed's own
    /// `strftime('%Y-%m-%dT%H:%M:%S','now','localtime')` in `011_setting.sql`.
    private static let connectionTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Marks the connection up: sets `connection.connected` and stamps `last_connection` with the
    /// current local date-time. Called as part of every successful device login (a new pairing, and
    /// each app-start/reconnect login) -- see `ApplicationDelegate.startDeviceEvents` and
    /// `011_setting.sql`. Returns the string written, so the caller can log it.
    ///
    /// Says nothing about pairing: that was settled before the attempt and is `recordPaired`'s job.
    @discardableResult
    func recordConnection(now: Date = Date()) -> String {
        let stamp = Self.connectionTimestampFormatter.string(from: now)
        saveSettingJSON(name: "connection", merging: ["connected": true, "last_connection": stamp])
        return stamp
    }

    /// Marks the connection down: clears `connection.connected` and stamps `connection_lost` with
    /// the current local date-time, when the app detects a lost device connection (see
    /// `ApplicationDelegate.handleDeviceDisconnect`). `connection_lost` is cleared again by
    /// `recordQuitRequest()` so a deliberate quit isn't misread as a drop. The device stays paired
    /// throughout -- a drop is not an unpairing.
    @discardableResult
    func recordConnectionLost(now: Date = Date()) -> String {
        let stamp = Self.connectionTimestampFormatter.string(from: now)
        saveSettingJSON(name: "connection", merging: ["connected": false, "connection_lost": stamp])
        return stamp
    }

    /// Stamps `connection.quit_request` with the current local date-time, marks the connection
    /// down, and clears `connection_lost` -- the imminent disconnect is an intentional shutdown,
    /// not a drop. Called from `ApplicationDelegate.applicationWillTerminate`.
    func recordQuitRequest(now: Date = Date()) {
        let stamp = Self.connectionTimestampFormatter.string(from: now)
        saveSettingJSON(name: "connection", merging: [
            "connected": false,
            "quit_request": stamp,
            "connection_lost": ""
        ])
    }

    /// Records whether the app is paired to a device, into the `paired` setting. **Durable**: set
    /// `true` when a first pairing succeeds and `false` only when the user forgets the device
    /// (Forget Device, or the end of a confirmed factory reset). Connects and disconnects
    /// deliberately don't write here -- going out of range doesn't unpair anything, and this row
    /// is what the app reads at launch to decide it still has a device to reconnect to. For "is it
    /// reachable right now", see `recordConnection`/`recordConnectionLost`. See `011_setting.sql`.
    func recordPaired(_ paired: Bool) {
        saveSettingJSON(name: "paired", merging: ["paired": paired])
    }

    /// Restores the pairing at launch. Defaults to not paired, matching a database that has never
    /// seen a pairing.
    func loadPaired() -> Bool {
        loadSettingJSON(name: "paired")?["paired"] as? Bool ?? false
    }

    /// The CoreBluetooth peripheral identifier of the paired device, used to reconnect to the same
    /// device rather than rediscovering it. Durable alongside `paired` and changing only on pairing
    /// or forgetting.
    /// `nil` is written as JSON null rather than skipped, so forgetting a device actually clears
    /// the stored value instead of leaving the previous one in place.
    func recordDeviceUUID(_ uuid: String?) {
        saveSettingJSON(name: "device_uuid", merging: ["uuid": uuid.map { $0 as Any } ?? NSNull()])
    }

    /// Restores the paired device's peripheral identifier at launch. Absent in a database that has
    /// never seen a pairing.
    func loadDeviceUUID() -> String? {
        loadSettingJSON(name: "device_uuid")?["uuid"] as? String
    }

    /// The name the cube is carrying (its GAP Device Name, `0x2A00`), mirrored here from the
    /// peripheral on every connect.
    ///
    /// Stored separately from `device_uuid` because the two have different lifetimes: forgetting a
    /// device clears the uuid but **not** the name, since forgetting does not un-rename the cube
    /// and that string is what the filtered scan needs to find it again. Only a confirmed factory
    /// reset clears this, the cube having reverted to the vendor name.
    func recordDeviceName(_ name: String?) {
        saveSettingJSON(name: "device_name", merging: ["name": name.map { $0 as Any } ?? NSNull()])
    }

    /// Restores the remembered device name at launch. Absent until the first connection, since the
    /// name is read from the device rather than guessed.
    func loadDeviceName() -> String? {
        loadSettingJSON(name: "device_name")?["name"] as? String
    }

    /// Whether the menu bar duration display includes seconds (the `display_seconds` setting,
    /// seeded to `true`; see `database/011_setting.sql`). Falls back to the seeded default if the
    /// row is missing or malformed.
    func loadDisplaySecondsEnabled() -> Bool {
        guard let enabled = loadSettingJSON(name: "display_seconds")?["enabled"] as? Bool else {
            return true
        }
        return enabled
    }

    /// Battery percentage at or below which the device is considered low on battery (the
    /// `low_battery_level` setting, seeded to `10`; see `database/011_setting.sql`). Falls back to
    /// the seeded default if the row is missing or malformed.
    func loadLowBatteryLevelPercent() -> Int {
        guard let percent = loadSettingJSON(name: "low_battery_level")?["percent"] as? Int else {
            return TimeFlipConstants.defaultLowBatteryWarningPercent
        }
        return percent
    }

    /// Whether dev-only debug messages (`DeveloperMode.debugPrint`) are actually emitted to the
    /// terminal (the `debug` setting's `enabled` field, seeded to `true`; see
    /// `database/011_setting.sql`). Falls back to the seeded default if the row is missing or
    /// malformed. Lets a user turn terminal logging off (or back on) by editing this setting
    /// directly, without needing a rebuild -- see docs/TODO-devmode.md.
    func loadDebugEnabled() -> Bool {
        guard let enabled = loadSettingJSON(name: "debug")?["enabled"] as? Bool else {
            return true
        }
        return enabled
    }

    /// LED brightness percent (the `led_settings` setting's `brightness` field, seeded to `50`;
    /// see `database/011_setting.sql`). Falls back to the seeded default if the row is missing or
    /// malformed.
    func loadLEDBrightnessPercent() -> UInt8 {
        guard let percent = loadSettingJSON(name: "led_settings")?["brightness"] as? Int else {
            return 50
        }
        return UInt8(max(1, min(100, percent)))
    }

    /// LED blink interval in seconds (the `led_settings` setting's `blink_interval` field, seeded
    /// to `15`; see `database/011_setting.sql`). Falls back to the seeded default if the row is
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

    /// Auto-pause delay in minutes (the `auto_pause_minutes` setting's `minutes` field, seeded to
    /// `0`; see `database/011_setting.sql`) -- the device itself only supports whole-minute
    /// granularity for this (device cmd 0x05), so there's no finer unit to store. Falls back to
    /// the seeded default if the row is missing or malformed.
    func loadAutoPauseMinutes() -> UInt16 {
        guard let minutes = loadSettingJSON(name: "auto_pause_minutes")?["minutes"] as? Int else {
            return 0
        }
        return UInt16(max(0, min(240, minutes)))
    }

    /// Persists a new auto-pause delay, in minutes, to the `auto_pause_minutes` row.
    func saveAutoPauseMinutes(_ minutes: UInt16) {
        saveSettingJSON(name: "auto_pause_minutes", merging: ["minutes": Int(minutes)])
    }

    /// Double-tap accelerometer register values (the `double_tap_settings` setting's
    /// `clickThreshold`/`limit`/`latency`/`window` fields; see `database/011_setting.sql`). Falls
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
    /// field, seeded to `true`; see `database/011_setting.sql`). Falls back to the seeded default
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

    /// The cached identity of the connected Google account -- name/email from the OpenID Connect
    /// userinfo endpoint (the `google_account` setting, seeded empty; see
    /// `database/011_setting.sql`). Returns `nil` when nothing has been cached yet (both fields
    /// empty/absent), which is the signal to fetch it from Google once and cache it.
    func loadGoogleAccount() -> GoogleAccountInfo? {
        guard let json = loadSettingJSON(name: "google_account") else { return nil }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let email = (json["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard name != nil || email != nil else { return nil }
        return GoogleAccountInfo(name: name, email: email)
    }

    /// Caches the connected account's identity in the `google_account` setting so the userinfo
    /// endpoint isn't called again on subsequent launches.
    func saveGoogleAccount(_ account: GoogleAccountInfo) {
        saveSettingJSON(name: "google_account", merging: [
            "name": account.name ?? "",
            "email": account.email ?? ""
        ])
    }

    /// Clears the cached account identity (e.g. on sign-out) so a later sign-in re-fetches fresh.
    /// Only `name` and `email` are reset -- the configuration keys below share this row and are
    /// not part of the identity being dropped.
    func clearGoogleAccount() {
        saveSettingJSON(name: "google_account", merging: ["name": "", "email": ""])
    }

    /// The calendar events sync into. Stored alongside the account identity rather than in its own
    /// row, since it is meaningless without one.
    func recordGoogleCalendar(id: String?, name: String?) {
        saveSettingJSON(name: "google_account", merging: [
            "calendar_id": id.map { $0 as Any } ?? NSNull(),
            "calendar_name": name.map { $0 as Any } ?? NSNull()
        ])
    }

    /// The OAuth client id. Not a secret -- it appears in every OAuth URL -- which is why it is
    /// here rather than in the Keychain alongside the client secret.
    func recordGoogleClientID(_ clientID: String?) {
        saveSettingJSON(name: "google_account", merging: [
            "client_id": clientID.map { $0 as Any } ?? NSNull()
        ])
    }

    /// Restores the Google configuration at launch. All three default to absent.
    func loadGoogleConfiguration() -> (calendarID: String?, calendarName: String?, clientID: String?) {
        let json = loadSettingJSON(name: "google_account")
        return (
            calendarID: json?["calendar_id"] as? String,
            calendarName: json?["calendar_name"] as? String,
            clientID: json?["client_id"] as? String
        )
    }

    /// Local hour (0-23) and minute (0-59) at which each category's tracked-time-vs-`daily_limit`
    /// accounting rolls over to a new day (the `daily_reset_time` setting, seeded to 3:00 AM; see
    /// `database/011_setting.sql`). Falls back to the seeded default if the row is missing or
    /// malformed.
    func loadDailyResetTime() -> (hour: Int, minute: Int) {
        let json = loadSettingJSON(name: "daily_reset_time")
        let hour = json?["hour"] as? Int ?? 3
        let minute = json?["minute"] as? Int ?? 0
        return (hour: max(0, min(23, hour)), minute: max(0, min(59, minute)))
    }

    /// Persists a new daily reset time (local hour/minute) to the `daily_reset_time` row.
    func saveDailyResetTime(hour: Int, minute: Int) {
        saveSettingJSON(name: "daily_reset_time", merging: [
            "hour": max(0, min(23, hour)),
            "minute": max(0, min(59, minute))
        ])
    }

    /// Persists `blip_time`, in seconds.
    func saveBlipTimeSeconds(_ seconds: Int) {
        saveSettingJSON(name: "blip_time", merging: [
            "seconds": max(
                TimeFlipConstants.minBlipTimeSeconds,
                min(TimeFlipConstants.maxBlipTimeSeconds, seconds)
            )
        ])
    }

    /// Persists the periodic history-fetch interval (`fetch_history_interval_seconds`), in seconds.
    func saveFetchHistoryIntervalSeconds(_ seconds: Int) {
        saveSettingJSON(name: "fetch_history_interval_seconds", merging: [
            "seconds": max(
                TimeFlipConstants.minFetchHistoryIntervalSeconds,
                min(TimeFlipConstants.maxFetchHistoryIntervalSeconds, seconds)
            )
        ])
    }

    /// Persists the battery level at or below which the low-battery warning shows
    /// (`low_battery_level`). Clamped to the device's own reportable range.
    func saveLowBatteryLevelPercent(_ percent: Int) {
        let clamped = max(
            Int(TimeFlipConstants.minBatteryLevel),
            min(TimeFlipConstants.effectiveMaxLowBatteryWarningPercent, percent)
        )
        saveSettingJSON(name: "low_battery_level", merging: ["percent": clamped])
    }

    /// Persists the menu bar's seconds preference (`display_seconds`).
    func saveDisplaySecondsEnabled(_ enabled: Bool) {
        saveSettingJSON(name: "display_seconds", merging: ["enabled": enabled])
    }

    /// Persists whether locking the device should pause it first -- see `loadPauseOnLockEnabled`,
    /// which the lock and quit paths re-read on every action rather than caching.
    func savePauseOnLockEnabled(_ enabled: Bool) {
        saveSettingJSON(name: "pause_on_lock", merging: ["enabled": enabled])
    }

    /// Reads a `setting` row's current JSON value, merges `updates` into it, and writes the
    /// result back -- the row always already exists (seeded by `011_setting.sql`), so this is a
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
        // Upsert, not a bare UPDATE: create the row if it's absent so a write self-heals a setting
        // this build added to the seed but an existing database predates (e.g. `paired` on a DB
        // created before that seed row existed). `setting_name` has a unique index (UN1_setting);
        // on conflict we touch only setting_value, preserving any seeded setting_description.
        let sql = """
            INSERT INTO setting (setting_name, setting_value) VALUES (?, ?)
            ON CONFLICT(setting_name) DO UPDATE SET setting_value = excluded.setting_value;
            """
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("saveSettingJSON prepare failed name=\(name, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, json, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                logger.error("saveSettingJSON exec failed name=\(name, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Device notifications (point-in-time, non-timing device events)

    /// Local-time-without-offset formatter for the `<name>` timestamp columns (e.g.
    /// `2026-07-16T09:30:00`); the zone that local time was captured in is recorded separately via
    /// the `<name>_timezone_id` foreign key to `timezone` (see `database/CLAUDE.md`).
    private static let localTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// `debug_log.logged_at` only: the same local-time ISO 8601 shape as `localTimeFormatter`, to the
    /// millisecond (`2026-07-16T09:30:00.123`).
    ///
    /// `debug_log` is the diagnostic record a test session is reconstructed from, and whole seconds
    /// are too coarse to time anything the device does. Every BLE round trip this app makes is
    /// sub-second -- a login is ~260ms, a history fetch ~130ms with nothing new -- so at second
    /// resolution the only way to recover a duration is statistically, from how often a pair of rows
    /// happens to straddle a second boundary. That is what had to be done to size
    /// `MockTimeFlipDevice.Latency`, and it gives one aggregate figure per operation rather than a
    /// measurement of any individual one.
    ///
    /// Applied on every database, not just the test one: the timings worth having are frequently in
    /// *production* data (the latency figures above came from `real.sqlite`), and one format
    /// everywhere means a parsing mistake cannot hide in the environment nobody looks at.
    ///
    /// Safe to widen because nothing reads these strings back into `Date`s in Swift -- they are
    /// write-only diagnostics. On the tooling side, `session_setup.py` parses them with Python's
    /// `datetime.fromisoformat`, which accepts fractional seconds, and `MAX(logged_at)` still orders
    /// correctly even across a mix of old and new rows, since the fraction sits after the part that
    /// decides the comparison.
    ///
    /// Deliberately *not* used for `device_event.start_time` or `device_notification.start_time`:
    /// those sit beside `start_epoch`, an INTEGER of whole seconds which is the actual ordering and
    /// uniqueness key (`UN1_device_event`), and making the text finer-grained than the key next to it
    /// would invite the two to disagree.
    private static let debugLogTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()


    /// Records a point-in-time device notification (double tap, battery level, system state,
    /// device info, event log — see `TimeFlipEvent.deviceNotification`) so what the device sends
    /// and how often can be inspected later in `device_notification`.
    @discardableResult
    func recordDeviceNotification(eventType: String, payload: String?, occurredAt: Date = Date()) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT INTO device_notification (event_type_id, start_time, timezone_id, start_epoch, payload)
        VALUES ((SELECT event_type_id FROM event_type WHERE event_name = ?), ?, ?, ?, ?);
        """
        var success = false
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logger.error("device_notification prepare failed event_type=\(eventType, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, eventType, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, AppDataStore.localTimeFormatter.string(from: occurredAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, currentTimezoneID)
            sqlite3_bind_int64(stmt, 4, Int64(occurredAt.timeIntervalSince1970))
            if let payload {
                sqlite3_bind_text(stmt, 5, payload, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
                logger.debug("device_notification event_type=\(eventType, privacy: .public) payload=\(payload ?? "nil", privacy: .public)")
            } else {
                logger.error("device_notification insert failed event_type=\(eventType, privacy: .public): \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
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
        INSERT INTO debug_log (logged_at, timezone_id, tag, message)
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
            sqlite3_bind_text(stmt, 1, AppDataStore.debugLogTimeFormatter.string(from: loggedAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, currentTimezoneID)
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

    /// Every tracked time entry still running at or after `cutoff`, oldest first. Feeds
    /// `DailyCategoryTotals.seedFromHistory`.
    ///
    /// **Reads `time_entry`, not `device_event`**, and that is the point rather than a detail. The
    /// day's totals are measured per category, because that is what a `daily_limit` is set on, and
    /// `time_entry.category_id` is the only place the category is recorded. Deriving it instead by
    /// joining `device_event` to `face` would use the mapping as it stands *now*, so reassigning a
    /// face would retroactively move yesterday's time to whichever category it points at today --
    /// exactly what `updateFaceCategory` sweeps before remapping in order to prevent.
    ///
    /// Two things follow from the source, both wanted:
    /// - A segment shorter than `blip_time` never became an entry, so it does not count. That is what
    ///   the setting is for: turning the cube past a face is not time spent on it.
    /// - A paused segment is never converted either, so pauses do not count towards the day.
    ///
    /// The open segment has no entry yet, so it is absent here and the caller adds its elapsed time
    /// on top; counting it in both places would count it twice. That was true of the `finalised = 1`
    /// test this replaced, and before that of the legacy `logbook` table, which only ever held
    /// segments the device had closed out.
    ///
    /// `start_epoch` comes from the joined `device_event` row rather than from `time_entry.started_at`,
    /// which is local text with no offset in it. The join is one-to-one: `device_event_id` is
    /// `NOT NULL` and carries `UN1_time_entry`.
    func loadTimeEntries(overlappingSince cutoff: Date) -> [TimeEntryRecord] {
        guard let db else { return [] }
        var items: [TimeEntryRecord] = []
        let sql = """
        SELECT te.category_id, de.start_epoch, te.duration_seconds
        FROM time_entry te
        JOIN device_event de ON de.device_event_id = te.device_event_id
        WHERE (de.start_epoch + te.duration_seconds) > ?
        ORDER BY de.start_epoch ASC;
        """
        let cutoffSeconds = cutoff.timeIntervalSince1970
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoffSeconds)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    items.append(
                        TimeEntryRecord(
                            categoryID: Int(sqlite3_column_int64(stmt, 0)),
                            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                            duration: sqlite3_column_double(stmt, 2)
                        )
                    )
                }
            } else {
                logger.error("time_entry window load prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            sqlite3_finalize(stmt)
        }
        return items
    }

    // MARK: - Device history position

    /// The **most recent segment recorded**, which is where the history fetch resumes. `nil` for a
    /// database with no history at all.
    ///
    /// The newest row, not the highest number. Those are different questions and only the first one
    /// is useful: event numbers restart at 1 after a factory reset, so `MAX(event_number)` returns
    /// a stranded value from a dead counter generation. On the production database today it returns
    /// 38, from a generation the cube abandoned, while the newest segment is event 10.
    ///
    /// This replaced a window-function walk that ordered every row, found the last point where
    /// `event_number` dropped below its predecessor, and took the maximum at or after that boundary.
    /// It computed the right answer, but only as a way of making `MAX` safe, and it could not do
    /// what it looked like it did: straight after a reset there is no post-reset row for the counter
    /// to have dropped between, so it still returned the stranded value.
    ///
    /// **Includes the open row, deliberately**, which is what makes the fetch resume *at* the live
    /// segment rather than past it, so its duration comes back updated. The caller must not treat
    /// this as "already finalised": the closing write for that segment has yet to arrive.
    ///
    /// Ordered by `start_epoch` rather than by `device_event_id` alone. They agree today (checked:
    /// zero rows in production were inserted out of chronological order, because a batch is sorted
    /// by event number before it is written), but a gap recovered in a later batch would be inserted
    /// after newer rows, and insertion order would then name an old segment as the newest.
    func latestRecordedEvent() -> RecordedEvent? {
        guard let db else { return nil }
        let sql = """
        SELECT event_number, start_epoch FROM device_event
        ORDER BY start_epoch DESC, device_event_id DESC
        LIMIT 1;
        """
        var result: RecordedEvent?
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW,
               sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                let ev = sqlite3_column_int64(stmt, 0)
                if ev > 0 {
                    result = RecordedEvent(
                        eventNumber: UInt32(clamping: ev),
                        startEpoch: sqlite3_column_int64(stmt, 1)
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    // MARK: - Helpers

    /// Runs every `.sql` file bundled under the `Database` resource directory, in filename order
    /// (hence the numeric prefixes on each file, e.g. `001_device_event.sql`). Adding, removing,
    /// or editing a `.sql` file in `database/` at the repo root is all that's needed to change the
    /// schema — this method never needs to change.
    private func runDatabaseDDL() {
        guard let db else { return }
        AppDataStore.runDatabaseDDL(on: db, logger: logger)
    }

    /// Runs every `.sql` file bundled under the `Database` resource directory, in filename order,
    /// against an arbitrary open handle -- factored out from the instance's own `runDatabaseDDL()`
    /// so the same seeding can run against any open connection.
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
            guard let rawSQL = try? String(contentsOf: file, encoding: .utf8) else {
                logger?.error("Could not read DDL file \(file.lastPathComponent, privacy: .public)")
                continue
            }
            let sql = skipSatisfiedColumnAdditions(rawSQL, db: db)
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                logger?.error("DDL file \(file.lastPathComponent, privacy: .public) failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
        }
    }

    /// Matches a single-line `ALTER TABLE <table> ADD COLUMN <column> ...;` statement -- the
    /// pattern a DDL file uses to add a column to a table that predates it (see
    /// `database/CLAUDE.md` § "Adding a column to an existing table"). Deliberately narrow: these
    /// additive statements are always written on one line ending in `;`, so a regex over the raw
    /// file text is enough without a full SQL tokenizer.
    private static let addColumnPattern = try! NSRegularExpression(
        pattern: #"ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(\w+)\b[^;]*;"#,
        options: [.caseInsensitive]
    )

    /// Comments out any `ALTER TABLE ... ADD COLUMN ...` statement in `sql` whose column already
    /// exists on that table -- so a DDL file can unconditionally declare the ALTER for databases
    /// that predate the column, while a database created fresh (which already got the column via
    /// that same table's own `CREATE TABLE IF NOT EXISTS`) doesn't hit sqlite's "duplicate column
    /// name" error. That error would otherwise abort every remaining statement in the same
    /// `sqlite3_exec` call, since sqlite3_exec stops at the first statement that fails.
    private static func skipSatisfiedColumnAdditions(_ sql: String, db: OpaquePointer) -> String {
        let nsSQL = sql as NSString
        var result = sql
        let matches = addColumnPattern.matches(in: sql, range: NSRange(location: 0, length: nsSQL.length))
        for match in matches.reversed() {
            let table = nsSQL.substring(with: match.range(at: 1))
            let column = nsSQL.substring(with: match.range(at: 2))
            guard columnExists(db: db, table: table, column: column),
                  let range = Range(match.range(at: 0), in: result)
            else { continue }
            result.replaceSubrange(range, with: "-- (skipped: \(table).\(column) already exists)")
        }
        return result
    }

    private static func columnExists(db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, column, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
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
    /// `scripts/switch-database.sh test`/`scripts/switch-database.sh prod` can repoint it at
    /// `test.sqlite` for a testing session without touching real data (see
    /// `Tests/CLAUDE.md`). A no-op if it's already a symlink, whatever it currently
    /// points at -- this only ever runs the one-time migration for a plain file (an install from
    /// before this symlink scheme existed, or a fresh install with no database yet). Only
    /// `production.sqlite` is ever brought into being through this scheme (by `sqlite3_open` on the
    /// symlink target at the app's next launch); `test.sqlite` is **not** created at startup -- it
    /// is created fresh only when a testing session is started (`scripts/switch-database.sh test`,
    /// which deletes any existing one first). Internal (not private) so `AppDataStoreTests` can
    /// exercise it directly against a temp directory, independent of the `DeveloperMode.isEnabled`
    /// gate at its one production call site (`init`).
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
                // Relative destination (not productionURL's full path) -- both files live in the
                // same directory by construction, and a relative link keeps working if this whole
                // directory is ever moved or restored somewhere else.
                try? fileManager.createSymbolicLink(
                    atPath: url.path,
                    withDestinationPath: productionURL.lastPathComponent
                )
            }
        }
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

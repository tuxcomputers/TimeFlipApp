import Foundation

/// The `time_entry` table's one writer: hand it a finished segment and it decides whether that segment counts
/// as tracked time, then records it if it does.
///
/// **It is handed an id, not the details.** `DeviceEventRecorder` calls this the moment it finalises a row, and
/// this reads the row back for itself: the table is what is true about that segment, and details passed as
/// arguments are a second copy that can differ from it (see the first rule in `CLAUDE.md`). What is *sent* is
/// the trigger, which is the one thing the table cannot tell anyone -- that a row just stopped being open.
///
/// The first thing it reads is `blip_time`, before anything about the particular segment. That threshold is the
/// module's standing rule rather than a property of the record, and reading it first means a decision is never
/// taken against a value read at some other moment.
@MainActor
final class TimeEntryRecorder {
    /// What considering a segment came to.
    enum Outcome: Equatable {
        /// It counted, and this is the row.
        case created(timeEntryID: Int, categoryID: Int)
        /// It did not count. Nothing was written to `time_entry`.
        case ignored(TimeEntryRules.Reason)
        /// It already had an entry, so nothing was written. `UN1_time_entry` makes this impossible to get
        /// wrong: the same segment cannot be counted twice however many times it is offered.
        case alreadyRecorded(timeEntryID: Int)
        /// No such `device_event` row, which means somebody is holding an id that no longer exists.
        case noSuchSegment
        /// It should have counted and the write did not take.
        case notWritten
    }

    private let connection: DatabaseConnection
    private let settings: SettingStore
    private let faces: FaceStore
    private let debugLog: DebugLog?

    init(connection: DatabaseConnection, settings: SettingStore, faces: FaceStore, debugLog: DebugLog?) {
        self.connection = connection
        self.settings = settings
        self.faces = faces
        self.debugLog = debugLog
    }

    /// Decides what a finished segment means for tracked time, and writes the entry if it earns one.
    ///
    /// Safe to call more than once for the same segment: the second call finds the entry and reports
    /// `alreadyRecorded` rather than counting it again.
    @discardableResult
    func consider(deviceEventID: Int) -> Outcome {
        // The threshold first, as its own read. See the type's note.
        let blip = TimeEntryRules.blipSeconds(from: settings.integer("blip_time", field: "seconds"))

        guard let segment = segment(deviceEventID) else {
            debugLog?.record(.entry, "time_entry: no device_event \(deviceEventID) to consider")
            return .noSuchSegment
        }
        if let existing = entryID(forSegment: deviceEventID) {
            return .alreadyRecorded(timeEntryID: existing)
        }

        switch TimeEntryRules.decision(
            durationSeconds: segment.durationSeconds,
            isPaused: segment.isPaused,
            isFinalised: segment.isFinalised,
            blipSeconds: blip
        ) {
        case let .ignore(reason):
            return ignore(segment, because: reason)
        case .create:
            return create(from: segment)
        }
    }

    // MARK: - the two answers

    private func ignore(_ segment: Segment, because reason: TimeEntryRules.Reason) -> Outcome {
        switch reason {
        case .stillRunning:
            // Not marked processed: the segment has not finished, so the question is not answered yet and has
            // to be asked again when it closes.
            debugLog?.record(.entry, "time_entry: device_event \(segment.id) is still open, so nothing yet")
        case .paused, .blip:
            // Marked processed, because for these two the answer is final: no entry, ever. That is what keeps
            // the unprocessed set draining rather than growing a tail of rows every later pass re-examines.
            // The previous app left paused rows at `processed = 0` for life and said so; the flag means "the
            // entry question has been answered", and for a pause it has been.
            markProcessed(segment.id)
            debugLog?.record(.entry, "time_entry: device_event \(segment.id) ignored, \(describe(reason))")
        }
        return .ignored(reason)
    }

    private func create(from segment: Segment) -> Outcome {
        // The face's category **now**, which is why the click writes the face after closing the segment that
        // just ended (see `SettingsWindowController.startTiming`). An unassigned face gives 0, the seeded
        // *Unassigned* row: an entry against it is visible and can be corrected, where a dropped entry is time
        // gone, so this counts it rather than refusing.
        let categoryID = faces.categoryID(forFace: segment.face) ?? 0
        var entryID: Int?

        let committed = connection.transaction {
            // `ended_at` is the start plus the duration, back through the local calendar: a reporter gives a
            // start and a length, never an end. Both zones are the segment's own for the same reason -- nothing
            // here could know the zone changed part way through it.
            //
            // Whole seconds, matching `device_event.duration_seconds`, which is what the device reports in.
            let endEpoch = segment.startEpoch + Int(segment.durationSeconds)
            guard connection.execute(
                """
                INSERT INTO time_entry (
                    category_id, device_event_id, started_at, start_timezone_id,
                    ended_at, end_timezone_id, duration_seconds
                ) VALUES (
                    \(categoryID),
                    \(segment.id),
                    strftime('%Y-%m-%dT%H:%M:%S', \(segment.startEpoch), 'unixepoch', 'localtime'),
                    \(segment.timezoneID),
                    strftime('%Y-%m-%dT%H:%M:%S', \(endEpoch), 'unixepoch', 'localtime'),
                    \(segment.timezoneID),
                    \(segment.durationSeconds)
                );
                """
            ) else {
                return false
            }
            entryID = connection.lastInsertedRowID
            // Both or neither. A `processed` flag set with no entry behind it is the one state nothing later
            // can tell from work already done, so it is the state this must never leave behind.
            return entryID != nil && connection.execute(
                "UPDATE device_event SET processed = 1 WHERE device_event_id = \(segment.id);"
            )
        }

        // `committed` as well as the id: the id is set inside the transaction, so on a rollback it holds the
        // row number of an insert that no longer exists, and reporting `created` from it would name a row
        // nothing can read.
        guard committed, let entryID else {
            debugLog?.record(.entry, "time_entry: device_event \(segment.id) earned an entry and it was refused")
            return .notWritten
        }
        debugLog?.record(
            .entry,
            "time_entry created id=\(entryID) from device_event \(segment.id) "
                + "face=\(segment.face) category=\(categoryID) dur=\(Int(segment.durationSeconds))s"
        )
        return .created(timeEntryID: entryID, categoryID: categoryID)
    }

    // MARK: - what the table says

    /// One `device_event` row, in the terms this decision needs.
    private struct Segment {
        let id: Int
        let face: Int
        let startEpoch: Int
        let durationSeconds: Double
        let isPaused: Bool
        let isFinalised: Bool
        let timezoneID: Int
    }

    private func segment(_ deviceEventID: Int) -> Segment? {
        var found: Segment?
        connection.forEachRow(
            "SELECT device_face, start_epoch, duration_seconds, paused, finalised, timezone_id "
                + "FROM device_event WHERE device_event_id = \(deviceEventID);"
        ) { row in
            found = Segment(
                id: deviceEventID,
                face: Int(row.int(0)),
                startEpoch: Int(row.int(1)),
                durationSeconds: row.double(2),
                isPaused: row.bool(3),
                isFinalised: row.bool(4),
                timezoneID: Int(row.int(5))
            )
        }
        return found
    }

    private func entryID(forSegment deviceEventID: Int) -> Int? {
        var found: Int?
        connection.forEachRow(
            "SELECT time_entry_id FROM time_entry WHERE device_event_id = \(deviceEventID);"
        ) { row in
            found = Int(row.int(0))
        }
        return found
    }

    private func markProcessed(_ deviceEventID: Int) {
        connection.execute("UPDATE device_event SET processed = 1 WHERE device_event_id = \(deviceEventID);")
    }

    private func describe(_ reason: TimeEntryRules.Reason) -> String {
        switch reason {
        case .stillRunning: return "still running"
        case .paused: return "a paused stretch"
        case let .blip(shorterThan): return "under blip_time=\(shorterThan)s"
        }
    }
}

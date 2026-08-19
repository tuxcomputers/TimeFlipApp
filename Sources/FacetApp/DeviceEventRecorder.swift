import Foundation

/// The `device_event` table's one writer: hand it a segment and it decides what that means for what is
/// already recorded, then records it.
///
/// **Everything about a segment's own bookkeeping is decided in here**, and nothing about it is decided by
/// the caller. A caller says "this face ran for this long from this moment"; whether that is a new row or a
/// row brought up to date, and whether the row that was open stops being open, is this module's to answer.
/// That is the point of it existing: the previous app spread the same questions across the history ingestor,
/// the store and manual mode's own teardown, and they disagreed -- a segment could be left claiming to be
/// live forever, and time in a row like that is never counted.
///
/// **What it deliberately does not decide** is whether any of this becomes tracked time. A `device_event` is
/// what a device says happened; a `time_entry` is what the app counts, and the two are not the same question
/// (a flip too short to mean anything is the obvious case). Closing a row is what creates that question, so
/// this is where the answer will be *asked for* -- see the note at the end of `record` -- but the answering
/// belongs to the time entry module. Not built yet, and nothing here anticipates its shape beyond leaving
/// the one call site.
///
/// `processed` is untouched here for the same reason: it is the time entry side's marker, not this side's.
@MainActor
final class DeviceEventRecorder {
    /// What recording a segment did, for a caller that wants to say so or to react to it.
    struct Outcome: Equatable {
        /// The row now holding this segment.
        let deviceEventID: Int

        /// Whether that row is the live one (`finalised = 0`), i.e. the segment still in progress.
        let isOpen: Bool

        /// `true` if this segment had never been seen, `false` if a row for it was brought up to date.
        let wasInserted: Bool

        /// How many rows stopped being open to make room for this one. Normally one, and zero when nothing
        /// was running -- the first segment after a launch, or one arriving out of order.
        let closedRows: Int
    }

    private let connection: DatabaseConnection
    private let timezones: TimezoneStore

    /// Told about every row this finalises, and answers the question closing one raises: does that stretch
    /// count? `nil` leaves segments recorded and nothing counted, which is what a test about this table alone
    /// wants.
    private let timeEntries: TimeEntryRecorder?

    /// `nil` in a build without the dev flag, which is all there is to switching this off.
    private let debugLog: DebugLog?

    init(
        connection: DatabaseConnection,
        timezones: TimezoneStore,
        timeEntries: TimeEntryRecorder?,
        debugLog: DebugLog?
    ) {
        self.connection = connection
        self.timezones = timezones
        self.timeEntries = timeEntries
        self.debugLog = debugLog
    }

    /// Records a segment, and reports what that came to. `nil` if nothing was written.
    ///
    /// Reports rather than logs-and-swallows, matching `DatabaseConnection.execute`: what a refused write
    /// means is the caller's to decide, and a caller handed nothing but `nil` and a line in a log somewhere
    /// could not decide anything.
    @discardableResult
    func record(_ segment: DeviceEventSegment, logging: Bool = true) -> Outcome? {
        // Both reads happen here, immediately before the decision that uses them, and neither is kept: the
        // table is what is true about what has been recorded, and this module holds no opinion of its own
        // between calls. See the first rule in `CLAUDE.md`, and `DeviceEventMark` for what the previous app
        // held instead.
        let existingRowID = rowID(for: segment)
        let mark = newestOnRecord()
        let decision = DeviceEventRules.decision(for: segment, existingRowID: existingRowID, mark: mark)

        // Collected as they are found and handed over below, once the writes have landed. Every arm can finish
        // a segment: an update whose row is no longer the newest, the close-out a newer segment triggers, and a
        // segment that arrives already closed.
        var finished: [Int] = []
        let outcome: Outcome?
        switch decision {
        case let .update(rowID, finalised):
            outcome = update(rowID: rowID, to: segment, finalised: finalised)
            if finalised, outcome != nil {
                finished.append(rowID)
            }
        case .insertAsOpen:
            let inserted = insert(segment, open: true)
            outcome = inserted
            if inserted != nil {
                finished.append(contentsOf: lastClosedRowIDs)
            }
        case .insertClosed:
            outcome = insert(segment, open: false)
            if let outcome {
                finished.append(outcome.deviceEventID)
            }
        }

        guard let outcome else {
            // A refusal is always worth a row, whatever the caller asked for: `logging` exists to keep a
            // routine tick quiet, not to hide the tick that failed.
            debugLog?.record(.event, "device_event refused: \(describe(segment))")
            return nil
        }
        if logging {
            debugLog?.record(
                .event,
                "device_event \(outcome.wasInserted ? "inserted" : "updated") id=\(outcome.deviceEventID) "
                    + "\(describe(segment)) open=\(outcome.isOpen) closed=\(outcome.closedRows)"
            )
        }

        // A finished segment is the only thing that can become tracked time, so closing one is what raises the
        // question -- and this is where it gets asked, after the writes rather than inside them: an entry is
        // derived from a segment, and deriving it must not be able to roll the segment back.
        handOver(finished)

        return outcome
    }

    // MARK: - segments the app is timing itself

    /// Starts a segment the app itself is reporting, and reports what that did to the row that was open.
    ///
    /// For manual mode, where the app is the thing generating the reading rather than a cube. It allocates the
    /// event number, which is the identity of a row in this table and so nobody else's business to choose, and
    /// the duration starts at zero because a segment that has only just begun has run for nothing.
    ///
    /// Closing the segment this one takes over from is `closeOpenSegment(at:)`, called **before** this and
    /// separately, because what happens between the two is not this module's to decide: the manual face is
    /// remapped in there, and doing it the other way round would file the segment that just ended under the
    /// category that replaced it.
    @discardableResult
    func startSegment(face: Int, at moment: Date) -> Outcome? {
        let startEpoch = Int(moment.timeIntervalSince1970)
        return record(
            DeviceEventSegment(
                eventNumber: nextEventNumber(inSecond: startEpoch),
                face: face,
                startedAt: moment,
                durationSeconds: 0,
                isPaused: false
            )
        )
    }

    /// Ends whatever segment is still open, as of `moment`, and reports the row it closed. `nil` when nothing
    /// was open, which is the ordinary state of a first click rather than a failure.
    ///
    /// **The duration is worked out here**, from the row's own `start_epoch`, because in manual mode the app is
    /// the reporter: nothing else can say how long that stretch ran. A cube's segments are never closed this
    /// way -- it reports its own durations in its history, and a wall-clock guess would overwrite what the
    /// device actually measured.
    ///
    /// Reads the open row rather than being told which one it is. The table is what is true about what is
    /// running, so a session interrupted by a crash or a quit leaves its row here and the next click still
    /// finds it.
    @discardableResult
    func closeOpenSegment(at moment: Date) -> Outcome? {
        guard let open = openSegment() else { return nil }
        // The difference between two whole-second stamps, which is how the device arrives at its own durations
        // and so what this table holds. Not a rounding of the interval: the row's `start_epoch` is already
        // truncated to a second, and the segment that replaces this one starts from the same truncation, so
        // taking the difference is what makes one segment end exactly where the next begins. Rounding the
        // interval up instead would leave a duration reaching a second past the next segment's start, which is
        // two segments claiming the same second.
        //
        // Never negative: `CHECK (duration_seconds >= 0)` would refuse it and the row would stay open for good.
        // Only a clock that moved backwards gets here, and zero is the honest answer then.
        let duration = Self.wholeSecondsRun(from: open.startEpoch, to: moment)
        let ran = connection.execute(
            """
            UPDATE device_event SET duration_seconds = \(duration), finalised = 1
            WHERE device_event_id = \(open.deviceEventID);
            """
        )
        guard ran, connection.changes > 0 else {
            debugLog?.record(.event, "device_event failed to close id=\(open.deviceEventID)")
            return nil
        }
        debugLog?.record(.event, "device_event closed id=\(open.deviceEventID) after \(Int(duration))s")
        // The segment has finished, so the entry question is now answerable. Pausing is the path that brought
        // this here, and the row it just closed is the stretch that either counts or was too short to.
        handOver([open.deviceEventID])
        return Outcome(deviceEventID: open.deviceEventID, isOpen: false, wasInserted: false, closedRows: 1)
    }

    /// Brings the open segment up to date, as of `moment`, without closing it. `nil` when nothing is open.
    ///
    /// **This is what the history timer's timeout ends in.** In manual mode nothing is going to tell the app
    /// what it is doing, so the timeout is the app reporting its own segment: the same segment, running longer.
    /// The identity is read back off the row rather than remembered between ticks, and then `record` decides,
    /// on its own terms, that this is the same event -- which is why the duration lands in the row that is
    /// already there instead of a new one every interval. It is the same path a cube's re-sent live frame takes.
    ///
    /// Quiet by default. At one tick every ten seconds a row apiece would bury everything else in `debug_log`,
    /// and a tick that did what the last one did says nothing; a refused write still reports itself.
    @discardableResult
    func refreshOpenSegment(at moment: Date) -> Outcome? {
        guard let open = openSegment() else { return nil }
        return record(
            DeviceEventSegment(
                eventNumber: open.eventNumber,
                face: open.face,
                // Rebuilt from the row's own whole second, so the `start_time` written back is the string
                // already there rather than a fresh formatting of a slightly different instant.
                startedAt: Date(timeIntervalSince1970: Double(open.startEpoch)),
                durationSeconds: Self.wholeSecondsRun(from: open.startEpoch, to: moment),
                isPaused: open.isPaused
            ),
            logging: false
        )
    }

    /// How long a segment starting on a whole second has run by `moment`, in whole seconds.
    ///
    /// The difference of two whole-second stamps rather than a rounding of the interval between them: the next
    /// segment's `start_epoch` truncates the same moment, so this is what makes one segment end exactly where
    /// the next begins instead of overlapping it. Clamped at zero, which only a clock that moved backwards
    /// reaches -- and `CHECK (duration_seconds >= 0)` would refuse the write, leaving the row open for good.
    private static func wholeSecondsRun(from startEpoch: Int, to moment: Date) -> Double {
        Double(max(0, Int(moment.timeIntervalSince1970) - startEpoch))
    }

    /// Finalises segments left open on the app's own faces, **keeping the duration each already has**, and
    /// reports which rows they were.
    ///
    /// For startup. A launch that ended without its quit sequence -- a crash, a force quit, a power cut -- leaves
    /// its segment open, and the next launch would otherwise close it with `closeOpenSegment`, measuring from its
    /// start to now: every hour the app was not running, recorded as time spent, and now an entry rather than
    /// just a duration. One session came back as 39 minutes having run for 14 seconds.
    ///
    /// So the duration is not recomputed. The last value written is the last moment anything knows the segment
    /// was running -- the history timer's final tick before the launch ended -- and a figure that is short by up
    /// to one interval is the honest answer where "now" is a guess that can be wrong by days.
    ///
    /// **Only faces above `ManualFace.highestDeviceFace`.** A cube's open segment is not stranded, because the
    /// cube keeps timing whether this app is running or not: a face left up overnight is still being timed at
    /// breakfast, and the duration the device reports for it will include every hour the app was closed. Nothing
    /// here has any business finalising that, and the history the next connection reads is what closes it -- with
    /// a figure the device measured rather than one this app guessed.
    ///
    /// Which is the whole difference between the two kinds of face: the app's own segments stop existing when the
    /// app does, and a cube's do not.
    @discardableResult
    func closeSegmentsStrandedOnAppFaces() -> [Int] {
        let stranded = openRowIDs(onFacesAbove: ManualFace.highestDeviceFace)
        guard !stranded.isEmpty else { return [] }
        guard connection.execute(
            "UPDATE device_event SET finalised = 1 "
                + "WHERE finalised = 0 AND device_face > \(ManualFace.highestDeviceFace);"
        ) else {
            debugLog?.record(.event, "device_event failed to close stranded rows \(stranded)")
            return []
        }
        debugLog?.record(
            .event,
            "device_event closed \(stranded.count) stranded by an earlier launch: \(stranded), durations left as they were"
        )
        // Same hand-over as any other close: a finished segment is a finished segment, and whether it counts is
        // the time entry side's answer -- including deciding it is too short to.
        handOver(stranded)
        return stranded
    }

    /// The number the app takes for a segment it is reporting itself: **the unix epoch second it started**,
    /// which is what the previous app used (`MockTimeFlipDevice` seeded its counter from
    /// `UInt32(now.timeIntervalSince1970)`), and the magnitude keeps these plainly distinguishable from a
    /// cube's own counter, which starts near zero and is reset by a battery pull.
    ///
    /// Derived from the table rather than counted in memory, so nothing has to be reseeded at launch and two
    /// launches cannot hand out the same number. A second segment inside one second takes the next number up,
    /// which is what stops the pair `(event_number, start_epoch)` -- the identity of a row here -- being the
    /// same for both, which would have made the second one silently overwrite the first.
    ///
    /// Fits `UInt32`, the width on the wire, until 2106.
    private func nextEventNumber(inSecond startEpoch: Int) -> Int {
        var highest = 0
        connection.forEachRow(
            "SELECT IFNULL(MAX(event_number), 0) FROM device_event WHERE start_epoch = \(startEpoch);"
        ) { row in
            highest = Int(row.int(0))
        }
        return max(startEpoch, highest + 1)
    }

    // MARK: - what is already on record

    /// The segment still open: what is happening right now, as far as the table is concerned.
    struct OpenSegment: Equatable {
        let deviceEventID: Int
        let eventNumber: Int
        let face: Int
        let startEpoch: Int
        let isPaused: Bool
    }

    /// The row that is still open, if there is one, with everything needed to report it again or to add its
    /// time to a total. More than one is a fault; the newest wins here and the close-out in `insert` is what
    /// sweeps up the rest.
    ///
    /// Internal because a running segment has no `time_entry` yet, so anything summing a category's time has to
    /// add this on top -- which is also what stops it being counted twice.
    func openSegment() -> OpenSegment? {
        var found: OpenSegment?
        connection.forEachRow(
            "SELECT device_event_id, event_number, device_face, start_epoch, paused FROM device_event "
                + "WHERE finalised = 0 ORDER BY start_epoch DESC, device_event_id DESC LIMIT 1;"
        ) { row in
            found = OpenSegment(
                deviceEventID: Int(row.int(0)),
                eventNumber: Int(row.int(1)),
                face: Int(row.int(2)),
                startEpoch: Int(row.int(3)),
                isPaused: row.bool(4)
            )
        }
        return found
    }

    /// The row holding this exact segment, or `nil` if it has never been seen.
    ///
    /// Matched on the pair, never on either column alone: `DeviceEventRules.decision` has the reasoning, and
    /// `UN1_device_event` is the same pair as a unique index.
    private func rowID(for segment: DeviceEventSegment) -> Int? {
        var found: Int?
        connection.forEachRow(
            "SELECT device_event_id FROM device_event "
                + "WHERE event_number = \(segment.eventNumber) AND start_epoch = \(segment.startEpoch);"
        ) { row in
            found = Int(row.int(0))
        }
        return found
    }

    /// Where the newest recorded segment sits.
    ///
    /// One statement for both halves, so they cannot come from two reads of a table something else is
    /// writing, and with the event number scoped to that epoch by the subquery rather than being a second
    /// `MAX` over the whole table -- which would pick up a higher number from an earlier second after a
    /// device reset. `IFNULL` puts the empty-table sentinel in the query, so Swift never sees a NULL that
    /// would arrive as a plausible-looking zero.
    /// The newest segment on record: the pair that identifies it, not the number alone.
    ///
    /// **The newest row, not the highest number**, which are different questions and only the first is useful. Event
    /// numbers restart at 1 after a factory reset, so `MAX(event_number)` returns a stranded value from a generation
    /// the cube has abandoned -- on the previous app's production database it returned 38 while the newest segment was
    /// event 10, and a fetch resuming from 38 asked for events the cube no longer had.
    ///
    /// **Internal because the table is the position.** `HistoryIngestor` reads it on every refresh rather than keeping
    /// a cursor: a saved high-water mark cannot follow the cube's counter back down through a reset, and a copy of it
    /// is one more thing to keep in step.
    func newestOnRecord() -> DeviceEventMark {
        let empty = DeviceEventMark.none
        var mark = empty
        connection.forEachRow(
            """
            SELECT IFNULL(MAX(start_epoch), \(empty.startEpoch)),
                   IFNULL((SELECT MAX(event_number) FROM device_event
                            WHERE start_epoch = (SELECT MAX(start_epoch) FROM device_event)), \(empty.eventNumber))
            FROM device_event;
            """
        ) { row in
            mark = DeviceEventMark(startEpoch: Int(row.int(0)), eventNumber: Int(row.int(1)))
        }
        return mark
    }

    // MARK: - writing

    /// Brings the row already holding this segment up to date.
    ///
    /// Every column the segment carries, not just the duration: a re-sent frame is the reporter's own account
    /// of that segment, so anything of ours that disagrees with it is ours being stale.
    private func update(rowID: Int, to segment: DeviceEventSegment, finalised: Bool) -> Outcome? {
        let ran = connection.execute(
            """
            UPDATE device_event SET
                event_type_id = (SELECT event_type_id FROM event_type WHERE event_name = ?),
                device_face = \(segment.face),
                start_time = ?,
                timezone_id = \(timezones.currentID()),
                duration_seconds = \(DeviceEventRules.wholeSeconds(segment.durationSeconds)),
                paused = \(segment.isPaused ? 1 : 0),
                finalised = \(finalised ? 1 : 0)
            WHERE device_event_id = \(rowID);
            """,
            bind: [DeviceEventRules.eventTypeName(isPaused: segment.isPaused), Self.startTime.string(from: segment.startedAt)]
        )
        // The row count as well as the step: an `UPDATE` naming a row that is not there completes perfectly
        // happily having changed nothing, and this is meant to report what is on record.
        guard ran, connection.changes > 0 else { return nil }
        return Outcome(deviceEventID: rowID, isOpen: !finalised, wasInserted: false, closedRows: 0)
    }

    /// Inserts a segment never seen before, closing the row that was open first when this one takes over as
    /// the live segment.
    ///
    /// Both statements or neither: interrupted between them, the table would hold a closed row where the live
    /// segment used to be and nothing live at all, which nothing later can tell from two finished segments.
    private func insert(_ segment: DeviceEventSegment, open: Bool) -> Outcome? {
        var closedRows = 0
        var insertedID: Int?
        lastClosedRowIDs = []

        connection.transaction {
            if open {
                // Every row that still claims to be open, not just the newest one. A row stranded by an
                // earlier fault is exactly what this is for, and asking the question rather than tracking
                // which row it should be is what stops a second stranding.
                //
                // Named before they are closed, because afterwards nothing distinguishes them from every other
                // finished row -- and they are the segments the time entry side has to be told about.
                lastClosedRowIDs = openRowIDs()
                guard connection.execute("UPDATE device_event SET finalised = 1 WHERE finalised != 1;") else {
                    return false
                }
                closedRows = connection.changes
            }
            guard connection.execute(
                """
                INSERT INTO device_event (
                    event_number, event_type_id, device_face, start_time, timezone_id,
                    start_epoch, duration_seconds, paused, finalised
                ) VALUES (
                    \(segment.eventNumber),
                    (SELECT event_type_id FROM event_type WHERE event_name = ?),
                    \(segment.face),
                    ?,
                    \(timezones.currentID()),
                    \(segment.startEpoch),
                    \(DeviceEventRules.wholeSeconds(segment.durationSeconds)),
                    \(segment.isPaused ? 1 : 0),
                    \(open ? 0 : 1)
                );
                """,
                bind: [
                    DeviceEventRules.eventTypeName(isPaused: segment.isPaused),
                    Self.startTime.string(from: segment.startedAt),
                ]
            ) else {
                return false
            }
            insertedID = connection.lastInsertedRowID
            return insertedID != nil
        }

        guard let insertedID else {
            // Rolled back, so nothing was closed after all and there is nothing to hand over.
            lastClosedRowIDs = []
            return nil
        }
        return Outcome(deviceEventID: insertedID, isOpen: open, wasInserted: true, closedRows: closedRows)
    }

    /// The face the most recent segment among `faces` was on, or `nil` if none of them has ever been used.
    ///
    /// How manual mode finds out where it is: the face of the last segment it recorded, from which
    /// `ManualFace.next(after:)` gives the face the next one goes on. Read rather than remembered, so a
    /// relaunch picks up the rotation where the previous one left it instead of starting over and overwriting
    /// a mapping a finished segment still depends on.
    ///
    /// By `device_event_id`, not by `start_epoch`: this asks which segment was recorded last, and two segments
    /// inside one second are exactly the case the epoch cannot separate.
    func latestFace(in faces: [Int]) -> Int? {
        guard !faces.isEmpty else { return nil }
        let list = faces.map(String.init).joined(separator: ",")
        var found: Int?
        connection.forEachRow(
            "SELECT device_face FROM device_event WHERE device_face IN (\(list)) "
                + "ORDER BY device_event_id DESC LIMIT 1;"
        ) { row in
            found = Int(row.int(0))
        }
        return found
    }

    /// The app's own face in use right now: the one the last manual segment was recorded on, or the first of them
    /// when nothing has been timed yet.
    ///
    /// One expression of it, here, because more than one thing asks: the window writes the next segment against it
    /// and `TimingReadout` resolves the category being timed through it. Two copies of this line would be two
    /// answers to which face is current, and they would only differ in the case that matters -- a fresh database,
    /// where the difference is `nil` versus `ManualFace.first`.
    ///
    /// Not the face the *next* segment goes on: that is `ManualFace.next(after: latestFace(in:))`, which must see
    /// the raw `nil` to start the rotation at its beginning rather than one past it.
    func currentManualFace() -> Int {
        latestFace(in: ManualFace.all) ?? ManualFace.first
    }

    /// The rows that still claim to be open, before a close-out takes that away from them.
    ///
    /// `onFacesAbove` narrows it to the app's own faces, which is what startup recovery wants and what an
    /// ordinary close-out must not do: that one closes everything open, stranded rows included.
    private func openRowIDs(onFacesAbove face: Int? = nil) -> [Int] {
        let onlyAppFaces = face.map { " AND device_face > \($0)" } ?? ""
        var ids: [Int] = []
        connection.forEachRow(
            "SELECT device_event_id FROM device_event WHERE finalised != 1\(onlyAppFaces);"
        ) { row in
            ids.append(Int(row.int(0)))
        }
        return ids
    }

    // MARK: - handing a finished segment on

    /// What the last close-out closed, for `record` to hand over once the writes have committed.
    ///
    /// A property rather than a return value because `insert` already reports an `Outcome`, and this is not part
    /// of what recording a segment *came to* -- it is bookkeeping between two steps of the same call. Cleared at
    /// the start of every insert, so a later hand-over cannot pick up an earlier one's rows.
    private var lastClosedRowIDs: [Int] = []

    /// Asks the time entry module about each segment that has just finished.
    ///
    /// One place, called from `record` and from `closeOpenSegment`, rather than at each of the arms that can
    /// finish a row. The previous app hooked the paths instead of the question and a path added later forgot to
    /// call it, which is how a finished segment could sit unconverted with nothing failing.
    private func handOver(_ deviceEventIDs: [Int]) {
        guard let timeEntries else { return }
        for id in deviceEventIDs {
            timeEntries.consider(deviceEventID: id)
        }
    }

    // MARK: - saying what happened

    private func describe(_ segment: DeviceEventSegment) -> String {
        "ev=\(segment.eventNumber) face=\(segment.face) "
            + "dur=\(Int(segment.durationSeconds))s paused=\(segment.isPaused)"
    }

    /// `2026-08-13T17:58:18`: local time, whole seconds, no offset -- the zone is the row's own foreign key.
    /// The same shape the previous app wrote, deliberately, because the rows it wrote are still in the
    /// database this one opens.
    private static let startTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

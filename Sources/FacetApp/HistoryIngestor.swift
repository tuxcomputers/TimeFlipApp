import Foundation

/// Brings the cube's own record of what it has been doing into `device_event`.
///
/// **The archive's sequence, massaged.** Its `HistoryIngestor` established the shape and every step of it survives
/// inspection, so the shape is kept whole:
///
///   1. Read where the app is up to, out of `device_event`. Every time; nothing is held between refreshes.
///   2. Ask the cube for one frame -- which event it is on. This is a **whole** frame, so if nothing has changed the
///      row can still be brought up to date from it and the stream is never asked for.
///   3. Otherwise stream from the stored position, or from the beginning if the cube cannot reach it.
///   4. Only once the stream reached the cube's own latest event: write everything but the last frame as finished,
///      **in ascending order**.
///   5. Write the last frame as the open segment.
///
/// Step 4's condition is where this parts company with the archive. There, the finished frames were written first and
/// only the live one was withheld; here nothing is written until the stream is known to have arrived whole, because
/// this app's recorder decides open-versus-closed from the newest row it can see -- so a partial batch would leave a
/// stretch that finished long ago drawn as what is happening now, which is what withholding the live frame is for.
///
/// What is not kept is its machinery. The archive carried an `async` device protocol, a debounce timer, a `pending`
/// flag and a trailing re-run; here a fetch is a callback and the one thing that needs guarding is that two do not run
/// at once. It also carried a daily-totals object to re-seed and a legacy table to write first, neither of which
/// exists in this app -- `DeviceEventRecorder` already hands finished segments to `TimeEntryRecorder` on its own.
///
/// **Nothing here holds an event number.** Not a cursor, not a high-water mark, not a copy of the last frame. The
/// table is the position and it is re-read on every refresh, which is what lets a factory reset be an ordinary answer
/// rather than a special case: once a post-reset row is in the table, the same read returns it.
@MainActor
final class HistoryIngestor {
    /// What a refresh came to, for whoever wants to redraw afterwards.
    enum Outcome: Equatable {
        /// No cube, or one that could not be asked.
        case nothingToAsk
        /// The cube is still on the segment already recorded. Its duration was refreshed; no stream was fetched.
        case unchanged
        /// Frames were written: how many finished, and whether the open segment was taken.
        case recorded(finished: Int, openSegment: Bool)
        /// The stream did not reach the cube's own latest event, or a write refused part way. Nothing was surfaced as
        /// current, and the next refresh resumes from the same place.
        case incomplete
    }

    private let events: DeviceEventRecorder
    private let readLastEvent: (@escaping (DeviceEventSegment?) -> Void) -> Void
    private let fetchHistory: (Int, @escaping ([DeviceEventSegment]) -> Void) -> Void
    private let debugLog: DebugLog?

    /// Whether a refresh is already running.
    ///
    /// **About the radio rather than about the cube.** Two fetches at once would be two conversations on one
    /// characteristic with nothing in the answers to say which is which -- the same reason `DeviceLogin` allows one
    /// at a time.
    private var isRefreshing = false

    /// A refresh asked for while one was already running, kept so it can be run the moment that one is over.
    ///
    /// **This used to be dropped, on the reasoning that the next trigger was a tick away.** That holds for the timer
    /// and not for the six other callers, every one of which is a state change that has just happened: the cube was
    /// turned, locked, unlocked, paused, reset, or a link came up. Those ask *because* the table is now out of date,
    /// and the tick they would wait for is up to ten seconds away -- during which the menu bar and the Faces tab go
    /// on drawing their play/pause glyph from `device_event`, which still says the opposite of what the app has just
    /// done and confirmed.
    ///
    /// Measured on a device run, 2026-08-22: the timer's fetch went out one row before a pause command, the pause was
    /// confirmed, and the refresh it asked for was dropped into a fetch that had already read the cube's answer. That
    /// run got away with it, the cube having applied the pause before answering; the ordering that does not is the
    /// same race a moment earlier.
    ///
    /// **Only the latest reason is kept**, so however many arrive during one fetch they collapse into a single
    /// re-run. They all want the same thing, which is the table brought up to date once this conversation is over.
    private var pendingReason: String?

    /// Told after every refresh that changed anything, so both surfaces can redraw.
    var onChanged: (() -> Void)?

    init(
        events: DeviceEventRecorder,
        readLastEvent: @escaping (@escaping (DeviceEventSegment?) -> Void) -> Void,
        fetchHistory: @escaping (Int, @escaping ([DeviceEventSegment]) -> Void) -> Void,
        debugLog: DebugLog?
    ) {
        self.events = events
        self.readLastEvent = readLastEvent
        self.fetchHistory = fetchHistory
        self.debugLog = debugLog
    }

    /// Asks the cube what has happened and records it.
    func refresh(because reason: String, then finished: ((Outcome) -> Void)? = nil) {
        guard !isRefreshing else {
            // Said rather than returned silently. A refresh that folded into one already running otherwise leaves no
            // trace at all, and the archive records a real run where exactly that made a startup fetch look as though
            // it had never happened.
            debugLog?.record(.history, "Already fetching history (\(reason)): asking again when this one is done")
            pendingReason = reason
            // **Still `.nothingToAsk` to this caller.** Its request has not been answered, and answering it later with
            // the re-run's outcome would report an answer to a question somebody else asked. No production caller
            // passes a handler; the tests that do are asserting exactly this.
            finished?(.nothingToAsk)
            return
        }
        isRefreshing = true

        // Step 1. The position, read from the table, every time.
        //
        // **The cube's own faces, not the newest row of any kind.** Manual segments live in this table too and carry
        // the epoch as their event number, so a manual stretch recorded after a cube's would answer this with a number
        // no cube can reach -- see `DeviceEventRecorder.newestFromTheCube`.
        let recorded = events.newestFromTheCube()
        debugLog?.record(
            .history,
            "Fetching history (\(reason)); on record: "
                + (recorded == .none ? "nothing" : "event \(recorded.eventNumber) at \(recorded.startEpoch)")
        )

        // Step 2. The cheap check: one frame, which is the whole segment rather than just a number.
        readLastEvent { [weak self] deviceLast in
            guard let self else { return }
            self.received(deviceLast, recorded: recorded, reason: reason, finished: finished)
        }
    }

    private func received(
        _ deviceLast: DeviceEventSegment?,
        recorded: DeviceEventMark,
        reason: String,
        finished: ((Outcome) -> Void)?
    ) {
        if let deviceLast {
            debugLog?.record(
                .history,
                "The cube is on event \(deviceLast.eventNumber), face \(deviceLast.face), "
                    + "\(Int(deviceLast.durationSeconds))s\(deviceLast.isPaused ? ", paused" : "")"
            )
        } else {
            debugLog?.record(.history, "The cube did not say which event it is on")
        }

        // **Nothing new.** The cube's current segment is the one already on record, so the stream is not asked for at
        // all -- but the row is still written, because its duration has grown since it was last looked at. That is the
        // whole value of the cheap check being a frame rather than a number.
        if let deviceLast, DeviceHistoryRules.isSameSegment(recorded, as: deviceLast) {
            events.record(deviceLast)
            done(.unchanged, reason: reason, changed: true, finished: finished)
            return
        }

        // Step 3. Where to resume: the stored position, or the beginning when the cube cannot reach it.
        let from = DeviceHistoryRules.resumeFrom(recorded, deviceLast: deviceLast)
        if from == 0, recorded != .none {
            debugLog?.record(.history, "Event \(recorded.eventNumber) is not one this cube can reach, so from the start")
        }
        fetchHistory(from) { [weak self] frames in
            guard let self else { return }
            self.fetched(frames, deviceLast: deviceLast, reason: reason, finished: finished)
        }
    }

    private func fetched(
        _ frames: [DeviceEventSegment],
        deviceLast: DeviceEventSegment?,
        reason: String,
        finished: ((Outcome) -> Void)?
    ) {
        let (closed, open) = DeviceHistoryRules.split(frames)
        guard let open else {
            done(.nothingToAsk, reason: reason, changed: false, finished: finished)
            return
        }

        // **A stream that did not reach the cube's own latest event is not written at all.**
        //
        // Not even the frames that did arrive, and that is a departure from the archive worth being explicit about.
        // There, the finished frames were written first and only the live one was withheld -- but this app's recorder
        // decides open-versus-closed from the newest row it can see, so the last frame written always becomes the open
        // one. Writing a partial batch would therefore leave a segment that finished some time ago drawn on both
        // surfaces as what is happening now, which is the exact thing withholding the live frame is for.
        //
        // Nothing is lost by waiting: the position is the table, so the next refresh asks from the same place and
        // brings the lot. What it costs is progress on a connection that keeps cutting streams short, and that is the
        // right trade -- a cube that cannot finish a stream is not one whose record should be half written.
        guard DeviceHistoryRules.isCurrent(open, deviceLast: deviceLast) else {
            debugLog?.record(
                .history,
                "The stream stopped at event \(open.eventNumber), short of the cube's own latest, so none of it is"
                    + " written -- the next fetch asks again from the same place"
            )
            done(.incomplete, reason: reason, changed: false, finished: finished)
            return
        }

        // Step 4. The finished ones, in ascending order, stopping at the first refusal.
        //
        // **Order is not tidiness here.** `DeviceEventRecorder` decides update-versus-insert from the newest row it
        // can see, so a later segment written first makes every earlier one look already superseded -- they take the
        // update branch against rows that were never inserted, and the whole backlog is silently dropped.
        //
        // **Stopping at the first refusal** is what stops a later event being recorded over the gap an earlier failure
        // left. The one that failed is retried on the next refresh rather than lost.
        var written = 0
        var allWritten = true
        for segment in closed {
            guard events.record(segment) != nil else {
                debugLog?.record(.history, "Event \(segment.eventNumber) would not record, so the rest waits")
                allWritten = false
                break
            }
            written += 1
        }

        // Step 5. The open one, once everything ahead of it has actually landed. A refusal part way leaves a gap, and
        // opening a segment past it would record over the hole rather than leaving it to be filled next time.
        guard allWritten else {
            done(.incomplete, reason: reason, changed: written > 0, finished: finished)
            return
        }
        events.record(open)
        done(.recorded(finished: written, openSegment: true), reason: reason, changed: true, finished: finished)
    }

    private func done(_ outcome: Outcome, reason: String, changed: Bool, finished: ((Outcome) -> Void)?) {
        isRefreshing = false
        debugLog?.record(.history, "History fetch done (\(reason)): \(outcome)")
        if changed { onChanged?() }
        finished?(outcome)

        // **Last, after this fetch has been reported.** The re-run is a fresh conversation with the cube and reads the
        // table again from the top, so it must not start until this one has told everybody what it found -- otherwise
        // `onChanged` fires for the second fetch before the first has been accounted for.
        guard let pending = pendingReason else { return }
        pendingReason = nil
        refresh(because: pending)
    }
}

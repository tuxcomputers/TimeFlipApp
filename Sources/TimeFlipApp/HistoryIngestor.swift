import Foundation
import OSLog

/// Fetches device history, writes completed segments to `device_event`, and updates UI with the live frame.
@MainActor
final class HistoryIngestor {
    private let device: TimeFlipSessionManaging
    private let dataStore: AppDataStore
    private let appState: AppState
    private let dailyTotals: DailyCategoryTotals
    private let onLatestEntry: ((TimeFlipHistoryEntry) -> Void)?
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "history-ingestor")

    private var isFetching = false
    private var pending = false
    private let debounceInterval: UInt64 = 250_000_000 // 250ms
    private var periodicFetchTimer: Timer?

    init(
        device: TimeFlipSessionManaging,
        dataStore: AppDataStore,
        appState: AppState,
        dailyTotals: DailyCategoryTotals,
        onLatestEntry: ((TimeFlipHistoryEntry) -> Void)? = nil
    ) {
        self.device = device
        self.dataStore = dataStore
        self.appState = appState
        self.dailyTotals = dailyTotals
        self.onLatestEntry = onLatestEntry
    }

    @MainActor
    deinit {
        periodicFetchTimer?.invalidate()
    }

    /// Starts a repeating timer (interval from the `fetch_history_interval_seconds` setting) that
    /// re-fetches device history so any entries the device hasn't pushed a live notification for
    /// yet still get picked up, on top of the fetches already triggered by live face/pause
    /// events. Safe to call again (e.g. if the setting changes) -- replaces any existing timer.
    func startPeriodicFetchTimer() {
        periodicFetchTimer?.invalidate()
        let interval = dataStore.loadFetchHistoryIntervalSeconds()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshHistory(trigger: "periodic")
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        periodicFetchTimer = timer
        logger.notice("periodic_fetch_timer_started interval_s=\(interval, privacy: .public)")
    }

    func stopPeriodicFetchTimer() {
        periodicFetchTimer?.invalidate()
        periodicFetchTimer = nil
    }

    func refreshHistory(trigger: String) async {
        // Coalesce bursts of triggers.
        if isFetching {
            pending = true
            // Say so, rather than returning silently. A coalesced trigger otherwise leaves no trace
            // at all: the fetch it folds into is logged under whichever trigger got here first, and
            // this one simply never appears. That is what made a real run look like the startup
            // fetch had never happened -- the periodic timer, which starts at launch and ticks
            // every 10s on the test database, won the race against a slow connect (6.4s to link,
            // then notifications, session setup and twelve face-colour writes), so the startup call
            // arrived mid-flight and vanished. The work still happened, under `trigger=periodic`.
            DeveloperMode.debugPrint(
                .histStart,
                "history fetch deferred: trigger=\(trigger) folded into the fetch already running; re-runs after it"
            )
            return
        }
        isFetching = true
        pending = false

        // Step 1: where the app is up to -- the newest segment on record, read out of
        // `device_event` on every refresh rather than mirrored in memory. The table is the only
        // record of the position; there is nothing else to keep in step with it, and nothing to
        // hydrate at the start of a session or clear at the end of one.
        let recorded = dataStore.latestRecordedEvent()
        logger.debug("history_ingest trigger=\(trigger, privacy: .public) recorded_ev=\(recorded?.eventNumber ?? 0)")
        DeveloperMode.debugPrint(
            .histStart,
            "history fetch triggered: trigger=\(trigger) recorded_ev=\(recorded.map { String($0.eventNumber) } ?? "nil")"
        )

        // Step 2: cheap single-frame read of the device's actual current record. Per the vendor
        // spec this comes back as a complete History block (face/start time/duration included,
        // not just the event number), so if it turns out nothing changed we can still refresh the
        // DB's duration for that entry below without paying for the full stream. A brand-new
        // pairing has nothing local to compare against, and a failed/timed-out read comes back
        // nil -- both fall through to the full fetch rather than getting stuck.
        let deviceEntry = await device.readLastEvent()
        DeveloperMode.debugPrint(
            .histCheck,
            // Both start epochs are printed, not just the numbers: the resume decision turns on them,
            // so a run that resumed somewhere surprising can be read back rather than guessed at.
            "history fetch: cheap check device_last_event=\(deviceEntry?.eventNumber.map(String.init) ?? "nil")@\(deviceEntry.map { String(Int64($0.startedAt.timeIntervalSince1970)) } ?? "nil") recorded_ev=\(recorded.map { "\($0.eventNumber)@\($0.startEpoch)" } ?? "nil")"
        )

        // Nothing new: the device's current segment is the one already on record. Compared on the
        // start time as well as the number, because a reset makes the number repeat -- a post-reset
        // event 10 is not the pre-reset event 10 this database holds, and treating it as one would
        // skip the stream that brings events 1-9 of the new generation in.
        if let recorded, let deviceEntry, recorded.isSameSegment(as: deviceEntry) {
            // Its duration will have grown since we last looked, so the row is still refreshed.
            dataStore.recordDeviceEvent(
                eventNumber: recorded.eventNumber,
                deviceFace: deviceEntry.faceID,
                startedAt: deviceEntry.startedAt,
                durationSeconds: deviceEntry.duration,
                isPaused: deviceEntry.isPaused
            )
            onLatestEntry?(deviceEntry)
            refreshDailyTotals()
            logger.debug("history_ingest ev=\(recorded.eventNumber, privacy: .public) unchanged; DB refreshed, stream skipped")
            DeveloperMode.debugPrint(.histResult, "history fetch: device event=\(recorded.eventNumber) unchanged; DB refreshed")
            DeveloperMode.debugPrint(.histDone, "history fetch complete: trigger=\(trigger)")
            await finishFetch()
            return
        }

        // Step 3: fetch from `resumeCursor` -- the stored position, or the very beginning when the
        // device cannot reach it. See that function; it is the whole of the reset handling.
        let startCursor = HistoryIngestor.resumeCursor(recorded: recorded, deviceLast: deviceEntry)
        DeveloperMode.debugPrint(
            .histStart,
            "history fetch: resuming from event=\(startCursor)\(startCursor == 0 && recorded != nil ? " -- the stored position is unreachable, so from the start" : "")"
        )
        let rawEntries = await device.fetchHistory(startingFrom: startCursor)
            .filter { $0.eventNumber != nil }
            .sorted { ($0.eventNumber ?? 0) < ($1.eventNumber ?? 0) }
        guard let latestEntry = rawEntries.last else {
            logger.debug("history_ingest no new entries")
            DeveloperMode.debugPrint(.histDone, "history fetch complete: trigger=\(trigger)")
            await finishFetch()
            return
        }

        // Step 4: write all but the last entry as finalised; the last is the live/current one and is
        // handled separately in step 5.
        // Must run BEFORE the live-entry recordDeviceEvent call below: AppDataStore.recordDeviceEvent
        // tracks the highest start_epoch it's seen so it can pick UPDATE vs INSERT without an
        // ON CONFLICT round-trip, so device_event rows have to be written in ascending
        // start_epoch (i.e. chronological) order. Recording the live (latest) entry first would
        // make every one of these earlier entries look "already superseded", taking the UPDATE
        // branch against a row that was never inserted -- a silent no-op that drops the entire
        // backfill batch.
        //
        // Every entry is written, with no "have I seen this number before?" filter in front of it.
        // `recordDeviceEvent` matches on `(event_number, start_epoch)`, so re-writing a segment
        // already on record updates that row in place rather than duplicating it, and the database
        // is the one thing that can answer the question correctly across a reset -- a filter keyed
        // on the number alone discards a whole post-reset generation as "already seen".
        let deliverableEntries = Array(rawEntries.dropLast())
        var allDeliverableCommitted = true
        if deliverableEntries.isEmpty {
            logger.debug("history_ingest no deliverable entries (live entry withheld for UI)")
        } else {
            allDeliverableCommitted = writeFinalisedEntries(deliverableEntries)
        }

        // Step 5: update the last known (current) entry from the history just received. The last
        // frame of a *complete* transmission is always the device's still-open segment (see
        // docs/timeflip.md §5) -- but a stream cut short by a dropped connection can also end on a
        // frame that's actually already closed, with more (unfetched) history beyond it that we
        // simply haven't received yet. Only trust and surface this frame as "current" once it
        // matches the device's own last event number read in step 2 AND everything ahead of it
        // actually got committed; otherwise leave it untouched (neither recorded nor
        // displayed) so the next refresh resumes from the same point and resolves the ambiguity,
        // instead of showing a stale or premature "current" activity.
        let latestEventNumber = latestEntry.eventNumber
        let latestIsConfirmedCurrent: Bool = {
            guard let deviceLastEventNumber = deviceEntry?.eventNumber else { return true }
            guard let latestEventNumber else { return false }
            return latestEventNumber >= deviceLastEventNumber
        }()
        guard latestIsConfirmedCurrent, allDeliverableCommitted else {
            // Deliberately doesn't force an immediate retry (e.g. via `pending`): if the ambiguity
            // is a transient stream cutoff, the next periodic/live-event trigger re-resolves it
            // naturally; if it's a persistently stuck connection, retrying in a tight loop here
            // would just hammer the device forever instead of leaving recovery to the existing
            // reconnect/backoff handling.
            logger.debug(
                "history_ingest live entry withheld: confirmed_current=\(latestIsConfirmedCurrent, privacy: .public) all_committed=\(allDeliverableCommitted, privacy: .public)"
            )
            DeveloperMode.debugPrint(.histResult, "history fetch: live entry ambiguous or backlog incomplete, deferring to next trigger")
            DeveloperMode.debugPrint(.histDone, "history fetch complete: trigger=\(trigger)")
            await finishFetch()
            return
        }

        // Record the confirmed-current segment as not-yet-finalised so device_event reflects the
        // live segment, growing in duration on each refresh until a later event closes it out.
        if let latestEventNumber {
            dataStore.recordDeviceEvent(
                eventNumber: latestEventNumber,
                deviceFace: latestEntry.faceID,
                startedAt: latestEntry.startedAt,
                durationSeconds: latestEntry.duration,
                isPaused: latestEntry.isPaused
            )
        }

        // Update UI with latest entry AFTER accumulating deliverable entries
        onLatestEntry?(latestEntry)

        // Once per batch (not once per recordDeviceEvent call above) so a backlog of history
        // doesn't spam the console with one line per record.
        dataStore.verifyMaxKnownStartEpochConsistency()

        // Backstop rather than the main path: every recordDeviceEvent call above has already run the
        // narrow conversion (createTimeEntriesForFinalisedEvents), so by here there is normally
        // nothing left to convert. This is the wider pass, the one that drops the processed
        // condition, and it earns its one query two ways: it catches a batch that finalises rows by
        // some route not going through recordDeviceEvent, and it reports any row left marked
        // processed with no time_entry to show for it, which the narrow conversion cannot see.
        dataStore.sweepTimeEntries(trigger: .historyIngest)

        // Last, because the totals are read out of `time_entry` and everything above is what puts
        // rows there. Seeding before the sweep would leave a segment the sweep repaired out of the
        // day's figure until the next refresh.
        refreshDailyTotals()

        DeveloperMode.debugPrint(.histDone, "history fetch complete: trigger=\(trigger)")
        await finishFetch()
    }

    /// Clears the in-flight flag and, if another trigger arrived while this fetch was running,
    /// re-runs after a short debounce so dense bursts collapse into one trailing re-fetch instead
    /// of hammering the device back-to-back.
    private func finishFetch() async {
        isFetching = false
        if pending {
            pending = false
            try? await Task.sleep(nanoseconds: debounceInterval)
            await refreshHistory(trigger: "debounce")
        }
    }

    /// Writes entries to `device_event` in order, stopping at the first write failure so a later
    /// event can never be recorded over the gap an earlier failure left -- the failed event is
    /// retried on the next fetch instead of being lost. Returns whether the whole batch landed,
    /// which is what gates surfacing the live frame below.
    ///
    /// Every entry here is one the device has moved past (a later event closed it out), so each
    /// write is the finalising one for its segment -- see the live-entry recording above for the
    /// in-progress one. This used to write the legacy `logbook` first and take *its* result as the
    /// halt signal, with the `device_event` write following unchecked; with that table gone the
    /// remaining write is the one that decides.
    private func writeFinalisedEntries(_ entries: [TimeFlipHistoryEntry]) -> Bool {
        for entry in entries {
            guard let eventNumber = entry.eventNumber else { continue }
            guard dataStore.recordDeviceEvent(
                eventNumber: eventNumber,
                deviceFace: entry.faceID,
                startedAt: entry.startedAt,
                durationSeconds: entry.duration,
                isPaused: entry.isPaused
            ) else {
                logger.error("device_event_commit_failed ev=\(eventNumber, privacy: .public); halting batch")
                return false
            }
            logger.debug("device_event_commit ev=\(eventNumber, privacy: .public) face=\(entry.faceID, privacy: .public)")
        }
        return true
    }

    /// Re-reads the day's per-category totals from `time_entry` and publishes them.
    ///
    /// Each committed segment used to be added to a running in-memory tally as it was written,
    /// which only stayed right for as long as no segment was ever written twice. That held because
    /// an event-number filter suppressed the second write, and it is exactly the filter this design
    /// does without: a re-delivered segment is re-written, deliberately, because the database is
    /// what decides whether it is new. Adding its duration a second time would inflate the day.
    ///
    /// So the totals are derived rather than accumulated. `seedFromHistory` sums the entries
    /// overlapping the current window, and a figure re-derived from the rows cannot drift from them.
    private func refreshDailyTotals() {
        dailyTotals.seedFromHistory()
        appState.replaceDailyTotals(dailyTotals.totals)
    }

    /// Where the next history stream starts, as a pure function of two readings: the newest segment
    /// the database holds, and the segment the device reports as its last.
    ///
    /// **The stored position is used only if the device's own last event is at or after it in both
    /// the counter and the clock.** Failing either, the stream starts from the beginning, because the
    /// position names a segment the cube can no longer reach and asking for it returns nothing --
    /// forever, while the events the device does hold are never fetched.
    ///
    /// Two ways it fails, and the second is why the comparison is not just on the number:
    /// - **A lower number.** The counter restarted at 1, which is what a factory reset does.
    /// - **An earlier start.** Within one counter generation a later event never begins before an
    ///   earlier one, so a "newer" event that started before the row on file proves the generation
    ///   changed. This is what catches a reset that has already counted back up to the stored number,
    ///   where the numbers match and nothing about them looks wrong. Production is exactly that
    ///   shape: its newest row is event 10, and event 10 also exists in two dead generations.
    ///
    /// Resuming *at* the stored position rather than past it is deliberate: that row is normally the
    /// still-open segment, and asking for it again is how its finished duration comes back.
    ///
    /// A read the device did not answer (`nil`) leaves the stored position standing, so a timeout
    /// re-requests the same thing rather than re-streaming the lot; the next refresh resolves it.
    ///
    /// **This replaces a reset special case, not just the comparison inside one.** A device saying it
    /// cannot reach the position is unavoidable information, but everything that used to hang off it
    /// is gone: a `resumedFromReset` flag, four in-memory event-number cursors hydrated at the start
    /// of a session, and the invalidation that had to clear all four in step whenever the flag was
    /// set. The position is read from `device_event` on every refresh, so there is nothing to
    /// invalidate -- once a post-reset row is in the table the same read simply returns it.
    ///
    /// The stored rows stay put either way: they are recorded time, and the cube restarting a counter
    /// says nothing about time already spent. `recordDeviceEvent` matches on
    /// `(event_number, start_epoch)`, so a reused number lands as its own row rather than overwriting
    /// the old generation's.
    ///
    /// **What this still does not cover:** a cube reset while the app is not running, which then
    /// counts *past* the stored position before the next launch. It reports both a higher number and a
    /// later start, so both tests pass and the two generations merge with the new one's early events
    /// never ingested. Telling that case apart needs a second device read -- asking for the device's
    /// own event 10 and seeing that it began at a different second from the row on file.
    static func resumeCursor(recorded: RecordedEvent?, deviceLast: TimeFlipHistoryEntry?) -> UInt32 {
        guard let recorded else { return 0 }
        guard let deviceLast, let deviceLastEventNumber = deviceLast.eventNumber else {
            return recorded.eventNumber
        }
        // The device is sitting on the very segment already recorded. Not reached from
        // `refreshHistory`, which returns on that case before getting here, but it is the position
        // to resume from, so the rule stays true on its own rather than only in context.
        if recorded.isSameSegment(as: deviceLast) { return recorded.eventNumber }
        // At or after in the clock as well as ahead in the counter. `>=` rather than `>` because a
        // zero-duration segment can share its second with the one that follows it -- production holds
        // several, e.g. events 24, 25 and 26 of the 2026-07-30 generation.
        let deviceStartEpoch = Int64(deviceLast.startedAt.timeIntervalSince1970)
        guard deviceLastEventNumber > recorded.eventNumber,
              deviceStartEpoch >= recorded.startEpoch else { return 0 }
        return recorded.eventNumber
    }
}

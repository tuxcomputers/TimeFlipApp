import Foundation
import OSLog

/// Fetches device history, writes completed entries to the logbook, and updates UI with the live frame.
@MainActor
final class HistoryIngestor {
    private let device: TimeFlipSessionManaging
    private let dataStore: AppDataStore
    private let appState: AppState
    private let dailyTotals: DailyFacetTotals
    private let onNewEvents: (() -> Void)?
    private let onLatestEntry: ((TimeFlipHistoryEntry) -> Void)?
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "history-ingestor")

    private var lastQueuedEventNumber: UInt32?
    private var lastCommittedEventNumber: UInt32?
    // Highest event number actually seen in a device response, including the still-open segment
    // -- unlike lastCommittedEventNumber (which only advances once a later event closes one out),
    // this is what the cheap max-event-number check below compares against, so it correctly
    // recognizes "the open segment hasn't moved on either" as "nothing new" instead of always
    // treating the open segment's own number as unseen.
    private var lastObservedEventNumber: UInt32?
    private var isFetching = false
    private var pending = false
    private let debounceInterval: UInt64 = 250_000_000 // 250ms
    private var periodicFetchTimer: Timer?

    private let deviceCursorIdentifier = "device-history"

    init(
        device: TimeFlipSessionManaging,
        dataStore: AppDataStore,
        appState: AppState,
        dailyTotals: DailyFacetTotals,
        onNewEvents: (() -> Void)? = nil,
        onLatestEntry: ((TimeFlipHistoryEntry) -> Void)? = nil
    ) {
        self.device = device
        self.dataStore = dataStore
        self.appState = appState
        self.dailyTotals = dailyTotals
        self.onNewEvents = onNewEvents
        self.onLatestEntry = onLatestEntry
    }

    @MainActor
    deinit {
        periodicFetchTimer?.invalidate()
    }

    /// Starts a repeating timer (interval from the `fetch_history_interval_seconds` setting) that
    /// re-fetches device history so any entries the device hasn't pushed a live notification for
    /// yet still get picked up, on top of the fetches already triggered by live facet/pause
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
            return
        }
        isFetching = true
        pending = false

        // Step 1: the max event number already known locally, including a still-open segment
        // that's never been formally "committed" to the cursor (see lastObservedEventNumber) --
        // falls back to the committed cursor on a fresh session for an already-paired device, so
        // the check below still applies rather than silently skipping it until the first
        // observation happens to land. ensureCursorLoaded() must run first: on a session's very
        // first refresh, lastCommittedEventNumber is still nil in memory even though a persisted
        // cursor exists on disk, and without loading it here, knownMax would read as nil (forcing
        // a full fetch) on every app launch regardless of whether anything actually changed.
        ensureCursorLoaded()
        let knownMax = lastObservedEventNumber ?? lastCommittedEventNumber
        logger.debug("history_ingest trigger=\(trigger, privacy: .public) known_max=\(knownMax ?? 0)")
        DeveloperMode.debugPrint(.history, "history fetch triggered: trigger=\(trigger) known_max=\(knownMax ?? 0)")

        // Step 2: cheap single-frame read of the device's actual current record. Per the vendor
        // spec this comes back as a complete History block (facet/start time/duration included,
        // not just the event number), so if it turns out nothing changed we can still refresh the
        // DB's duration for that entry below without paying for the full stream. A brand-new
        // pairing has nothing local to compare against, and a failed/timed-out read comes back
        // nil -- both fall through to the full fetch rather than getting stuck.
        let deviceEntry = await device.readLastEvent()
        let deviceLastEventNumber = deviceEntry?.eventNumber
        DeveloperMode.debugPrint(
            .history,
            "history fetch: cheap check device_last_event=\(deviceLastEventNumber.map(String.init) ?? "nil") known_max=\(knownMax.map(String.init) ?? "nil")"
        )

        if let knownMax, let deviceEntry, let deviceLastEventNumber, deviceLastEventNumber == knownMax {
            // Same event -- nothing new, but its duration may have grown since we last saw it.
            dataStore.recordDeviceEvent(
                eventNumber: deviceLastEventNumber,
                deviceFace: deviceEntry.facetID,
                startedAt: deviceEntry.startedAt,
                durationSeconds: deviceEntry.duration,
                isPaused: deviceEntry.isPaused
            )
            onLatestEntry?(deviceEntry)
            logger.debug("history_ingest device_max=\(deviceLastEventNumber, privacy: .public) unchanged; DB refreshed, stream skipped")
            DeveloperMode.debugPrint(.history, "history fetch: device max_event_number=\(deviceLastEventNumber) unchanged; DB refreshed")
            await finishFetch()
            return
        }

        // Step 3: different (or unknown) -- fetch history starting AT the last known event
        // (nextStartCursor() resolves to lastCommittedEventNumber + 1, which is the previously
        // still-open entry's own number, not past it) so its complete/updated record comes back
        // too, instead of leaving its state ambiguous.
        let startCursor = nextStartCursor()
        let rawEntries = await device.fetchHistory(startingFrom: startCursor)
            .filter { $0.eventNumber != nil }
            .sorted { ($0.eventNumber ?? 0) < ($1.eventNumber ?? 0) }
        guard let latestEntry = rawEntries.last else {
            logger.debug("history_ingest no new entries")
            await finishFetch()
            return
        }

        // Step 5: insert the rest -- deliver all but the last entry to the logbook; the last entry
        // is handled separately below (step 4) since it's the live/current one, not a closed one.
        // Must run BEFORE the live-entry recordDeviceEvent call below: AppDataStore.recordDeviceEvent
        // tracks the highest start_epoch it's seen so it can pick UPDATE vs INSERT without an
        // ON CONFLICT round-trip, so device_event rows have to be written in ascending
        // start_epoch (i.e. chronological) order. Recording the live (latest) entry first would
        // make every one of these earlier entries look "already superseded", taking the UPDATE
        // branch against a row that was never inserted -- a silent no-op that drops the entire
        // backfill batch.
        let deliverableEntries = Array(rawEntries.dropLast())
        var allDeliverableCommitted = true
        if deliverableEntries.isEmpty {
            logger.debug("history_ingest no deliverable entries (live entry withheld for UI)")
        } else {
            let newEntries = deliverableEntries.filter { entry in
                guard let ev = entry.eventNumber else { return false }
                guard let lastQueuedEventNumber else { return true }
                return ev > lastQueuedEventNumber
            }
            if !newEntries.isEmpty {
                if let maxEv = await writeToLogbook(newEntries) {
                    lastQueuedEventNumber = max(lastQueuedEventNumber ?? 0, maxEv)
                    lastCommittedEventNumber = max(lastCommittedEventNumber ?? 0, maxEv)
                    persistDeviceCursor()
                    logger.notice("history_ingest logbook advanced_event_to=\(maxEv, privacy: .public)")
                    allDeliverableCommitted = maxEv == newEntries.last?.eventNumber
                } else {
                    logger.error("history_ingest no entries committed this batch; cursor unchanged")
                    allDeliverableCommitted = false
                }
                onNewEvents?()
            }
        }

        // Step 4: update the last known (current) entry from the history just received. The last
        // frame of a *complete* transmission is always the device's still-open segment (see
        // docs/timeflip.md §5) -- but a stream cut short by a dropped connection can also end on a
        // frame that's actually already closed, with more (unfetched) history beyond it that we
        // simply haven't received yet. Only trust and surface this frame as "current" once it
        // matches the device's own last event number read in step 2 AND everything ahead of it
        // actually made it into the logbook; otherwise leave it untouched (neither committed nor
        // displayed) so the next refresh resumes from the same point and resolves the ambiguity,
        // instead of showing a stale or premature "current" activity.
        let latestEventNumber = latestEntry.eventNumber
        let latestIsConfirmedCurrent: Bool = {
            guard let deviceLastEventNumber else { return true }
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
            DeveloperMode.debugPrint(.history, "history fetch: live entry ambiguous or backlog incomplete, deferring to next trigger")
            await finishFetch()
            return
        }

        // Record the confirmed-current segment as not-yet-finalised so device_event reflects the
        // live segment, growing in duration on each refresh until a later event closes it out.
        if let latestEventNumber {
            dataStore.recordDeviceEvent(
                eventNumber: latestEventNumber,
                deviceFace: latestEntry.facetID,
                startedAt: latestEntry.startedAt,
                durationSeconds: latestEntry.duration,
                isPaused: latestEntry.isPaused
            )
            lastObservedEventNumber = max(lastObservedEventNumber ?? 0, latestEventNumber)
        }

        // Update UI with latest entry AFTER accumulating deliverable entries
        onLatestEntry?(latestEntry)

        // Once per batch (not once per recordDeviceEvent call above) so a backlog of history
        // doesn't spam the console with one line per record.
        dataStore.verifyMaxKnownStartEpochConsistency()

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

    /// Writes entries to the logbook in order, stopping at the first write failure so the
    /// device cursor (advanced by the caller based on the returned value) never skips past an
    /// uncommitted event — the failed event is retried on the next fetch instead of being lost.
    @discardableResult
    private func writeToLogbook(_ entries: [TimeFlipHistoryEntry]) async -> UInt32? {
        var maxCommitted: UInt32?
        for entry in entries {
            guard let eventNumber = entry.eventNumber else { continue }
            let activity = appState.activity(for: entry.facetID)
                ?? Activity(name: "Unassigned", iconName: nil, limitMinutes: 0)
            let record = DeviceEventRecord(
                id: nil,
                eventNumber: eventNumber,
                facetID: entry.facetID,
                startedAt: entry.startedAt,
                duration: entry.duration,
                isPaused: entry.isPaused,
                activityName: activity.name
            )
            guard dataStore.append(record) else {
                logger.error("logbook_commit_failed ev=\(eventNumber, privacy: .public); halting batch")
                break
            }
            // Only reached for entries the device has moved past (a later event closed them out),
            // so this is always the finalising write for this event_number -- see the live-entry
            // recording above for the in-progress segment.
            dataStore.recordDeviceEvent(
                eventNumber: eventNumber,
                deviceFace: entry.facetID,
                startedAt: entry.startedAt,
                durationSeconds: entry.duration,
                isPaused: entry.isPaused
            )
            // Only accumulate time for active (non-paused) segments
            if !entry.isPaused {
                let added = dailyTotals.accumulate(start: entry.startedAt, duration: entry.duration, facetID: entry.facetID)
                if added > 0 {
                    appState.incrementDailyTotal(facetID: entry.facetID, by: added)
                }
            }
            maxCommitted = eventNumber
            logger.debug("logbook_commit ev=\(eventNumber, privacy: .public) facet=\(entry.facetID, privacy: .public)")
        }
        return maxCommitted
    }

    private func persistLogbookCursor() {
        // no-op: delivery cursors are managed by integrations using logbook rowids
    }

    private func persistDeviceCursor() {
        if let committed = lastCommittedEventNumber {
            dataStore.saveEventCursor(
                target: .local,
                identifier: deviceCursorIdentifier,
                lastSentEventID: Int64(committed)
            )
        }
    }

    func resetCursors(reason: String) {
        lastQueuedEventNumber = nil
        lastCommittedEventNumber = nil
        lastObservedEventNumber = nil
        dataStore.clearEventCursors()
        dataStore.purgeAllEvents()
        logger.notice("history_ingest cursors reset reason=\(reason, privacy: .public)")
    }

    /// Hydrates lastCommittedEventNumber/lastQueuedEventNumber from the persisted cursor exactly
    /// once per instance lifetime (a no-op once either is already set, whether from a prior
    /// commit this session or a previous call to this method) -- must run before anything reads
    /// lastCommittedEventNumber, or a fresh session would see it as nil despite a real persisted
    /// value existing on disk.
    private func ensureCursorLoaded() {
        guard lastCommittedEventNumber == nil else { return }
        if let persisted = dataStore.loadEventCursor(target: .local, identifier: deviceCursorIdentifier) {
            let asUInt32 = UInt32(clamping: persisted)
            lastCommittedEventNumber = asUInt32
            lastQueuedEventNumber = asUInt32
        }
    }

    private func nextStartCursor() -> UInt32? {
        ensureCursorLoaded()
        if let cached = lastCommittedEventNumber {
            return cached &+ 1
        }
        return 0
    }
}

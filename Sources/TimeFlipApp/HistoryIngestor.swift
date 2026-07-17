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

        let startCursor = nextStartCursor()
        logger.debug("history_ingest trigger=\(trigger, privacy: .public) start_cursor=\(startCursor ?? 0)")
        DeveloperMode.debugPrint(.history, "history fetch triggered: trigger=\(trigger) start_cursor=\(startCursor ?? 0)")
        let rawEntries = await device.fetchHistory(startingFrom: startCursor)
            .filter { $0.eventNumber != nil }
            .sorted { ($0.eventNumber ?? 0) < ($1.eventNumber ?? 0) }
        guard let latestEntry = rawEntries.last else {
            logger.debug("history_ingest no new entries")
            isFetching = false
            if pending {
                pending = false
                try? await Task.sleep(nanoseconds: debounceInterval)
                await refreshHistory(trigger: "debounce")
            }
            return
        }

        // Deliver all but the last entry to the logbook; keep the last entry for live menu/state updates.
        // Must run BEFORE the live-entry recordDeviceEvent call below: AppDataStore.recordDeviceEvent
        // tracks the highest start_epoch it's seen so it can pick UPDATE vs INSERT without an
        // ON CONFLICT round-trip, so device_events rows have to be written in ascending
        // start_epoch (i.e. chronological) order. Recording the live (latest) entry first would
        // make every one of these earlier entries look "already superseded", taking the UPDATE
        // branch against a row that was never inserted -- a silent no-op that drops the entire
        // backfill batch.
        let deliverableEntries = Array(rawEntries.dropLast())
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
                } else {
                    logger.error("history_ingest no entries committed this batch; cursor unchanged")
                }
                onNewEvents?()
            }
        }

        // The device always reports its still-open, in-progress segment as the last frame (see
        // docs/timeflip.md §5); record it as not-yet-finalised so device_events reflects the live
        // segment, growing in duration on each refresh until a later event closes it out.
        if let latestEventNumber = latestEntry.eventNumber {
            dataStore.recordDeviceEvent(
                eventNumber: latestEventNumber,
                deviceFace: latestEntry.facetID,
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

        isFetching = false
        if pending {
            pending = false
            // Debounce to avoid hammering the device on dense event bursts.
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
        dataStore.clearEventCursors()
        dataStore.purgeAllEvents()
        logger.notice("history_ingest cursors reset reason=\(reason, privacy: .public)")
    }

    private func nextStartCursor() -> UInt32? {
        if let cached = lastCommittedEventNumber {
            return cached &+ 1
        }
        if let persisted = dataStore.loadEventCursor(target: .local, identifier: deviceCursorIdentifier) {
            let asUInt32 = UInt32(clamping: persisted)
            lastCommittedEventNumber = asUInt32
            lastQueuedEventNumber = asUInt32
            return asUInt32 &+ 1
        }
        return 0
    }
}

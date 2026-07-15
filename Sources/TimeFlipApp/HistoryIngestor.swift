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

        // Update UI with latest entry AFTER accumulating deliverable entries
        onLatestEntry?(latestEntry)

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

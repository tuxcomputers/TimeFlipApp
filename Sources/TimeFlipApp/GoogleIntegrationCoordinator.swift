import Foundation
import OSLog

@MainActor
final class GoogleIntegrationCoordinator {
    private enum Constants {
        static let minCalendarDuration: TimeInterval = 15 * 60
    }

    private let authManager: GoogleAuthManager?
    private let calendarClient: GoogleCalendarClient
    private let dataStore: AppDataStore
    private let cursorStore: IntegrationEventCursorStore
    private let tokenProvider: () async throws -> String
    private let preferencesProvider: () -> IntegrationPreferences
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "google-integration")
    private let integrationEnabled: Bool
    private var isProcessing = false
    // Set when a trigger arrives while processPending is already running, so that run picks up
    // the new work in another pass instead of the trigger being silently dropped.
    private var needsRerun = false
    private var periodicRetryTask: Task<Void, Never>?
    private let maxBatch = 200

    var isEnabled: Bool { integrationEnabled }

    init(
        authManager: GoogleAuthManager? = nil,
        calendarClient: GoogleCalendarClient = GoogleCalendarAPIClient(),
        tokenProvider: (() async throws -> String)? = nil,
        store: AppDataStore = AppDataStore(),
        preferencesProvider: @escaping () -> IntegrationPreferences = {
            IntegrationPreferences(calendarId: nil)
        },
        integrationEnabled: Bool = true
    ) {
        self.authManager = authManager
        self.calendarClient = calendarClient
        self.dataStore = store
        self.cursorStore = store
        self.preferencesProvider = preferencesProvider
        self.integrationEnabled = integrationEnabled
        self.tokenProvider = tokenProvider ?? { [weak authManager] in
            guard let authManager else { throw GoogleIntegrationCoordinatorError.missingAuthManager }
            return try await authManager.accessToken()
        }
    }

    func fetchCalendars() async throws -> [GoogleCalendarSummary] {
        guard integrationEnabled else { throw GoogleIntegrationCoordinatorError.disabled }
        let accessToken = try await tokenProvider()
        return try await calendarClient.listCalendars(accessToken: accessToken)
    }

    /// The connected account's identity as already cached in the `setting` table, with no network
    /// call. `nil` on a cache miss (nothing fetched yet).
    func cachedAccountInfo() -> GoogleAccountInfo? {
        guard integrationEnabled else { return nil }
        return dataStore.loadGoogleAccount()
    }

    /// Cache-first account identity: returns the cached copy if present, otherwise fetches it from
    /// the userinfo endpoint once and caches it. Only the first call after sign-in hits the network.
    @discardableResult
    func loadAccountInfo() async throws -> GoogleAccountInfo? {
        guard integrationEnabled else { return nil }
        if let cached = dataStore.loadGoogleAccount() {
            return cached
        }
        let accessToken = try await tokenProvider()
        let info = try await calendarClient.fetchUserInfo(accessToken: accessToken)
        dataStore.saveGoogleAccount(info)
        return info
    }

    /// Drops the cached account identity (sign-out) so the next `loadAccountInfo()` re-fetches.
    func clearCachedAccountInfo() {
        dataStore.clearGoogleAccount()
    }

    func flushPendingSessions() {
        guard integrationEnabled else {
            logger.info("flushPendingSessions skipped: integrations disabled")
            return
        }
        Task { @MainActor in
            await self.processPending()
        }
    }

    /// Awaitable variant of `flushPendingSessions()` for callers (namely tests) that need
    /// delivery to have actually finished before proceeding, instead of guessing at a sleep.
    func flushPendingSessionsAndWait() async {
        guard integrationEnabled else {
            logger.info("flushPendingSessions skipped: integrations disabled")
            return
        }
        await processPending()
    }

    /// Periodically re-triggers delivery so a target that's backing off after a failure (or a
    /// trigger that arrived with nothing else to wake `processPending`) eventually retries
    /// without needing a new device event.
    func startPeriodicRetryTimer(interval: TimeInterval = 60) {
        guard integrationEnabled, periodicRetryTask == nil else { return }
        periodicRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.flushPendingSessions()
            }
        }
    }

    func stopPeriodicRetryTimer() {
        periodicRetryTask?.cancel()
        periodicRetryTask = nil
    }

    private func writeCalendarEvent(accessToken: String, calendarId: String, record: ActivityRecord) async throws {
        let event = GoogleCalendarEvent(
            summary: record.activityName,
            description: "",
            startDate: record.startDate,
            endDate: record.endDate
        )
        logger.debug("writeCalendarEvent id=\(calendarId, privacy: .public) start=\(record.startDate.timeIntervalSince1970, privacy: .public) dur=\(record.duration, privacy: .public)")
        try await calendarClient.insertEvent(accessToken: accessToken, calendarId: calendarId, event: event)
    }

    // MARK: - Session helpers

    private func buildTargets(preferences: IntegrationPreferences) -> [IntegrationTargetDescriptor] {
        guard integrationEnabled else { return [] }
        var targets: [IntegrationTargetDescriptor] = []
        let calendarId = preferences.calendarId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !calendarId.isEmpty {
            targets.append(.calendar(calendarId))
        }
        return targets
    }

    private func processPending() async {
        guard integrationEnabled else {
            logger.info("processPending skipped: integrations disabled")
            return
        }
        guard !isProcessing else {
            logger.debug("process_pending deferred: already in-flight, will rerun")
            needsRerun = true
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        // Loop instead of a single pass: a trigger arriving mid-run sets needsRerun so its
        // events get delivered in another pass here, rather than being silently dropped.
        repeat {
            needsRerun = false
            let preferences = preferencesProvider()
            let targets = buildTargets(preferences: preferences)
            let targetList = targets.map { $0.asTarget.rawValue }.joined(separator: ",")
            logger.debug("process_pending targets=\(targetList, privacy: .public)")
            guard !targets.isEmpty else {
                logger.warning("processPending skipped: no calendar configured")
                break
            }
            for target in targets {
                guard shouldAttempt(target: target) else { continue }
                await deliverPendingSessions(to: target)
            }
        } while needsRerun
    }

    private func deliverPendingSessions(to target: IntegrationTargetDescriptor) async {
        guard integrationEnabled else { return }
        guard let identifier = target.identifier else { return }
        var cursor = cursorStore.loadEventCursor(target: target.asTarget, identifier: identifier)
        if cursor == nil, cursorStore.hasCursor(target: target.asTarget, excludingIdentifier: identifier),
           let maxRowID = dataStore.maxLogbookRowID() {
            // A cursor already exists under a *different* identifier for this target type, so
            // this is a switch (e.g. pointed at a different calendar), not the first-ever setup.
            // Seed at the current tip instead of delivering the entire historical logbook to the
            // newly chosen target — first-time setup with no prior cursor at all still sees the
            // existing backlog, which is what users expect when they first turn integration on.
            cursorStore.saveEventCursor(target: target.asTarget, identifier: identifier, lastSentEventID: maxRowID)
            cursor = maxRowID
            logger.notice(
                "deliver_pending seeded_cursor target=\(target.asTarget.rawValue, privacy: .public) identifier=\(identifier, privacy: .public) rowid=\(maxRowID, privacy: .public)"
            )
        }

        do {
            let accessToken = try await tokenProvider()
            while true {
                let events = dataStore.loadEvents(after: cursor, limit: maxBatch)
                logger.debug(
                    "deliver_pending target=\(target.asTarget.rawValue, privacy: .public) identifier=\(identifier, privacy: .public) cursor_rowid=\(cursor ?? 0, privacy: .public) events=\(events.count, privacy: .public)"
                )
                if events.isEmpty {
                    logger.info("deliverPending complete: no events after cursor for target=\(target.asTarget.rawValue, privacy: .public)")
                    return
                }

                for event in events {
                    do {
                        cursor = try await deliver(
                            event: event,
                            to: target,
                            accessToken: accessToken,
                            identifier: identifier,
                            currentCursor: cursor
                        )
                    } catch {
                        cursorStore.recordEventFailure(
                            target: target.asTarget,
                            identifier: identifier,
                            error: error.localizedDescription
                        )
                        logger.error(
                            "delivery_failed target=\(target.asTarget.rawValue, privacy: .public) rowid=\(event.id ?? -1, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                        markUnauthenticatedIfNeeded(error)
                        return
                    }
                }

                if events.count < maxBatch {
                    return
                }
            }
        } catch {
            cursorStore.recordEventFailure(
                target: target.asTarget,
                identifier: identifier,
                error: error.localizedDescription
            )
            logger.error(
                "token_failed target=\(target.asTarget.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            markUnauthenticatedIfNeeded(error)
        }
    }

    /// Google revoking access shows up as a 401/invalid_grant from the API, or as an
    /// invalid_grant failure surfaced while refreshing the token itself — either way, the UI
    /// should stop showing "connected" instead of quietly failing every delivery under backoff.
    private func markUnauthenticatedIfNeeded(_ error: Error) {
        let isRevoked: Bool
        if case GoogleAPIError.unauthorized = error {
            isRevoked = true
        } else {
            isRevoked = error.localizedDescription.contains("invalid_grant")
        }
        guard isRevoked else { return }
        authManager?.markUnauthenticated(reason: error.localizedDescription)
    }

    private func deliver(
        event: DeviceEventRecord,
        to target: IntegrationTargetDescriptor,
        accessToken: String,
        identifier: String,
        currentCursor: Int64?
    ) async throws -> Int64? {
        let record = ActivityRecord(
            activityName: event.activityName,
            startDate: event.startedAt,
            endDate: event.startedAt.addingTimeInterval(event.duration),
            duration: event.duration,
            reason: .history
        )

        switch target {
        case .calendar(let calendarId):
            guard record.duration >= Constants.minCalendarDuration else {
                logger.info(
                    "skip_calendar_short rowid=\(event.id ?? -1, privacy: .public) dur=\(record.duration, privacy: .public)"
                )
                if let rowid = event.id {
                    cursorStore.saveEventCursor(target: target.asTarget, identifier: identifier, lastSentEventID: rowid)
                    return rowid
                }
                return currentCursor
            }
            logger.debug(
                "deliver_calendar id=\(calendarId, privacy: .public) start=\(record.startDate.timeIntervalSince1970, privacy: .public) dur=\(record.duration, privacy: .public)"
            )
            try await writeCalendarEvent(accessToken: accessToken, calendarId: calendarId, record: record)
        }

        if let rowid = event.id {
            cursorStore.saveEventCursor(target: target.asTarget, identifier: identifier, lastSentEventID: rowid)
            logger.info(
                "delivered target=\(target.asTarget.rawValue, privacy: .public) start=\(record.startDate.timeIntervalSince1970, privacy: .public)"
            )
            return rowid
        }

        return currentCursor
    }

    private static func nextAttempt(afterFailures attempts: Int, from date: Date) -> Date {
        guard attempts > 0 else { return date }
        // Exponential backoff: 5s, 15s, 45s, 135s, capped at 5 minutes.
        let base: TimeInterval = 5
        let multiplier = pow(3, Double(max(0, attempts - 1)))
        let delay = min(base * multiplier, 300)
        return date.addingTimeInterval(delay)
    }

    private func shouldAttempt(target: IntegrationTargetDescriptor) -> Bool {
        guard let identifier = target.identifier else { return false }
        guard let status = cursorStore.loadEventCursorStatus(
            target: target.asTarget,
            identifier: identifier
        ) else { return true }
        let lastAttemptedAt = status.updatedAt ?? Date(timeIntervalSince1970: 0)
        let nextAllowed = Self.nextAttempt(afterFailures: status.attempts, from: lastAttemptedAt)
        if status.attempts > 0 && Date() < nextAllowed {
            logger.warning("backoff target=\(target.asTarget.rawValue, privacy: .public) attempts=\(status.attempts) next=\(nextAllowed.timeIntervalSince1970, privacy: .public)")
            return false
        }
        return true
    }
}

private enum IntegrationTargetDescriptor {
    case calendar(String)

    var asTarget: IntegrationTarget {
        switch self {
        case .calendar:
            return .calendar
        }
    }

    var identifier: String? {
        switch self {
        case .calendar(let id):
            return id
        }
    }

}

enum GoogleIntegrationCoordinatorError: Error {
    case missingAuthManager
    case disabled
}

struct IntegrationPreferences {
    let calendarId: String?
}

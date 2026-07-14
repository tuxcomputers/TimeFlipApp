import Foundation
import OSLog

@MainActor
final class GoogleIntegrationCoordinator {
    private enum Constants {
        static let minCalendarDuration: TimeInterval = 15 * 60
    }

    private let authManager: GoogleAuthManager?
    private let calendarClient: GoogleCalendarClient
    private let sheetsClient: GoogleSheetsClient
    private let dataStore: AppDataStore
    private let cursorStore: IntegrationEventCursorStore
    private let tokenProvider: () async throws -> String
    private let preferencesProvider: () -> IntegrationPreferences
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "google-integration")
    private var sheetTitleCache: [SheetCacheKey: String] = [:]
    private let integrationEnabled: Bool
    private var isProcessing = false
    private let maxBatch = 200

    var isEnabled: Bool { integrationEnabled }

    init(
        authManager: GoogleAuthManager? = nil,
        calendarClient: GoogleCalendarClient = GoogleCalendarAPIClient(),
        sheetsClient: GoogleSheetsClient = GoogleSheetsAPIClient(),
        tokenProvider: (() async throws -> String)? = nil,
        store: AppDataStore = AppDataStore(),
        preferencesProvider: @escaping () -> IntegrationPreferences = {
            IntegrationPreferences(calendarId: nil, sheetURL: nil)
        },
        integrationEnabled: Bool = true
    ) {
        self.authManager = authManager
        self.calendarClient = calendarClient
        self.sheetsClient = sheetsClient
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

    func flushPendingSessions() {
        guard integrationEnabled else {
            logger.info("flushPendingSessions skipped: integrations disabled")
            return
        }
        Task { @MainActor in
            await self.processPending()
        }
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

    private func appendSheetRow(accessToken: String, sheetURL: String, record: ActivityRecord) async throws {
        guard let destination = GoogleSheetDestination.parse(from: sheetURL) else {
            logger.error("Invalid Google Sheet URL: \(sheetURL, privacy: .public)")
            return
        }

        let range = try await resolveSheetRange(accessToken: accessToken, destination: destination)
        let timestamp = ActivityRecordFormatter.sheetsTimestamp(from: record.startDate)
        let duration = ActivityRecordFormatter.formattedDuration(record.duration)
        let values = [[timestamp, duration, record.activityName]]
        logger.debug("appendSheetRow sheet=\(destination.spreadsheetId, privacy: .public) start=\(record.startDate.timeIntervalSince1970, privacy: .public) dur=\(record.duration, privacy: .public)")
        try await sheetsClient.appendRow(
            accessToken: accessToken,
            spreadsheetId: destination.spreadsheetId,
            range: range,
            values: values
        )
    }

    private func resolveSheetRange(
        accessToken: String,
        destination: GoogleSheetDestination
    ) async throws -> String {
        let cacheKey = SheetCacheKey(spreadsheetId: destination.spreadsheetId, sheetGid: destination.sheetGid)
        if let cached = sheetTitleCache[cacheKey] {
            return "\(cached)!A:C"
        }

        let sheets = try await sheetsClient.fetchSheets(
            accessToken: accessToken,
            spreadsheetId: destination.spreadsheetId
        )
        let resolvedTitle: String?
        if let gid = destination.sheetGid {
            resolvedTitle = sheets.first { $0.id == gid }?.title
        } else {
            resolvedTitle = sheets.first?.title
        }

        if let resolvedTitle {
            sheetTitleCache[cacheKey] = resolvedTitle
            return "\(resolvedTitle)!A:C"
        }

        return "A:C"
    }

    // MARK: - Session helpers

    private func buildTargets(preferences: IntegrationPreferences) -> [IntegrationTargetDescriptor] {
        guard integrationEnabled else { return [] }
        var targets: [IntegrationTargetDescriptor] = []
        let calendarId = preferences.calendarId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sheetURL = preferences.sheetURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !calendarId.isEmpty {
            targets.append(.calendar(calendarId))
        }
        if !sheetURL.isEmpty {
            targets.append(.sheets(sheetURL))
        }
        return targets
    }

    private func processPending() async {
        guard integrationEnabled else {
            logger.info("processPending skipped: integrations disabled")
            return
        }
        guard !isProcessing else {
            logger.debug("process_pending skipped: already in-flight")
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        let preferences = preferencesProvider()
        let targets = buildTargets(preferences: preferences)
        let targetList = targets.map { $0.asTarget.rawValue }.joined(separator: ",")
        logger.debug("process_pending targets=\(targetList, privacy: .public)")
        guard !targets.isEmpty else {
            logger.warning("processPending skipped: no calendar/sheets configured")
            return
        }
        for target in targets {
            guard shouldAttempt(target: target) else { continue }
            await deliverPendingSessions(to: target)
        }
    }

    private func deliverPendingSessions(to target: IntegrationTargetDescriptor) async {
        guard integrationEnabled else { return }
        guard let identifier = target.identifier else { return }
        var cursor = cursorStore.loadEventCursor(target: target.asTarget, identifier: identifier)

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
        }
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
        case .sheets(let sheetURL):
            logger.debug(
                "deliver_sheet url=\(sheetURL, privacy: .private) start=\(record.startDate.timeIntervalSince1970, privacy: .public) dur=\(record.duration, privacy: .public)"
            )
            try await appendSheetRow(accessToken: accessToken, sheetURL: sheetURL, record: record)
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
    case sheets(String)

    var asTarget: IntegrationTarget {
        switch self {
        case .calendar:
            return .calendar
        case .sheets:
            return .sheets
        }
    }

    var identifier: String? {
        switch self {
        case .calendar(let id):
            return id
        case .sheets(let url):
            return url
        }
    }

}

private struct SheetCacheKey: Hashable {
    let spreadsheetId: String
    let sheetGid: Int?
}

enum GoogleIntegrationCoordinatorError: Error {
    case missingAuthManager
    case disabled
}

struct IntegrationPreferences {
    let calendarId: String?
    let sheetURL: String?
}

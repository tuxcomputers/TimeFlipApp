import Foundation

@MainActor
final class GoogleIntegrationCoordinator {
    private let authManager: GoogleAuthManager?
    private let calendarClient: GoogleCalendarClient
    private let dataStore: AppDataStore
    private let tokenProvider: () async throws -> String
    private let integrationEnabled: Bool

    var isEnabled: Bool { integrationEnabled }

    init(
        authManager: GoogleAuthManager? = nil,
        calendarClient: GoogleCalendarClient = GoogleCalendarAPIClient(),
        tokenProvider: (() async throws -> String)? = nil,
        store: AppDataStore = AppDataStore(),
        integrationEnabled: Bool = true
    ) {
        self.authManager = authManager
        self.calendarClient = calendarClient
        self.dataStore = store
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

    /// Creates a new secondary calendar (`calendars.insert`, permitted by the `calendar.app.created`
    /// scope) and returns it. The caller is responsible for the "already exists" check beforehand.
    func createCalendar(named name: String) async throws -> GoogleCalendarSummary {
        guard integrationEnabled else { throw GoogleIntegrationCoordinatorError.disabled }
        let accessToken = try await tokenProvider()
        return try await calendarClient.createCalendar(accessToken: accessToken, summary: name)
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
}

enum GoogleIntegrationCoordinatorError: Error {
    case missingAuthManager
    case disabled
}

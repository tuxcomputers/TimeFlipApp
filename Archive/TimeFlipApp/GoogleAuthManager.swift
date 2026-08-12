import Foundation
import OSLog

@MainActor
final class GoogleAuthManager: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?

    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "google-auth")
    private let stateStore: GoogleAuthStateStore
    private let configurationProvider: () throws -> GoogleAuthConfiguration
    // Kept alive across calls (instead of unarchived per request) so AppAuth's own refresh
    // coalescing and its stateChangeDelegate observer actually do something. Only rebuilt when
    // the resolved configuration (e.g. client ID/secret edited in Settings) actually changes.
    private var cachedService: GoogleAuthService?
    private var cachedConfiguration: GoogleAuthConfiguration?

    init(
        stateStore: GoogleAuthStateStore = KeychainAuthStateStore(),
        configurationProvider: @escaping () throws -> GoogleAuthConfiguration = {
            try GoogleAuthConfiguration.loadFromEnvironment()
        }
    ) {
        self.stateStore = stateStore
        self.configurationProvider = configurationProvider
        refreshStatus()
    }

    func refreshStatus() {
        do {
            let state = try stateStore.loadState()
            isAuthenticated = state?.isAuthorized ?? false
            errorMessage = nil
        } catch {
            isAuthenticated = false
            errorMessage = error.localizedDescription
        }
    }

    func authenticate() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil

        do {
            let service = try makeAuthService()
            let authState = try await service.authorize()
            isAuthenticated = authState.isAuthorized
            logger.notice("Google OAuth succeeded")
        } catch {
            isAuthenticated = false
            errorMessage = error.localizedDescription
            logger.error("Google OAuth failed: \(error.localizedDescription, privacy: .public)")
        }

        isAuthenticating = false
    }

    func signOut() {
        do {
            try stateStore.clearState()
            isAuthenticated = false
            errorMessage = nil
            logger.notice("Google OAuth cleared")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to clear Google OAuth token: \(error.localizedDescription, privacy: .public)")
        }
    }

    func accessToken() async throws -> String {
        let service = try makeAuthService()
        return try await service.freshAccessToken()
    }

    /// Called when a Google API call reports revoked/expired access (401 or invalid_grant) so
    /// the UI stops showing "connected" while every delivery silently fails under backoff.
    func markUnauthenticated(reason: String) {
        guard isAuthenticated else { return }
        isAuthenticated = false
        errorMessage = reason
        logger.error("Google access marked unauthenticated: \(reason, privacy: .public)")
    }

    private func makeAuthService() throws -> GoogleAuthService {
        let configuration = try configurationProvider()
        if let cachedService, cachedConfiguration == configuration {
            return cachedService
        }
        let service = GoogleAuthService(
            configuration: configuration,
            stateStore: stateStore,
            logger: logger
        )
        cachedService = service
        cachedConfiguration = configuration
        return service
    }
}

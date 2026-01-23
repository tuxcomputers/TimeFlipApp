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

    private func makeAuthService() throws -> GoogleAuthService {
        let configuration = try configurationProvider()
        return GoogleAuthService(
            configuration: configuration,
            stateStore: stateStore,
            logger: logger
        )
    }
}

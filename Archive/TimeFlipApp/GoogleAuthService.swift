import AppAuth
import AppKit
import Foundation
import OSLog

@MainActor
final class GoogleAuthService {
    private let configuration: GoogleAuthConfiguration
    private let stateStore: GoogleAuthStateStore
    private let logger: Logger
    private var stateObserver: GoogleAuthStateObserver?
    private var redirectHandler: OIDRedirectHTTPHandler?

    init(
        configuration: GoogleAuthConfiguration,
        stateStore: GoogleAuthStateStore = KeychainAuthStateStore(),
        logger: Logger = Logger(subsystem: AppIdentifiers.subsystem, category: "google-auth")
    ) {
        self.configuration = configuration
        self.stateStore = stateStore
        self.logger = logger
    }

    func authorize() async throws -> OIDAuthState {
        let serviceConfiguration = try await discoverServiceConfiguration()
        let loopbackHandler = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let redirectURL = loopbackHandler.startHTTPListener(&listenerError)
        if let listenerError {
            throw listenerError
        }

        let request = makeAuthorizationRequest(
            serviceConfiguration: serviceConfiguration,
            redirectURL: redirectURL
        )

        cancelCurrentFlow()

        let externalUserAgent = DefaultBrowserExternalUserAgent()
        let authState = try await withCheckedThrowingContinuation { continuation in
            let session = OIDAuthState.authState(
                byPresenting: request,
                externalUserAgent: externalUserAgent
            ) { [weak self, stateStore, logger] authState, error in
                self?.cancelCurrentFlow()
                if let authState {
                    do {
                        try stateStore.saveState(authState)
                        continuation.resume(returning: authState)
                    } catch {
                        logger.error("Failed to persist Google auth state: \(error.localizedDescription, privacy: .public)")
                        continuation.resume(throwing: error)
                    }
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: GoogleAuthError.authorizationFailed)
                }
            }

            loopbackHandler.currentAuthorizationFlow = session
            redirectHandler = loopbackHandler
        }

        attachObserver(to: authState)
        return authState
    }

    func loadState() throws -> OIDAuthState? {
        let state = try stateStore.loadState()
        if let state {
            attachObserver(to: state)
        }
        return state
    }

    func clearState() throws {
        try stateStore.clearState()
    }

    func freshAccessToken() async throws -> String {
        guard let authState = try loadState() else {
            throw GoogleAuthError.missingStoredState
        }

        return try await withCheckedThrowingContinuation { continuation in
            authState.performAction { [stateStore, logger] accessToken, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let accessToken else {
                    continuation.resume(throwing: GoogleAuthError.missingAccessToken)
                    return
                }
                do {
                    try stateStore.saveState(authState)
                    continuation.resume(returning: accessToken)
                } catch {
                    logger.error("Failed to persist refreshed Google auth state: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func discoverServiceConfiguration() async throws -> OIDServiceConfiguration {
        return try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.discoverConfiguration(
                forIssuer: configuration.issuer
            ) { serviceConfiguration, error in
                if let serviceConfiguration {
                    continuation.resume(returning: serviceConfiguration)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: GoogleAuthError.missingServiceConfiguration)
                }
            }
        }
    }

    private func makeAuthorizationRequest(
        serviceConfiguration: OIDServiceConfiguration,
        redirectURL: URL
    ) -> OIDAuthorizationRequest {
        let additionalParameters = [
            "access_type": "offline",
            "prompt": "consent",
            "include_granted_scopes": "true"
        ]

        if let clientSecret = configuration.clientSecret {
            return OIDAuthorizationRequest(
                configuration: serviceConfiguration,
                clientId: configuration.clientID,
                clientSecret: clientSecret,
                scopes: configuration.scopes,
                redirectURL: redirectURL,
                responseType: OIDResponseTypeCode,
                additionalParameters: additionalParameters
            )
        }

        return OIDAuthorizationRequest(
            configuration: serviceConfiguration,
            clientId: configuration.clientID,
            scopes: configuration.scopes,
            redirectURL: redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: additionalParameters
        )
    }

    private func attachObserver(to authState: OIDAuthState) {
        if authState.stateChangeDelegate == nil {
            let observer = GoogleAuthStateObserver(stateStore: stateStore, logger: logger)
            authState.stateChangeDelegate = observer
            authState.errorDelegate = observer
            stateObserver = observer
        }
    }

    private func cancelCurrentFlow() {
        redirectHandler?.cancelHTTPListener()
        redirectHandler = nil
    }
}

private final class DefaultBrowserExternalUserAgent: NSObject, OIDExternalUserAgent {
    private weak var session: OIDExternalUserAgentSession?
    private var isFlowInProgress = false

    func present(
        _ request: OIDExternalUserAgentRequest,
        session: OIDExternalUserAgentSession
    ) -> Bool {
        if isFlowInProgress {
            return false
        }
        isFlowInProgress = true
        self.session = session

        let opened = NSWorkspace.shared.open(request.externalUserAgentRequestURL())
        if !opened {
            isFlowInProgress = false
            self.session = nil
            let error = OIDErrorUtilities.error(
                with: OIDErrorCode.browserOpenError,
                underlyingError: nil,
                description: "Unable to open the default browser."
            )
            session.failExternalUserAgentFlowWithError(error)
        }
        return opened
    }

    func dismiss(animated: Bool, completion: @escaping @Sendable () -> Void) {
        _ = animated
        isFlowInProgress = false
        session = nil
        completion()
    }
}

private final class GoogleAuthStateObserver: NSObject, OIDAuthStateChangeDelegate, OIDAuthStateErrorDelegate {
    private let stateStore: GoogleAuthStateStore
    private let logger: Logger

    init(stateStore: GoogleAuthStateStore, logger: Logger) {
        self.stateStore = stateStore
        self.logger = logger
    }

    func didChange(_ state: OIDAuthState) {
        do {
            try stateStore.saveState(state)
        } catch {
            logger.error("Failed to persist Google auth state: \(error.localizedDescription, privacy: .public)")
        }
    }

    func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: Error) {
        _ = state
        logger.error("Google auth encountered error: \(error.localizedDescription, privacy: .public)")
    }
}

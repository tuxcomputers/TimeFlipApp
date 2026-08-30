import AppKit
import Foundation
import Network

/// The OAuth client this build signs in as.
///
/// **Resolved at the moment it is needed, not held from launch.** Three places are tried, override first, which is
/// `docs/google-oauth-setup.md` Part 2 step 2: it lets a developer point at a second project without a release build,
/// and gives somebody a way out if the bundled project is ever suspended.
struct GoogleCredentials: Equatable {
    let clientID: String
    let clientSecret: String

    /// `FACET_GOOGLE_CLIENT_JSON`, then `~/.config/facet/google-client.json`, then what was built in.
    ///
    /// **The first two are a file on one machine; only the third travels with the binary.** They are the console's
    /// own download, unedited, so there is nothing to transcribe, and they are what a developer resolves through --
    /// which is exactly why they cannot be the whole answer: a `.app` handed to somebody else finds neither.
    ///
    /// The third is `scripts/generate-credentials.sh`'s doing. It copies the same download to
    /// `Resources/google-client.json`, gitignored, so neither value is committed. **Absent, this is simply `nil`**,
    /// which is what lets a fresh clone build and run with no credentials and no generator run -- the app works,
    /// and the App tab says in words that this copy cannot sign in.
    ///
    /// Overrides ahead of it rather than behind it, deliberately: it lets a developer point at a second project
    /// without a release build, and gives somebody a way out if the bundled project is ever suspended.
    ///
    /// **It used to read two `Info.plist` keys here**, which no build step ever wrote, so the third source was dead
    /// and a distributed build could not sign in at all.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundled: GoogleCredentials? = .builtIn
    ) -> GoogleCredentials? {
        if let path = environment["FACET_GOOGLE_CLIENT_JSON"],
           let found = fromJSON(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) {
            return found
        }
        if let found = fromJSON(at: home.appendingPathComponent(".config/facet/google-client.json")) {
            return found
        }
        return bundled
    }

    /// What the generator built in, or `nil` when it had nothing to build in.
    ///
    /// **Read through `fromJSON`, the same reader the two overrides use**, because it is the same file: the
    /// generator copies the console's download verbatim rather than rewriting it, so there is one format and one
    /// parser rather than two that can drift.
    ///
    /// `Bundle.main` then `Bundle.module`, which is `DatabaseBootstrap.bundledDDLDirectory`'s order and for its
    /// reason: the first finds it inside a built `.app`, the second under `swift run` and `swift test`.
    ///
    /// A default argument on `resolve` rather than a read inside it, so a test can pass its own and never depend on
    /// whether the machine running the suite happens to have credentials sitting in its build directory.
    static var builtIn: GoogleCredentials? {
        guard
            let url = Bundle.main.url(forResource: "google-client", withExtension: "json")
                ?? Bundle.module.url(forResource: "google-client", withExtension: "json")
        else {
            return nil
        }
        return fromJSON(at: url)
    }

    /// Reads the console's download. Its top-level key is `installed` for a Desktop client, which is the type this app
    /// uses; a `web` key would mean the wrong one was made, and is treated as no credentials at all rather than being
    /// half-accepted.
    static func fromJSON(at url: URL) -> GoogleCredentials? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let installed = object["installed"] as? [String: Any],
            let id = installed["client_id"] as? String,
            let secret = installed["client_secret"] as? String
        else {
            return nil
        }
        return GoogleCredentials(clientID: id, clientSecret: secret)
    }
}

/// Listens on a loopback port for the one redirect Google sends back.
///
/// **The port is whatever the system gives**, never a fixed number. Google accepts any port on the loopback address
/// for an installed app precisely so it does not have to be registered, and a hardcoded one is a sign-in that breaks
/// the moment something else is holding it.
///
/// `@unchecked Sendable` because Network's callbacks arrive on its own queue: every mutable field here is touched
/// only inside `queue`, which is what makes that safe.
final class GoogleLoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "au.com.tux.facet.oauth-loopback")
    private let expectedState: String
    private var waiting: CheckedContinuation<GoogleOAuthRules.Redirect, Never>?
    private var starting: CheckedContinuation<UInt16, Error>?
    private var arrived: GoogleOAuthRules.Redirect?
    private var connections: [NWConnection] = []

    init(expectedState: String) throws {
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        // Loopback only. The redirect never crosses an interface, and binding wider would put a listener on the
        // network for as long as somebody has a browser tab open.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GoogleOAuthRules.Failure.listenerFailed(error.localizedDescription)
        }
    }

    /// Starts listening and answers with the port the system assigned.
    ///
    /// The continuation is held as a field rather than guarded by a lock: `stateUpdateHandler` is called on `queue`,
    /// which is serial, so "resume it once and only once" needs nothing more than clearing it first.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.starting = continuation
                self.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard let port = self.listener.port?.rawValue else {
                            self.finishStart(.failure(GoogleOAuthRules.Failure.listenerFailed("no port was assigned")))
                            return
                        }
                        self.finishStart(.success(port))
                    case let .failed(error):
                        self.finishStart(.failure(GoogleOAuthRules.Failure.listenerFailed(error.localizedDescription)))
                    case let .waiting(error):
                        // On loopback this means the port could not be taken, which is not going to improve on its own.
                        self.finishStart(.failure(GoogleOAuthRules.Failure.listenerFailed(error.localizedDescription)))
                    default:
                        break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        guard let starting else { return }
        self.starting = nil
        starting.resume(with: result)
    }

    /// The redirect, once it arrives. One value only: the listener is stopped as soon as it has one.
    func redirect() async -> GoogleOAuthRules.Redirect {
        await withCheckedContinuation { continuation in
            queue.async {
                if let arrived = self.arrived {
                    continuation.resume(returning: arrived)
                } else {
                    self.waiting = continuation
                }
            }
        }
    }

    /// Gives up waiting, so a browser tab nobody ever finishes does not leave a port open for the life of the process.
    func cancel(with redirect: GoogleOAuthRules.Redirect = .ignored) {
        queue.async {
            self.deliver(redirect)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let result = GoogleOAuthRules.redirect(fromRequestLine: String(line), expectedState: expectedState)

            // A browser asks for /favicon.ico beside the redirect. Answering it and carrying on is the difference
            // between a sign-in that works and one that ends on whichever request happened to land second.
            guard result != .ignored else {
                connection.cancel()
                return
            }
            let body: String
            if case .code = result {
                body = "Facet is connected."
            } else {
                body = "Facet is not connected."
            }
            connection.send(
                content: Data(GoogleOAuthRules.redirectResponse(body).utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
            self.deliver(result)
        }
    }

    /// Hands the redirect to whoever is waiting, exactly once, and shuts everything down.
    private func deliver(_ redirect: GoogleOAuthRules.Redirect) {
        guard arrived == nil else { return }
        arrived = redirect
        waiting?.resume(returning: redirect)
        waiting = nil
        listener.cancel()
        for connection in connections {
            connection.cancel()
        }
        connections = []
    }
}

/// Runs the sign-in, start to finish.
@MainActor
enum GoogleSignIn {
    /// How long a sign-in is allowed to sit unfinished before the port is given back.
    static let timeout: Duration = .seconds(300)

    /// Opens the browser, waits for the redirect, and exchanges the code for tokens.
    ///
    /// **Nothing is written here.** This answers with what Google said and leaves storing it to the caller, so the
    /// window keeps its one rule: write, read back, and only then believe it.
    static func run(
        credentials: GoogleCredentials,
        open: (URL) -> Void = { NSWorkspace.shared.open($0) },
        session: URLSession = .shared
    ) async throws -> GoogleOAuthRules.Tokens {
        let pkce = GoogleOAuthRules.pkce()
        let state = GoogleOAuthRules.state()
        let listener = try GoogleLoopbackListener(expectedState: state)
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        open(GoogleOAuthRules.authorizationURL(
            clientID: credentials.clientID, redirect: redirectURI, pkce: pkce, state: state
        ))

        let redirect = await withTaskGroup(of: GoogleOAuthRules.Redirect?.self) { group in
            group.addTask { await listener.redirect() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                listener.cancel(with: .ignored)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        switch redirect {
        case let .code(code):
            return try await exchange(
                code: code, verifier: pkce.verifier, redirect: redirectURI,
                credentials: credentials, session: session
            )
        case let .denied(reason):
            throw GoogleOAuthRules.Failure.denied(reason)
        case .ignored, .none:
            throw GoogleOAuthRules.Failure.cancelled
        }
    }

    /// Trades the authorization code for tokens.
    ///
    /// The client secret goes in the body, which is what Google's installed-app flow expects and is not a
    /// confidentiality claim: it ships in the binary. **PKCE is what makes this safe**, and the verifier is the one
    /// value here that never left this process.
    private static func exchange(
        code: String,
        verifier: String,
        redirect: String,
        credentials: GoogleCredentials,
        session: URLSession
    ) async throws -> GoogleOAuthRules.Tokens {
        var request = URLRequest(url: GoogleOAuthRules.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GoogleOAuthRules.Failure.exchangeFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Google puts a machine-readable reason in the body, and it is the only thing that distinguishes "your
            // project is suspended" from "that code was already used".
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw GoogleOAuthRules.Failure.exchangeFailed(reason ?? "the request was refused")
        }
        guard let tokens = GoogleOAuthRules.tokens(fromTokenResponse: data) else {
            throw GoogleOAuthRules.Failure.exchangeFailed("the reply could not be read")
        }
        guard tokens.refreshToken != nil else {
            throw GoogleOAuthRules.Failure.noRefreshToken
        }
        return tokens
    }
}

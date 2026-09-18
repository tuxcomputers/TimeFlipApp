import Foundation
#if canImport(Network)
import Network
#endif

// **The Darwin half of the listener, and it is the half still in the core.** The socket half moved to
// `FacetLinux/SocketLoopbackListener.swift` on 2026-09-18, which is the Linux side of item 16 of
// `docs/linux-port.md`; this one is the Mac's to move, and until it does this file is the last entry on
// `PlatformBlindCoreTests.adaptersStillInTheCore`.
//
// **Nothing about it changed in the move except its name and its conformance.** It is the path a real
// sign-in has used, and there was nothing to gain by touching it while shifting the other half out.
//
// **`GoogleLoopbackListener` was what both halves were called**, one visible at a time, and the name said
// nothing about which. `NetworkLoopbackListener` and `SocketLoopbackListener` each say what performs the
// capability, which is what the ports rule asks of an adapter's name.

#if canImport(Network)
/// Listens on a loopback port for the one redirect Google sends back.
///
/// **The port is whatever the system gives**, never a fixed number. Google accepts any port on the loopback address
/// for an installed app precisely so it does not have to be registered, and a hardcoded one is a sign-in that breaks
/// the moment something else is holding it.
///
/// `@unchecked Sendable` because Network's callbacks arrive on its own queue: every mutable field here is touched
/// only inside `queue`, which is what makes that safe.
package final class NetworkLoopbackListener: GoogleRedirectListener, @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "au.com.tux.facet.oauth-loopback")
    private let expectedState: String
    private var waiting: CheckedContinuation<GoogleOAuthRules.Redirect, Never>?
    private var starting: CheckedContinuation<UInt16, Error>?
    private var arrived: GoogleOAuthRules.Redirect?
    private var connections: [NWConnection] = []

    package init(expectedState: String) throws {
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
    package func start() async throws -> UInt16 {
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
    package func redirect() async -> GoogleOAuthRules.Redirect {
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
    package func cancel(with redirect: GoogleOAuthRules.Redirect = .ignored) {
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
            // The redirect is delivered from inside the completion, not beside the send. `deliver` cancels every
            // connection it holds, this one among them, so delivering before the send has been processed discards
            // the response: the app takes the code and the browser is left on an empty tab. `.contentProcessed`
            // arrives on `queue`, which is where every mutable field here is already touched.
            connection.send(
                content: Data(GoogleOAuthRules.redirectResponse(body).utf8),
                completion: .contentProcessed { [weak self] _ in
                    connection.cancel()
                    self?.deliver(result)
                }
            )
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

extension GoogleOAuthClient {
    /// The Darwin call, which supplies the listener still living in the core.
    ///
    /// **A staging post rather than a design.** `NetworkLoopbackListener` belongs in `FacetMac` beside every other
    /// Darwin adapter, and moving it is the Mac's half of item 16 of `docs/linux-port.md` -- a file this box cannot
    /// compile. Until then this overload keeps every macOS call site working unchanged while the Linux half is out,
    /// which is what let one machine do one half of a two-machine item without breaking the other.
    ///
    /// **It goes when that lands**, along with this whole file's `#if`, and the composition root supplies the
    /// listener the way it already supplies the browser.
    package static func run(
        credentials: GoogleCredentials,
        open: (URL) -> Void,
        session: URLSession = .shared
    ) async throws -> GoogleOAuthRules.Tokens {
        try await run(
            credentials: credentials,
            open: open,
            listening: { try NetworkLoopbackListener(expectedState: $0) },
            session: session
        )
    }
}
#endif

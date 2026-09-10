import Foundation
#if canImport(Network)
import Network
#else
#if canImport(Glibc)
import Glibc
#endif
#endif

// **The loopback listener, twice: Network where there is Network, and Berkeley sockets where there is
// not.** One interface, `init(expectedState:)` / `start()` / `redirect()` / `cancel(with:)`, and both
// answer the same three `GoogleOAuthRules.Redirect` cases from the same request line, through the same
// `GoogleOAuthRules.redirect(fromRequestLine:expectedState:)` and `redirectResponse(_:)`. What differs is
// only how bytes arrive.
//
// **The Darwin half is moved across unchanged**, deliberately: it is the path a real sign-in has used,
// and there is nothing to gain on that platform by rewriting it in sockets for the sake of having one
// implementation. What made this file portable enough to live in the core was taking it *out* of
// `GoogleOAuthClient`, which has since followed it in: that file's one tie to AppKit was a default argument
// handing the sign-in URL to a browser, and removing the default is what moved it. The browser is now
// supplied by whoever starts a sign-in, so both halves of the flow are core and only the opening is not.

#if canImport(Network)
/// Listens on a loopback port for the one redirect Google sends back.
///
/// **The port is whatever the system gives**, never a fixed number. Google accepts any port on the loopback address
/// for an installed app precisely so it does not have to be registered, and a hardcoded one is a sign-in that breaks
/// the moment something else is holding it.
///
/// `@unchecked Sendable` because Network's callbacks arrive on its own queue: every mutable field here is touched
/// only inside `queue`, which is what makes that safe.
package final class GoogleLoopbackListener: @unchecked Sendable {
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

#else

/// Listens on a loopback port for the one redirect Google sends back, over Berkeley sockets.
///
/// **The port is whatever the system gives**, exactly as the Network implementation has it: bound to port
/// 0 and read back with `getsockname`. Google accepts any loopback port for an installed app precisely so
/// it need not be registered, and a fixed one is a sign-in that breaks the moment something else holds it.
///
/// `@unchecked Sendable` for the same reason as the other half: every mutable field is touched only on
/// `queue`, which is serial. The accept loop runs on a thread of its own because `accept` blocks, and it
/// reaches state through `queue` like everything else.
package final class GoogleLoopbackListener: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "au.com.tux.facet.oauth-loopback")
    private var listening: Int32 = -1
    private var waiting: CheckedContinuation<GoogleOAuthRules.Redirect, Never>?
    private var arrived: GoogleOAuthRules.Redirect?

    /// Read by the accept thread and written by `queue`, so it carries its own lock rather than borrowing
    /// the queue: the thread cannot block on the queue to ask whether it should stop.
    private let stopLock = NSLock()
    private var stopRequested = false

    package init(expectedState: String) throws {
        self.expectedState = expectedState
    }

    /// Binds, listens, and answers with the port the system assigned.
    ///
    /// Synchronous work in an `async` signature, matching the other half's shape: there is nothing to wait
    /// for here, a `bind` either takes the port or does not.
    package func start() async throws -> UInt16 {
        let socketDescriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketDescriptor >= 0 else {
            throw GoogleOAuthRules.Failure.listenerFailed(Self.reasonFromErrno("a socket could not be made"))
        }

        // What `NWParameters.allowLocalEndpointReuse` asks for on the other side: a port left in
        // TIME_WAIT by the previous sign-in should not refuse this one.
        var reuse: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // **Loopback only**, which is the other half's `requiredInterfaceType = .loopback`. The redirect
        // never crosses an interface, and binding wider would put a listener on the network for as long as
        // somebody has a browser tab open. `bigEndian` rather than `htons`, which is a C macro Swift
        // cannot call.
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let reason = Self.reasonFromErrno("the loopback port could not be taken")
            close(socketDescriptor)
            throw GoogleOAuthRules.Failure.listenerFailed(reason)
        }
        guard listen(socketDescriptor, 8) == 0 else {
            let reason = Self.reasonFromErrno("the socket would not listen")
            close(socketDescriptor)
            throw GoogleOAuthRules.Failure.listenerFailed(reason)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard named == 0, assigned.sin_port != 0 else {
            let reason = Self.reasonFromErrno("no port was assigned")
            close(socketDescriptor)
            throw GoogleOAuthRules.Failure.listenerFailed(reason)
        }

        queue.sync { listening = socketDescriptor }
        let thread = Thread { [weak self] in self?.acceptLoop(socketDescriptor) }
        thread.name = "au.com.tux.facet.oauth-loopback.accept"
        thread.start()

        return assigned.sin_port.bigEndian
    }

    /// The redirect, once it arrives. One value only: the listener stops as soon as it has one.
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

    /// Gives up waiting, so a browser tab nobody ever finishes does not leave a port open for the life of
    /// the process.
    package func cancel(with redirect: GoogleOAuthRules.Redirect = .ignored) {
        queue.async {
            self.deliver(redirect)
        }
    }

    // MARK: - the accept loop

    /// **`poll` with a timeout rather than a bare `accept`.** Closing a descriptor another thread is
    /// blocked in `accept` on does not reliably wake it on Linux, so the loop asks whether anything is
    /// waiting, and between asks it checks whether it has been told to stop.
    private func acceptLoop(_ socketDescriptor: Int32) {
        while !isStopped() {
            var descriptor = pollfd(fd: socketDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0 else { continue }

            let connection = accept(socketDescriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }
            handle(connection)
        }
        close(socketDescriptor)
    }

    private func handle(_ connection: Int32) {
        defer { close(connection) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(connection, &buffer, buffer.count)
        let text = count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
        let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let result = GoogleOAuthRules.redirect(fromRequestLine: String(line), expectedState: expectedState)

        // A browser asks for /favicon.ico beside the redirect. Answering it and carrying on is the
        // difference between a sign-in that works and one that ends on whichever request landed second.
        guard result != .ignored else { return }

        let body: String
        if case .code = result {
            body = "Facet is connected."
        } else {
            body = "Facet is not connected."
        }
        write(connection, Data(GoogleOAuthRules.redirectResponse(body).utf8))
        queue.async { self.deliver(result) }
    }

    /// A whole `Data` down a descriptor, however many writes that takes. A short write is legal and the
    /// page is a couple of hundred bytes, so it will not happen -- and a loop is how it is written when it
    /// does.
    private func write(_ connection: Int32, _ data: Data) {
        var sent = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < raw.count {
                let written = Glibc.write(connection, base.advanced(by: sent), raw.count - sent)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                sent += written
            }
        }
    }

    // MARK: - state, all of it on `queue`

    /// Hands the redirect to whoever is waiting, exactly once, and shuts everything down.
    private func deliver(_ redirect: GoogleOAuthRules.Redirect) {
        guard arrived == nil else { return }
        arrived = redirect
        waiting?.resume(returning: redirect)
        waiting = nil

        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
        // The accept loop closes the descriptor itself, on its way out, so this only says to stop.
        listening = -1
    }

    private func isStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    private static func reasonFromErrno(_ what: String) -> String {
        "\(what): \(String(cString: strerror(errno)))"
    }
}

#endif

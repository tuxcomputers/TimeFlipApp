import Foundation
import Testing
@testable import FacetCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GoogleLoopbackListener`, driven over a real loopback connection.
///
/// **The point of these is that they run on both platforms against two different implementations.** The
/// listener is Network on Darwin and Berkeley sockets where there is no Network, and the only thing that
/// says the second behaves like the first is a test that talks to whichever one it got the same way a
/// browser would. Nothing here knows which it is.
///
/// **A real port and a real request**, not a parsing test: `GoogleOAuthRulesTests` covers the request-line
/// reading. What is checked here is the half that was rewritten -- that a port gets assigned, that a
/// request on it arrives, that the browser is answered, and that a request which is not the redirect
/// leaves the listener waiting.
@Suite(.timeLimit(.minutes(1)))
struct GoogleLoopbackListenerTests {
    /// Fetches a URL and answers the body, or `nil` if the connection failed.
    private func get(_ url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func redirectURL(port: UInt16, query: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/?\(query)")!
    }

    @Test func aPortIsAssignedAndItIsNotAFixedOne() async throws {
        let first = try GoogleLoopbackListener(expectedState: "state-1")
        let second = try GoogleLoopbackListener(expectedState: "state-2")
        let firstPort = try await first.start()
        let secondPort = try await second.start()
        defer {
            first.cancel()
            second.cancel()
        }

        #expect(firstPort > 0)
        #expect(secondPort > 0)
        // Two listeners at once is what says the port came from the system rather than from the code: a
        // fixed port would have refused the second, which is the failure this arrangement exists to avoid.
        #expect(firstPort != secondPort)
    }

    @Test func theCodeArrivesAndTheBrowserIsToldItWorked() async throws {
        let listener = try GoogleLoopbackListener(expectedState: "state-abc")
        let port = try await listener.start()

        async let arriving = listener.redirect()
        let body = await get(redirectURL(port: port, query: "code=the-code&state=state-abc"))
        let redirect = await arriving

        #expect(redirect == .code("the-code"))
        #expect(body?.contains("Facet is connected.") == true, "the page the browser is left looking at")
    }

    @Test func aRefusalArrivesAsDeniedAndSaysSo() async throws {
        let listener = try GoogleLoopbackListener(expectedState: "state-def")
        let port = try await listener.start()

        async let arriving = listener.redirect()
        let body = await get(redirectURL(port: port, query: "error=access_denied&state=state-def"))
        let redirect = await arriving

        #expect(redirect == .denied("access_denied"))
        #expect(body?.contains("Facet is not connected.") == true)
    }

    /// **The favicon case, which is the one that actually broke a sign-in.** A browser asks for
    /// `/favicon.ico` beside the redirect, and a listener that answered the first request it got and
    /// stopped would end on whichever landed first.
    @Test func aRequestThatIsNotTheRedirectLeavesItWaiting() async throws {
        let listener = try GoogleLoopbackListener(expectedState: "state-ghi")
        let port = try await listener.start()

        _ = await get(URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        _ = await get(redirectURL(port: port, query: "state=someone-elses-state&code=nope"))

        async let arriving = listener.redirect()
        _ = await get(redirectURL(port: port, query: "code=the-real-code&state=state-ghi"))
        let redirect = await arriving

        #expect(redirect == .code("the-real-code"), "the two ignored requests must not have settled it")
    }

    @Test func cancellingSettlesWhoeverIsWaiting() async throws {
        let listener = try GoogleLoopbackListener(expectedState: "state-jkl")
        _ = try await listener.start()

        async let arriving = listener.redirect()
        listener.cancel()

        #expect(await arriving == .ignored)
    }
}

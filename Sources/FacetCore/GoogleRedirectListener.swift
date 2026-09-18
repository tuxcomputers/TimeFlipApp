import Foundation

/// Listens on a loopback port for the one redirect Google sends back.
///
/// **The port in the ports model, and the arm is the sign-in.** `GoogleOAuthClient` states what it needs here and
/// something outside hands over the thing that does it: `NetworkLoopbackListener` where there is `Network`, and
/// `SocketLoopbackListener` in `FacetLinux` where there is not. The core must not know which it got, which is
/// `CLAUDE.md` under *The core is platform-blind*, and until 2026-09-18 it did -- one file held both
/// implementations behind a `#if`, which is a port wearing a conditional.
///
/// **Four members, because that is what both halves already had.** They were written against one interface
/// deliberately (`init(expectedState:)`, `start()`, `redirect()`, `cancel(with:)`), both answering the same three
/// `GoogleOAuthRules.Redirect` cases from the same request line through the same
/// `GoogleOAuthRules.redirect(fromRequestLine:expectedState:)`. So this protocol is a description of what was
/// there rather than a new shape either half had to be bent into.
///
/// **`Sendable` because a sign-in is `async` and both halves answer off their own queue.** The Network one is
/// called back on `NWListener`'s queue and the socket one runs its accept loop on a thread of its own; both are
/// `@unchecked Sendable` and say why at the point they claim it.
package protocol GoogleRedirectListener: Sendable {
    /// Starts listening and answers with the port the system assigned.
    ///
    /// **Never a fixed number.** Google accepts any loopback port for an installed app precisely so it need not be
    /// registered, and a hardcoded one is a sign-in that breaks the moment something else is holding it.
    func start() async throws -> UInt16

    /// The redirect, once it arrives.
    func redirect() async -> GoogleOAuthRules.Redirect

    /// Stops listening, answering anything still waiting with `redirect`.
    func cancel(with redirect: GoogleOAuthRules.Redirect)
}

extension GoogleRedirectListener {
    /// Stops listening with nothing to report, which is what a timeout and an abandoned sign-in both are.
    ///
    /// **The default lives here rather than on the requirement**, because a default argument on a protocol member
    /// is not inherited through an existential -- and both adapters are reached through one. Each concrete type
    /// still carries its own `= .ignored`, which is what its own tests call; this is what a caller holding the
    /// port gets.
    package func cancel() {
        cancel(with: .ignored)
    }
}

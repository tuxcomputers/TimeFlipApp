import Foundation

/// What somebody picked when told the cube could not be found.
enum ManualModeAnswer: Equatable {
    /// Look again: one more attempt, and the offer again if that finds nothing too. There is no limit on how many
    /// times this can be chosen.
    case retry
    /// Time by hand instead. The app makes no further attempt **of its own** for the rest of the launch.
    case switchToManualMode
}

/// Whether a failed attempt on the paired cube should be put to the user, or retried quietly.
///
/// **Massaged from the archive's `ManualModeOffer`**, whose rule is kept whole because both halves of it were paid
/// for:
///
/// - **The first failure asks.** One attempt, and if the cube did not answer it, say so. The archive had a threshold
///   here once -- a `manual_mode` setting counting failures before the dialog -- and it bought nothing: each round is
///   the same scan over the same airspace, so three of them find the same nothing three times while somebody watches
///   an app that appears to be doing something. Retry is one click and is the same wait, made deliberately.
/// - **Startup only.** This applies while a launch has never reached the cube. Once one connection has succeeded the
///   question is settled for the session, and a drop after that reconnects on the capped backoff for ever with no
///   offer -- losing a cube mid-session is a different situation from never having had it, and somebody who walked
///   away from a working app should not come back to a dialog.
///
/// What it deliberately does not model is whether the offer is on screen or whether manual mode was chosen. Both are
/// about whether an attempt may run at all, which is `DeviceReconnectRules.shouldAttempt`'s question.
struct ManualModeOffer {
    enum Decision: Equatable {
        /// Go round again on the usual backoff.
        case keepTrying
        /// Stop, and ask whether to retry or time by hand.
        case ask
    }

    /// Whether this launch has ever reached the cube. One-way: nothing sets it back, which is what makes the offer a
    /// startup-only thing.
    private(set) var hasReachedTheCube = false

    /// A login succeeded. Settles the question for the rest of the launch.
    mutating func recordConnected() {
        hasReachedTheCube = true
    }

    /// An attempt failed. Says whether to go round again or ask.
    mutating func recordFailedAttempt() -> Decision {
        hasReachedTheCube ? .keepTrying : .ask
    }

    /// Why the app gave up, in the words the offer's log line needs.
    ///
    /// **Derived from the outcome rather than passed in at the call site**, which is the archive's rule and the reason
    /// it exists: "nothing was in range" and "it was right there and refused this app's PIN" are different problems
    /// with different fixes, and a `reason` string handed in got it wrong twice -- once so badly that the log
    /// confidently blamed a cube sitting on the desk, 3ms after the accurate line (measured on hardware 2026-08-09,
    /// see the archive's `ManualModeOfferReason`).
    ///
    /// **Simpler than the archive's, and only because this app reconnects by identifier.** That version counted how
    /// many eligible devices a scan found and how many refused the PIN, because it scanned for candidates by name and
    /// tried each in turn to work out which cube was its own. `device_uuid` names the cube here, so a reach gets that
    /// one or nothing, and the outcome it reports already is the answer.
    static func reason(for outcome: DeviceLoginOutcome) -> String {
        switch outcome {
        case .unreachable: return "nothing answered"
        case .wrongPIN: return "the cube was found and refused this app's PIN"
        case .newPINRefused: return "the cube was found and would not take a new PIN"
        case .notATimeFlip: return "what answered is not a TimeFlip"
        case .timedOut: return "the cube answered and then stopped part way through"
        // Not reachable from the one caller, which asks only about failures. Answered rather than trapped, because a
        // fatal error in a log line would be a crash on the path that exists to keep a broken connection usable.
        case .loggedIn: return "the cube answered"
        }
    }
}

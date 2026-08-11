import Foundation

/// What the user picked when told the device isn't in range.
enum ManualModeAnswer: Equatable {
    /// Try again: one more scan, and the offer again if it finds nothing. There is no limit on how
    /// many times this can be chosen.
    case retry
    /// Switch to manual mode. The app makes no further connection attempt *of its own* -- see
    /// `AppState.enterManualMode` -- so the mode ends only by an act of the user's: pairing a device
    /// from the Device tab, or quitting and starting again.
    case switchToManualMode
}

/// Whether a failed attempt on the paired device should offer manual mode, or be retried quietly.
///
/// Kept out of `ApplicationDelegate` for the same reason as `LowBatteryLatch`: the rule is small and
/// its edges are easy to get subtly wrong, and here it can be driven through every one of them in a
/// unit test without a device, a run loop, or a dialog to dismiss.
///
/// The rule (see `docs/TODO-features-under-development.md`, Manual mode):
///
/// - **The first failure asks.** One scan, and if this app's device is not among what answered, say
///   so. There used to be a threshold here -- a `manual_mode` setting counting failures before the
///   dialog -- and it bought nothing: each round is the same scan over the same airspace, so three
///   of them find the same nothing three times while somebody watches an app that appears to be
///   doing something. Retry is one click and is the same wait, made deliberately.
/// - **Startup only.** This applies while a launch has never reached the device. Once one connect
///   has succeeded the question is settled for the session, and a drop after that reconnects on the
///   capped backoff indefinitely with no offer, because losing the cube mid-session is a different
///   situation from never having had it.
///
/// What it deliberately does *not* model: whether the offer is currently on screen, and whether
/// manual mode was chosen. Both gate whether the app may attempt a connection at all, which is
/// `AppState`'s question rather than this one's -- see `AppState.shouldAttemptConnection`.
struct ManualModeOffer {
    enum Decision: Equatable {
        /// Schedule another attempt on the usual backoff.
        case keepTrying
        /// Stop, and ask whether to retry or switch to manual mode.
        case offerManualMode
    }

    /// Whether this launch has ever reached the device. One-way: nothing sets it back to false,
    /// which is what makes the offer a startup-only thing.
    private(set) var hasConnectedThisLaunch = false

    /// A connect succeeded. Settles the question for the rest of the session.
    mutating func recordConnected() {
        hasConnectedThisLaunch = true
    }

    /// An attempt to reach the device failed. Returns whether to go round again or ask the user.
    mutating func recordFailedAttempt() -> Decision {
        hasConnectedThisLaunch ? .keepTrying : .offerManualMode
    }
}

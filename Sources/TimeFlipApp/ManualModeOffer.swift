import Foundation

/// What the user picked when told the device isn't in range.
enum ManualModeAnswer: Equatable {
    /// Try again: a fresh round of `prompt_after_attempts` attempts, and the offer again if they
    /// all fail. There is no limit on how many times this can be chosen.
    case retry
    /// Switch to manual mode. Final for this launch -- the app makes no further connection attempt
    /// of any kind, and quitting and restarting is the only way back to the device.
    case switchToManualMode
}

/// When to stop retrying a paired device that isn't answering, and offer manual mode instead.
///
/// Kept out of `ApplicationDelegate` for the same reason as `LowBatteryLatch`: the rule is a small
/// state machine with edges that are easy to get subtly wrong, and here it can be driven through
/// every one of them in a unit test without a device, a run loop, or a dialog to dismiss.
///
/// The rule (see `docs/TODO-features-under-development.md`, Manual mode):
///
/// - **Startup only.** The count runs while a launch has never reached the device. Once one connect
///   has succeeded the question is settled for the session, and a drop after that reconnects on the
///   capped backoff indefinitely with no offer, because losing the cube mid-session is a different
///   situation from not having it.
/// - **Retry resets the count**, so each round of the dialog buys the same number of attempts as the
///   first. The loop has no limit: it repeats until the device answers or the user picks manual mode.
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

    /// How many failed attempts in a row before the offer, from the `manual_mode` setting's
    /// `prompt_after_attempts`. Floored at 1 defensively: the loader clamps it too, but a 0 here
    /// would offer manual mode before a single attempt had been made, and this type is the one that
    /// would have to behave sensibly if it ever arrived.
    private let promptAfterAttempts: Int

    /// Failures since the launch began, or since the last Retry. Reset by both `recordConnected()`
    /// and `retryChosen()`.
    private(set) var failedAttempts = 0

    /// Whether this launch has ever reached the device. One-way: nothing sets it back to false,
    /// which is what makes the offer a startup-only thing.
    private(set) var hasConnectedThisLaunch = false

    init(promptAfterAttempts: Int) {
        self.promptAfterAttempts = max(1, promptAfterAttempts)
    }

    /// A connect succeeded. Settles the question for the rest of the session.
    mutating func recordConnected() {
        hasConnectedThisLaunch = true
        failedAttempts = 0
    }

    /// An attempt to reach the device failed. Returns whether to go round again or ask the user.
    mutating func recordFailedAttempt() -> Decision {
        guard !hasConnectedThisLaunch else { return .keepTrying }
        failedAttempts += 1
        return failedAttempts >= promptAfterAttempts ? .offerManualMode : .keepTrying
    }

    /// The user answered the offer with Retry. Buys another full round of attempts.
    mutating func retryChosen() {
        failedAttempts = 0
    }
}

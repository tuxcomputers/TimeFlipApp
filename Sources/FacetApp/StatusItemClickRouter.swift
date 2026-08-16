import Foundation

/// What a click on the status item should do.
enum StatusItemClick: Equatable {
    /// The dropdown. Always reachable, in every state, because it is the only route to Quit.
    case showMenu
    /// Stop the clock, or start it again -- the same toggle the dropdown's Pause item and the Timing column's
    /// control end in, not a third implementation of pausing.
    case togglePause
    /// Nothing: there is no clock to stop. Deliberately inert rather than falling through to the menu, so the
    /// halves never merge into one target and quietly stay merged.
    case ignore
}

/// Which of those a given click is, decided with none of the AppKit it is decided inside.
///
/// A separate type for two rules, which the archived implementation earns: the same decisions lived as nested
/// `guard`s inside an `@objc` handler, and its own comment records the cost -- reaching them "needed a real status
/// item, a real click and a real window server, so in practice they were only ever verified by hand".
///
/// The rule is the archive's manual-mode line (`Archive/TimeFlipApp/MenuBarClickRouter`), which this app is
/// permanently in: left is the menu, right is the pause. What is dropped is what it needed a cube for. There is no
/// double-click that locks the device, so there is nothing a first click might turn out to have been half of, and
/// the pause goes out at once rather than being held back for the system double-click interval. There is no
/// connection to be down and no low battery to be blinking, so neither can redirect a half.
enum StatusItemClickRouter {
    /// - Parameters:
    ///   - isLeftSide: which half of the item was clicked. The caller works this out from the event, since only it
    ///     knows how wide the item currently is -- the width tracks the title, so it changes as the display does.
    ///   - timing: what the clock is doing, which is what decides whether the right half has anything to act on.
    ///     Asked through `ManualTimerRules.isClickable` rather than compared here, because the dropdown's Pause
    ///     item and the on-screen control ask the same question and must get the same answer: the previous app had
    ///     the right half taught about manual mode and the menu item beside it not, leaving a dead Pause above a
    ///     live one.
    ///   - isLimitReached: whether the category on show has spent its `daily_limit`. It makes the right half a
    ///     no-op rather than a refusal further in, so the click is recorded as ignored and nothing downstream has
    ///     to know why.
    static func action(isLeftSide: Bool, timing: TimingState, isLimitReached: Bool = false) -> StatusItemClick {
        guard !isLeftSide else { return .showMenu }
        return ManualTimerRules.isClickable(timing, isLimitReached: isLimitReached) ? .togglePause : .ignore
    }
}

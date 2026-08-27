import Foundation

/// What a click on the status item should do.
enum StatusItemClick: Equatable {
    /// The dropdown. Always reachable, in every timingState, because it is the only route to Quit.
    case showMenu
    /// Stop the **app's own** clock, or start it again -- the same toggle the dropdown's Pause item and the Timing
    /// column's control end in, not a third implementation of pausing. Sent at once: manual mode has no lock, so
    /// there is no second gesture this could turn out to have been half of.
    case togglePause
    /// Stop the **cube** counting, or start it again (`0x06`). **Deliberately held back by the system's double-click
    /// interval**, so a fast second click can cancel it and become the lock below instead of doing both.
    case toggleCubePause
    /// Lock the cube, or unlock it (`0x04`) -- the double click, and the same path the dropdown's Lock item takes.
    case toggleCubeLock
    /// Nothing: there is no clock to stop and no cube to stop it on. Deliberately inert rather than falling through
    /// to the menu, so the halves never merge into one target and quietly stay merged.
    case ignore
}

/// Which of those a given click is, decided with none of the AppKit it is decided inside.
///
/// A separate type for these rules, which the archived implementation earns: the same decisions lived as nested
/// `guard`s inside an `@objc` handler, and its own comment records the cost -- reaching them "needed a real status
/// item, a real click and a real window server, so in practice they were only ever verified by hand".
///
/// **The rule is the archive's, massaged** (`Archive/TimeFlipApp/MenuBarClickRouter`). Left is the menu, right acts
/// on whatever is being timed: with a cube that is the cube, single to pause and double to lock; with the app's own
/// clock running it is that clock, at once. What is dropped is what the archive needed extra timingState for -- there is no
/// low-battery blink redirecting the left half to Settings here, and no separate `isCubePaired` to disagree with the
/// connection.
enum StatusItemClickRouter {
    /// - Parameters:
    ///   - isLeftSide: which half of the item was clicked. The caller works this out from the event, since only it
    ///     knows how wide the item currently is -- the width tracks the title, so it changes as the display does.
    ///   - timing: what the app's own clock is doing, which is what decides whether the right half has a session of
    ///     its own to act on. Asked through `ManualTimerRules.isClickable` rather than compared here, because the
    ///     dropdown's Pause item and the on-screen control ask the same question and must get the same answer: the
    ///     previous app had the right half taught about manual mode and the menu item beside it not, leaving a dead
    ///     Pause above a live one.
    ///   - isCubeConnected: whether there is a live link to send a command down. **The connection, not the pairing**
    ///     -- `CubeLockRules.isEnabled` draws the line in the same place and for the same reason: a paired cube in
    ///     another room can be neither paused nor locked.
    ///   - isLimitReached: whether the category on show has spent its `daily_limit`. It makes the right half a no-op
    ///     rather than a refusal further in, so the click is recorded as ignored and nothing downstream has to know
    ///     why.
    ///
    ///     **It used to be about the app's own clock only, and said so**: the limit was not enforced against a cube
    ///     at all, `DailyLimitWatch` ticking only while the app was the clock, so refusing the cube's resume here
    ///     would have been half a rule and would have stranded a cube nothing had paused. That reasoning was right
    ///     and is no longer true -- the watch now enforces against a cube -- so what was a considered exemption
    ///     became the way round the limit: reported live on 2026-08-27, a single click on the right half starting a
    ///     cube whose budget was spent, with the watch stopping it again two seconds later.
    ///   - isCubePaused: whether the cube is stopped, which decides *which way* the click goes and so whether the
    ///     limit has anything to say about it. Only a click that would start the cube is refused; stopping one stays
    ///     available throughout, for `ManualTimerRules`' reason -- a limit that trapped somebody into recording time
    ///     would be the opposite of what it is for.
    ///   - clickCount: the event's own, so the second click of a pair is what asks for the lock.
    static func action(
        isLeftSide: Bool,
        timingState: TimingState,
        isCubeConnected: Bool = false,
        cubePauseState: CubePauseState = .unknown,
        isLimitReached: Bool = false,
        clickCount: Int = 1
    ) -> StatusItemClick {
        guard !isLeftSide else { return .showMenu }
        // **The app's own clock is asked about first, in the order `TimingReadout` itself reads them.** A running
        // manual session is never taken over by a cube that happens to be connected -- and it is the same precedence,
        // so the half cannot come to act on one while the item beside it draws the other.
        if ManualTimerRules.isClickable(timingState, isLimitReached: isLimitReached) { return .togglePause }
        // A session that exists but has been refused stays refused, rather than falling through to the cube: a spent
        // daily limit would otherwise be undone by clicking the same place a second time.
        guard timingState == .idle, isCubeConnected else { return .ignore }
        // `>= 2` rather than `== 2`, so a third click cannot land back on the pause.
        let action: StatusItemClick = clickCount >= 2 ? .toggleCubeLock : .toggleCubePause
        // **The lock is not refused, only the resume.** A double click locks or unlocks, and unlocking is the one way
        // out of a timingState this app cannot otherwise reach -- `CubeLock.resume` unlocks and leaves the cube stopped when
        // the budget is spent, so the gesture stays available and simply does not start anything.
        guard !(action == .toggleCubePause && isLimitReached && cubePauseState == .paused) else { return .ignore }
        return action
    }
}

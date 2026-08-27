import Foundation

/// What the dropdown's Pause item acts on, what it is called, and whether it can be chosen.
///
/// **It exists because the item was only ever taught about half of what it sits above.** `menuTogglePause` called the
/// app's own clock and `ManualTimerRules.isClickable` answered `false` for `.idle`, so with a cube connected and no
/// manual session the item was greyed out -- while a single click on the status item's right half, two lines away in
/// `StatusItemClickRouter`, pauses that same cube perfectly well. One surface knew about the cube and the other did
/// not, which is the exact fault `CubeLockRules`' own comment records the archive dying of: "one was taught and the
/// other was not, and nothing failed".
///
/// So the precedence here is `StatusItemClickRouter`'s, deliberately and in the same order: the app's own clock first,
/// the cube only when there is no manual session to act on. A running manual session is never taken over by a cube
/// that happens to be connected.
enum PauseMenuRules {
    /// What choosing the item would actually do.
    ///
    /// Named rather than inferred from the title, so the handler does not have to work backwards from the word it is
    /// about to draw -- which is how a control comes to say one thing and do another.
    enum Target: Equatable {
        /// The app's own clock, which is what the item has always done.
        case appClock
        /// The cube, which is what the right half of the status item has always done and this never did.
        case cube
        /// Nothing can be acted on, so the item is dead.
        case nothing
    }

    /// - Parameters:
    ///   - timing: what the app's own clock is doing. Asked through `ManualTimerRules.isClickable` rather than
    ///     compared here, so this and the status item cannot come to different answers about manual mode.
    ///   - isCubeConnected: **the connection, not the pairing.** It ends in a command and a command needs a live
    ///     link, which is where `CubeLockRules.isEnabled` draws the same line.
    ///   - isCubeLocked: `nil` when nobody has asked. **A locked cube is not pausable at all**: lock freezes it on the
    ///     face it is on and it ignores everything but an unlock, so an item offering to pause one is an item that
    ///     will be refused. `CubeLock.togglePause` refuses it in as many words -- "The cube is locked, so pausing it
    ///     means nothing; unlock it first" -- and a menu is the one surface that can say so before it is pressed
    ///     rather than after.
    ///   - isLimitReached: whether the category on show has spent its `daily_limit`, which is what makes the limit
    ///     hard rather than advisory. About the app's own clock only, as it is everywhere else.
    static func target(
        timingState: TimingState,
        isCubeConnected: Bool,
        cubeLockState: CubeLockState,
        isCubePaused: Bool? = nil,
        isLimitReached: Bool = false
    ) -> Target {
        if ManualTimerRules.isClickable(timingState, isLimitReached: isLimitReached) { return .appClock }
        // A session that exists but has been refused stays refused rather than falling through to the cube, which is
        // `StatusItemClickRouter`'s rule and for its reason: a spent daily limit would otherwise be undone by
        // reaching for the menu instead of the status item.
        guard timingState == .idle, isCubeConnected else { return .nothing }
        // **And the limit has to be asked again for the cube, which it was not.** `ManualTimerRules.isClickable`
        // above answers about *this app's* clock, and a cube leaves that `.idle` however busy it is -- so every cube
        // click fell straight past the only place the limit was consulted. Reported live on 2026-08-27: a single
        // click on the right half started a cube whose category had spent its budget, and `DailyLimitWatch` stopped
        // it again two seconds later.
        //
        // **Only a click that would *start* it is refused**, which is the same asymmetry `ManualTimerRules` has:
        // stopping stays available throughout, because a limit that trapped somebody into recording time would be the
        // opposite of what it is for. A click at a running cube is a pause and is always allowed.
        guard !(isLimitReached && isCubePaused == true) else { return .nothing }
        // **Unknown is treated as unlocked**, which is the same way round as `CubeLockRules.title`. A cube nobody has
        // asked is far more often running than locked, and of the two ways to be wrong an item that is enabled and
        // gets refused says why in the log, while one greyed out for a lock that is not there offers no way to find
        // out it was wrong.
        return cubeLockState == .locked ? .nothing : .cube
    }

    /// What the item is called.
    ///
    /// **A menu item says what clicking does**, which `ManualTimerRules.pauseMenuTitle` already sets out: it reads
    /// "Pause" while time is being recorded, the opposite of the glyph beside it.
    ///
    /// - Parameter isCubePaused: only consulted for `.cube`, and that matters: **a locked cube reports itself paused
    ///   whatever its pause byte says**, so this answer is only meaningful where the cube is not locked -- which is
    ///   exactly and only where `target` returns `.cube`.
    static func title(
        for target: Target,
        timingState: TimingState,
        isCubePaused: Bool? = nil
    ) -> String {
        switch target {
        case .appClock, .nothing:
            // A dead item reads "Pause" rather than "Resume", carried over from the previous app with its reasoning:
            // a dead item claiming there is something to resume is worse than one claiming there is something to
            // pause. That covers the locked cube too, where the cube would answer "paused" and "Resume" would be an
            // offer the cube is going to refuse.
            return ManualTimerRules.pauseMenuTitle(for: timingState)
        case .cube:
            return isCubePaused == true ? "Resume" : "Pause"
        }
    }

    /// Whether it can be chosen. Exactly "there is something for it to act on".
    static func isEnabled(_ target: Target) -> Bool {
        target != .nothing
    }
}

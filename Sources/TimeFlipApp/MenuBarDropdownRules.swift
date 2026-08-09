import Foundation

/// Which of the dropdown's two device actions can be chosen, and what Pause is called.
///
/// The same seam as `MenuBarClickRouter`, for the other way into the same gestures: these were
/// three expressions inside `rebuildMenu()`, which builds real `NSMenuItem`s and so is out of reach
/// of any test. That is how the dropdown came to disagree with the status item about manual mode --
/// the right half was taught to pause and the menu item beside it was not, and nothing failed.
enum MenuBarDropdownRules {

    /// Whether **Pause/Resume** can be chosen.
    ///
    /// Manual mode is included, and it is the whole point of this type: there is a timer to stop,
    /// it is one this app runs itself, and the menu item goes to the same place the status item's
    /// right half does. Excluding it left a dead Pause sitting above a live one.
    ///
    /// With a cube it needs a live connection rather than a remembered pairing, since it ends in a
    /// command, and it is refused while locked: the only valid action then is the unlock gesture, so
    /// pause must not be reachable from the menu either. Manual mode has nothing to lock, and the
    /// lock state it would read is left over from a device this launch never reached.
    static func allowsPause(connectionStatus: ConnectionStatus, isPaired: Bool, isLocked: Bool) -> Bool {
        if connectionStatus == .manual { return true }
        return isPaired && connectionStatus == .connected && !isLocked
    }

    /// Whether **Lock/Unlock** can be chosen.
    ///
    /// Manual mode is deliberately **not** included, unlike Pause. Pause survives because the thing
    /// it acts on moved into the app; lock has no such half. It is a device command with a device
    /// state behind it, and in manual mode there is no device, so the item would send nothing and
    /// report a state belonging to a cube this launch never reached.
    static func allowsLock(connectionStatus: ConnectionStatus, isPaired: Bool) -> Bool {
        isPaired && connectionStatus == .connected
    }

    /// What the pause item is called: "Resume" only when there is a stopped timer to resume.
    ///
    /// Anything with no timing source at all reads "Pause" whatever `isPaused` happens to hold,
    /// because a dead item claiming there is something to resume is worse than a dead item claiming
    /// there is something to pause. A connected-but-locked cube keeps naming its real state, which
    /// is what it did before manual mode existed: the item is dead there for the lock's sake, not
    /// for want of anything to say.
    static func pauseTitle(connectionStatus: ConnectionStatus, isPaired: Bool, isPaused: Bool) -> String {
        let hasTimer = connectionStatus == .manual || (isPaired && connectionStatus == .connected)
        guard hasTimer else { return "Pause" }
        return isPaused ? "Resume" : "Pause"
    }
}

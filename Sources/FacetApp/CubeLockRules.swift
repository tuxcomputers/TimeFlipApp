import Foundation

/// Whether the cube is frozen on the face it is resting on.
///
/// **Three answers, not two, and `unknown` is a real one.** It is the cube nobody has asked yet, and it was a `Bool?`
/// read as `== true` until the state sweep: a comparison that looks like a slip and is in fact the whole decision that
/// unknown counts as unlocked. Written out, a reader can see which way each caller goes, and they do not all go the
/// same way -- `ForcedPause` deliberately requires a known `.unlocked` before it will send anything, while the menu
/// and the click router treat unknown as unlocked so that a cube nobody has asked is still operable.
///
/// The truth is `0x10`, and nothing else answers it: no history frame carries a lock bit and `device_event` has no
/// column for one.
enum CubeLockState: Equatable {
    /// Nobody has asked, or the cube would not answer.
    case unknown
    case locked
    case unlocked

    /// From the cube's own `0x10` answer, which is absent until it has been read.
    init(reported: Bool?) {
        switch reported {
        case .some(true): self = .locked
        case .some(false): self = .unlocked
        case nil: self = .unknown
        }
    }
}

/// What the dropdown's Lock item is called, and whether it can be chosen.
///
/// **A rules type rather than three expressions inside `makeMenu`**, which is the seam `MenuBarDropdownRules` was in
/// the archive and for the reason recorded there: menu building makes real `NSMenuItem`s and is out of reach of a
/// test, and that is exactly how the dropdown came to disagree with the status item about manual mode -- one was
/// taught and the other was not, and nothing failed.
enum CubeLockRules {
    /// What the item is called.
    ///
    /// **"Unlock" rather than "Resume", which is the archive's pair and is the one that reads correctly here.**
    /// "Resume" put the word twice in one short menu -- the Pause item above already becomes "Resume" when the app's
    /// own clock is stopped -- and two items reading the same thing while doing entirely different things is a menu
    /// nobody can use. They are different things: that one starts the app's clock, this one starts the cube.
    ///
    /// **Unlocking still lifts the pause that locking applied**, even though the word does not say so, and that is a
    /// departure from the archive worth being explicit about. There, unlocking deliberately did not resume, because
    /// its Pause item commanded the device and could resume it separately. This app's Pause item is the app's own
    /// clock and sends the cube nothing, so an unlock that left the cube paused would leave it paused for good.
    ///
    /// **Unknown reads as "Lock".** That covers a cube nobody has asked yet and one that would not answer, and it is
    /// the safer of the two to be wrong about: an item that offers to lock an already-locked cube sends a command
    /// that changes nothing, while one offering to unlock a running cube would unpause what was never paused.
    static func title(cubeLockState: CubeLockState) -> String {
        cubeLockState == .locked ? "Unlock" : "Lock"
    }

    /// Whether it can be chosen: only with a cube on the other end.
    ///
    /// **The connection, not the pairing** -- the archive's `allowsLock`, kept. It ends in a command, and a command
    /// needs a live link: a paired cube in another room can be neither locked nor resumed, so an item offering it
    /// would be a control that does nothing and says nothing about why.
    ///
    /// **Manual mode is not a case here, unlike Pause.** Pause survives into manual mode because the thing it acts on
    /// moved into the app; lock has no such half. It is a device command with a device state behind it, and with no
    /// device there is nothing to send and nothing to report.
    static func isEnabled(isCubeConnected: Bool) -> Bool {
        isCubeConnected
    }
}

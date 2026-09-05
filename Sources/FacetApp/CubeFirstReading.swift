import Foundation

/// Whether this launch has yet had one complete reading of its paired cube, which is what decides whether the status
/// item is still saying `Connecting…`.
///
/// **A connection is not a reading, and that is the whole reason this is three facts rather than one.**
/// `DeviceLogin` reports `.loggedIn` the moment the PIN is accepted, which is several round trips before it has asked
/// the cube anything about itself: the `0x17` and `0x10` reads come after, and the `0x10` answer is where the lock and
/// the pause come from. So a title that stopped at the connection would drop `Connecting…` while the app still could
/// not say what face was up or whether the cube was running, and would then have to correct itself a moment later.
/// The three facts are the ones the item actually draws, so they are the ones it waits for.
///
/// **One-way, and that is what makes it a startup thing.** `CubeNotFoundOffer.hasReachedCube` is the same shape for
/// the same reason, and its note is this one: losing a cube mid-session is a different situation from never having had
/// it. A drop clears the face, the lock and the pause at the radio (`BluetoothRadio`), so without the latch every drop
/// would put `Connecting…` back over a line that is meant to keep the category and turn yellow -- which is the
/// established behaviour and is what somebody who walked away from a working app comes back to.
struct CubeFirstReading {
    /// Whether a complete reading has happened this launch. Nothing sets it back.
    private(set) var hasReadTheCube = false

    /// Offered the cube as it stands, once per draw. Latches on the first reading that has everything.
    ///
    /// **All four or nothing.** A face with no lock behind it is half an answer, and half an answer drawn is the item
    /// correcting itself in front of somebody.
    mutating func record(
        isCubeConnected: Bool,
        cubeFace: Int?,
        cubePauseState: CubePauseState,
        cubeLockState: CubeLockState
    ) {
        guard isCubeConnected,
              cubeFace != nil,
              cubePauseState != .unknown,
              cubeLockState != .unknown
        else {
            return
        }
        hasReadTheCube = true
    }

    /// Whether the item should say `Connecting…` rather than draw a reading.
    ///
    /// **`isManualMode` carries the pairing**, so there is no third input: it is
    /// `!isCubePaired || hasGivenUpOnCube` (`ManualTimerRules`), and its negation is therefore "paired, and still
    /// looking". That is exactly the population this title is for, and it settles the two ends of the offer in one
    /// go -- `Rescan` leaves the launch still looking and so keeps the title, while `Time by Hand` sets
    /// `hasGivenUpOnCube` and so ends it on the same fact the Faces tab and the menu bar already read.
    func isConnecting(isManualMode: Bool) -> Bool {
        !isManualMode && !hasReadTheCube
    }
}

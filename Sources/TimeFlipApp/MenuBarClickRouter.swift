import Foundation

/// What a click on the status item should do.
enum StatusItemClick: Equatable {
    /// The dropdown. Always reachable from somewhere, in every state, because it is the only route
    /// to Quit.
    case showMenu
    case openSettings
    /// The double-click gesture, which locks the device.
    case lockDevice
    /// The single-click gesture. Deliberately deferred by the system double-click interval, so a
    /// fast second click can cancel it and upgrade to `lockDevice` instead of doing both.
    case togglePause
    /// The same toggle, without the wait. Manual mode has no lock, so there is no second gesture
    /// for a click to turn out to have been part of, and nothing to be gained by holding it back.
    case togglePauseImmediately
}

/// Which of those a given click is, with none of the AppKit it is decided inside -- the same seam
/// `MenuBarStatusStyle` is for what the item looks like.
///
/// The status item is split down the middle and the halves mean different things in different
/// states, which is three rules that used to live as nested `guard`s inside an `@objc` handler no
/// test could call. Reaching them needed a real status item, a real click and a real window server,
/// so in practice they were only ever verified by hand.
///
enum MenuBarClickRouter {

    /// - Parameters:
    ///   - isConnected: paired **and** reporting `.connected`. The pause/lock half only means
    ///     anything when there is a device listening to act on it.
    ///   - isManualMode: the app is driving time itself. There is a timer to stop, so the right half
    ///     keeps its meaning -- pause -- even though the device the ordinary pause talks to is not
    ///     there. Lock does not survive the same way, having nothing to lock, so a double-click is
    ///     just two toggles. The left half stays on the menu, which is where Quit lives, and that
    ///     matters more here than anywhere else since quitting is the only way *out* of the mode.
    ///   - isLowBatteryBlinking: the activity text is flashing a low battery. A left-click then
    ///     goes to Settings rather than the menu, on the reading that someone clicking a warning
    ///     wants the thing the warning is about.
    static func action(
        isConnected: Bool,
        isManualMode: Bool,
        isLowBatteryBlinking: Bool,
        isLeftSide: Bool,
        clickCount: Int
    ) -> StatusItemClick {
        if isManualMode {
            return isLeftSide ? .showMenu : .togglePauseImmediately
        }
        guard isConnected else { return .showMenu }
        guard !isLeftSide else {
            return isLowBatteryBlinking ? .openSettings : .showMenu
        }
        return clickCount >= 2 ? .lockDevice : .togglePause
    }
}

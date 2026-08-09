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
}

/// Which of those a given click is, with none of the AppKit it is decided inside -- the same seam
/// `MenuBarStatusStyle` is for what the item looks like.
///
/// The status item is split down the middle and the halves mean different things in different
/// states, which is four rules that used to live as nested `guard`s inside an `@objc` handler no
/// test could call. Reaching them needed a real status item, a real click and a real window server,
/// so in practice they were only ever verified by hand.
enum MenuBarClickRouter {

    /// - Parameters:
    ///   - isConnected: paired **and** reporting `.connected`. The pause/lock half only means
    ///     anything when there is a device listening to act on it.
    ///   - isManualMode: the app is driving time itself. Both halves open the menu: there is no
    ///     device for pause and lock to act on, and the menu carries Quit, which matters more here
    ///     than anywhere else -- quitting is the only way *out* of manual mode, and the work is done
    ///     in the Settings window, which has no Quit of its own. Sending a half of the status item
    ///     to Settings instead would put the one exit behind knowing which half to click.
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
        // Ahead of the low-battery route below, not folded into the `isConnected` guard: a blink
        // left over from before the device went away would otherwise send the left half to Settings
        // and take the menu, and Quit with it, out of reach again.
        if isManualMode { return .showMenu }
        guard isConnected else { return .showMenu }
        guard !isLeftSide else {
            return isLowBatteryBlinking ? .openSettings : .showMenu
        }
        return clickCount >= 2 ? .lockDevice : .togglePause
    }
}

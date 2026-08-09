import Foundation

/// Which tab the Settings window should land on when it is opened.
///
/// The window is built once and only ordered out when closed, so `SettingsRootView`'s
/// `selectedTab` survives a close and the default is to reopen wherever the user left off. That is
/// the right default: it is their window, and moving it under them is worse than useless most of
/// the time. These are the cases where the app knows better than the last click did.
enum SettingsTabRules {

    /// - Parameters:
    ///   - isManualMode: the app is driving time itself. Faces is where a manual session is
    ///     steered from, and it is the reason the window is being opened at all, so it is worth
    ///     overriding the remembered tab on **every** open rather than only the first. Somebody who
    ///     glanced at Report and closed it should not have to click back to Faces to start timing
    ///     again.
    ///   - isLowBatteryBlinking: the activity text is flashing a low battery, so the window jumps
    ///     to Device, where the battery line lives.
    /// - Returns: the tab to force, or `nil` to leave whatever was last selected.
    static func tabOnOpen(isManualMode: Bool, isLowBatteryBlinking: Bool) -> SettingsTab? {
        // Manual mode outranks the blink, matching `MenuBarClickRouter`. A blink can only be left
        // over from before the device went away, since manual mode never reads a battery, and a
        // stale warning about a device the user has already given up on should not divert them from
        // the tab they came here for.
        if isManualMode { return .faces }
        if isLowBatteryBlinking { return .timeflip }
        return nil
    }
}

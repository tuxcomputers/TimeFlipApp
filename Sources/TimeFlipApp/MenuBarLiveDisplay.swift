import Foundation

/// What the menu bar's relationship to a timing source is, moment to moment.
///
/// Three separate questions that all used to be answered inline from `isPaired` and
/// `connectionStatus`, which worked while a cube was the only thing that could be timing. Manual
/// mode breaks that: it reports `.disconnected` -- truthfully, there is no cube -- while a session
/// is running and has a category and a duration to show. Read literally, every one of these
/// answered "nothing is happening" for a session that very much was.
enum MenuBarLiveDisplay {

    /// Whether there is anything to draw at all, as against the plain app-name placeholder.
    ///
    /// The placeholder is for "no reading has ever arrived this session": no pairing, or a pairing
    /// the app has not reached yet. It deliberately is **not** shown for a device that dropped after
    /// being reached, which keeps rendering its last known activity. A manual session always has a
    /// reading, its source being one this app is driving itself.
    static func showsActivity(isPaired: Bool, hasReachedDeviceThisSession: Bool, isManualMode: Bool) -> Bool {
        if isManualMode { return true }
        return isPaired && hasReachedDeviceThisSession
    }

    /// Whether what is drawn is a **current** reading, which is what earns the live colours -- green,
    /// or the over-limit red and low-battery blink. `false` gives the flat yellow of a reading that
    /// is the last one seen rather than the one happening now.
    ///
    /// Manual mode is as current as it gets: the app is the thing generating the reading, so there
    /// is no window in which what is shown could be out of date.
    static func rendersAsLive(isPaired: Bool, isConnected: Bool, isManualMode: Bool) -> Bool {
        if isManualMode { return true }
        return isPaired && isConnected
    }

    /// Whether a `.disconnected` status means tear the display down.
    ///
    /// Normally yes: the device is gone and there is nothing to show. In manual mode `.disconnected`
    /// is not a connection that was lost, it is the deliberate absence of one, held for the rest of
    /// the launch while a session runs -- so tearing down on it would clear the very session the
    /// status is describing.
    static func tearsDownOnDisconnect(isManualMode: Bool) -> Bool {
        !isManualMode
    }
}

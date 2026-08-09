import Foundation

/// What the menu bar's relationship to a timing source is, moment to moment.
///
/// Two questions that used to be answered inline from `isPaired` and `connectionStatus`, which
/// worked while a cube was the only thing that could be timing. Manual mode broke that: read
/// literally, both answered "nothing is happening" for a session that very much was.
///
/// There was a third, `tearsDownOnDisconnect`, asking whether a `.disconnected` meant clear the
/// display. It existed only because manual mode reported `.disconnected` while running, and went
/// when `ConnectionStatus.manual` arrived: a status that is no longer a lie needs no exception
/// taken to it, and the teardown is now an ordinary arm of an ordinary switch.
enum MenuBarLiveDisplay {

    /// Whether there is anything to draw at all, as against the plain app-name placeholder.
    ///
    /// The placeholder is for "no reading has ever arrived this session": no pairing, or a pairing
    /// the app has not reached yet. It deliberately is **not** shown for a device that dropped after
    /// being reached, which keeps rendering its last known activity. A manual session always has a
    /// reading, its source being one this app is driving itself.
    static func showsActivity(
        isPaired: Bool,
        hasReachedDeviceThisSession: Bool,
        connectionStatus: ConnectionStatus
    ) -> Bool {
        if connectionStatus == .manual { return true }
        return isPaired && hasReachedDeviceThisSession
    }

    /// Whether what is drawn is a **current** reading, which is what earns the live colours -- green,
    /// or the over-limit red and low-battery blink. `false` gives the flat yellow of a reading that
    /// is the last one seen rather than the one happening now.
    ///
    /// Manual mode is as current as it gets: the app is the thing generating the reading, so there
    /// is no window in which what is shown could be out of date.
    static func rendersAsLive(isPaired: Bool, connectionStatus: ConnectionStatus) -> Bool {
        switch connectionStatus {
        case .manual:
            return true
        case .connected:
            // Still gated on the pairing, which is what `AppState.isConnected` asks and what this
            // stands in for. A cube case cannot borrow the manual answer.
            return isPaired
        case .disconnected, .pairing, .reconnecting, .resetting, .failed:
            return false
        }
    }
}

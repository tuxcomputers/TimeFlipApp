import Foundation

/// What the Device tab will let the user do, given what the app is currently talking to.
enum DeviceTabRules {

    /// Whether **Forget Device** is live.
    ///
    /// Almost always, and that is the point. Every other control on the tab is a device setting and is
    /// gated on being connected; this one is local bookkeeping (`AppState.forgetDevice`) that reaches no
    /// radio, so refusing it while the device is out of reach would take it away in the one state it is
    /// needed. Forgetting a cube that is missing, flat, or on a PIN the app cannot present is a
    /// perfectly ordinary thing to want, and it is the *only* way back from the last of those.
    ///
    /// **Manual mode included, from 2026-08-11.** It was excluded while forgetting still reset the
    /// cube's password, which in manual mode would have reported success having sent nothing and thrown
    /// away the app's copy of a PIN the real cube still held. That is gone, and excluding it closed the
    /// escape hatch on the exact sequence a user hits after changing the batteries: the cube comes back
    /// on the vendor default, a paired connect presents the stored PIN and is refused (connecting never
    /// guesses -- see `PairingPasswordRules`), the app offers manual mode, and from there the only route
    /// back is to forget and re-pair. With Forget dead, there was none.
    ///
    /// Refused during a pairing attempt, which owns the pairing state until it resolves: dropping it
    /// from underneath an attempt in flight would leave the two disagreeing about whether there is a
    /// device. An attempt has its own cancel gesture and is over in seconds.
    static func allowsForget(connectionStatus: ConnectionStatus) -> Bool {
        connectionStatus != .pairing
    }

    /// Whether **Reset Device** is live.
    ///
    /// Not gated on being connected either, since a cube out of range is one you may still want to
    /// stop chasing -- but manual mode is the exception, and the reason is that something *does*
    /// answer. Reset is routed against `TimeFlipSessionManaging` rather than the BLE type -- done
    /// deliberately, so the mock can be tested -- so `0xFF` lands on the virtual device, which accepts
    /// it. The reset is then "confirmed", and confirming one calls
    /// `forgetDevice(deviceWasWiped: true)`, which discards the stored device name and uuid. The cube,
    /// wherever it is, is untouched: the app has simply thrown away the two things its scan uses to
    /// find it, and that is not recoverable without the cube in hand.
    ///
    /// Also refused during a pairing attempt, for the reason `allowsForget` gives.
    static func allowsReset(connectionStatus: ConnectionStatus) -> Bool {
        switch connectionStatus {
        case .manual, .pairing:
            return false
        case .disconnected, .connected, .reconnecting, .resetting, .failed:
            return true
        }
    }
}

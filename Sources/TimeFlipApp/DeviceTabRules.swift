import Foundation

/// What the Device tab will let the user do, given what the app is currently talking to.
enum DeviceTabRules {

    /// Whether **Forget Device** and **Reset Device** are live.
    ///
    /// Every other control on the tab is a device setting and is already gated on being connected.
    /// These two are not, on purpose: forgetting a cube that is out of range is a perfectly ordinary
    /// thing to want, and refusing it until the device came back would strand the user.
    ///
    /// Manual mode is the exception, and the reason is **Reset Device**. It is routed against
    /// `TimeFlipSessionManaging` rather than the BLE type -- done deliberately, so the mock can be
    /// tested -- so `0xFF` lands on the stand-in, which accepts it. The reset is then confirmed, and
    /// confirming a reset calls `forgetDevice(deviceWasWiped: true)`, which discards the stored
    /// device name and uuid. The cube, wherever it is, is untouched: the app has simply thrown away
    /// the two things its scan uses to find it, and that is not recoverable without the cube in hand.
    ///
    /// Forget Device is no longer dangerous here -- it is local bookkeeping that touches neither the
    /// cube nor the stored PIN (see `AppState.forgetDevice`, and the 2026-08-11 note there on what it
    /// used to do). It stays behind the same gate because the two buttons share one rule and there is
    /// nothing to be gained by dropping a pairing in the middle of a manual session, which lasts only
    /// as long as the launch anyway.
    static func allowsPairingActions(connectionStatus: ConnectionStatus) -> Bool {
        switch connectionStatus {
        case .manual:
            return false
        case .pairing:
            // The attempt owns the connection until it resolves.
            return false
        case .disconnected, .connected, .reconnecting, .resetting, .failed:
            return true
        }
    }
}

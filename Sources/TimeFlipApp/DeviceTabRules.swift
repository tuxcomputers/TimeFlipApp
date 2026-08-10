import Foundation

/// What the Device tab will let the user do, given what the app is currently talking to.
enum DeviceTabRules {

    /// Whether **Forget Device** and **Reset Device** are live.
    ///
    /// Every other control on the tab is a device setting and is already gated on being connected.
    /// These two are not, on purpose: forgetting a cube that is out of range is a perfectly ordinary
    /// thing to want, and refusing it until the device came back would strand the user.
    ///
    /// Manual mode is the exception, and the reason is that something *does* answer. The app is
    /// holding a virtual device, and both of these paths reach it:
    ///
    /// - Reset Device is routed against `TimeFlipSessionManaging` rather than the BLE type -- done
    ///   deliberately, so the mock can be tested -- so `0xFF` lands on the stand-in, which accepts
    ///   it. The reset is then confirmed, and confirming a reset calls `forgetDevice(deviceWasWiped:
    ///   true)`, which discards the stored device name and uuid. The cube, wherever it is, is
    ///   untouched: the app has simply thrown away the two things its scan uses to find it.
    /// - Forget Device asks for a password reset first, and that path casts to the BLE type and
    ///   returns `true` when the cast fails. So it reports success having done nothing, clears the
    ///   stored password and unpairs, while the real cube keeps the PIN this app rotated onto it.
    ///   The user is then locked out of their own device by the app having deleted the only copy of
    ///   its password.
    ///
    /// Both read as ordinary buttons doing ordinary things, and both are unrecoverable without the
    /// cube in hand. Disabled is the only safe answer while there is a stand-in in the way.
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

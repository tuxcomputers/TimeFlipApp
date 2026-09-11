import Foundation

/// The radio as the reconnect loop needs it: what it is busy with, and the one instruction that reaches for a cube.
///
/// **Six members, which is all `DeviceReconnector` touches.** `BluetoothRadio` is much larger than this, and every
/// other part of it belongs to whatever is talking to the cube rather than to the loop that decides when to try.
///
/// Nothing here does any deciding. `DeviceReconnectRules` reads the four flags and answers whether an attempt is
/// worth making; `reach` is the attempt itself.
@MainActor
package protocol CubeRadio: AnyObject {
    /// The device this app is currently logged in to, or `nil`.
    var connectedDevice: DeviceHandle? { get }
    /// Whether a scan is running.
    var isScanning: Bool { get }
    /// Whether an attempt to reach a cube is already under way, from this loop or from anywhere else.
    var isReachingForCube: Bool { get }
    /// Whether a factory reset is waiting on the cube to come back.
    var isFactoryResetRunning: Bool { get }

    /// Reach for one device: connect if it is already in hand, scan for it otherwise, and log in with the first
    /// candidate PIN that the cube accepts.
    ///
    /// `remembered` and `previouslyKnown` are the names the app has for it, which is how a renamed cube is still
    /// recognised. `rotatingTo` is a new PIN to set once logged in, or `nil` to leave it alone.
    func reach(
        _ id: DeviceHandle,
        presenting candidates: [String],
        rotatingTo: String?,
        remembered: String?,
        previouslyKnown: String?
    )

    /// Drop what the last scan found, so the next `reach` has to look again rather than reusing it. The connected
    /// cube is kept.
    func forgetWhatWasFound()
}

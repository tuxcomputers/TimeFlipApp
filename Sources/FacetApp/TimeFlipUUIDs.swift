import CoreBluetooth

/// The vendor's UUIDs, from `docs/TimeFlip2 BLE Protocol v4.3.md`.
///
/// **Only the ones something in this app talks to.** The cube exposes nine characteristics and this names four of
/// them, because a constant for a characteristic nothing reads is a claim about behaviour nobody has checked. The
/// rest arrive with the feature that uses them.
///
/// Each is a computed property rather than a `static let`: `CBUUID` is a class and is not `Sendable`, so held as a
/// stored global it is shared mutable state and the compiler refuses it. The strings are the constants.
enum TimeFlipUUIDs {
    static let serviceString = "F1196F50-71A4-11E6-BDF4-0800200C9A66"
    static let commandResultString = "F1196F53-71A4-11E6-BDF4-0800200C9A66"
    static let passwordString = "F1196F57-71A4-11E6-BDF4-0800200C9A66"

    /// The service everything TimeFlip-specific hangs off, and the only UUID a scan could ask about.
    static var service: CBUUID { CBUUID(string: serviceString) }

    /// Where the cube answers. The PIN verdict is read from here, and per finding 2 in
    /// `docs/timeflip2-firmware-observations.md` a good number of commands never write to it at all, so a value read
    /// from it is only trustworthy where a command is known to update it. The login is one that does.
    static var commandResult: CBUUID { CBUUID(string: commandResultString) }

    /// Write-only, six bytes. The cube refuses every command until the right PIN is written here, and it forgets it
    /// on every disconnect (protocol v4.3), so this is presented on each connection rather than once.
    static var password: CBUUID { CBUUID(string: passwordString) }

    /// A readable name for the raw comms log.
    ///
    /// **Falls back to the bare UUID rather than to "unknown"**, which is the archive's decision and worth keeping
    /// verbatim: the point of logging every characteristic is to see traffic this app has no handler for, so a UUID
    /// appearing here unnamed is a genuine finding and has to be printed in full to be looked up in the spec.
    static func name(for uuid: CBUUID) -> String {
        switch uuid {
        case service: return "timeFlipService"
        case commandResult: return "commandResult"
        case password: return "password"
        default: return uuid.uuidString
        }
    }
}

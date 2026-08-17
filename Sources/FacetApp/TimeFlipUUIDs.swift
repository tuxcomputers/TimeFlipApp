import CoreBluetooth

/// The vendor's UUIDs, from `docs/TimeFlip2 BLE Protocol v4.3.md`.
///
/// **Only the ones something in this app talks to**, because a constant for a characteristic nothing reads is a claim
/// about behaviour nobody has checked. The rest arrive with the feature that uses them, which is what the Device
/// Information four below are: they were not here until a tab wanted them on screen.
///
/// Each is a computed property rather than a `static let`: `CBUUID` is a class and is not `Sendable`, so held as a
/// stored global it is shared mutable state and the compiler refuses it. The strings are the constants.
enum TimeFlipUUIDs {
    static let serviceString = "F1196F50-71A4-11E6-BDF4-0800200C9A66"
    static let commandResultString = "F1196F53-71A4-11E6-BDF4-0800200C9A66"
    static let commandString = "F1196F54-71A4-11E6-BDF4-0800200C9A66"
    static let passwordString = "F1196F57-71A4-11E6-BDF4-0800200C9A66"

    /// The standard Device Information service and the four strings the Device tab's **More** rows show.
    ///
    /// **Bluetooth SIG's, not the vendor's**, which is why they are 16-bit and why they behave unlike everything else
    /// in this file: each is a plain read of its own characteristic, with no command channel and no command result in
    /// the way. `docs/TimeFlip2 BLE Protocol v4.3.md` Tab. 1 lists all four at 20 bytes, read-only.
    ///
    /// Standard GATT puts no authentication on these, so they should answer without a PIN -- but **this app has never
    /// asked one that way and does not rely on it**: the reads run after a confirmed login, which is the only state
    /// they have been measured in (2026-08-17).
    ///
    /// **System ID (`0x2A23`) is deliberately absent.** The archive read it too, and hex-encoded it because it is raw
    /// binary rather than text, but nothing in this app shows it -- so by this file's own rule it waits for whatever
    /// feature wants it.
    static let deviceInformationString = "180A"
    static let manufacturerNameString = "2A29"
    static let modelNumberString = "2A24"
    static let hardwareRevisionString = "2A27"
    static let firmwareRevisionString = "2A26"

    /// The service everything TimeFlip-specific hangs off, and the only UUID a scan could ask about.
    static var service: CBUUID { CBUUID(string: serviceString) }

    /// Where the cube answers. The PIN verdict is read from here, and per finding 2 in
    /// `docs/timeflip2-firmware-observations.md` a good number of commands never write to it at all, so a value read
    /// from it is only trustworthy where a command is known to update it. The login is one that does.
    static var commandResult: CBUUID { CBUUID(string: commandResultString) }

    /// Where every command goes, one byte of command number followed by its arguments. The only one this app writes
    /// so far is `0x30`, which sets a new PIN (`DeviceLoginRules.setPIN`); the cube refuses the lot until a PIN has
    /// been accepted on `password`.
    static var command: CBUUID { CBUUID(string: commandString) }

    /// Write-only, six bytes. The cube refuses every command until the right PIN is written here, and it forgets it
    /// on every disconnect (protocol v4.3), so this is presented on each connection rather than once.
    static var password: CBUUID { CBUUID(string: passwordString) }

    /// Where a cube says what it is. Discovered on its own, after the login rather than during it, since none of it
    /// is what a login needs (see `DeviceLogin.readDeviceInfo`).
    static var deviceInformation: CBUUID { CBUUID(string: deviceInformationString) }
    static var manufacturerName: CBUUID { CBUUID(string: manufacturerNameString) }
    static var modelNumber: CBUUID { CBUUID(string: modelNumberString) }
    static var hardwareRevision: CBUUID { CBUUID(string: hardwareRevisionString) }
    static var firmwareRevision: CBUUID { CBUUID(string: firmwareRevisionString) }

    /// The four the Device Information service is asked for, in the order the tab shows them.
    static var deviceInformationCharacteristics: [CBUUID] {
        [manufacturerName, modelNumber, hardwareRevision, firmwareRevision]
    }

    /// A readable name for the raw comms log.
    ///
    /// **Falls back to the bare UUID rather than to "unknown"**, which is the archive's decision and worth keeping
    /// verbatim: the point of logging every characteristic is to see traffic this app has no handler for, so a UUID
    /// appearing here unnamed is a genuine finding and has to be printed in full to be looked up in the spec.
    static func name(for uuid: CBUUID) -> String {
        switch uuid {
        case service: return "timeFlipService"
        case commandResult: return "commandResult"
        case command: return "command"
        case password: return "password"
        case deviceInformation: return "deviceInformation"
        case manufacturerName: return "manufacturerName"
        case modelNumber: return "modelNumber"
        case hardwareRevision: return "hardwareRevision"
        case firmwareRevision: return "firmwareRevision"
        default: return uuid.uuidString
        }
    }
}

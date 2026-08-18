import CoreBluetooth

/// The vendor's UUIDs, from `docs/TimeFlip2 BLE Protocol v4.3.md`.
///
/// **Only the ones something in this app talks to**, because a constant for a characteristic nothing reads is a claim
/// about behaviour nobody has checked. The rest arrive with the feature that uses them, which is what the Device
/// Information four below are: they were not here until a tab wanted them on screen.
///
/// **Listening counts as talking to one.** The app subscribes to every characteristic that says it can notify, so
/// five the cube pushes on are named here with no feature reading them yet -- see their own note for why a name is
/// not a claim.
///
/// Each is a computed property rather than a `static let`: `CBUUID` is a class and is not `Sendable`, so held as a
/// stored global it is shared mutable state and the compiler refuses it. The strings are the constants.
enum TimeFlipUUIDs {
    static let serviceString = "F1196F50-71A4-11E6-BDF4-0800200C9A66"
    static let commandResultString = "F1196F53-71A4-11E6-BDF4-0800200C9A66"
    static let commandString = "F1196F54-71A4-11E6-BDF4-0800200C9A66"
    static let passwordString = "F1196F57-71A4-11E6-BDF4-0800200C9A66"

    /// The five the cube pushes on, from `docs/TimeFlip2 BLE Protocol v4.3.md` Tab. 1.
    ///
    /// **Nothing here reads any of them, and they are still named**, which is the one exception to this file's rule
    /// above and has its own reason. `DeviceLogin.listenToTheCube` subscribes to everything whose properties say it
    /// can notify, so the app *does* talk to these -- it listens to them -- and every value they push is a `ble-rx`
    /// row. Without a name each of those rows would be a bare 128-bit UUID, which is a trace nobody can read at a
    /// glance and exactly the state finding 3 was found in.
    ///
    /// **They are names, not claims about behaviour.** The subscription is driven by the characteristic's own
    /// properties rather than by this list, so a cube offering something not named here is still subscribed to and
    /// still logged, under its bare UUID -- which the trace treats as a finding rather than as noise.
    static let eventsDataString = "F1196F51-71A4-11E6-BDF4-0800200C9A66"
    static let facesString = "F1196F52-71A4-11E6-BDF4-0800200C9A66"
    static let doubleTapString = "F1196F55-71A4-11E6-BDF4-0800200C9A66"
    static let systemStateString = "F1196F56-71A4-11E6-BDF4-0800200C9A66"
    static let historyString = "F1196F58-71A4-11E6-BDF4-0800200C9A66"

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

    /// The standard Battery Service and the one characteristic in it, which is where the charge comes from.
    ///
    /// **Bluetooth SIG's as well**, and the vendor lists it in `docs/TimeFlip2 BLE Protocol v4.3.md` Tab. 1 as one
    /// byte, read **and notify**. Both halves of that are used and both are needed: the cube pushes a value only when
    /// it changes, so a subscription on its own leaves a freshly connected app with no figure at all until the charge
    /// next moves -- which on the archive's logged traffic was sometimes over an hour. See `DeviceLogin.followBattery`.
    static let batteryServiceString = "180F"
    static let batteryLevelString = "2A19"

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

    /// Where the charge is. Discovered after the login like the Device Information service, and for the same reason:
    /// a login that waited on it would spend round trips in front of the answer somebody is watching for.
    static var batteryService: CBUUID { CBUUID(string: batteryServiceString) }
    static var batteryLevel: CBUUID { CBUUID(string: batteryLevelString) }

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
        case batteryService: return "batteryService"
        case batteryLevel: return "batteryLevel"
        case CBUUID(string: eventsDataString): return "eventsData"
        case CBUUID(string: facesString): return "faces"
        case CBUUID(string: doubleTapString): return "doubleTap"
        case CBUUID(string: systemStateString): return "systemState"
        case CBUUID(string: historyString): return "history"
        default: return uuid.uuidString
        }
    }
}

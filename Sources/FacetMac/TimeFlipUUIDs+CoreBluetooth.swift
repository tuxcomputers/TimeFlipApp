import CoreBluetooth
import FacetCore

/// CoreBluetooth's view of the UUIDs `FacetCore.TimeFlipUUIDs` names.
///
/// **Separated from the strings because `CBUUID` is the platform's and the strings are not.** BlueZ names the same
/// characteristics with 128-bit lowercase strings and needs no type at all, so the constants moved to the core and
/// this stayed here -- which is also why every one of these is a computed property: `CBUUID` is a class and is not
/// `Sendable`, so held as a stored global it is shared mutable state the compiler refuses.
extension TimeFlipUUIDs {
    /// The service everything TimeFlip-specific hangs off, and the only UUID a scan could ask about.
    package static var service: CBUUID { CBUUID(string: serviceString) }

    /// Where the cube answers. The PIN verdict is read from here, and per finding 2 in
    /// `docs/timeflip2-firmware-observations.md` a good number of commands never write to it at all, so a value read
    /// from it is only trustworthy where a command is known to update it. The login is one that does.
    package static var commandResult: CBUUID { CBUUID(string: commandResultString) }

    /// Where every command goes, one byte of command number followed by its arguments. The only one this app writes
    /// so far is `0x30`, which sets a new PIN (`DeviceLoginRules.setPIN`); the cube refuses the lot until a PIN has
    /// been accepted on `password`.
    package static var command: CBUUID { CBUUID(string: commandString) }

    /// Write-only, six bytes. The cube refuses every command until the right PIN is written here, and it forgets it
    /// on every disconnect (protocol v4.3), so this is presented on each connection rather than once.
    package static var password: CBUUID { CBUUID(string: passwordString) }

    /// Where a cube says what it is. Discovered on its own, after the login rather than during it, since none of it
    /// is what a login needs (see `DeviceLogin.readDeviceInfo`).
    package static var deviceInformation: CBUUID { CBUUID(string: deviceInformationString) }
    package static var manufacturerName: CBUUID { CBUUID(string: manufacturerNameString) }
    package static var modelNumber: CBUUID { CBUUID(string: modelNumberString) }
    package static var hardwareRevision: CBUUID { CBUUID(string: hardwareRevisionString) }
    package static var firmwareRevision: CBUUID { CBUUID(string: firmwareRevisionString) }

    /// Which face the cube is resting on. One byte, read **and** notify, and both halves are used for the same reason
    /// the charge's are: the subscription gives every flip from now on, and the read is the only way to know which way
    /// up a cube already is (see `DeviceLogin.askWhichFaceIsUp`).
    package static var faces: CBUUID { CBUUID(string: facesString) }

    /// The cube's own record of what it has been doing. Read, **write** and notify, and all three matter: a request is
    /// written to it and the answer comes back on it, frame by frame, until a sentinel (see `DeviceHistoryRules`).
    package static var history: CBUUID { CBUUID(string: historyString) }

    /// What the cube says about its own condition: what it wants pushed back to it, and whether its hardware works.
    /// Read **and** notify, and the read is the half that matters most -- the conditions it reports are standing ones,
    /// so a cube reset before this launch, or one whose flash has failed, says so once and then sits there (see
    /// `DeviceLogin.askWhatStateTheCubeIsIn`).
    package static var systemState: CBUUID { CBUUID(string: systemStateString) }

    /// Where the charge is. Discovered after the login like the Device Information service, and for the same reason:
    /// a login that waited on it would spend round trips in front of the answer somebody is watching for.
    package static var batteryService: CBUUID { CBUUID(string: batteryServiceString) }
    package static var batteryLevel: CBUUID { CBUUID(string: batteryLevelString) }

    /// The four the Device Information service is asked for, in the order the tab shows them.
    package static var deviceInformationCharacteristics: [CBUUID] {
        [manufacturerName, modelNumber, hardwareRevision, firmwareRevision]
    }

    // **There was a `name(for: CBUUID)` here and nothing calls it any more.** The trace rows moved into
    // `FacetCore.BLETrace` on 2026-09-11 and name their own UUIDs from the core's one table, so this had become a
    // spelling with no caller -- which is what `feature/commandChannel` was gated on for `linkEnded()`, and the
    // same answer applies.
}

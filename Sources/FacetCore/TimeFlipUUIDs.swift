import Foundation

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
/// **The strings are here and the platform types are not.** CoreBluetooth's `CBUUID` accessors live beside
/// `BluetoothRadio` in `TimeFlipUUIDs+CoreBluetooth.swift`, because `CBUUID` is a class and is not `Sendable`, so
/// held as a stored global it is shared mutable state the compiler refuses. What is portable about a UUID is the
/// string, and BlueZ wants exactly that -- see `canonical(_:)` below for the one thing the two platforms disagree
/// about.
package enum TimeFlipUUIDs {
    package static let serviceString = "F1196F50-71A4-11E6-BDF4-0800200C9A66"
    package static let commandResultString = "F1196F53-71A4-11E6-BDF4-0800200C9A66"
    package static let commandString = "F1196F54-71A4-11E6-BDF4-0800200C9A66"
    package static let passwordString = "F1196F57-71A4-11E6-BDF4-0800200C9A66"

    /// The five the cube pushes on, from `docs/TimeFlip2 BLE Protocol v4.3.md` Tab. 1.
    ///
    /// **Only `faces` is read; the other four are still named**, which is the one exception to this file's rule above
    /// and has its own reason. `DeviceLogin.listenToTheCube` subscribes to everything whose properties say it can
    /// notify, so the app *does* talk to these -- it listens to them -- and every value they push is a `ble-rx` row.
    /// Without a name each of those rows would be a bare 128-bit UUID, which is a trace nobody can read at a glance
    /// and exactly the state finding 3 was found in.
    ///
    /// **They are names, not claims about behaviour.** The subscription is driven by the characteristic's own
    /// properties rather than by this list, so a cube offering something not named here is still subscribed to and
    /// still logged, under its bare UUID -- which the trace treats as a finding rather than as noise.
    package static let eventsDataString = "F1196F51-71A4-11E6-BDF4-0800200C9A66"
    package static let facesString = "F1196F52-71A4-11E6-BDF4-0800200C9A66"
    package static let doubleTapString = "F1196F55-71A4-11E6-BDF4-0800200C9A66"
    package static let systemStateString = "F1196F56-71A4-11E6-BDF4-0800200C9A66"
    package static let historyString = "F1196F58-71A4-11E6-BDF4-0800200C9A66"

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
    package static let deviceInformationString = "180A"
    package static let manufacturerNameString = "2A29"
    package static let modelNumberString = "2A24"
    package static let hardwareRevisionString = "2A27"
    package static let firmwareRevisionString = "2A26"

    /// The standard Battery Service and the one characteristic in it, which is where the charge comes from.
    ///
    /// **Bluetooth SIG's as well**, and the vendor lists it in `docs/TimeFlip2 BLE Protocol v4.3.md` Tab. 1 as one
    /// byte, read **and notify**. Both halves of that are used and both are needed: the cube pushes a value only when
    /// it changes, so a subscription on its own leaves a freshly connected app with no figure at all until the charge
    /// next moves -- which on the archive's logged traffic was sometimes over an hour. See `DeviceLogin.followBattery`.
    /// The four values a cube is asked for out of Device Information, and the whole of what this app wants from
    /// that service.
    ///
    /// **Which four is a decision, not a spelling**, so it is here rather than beside the platform's UUID type:
    /// a cube exposing three of them is read three times and reports three values, rather than the whole lot
    /// timing out behind one that was never going to arrive.
    package static let deviceInformationCharacteristicStrings = [
        manufacturerNameString, modelNumberString, hardwareRevisionString, firmwareRevisionString,
    ]

    package static let batteryServiceString = "180F"
    package static let batteryLevelString = "2A19"

    /// The Bluetooth SIG base UUID that every 16-bit assigned number sits inside.
    ///
    /// `0000XXXX-0000-1000-8000-00805F9B34FB`, from the Core Specification. The seven standard UUIDs above are
    /// written in the 16-bit shorthand because that is how the vendor's table lists them and how CoreBluetooth
    /// accepts them.
    package static let sigBase = "0000%@-0000-1000-8000-00805f9b34fb"

    /// A UUID string in the one form that can be compared against what a platform reports.
    ///
    /// **The two platforms do not agree on how a standard UUID is spelled**, which is the whole reason this exists.
    /// CoreBluetooth takes `2A19` and gives it back as `2A19`; BlueZ never uses the shorthand at all and reports
    /// `00002a19-0000-1000-8000-00805f9b34fb` for the same characteristic. Comparing what this file holds against
    /// what a `GattCharacteristic1` object says therefore needs one of them expanded, and lowercase is what BlueZ
    /// answers in.
    ///
    /// A 32-bit shorthand is expanded the same way, the specification allowing it, though nothing here uses one.
    /// Anything already 128-bit is only lowercased, and anything else is handed back untouched -- this decides how to
    /// spell a UUID, not whether it is one.
    package static func canonical(_ uuid: String) -> String {
        let trimmed = uuid.trimmingCharacters(in: .whitespaces)
        let short = trimmed.count == 4 || trimmed.count == 8
        guard short, trimmed.allSatisfy(\.isHexDigit) else { return trimmed.lowercased() }
        let padded = String(repeating: "0", count: 8 - trimmed.count) + trimmed.lowercased()
        return "\(padded)-0000-1000-8000-00805f9b34fb"
    }

    /// Whether two UUID strings name the same thing, however each is spelled.
    package static func match(_ one: String, _ other: String) -> Bool {
        canonical(one) == canonical(other)
    }

    /// What this app calls a UUID, for a log or a listing. `nil` for one it has never named -- which is a
    /// finding rather than noise: a cube offering something unnamed is still subscribed to.
    package static func name(for uuid: String) -> String? {
        let named: [(String, String)] = [
            (serviceString, "service"), (commandResultString, "command result"),
            (commandString, "command"), (passwordString, "password"),
            (eventsDataString, "events data"), (facesString, "faces"),
            (doubleTapString, "double tap"), (systemStateString, "system state"),
            (historyString, "history"), (deviceInformationString, "device information"),
            (manufacturerNameString, "manufacturer name"), (modelNumberString, "model number"),
            (hardwareRevisionString, "hardware revision"), (firmwareRevisionString, "firmware revision"),
            (batteryServiceString, "battery service"), (batteryLevelString, "battery level"),
        ]
        return named.first { match($0.0, uuid) }?.1
    }
}

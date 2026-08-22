import Foundation

/// Writes down that this app has a device: which one, what it is called, and whether it can be heard from right now.
///
/// **This is the moment a connection becomes a pairing.** Reaching a cube and pairing with it were the same press
/// until now and are still one gesture, but they are not the same claim: the link is this window's and goes when the
/// window does, while `paired` and `device_uuid` are described in `database/011_setting.sql` as surviving every drop,
/// every refusal and every quit. So the rows go in at the one point where the app knows it is talking to the right
/// cube and knows the PIN it will need next time -- a confirmed login, after any new PIN has been set and proved.
///
/// **Five rows, three lifetimes**, which is why this is one call rather than five call sites:
///
/// - `paired` and `device_uuid` are durable, and only forgetting a device clears them.
/// - `device_name` is durable and outlives even that, since forgetting does not un-rename a cube.
/// - `device_info` is durable alongside the pairing, and is the one row here that is **not** written by
///   `recordPairing`: what the cube says it is arrives seconds later, off its own reads, so it has `recordInfo` to
///   itself.
/// - `connection` is transient: it says whether the cube is reachable now, and it is put back down by
///   `recordConnectionLost` the moment the link goes, deliberate or not. A row left saying `connected` while nothing
///   is connected is the two-answers problem in its purest form -- the app would be reporting a device it cannot
///   hear.
///
/// **Every write is read back** (`SettingStore.write`), and a refusal is said out loud rather than swallowed. A
/// pairing the table did not take is one the next launch will not find, and the app would spend that launch in manual
/// mode with a perfectly good cube in front of it.
///
/// **Massaged from `AppDataStore.recordPaired` / `recordDeviceUUID` / `recordDeviceName` / `recordConnection`.** The
/// decisions are the archive's and they survive inspection: what goes in each row, which of them a drop touches, and
/// that only a real change moves `previous_name`. What is not kept is four separate methods on a 3,000-line store
/// that callers had to remember to call in the right order -- the order is what makes `previous_name` correct, so it
/// belongs in the thing that writes them rather than in whoever calls it.
@MainActor
struct DevicePairingRecorder {
    private let settings: SettingStore
    private let debugLog: DebugLog?

    init(settings: SettingStore, debugLog: DebugLog?) {
        self.settings = settings
        self.debugLog = debugLog
    }

    /// Records a confirmed pairing and marks the connection up. Answers whether every row took it.
    @discardableResult
    func recordPairing(with device: ScannedDevice, at moment: Date = Date()) -> Bool {
        // **Which write was refused is collected, not just whether one was.** "the table refused a write" names the
        // problem and nothing else, and on 2026-08-22 that cost half an hour of reading a log backwards to find out
        // that a busy database had dropped one of these six. A refusal is rare enough that the failure message is the
        // only evidence anybody will have of it, so it has to say which row did not take.
        var refused: [String] = []
        func put(_ name: String, _ field: String, _ value: Bool) {
            if !settings.write(name, field: field, value) { refused.append("\(name).\(field)") }
        }
        func put(_ name: String, _ field: String, _ value: String) {
            if !settings.write(name, field: field, value) { refused.append("\(name).\(field)") }
        }

        put("paired", "paired", true)
        put("device_uuid", "uuid", device.id.uuidString)

        if let name = DevicePairingRules.gapName(of: device) {
            // Before the name itself, because the rule reads what the row currently holds.
            if let previous = DevicePairingRules.previousName(
                replacing: settings.string("device_name", field: "name"), with: name
            ) {
                put("device_name", "previous_name", previous)
                debugLog?.record(.pair, "The cube was called \"\(previous)\", which the scan filter keeps")
            }
            put("device_name", "name", name)
        }

        put("connection", "connected", true)
        put("connection", "last_connection", Self.stamp(moment))

        debugLog?.record(
            .pair,
            refused.isEmpty
                ? "Paired with \(DeviceScanRules.label(for: device)) (\(device.id.uuidString))"
                : "PAIRING NOT FULLY RECORDED for \(device.id.uuidString) -- "
                    + "the table refused \(refused.joined(separator: ", "))"
        )
        return refused.isEmpty
    }

    /// Records that the app has got back to the cube it was already paired to. Answers whether both rows took it.
    ///
    /// **The connection row and nothing else, which is the whole point of it being separate from `recordPairing`.** The
    /// pairing has not changed: `paired`, `device_uuid` and `device_name` say the same thing they said before the link
    /// went, and they are described in `database/011_setting.sql` as surviving exactly this. What changed is that the cube
    /// is reachable again, and that is one row.
    ///
    /// **It also stops the log lying.** `recordPairing` writes "Paired with ...", which on the twentieth reconnect of a
    /// morning is a record of a pairing that did not happen -- and the debug log is what a device run is read from, so a
    /// line that names the wrong event costs somebody an hour later on.
    @discardableResult
    func recordReconnection(with device: ScannedDevice, at moment: Date = Date()) -> Bool {
        var wrote = settings.write("connection", field: "connected", true)
        wrote = settings.write("connection", field: "last_connection", Self.stamp(moment)) && wrote
        debugLog?.record(
            .pair,
            wrote
                ? "Reconnected to \(DeviceScanRules.label(for: device)) (\(device.id.uuidString))"
                : "RECONNECTION NOT RECORDED for \(device.id.uuidString) -- the table refused a write"
        )
        return wrote
    }

    /// Records what the cube says it is. Answers whether every field that arrived took.
    ///
    /// **Only what the cube actually answered is written**, which is the whole reason `DeviceInfo`'s fields are
    /// optional rather than defaulted to `""`. A read that failed, or a characteristic the cube does not expose, must
    /// not blank a value an earlier connection did get: the cube has not stopped being a `TFv4.1` because it declined
    /// to say so this time, and a row that empties itself on a bad read is worse than one that never filled.
    ///
    /// **A value that arrived is written even when it matches what is stored**, and the read-back is what makes that
    /// cheap rather than wasteful: `SettingStore.write` proves each field took, so re-recording is also the standing
    /// check that the row still says what the cube says. What it costs is a write per connection per field.
    ///
    /// **Nothing here is conditional on `paired`.** These reads only happen on a confirmed login, which is the same
    /// moment `recordPairing` runs, so by the time this is called the app has a device. Whether the tab may *show*
    /// them is a separate question and belongs to `DeviceInfoRules.detail`, which asks about the pairing at the point
    /// the words are chosen rather than letting an empty row stand in for "no device".
    @discardableResult
    func recordInfo(_ info: DeviceInfo) -> Bool {
        guard !info.isEmpty else {
            debugLog?.record(.info, "The cube said nothing about itself, so nothing was recorded")
            return true
        }
        var wrote = true
        for (field, value) in [
            ("manufacturer", info.manufacturer),
            ("model", info.model),
            ("hardware", info.hardware),
            ("firmware", info.firmware),
        ] {
            guard let value else { continue }
            wrote = settings.write("device_info", field: field, value) && wrote
        }
        debugLog?.record(
            .info,
            wrote
                ? "Recorded what the cube says it is"
                : "WHAT THE CUBE SAYS IT IS WAS NOT FULLY RECORDED -- the table refused a write"
        )
        return wrote
    }

    /// Forgets the device: the app stops having one.
    ///
    /// **Copied from `AppState.forgetDevice` as it stands**, because its decisions survive inspection and rewriting
    /// them would land in the same place. What is kept is the whole of its reasoning:
    ///
    /// - **It reaches no radio.** That is what makes it the escape hatch, and the archive is emphatic that it must
    ///   never need the device: forgetting a cube that is missing, flat, or on a PIN this app cannot present is an
    ///   ordinary thing to want, and after a battery change -- which puts the cube back on the vendor PIN while the
    ///   app still holds the old one -- it is the only way back.
    /// - **`device_name` survives**, which `database/011_setting.sql` says in the row's own description: forgetting
    ///   does not un-rename a cube. Once a device has been renamed off "TimeFlip" that string is the only thing a
    ///   filtered scan can match it on, so discarding it here would throw away the way back to the very device being
    ///   forgotten. Only a confirmed factory reset clears it, the cube having actually reverted to the vendor name.
    /// - **The stored PIN survives too**, and for the same kind of reason: forgetting does not change the cube's PIN,
    ///   so writing the vendor default over a stored one would record something untrue about the hardware. The archive
    ///   notes this went wrong once, a Forget stamping `000000` over a hand-set PIN on 2026-08-01.
    ///
    /// **`device_info` is cleared, which is the one place this departs from the row's own description** -- and the
    /// departure is the archive's instinct applied to a row it did not have. `AppState.forgetDevice` clears
    /// `deviceInfo` because it was a live reading of the device being let go. Here those four strings are stored, and
    /// keeping them would be worse than a stale reading: `recordInfo` only writes what a cube actually answers, so
    /// pairing a second cube that exposes no Device Information service would leave the first one's manufacturer and
    /// firmware on screen attributed to it. The row describes *the paired device*, and after this there is not one.
    @discardableResult
    func recordForget() -> Bool {
        var wrote = settings.write("paired", field: "paired", false)
        wrote = settings.write("device_uuid", field: "uuid", "") && wrote
        // The connection goes down with the pairing: a connection is only meaningful while there is a device for it
        // to be to, so a row left saying `connected` under an unpaired app is the two-answers problem again.
        wrote = settings.write("connection", field: "connected", false) && wrote
        // Emptied rather than removed, which is how this table clears a field everywhere else (`SettingStore.write`,
        // and the Google sign-out that set the precedent): the key has to survive for the read-back to confirm it.
        for field in ["manufacturer", "model", "hardware", "firmware"] where settings.string("device_info", field: field) != nil {
            wrote = settings.write("device_info", field: field, "") && wrote
        }
        debugLog?.record(
            .pair,
            wrote
                ? "Forgot the device; the name it is carrying is kept so a scan can still find it"
                : "DEVICE NOT FULLY FORGOTTEN -- the table refused a write"
        )
        return wrote
    }

    /// Forgets the device *and* records that the cube itself was wiped.
    ///
    /// **Everything `recordForget` does, plus the name**, which is the archive's `forgetDevice(deviceWasWiped: true)`
    /// and its reasoning: a plain forget keeps `device_name` because forgetting does not un-rename a cube, while a
    /// factory reset genuinely has put it back on the vendor name, so the remembered one is now wrong about the
    /// hardware.
    ///
    /// **The name is moved to `previous_name` rather than discarded, and that is a deliberate departure.** The archive
    /// threw it away, and could afford to because it confirmed the wipe out of band before doing so -- it waited up to
    /// 120 seconds for the cube to come back on the vendor PIN (`ApplicationDelegate.factoryResetConfirmDeadline`).
    /// This app has no reconnect loop to confirm in, and `0xFF` has no usable acknowledgement
    /// (`DeviceLoginRules.factoryReset`), so a wipe that silently failed is a real possibility -- and discarding the
    /// name on one would leave a renamed cube that no filtered scan can match. `previous_name` is already in that
    /// filter (`DeviceScanRules.isEligible`, via `BluetoothRadio.start`), so keeping it there costs nothing and covers
    /// both outcomes: a cube that was wiped answers to the vendor default, and one that was not still answers to the
    /// name sitting in `previous_name`.
    ///
    /// **The stored PIN is not touched either**, and does not need to be: `DeviceLoginRules.candidates` always presents
    /// the vendor default first and the stored one after it, so a wiped cube and an unwiped one are both reachable on
    /// the next attempt without this having to guess which happened.
    @discardableResult
    func recordFactoryReset() -> Bool {
        var wrote = recordForget()
        if let name = settings.string("device_name", field: "name"), !name.isEmpty {
            wrote = settings.write("device_name", field: "previous_name", name) && wrote
            wrote = settings.write("device_name", field: "name", "") && wrote
            debugLog?.record(.pair, "The cube was called \"\(name)\"; keeping it in the scan filter in case the wipe did not take")
        }
        debugLog?.record(
            .pair,
            wrote ? "Reset the cube and forgot it" : "RESET NOT FULLY RECORDED -- the table refused a write"
        )
        return wrote
    }

    /// Marks the connection down, whether the cube went away or the app let it go.
    ///
    /// **The pairing is untouched**, which is the archive's rule and the row's own description: going out of range
    /// does not change which device this app is paired to, and clearing it here would make the app forget a perfectly
    /// good cube the moment somebody carried it out of the room.
    @discardableResult
    func recordConnectionLost(because reason: String, at moment: Date = Date()) -> Bool {
        var wrote = settings.write("connection", field: "connected", false)
        wrote = settings.write("connection", field: "connection_lost", Self.stamp(moment)) && wrote
        debugLog?.record(
            .pair,
            wrote
                ? "Connection down: \(reason)"
                : "CONNECTION STILL RECORDED AS UP after \(reason) -- the table refused a write"
        )
        return wrote
    }

    /// Records that the app was asked to quit, and marks the connection down with it.
    ///
    /// **`connection_lost` is cleared here, deliberately.** The three fields on that row exist to tell three
    /// different endings apart -- reachable now, lost the cube, shut down on purpose -- and a quit that left the
    /// last drop's stamp behind would make an intentional shutdown read afterwards as a device that went away. The
    /// archive's `recordQuitRequest`, copied for that reasoning.
    ///
    /// Written whether or not anything was connected: it says the app was asked to stop, which is true either way.
    @discardableResult
    func recordQuit(at moment: Date = Date()) -> Bool {
        var wrote = settings.write("connection", field: "connected", false)
        wrote = settings.write("connection", field: "quit_request", Self.stamp(moment)) && wrote
        wrote = settings.write("connection", field: "connection_lost", "") && wrote
        debugLog?.record(
            .pair,
            wrote ? "Quit: let go of the device" : "Quit: the connection row refused a write"
        )
        return wrote
    }

    /// `2026-08-17T13:25:38`, local, which is the form every date-time in the `setting` table takes
    /// (`database/011_setting.sql`) and the form `DebugLog` writes its rows in, minus the milliseconds nothing here
    /// is measured to.
    private static func stamp(_ moment: Date) -> String {
        formatter.string(from: moment)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

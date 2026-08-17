import Foundation

/// What a confirmed pairing puts in the `setting` table, decided away from the writing of it.
///
/// Two questions, both about names, and both easy to get wrong in a way no test with a radio in it would catch.
enum DevicePairingRules {
    /// The name to record for a cube: its **GAP name and nothing else**.
    ///
    /// **Not `DeviceScanRules.label`**, which is what the list shows and falls back to the advertised name and then to
    /// a placeholder. `database/011_setting.sql` is explicit that `device_name.name` is the GAP Device Name (`0x2A00`)
    /// -- the one a rename writes, the one this row is compared against on the next scan, and the one that will later
    /// be written back by command `0x15`. Recording `TimeFlip v2.0` there because the GAP name was not known yet would
    /// put a name in the row that no rename can ever change, and finding 1 in
    /// `docs/timeflip2-firmware-observations.md` is precisely that the advertised name never moves.
    ///
    /// `nil` when the cube has not told this Mac its name, which is a real state and not a fault: the row stays empty
    /// and the Info panel says `Unknown`, exactly as it does for a pairing that has not connected since.
    static func gapName(of device: ScannedDevice) -> String? {
        let name = (device.peripheralName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The name to keep as `previous_name`, or `nil` to leave that field exactly as it is.
    ///
    /// **Only a real change moves it**, which is the archive's rule and the reason it exists: the name is recorded on
    /// every connection, so re-recording the same string would push the genuinely previous name out of the row and
    /// undo the one thing it is there for. That second name is not history for its own sake -- `CBPeripheral.name` is
    /// one connection stale after a rename (measured over 120 polls in 30 seconds), so the scan straight after a
    /// rename is still seeing the old name, and it is in the filter so that a rename cannot lose the cube at the exact
    /// moment somebody is watching for the new one.
    ///
    /// Nothing to displace means nothing to record: a first pairing has no previous name, and writing an empty string
    /// there would put a name in the scan filter that matches nothing.
    static func previousName(replacing current: String?, with incoming: String) -> String? {
        let current = (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, current != incoming else { return nil }
        return current
    }

    // MARK: - which controls the TimeFlip section shows

    /// Whether the scan controls are on show: the **Scan for Devices** button and the **All Devices** box.
    ///
    /// **Looking for a cube is what an app with no cube does.** Once one is paired the section's job changes from
    /// finding a device to managing the one it has, so the controls change with it -- a scan offered beside a paired
    /// device invites somebody to go looking for a cube they already have, and connecting to a second one silently
    /// drops the first (`BluetoothRadio.connect`).
    ///
    /// **Gated on the pairing and not on the connection**, which is the same distinction the Info panel draws: a cube
    /// out of range is still this app's cube, and putting the Scan button back the moment it went quiet would offer to
    /// replace a device that is merely in another room.
    static func showsScanControls(isPaired: Bool) -> Bool { !isPaired }

    /// Whether **Forget** and **Reset** are on show. The other half of the same swap: exactly one of the two sets is up
    /// at any time, because they answer the two states the section can be in.
    static func showsPairedControls(isPaired: Bool) -> Bool { isPaired }

    /// Whether **Forget Device** may be pressed.
    ///
    /// **Live whenever there is a pairing, and not gated on the connection** -- the archive's `DeviceTabRules
    /// .allowsForget`, kept for its reasoning. Every other control on this tab is a device setting and needs the cube;
    /// this one is local bookkeeping that reaches no radio, so refusing it while the device is out of reach would take
    /// it away in the one state it is most needed. It is also the only way back once a cube is on a PIN the app cannot
    /// present, which is exactly what a battery change does.
    ///
    /// **Refused while an attempt is in flight**, which is the archive's other half: a connect owns the pairing state
    /// until it resolves, and dropping it from underneath one would leave the two disagreeing about whether there is a
    /// device. An attempt is over in seconds.
    static func allowsForget(isPaired: Bool, isReaching: Bool) -> Bool { isPaired && !isReaching }

    /// Whether **Reset Device** may be pressed.
    ///
    /// **Unlike Forget, this one needs the cube**, and that is the whole difference between the two buttons: forgetting
    /// is something the app does to its own rows, while resetting is a command (`0xFF`) that has to reach the hardware.
    ///
    /// **A deliberate departure from the archive**, which allowed it while disconnected on the grounds that "a cube out
    /// of range is one you may still want to stop chasing". That reasoning depended on something this app does not
    /// have: the archive routed reset through a session abstraction, so `0xFF` landed on a mock that accepted it and
    /// the reset was then "confirmed" without any cube being touched. Here there is one path and it is the radio, so a
    /// live button with nothing connected would report a wipe that never left the Mac. Wanting to stop chasing a cube
    /// is what Forget is for, and it stays available in exactly that state.
    static func allowsReset(isPaired: Bool, isConnected: Bool, isReaching: Bool) -> Bool {
        isPaired && isConnected && !isReaching
    }
}

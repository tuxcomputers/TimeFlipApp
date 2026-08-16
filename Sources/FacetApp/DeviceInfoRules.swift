import Foundation

/// What the Device tab's Info panel says, given what the app knows about a cube.
///
/// A rule with no view and no database in it, as `CategoryRenameRules` and `AppSettingsRules` are: what is stored
/// goes in, the words on screen come out. That matters more here than anywhere else on the tab, because every one of
/// these rows is a sentence about a thing that is not there yet, and "no device" has several meanings that must not
/// be collapsed into one.
///
/// **Three of them, kept apart deliberately** -- the archive's distinction, and its reasoning survives inspection:
///
/// - **Not paired.** The app does not know which cube it is meant to talk to. There is nothing to be disconnected
///   from and nothing to report a battery for.
/// - **Paired but not reachable.** There is a cube, and it cannot be heard from right now. Its name is still known;
///   its battery is not.
/// - **Manual mode.** The app is timing from its own faces and is not reaching for a cube at all. The archive says
///   why this cannot read as "Disconnected": that is true of the cube and no answer at all to why the app is plainly
///   still recording time.
enum DeviceInfoRules {
    /// What the Name row shows.
    ///
    /// The name outlives a great deal -- it survives Forget Device, because forgetting does not un-rename a cube --
    /// but it is only *shown* while there is a pairing for it to belong to. A remembered name against no pairing
    /// would read as a device the app has, and the app has none.
    static func name(isPaired: Bool, deviceName: String?) -> String {
        guard isPaired else { return "Not paired" }
        let name = (deviceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Paired and unnamed is a real state, not a fault: the name is read from the cube on connect and never
        // guessed, so a pairing that has not connected since has nothing to show.
        return name.isEmpty ? "Unknown" : name
    }

    /// What the Connection row shows.
    ///
    /// **Manual mode is asked about first**, ahead of whether anything is paired, because it is the answer to a
    /// different question: the other two describe a cube, and this one describes what the app is doing instead of
    /// using one.
    static func connection(isPaired: Bool, isConnected: Bool, isManualMode: Bool) -> String {
        if isManualMode { return "Manual mode, no device" }
        guard isPaired else { return "Not paired" }
        return isConnected ? "Connected" : "Disconnected"
    }

    /// What the Battery row shows.
    ///
    /// **No cube at all is a different answer from a cube that cannot be heard from**, which is the archive's line
    /// and the reason this is not simply blank. A percentage only ever comes off a live reading: the level is not
    /// stored anywhere, deliberately, since a remembered one is a number that was true at some point nobody can name.
    static func battery(isPaired: Bool, isConnected: Bool, percent: Int?) -> String {
        guard isPaired else { return "Not paired" }
        guard isConnected, let percent else { return "Unknown" }
        return "\(percent)%"
    }

    /// What one of the More rows shows: what the cube reported, or that it has not.
    static func detail(_ reported: String?) -> String {
        let value = (reported ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unknown" : value
    }

    /// Whether the Info values are describing something the app can currently hear.
    ///
    /// What it drives is the colour: live values read in the ordinary label colour, and everything else greys, so
    /// "Not paired" and "Unknown" sit back as the placeholders they are rather than presenting as readings. The
    /// archive greyed them together for that reason and it is worth keeping -- a greyed row is the difference between
    /// a value the app is standing behind and one it is not.
    static func isLive(isConnected: Bool) -> Bool { isConnected }
}

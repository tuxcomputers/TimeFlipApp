import Foundation

/// What a cube says about itself, read off the standard Device Information service (`0x180A`).
///
/// **Every field is optional and they arrive independently**, because that is how four separate characteristic reads
/// actually come back: a cube may answer three of them and not the fourth, and a read that failed is a different thing
/// from a cube that answered with nothing. `nil` means "this one did not arrive", which is what stops it being written
/// over a value an earlier connection did get (`DevicePairingRecorder.recordInfo`).
struct DeviceInfo: Equatable {
    var manufacturer: String?
    var model: String?
    var hardware: String?
    var firmware: String?

    /// Nothing was read at all: a cube with no Device Information service, or one that refused every read.
    var isEmpty: Bool { manufacturer == nil && model == nil && hardware == nil && firmware == nil }
}

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
    ///
    /// **Gated on the pairing exactly as the Name and Battery rows are**, and for the same reason. These four are
    /// stored now, and stored means they outlive the connection that read them -- so an app with no device would
    /// otherwise go on reporting a manufacturer and a firmware version for a cube it no longer has, which is a
    /// stronger claim than any of the other rows are allowed to make.
    static func detail(isPaired: Bool, reported: String?) -> String {
        guard isPaired else { return "Not paired" }
        let value = (reported ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unknown" : value
    }

    /// One Device Information characteristic's bytes as the string it is meant to be, or `nil` if there is nothing
    /// there to show.
    ///
    /// **The trailing NULs are cut before anything else looks at it.** `docs/TimeFlip2 BLE Protocol v4.3.md` Tab. 1
    /// gives each of these a 20-byte field, and a fixed-width field holding a shorter string is padded -- which
    /// decodes as valid UTF-8 with invisible characters on the end, so it compares unequal to itself, sorts oddly and
    /// draws a label wider than the words in it. The archive's `readString` did a bare `String(data:encoding:)` and
    /// got away with it because the cube it measured answered at exact length; that is a fact about one cube's
    /// firmware rather than about the field, so it is not leaned on here.
    ///
    /// `nil` rather than `""` for an empty answer, so "the cube did not say" stays distinguishable all the way to
    /// `DevicePairingRecorder`, which must not write a blank over a value an earlier connection did read.
    static func reported(_ data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let value = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Whether the Info values are describing something the app can currently hear.
    ///
    /// What it drives is the colour: live values read in the ordinary label colour, and everything else greys, so
    /// "Not paired" and "Unknown" sit back as the placeholders they are rather than presenting as readings. The
    /// archive greyed them together for that reason and it is worth keeping -- a greyed row is the difference between
    /// a value the app is standing behind and one it is not.
    static func isLive(isConnected: Bool) -> Bool { isConnected }
}

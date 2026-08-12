import Foundation

/// Whether the app is timing sessions itself rather than following a cube.
///
/// **In memory only, deliberately, and not a setting.** It is not durable configuration: it describes
/// what this launch is doing, and the next launch works it out again from what it finds. Nor is it a
/// mirror of `paired` -- it is *initialised* from `paired` at startup, and will later be turned on and
/// off by things that have nothing to do with pairing (a session the user starts by hand, a device that
/// arrives mid-run). Storing it would create a second answer to "is a device paired" that could
/// disagree with the first, which is exactly what `CLAUDE.md`'s first design rule is about.
///
/// `paired` itself lives in the database and is read from there, at the moment the answer is wanted.
@MainActor
final class ManualMode {
    /// Off until something turns it on.
    private(set) var isOn = false

    private let debugLog: DebugLog?

    init(debugLog: DebugLog?) {
        self.debugLog = debugLog
    }

    /// Turns manual mode on if the app has no device paired, and reports which way it went.
    ///
    /// No device paired means there is nothing to follow and nothing to wait for, so timing by hand is
    /// the only way the app is any use at all. It is not an error state and not a fallback from a failed
    /// connection: an app that has never been paired is in this mode from its first launch.
    ///
    /// An unreadable `paired` setting counts as not paired. Of the two ways to be wrong, sitting in
    /// manual mode with a perfectly good cube on the desk is visible and recoverable, while waiting
    /// forever for a device the app was never paired to looks exactly like a broken app.
    func startIfNoDeviceIsPaired(_ settings: SettingReader) {
        let isPaired = settings.flag("paired", field: "paired") ?? false
        guard !isPaired else {
            debugLog?.record(.mode, "Manual mode: off, a device is paired")
            return
        }
        isOn = true
        debugLog?.record(.mode, "Manual mode: on, no device is paired")
    }
}

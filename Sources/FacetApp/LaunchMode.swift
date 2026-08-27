import Foundation

/// Which of the two things this launch is: an app following a cube, or an app that is its own clock.
///
/// **Decided once, from what the tables say at startup, and then fixed until the process ends.** Pairing a cube
/// during a launch, forgetting one, resetting one, or failing to find one changes what the *device* is; none of them
/// changes which of these two the app is. The way to the other mode is to quit and start the app, which is what the
/// offer dialog has always told people in so many words (`CubeNotFoundAlert.informativeText`).
///
/// **An enum decided at launch, rather than an object with the answer inside it**, and the difference is the whole
/// point of the type. What was here before could be turned on and off from three places on the Device tab and a
/// fourth in `main.swift`, which made "which mode is the app in" a question with two live sources -- this, and the
/// shape of a `TimingReadout.Reading` -- free to disagree with each other for as long as the disagreement went
/// unnoticed. A value with no setter cannot drift from itself. What was a rule somebody had to keep is now a thing
/// that cannot be said.
///
/// **The switching was worth more than it cost only on paper.** Adopting a cube found mid-launch, or falling back to
/// timing by hand when one was forgotten, reads as an app that keeps up. What it actually bought was every screen
/// having to be told the mode had moved -- the menu bar's colour, the Faces tab's click, the reconnect loop's gate,
/// the Device tab's status line -- with nothing to catch the one that was not told. A launch that picks a lane and
/// stays in it is the same app with a class of bug removed.
///
/// ### On the read-at-point-of-use rule
///
/// `CLAUDE.md`'s first rule says a value that lives in the database is read from it every time it is needed, and this
/// reads `paired` once. **That is not this value caching that one.** They are two different facts: `paired` is
/// whether the app has a cube, which the tables own and which this launch may well change; `LaunchMode` is what this
/// launch is doing, which nothing changes after startup by design. The mode is *derived* from `paired` at the one
/// moment the derivation is defined -- launch -- and is its own answer from then on.
///
/// So the two are meant to be able to differ, and the Device tab says so out loud when they do rather than quietly
/// resolving it: see `DeviceInfoRules.connection`, which has a line for a manual launch that has since paired a cube
/// and one for a device launch whose cube has since gone.
enum LaunchMode: Equatable {
    /// There is a cube to follow, and this launch follows it.
    case device

    /// This app is the clock. Either nothing was paired when the app started, or a paired launch could not reach its
    /// cube and was told to stop looking.
    case manual

    /// Whether the app is timing sessions itself. The question nearly every caller actually has.
    var isManual: Bool { self == .manual }

    /// Reads `paired` and settles the mode on it, once.
    ///
    /// **An unreadable `paired` setting counts as not paired.** Of the two ways to be wrong, sitting in manual mode
    /// with a perfectly good cube on the desk is visible and recoverable, while waiting forever for a device the app
    /// was never paired to looks exactly like a broken app.
    ///
    /// The `debug_log` row is written here rather than by the caller, so a launch's mode is always accounted for in
    /// the log whichever way it went -- a run reconstructed from the table should never have to infer it.
    /// `@MainActor` on the method rather than the type: reading the table and writing the log row both are, while
    /// the value itself is a plain enum anything may hold.
    @MainActor
    static func decided(from settings: SettingStore, debugLog: DebugLog?) -> LaunchMode {
        let isCubePaired = settings.flag("paired", field: "paired") ?? false
        let mode: LaunchMode = isCubePaired ? .device : .manual
        debugLog?.record(
            .mode,
            isCubePaired
                ? "Launch mode: device, a device is paired"
                : "Launch mode: manual, no device is paired"
        )
        return mode
    }
}

import Foundation

/// The Settings window's tabs, in the order they are drawn.
///
/// The case name is its title lowercased, and the title is derived from the case rather than written
/// out beside it. That is the whole point of the shape: a tab whose name in code says one thing while
/// its label on screen says another is a trap that costs a bug to find, and it is avoidable by never
/// letting the two be written down separately.
///
/// **Faces first and Device last**, which is the previous app's order turned round. It put the device first, on the
/// reading that a cube is what the app is about; the work is where the time is, and Faces is the tab this window
/// opens on every time (see `SettingsWindowController.tabOnOpen`), so it should also be the tab it opens *at* rather
/// than one along from the first. Device is the tab somebody visits when something is wrong with the cube or when
/// setting it up, which is rarely, so it sits at the end where a setup tab belongs.
///
/// It matches the order the work is being done in as well: manual mode across every tab first, the device after
/// (see `docs/rebuild.md`).
///
/// Empty for now. Each case is a name and a pane to hang content on, and nothing else yet.
enum SettingsTab: String, CaseIterable {
    /// Which category each face is timing, and the clock for the one in use.
    case faces
    /// The activities time is recorded against.
    case categories
    /// What the recorded time adds up to.
    case report
    /// The app's own preferences, as opposed to the device's.
    case app
    /// The device itself: what it is, how it is set up, what it is doing.
    case device

    /// The tab's visible label.
    var title: String { rawValue.capitalized }

    /// The accessibility identifier of the tab's pane, which is how a script confirms it is looking
    /// at the right one. Kebab-case, matching every other identifier in the app.
    var paneIdentifier: String { "settings-pane-\(rawValue)" }
}

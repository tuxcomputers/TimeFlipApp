import AppKit

/// A section of a Settings tab that folds away.
///
/// **What this exists for is one rule: opening Settings shows every section as it is built, whatever it was left as.**
/// The panes are made once and reused for the life of the launch, so without this a fold survives the window that made
/// it -- and the second open shows a tab arranged by something the user did minutes ago and has no reason to remember.
/// That is not a setting they chose; it is a gesture, and a gesture does not outlive the window it was made in.
///
/// **Each section owns what its default is, rather than the reset naming it.** A list of "put More back to closed" at
/// the call site would be a second copy of a fact the section already holds, and the two would part company the first
/// time a default changed -- the same two-answers problem the first rule in `CLAUDE.md` is about, in miniature.
///
/// **Conformers are found by walking the view tree**, not by being listed anywhere
/// (`SettingsWindowController.restoreDefaultSectionStates`). Adding a collapsible group to any tab is therefore the
/// whole of adding it: nothing has to be told, which is what keeps this true of "every collapsible group the app
/// grows" rather than of the three that existed when it was written.
@MainActor
protocol CollapsibleSection: AnyObject {
    /// Puts the section back to the state it is built in.
    ///
    /// Silent: this is not the user folding anything, so it must not reach `onToggle` and must not write a `debug_log`
    /// row. A reset that narrated itself would fill the log with folds nobody made, on every single open.
    func restoreDefaultState()
}

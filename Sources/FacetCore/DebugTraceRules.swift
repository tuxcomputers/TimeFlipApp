import Foundation

/// The `debug` setting as values: whether the trace is being gathered, and which folder it is kept in.
///
/// **The folder is stored with a leading `~` and expanded at the moment it is used.** A stored absolute path names
/// one machine's home directory, and a database is copied between machines and rebuilt from the DDL by the test
/// suite, so the expansion belongs at the read rather than at the write.
///
/// **And the seeded default is stored as nothing at all**, because the folder it means is different on each
/// platform and the DDL is shared. Empty resolves to `defaultDirectory` here and to
/// `DatabaseBootstrap.debugDatabaseURL(in: nil)` at the file, both of which ask `FileManager` rather than naming
/// a path. See `defaultDirectory`.
///
/// **What the trace is called is not here**, and is not a setting either: `DatabaseBootstrap.debugDatabaseURL(in:)`
/// names the file, so the folder is the only part anybody chooses.
package enum DebugTraceRules {
    package static let setting = "debug"
    package static let enabledField = "enabled"
    package static let directoryField = "directory"

    /// The seeded `enabled` (`database/011_setting.sql`), which is what a database missing the row means here.
    ///
    /// **Off**: the trace is what somebody turns on while something is being looked into, so a fresh install is
    /// quiet until asked.
    package static let defaultEnabled = false

    /// The folder the trace goes in when the setting names none: the one the app already keeps its databases in, so
    /// a database that never had this row and one seeded today put the trace in the same place.
    ///
    /// **Asked rather than written down, because the answer is not the same on both platforms.**
    /// `~/Library/Application Support/Facet` on macOS and `~/.local/share/Facet` where the XDG layout applies, and
    /// `FileManager` is what knows which. That is also why `database/011_setting.sql` seeds this as an empty string
    /// rather than a path: one DDL serves both platforms, so it cannot carry either answer.
    ///
    /// In the stored form, with a leading `~`, so it round-trips through `stored(for:)` and can be shown as-is.
    package static var defaultDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return stored(for: base.appendingPathComponent("Facet", isDirectory: true))
    }

    /// The stored path as a folder on disk, with `~` expanded, or `nil` when the setting names nothing.
    ///
    /// `nil` rather than a fallback, so the caller decides what an empty setting means -- which is the same reason
    /// `SettingStore` answers `nil` for a missing row.
    package static func directoryURL(from stored: String) -> URL? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// A folder as it goes into the setting: inside the home directory it is written back with a `~`, the home
    /// directory itself is `~`, and anywhere else is the path as it stands.
    ///
    /// Written out rather than `NSString.abbreviatingWithTildeInPath`, which the corelibs Foundation on Linux does
    /// not have. `expandingTildeInPath`, which `directoryURL` uses to undo this, does exist there.
    package static func stored(for url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// What a copy of the trace is called when it is saved to be sent in: `facet-debug-2026-09-03-22.15.38.sqlite`.
    ///
    /// **Named for the moment the copy was taken**, so two traces from the same person are told apart by their
    /// filenames rather than by asking which is which. Local time, zero-padded 24-hour and POSIX-locale, matching the
    /// console prefix (`DebugLog`), so a machine set to a 12-hour region still writes `22` rather than `10 PM`.
    package static func copyName(at moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "facet-debug-\(formatter.string(from: moment)).sqlite"
    }

    /// The folder as a row shows it, which is the stored form: a `~` is shorter than the path it stands for and is
    /// what somebody recognises as their own home directory.
    package static func display(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDirectory : trimmed
    }
}

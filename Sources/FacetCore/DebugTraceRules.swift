import Foundation

/// The `debug` setting as values: whether the trace is being gathered, and which folder it is kept in.
///
/// **The folder is stored with a leading `~` and expanded at the moment it is used.** A stored absolute path names
/// one machine's home directory, and a database is copied between machines and rebuilt from the DDL by the test
/// suite, so the expansion belongs at the read rather than at the write.
///
/// **What the trace is called is not here**, and is not a setting either: `DatabaseBootstrap.debugDatabaseURL(in:)`
/// names the file, so the folder is the only part anybody chooses.
enum DebugTraceRules {
    static let setting = "debug"
    static let enabledField = "enabled"
    static let directoryField = "directory"

    /// The seeded `enabled` (`database/011_setting.sql`), which is what a database missing the row means here.
    ///
    /// **Off**: the trace is what somebody turns on while something is being looked into, so a fresh install is
    /// quiet until asked.
    static let defaultEnabled = false

    /// The seeded `directory`: the folder the app already keeps its databases in, so a database that never had this
    /// row and one seeded today put the trace in the same place.
    static let defaultDirectory = "~/Library/Application Support/Facet"

    /// The stored path as a folder on disk, with `~` expanded, or `nil` when the setting names nothing.
    ///
    /// `nil` rather than a fallback, so the caller decides what an empty setting means -- which is the same reason
    /// `SettingStore` answers `nil` for a missing row.
    static func directoryURL(from stored: String) -> URL? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// A folder as it goes into the setting: inside the home directory it is written back with a `~`, and anywhere
    /// else it is the path as it stands.
    static func stored(for url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// What a copy of the trace is called when it is saved to be sent in: `facet-debug-2026-09-03-22.15.38.sqlite`.
    ///
    /// **Named for the moment the copy was taken**, so two traces from the same person are told apart by their
    /// filenames rather than by asking which is which. Local time, zero-padded 24-hour and POSIX-locale, matching the
    /// console prefix (`DebugLog`), so a machine set to a 12-hour region still writes `22` rather than `10 PM`.
    static func copyName(at moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "facet-debug-\(formatter.string(from: moment)).sqlite"
    }

    /// The folder as a row shows it, which is the stored form: a `~` is shorter than the path it stands for and is
    /// what somebody recognises as their own home directory.
    static func display(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDirectory : trimmed
    }
}

import AppKit

/// The tag at the far left of the status item, naming which database this launch is recording into.
///
/// A constant of the launch rather than a live reading: `db_type` is written when the database file
/// is created and never changes afterwards, so it is resolved once at startup and every title after
/// that is composed against the same value. Nothing here needs re-reading on a tick.
///
/// Far left, and first in the title, because it qualifies everything to its right. Whatever the rest
/// of the item comes to say -- a category, a running duration -- it is only true of one database, and
/// which one has to be readable in the same glance.
struct DatabaseBadge: Equatable {
    /// The menu bar text. Short: it occupies that space permanently, ahead of everything the item
    /// actually exists to show.
    let text: String
    let color: NSColor
    /// The status item's accessibility label, spelled out, because "PROD" is not a word and the
    /// colour that carries the warning is not available to a screen reader at all.
    let spokenDescription: String

    static func forEnvironment(_ environment: DatabaseEnvironment?) -> DatabaseBadge {
        switch environment {
        case .production:
            // `.labelColor` rather than a hardcoded white: as text in the status item it is resolved
            // against the menu bar's own appearance as it draws, so it stays legible on a light strip
            // as well as a dark one. White only works on one of the two.
            return DatabaseBadge(text: "PROD", color: .labelColor, spokenDescription: "production database")
        case .test:
            // Red, the same attention colour a warning gets, so a test database cannot be mistaken
            // for the real one and a real day's timings recorded into something disposable.
            return DatabaseBadge(text: "TEST", color: .systemRed, spokenDescription: "test database")
        case nil:
            // Also red, and deliberately not "PROD". The database could not be read, so this is the
            // one state where the app does not know where its writes are going -- which is worth more
            // attention than a test database, not less.
            return DatabaseBadge(text: "DB?", color: .systemRed, spokenDescription: "database unknown")
        }
    }
}

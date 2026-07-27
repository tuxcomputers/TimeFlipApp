import Foundation

/// What the menu bar draws for the current face, resolved from the category the `face` table
/// assigns it (see `AppState.categoryActivity`). A snapshot for display -- not a stored record.
struct Activity: Equatable {
    let name: String
    let iconName: String?
    /// The category's `daily_limit` in whole minutes, `0` = no limit. Carried alongside the name
    /// and icon it was resolved with, so the over-limit indicator can't end up reflecting a
    /// different category from the one on screen.
    let limitMinutes: Int
}

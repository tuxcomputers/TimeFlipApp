import Foundation

/// What the menu bar draws for the current face, resolved from the category the `face` table
/// assigns it (see `AppState.categoryActivity`). A snapshot for display -- not a stored record.
struct Activity: Equatable {
    /// The `category.category_id` this was resolved from, so the day's total can be looked up by the
    /// same key the name and limit came from. Carried rather than re-derived from
    /// `AppState.faceCategories` at the point of use: `@Published` publishes in `willSet`, so a
    /// subscriber reading that property back gets the value it is in the middle of replacing.
    let categoryID: Int
    let name: String
    let iconName: String?
    /// The category's `daily_limit` in whole minutes, `0` = no limit. Carried alongside the name
    /// and icon it was resolved with, so the over-limit indicator can't end up reflecting a
    /// different category from the one on screen.
    let limitMinutes: Int
}

import Foundation

/// What the Categories tab writes to the right of an inactive row's Active box.
///
/// A retired category is kept so historical `time_entry` rows still resolve, which means the reason
/// to reinstate one is the history attached to it. Until now a row said nothing about that, and
/// `UN1_category` allows any number of *retired* categories to share a name, so several identical
/// rows could sit in the Inactive list each owning different history, with no way to tell which held
/// the data (see `docs/TODO-features-under-development.md`, "Telling retired namesakes apart").
///
/// That note proposed a `retired_at` column instead, on the grounds that when it was last *used*
/// needed `time_entry`, which had no writer at the time. It has one now
/// (`AppDataStore.convertEligibleEvents`), so the better signal is available and this uses it: when
/// the category last recorded time is what distinguishes two namesakes, where when they were retired
/// need not.
enum CategoryLastUsedText {
    /// The column's caption, in the header row rather than repeated down every cell.
    static let columnTitle = "Last used"

    /// Shown when an inactive category has no recorded time at all. Deliberately not blank: an empty
    /// cell reads as "this has not loaded" or "something is broken", where the interesting fact is
    /// that there is genuinely nothing behind this row -- which for two namesakes is the whole
    /// answer about which one to reinstate. One word, because `columnTitle` supplies the rest of the
    /// sentence: the column reads "Last used / Never".
    static let neverUsed = "Never"

    /// `nil` means draw nothing at all.
    ///
    /// Active rows get nothing. The date is a fact about a retired row, and an active category is
    /// one being used now, so the column would be noise on every row that matters day to day. That
    /// is also why the header carries `columnTitle` only above the Inactive list: captioning the
    /// Active one would label a column that is empty by definition.
    static func label(isActive: Bool, lastUsed: Date?, formatter: DateFormatter = defaultFormatter) -> String? {
        guard !isActive else { return nil }
        guard let lastUsed else { return neverUsed }
        return formatter.string(from: lastUsed)
    }

    /// Localised rather than the app's usual fixed `yyyy-MM-dd HH:mm`. That format exists for debug
    /// output and log correlation, where it is read next to timestamps in the same shape; this is a
    /// sentence in the UI, read by whoever is using the app.
    static let defaultFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

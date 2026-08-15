import Foundation

/// The "Last used" column on the Inactive list: what it is called, and what each row says.
///
/// **Copied from the previous app as it stands**, reasoning included, because every part of it is a decision rather
/// than a formatting detail.
enum CategoryLastUsedText {
    /// The column's caption, in the header row rather than repeated down every cell.
    static let columnTitle = "Last used"

    /// Shown when a retired category has no recorded time at all. Deliberately not blank: an empty cell reads as
    /// "this has not loaded" or "something is broken", where the interesting fact is that there is genuinely nothing
    /// behind this row -- which for two namesakes is the whole answer about which one to bring back. One word,
    /// because `columnTitle` supplies the rest of the sentence: the column reads "Last used / Never".
    static let neverUsed = "Never"

    /// `nil` means draw nothing at all.
    ///
    /// Active rows get nothing. The date is a fact about a retired row, and an active category is one being used now,
    /// so the column would be noise on every row that matters day to day. That is also why the caption appears above
    /// the Inactive list only: captioning the Active one would label a column that is empty by definition.
    static func label(isActive: Bool, lastUsed: Date?, formatter: DateFormatter = defaultFormatter) -> String? {
        guard !isActive else { return nil }
        guard let lastUsed else { return neverUsed }
        return formatter.string(from: lastUsed)
    }

    /// Localised rather than the app's usual fixed `yyyy-MM-dd HH:mm`. That format exists for debug output and log
    /// correlation, where it is read next to timestamps in the same shape; this is a sentence in the interface, read
    /// by whoever is using the app.
    static let defaultFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

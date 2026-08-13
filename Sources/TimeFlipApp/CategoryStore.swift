import AppKit

/// A category as something showing it needs it: the name, the icon and colour it is drawn with, and
/// whether it is still in use.
struct CategoryRecord: Equatable {
    let id: Int
    let name: String
    /// The artwork's filename, or `nil` for the None icon (`icon_id` 0) -- a sentinel row rather than a
    /// bundled asset, so there is nothing to draw.
    let iconName: String?
    /// `nil` for the None colour (`colour_id` 0), which has no hex of its own.
    let colour: NSColor?
    /// From the colour's own row: `true` for colours dark enough to swallow a black glyph, so the icon
    /// on top of them is drawn white instead.
    let usesWhiteLines: Bool

    /// The budget for this category's tracked time in one day, in minutes. `0` disables it, which is what every
    /// category starts with.
    ///
    /// **Stored, and enforced by nothing yet.** What reads it is the over-limit colouring and the pause the previous
    /// app sent the cube when a category was spent, neither of which this app has rebuilt. Editable ahead of that
    /// deliberately: the column belongs on the tab with the rest of what a category is, and a value already set is
    /// what the enforcement will find when it arrives.
    let dailyLimitMinutes: Int
    /// `false` once retired: the row stays so historical `time_entry` rows keep resolving, but it drops
    /// out of the lists a category can be picked from.
    let isActive: Bool
}

extension CategoryRecord {
    /// The order a list of categories is shown in. Carried over from the previous app unchanged, because
    /// every part of it is there for a reason that still holds.
    ///
    /// Names that are **entirely** a number come first, in numeric order, then everything else as text. A
    /// plain text sort interleaves them by digit -- 1, 10, 11, 2, 20, 3 -- which reads as broken the moment
    /// categories are numbered.
    ///
    /// The text comparison is `localizedStandardCompare`, the same Finder-style ordering that puts "ABC-2"
    /// before "ABC-10", so a number buried in a name comes out sensibly too, and case and accents do not
    /// decide anything.
    ///
    /// A name too long to fit an `Int` falls back to text: an overflowed number is not a number this can
    /// order.
    static func displayOrder(_ lhs: CategoryRecord, _ rhs: CategoryRecord) -> Bool {
        switch (Int(lhs.name), Int(rhs.name)) {
        case let (lhsValue?, rhsValue?) where lhsValue != rhsValue:
            return lhsValue < rhsValue
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            // Either both are text, or both are the same number written differently ("1" / "01").
            // `localizedStandardCompare` compares digit runs numerically, so that second case comes back
            // `.orderedSame` and drops through to the id tiebreak below.
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            // Two rows can legitimately hold one name -- a category created alongside retired namesakes --
            // so the tie is broken rather than left to an unstable sort.
            return lhs.id < rhs.id
        }
    }
}

/// The `category` table: reads and the writes that go with them.
///
/// One read per ask and nothing kept -- see `SettingReader` for the rule. Writes report whether they
/// took, and never work around a refusal: the unique index on an active name is the last thing standing
/// between a typo and two identical categories, so a caller that meant to insert has to hear "no".
@MainActor
final class CategoryStore {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    // MARK: - reading

    /// The categories that can be assigned to a face, in `CategoryRecord.displayOrder`.
    ///
    /// Which rows appear is inherited from the previous app, because it is what the list on screen meant:
    ///
    /// - `active = 1`: a retired category is not offered.
    /// - `category_id >= 1`: id 0 is the seeded *Unassigned* row, which is what a face points at when it
    ///   has no category. A placeholder, not something to choose.
    ///
    /// **The order is not the query's.** The `ORDER BY` here only makes the rows arrive in a fixed order
    /// rather than whatever sqlite feels like, and the display order is applied on top -- because it is a
    /// rule sqlite cannot express: numeric names ahead of text, `localizedStandardCompare` for the rest
    /// (`COLLATE NOCASE` folds ASCII only, and would put an accented name after `Z` and "Task 10" before
    /// "Task 2"), and an id tiebreak.
    func activeCategories() -> [CategoryRecord] {
        read(where: "c.active = 1 AND c.category_id >= 1", order: "c.category_id")
            .sorted(by: CategoryRecord.displayOrder)
    }

    /// The retired categories, in the same display order as the active ones.
    ///
    /// Kept rather than deleted, which is what this list is a view of: a retired row stays so every `time_entry`
    /// recorded against it still resolves, and it drops out of the lists a category can be picked from. Id 0 is
    /// excluded for the same reason as above -- *Unassigned* is a placeholder, not a category anybody retired.
    func inactiveCategories() -> [CategoryRecord] {
        read(where: "c.active = 0 AND c.category_id >= 1", order: "c.category_id")
            .sorted(by: CategoryRecord.displayOrder)
    }

    /// Every category holding `name`, whatever state it is in, **the active one first**.
    ///
    /// `COLLATE NOCASE`, so "meeting" finds "Meeting" -- which is the point of looking at all: the unique
    /// index that bars a second active namesake is case-insensitive too, so a check that was not would
    /// pass a name the insert then refuses.
    ///
    /// Every match rather than the first, because how many there are changes the answer (see
    /// `CategoryCreateRules`). At most one can be active, and the ordering here is what lets the rules
    /// decide from `matches.first` alone.
    func matching(name: String) -> [CategoryRecord] {
        guard !name.isEmpty else { return [] }
        return read(
            where: "c.category_name = ? COLLATE NOCASE",
            order: "c.active DESC, c.category_id ASC",
            bind: [name]
        )
    }

    /// One category by id, whatever state it is in.
    ///
    /// Retired ones included on purpose: this answers "what is this row", and the caller that asked -- a
    /// face holding a category, a session timing one -- needs the answer even if the category has since
    /// been retired out of the pickable list.
    func category(id: Int) -> CategoryRecord? {
        read(where: "c.category_id = \(id)", order: "c.category_id").first
    }

    private func read(where condition: String, order: String, bind: [String] = []) -> [CategoryRecord] {
        var categories: [CategoryRecord] = []
        connection.forEachRow(
            """
            SELECT c.category_id, c.category_name, i.icon_name, l.device_hex, l.white_lines, c.active,
                   c.daily_limit
              FROM category c
              JOIN icon i ON i.icon_id = c.icon_id
              JOIN colour l ON l.colour_id = c.colour_id
             WHERE \(condition)
             ORDER BY \(order);
            """,
            bind: bind
        ) { row in
            let iconName = row.string(2)
            categories.append(
                CategoryRecord(
                    id: Int(row.int(0)),
                    name: row.string(1) ?? "",
                    // The None row is named "None" rather than left null, so the name is the sentinel.
                    iconName: iconName == "None" ? nil : iconName,
                    colour: row.string(3).flatMap(NSColor.init(hex:)),
                    usesWhiteLines: row.bool(4),
                    dailyLimitMinutes: Int(row.int(6)),
                    isActive: row.bool(5)
                )
            )
        }
        return categories
    }

    // MARK: - writing

    /// Inserts a category with no icon and no colour, returning its new id, or `nil` if the insert was
    /// refused.
    ///
    /// No icon and no colour on purpose: a new category is named first and dressed afterwards, and
    /// picking either for the user would be inventing a choice they did not make. Both columns default to
    /// the None rows.
    ///
    /// The insert is unguarded, so `UN1_category` -- the unique index over active names -- is what
    /// refuses a duplicate. That is deliberate: the check in `CategoryCreateRules` and the index say the
    /// same thing, and if they ever disagree the index is the one that is right.
    func insert(name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        guard connection.execute(
            "INSERT INTO category (category_name, icon_id, colour_id) VALUES (?, 0, 0);",
            bind: [name]
        ) else {
            return nil
        }
        return connection.lastInsertedRowID
    }

    /// Brings a retired category back, keeping every `time_entry` already attached to it.
    ///
    /// Can be refused, and the refusal matters: only one active category may hold a name, so a retired
    /// row whose name has since been taken by an active one cannot come back under it.
    func reactivate(id: Int) -> Bool {
        setActive(id: id, true)
    }

    /// Retires a category or brings it back.
    ///
    /// The retired row stays, which is the point of the column rather than a delete: every `time_entry` recorded
    /// against it still has to resolve. What changes is that it drops out of the lists a category can be picked
    /// from.
    ///
    /// Reinstating can be refused, by the unique index over active names rather than by a check here: only one
    /// active category may hold a name. Retiring cannot be refused by the database, so a `false` from that
    /// direction means the id is not there.
    func setActive(id: Int, _ isActive: Bool) -> Bool {
        // The row count as well as the step, so a category that is not there reads as refused rather than as
        // done. A name collision is refused by the index and fails the step; a missing id changes nothing and
        // would otherwise pass.
        connection.execute(
            "UPDATE category SET active = \(isActive ? 1 : 0) WHERE category_id = \(id);"
        ) && connection.changes > 0
    }

    /// Sets a category's daily budget, in minutes, and reports whether it took.
    ///
    /// The value is bounded by the caller (`CategoryEditRules.dailyLimitMinutes`) rather than here: what a sensible
    /// limit is belongs with the rest of the rules, and this writes what it is given.
    func setDailyLimit(id: Int, minutes: Int) -> Bool {
        connection.execute(
            "UPDATE category SET daily_limit = \(minutes) WHERE category_id = \(id);"
        ) && connection.changes > 0
    }
}

extension NSColor {
    /// Parses `"#rrggbb"` (or `"rrggbb"`) into an opaque sRGB colour. `nil` for anything that is not
    /// exactly six hex digits, which includes the None colour's `NULL` hex.
    ///
    /// sRGB explicitly: the same six digits mean different colours in different spaces, and these are
    /// the values the device is eventually told to light its LED with.
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

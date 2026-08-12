import AppKit

/// A category as something showing it needs it: the name, and the icon and colour it is drawn with.
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
}

/// Reads the `category` table. One read per ask, and nothing kept -- see `SettingReader` for the rule.
@MainActor
final class CategoryReader {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// The categories that can be assigned to a face, in the order they are shown.
    ///
    /// Three things about this query are inherited deliberately from the previous app, because they are
    /// what the list on screen meant:
    ///
    /// - `active = 1`: a retired category stays in the table so old `time_entry` rows keep resolving, but
    ///   drops out of the lists you can assign from.
    /// - `category_id >= 1`: id 0 is the seeded *Unassigned* row, which is what a face points at when it
    ///   has no category. It is a placeholder, not something to choose.
    /// - `ORDER BY category_id`: insertion order. The old query had no `ORDER BY` at all and so came back
    ///   in rowid order, which is the same thing -- said out loud here, because relying on the absence of
    ///   an `ORDER BY` is relying on sqlite not to change its mind.
    ///
    /// The icon and colour arrive by join. The previous app read both reference tables into memory once
    /// per launch and matched them up in Swift; one statement gets the same three rows' worth of data at
    /// the moment it is needed, which is what the database rule asks for anyway.
    func activeCategories() -> [CategoryRecord] {
        var categories: [CategoryRecord] = []
        connection.forEachRow(
            """
            SELECT c.category_id, c.category_name, i.icon_name, l.device_hex, l.white_lines
              FROM category c
              JOIN icon i ON i.icon_id = c.icon_id
              JOIN colour l ON l.colour_id = c.colour_id
             WHERE c.active = 1 AND c.category_id >= 1
             ORDER BY c.category_id;
            """
        ) { row in
            let iconName = row.string(2)
            categories.append(
                CategoryRecord(
                    id: Int(row.int(0)),
                    name: row.string(1) ?? "",
                    // The None row is named "None" rather than left null, so the name is the sentinel.
                    iconName: iconName == "None" ? nil : iconName,
                    colour: row.string(3).flatMap(NSColor.init(hex:)),
                    usesWhiteLines: row.bool(4)
                )
            )
        }
        return categories
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

import AppKit

/// One colour a category can be drawn in: the id stored against it, its name, the colour itself, and whether an icon
/// on top of it has to be drawn white.
struct ColourRecord: Equatable {
    let id: Int
    /// The name from the table, e.g. `Navy`. Shown beside the swatch, since a square of colour is not a thing
    /// somebody can say out loud or search for.
    let name: String
    /// The row's `device_hex`, parsed. Not optional: a row without a usable hex is not offered at all (see `all()`).
    let colour: NSColor
    /// `true` for colours dark enough to swallow a black glyph, straight from the row's `white_lines`.
    let usesWhiteLines: Bool
}

/// The `colour` table: the palette a category can be given.
///
/// A **reference table** by the standing exception in `CLAUDE.md`, exactly as `IconStore` is: seeded by the DDL, never
/// written by the app, and fixed for the life of a launch. Read per ask anyway, for the same reason -- the only thing
/// that asks is a picker somebody has just opened, and a read that costs nothing needs no exception written next to it.
@MainActor
final class ColourStore {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// Every colour that can be picked, in `colour_id` order.
    ///
    /// **That order is the palette's own**, not alphabetical: the ids run Red, Maroon, Brown, Tan, Orange ...
    /// (`database/005_colour.sql`), which is a wheel somebody arranged, and sorting it by name would scatter the
    /// shades that belong beside each other.
    ///
    /// Two kinds of row are left out, both the archive's rule and both for the same reason -- there is no square to
    /// draw:
    ///
    /// - Id 0 is the *None* sentinel, which is how a category with no colour is stored rather than a colour to choose.
    /// - Any row whose `device_hex` is missing or unparseable. A palette entry that cannot say what colour it is has
    ///   nothing to offer a picker, and guessing one would put a colour on screen the device would never light.
    ///
    /// Clearing a colour is done by re-clicking the one already chosen -- see `CategoryEditRules.colourSelection`,
    /// which is what lets a list with no None row still unset one.
    func all() -> [ColourRecord] {
        var colours: [ColourRecord] = []
        connection.forEachRow(
            "SELECT colour_id, colour_name, device_hex, white_lines FROM colour WHERE colour_id >= 1 ORDER BY colour_id;"
        ) { row in
            guard let colour = row.string(2).flatMap(NSColor.init(hex:)) else { return }
            colours.append(
                ColourRecord(
                    id: Int(row.int(0)),
                    name: row.string(1) ?? "",
                    colour: colour,
                    usesWhiteLines: row.bool(3)
                )
            )
        }
        return colours
    }
}

import Foundation

/// One icon a category can be drawn with: the id stored against it, the artwork's filename, and a name for a human.
struct IconRecord: Equatable {
    let id: Int
    /// The SVG's filename in `Resources/Icons`, e.g. `ic_admin`.
    let fileName: String
    /// The filename made readable, e.g. `Admin`. See `IconStore.displayName`.
    let name: String
}

/// The `icon` table: the artwork a category can be given.
///
/// A **reference table** by the standing exception in `CLAUDE.md`: seeded by the DDL, never written by the app, and
/// fixed for the life of a launch, so it would be allowed to be read once and held. It is read per ask anyway, since
/// the only thing that asks is a picker somebody opened, and a read that costs nothing needs no exception written
/// next to it.
@MainActor
final class IconStore {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// Every icon that can be picked, by id.
    ///
    /// Id 0 is left out: it is the *None* sentinel rather than a bundled asset, so there is nothing to draw in a
    /// cell for it. Clearing an icon is done by re-clicking the one already chosen -- see
    /// `CategoryEditRules.iconSelection`, which is what makes a grid with no None cell able to unset one.
    func all() -> [IconRecord] {
        var icons: [IconRecord] = []
        connection.forEachRow("SELECT icon_id, icon_name FROM icon WHERE icon_id >= 1 ORDER BY icon_id;") { row in
            let fileName = row.string(1) ?? ""
            icons.append(IconRecord(id: Int(row.int(0)), fileName: fileName, name: Self.displayName(for: fileName)))
        }
        return icons
    }

    /// `ic_deep_work` as `Deep Work`: the filename is what the table holds and what the bundle is searched by, and it
    /// is not a thing to show anybody. Copied from the previous app, which had the same two names for one icon.
    static func displayName(for fileName: String) -> String {
        let trimmed = fileName.replacingOccurrences(of: "ic_", with: "")
        return trimmed
            .split(separator: "_")
            .map { $0.lowercased().prefix(1).uppercased() + $0.lowercased().dropFirst() }
            .joined(separator: " ")
    }
}

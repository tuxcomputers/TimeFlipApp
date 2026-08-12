import Foundation

/// Reads the `setting` table. One read per ask, every ask.
///
/// Nothing here caches: per the first design rule in `CLAUDE.md`, a value that lives in the database is
/// read from the database at the moment it is needed, so asking twice means two reads. The connection
/// is shared and held open (see `DatabaseConnection`), which is a different thing from holding a value.
///
/// Read-only, so far. Nothing in the app writes a setting yet; when something does, this gains a writer
/// rather than the app gaining a second way to reach the table.
@MainActor
final class SettingReader {
    private let connection: DatabaseConnection

    init(connection: DatabaseConnection) {
        self.connection = connection
    }

    /// A setting's value as a JSON object, or `nil` if there is no such row and for anything that will
    /// not parse.
    ///
    /// JSON because `setting` is one generic key/value table serving settings of every shape (see
    /// `database/011_setting.sql`), so the column holds an object rather than a bare value.
    func json(_ name: String) -> [String: Any]? {
        var value: String?
        connection.forEachRow(
            "SELECT setting_value FROM setting WHERE setting_name = ?;",
            bind: [name]
        ) { row in
            value = row.string(0)
        }
        guard let data = value?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// One field of a setting, as a boolean: `flag("paired", field: "paired")`.
    func flag(_ name: String, field: String) -> Bool? {
        json(name)?[field] as? Bool
    }

    /// One field of a setting, as text: `string("db_type", field: "type")`.
    func string(_ name: String, field: String) -> String? {
        json(name)?[field] as? String
    }
}

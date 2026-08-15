import Foundation

/// The `setting` table: reads, and the writes the App tab makes.
///
/// Nothing here caches: per the first design rule in `CLAUDE.md`, a value that lives in the database is
/// read from the database at the moment it is needed, so asking twice means two reads. The connection
/// is shared and held open (see `DatabaseConnection`), which is a different thing from holding a value.
///
/// **One row holds a whole JSON object**, so a write is a read, one field replaced, and a write back.
/// That is not a cache: nothing is held between the two, and the alternative -- writing the object the
/// caller happens to know about -- would drop every field it did not (`daily_reset_time` carries a
/// `minute` beside its `hour`).
@MainActor
final class SettingStore {
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

    /// One field of a setting, as a whole number:
    /// `integer("fetch_history_interval_seconds", field: "seconds")`.
    ///
    /// `nil` rather than a default for a missing row or a value that is not a number, so the caller can
    /// decide what absence means. What a sensible fallback is depends entirely on the setting, and it is
    /// never this type's to guess.
    func integer(_ name: String, field: String) -> Int? {
        json(name)?[field] as? Int
    }

    // MARK: - writing

    /// One field of a setting, written and then **read back to prove it took**.
    ///
    /// The read-back is the point rather than a belt-and-braces extra: a write that reports success and did not
    /// happen leaves the window showing a value the table does not hold, which is the two-answers problem the first
    /// design rule exists to prevent. So the answer to "did that work" comes from asking the table, not from the
    /// statement's return code -- and a caller that gets `false` has something to tell somebody.
    ///
    /// Every other field of the row survives, the object being read first and one key replaced: `daily_reset_time`
    /// carries a `minute` that no control on the App tab touches, and a write that dropped it would quietly change
    /// the rollover as well.
    ///
    /// `false` for a missing row too. This does not insert: the rows are seeded by the DDL, so one that is not there
    /// is a database that has not been brought up to date rather than a setting waiting to be created, and inventing
    /// it here would hide that.
    func write(_ name: String, field: String, _ value: Int) -> Bool {
        write(name, field: field, any: value) && integer(name, field: field) == value
    }

    /// The same, for a flag.
    func write(_ name: String, field: String, _ value: Bool) -> Bool {
        write(name, field: field, any: value) && flag(name, field: field) == value
    }

    private func write(_ name: String, field: String, any value: Any) -> Bool {
        guard var object = json(name) else { return false }
        object[field] = value
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return connection.execute(
            "UPDATE setting SET setting_value = ? WHERE setting_name = ?;",
            bind: [text, name]
        ) && connection.changes > 0
    }
}

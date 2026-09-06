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

    /// The same, for text.
    ///
    /// **Written as an empty string rather than removed** when it is being cleared, which is what signing out of
    /// Google does. `database/011_setting.sql` keeps `calendar_id`, `calendar_name` and `client_id` in the same row,
    /// so the key has to survive for the read-back to have something to confirm.
    func write(_ name: String, field: String, _ value: String) -> Bool {
        write(name, field: field, any: value) && string(name, field: field) == value
    }

    /// Several fields of one setting, written in **one** update and read back together.
    ///
    /// **For fields that are only true as a set.** The four double-tap registers go to the cube as a single command
    /// and describe nothing on their own, so a row left holding three new numbers and one old one would describe a
    /// cube that has never existed. Calling the single-field write above four times can stop half way and leave
    /// exactly that; this cannot, the whole object being replaced once.
    ///
    /// The archive merged the same four in one go (`AppDataStore.saveDoubleTapParameters`), for the same reason.
    ///
    /// `false` if any one of them did not take, and the read-back is per field rather than on the object: what makes
    /// the answer worth having is that it asked the table, and asking it about the object it was just handed would
    /// only prove `JSONSerialization` is deterministic.
    func write(_ name: String, fields: [String: Value]) -> Bool {
        guard var object = json(name) else { return false }
        for (field, value) in fields { object[field] = value.stored }
        guard store(object, as: name) else { return false }
        return fields.allSatisfy { field, value in
            switch value {
            case .number(let number): return integer(name, field: field) == number
            case .flag(let flag): return self.flag(name, field: field) == flag
            case .text(let text): return string(name, field: field) == text
            }
        }
    }

    /// One field's value, for `write(_:fields:)`.
    ///
    /// **A case per type rather than `Any`**, so the read-back compares like with like. Through `Any` it could not:
    /// `JSONSerialization` hands both `true` and `1` back as an `NSNumber`, and those two compare equal -- so a row
    /// that came back holding `1` where a flag was asked for would read as confirmed.
    enum Value: Equatable {
        case number(Int)
        case flag(Bool)
        case text(String)

        fileprivate var stored: Any {
            switch self {
            case .number(let number): return number
            case .flag(let flag): return flag
            case .text(let text): return text
            }
        }
    }

    private func write(_ name: String, field: String, any value: Any) -> Bool {
        guard var object = json(name) else { return false }
        object[field] = value
        return store(object, as: name)
    }

    private func store(_ object: [String: Any], as name: String) -> Bool {
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

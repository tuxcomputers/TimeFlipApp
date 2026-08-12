import Foundation
import SQLite3

/// Reads the `setting` table. One read per ask, every ask.
///
/// The connection is held; the **values are not**. That distinction is the whole design: per the first
/// design rule in `CLAUDE.md`, a value that lives in the database is read from the database at the
/// moment it is needed, so nothing here caches, and asking twice means two reads. Holding the
/// connection open is not a cache -- it is the absence of a syscall bill for opening the same file
/// over and over.
///
/// Read-only, so far. Nothing in the app writes a setting yet; when something does, this gains a
/// writer rather than the app gaining a second way to reach the table.
@MainActor
final class SettingReader {
    /// The handle, in its own object so it closes when the reader goes away. A `@MainActor` class's
    /// `deinit` cannot touch its own non-Sendable properties, which is a compile error rather than a
    /// subtlety (see `DebugLog` for the same shape and the same reason).
    private final class Connection {
        var db: OpaquePointer?

        deinit {
            sqlite3_close(db)
        }
    }

    private let connection = Connection()

    init(databaseURL: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        connection.db = handle
    }

    /// A setting's value as a JSON object, or `nil` if there is no such row and for anything that will
    /// not parse.
    ///
    /// JSON because `setting` is one generic key/value table serving settings of every shape (see
    /// `database/011_setting.sql`), so the column holds an object rather than a bare value.
    func json(_ name: String) -> [String: Any]? {
        guard let db = connection.db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT setting_value FROM setting WHERE setting_name = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0),
              let data = String(cString: value).data(using: .utf8)
        else {
            return nil
        }
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

/// sqlite's own "copy this string" sentinel, which the C macro defines as `((sqlite3_destructor_type)
/// -1)` and so does not survive into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

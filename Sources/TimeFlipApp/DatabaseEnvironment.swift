import Foundation
import SQLite3

/// Which database this launch is recording into.
///
/// Read from the `db_type` setting row rather than inferred from the file's name. The app always
/// opens `appdata.sqlite`, and pointing a session at a throwaway copy is a matter of what that name
/// resolves to -- so the path says nothing, while the row travels with the file itself and stays
/// right however the file was reached.
enum DatabaseEnvironment: String, CaseIterable {
    /// The real database, holding real timings.
    case production
    /// A copy, so a test run cannot write into the real one.
    case test

    /// Reads `db_type` from a database that already exists.
    ///
    /// Returns `nil` for anything unexpected -- no file, no row, a value naming neither environment
    /// -- rather than falling back to `.production`. A default here would answer "which database am
    /// I writing to" with the reassuring option at exactly the moment the answer is unknown, and the
    /// whole point of asking is to catch the case where it isn't the one you assumed.
    static func read(from databaseURL: URL) -> DatabaseEnvironment? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle
        else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT setting_value FROM setting WHERE setting_name = 'db_type';",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return parse(settingValue: String(cString: value))
    }

    /// `{"type":"test"}` -> `.test`.
    ///
    /// Separate from the read so the value's shape can be pinned down without a database. The column
    /// holds JSON because `setting` is one generic key/value table for settings of every shape (see
    /// `database/011_setting.sql`), not because this particular setting needs a structure.
    static func parse(settingValue: String) -> DatabaseEnvironment? {
        guard let data = settingValue.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return nil
        }
        return DatabaseEnvironment(rawValue: type.lowercased())
    }
}

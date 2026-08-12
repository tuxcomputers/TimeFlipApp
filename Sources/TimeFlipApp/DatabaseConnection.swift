import Foundation
import SQLite3

/// The app's connection to the database, and the sqlite plumbing every reader would otherwise repeat.
///
/// Held open for the life of the app. That is not a cache: no value read through it is kept, per the
/// first design rule in `CLAUDE.md`. What is avoided is opening the same file again for every question.
///
/// One type per table sits on top of this (`SettingReader`, `CategoryStore`), rather than one
/// object growing a method per query. The alternative has been tried in this project: a single store
/// that knew every table ended up sixteen hundred lines long.
///
/// `DebugLog` keeps its own connection deliberately, and writes through it -- see the reasoning there.
@MainActor
final class DatabaseConnection {
    /// The handle, in its own object so it closes when the connection goes away: a `@MainActor` class's
    /// `deinit` cannot touch its own non-Sendable properties.
    private final class Handle {
        var db: OpaquePointer?

        deinit {
            sqlite3_close(db)
        }
    }

    private let handle = Handle()

    init(databaseURL: URL) {
        var db: OpaquePointer?
        // Read/write, but not `CREATE`: the file is brought into being and brought up to the schema by
        // `DatabaseBootstrap`, before this is opened. A connection that could create it would quietly
        // make an empty database when the path was wrong, instead of failing where it can be seen.
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        handle.db = db
        // Off by default in sqlite and per-connection, so this one needs it too: an insert naming an
        // icon or colour that does not exist should fail here rather than sit in the table pointing at
        // nothing.
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    }

    /// One row of a result set. Valid only for the duration of the call it is handed to.
    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        /// `nil` for a `NULL` column, which is a real answer here: a colour with no hex, an icon with no
        /// name. Callers that treat those as absent rather than empty depend on the difference.
        func string(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        func bool(_ column: Int32) -> Bool {
            sqlite3_column_int64(statement, column) != 0
        }
    }

    /// Runs `sql`, handing each row to `read` in turn. Does nothing if the statement will not prepare or
    /// the database never opened -- a reader's job is to answer or not, not to crash the app it is in.
    func forEachRow(_ sql: String, bind: [String] = [], read: (Row) -> Void) {
        guard let db = handle.db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            read(Row(statement: statement))
        }
    }

    /// Runs a statement that changes something. `true` if it ran.
    ///
    /// The caller decides what a failure means, which is why this reports rather than logs: an insert
    /// refused by a unique index is a thing to tell the user about, and a caller that only saw `false`
    /// with a line in a log somewhere could not.
    @discardableResult
    func execute(_ sql: String, bind: [String] = []) -> Bool {
        guard let db = handle.db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// How many rows the last statement on this connection changed.
    ///
    /// Needed because "the statement ran" and "the statement did something" are different questions, and
    /// sqlite answers the first one for both. An `UPDATE ... WHERE locked = 0` against a locked row completes
    /// perfectly happily having changed nothing, so a caller that reported success from the step alone would
    /// tell the app a write took when it was refused.
    var changes: Int {
        guard let db = handle.db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// The row id the last insert on this connection produced, and `nil` if that insert changed nothing.
    ///
    /// Read straight after the insert, on the same connection, or it is somebody else's row id.
    var lastInsertedRowID: Int? {
        guard let db = handle.db, sqlite3_changes(db) > 0 else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }
}

/// sqlite's own "copy this string" sentinel, which the C macro defines as `((sqlite3_destructor_type)
/// -1)` and so does not survive into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

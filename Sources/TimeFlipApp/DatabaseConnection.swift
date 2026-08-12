import Foundation
import SQLite3

/// One read-only connection to the database, and the sqlite plumbing every reader would otherwise
/// repeat.
///
/// Held open for the life of the app. That is not a cache: no value read through it is kept, per the
/// first design rule in `CLAUDE.md`. What is avoided is opening the same file again for every question.
///
/// Readers sit on top of this, one per table (`SettingReader`, `CategoryReader`), rather than one
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
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        handle.db = db
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
}

/// sqlite's own "copy this string" sentinel, which the C macro defines as `((sqlite3_destructor_type)
/// -1)` and so does not survive into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

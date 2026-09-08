@testable import FacetCore
import Foundation
import SQLite3

/// A throwaway database under the temporary directory, built from the repository's real DDL.
///
/// Real DDL rather than a fixture, because most of what these tests assert is about those files --
/// that the seeds are guarded, that `db_type` is seeded at all, that the shape of its value is what
/// the code parses. A fixture would only prove the code agrees with itself.
struct TemporaryDatabase {
    let directory: URL

    var url: URL { directory.appendingPathComponent("appdata.sqlite") }

    /// The trace's own file, beside the app's, exactly as the two sit in Application Support.
    var debugURL: URL { directory.appendingPathComponent("debug.sqlite") }

    /// The one real copy of the DDL, located from this file's own path so no test depends on
    /// bundling or on the working directory a runner happens to use.
    ///
    /// **`database/` is the real directory and `Sources/FacetCore/Resources/Database` is the symlink**,
    /// which is the opposite of how it used to be, and this points at the real one for a reason that is
    /// not tidiness. `FileManager.contentsOfDirectory(at:)` returns an **empty array** for a symlinked
    /// directory on Linux where it follows the link on Darwin (measured 2026-09-06,
    /// `docs/linux-port.md`), and `DatabaseBootstrap` enumerates whatever it is handed. So a test that
    /// went through the symlink would get a database with no tables, on Linux only, reported as a
    /// database that was created successfully.
    ///
    /// The schema lives at `database/` because both platforms need it and neither owns it; the symlink
    /// under `Sources/` exists only because SwiftPM requires a target's resources to sit inside the
    /// target, and SwiftPM does follow it when bundling.
    static var ddlDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/FacetTests/TemporaryDatabase.swift
            .deletingLastPathComponent()        // .../Tests/FacetTests
            .deletingLastPathComponent()        // .../Tests
            .deletingLastPathComponent()        // repository root
            .appendingPathComponent("database", isDirectory: true)
    }

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("facet-db-\(UUID().uuidString)", isDirectory: true)
    }

    @discardableResult
    func bootstrap() throws -> DatabaseBootstrap.Outcome {
        try DatabaseBootstrap.ensureDatabase(at: url, ddlDirectory: Self.ddlDirectory)
    }

    /// Brings up the trace's database as well, for a test that hands a `DebugLog` somewhere.
    ///
    /// **Separate because the two really are separate files**, and a test that pointed `DebugLog` at `url` would be
    /// testing a shape the app does not have. That is not hypothetical: when `debug_log` moved out on 2026-08-22,
    /// three `DeviceReconnectorOfferTests` started failing, and they failed *positively* -- `logged()` reads a count
    /// and a query against a missing table answers `nil`, which is not `"0"`, so "is there a row?" came back yes.
    @discardableResult
    func bootstrapDebug() throws -> DatabaseBootstrap.Outcome {
        try DatabaseBootstrap.ensureDebugDatabase(at: debugURL, ddlDirectory: Self.ddlDirectory)
    }

    /// A read connection to this database, for the readers that sit on one.
    @MainActor
    func connection() -> DatabaseConnection {
        DatabaseConnection(databaseURL: url)
    }

    /// Runs a statement against the built database. Returns whether it succeeded, so a caller can
    /// fail its own test rather than have this one silently do nothing.
    @discardableResult
    func execute(_ sql: String) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    /// The first column of the first row, or `nil` if the query returned nothing.
    func string(_ sql: String) -> String? { Self.string(sql, in: url) }

    private static func string(_ sql: String, in databaseURL: URL) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: value)
    }

    /// The same, against the trace's database.
    func debugString(_ sql: String) -> String? { Self.string(sql, in: debugURL) }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

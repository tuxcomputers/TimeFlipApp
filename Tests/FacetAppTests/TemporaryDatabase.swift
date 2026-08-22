@testable import FacetApp
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
    /// Deliberately the real path rather than the `database/` symlink at the repository root: the
    /// symlink exists for the short paths humans and scripts use, and a test that went through it
    /// would fail confusingly if it were ever removed, rather than saying the schema is missing.
    static var ddlDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/FacetAppTests/TemporaryDatabase.swift
            .deletingLastPathComponent()        // .../Tests/FacetAppTests
            .deletingLastPathComponent()        // .../Tests
            .deletingLastPathComponent()        // repository root
            .appendingPathComponent("Sources/FacetApp/Resources/Database", isDirectory: true)
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

@testable import TimeFlipApp
import SQLite3
import XCTest

/// Covers `DatabaseBootstrap`: that one run builds the schema and seeds it, and that a second run
/// over the same file changes nothing.
///
/// Run against the repository's real `database/*.sql` rather than a fixture, because the claim being
/// tested is about those files -- that every `CREATE` is `IF NOT EXISTS` and every seed is guarded.
/// A fixture would only prove the loop works.
final class DatabaseBootstrapTests: XCTestCase {
    private var directory: URL!

    /// The one real copy of the DDL, located from this file's own path so the test does not depend on
    /// bundling or on the working directory a runner happens to use.
    ///
    /// Deliberately the real path rather than the `database/` symlink at the repository root: the
    /// symlink is there for the short paths humans and scripts use, and a test that went through it
    /// would fail confusingly if it were ever removed, rather than saying the schema is missing.
    private var ddlDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/TimeFlipAppTests/DatabaseBootstrapTests.swift
            .deletingLastPathComponent()        // .../Tests/TimeFlipAppTests
            .deletingLastPathComponent()        // .../Tests
            .deletingLastPathComponent()        // repository root
            .appendingPathComponent("Sources/TimeFlipApp/Resources/Database", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("db-bootstrap-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var databaseURL: URL {
        directory.appendingPathComponent("appdata.sqlite")
    }

    @discardableResult
    private func bootstrap() throws -> DatabaseBootstrap.Outcome {
        try DatabaseBootstrap.ensureDatabase(at: databaseURL, ddlDirectory: ddlDirectory)
    }

    /// One read-only query against the built database.
    private func scalar(_ sql: String) throws -> Int64 {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW
        else {
            XCTFail("query failed: \(sql)")
            return -1
        }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: - building it

    func testTheFirstRunCreatesTheDatabaseAndAppliesEveryFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path), "precondition")

        let outcome = try bootstrap()

        XCTAssertTrue(outcome.createdDatabase)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(
            outcome.filesApplied.count,
            try FileManager.default.contentsOfDirectory(atPath: ddlDirectory.path)
                .filter { $0.hasSuffix(".sql") }.count,
            "every .sql file in database/ should have been applied"
        )
        XCTAssertEqual(outcome.filesApplied, outcome.filesApplied.sorted(), "applied in filename order")
    }

    func testTheSchemaAndItsSeedsAreThere() throws {
        try bootstrap()

        // A table from the DDL, and rows from the seeds that later work depends on: 12 cube faces,
        // and the settings the app reads on startup.
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='face';"), 1)
        // Thirteen, not twelve: the cube's twelve physical faces plus face 13, which is the app's
        // own and is what a manual-mode segment is recorded against (`database/008_face.sql`, and
        // `manualFaceID` in the archived constants).
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM face;"), 13, "12 cube faces plus the manual face")
        XCTAssertGreaterThan(try scalar("SELECT COUNT(*) FROM setting;"), 0)
        XCTAssertGreaterThan(try scalar("SELECT COUNT(*) FROM category;"), 0)
    }

    // MARK: - running it again

    func testASecondRunChangesNothing() throws {
        try bootstrap()
        let facesAfterFirst = try scalar("SELECT COUNT(*) FROM face;")
        let categoriesAfterFirst = try scalar("SELECT COUNT(*) FROM category;")
        let settingsAfterFirst = try scalar("SELECT COUNT(*) FROM setting;")

        let second = try bootstrap()

        XCTAssertFalse(second.createdDatabase, "the file was already there the second time")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM face;"), facesAfterFirst, "seeds must not double up")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM category;"), categoriesAfterFirst)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM setting;"), settingsAfterFirst)
    }

    func testARunOverAnEstablishedDatabaseLeavesItsDataAlone() throws {
        try bootstrap()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "INSERT INTO category (category_name, active) VALUES ('Kept', 1);", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(handle)

        try bootstrap()

        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM category WHERE category_name = 'Kept';"), 1,
            "re-running the DDL is not allowed to disturb rows the app has since written"
        )
    }

    // MARK: - failure is reported, not swallowed

    func testAMissingDDLDirectoryIsAnError() {
        let missing = directory.appendingPathComponent("nowhere", isDirectory: true)
        XCTAssertThrowsError(
            try DatabaseBootstrap.ensureDatabase(at: databaseURL, ddlDirectory: missing)
        ) { error in
            guard case DatabaseBootstrap.Failure.ddlDirectoryUnreadable = error else {
                return XCTFail("expected ddlDirectoryUnreadable, got \(error)")
            }
        }
    }
}

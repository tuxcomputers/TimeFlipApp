@testable import FacetApp
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

    /// The one real copy of the DDL. Shared with every other test that needs a database, so the walk
    /// up from a test file to the repository root is written once (see `TemporaryDatabase`).
    private var ddlDirectory: URL { TemporaryDatabase.ddlDirectory }

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

    /// Every table a database actually holds, sorted. `sqlite_sequence` is sqlite's own bookkeeping for
    /// `AUTOINCREMENT`, so it is not part of anybody's schema and is left out.
    private func tableNames(in databaseURL: URL) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("could not open \(databaseURL.lastPathComponent)")
            return []
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;",
            -1, &stmt, nil
        ) == SQLITE_OK else {
            return []
        }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return names
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
        // **Every file this database owns, and none of the other's.** One directory holds both schemas and the
        // number says which is which -- below 500 the app's, 500 and up the trace's -- so counting the directory
        // outright would expect `appdata.sqlite` to grow the debug log's tables as well.
        let appFiles = try FileManager.default.contentsOfDirectory(atPath: ddlDirectory.path)
            .filter { $0.hasSuffix(".sql") }
            .filter { (Int($0.prefix(3)) ?? 0) < DatabaseBootstrap.firstDebugDDLNumber }
        XCTAssertEqual(
            outcome.filesApplied.count, appFiles.count,
            "every .sql file below \(DatabaseBootstrap.firstDebugDDLNumber) should have been applied"
        )
        XCTAssertEqual(outcome.filesApplied, outcome.filesApplied.sorted(), "applied in filename order")
    }

    /// The other half of the split, from the other side: the trace's database gets the `500` files and nothing else.
    ///
    /// Worth its own case rather than trusting the count above, because the failure that matters is not "too few
    /// files" but "the wrong ones" -- an `appdata.sqlite` carrying `debug_log`, or a `debug.sqlite` carrying
    /// `time_entry`, would both satisfy a count and neither is the shape the app has.
    func testTheDebugDatabaseGetsItsOwnSchemaAndNotTheApps() throws {
        let debugURL = directory.appendingPathComponent("debug.sqlite")

        try bootstrap()
        try DatabaseBootstrap.ensureDebugDatabase(at: debugURL, ddlDirectory: ddlDirectory)

        XCTAssertEqual(tableNames(in: debugURL), ["debug_log", "timezone"], "the trace's file, and only it")
        XCTAssertFalse(tableNames(in: databaseURL).contains("debug_log"), "the app's file keeps no trace table")
        XCTAssertTrue(tableNames(in: databaseURL).contains("time_entry"), "precondition: the app's schema is there")
    }

    func testTheSchemaAndItsSeedsAreThere() throws {
        try bootstrap()

        // A table from the DDL, and rows from the seeds that later work depends on: 12 cube faces,
        // and the settings the app reads on startup.
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='face';"), 1)
        // Fourteen, not twelve: the cube's twelve physical faces plus the app's own two, which is what a
        // manual-mode segment is recorded against. There are two of those rather than one so consecutive
        // manual segments never share a face -- see `ManualFace` and `database/008_face.sql`.
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM face;"),
            Int64(12 + ManualFace.all.count),
            "12 cube faces plus the app's own"
        )
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

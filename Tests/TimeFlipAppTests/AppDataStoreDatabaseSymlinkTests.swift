@testable import TimeFlipApp
import SQLite3
import XCTest

final class AppDataStoreDatabaseSymlinkTests: XCTestCase {
    private var directory: URL!
    private var appdataURL: URL!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppDataStoreDatabaseSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        appdataURL = directory.appendingPathComponent("appdata.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var productionURL: URL {
        directory.appendingPathComponent("production.sqlite")
    }

    private var testURL: URL {
        directory.appendingPathComponent("test.sqlite")
    }

    private func dbType(at url: URL) throws -> String {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT setting_value FROM setting WHERE setting_name = 'db_type';", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let json = String(cString: sqlite3_column_text(stmt, 0))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(object["type"] as? String)
    }

    func testFreshInstallCreatesSymlinkToProduction() throws {
        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: appdataURL.path)
        XCTAssertEqual(destination, productionURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: productionURL.path), "sqlite3_open, not this method, creates the target file")
    }

    func testFreshInstallAlsoEagerlyCreatesAFullySeededTestDatabase() throws {
        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testURL.path), "test.sqlite must exist immediately, not only once a testing session first switches to it")
        XCTAssertEqual(try dbType(at: testURL), "test")
    }

    func testExistingTestDatabaseIsNotResetOnSubsequentRuns() throws {
        AppDataStore.ensureDatabaseSymlink(at: appdataURL)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(testURL.path, &handle), SQLITE_OK)
        sqlite3_exec(handle, "INSERT INTO event_type (event_type_id, event_name) VALUES (99, 'marker_row');", nil, nil, nil)
        sqlite3_close(handle)

        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        var recheck: OpaquePointer?
        sqlite3_open(testURL.path, &recheck)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(recheck, "SELECT COUNT(*) FROM event_type WHERE event_type_id = 99;", -1, &stmt, nil)
        sqlite3_step(stmt)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1, "an existing test.sqlite's accumulated state must survive re-running the bootstrap")
        sqlite3_finalize(stmt)
        sqlite3_close(recheck)
    }

    func testPreExistingPlainFileIsMigratedIntoProduction() throws {
        let originalData = "not really sqlite, just marking identity".data(using: .utf8)!
        try originalData.write(to: appdataURL)

        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: appdataURL.path)
        XCTAssertEqual(destination, productionURL.path)
        XCTAssertEqual(try Data(contentsOf: productionURL), originalData, "pre-existing data must be preserved under production.sqlite, not discarded")
    }

    func testAlreadySymlinkedIsLeftUntouched() throws {
        let testDBURL = directory.appendingPathComponent("test.sqlite")
        try Data().write(to: testDBURL)
        try FileManager.default.createSymbolicLink(at: appdataURL, withDestinationURL: testDBURL)

        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: appdataURL.path)
        XCTAssertEqual(destination, testDBURL.path, "an existing symlink must be left pointing wherever it already did, not reset to production.sqlite")
    }

    func testDoesNotOverwriteAnExistingProductionFile() throws {
        let productionData = "existing production data".data(using: .utf8)!
        try productionData.write(to: productionURL)
        let strayData = "stray plain file at the symlink path".data(using: .utf8)!
        try strayData.write(to: appdataURL)

        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        // Ambiguous conflict (both a real file at the symlink path AND an existing production.sqlite)
        // -- must not silently clobber either one.
        XCTAssertEqual(try Data(contentsOf: productionURL), productionData)
    }
}

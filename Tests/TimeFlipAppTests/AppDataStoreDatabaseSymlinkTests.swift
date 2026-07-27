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

    func testFreshInstallCreatesSymlinkToProduction() throws {
        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: appdataURL.path)
        XCTAssertEqual(destination, productionURL.lastPathComponent, "relative, not absolute, so the link keeps working if this directory is ever moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: productionURL.path), "sqlite3_open, not this method, creates the target file")
    }

    func testFreshInstallDoesNotCreateTestDatabase() throws {
        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: testURL.path), "test.sqlite is created only when a testing session is started (scripts/use-test-database.sh), never at app startup")
    }

    func testPreExistingPlainFileIsMigratedIntoProduction() throws {
        let originalData = "not really sqlite, just marking identity".data(using: .utf8)!
        try originalData.write(to: appdataURL)

        AppDataStore.ensureDatabaseSymlink(at: appdataURL)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: appdataURL.path)
        XCTAssertEqual(destination, productionURL.lastPathComponent, "relative, not absolute, so the link keeps working if this directory is ever moved")
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

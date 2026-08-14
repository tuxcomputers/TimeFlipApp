@testable import TimeFlipApp
import XCTest

/// Covers `DatabaseEnvironment`: reading which database a launch opened.
///
/// The read matters more than it looks. Its answer decides whether the menu bar warns that a test
/// database is open, so a wrong answer is worse than no answer -- which is why the `nil` cases below are
/// tested as carefully as the two real ones.
@MainActor
final class DatabaseEnvironmentTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    override func tearDown() {
        settings = nil
        database.remove()
        super.tearDown()
    }

    private func setType(_ value: String) {
        XCTAssertTrue(
            database.execute("UPDATE setting SET setting_value = '\(value)' WHERE setting_name = 'db_type';")
        )
    }

    func testAFreshDatabaseReadsAsProduction() {
        XCTAssertEqual(DatabaseEnvironment.read(from: settings), .production)
    }

    func testADatabaseMarkedAsATestCopyReadsAsTest() {
        // What switching to a test database does to the row it just seeded.
        setType(#"{"type":"test"}"#)

        XCTAssertEqual(DatabaseEnvironment.read(from: settings), .test)
    }

    func testTheTypeIsReadCaseInsensitively() {
        // The row is written by hand and by script, so the casing it arrives in is not guaranteed.
        setType(#"{"type":"TEST"}"#)

        XCTAssertEqual(DatabaseEnvironment.read(from: settings), .test)
    }

    func testAValueNamingNeitherEnvironmentIsNotGuessedAt() {
        for value in [#"{"type":"staging"}"#, #"{"type":""}"#, #"{"kind":"test"}"#, "production"] {
            setType(value)
            XCTAssertNil(DatabaseEnvironment.read(from: settings), "should not resolve: \(value)")
        }
    }

    func testAMissingSettingRowIsUnknownRatherThanProduction() {
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'db_type';"))

        XCTAssertNil(DatabaseEnvironment.read(from: settings))
    }

    func testAMissingDatabaseIsUnknownRatherThanProduction() {
        // A launch that reads production while opening nothing is the worst of the three answers.
        let missing = SettingStore(connection: DatabaseConnection(databaseURL: database.directory.appendingPathComponent("nowhere.sqlite")))

        XCTAssertNil(DatabaseEnvironment.read(from: missing))
    }
}

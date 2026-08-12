@testable import TimeFlipApp
import XCTest

/// Covers `DatabaseEnvironment`: reading which database a launch opened, and the value's shape.
///
/// The read matters more than it looks. Its answer decides whether the menu bar warns that a test
/// database is open, so a wrong answer is worse than no answer -- which is why the `nil` cases below
/// are tested as carefully as the two real ones.
final class DatabaseEnvironmentTests: XCTestCase {
    private var database: TemporaryDatabase!

    override func setUp() {
        super.setUp()
        database = TemporaryDatabase()
    }

    override func tearDown() {
        database.remove()
        super.tearDown()
    }

    // MARK: - the value's shape

    func testTheSeededValueParses() {
        XCTAssertEqual(DatabaseEnvironment.parse(settingValue: #"{"type":"production"}"#), .production)
        XCTAssertEqual(DatabaseEnvironment.parse(settingValue: #"{"type":"test"}"#), .test)
    }

    func testTheTypeIsReadCaseInsensitively() {
        // The row is written by hand and by script, so the casing it arrives in is not guaranteed.
        XCTAssertEqual(DatabaseEnvironment.parse(settingValue: #"{"type":"TEST"}"#), .test)
    }

    func testAValueThatNamesNeitherEnvironmentIsNotGuessedAt() {
        XCTAssertNil(DatabaseEnvironment.parse(settingValue: #"{"type":"staging"}"#))
        XCTAssertNil(DatabaseEnvironment.parse(settingValue: #"{"type":""}"#))
        XCTAssertNil(DatabaseEnvironment.parse(settingValue: #"{"kind":"test"}"#))
        XCTAssertNil(DatabaseEnvironment.parse(settingValue: "production"), "bare text, not the JSON shape")
        XCTAssertNil(DatabaseEnvironment.parse(settingValue: ""))
    }

    // MARK: - reading it from a database

    func testAFreshDatabaseReadsAsProduction() throws {
        try database.bootstrap()

        XCTAssertEqual(DatabaseEnvironment.read(from: database.url), .production)
    }

    func testADatabaseMarkedAsATestCopyReadsAsTest() throws {
        try database.bootstrap()
        // What switching to a test database does to the row it just seeded.
        XCTAssertTrue(
            database.execute(#"UPDATE setting SET setting_value = '{"type":"test"}' WHERE setting_name = 'db_type';"#)
        )

        XCTAssertEqual(DatabaseEnvironment.read(from: database.url), .test)
    }

    func testAMissingDatabaseIsUnknownRatherThanProduction() {
        // Nothing has been bootstrapped, so there is no file to open. The badge has to be able to say
        // "unknown" here: a launch that reads production while opening nothing is the worst answer of
        // the three.
        XCTAssertNil(DatabaseEnvironment.read(from: database.url))
    }

    func testAMissingSettingRowIsUnknownRatherThanProduction() throws {
        try database.bootstrap()
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'db_type';"))

        XCTAssertNil(DatabaseEnvironment.read(from: database.url))
    }
}

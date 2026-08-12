@testable import TimeFlipApp
import XCTest

/// Covers `SettingReader`: reading a setting's fields, and -- the important one -- that it reads every
/// time rather than remembering.
@MainActor
final class SettingReaderTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var settings: SettingReader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingReader(connection: database.connection())
    }

    override func tearDown() {
        settings = nil
        database.remove()
        super.tearDown()
    }

    // MARK: - the design rule

    func testAChangedSettingIsSeenByTheNextRead() {
        XCTAssertEqual(settings.flag("paired", field: "paired"), false, "the seeded state")

        XCTAssertTrue(
            database.execute(#"UPDATE setting SET setting_value = '{"paired":true}' WHERE setting_name = 'paired';"#)
        )

        // The whole point of the type. A reader that cached the first answer would pass every other test
        // in this file and fail here, and in the app it would fail as a stale value on screen that
        // nobody could explain.
        XCTAssertEqual(settings.flag("paired", field: "paired"), true, "read again, not remembered")
    }

    // MARK: - reading fields

    func testReadsABooleanField() {
        XCTAssertEqual(settings.flag("paired", field: "paired"), false)
    }

    func testReadsATextField() {
        XCTAssertEqual(settings.string("db_type", field: "type"), "production")
    }

    func testReadsAWholeSettingAsAnObject() {
        // `daily_reset_time` is seeded with two fields, so it shows the object arriving intact rather
        // than a single value that happens to parse.
        let json = settings.json("daily_reset_time")
        XCTAssertEqual(json?["hour"] as? Int, 3)
        XCTAssertEqual(json?["minute"] as? Int, 0)
    }

    // MARK: - nothing is guessed at

    func testASettingThatDoesNotExistIsNil() {
        XCTAssertNil(settings.json("no_such_setting"))
        XCTAssertNil(settings.flag("no_such_setting", field: "enabled"))
        XCTAssertNil(settings.string("no_such_setting", field: "type"))
    }

    func testAFieldThatDoesNotExistIsNil() {
        XCTAssertNil(settings.flag("paired", field: "enabled"))
        XCTAssertNil(settings.string("paired", field: "paired"), "present, but not text")
    }

    func testAValueThatIsNotJSONIsNil() {
        XCTAssertTrue(database.execute("UPDATE setting SET setting_value = 'true' WHERE setting_name = 'paired';"))

        XCTAssertNil(settings.json("paired"))
        XCTAssertNil(settings.flag("paired", field: "paired"))
    }

    func testADatabaseThatWillNotOpenReadsAsNilRatherThanCrashing() {
        let missing = SettingReader(connection: DatabaseConnection(databaseURL: database.directory.appendingPathComponent("nowhere.sqlite")))

        XCTAssertNil(missing.flag("paired", field: "paired"))
    }
}

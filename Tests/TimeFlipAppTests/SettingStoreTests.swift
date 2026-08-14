@testable import TimeFlipApp
import XCTest

/// Covers `SettingStore`: reading a setting's fields, writing one of them, and -- the important one -- that it
/// reads every time rather than remembering.
@MainActor
final class SettingStoreTests: XCTestCase {
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
        let missing = SettingStore(connection: DatabaseConnection(databaseURL: database.directory.appendingPathComponent("nowhere.sqlite")))

        XCTAssertNil(missing.flag("paired", field: "paired"))
    }

    // MARK: - writing

    func testAWrittenFieldIsWhatTheNextReadGets() {
        XCTAssertTrue(settings.write("blip_time", field: "seconds", 9))

        XCTAssertEqual(settings.integer("blip_time", field: "seconds"), 9)
        XCTAssertEqual(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'blip_time';"),
            #"{"seconds":9}"#
        )
    }

    func testAFlagIsWrittenAsABooleanRatherThanANumber() {
        XCTAssertTrue(settings.write("display_seconds", field: "enabled", false))

        XCTAssertEqual(settings.flag("display_seconds", field: "enabled"), false)
        // As JSON `false`, not `0`: the row is read by `flag`, which asks for a boolean and would get nothing.
        XCTAssertEqual(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'display_seconds';"),
            #"{"enabled":false}"#
        )
    }

    func testTheRestOfTheRowSurvivesAWrite() {
        // `daily_reset_time` carries a minute beside its hour, and no control on the App tab touches it. A write that
        // replaced the object would quietly change the rollover as well as the hour.
        XCTAssertTrue(database.execute(
            #"UPDATE setting SET setting_value = '{"hour":3,"minute":30}' WHERE setting_name = 'daily_reset_time';"#
        ))

        XCTAssertTrue(settings.write("daily_reset_time", field: "hour", 6))

        XCTAssertEqual(settings.integer("daily_reset_time", field: "hour"), 6)
        XCTAssertEqual(settings.integer("daily_reset_time", field: "minute"), 30)
    }

    func testWritingASettingThatIsNotThereIsRefused() {
        // The rows are seeded by the DDL, so a missing one is a database that has not been brought up to date rather
        // than a setting waiting to be created. Inventing it here would hide that.
        XCTAssertFalse(settings.write("no_such_setting", field: "enabled", true))
    }

    func testWritingIntoARowThatIsNotJSONIsRefused() {
        XCTAssertTrue(database.execute(
            "UPDATE setting SET setting_value = 'not json at all' WHERE setting_name = 'blip_time';"
        ))

        XCTAssertFalse(settings.write("blip_time", field: "seconds", 9))
    }

    func testAWriteIsCheckedByReadingItBack() {
        // The answer to "did that work" comes from the table rather than from the statement, because a write that
        // reported success and did not happen would leave a window showing a value the table does not hold.
        XCTAssertTrue(settings.write("low_battery_level", field: "percent", 15))
        XCTAssertEqual(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'low_battery_level';"),
            #"{"percent":15}"#
        )
    }
}

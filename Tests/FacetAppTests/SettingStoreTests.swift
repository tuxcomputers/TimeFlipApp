@testable import FacetApp
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

    // MARK: - writing several fields at once

    func testSeveralFieldsLandTogether() {
        // The four double-tap registers are the case this exists for: they go to the cube as one command and describe
        // nothing apart, so a row holding three new numbers and one old one would describe a cube that has never
        // existed.
        XCTAssertTrue(settings.write("double_tap_settings", fields: [
            "clickThreshold": .number(200),
            "limit": .number(45),
            "latency": .number(34),
            "window": .number(0),
        ]))

        XCTAssertEqual(settings.integer("double_tap_settings", field: "clickThreshold"), 200)
        XCTAssertEqual(settings.integer("double_tap_settings", field: "limit"), 45)
        XCTAssertEqual(settings.integer("double_tap_settings", field: "latency"), 34)
        XCTAssertEqual(settings.integer("double_tap_settings", field: "window"), 0)
    }

    func testTheFieldsNotNamedSurviveIt() {
        // `enabled` shares the row with the four registers and is set by a different control, so a write that
        // replaced the object would turn the gesture on behind whoever had just turned it off.
        XCTAssertTrue(settings.write("double_tap_settings", field: "enabled", false))

        XCTAssertTrue(settings.write("double_tap_settings", fields: ["window": .number(0)]))

        XCTAssertEqual(settings.flag("double_tap_settings", field: "enabled"), false)
    }

    func testAFlagAndANumberKeepTheirTypesThroughIt() {
        // Why `Value` is an enum rather than `Any`: `JSONSerialization` hands `true` and `1` back as the same
        // `NSNumber`, so a read-back through `Any` would confirm a row that came back holding the wrong one.
        XCTAssertTrue(settings.write("double_tap_settings", fields: [
            "enabled": .flag(false),
            "window": .number(1),
        ]))

        XCTAssertEqual(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'double_tap_settings';"),
            #"{"clickThreshold":90,"enabled":false,"latency":50,"limit":20,"window":1}"#
        )
    }

    func testWritingSeveralFieldsIntoASettingThatIsNotThereIsRefused() {
        XCTAssertFalse(settings.write("no_such_setting", fields: ["window": .number(0)]))
    }

    func testWritingSeveralFieldsIntoARowThatIsNotJSONIsRefused() {
        XCTAssertTrue(database.execute(
            "UPDATE setting SET setting_value = 'not json at all' WHERE setting_name = 'double_tap_settings';"
        ))

        XCTAssertFalse(settings.write("double_tap_settings", fields: ["window": .number(0)]))
    }
}

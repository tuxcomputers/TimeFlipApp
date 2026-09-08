@testable import FacetCore
import Foundation
import Testing

/// Covers `SettingStore`: reading a setting's fields, writing one of them, and -- the important one -- that it
/// reads every time rather than remembering.
@Suite @MainActor
final class SettingStoreTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored
        // properties by hand is what the old `MainActor.assumeIsolated` block was for; the
        // instance is discarded whole here, so removing the directory is all that is left.
        // The database connection closes after the file is unlinked rather than before, which
        // both platforms allow.
        database.remove()
    }

    // MARK: - the design rule

    @Test func testAChangedSettingIsSeenByTheNextRead() {
        #expect(settings.flag("paired", field: "paired") == false, "the seeded state")

        #expect(
            database.execute(#"UPDATE setting SET setting_value = '{"paired":true}' WHERE setting_name = 'paired';"#)
        )

        // The whole point of the type. A reader that cached the first answer would pass every other test
        // in this file and fail here, and in the app it would fail as a stale value on screen that
        // nobody could explain.
        #expect(settings.flag("paired", field: "paired") == true, "read again, not remembered")
    }

    // MARK: - reading fields

    @Test func testReadsABooleanField() {
        #expect(settings.flag("paired", field: "paired") == false)
    }

    @Test func testReadsATextField() {
        #expect(settings.string("db_type", field: "type") == "production")
    }

    @Test func testReadsAWholeSettingAsAnObject() {
        // `daily_reset_time` is seeded with two fields, so it shows the object arriving intact rather
        // than a single value that happens to parse.
        let json = settings.json("daily_reset_time")
        #expect(json?["hour"] as? Int == 3)
        #expect(json?["minute"] as? Int == 0)
    }

    // MARK: - nothing is guessed at

    @Test func testASettingThatDoesNotExistIsNil() {
        #expect(settings.json("no_such_setting") == nil)
        #expect(settings.flag("no_such_setting", field: "enabled") == nil)
        #expect(settings.string("no_such_setting", field: "type") == nil)
    }

    @Test func testAFieldThatDoesNotExistIsNil() {
        #expect(settings.flag("paired", field: "enabled") == nil)
        #expect(settings.string("paired", field: "paired") == nil, "present, but not text")
    }

    @Test func testAValueThatIsNotJSONIsNil() {
        #expect(database.execute("UPDATE setting SET setting_value = 'true' WHERE setting_name = 'paired';"))

        #expect(settings.json("paired") == nil)
        #expect(settings.flag("paired", field: "paired") == nil)
    }

    @Test func testADatabaseThatWillNotOpenReadsAsNilRatherThanCrashing() {
        let missing = SettingStore(connection: DatabaseConnection(databaseURL: database.directory.appendingPathComponent("nowhere.sqlite")))

        #expect(missing.flag("paired", field: "paired") == nil)
    }

    // MARK: - writing

    @Test func testAWrittenFieldIsWhatTheNextReadGets() {
        #expect(settings.write("blip_time", field: "seconds", 9))

        #expect(settings.integer("blip_time", field: "seconds") == 9)
        #expect(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'blip_time';") == #"{"seconds":9}"#
        )
    }

    @Test func testAFlagIsWrittenAsABooleanRatherThanANumber() {
        #expect(settings.write("display_seconds", field: "enabled", false))

        #expect(settings.flag("display_seconds", field: "enabled") == false)
        // As JSON `false`, not `0`: the row is read by `flag`, which asks for a boolean and would get nothing.
        #expect(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'display_seconds';") == #"{"enabled":false}"#
        )
    }

    @Test func testTheRestOfTheRowSurvivesAWrite() {
        // `daily_reset_time` carries a minute beside its hour, and no control on the App tab touches it. A write that
        // replaced the object would quietly change the rollover as well as the hour.
        #expect(
            database.execute( #"UPDATE setting SET setting_value = '{"hour":3,"minute":30}' WHERE setting_name = 'daily_reset_time';"# )
        )

        #expect(settings.write("daily_reset_time", field: "hour", 6))

        #expect(settings.integer("daily_reset_time", field: "hour") == 6)
        #expect(settings.integer("daily_reset_time", field: "minute") == 30)
    }

    @Test func testWritingASettingThatIsNotThereIsRefused() {
        // The rows are seeded by the DDL, so a missing one is a database that has not been brought up to date rather
        // than a setting waiting to be created. Inventing it here would hide that.
        #expect(!(settings.write("no_such_setting", field: "enabled", true)))
    }

    @Test func testWritingIntoARowThatIsNotJSONIsRefused() {
        #expect(
            database.execute( "UPDATE setting SET setting_value = 'not json at all' WHERE setting_name = 'blip_time';" )
        )

        #expect(!(settings.write("blip_time", field: "seconds", 9)))
    }

    @Test func testAWriteIsCheckedByReadingItBack() {
        // The answer to "did that work" comes from the table rather than from the statement, because a write that
        // reported success and did not happen would leave a window showing a value the table does not hold.
        #expect(settings.write("low_battery_level", field: "percent", 15))
        #expect(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'low_battery_level';") == #"{"percent":15}"#
        )
    }

    // MARK: - writing several fields at once

    @Test func testSeveralFieldsLandTogether() {
        // The four double-tap registers are the case this exists for: they go to the cube as one command and describe
        // nothing apart, so a row holding three new numbers and one old one would describe a cube that has never
        // existed.
        #expect(
            settings.write("double_tap_settings", fields: [ "clickThreshold": .number(200), "limit": .number(45), "latency": .number(34), "window": .number(0), ])
        )

        #expect(settings.integer("double_tap_settings", field: "clickThreshold") == 200)
        #expect(settings.integer("double_tap_settings", field: "limit") == 45)
        #expect(settings.integer("double_tap_settings", field: "latency") == 34)
        #expect(settings.integer("double_tap_settings", field: "window") == 0)
    }

    @Test func testTheFieldsNotNamedSurviveIt() {
        // `enabled` shares the row with the four registers and is set by a different control, so a write that
        // replaced the object would turn the gesture on behind whoever had just turned it off.
        #expect(settings.write("double_tap_settings", field: "enabled", false))

        #expect(settings.write("double_tap_settings", fields: ["window": .number(0)]))

        #expect(settings.flag("double_tap_settings", field: "enabled") == false)
    }

    @Test func testAFlagAndANumberKeepTheirTypesThroughIt() {
        // Why `Value` is an enum rather than `Any`: `JSONSerialization` hands `true` and `1` back as the same
        // `NSNumber`, so a read-back through `Any` would confirm a row that came back holding the wrong one.
        #expect(settings.write("double_tap_settings", fields: [ "enabled": .flag(false), "window": .number(1), ]))

        #expect(
            database.string("SELECT setting_value FROM setting WHERE setting_name = 'double_tap_settings';") == #"{"clickThreshold":90,"enabled":false,"latency":50,"limit":20,"window":1}"#
        )
    }

    @Test func testWritingSeveralFieldsIntoASettingThatIsNotThereIsRefused() {
        #expect(!(settings.write("no_such_setting", fields: ["window": .number(0)])))
    }

    @Test func testWritingSeveralFieldsIntoARowThatIsNotJSONIsRefused() {
        #expect(
            database.execute( "UPDATE setting SET setting_value = 'not json at all' WHERE setting_name = 'double_tap_settings';" )
        )

        #expect(!(settings.write("double_tap_settings", fields: ["window": .number(0)])))
    }
}

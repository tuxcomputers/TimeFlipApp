@testable import FacetCore
import Foundation
import Testing

/// The five rows of the Device tab's Settings section, with no cube and no window.
///
/// **What these pin is which rows reach the cube and which do not**, and that the table is written only after the
/// cube has taken a command. `DeviceSettingWriteTests` covers the ordering itself; this covers the five callers --
/// which command each sends, which row each writes, and that a refused write puts the row back.
@Suite @MainActor
final class DeviceSettingRowsTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var dialogues: RecordingDialogues!
    private var rows: DeviceSettingRows!

    /// What went to the cube, and what the cube said about it.
    private var sent: [Data] = []
    private var cubeTakesIt = true
    private var putBacks = 0

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
        dialogues = RecordingDialogues()
        rows = DeviceSettingRows(settings: settings, dialogues: dialogues, debugLog: nil)
        rows.putBack = { [self] in putBacks += 1 }
    }

    deinit {
        database.remove()
    }

    /// A radio that answers immediately, which is what a hermetic test can have: what `DeviceSettingWrite` needs is
    /// an answer, and when it arrives is the adapter's business.
    private func withRadio() {
        rows.send = { [self] command, reported in
            sent.append(command)
            reported(cubeTakesIt)
        }
    }

    // MARK: - the two that send nothing

    @Test func testPauseOnLockIsTheTableAndNothingElse() {
        withRadio()

        rows.pauseOnLock(true)

        #expect(settings.flag("pause_on_lock", field: "enabled") == true)
        #expect(sent.isEmpty, "no command carries this: the app reads it on its way to a lock")
    }

    @Test func testTheBatteryWarningIsTheTableAndNothingElse() {
        withRadio()

        rows.batteryWarning(25)

        #expect(settings.integer("low_battery_level", field: "percent") == 25)
        #expect(sent.isEmpty, "a threshold this app applies to readings the cube volunteers")
    }

    // MARK: - the three that reach the cube

    @Test func testAutoPauseGoesToTheCubeBeforeTheTable() {
        withRadio()

        rows.autoPause(15)

        #expect(sent.count == 1)
        #expect(sent.first == DeviceCommandRules.autoPause(15))
        #expect(settings.integer("auto_pause_minutes", field: "minutes") == 15)
    }

    @Test func testACubeThatRefusesLeavesTheTableAloneAndPutsTheRowBack() {
        withRadio()
        cubeTakesIt = false
        let before = settings.integer("auto_pause_minutes", field: "minutes")

        rows.autoPause(15)

        #expect(settings.integer("auto_pause_minutes", field: "minutes") == before, "the cube said no")
        #expect(putBacks == 1)
        #expect(dialogues.told.count == 1, "and it says so rather than leaving a field showing what was typed")
    }

    @Test func testWithNoRadioNothingIsWrittenAndTheRowGoesBack() {
        rows.autoPause(15)

        #expect(sent.isEmpty)
        #expect(settings.integer("auto_pause_minutes", field: "minutes") != 15)
        #expect(putBacks == 1)
    }

    @Test func testTheTwoLEDValuesShareARowAndDoNotOverwriteEachOther() {
        withRadio()

        rows.ledBrightness(60)
        rows.ledBlink(4)

        // `SettingStore.write(_:field:_:)` merges into the row it finds, and the archive pinned this after the two
        // shared a row: brightness and the blink period are two commands that have never had to agree about
        // anything.
        #expect(settings.integer("led_settings", field: "brightness") == 60)
        #expect(settings.integer("led_settings", field: "blink_interval") == 4)
    }

    @Test func testEachLEDValueSendsItsOwnCommand() {
        withRadio()

        rows.ledBrightness(60)
        rows.ledBlink(4)

        #expect(sent == [DeviceCommandRules.ledBrightness(60), DeviceCommandRules.ledBlink(4)])
    }
}

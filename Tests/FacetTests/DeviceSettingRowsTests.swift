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

    /// Every outcome reported back, which is the whole of what a surface is told.
    private var outcomes: [DeviceSettingWrite.Outcome] = []

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
        dialogues = RecordingDialogues()
        rows = DeviceSettingRows(settings: settings, dialogues: dialogues, debugLog: nil)

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

        rows.pauseOnLock(true) { [self] in outcomes.append($0) }

        #expect(settings.flag("pause_on_lock", field: "enabled") == true)
        #expect(sent.isEmpty, "no command carries this: the app reads it on its way to a lock")
    }

    @Test func testTheBatteryWarningIsTheTableAndNothingElse() {
        withRadio()

        rows.batteryWarning(25) { [self] in outcomes.append($0) }

        #expect(settings.integer("low_battery_level", field: "percent") == 25)
        #expect(sent.isEmpty, "a threshold this app applies to readings the cube volunteers")
    }

    // MARK: - the eighth row

    @Test func testANameThatDidNotChangeIsIgnoredWithNothingSaid() {
        withRadio()
        var notices: [Dialogue?] = []

        rows.rename(to: "TimeFlip v2.0", replacing: "TimeFlip v2.0") { notices.append($0) }

        #expect(sent.isEmpty)
        #expect(notices == [nil], "an alert saying nothing happened is worse than nothing happening")
    }

    @Test func testANameTheCubeCannotHoldIsRefusedBeforeAnythingIsSent() {
        withRadio()
        var notices: [Dialogue?] = []

        rows.rename(to: String(repeating: "x", count: 200), replacing: nil) { notices.append($0) }

        #expect(sent.isEmpty, "the refusal is about what the cube can hold, so nothing is asked of it")
        #expect(notices.first??.title == DeviceNameProblem.tooLong(count: 200).title)
    }

    @Test func testARenameThatLandsSaysSoOnSuccess() {
        withRadio()
        var notices: [Dialogue?] = []

        rows.rename(to: "Desk cube", replacing: "TimeFlip v2.0") { notices.append($0) }

        #expect(sent.first == DeviceCommandRules.setName("Desk cube"))
        #expect(settings.string("device_name", field: "name") == "Desk cube")
        // **The only row on this tab that speaks on success**, because the cube goes on advertising the old name
        // until it is power-cycled and a scan would otherwise look like nothing happened.
        #expect(notices.first??.title == "The TimeFlip has been renamed")
    }

    @Test func testARenameWithNoRadioSpeaksWhereEveryOtherRowIsSilent() {
        var notices: [Dialogue?] = []

        rows.rename(to: "Desk cube", replacing: nil) { notices.append($0) }

        #expect(settings.string("device_name", field: "name") != "Desk cube")
        // A name that reached neither the cube nor the table is not a stale row: it is an app that may not find its
        // cube again, the scan filtering on exactly this (`DeviceScanRules.isEligible`).
        #expect(notices.first??.title == DeviceNameProblem.writeFailed.title)
    }

    @Test func testACubeThatRefusesTheRenameLeavesTheTableAlone() {
        withRadio()
        cubeTakesIt = false
        var notices: [Dialogue?] = []

        rows.rename(to: "Desk cube", replacing: nil) { notices.append($0) }

        #expect(settings.string("device_name", field: "name") != "Desk cube")
        #expect(notices.first??.title == DeviceNameProblem.writeFailed.title)
    }

    @Test func testTheRenameAnnouncesItselfInTheWordsTheScriptedCheckMatches() throws {
        // `66-device-rename.sh` matches `Renaming the cube to <name>` in full and reads its row id to prove the
        // table was written after the cube, so this row is an interface rather than a message. There is one caller
        // of `announcing:` and this is it.
        try database.bootstrapDebug()
        let rows = DeviceSettingRows(
            settings: settings,
            dialogues: dialogues,
            debugLog: DebugLog(databaseURL: database.debugURL, isRecording: true)
        )
        rows.send = { [self] command, reported in
            sent.append(command)
            reported(true)
        }

        rows.rename(to: "Desk cube", replacing: nil)

        let row = database.debugString(
            "SELECT message FROM debug_log WHERE message = 'Renaming the cube to Desk cube';"
        )
        #expect(row == "Renaming the cube to Desk cube")
    }

    // MARK: - the three that reach the cube

    @Test func testAutoPauseGoesToTheCubeBeforeTheTable() {
        withRadio()

        rows.autoPause(15) { [self] in outcomes.append($0) }

        #expect(sent.count == 1)
        #expect(sent.first == DeviceCommandRules.autoPause(15))
        #expect(settings.integer("auto_pause_minutes", field: "minutes") == 15)
    }

    @Test func testACubeThatRefusesLeavesTheTableAloneAndSaysSo() {
        withRadio()
        cubeTakesIt = false
        let before = settings.integer("auto_pause_minutes", field: "minutes")

        rows.autoPause(15) { [self] in outcomes.append($0) }

        #expect(settings.integer("auto_pause_minutes", field: "minutes") == before, "the cube said no")
        #expect(outcomes == [.refusedByTheCube])
        #expect(outcomes.first?.putsTheRowBack == true, "and the surface is told to put its row back")
        #expect(dialogues.told.count == 1, "and it says so rather than leaving a field showing what was typed")
    }

    @Test func testWithNoRadioNothingIsWrittenAndTheOutcomeSaysWhy() {
        rows.autoPause(15) { [self] in outcomes.append($0) }

        #expect(sent.isEmpty)
        #expect(settings.integer("auto_pause_minutes", field: "minutes") != 15)
        // **A refusal rather than a quiet success**: a row left showing a number that reached neither the cube nor
        // the table is the surface claiming something about hardware nobody ever asked.
        #expect(outcomes == [.nothingToSendTo])
    }

    @Test func testAWriteThatLandedReportsSettledSoASurfaceCanUpdateItsOwnCopy() {
        // **The half `putBack` could not express**, and the reason the Mac could not adopt this module: it needs to
        // tell a write that landed from one that did not, so its pane can bring its copy up to date without
        // reloading a field somebody may have stepped again since.
        withRadio()

        rows.autoPause(15) { [self] in outcomes.append($0) }

        #expect(outcomes == [.settled])
        #expect(outcomes.first?.putsTheRowBack == false)
    }

    @Test func testEveryRowReportsSomething() {
        withRadio()
        let report: @MainActor (DeviceSettingWrite.Outcome) -> Void = { [self] in outcomes.append($0) }

        rows.pauseOnLock(true, then: report)
        rows.batteryWarning(25, then: report)
        rows.autoPause(15, then: report)
        rows.ledBrightness(60, then: report)
        rows.ledBlink(4, then: report)

        // Five rows, five answers: a surface never has to work out which of them it has been told about.
        #expect(outcomes == [.settled, .settled, .settled, .settled, .settled])
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

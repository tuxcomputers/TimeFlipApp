@testable import FacetCore
import Foundation
import Testing

/// What a confirmed login writes into the `setting` table, and what it deliberately leaves alone.
///
/// **Against a real database built from the real DDL**, because the rows' seeded shapes are half the claim: `paired`
/// is seeded `{"paired":false}` and `device_uuid` is seeded `{}`, and a writer that only worked against a row it had
/// invented itself would prove nothing about either.
@Suite @MainActor
final class DevicePairingRecorderTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var recorder: DevicePairingRecorder!

    private let cube = ScannedDevice(
        id: DeviceHandle("0BE1F1CE-0000-4000-8000-000000000001"),
        peripheralName: "Dibby",
        advertisedName: "TimeFlip v2.0",
        advertisesTimeFlipService: true
    )

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
        recorder = DevicePairingRecorder(settings: settings, debugLog: nil)
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored
        // properties by hand is what the old `MainActor.assumeIsolated` block was for; the
        // instance is discarded whole here, so removing the directory is all that is left.
        // The database connection closes after the file is unlinked rather than before, which
        // both platforms allow.
        database.remove()
    }

    private func moment(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try #require(formatter.date(from: text))
    }

    // MARK: - pairing

    @Test func testAConfirmedLoginPairsTheApp() throws {
        #expect(settings.flag("paired", field: "paired") == false, "precondition: the seeded state")

        #expect(recorder.recordPairing(with: cube))

        #expect(settings.flag("paired", field: "paired") == true)
    }

    @Test func testItRecordsWhichDeviceItIs() throws {
        // The peripheral identifier, which is how the app finds the same cube again rather than rediscovering one.
        #expect(recorder.recordPairing(with: cube))

        #expect(settings.string("device_uuid", field: "uuid") == cube.id.value)
    }

    @Test func testItRecordsTheNameTheCubeIsCarrying() throws {
        #expect(recorder.recordPairing(with: cube))

        // The GAP name, not the advertised one and not the list's label.
        #expect(settings.string("device_name", field: "name") == "Dibby")
    }

    @Test func testACubeThatHasNotSaidWhatItIsCalledLeavesTheNameAlone() throws {
        let unnamed = ScannedDevice(
            id: cube.id, peripheralName: nil, advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )

        #expect(recorder.recordPairing(with: unnamed))

        // Paired and unnamed is a real state: the TimeFlip section says `Unknown` rather than `TimeFlip v2.0`, which is a
        // name no rename could ever change.
        #expect(settings.flag("paired", field: "paired") == true)
        #expect(settings.string("device_name", field: "name") == nil)
    }

    @Test func testItMarksTheConnectionUp() throws {
#expect(recorder.recordPairing(with: cube, at: try moment("2026-08-17T09:15:30")))

        #expect(settings.flag("connection", field: "connected") == true)
        #expect(settings.string("connection", field: "last_connection") == "2026-08-17T09:15:30")
    }

    // MARK: - the name it displaced

    @Test func testARenamedCubeKeepsTheNameTheScanIsStillSeeing() throws {
        #expect(recorder.recordPairing(with: cube), "precondition: paired as Dibby")
        let renamed = ScannedDevice(
            id: cube.id, peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )

        #expect(recorder.recordPairing(with: renamed))

        // `CBPeripheral.name` is one connection stale after a rename, so the very next scan still advertises the old
        // name -- which is why both are in the filter.
        #expect(settings.string("device_name", field: "name") == "Wobble")
        #expect(settings.string("device_name", field: "previous_name") == "Dibby")
    }

    @Test func testConnectingAgainUnderTheSameNameDoesNotPushThePreviousOneOut() throws {
        #expect(recorder.recordPairing(with: cube))
        let renamed = ScannedDevice(
            id: cube.id, peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        #expect(recorder.recordPairing(with: renamed), "precondition: renamed once")

        #expect(recorder.recordPairing(with: renamed))

        // The name is recorded on every connection, so a rule that moved this each time would undo the one thing it
        // is there for after a single reconnect.
        #expect(settings.string("device_name", field: "previous_name") == "Dibby")
    }

    // MARK: - the name changing on its own account

    @Test func testARenameIsRecordedWithTheNameItReplaces() throws {
        #expect(recorder.recordPairing(with: cube), "precondition: paired as Dibby")

        #expect(recorder.recordName("Plopper", because: "renamed from the Device tab"))

        #expect(settings.string("device_name", field: "name") == "Plopper")
        // The scan straight after a rename still sees the old GAP name, so it stays in the filter.
        #expect(settings.string("device_name", field: "previous_name") == "Dibby")
    }

    @Test func testACubeReportingTheNameItAlreadyHadChangesNothing() throws {
        #expect(recorder.recordPairing(with: cube))
        #expect(recorder.recordName("Plopper", because: "renamed"), "precondition: renamed once")

        #expect(recorder.recordName("Plopper", because: "the cube said so on connecting"))

        // Every connection reports a name, so a rule that moved this each time would undo the one thing
        // `previous_name` is there for after a single reconnect.
        #expect(settings.string("device_name", field: "previous_name") == "Dibby")
    }

    @Test func testRecordingANameIsUnconditional() throws {
        // **Whether a name is worth adopting is asked before this, not inside it** (`DevicePairingRules.adoption`),
        // because the two callers ask it about different things: a rename is this app writing what it sent, and a
        // connection reporting a name is a read that can be out of date. So renaming a cube back to what it was
        // called does exactly what it says.
        #expect(recorder.recordPairing(with: cube))
        #expect(recorder.recordName("Plopper", because: "renamed"), "precondition: renamed to Plopper")

        #expect(recorder.recordName("Dibby", because: "the cube said so on connecting"))

        #expect(settings.string("device_name", field: "name") == "Dibby")
        #expect(settings.string("device_name", field: "previous_name") == "Plopper")
    }

    @Test func testAnEmptyNameIsNotARename() throws {
        #expect(recorder.recordPairing(with: cube), "precondition: paired as Dibby")

        #expect(!(recorder.recordName("   ", because: "nothing at all")))

        #expect(settings.string("device_name", field: "name") == "Dibby")
    }

    @Test func testARenameTouchesNothingElseAboutThePairing() throws {
        #expect(recorder.recordPairing(with: cube))

        #expect(recorder.recordName("Plopper", because: "renamed"))

        #expect(settings.flag("paired", field: "paired") == true)
        #expect(settings.string("device_uuid", field: "uuid") == cube.id.value)
        #expect(settings.flag("connection", field: "connected") == true)
    }

    @Test func testAPairingMadeStraightAfterARenameKeepsTheNewName() throws {
        // The documented way to make a rename show up elsewhere -- rename, forget, scan, pair again -- hands the
        // pairing the GAP name macOS had cached, which is the name the cube was renamed away from. Adopting it would
        // undo the rename at the exact moment somebody was watching for it.
        #expect(recorder.recordPairing(with: cube), "precondition: paired as Dibby")
        #expect(recorder.recordName("Plopper", because: "renamed"), "precondition: renamed to Plopper")

        #expect(recorder.recordPairing(with: cube), "the scan is still handing out Dibby")

        #expect(settings.string("device_name", field: "name") == "Plopper")
        #expect(settings.string("device_name", field: "previous_name") == "Dibby")
    }

    @Test func testACubeGenuinelyRenamedElsewhereIsStillPickedUpByAPairing() throws {
        // The other half of the rule: only the one name it can show is out of date is refused.
        #expect(recorder.recordPairing(with: cube))
        #expect(recorder.recordName("Plopper", because: "renamed"))
        let elsewhere = ScannedDevice(
            id: cube.id, peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )

        #expect(recorder.recordPairing(with: elsewhere))

        #expect(settings.string("device_name", field: "name") == "Wobble")
        #expect(settings.string("device_name", field: "previous_name") == "Plopper")
    }

    // MARK: - losing it

    @Test func testLosingTheConnectionMarksItDownWithoutUnpairing() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")

#expect(recorder.recordConnectionLost(because: "the cube went away", at: try moment("2026-08-17T09:20:00")))

        #expect(settings.flag("connection", field: "connected") == false)
        #expect(settings.string("connection", field: "connection_lost") == "2026-08-17T09:20:00")
        // Going out of range does not change which device this app is paired to, and clearing it here would make the
        // app forget a perfectly good cube the moment somebody carried it out of the room.
        #expect(settings.flag("paired", field: "paired") == true)
        #expect(settings.string("device_uuid", field: "uuid") == cube.id.value)
        #expect(settings.string("device_name", field: "name") == "Dibby")
    }

    // MARK: - getting back to it

    @Test func testAReconnectionMarksTheConnectionUpAgain() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")
        #expect(recorder.recordConnectionLost(because: "the cube went away"), "precondition")

#expect(recorder.recordReconnection(with: cube, at: try moment("2026-08-17T09:30:00")))

        #expect(settings.flag("connection", field: "connected") == true)
        #expect(settings.string("connection", field: "last_connection") == "2026-08-17T09:30:00")
    }

    @Test func testAReconnectionLeavesTheStampFromTheDropAlone() throws {
        // The three fields on that row exist to tell three endings apart, and the last drop is worth being able to see
        // after the app has got back: how long the cube was away is the difference between a flicker and a lunch break.
        #expect(recorder.recordPairing(with: cube), "precondition")
#expect(recorder.recordConnectionLost(because: "the cube went away", at: try moment("2026-08-17T09:20:00")))

#expect(recorder.recordReconnection(with: cube, at: try moment("2026-08-17T09:30:00")))

        #expect(settings.string("connection", field: "connection_lost") == "2026-08-17T09:20:00")
    }

    @Test func testAReconnectionDoesNotRewriteThePairing() throws {
        // A reconnection is not a pairing and must not write one: the pairing rows already say this, and re-writing them
        // on every reconnect is how `previous_name` gets pushed out of the row by a name it never displaced.
        let renamed = ScannedDevice(
            id: cube.id, peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        #expect(recorder.recordPairing(with: cube), "precondition")
        #expect(recorder.recordPairing(with: renamed), "precondition: a rename, so previous_name is filled")
        #expect(settings.string("device_name", field: "previous_name") == "Dibby", "precondition")

        #expect(recorder.recordReconnection(with: renamed))

        #expect(settings.string("device_name", field: "name") == "Wobble")
        #expect(settings.string("device_name", field: "previous_name") == "Dibby")
    }

    // MARK: - quitting

    @Test func testQuittingMarksTheConnectionDownAndSaysItWasDeliberate() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")

#expect(recorder.recordQuit(at: try moment("2026-08-17T17:45:00")))

        #expect(settings.flag("connection", field: "connected") == false)
        #expect(settings.string("connection", field: "quit_request") == "2026-08-17T17:45:00")
        // The pairing is untouched by a quit, exactly as it is by a drop: the app still has a device, it just is not
        // running.
        #expect(settings.flag("paired", field: "paired") == true)
    }

    @Test func testAQuitClearsTheLastDropSoTheTwoAreNotConfused() throws {
#expect(recorder.recordConnectionLost(because: "the cube went away", at: try moment("2026-08-17T09:20:00")))

#expect(recorder.recordQuit(at: try moment("2026-08-17T17:45:00")))

        // Three fields telling three endings apart is only worth anything if a deliberate shutdown does not leave
        // the last drop's stamp sitting there to be read as one.
        #expect(settings.string("connection", field: "connection_lost") == "")
    }

    // MARK: - forgetting

    @Test func testForgettingStopsTheAppHavingADevice() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")

        #expect(recorder.recordForget())

        #expect(settings.flag("paired", field: "paired") == false)
        #expect(settings.string("device_uuid", field: "uuid") == "")
        // A connection is only meaningful while there is a device for it to be to.
        #expect(settings.flag("connection", field: "connected") == false)
    }

    @Test func testForgettingKeepsTheNameTheCubeIsCarrying() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")

        #expect(recorder.recordForget())

        // The archive's rule, and the row's own description: forgetting does not un-rename a cube. Once one has been
        // renamed off "TimeFlip" this string is the only thing a filtered scan can match it on, so discarding it would
        // throw away the way back to the device just forgotten.
        #expect(settings.string("device_name", field: "name") == "Dibby")
    }

    @Test func testForgettingClearsWhatTheCubeSaidItWas() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")
        #expect(recorder.recordInfo(reading), "precondition")

        #expect(recorder.recordForget())

        // The row describes *the paired device*, and after this there is not one. Left behind, it would be attributed
        // to whatever is paired next: `recordInfo` only writes what a cube answers, so a second cube exposing no
        // Device Information service would wear the first one's manufacturer and firmware.
        #expect(
            DeviceInfoRules.detail(isCubePaired: true, reported: settings.string("device_info", field: "firmware")) == "Unknown"
        )
        #expect(
            DeviceInfoRules.detail(isCubePaired: true, reported: settings.string("device_info", field: "manufacturer")) == "Unknown"
        )
    }

    @Test func testASecondCubeDoesNotInheritTheFirstOnesIdentity() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")
        #expect(recorder.recordInfo(reading), "precondition: the first cube said what it was")
        #expect(recorder.recordForget(), "precondition")
        let other = ScannedDevice(
            id: DeviceHandle("0BE1F1CE-0000-4000-8000-000000000002"),
            peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )

        #expect(recorder.recordPairing(with: other))
        // A cube with no Device Information service answers nothing, so nothing is written.
        #expect(recorder.recordInfo(DeviceInfo()))

        #expect(
            DeviceInfoRules.detail(isCubePaired: true, reported: settings.string("device_info", field: "firmware")) == "Unknown",
            "the second cube must not be shown wearing the first one's firmware"
        )
    }

    @Test func testForgettingIsFineWithNothingRecordedAboutTheCube() throws {
        // A pairing that never connected long enough to read the four strings leaves `device_info` seeded empty, and
        // clearing what is not there must not be reported as a refused write.
        #expect(recorder.recordPairing(with: cube), "precondition")

        #expect(recorder.recordForget())
    }

    @Test func testARefusedForgetIsReportedRatherThanAssumed() throws {
        #expect(database.execute("DELETE FROM setting WHERE setting_name = 'paired';"))

        #expect(!(recorder.recordForget()))
    }

    // MARK: - a confirmed factory reset

    @Test func testAConfirmedResetForgetsTheDevice() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")

        #expect(recorder.recordFactoryReset())

        #expect(settings.flag("paired", field: "paired") == false)
        #expect(settings.string("device_uuid", field: "uuid") == "")
        #expect(settings.flag("connection", field: "connected") == false)
    }

    @Test func testAResetTakesTheNameOutOfUseButKeepsItInTheScanFilter() throws {
        #expect(recorder.recordPairing(with: cube), "precondition: paired as Dibby")

        #expect(recorder.recordFactoryReset())

        // A wiped cube is back on the vendor name, so the remembered one is wrong about the hardware and must not go
        // on being presented as its name.
        #expect(settings.string("device_name", field: "name") == "")
        // But it is kept where a scan can still match it. The archive discarded it, having confirmed the wipe out of
        // band first; `0xFF` has no usable acknowledgement, so a wipe that silently failed leaves a cube still called
        // Dibby -- and with the name gone entirely, nothing could find it.
        #expect(settings.string("device_name", field: "previous_name") == "Dibby")
    }

    @Test func testAResetClearsWhatTheCubeSaidItWas() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")
        #expect(recorder.recordInfo(reading), "precondition")

        #expect(recorder.recordFactoryReset())

        #expect(
            DeviceInfoRules.detail(isCubePaired: true, reported: settings.string("device_info", field: "firmware")) == "Unknown"
        )
    }

    @Test func testAResetOnACubeThatNeverSaidItsNameIsStillARest() throws {
        let unnamed = ScannedDevice(
            id: cube.id, peripheralName: nil, advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        #expect(recorder.recordPairing(with: unnamed), "precondition")

        // Nothing to move out of the way, and that must not read as a refused write.
        #expect(recorder.recordFactoryReset())
        #expect(settings.flag("paired", field: "paired") == false)
    }

    // MARK: - what the cube says it is

    private let reading = DeviceInfo(
        manufacturer: "DI_LABS", model: "2.0", hardware: "TFv4.1", firmware: "FW_v3.64"
    )

    @Test func testItRecordsTheFourStringsTheCubeReported() throws {
        #expect(settings.json("device_info")?.isEmpty == true, "precondition: the seeded state is an empty object")

        #expect(recorder.recordInfo(reading))

        #expect(settings.string("device_info", field: "manufacturer") == "DI_LABS")
        #expect(settings.string("device_info", field: "model") == "2.0")
        #expect(settings.string("device_info", field: "hardware") == "TFv4.1")
        #expect(settings.string("device_info", field: "firmware") == "FW_v3.64")
    }

    @Test func testAValueTheCubeDidNotAnswerForLeavesTheStoredOneAlone() throws {
        #expect(recorder.recordInfo(reading), "precondition")

        // A second connection where only the firmware read came back. The other three did not fail to a blank, they
        // did not happen -- and the cube has not stopped being a TFv4.1 because it declined to say so this time.
        #expect(recorder.recordInfo(DeviceInfo(firmware: "FW_v3.70")))

        #expect(settings.string("device_info", field: "firmware") == "FW_v3.70")
        #expect(settings.string("device_info", field: "hardware") == "TFv4.1")
        #expect(settings.string("device_info", field: "manufacturer") == "DI_LABS")
    }

    @Test func testACubeThatSaidNothingWritesNothingAndIsNotAFailure() throws {
        #expect(recorder.recordInfo(reading), "precondition")

        // A cube with no Device Information service is a cube this app reached and paired with. Reporting it as a
        // failed write would put a warning in the log about something that went exactly as it should.
        #expect(recorder.recordInfo(DeviceInfo()))

        #expect(settings.string("device_info", field: "firmware") == "FW_v3.64")
    }

    @Test func testRecordingWhatTheCubeSaysDoesNotTouchThePairing() throws {
        #expect(recorder.recordPairing(with: cube), "precondition")

        #expect(recorder.recordInfo(reading))

        // These reads run after the login and cannot change its outcome, so nothing about them is allowed to reach
        // the rows that say whether the app has a device.
        #expect(settings.flag("paired", field: "paired") == true)
        #expect(settings.flag("connection", field: "connected") == true)
        #expect(settings.string("device_name", field: "name") == "Dibby")
    }

    @Test func testARefusedInfoWriteIsReportedRatherThanAssumed() throws {
        #expect(database.execute("DELETE FROM setting WHERE setting_name = 'device_info';"))

        #expect(!(recorder.recordInfo(reading)))
    }

    // MARK: - when the table refuses

    @Test func testAWriteTheTableRefusedIsReportedRatherThanAssumed() throws {
        // A pairing the table did not take is one the next launch will not find, and the app would spend that launch
        // in manual mode with a perfectly good cube in front of it. `SettingStore.write` reads back, and this is the
        // caller acting on the answer.
        #expect(database.execute("DELETE FROM setting WHERE setting_name = 'paired';"))

        #expect(!(recorder.recordPairing(with: cube)))

        // And the rows that could still be written were: a half-recorded pairing is reported, not rolled back, since
        // the uuid and the name are what a later diagnosis is made from.
        #expect(settings.string("device_uuid", field: "uuid") == cube.id.value)
    }
}

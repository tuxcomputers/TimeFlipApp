@testable import FacetApp
import Foundation
import XCTest

/// What a confirmed login writes into the `setting` table, and what it deliberately leaves alone.
///
/// **Against a real database built from the real DDL**, because the rows' seeded shapes are half the claim: `paired`
/// is seeded `{"paired":false}` and `device_uuid` is seeded `{}`, and a writer that only worked against a row it had
/// invented itself would prove nothing about either.
@MainActor
final class DevicePairingRecorderTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    private var recorder: DevicePairingRecorder!

    private let cube = ScannedDevice(
        id: UUID(uuidString: "0BE1F1CE-0000-4000-8000-000000000001")!,
        peripheralName: "Dibby",
        advertisedName: "TimeFlip v2.0",
        advertisesTimeFlipService: true
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
        recorder = DevicePairingRecorder(settings: settings, debugLog: nil)
    }

    override func tearDown() {
        recorder = nil
        settings = nil
        database.remove()
        super.tearDown()
    }

    private func moment(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try XCTUnwrap(formatter.date(from: text))
    }

    // MARK: - pairing

    func testAConfirmedLoginPairsTheApp() throws {
        XCTAssertEqual(settings.flag("paired", field: "paired"), false, "precondition: the seeded state")

        XCTAssertTrue(recorder.recordPairing(with: cube))

        XCTAssertEqual(settings.flag("paired", field: "paired"), true)
    }

    func testItRecordsWhichDeviceItIs() throws {
        // The peripheral identifier, which is how the app finds the same cube again rather than rediscovering one.
        XCTAssertTrue(recorder.recordPairing(with: cube))

        XCTAssertEqual(settings.string("device_uuid", field: "uuid"), cube.id.uuidString)
    }

    func testItRecordsTheNameTheCubeIsCarrying() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube))

        // The GAP name, not the advertised one and not the list's label.
        XCTAssertEqual(settings.string("device_name", field: "name"), "Dibby")
    }

    func testACubeThatHasNotSaidWhatItIsCalledLeavesTheNameAlone() throws {
        let unnamed = ScannedDevice(
            id: cube.id, peripheralName: nil, advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )

        XCTAssertTrue(recorder.recordPairing(with: unnamed))

        // Paired and unnamed is a real state: the Info panel says `Unknown` rather than `TimeFlip v2.0`, which is a
        // name no rename could ever change.
        XCTAssertEqual(settings.flag("paired", field: "paired"), true)
        XCTAssertNil(settings.string("device_name", field: "name"))
    }

    func testItMarksTheConnectionUp() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube, at: try moment("2026-08-17T09:15:30")))

        XCTAssertEqual(settings.flag("connection", field: "connected"), true)
        XCTAssertEqual(settings.string("connection", field: "last_connection"), "2026-08-17T09:15:30")
    }

    // MARK: - the name it displaced

    func testARenamedCubeKeepsTheNameTheScanIsStillSeeing() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition: paired as Dibby")
        let renamed = ScannedDevice(
            id: cube.id, peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )

        XCTAssertTrue(recorder.recordPairing(with: renamed))

        // `CBPeripheral.name` is one connection stale after a rename, so the very next scan still advertises the old
        // name -- which is why both are in the filter.
        XCTAssertEqual(settings.string("device_name", field: "name"), "Wobble")
        XCTAssertEqual(settings.string("device_name", field: "previous_name"), "Dibby")
    }

    func testConnectingAgainUnderTheSameNameDoesNotPushThePreviousOneOut() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube))
        let renamed = ScannedDevice(
            id: cube.id, peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        XCTAssertTrue(recorder.recordPairing(with: renamed), "precondition: renamed once")

        XCTAssertTrue(recorder.recordPairing(with: renamed))

        // The name is recorded on every connection, so a rule that moved this each time would undo the one thing it
        // is there for after a single reconnect.
        XCTAssertEqual(settings.string("device_name", field: "previous_name"), "Dibby")
    }

    // MARK: - losing it

    func testLosingTheConnectionMarksItDownWithoutUnpairing() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")

        XCTAssertTrue(recorder.recordConnectionLost(because: "the cube went away", at: try moment("2026-08-17T09:20:00")))

        XCTAssertEqual(settings.flag("connection", field: "connected"), false)
        XCTAssertEqual(settings.string("connection", field: "connection_lost"), "2026-08-17T09:20:00")
        // Going out of range does not change which device this app is paired to, and clearing it here would make the
        // app forget a perfectly good cube the moment somebody carried it out of the room.
        XCTAssertEqual(settings.flag("paired", field: "paired"), true)
        XCTAssertEqual(settings.string("device_uuid", field: "uuid"), cube.id.uuidString)
        XCTAssertEqual(settings.string("device_name", field: "name"), "Dibby")
    }

    // MARK: - quitting

    func testQuittingMarksTheConnectionDownAndSaysItWasDeliberate() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")

        XCTAssertTrue(recorder.recordQuit(at: try moment("2026-08-17T17:45:00")))

        XCTAssertEqual(settings.flag("connection", field: "connected"), false)
        XCTAssertEqual(settings.string("connection", field: "quit_request"), "2026-08-17T17:45:00")
        // The pairing is untouched by a quit, exactly as it is by a drop: the app still has a device, it just is not
        // running.
        XCTAssertEqual(settings.flag("paired", field: "paired"), true)
    }

    func testAQuitClearsTheLastDropSoTheTwoAreNotConfused() throws {
        XCTAssertTrue(recorder.recordConnectionLost(because: "the cube went away", at: try moment("2026-08-17T09:20:00")))

        XCTAssertTrue(recorder.recordQuit(at: try moment("2026-08-17T17:45:00")))

        // Three fields telling three endings apart is only worth anything if a deliberate shutdown does not leave
        // the last drop's stamp sitting there to be read as one.
        XCTAssertEqual(settings.string("connection", field: "connection_lost"), "")
    }

    // MARK: - forgetting

    func testForgettingStopsTheAppHavingADevice() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")

        XCTAssertTrue(recorder.recordForget())

        XCTAssertEqual(settings.flag("paired", field: "paired"), false)
        XCTAssertEqual(settings.string("device_uuid", field: "uuid"), "")
        // A connection is only meaningful while there is a device for it to be to.
        XCTAssertEqual(settings.flag("connection", field: "connected"), false)
    }

    func testForgettingKeepsTheNameTheCubeIsCarrying() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")

        XCTAssertTrue(recorder.recordForget())

        // The archive's rule, and the row's own description: forgetting does not un-rename a cube. Once one has been
        // renamed off "TimeFlip" this string is the only thing a filtered scan can match it on, so discarding it would
        // throw away the way back to the device just forgotten.
        XCTAssertEqual(settings.string("device_name", field: "name"), "Dibby")
    }

    func testForgettingClearsWhatTheCubeSaidItWas() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")
        XCTAssertTrue(recorder.recordInfo(reading), "precondition")

        XCTAssertTrue(recorder.recordForget())

        // The row describes *the paired device*, and after this there is not one. Left behind, it would be attributed
        // to whatever is paired next: `recordInfo` only writes what a cube answers, so a second cube exposing no
        // Device Information service would wear the first one's manufacturer and firmware.
        XCTAssertEqual(DeviceInfoRules.detail(isPaired: true, reported: settings.string("device_info", field: "firmware")), "Unknown")
        XCTAssertEqual(DeviceInfoRules.detail(isPaired: true, reported: settings.string("device_info", field: "manufacturer")), "Unknown")
    }

    func testASecondCubeDoesNotInheritTheFirstOnesIdentity() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")
        XCTAssertTrue(recorder.recordInfo(reading), "precondition: the first cube said what it was")
        XCTAssertTrue(recorder.recordForget(), "precondition")
        let other = ScannedDevice(
            id: UUID(uuidString: "0BE1F1CE-0000-4000-8000-000000000002")!,
            peripheralName: "Wobble", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )

        XCTAssertTrue(recorder.recordPairing(with: other))
        // A cube with no Device Information service answers nothing, so nothing is written.
        XCTAssertTrue(recorder.recordInfo(DeviceInfo()))

        XCTAssertEqual(
            DeviceInfoRules.detail(isPaired: true, reported: settings.string("device_info", field: "firmware")),
            "Unknown",
            "the second cube must not be shown wearing the first one's firmware"
        )
    }

    func testForgettingIsFineWithNothingRecordedAboutTheCube() throws {
        // A pairing that never connected long enough to read the four strings leaves `device_info` seeded empty, and
        // clearing what is not there must not be reported as a refused write.
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")

        XCTAssertTrue(recorder.recordForget())
    }

    func testARefusedForgetIsReportedRatherThanAssumed() throws {
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'paired';"))

        XCTAssertFalse(recorder.recordForget())
    }

    // MARK: - a confirmed factory reset

    func testAConfirmedResetForgetsTheDevice() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")

        XCTAssertTrue(recorder.recordFactoryReset())

        XCTAssertEqual(settings.flag("paired", field: "paired"), false)
        XCTAssertEqual(settings.string("device_uuid", field: "uuid"), "")
        XCTAssertEqual(settings.flag("connection", field: "connected"), false)
    }

    func testAResetTakesTheNameOutOfUseButKeepsItInTheScanFilter() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition: paired as Dibby")

        XCTAssertTrue(recorder.recordFactoryReset())

        // A wiped cube is back on the vendor name, so the remembered one is wrong about the hardware and must not go
        // on being presented as its name.
        XCTAssertEqual(settings.string("device_name", field: "name"), "")
        // But it is kept where a scan can still match it. The archive discarded it, having confirmed the wipe out of
        // band first; `0xFF` has no usable acknowledgement, so a wipe that silently failed leaves a cube still called
        // Dibby -- and with the name gone entirely, nothing could find it.
        XCTAssertEqual(settings.string("device_name", field: "previous_name"), "Dibby")
    }

    func testAResetClearsWhatTheCubeSaidItWas() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")
        XCTAssertTrue(recorder.recordInfo(reading), "precondition")

        XCTAssertTrue(recorder.recordFactoryReset())

        XCTAssertEqual(
            DeviceInfoRules.detail(isPaired: true, reported: settings.string("device_info", field: "firmware")),
            "Unknown"
        )
    }

    func testAResetOnACubeThatNeverSaidItsNameIsStillARest() throws {
        let unnamed = ScannedDevice(
            id: cube.id, peripheralName: nil, advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        XCTAssertTrue(recorder.recordPairing(with: unnamed), "precondition")

        // Nothing to move out of the way, and that must not read as a refused write.
        XCTAssertTrue(recorder.recordFactoryReset())
        XCTAssertEqual(settings.flag("paired", field: "paired"), false)
    }

    // MARK: - what the cube says it is

    private let reading = DeviceInfo(
        manufacturer: "DI_LABS", model: "2.0", hardware: "TFv4.1", firmware: "FW_v3.64"
    )

    func testItRecordsTheFourStringsTheCubeReported() throws {
        XCTAssertEqual(settings.json("device_info")?.isEmpty, true, "precondition: the seeded state is an empty object")

        XCTAssertTrue(recorder.recordInfo(reading))

        XCTAssertEqual(settings.string("device_info", field: "manufacturer"), "DI_LABS")
        XCTAssertEqual(settings.string("device_info", field: "model"), "2.0")
        XCTAssertEqual(settings.string("device_info", field: "hardware"), "TFv4.1")
        XCTAssertEqual(settings.string("device_info", field: "firmware"), "FW_v3.64")
    }

    func testAValueTheCubeDidNotAnswerForLeavesTheStoredOneAlone() throws {
        XCTAssertTrue(recorder.recordInfo(reading), "precondition")

        // A second connection where only the firmware read came back. The other three did not fail to a blank, they
        // did not happen -- and the cube has not stopped being a TFv4.1 because it declined to say so this time.
        XCTAssertTrue(recorder.recordInfo(DeviceInfo(firmware: "FW_v3.70")))

        XCTAssertEqual(settings.string("device_info", field: "firmware"), "FW_v3.70")
        XCTAssertEqual(settings.string("device_info", field: "hardware"), "TFv4.1")
        XCTAssertEqual(settings.string("device_info", field: "manufacturer"), "DI_LABS")
    }

    func testACubeThatSaidNothingWritesNothingAndIsNotAFailure() throws {
        XCTAssertTrue(recorder.recordInfo(reading), "precondition")

        // A cube with no Device Information service is a cube this app reached and paired with. Reporting it as a
        // failed write would put a warning in the log about something that went exactly as it should.
        XCTAssertTrue(recorder.recordInfo(DeviceInfo()))

        XCTAssertEqual(settings.string("device_info", field: "firmware"), "FW_v3.64")
    }

    func testRecordingWhatTheCubeSaysDoesNotTouchThePairing() throws {
        XCTAssertTrue(recorder.recordPairing(with: cube), "precondition")

        XCTAssertTrue(recorder.recordInfo(reading))

        // These reads run after the login and cannot change its outcome, so nothing about them is allowed to reach
        // the rows that say whether the app has a device.
        XCTAssertEqual(settings.flag("paired", field: "paired"), true)
        XCTAssertEqual(settings.flag("connection", field: "connected"), true)
        XCTAssertEqual(settings.string("device_name", field: "name"), "Dibby")
    }

    func testARefusedInfoWriteIsReportedRatherThanAssumed() throws {
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'device_info';"))

        XCTAssertFalse(recorder.recordInfo(reading))
    }

    // MARK: - when the table refuses

    func testAWriteTheTableRefusedIsReportedRatherThanAssumed() throws {
        // A pairing the table did not take is one the next launch will not find, and the app would spend that launch
        // in manual mode with a perfectly good cube in front of it. `SettingStore.write` reads back, and this is the
        // caller acting on the answer.
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'paired';"))

        XCTAssertFalse(recorder.recordPairing(with: cube))

        // And the rows that could still be written were: a half-recorded pairing is reported, not rolled back, since
        // the uuid and the name are what a later diagnosis is made from.
        XCTAssertEqual(settings.string("device_uuid", field: "uuid"), cube.id.uuidString)
    }
}

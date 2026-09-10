@testable import FacetCore
import Foundation
import Testing

/// The login sequence, driven through `CubeGatt` with no radio and no cube.
///
/// **`DeviceLogin` has never had a test.** It held a `CBPeripheral`, so exercising it needed real hardware, and
/// everything it decides was covered only by `Tests/Scripted/50`-`66` and by whoever was watching the run.
/// `DeviceLoginRules` was always tested, but the rules are the easy half: what this covers is the sequence, and
/// in particular **which UUID an answer is filed under**, which is the part a refactor breaks silently.
///
/// **That is not hypothetical.** Moving this file onto the port on 2026-09-10 broke it in exactly that way and
/// the compiler was perfectly happy: a real adapter answers in the canonical spelling, lowercase and with the
/// vendor's 16-bit shorthand expanded, and eleven comparisons in here were `==` against the constants as
/// written. `2A29` is not `00002a29-0000-1000-8000-00805f9b34fb`, so the login would have discovered its
/// characteristics, presented no PIN, and reported nothing at all. These tests are what would have caught it.
@Suite @MainActor
final class DeviceLoginTests {
    private let gatt = InMemoryGatt()
    private let clock = HandDrivenScheduler()

    private var outcome: DeviceLoginOutcome?
    private var reportedInfo: DeviceInfo?
    private var reportedFace: Int?

    private func login(pin: String = "000000", debugLog: DebugLog? = nil) -> DeviceLogin {
        DeviceLogin(
            gatt: gatt,
            pin: pin,
            rotatingTo: nil,
            debugLog: debugLog,
            scheduler: clock,
            rotated: { _ in },
            reported: { [self] in reportedInfo = $0 },
            face: { [self] in reportedFace = $0 },
            finished: { [self] in outcome = $0 }
        )
    }

    /// Everything up to the moment a PIN is presented.
    private func reachThePINPrompt(_ login: DeviceLogin) {
        login.begin()
        gatt.answerServices([TimeFlipUUIDs.serviceString])
        gatt.answerCharacteristics(
            [TimeFlipUUIDs.passwordString, TimeFlipUUIDs.commandResultString, TimeFlipUUIDs.commandString],
            ofService: TimeFlipUUIDs.serviceString
        )
    }

    // MARK: - finding the cube

    @Test func testItAsksForTheTimeFlipServiceAndThenItsThreeCharacteristics() {
        let login = login()

        login.begin()
        gatt.answerServices([TimeFlipUUIDs.serviceString])

        #expect(gatt.servicesAsked == [[TimeFlipUUIDs.serviceString]], "only the one service, never everything")
        let asked = gatt.characteristicsAsked.last
        #expect(asked?.service == TimeFlipUUIDs.serviceString)
        #expect(asked?.uuids?.count == 3, "the password, the command and the command result")
    }

    @Test func testSomethingWithoutTheTimeFlipServiceIsNotATimeFlip() {
        // A better test than the name the scan filtered on: names are chosen by people and this is the hardware
        // saying what it is.
        let login = login()

        login.begin()
        gatt.answerServices(["180F"])

        #expect(outcome == .notATimeFlip)
    }

    @Test func testAFailedServiceDiscoveryIsUnreachableRatherThanNotATimeFlip() {
        // The two have opposite remedies: one is a device to stop trying, the other is a link to try again.
        let login = login()

        login.begin()
        gatt.answerServices([], failed: "the link went")

        #expect(outcome == .unreachable)
    }

    // MARK: - the PIN

    @Test func testThePINGoesToThePasswordCharacteristicAndIsAcknowledged() throws {
        // **The test that would have caught the canonical-spelling bug.** A real adapter answers in the
        // canonical spelling; if the login compares that against the constant as written, it files none of its
        // three characteristics, and this write never happens.
        let login = login(pin: "123456")

        reachThePINPrompt(login)

        let written = try #require(gatt.writes.last)
        #expect(written.payload == Data("123456".utf8))
        #expect(written.characteristic == TimeFlipUUIDs.canonical(TimeFlipUUIDs.passwordString))
        #expect(written.acknowledged, "so a write the cube refused is distinguishable from one it took")
    }

    @Test func testAServiceMissingThePasswordCharacteristicIsNotATimeFlip() {
        let login = login()

        login.begin()
        gatt.answerServices([TimeFlipUUIDs.serviceString])
        gatt.answerCharacteristics([TimeFlipUUIDs.commandString], ofService: TimeFlipUUIDs.serviceString)

        #expect(outcome == .notATimeFlip)
    }

    @Test func testTheVerdictIsReadOnlyOnceTheWriteIsAcknowledged() {
        // Reading before the cube has processed the write is how a stale command result gets mistaken for an
        // answer, which is finding 2 in the firmware observations.
        let login = login()
        reachThePINPrompt(login)
        #expect(gatt.reads.isEmpty, "nothing is read while the PIN is still in flight")

        gatt.acknowledge(TimeFlipUUIDs.passwordString)

        #expect(gatt.reads.last == TimeFlipUUIDs.canonical(TimeFlipUUIDs.commandResultString))
    }

    @Test func testAPINTheCubeWillNotEvenTakeEndsTheAttempt() {
        let login = login()
        reachThePINPrompt(login)

        gatt.acknowledge(TimeFlipUUIDs.passwordString, failed: "the cube refused the write")

        #expect(outcome != nil, "the attempt ends rather than waiting for an answer that is not coming")
    }

    // MARK: - what the cube says about itself

    @Test func testTheFourDeviceInformationValuesAreFiledUnderTheRightNames() throws {
        // **The second half of the canonical bug.** These four UUIDs are written in the vendor's 16-bit
        // shorthand and arrive expanded, so a switch over the shorthand files none of them: the reads would all
        // answer and the Device tab would sit empty with nothing in the log to say why.
        let login = login()
        // `begin` first, because that is what hands the login to the GATT table as its listener, and because it
        // is what happens on a real connection: Device Information is asked for after the login, never instead.
        login.begin()
        login.readDeviceInfo()
        gatt.answerServices([TimeFlipUUIDs.deviceInformationString])
        gatt.answerCharacteristics(
            TimeFlipUUIDs.deviceInformationCharacteristicStrings, ofService: TimeFlipUUIDs.deviceInformationString
        )

        gatt.deliver(Data("DI_LABS".utf8), from: TimeFlipUUIDs.manufacturerNameString)
        gatt.deliver(Data("2.0".utf8), from: TimeFlipUUIDs.modelNumberString)
        gatt.deliver(Data("TFv4.1".utf8), from: TimeFlipUUIDs.hardwareRevisionString)
        gatt.deliver(Data("FW_v3.64".utf8), from: TimeFlipUUIDs.firmwareRevisionString)

        let info = try #require(reportedInfo)
        #expect(info.manufacturer == "DI_LABS")
        #expect(info.model == "2.0")
        #expect(info.hardware == "TFv4.1")
        #expect(info.firmware == "FW_v3.64")
    }

    @Test func testOnlyTheValuesTheCubeActuallyHasAreWaitedFor() throws {
        // A cube exposing three of the four answers three reads and reports three values, rather than the whole
        // lot timing out behind one that was never going to arrive.
        let login = login()
        // `begin` first, because that is what hands the login to the GATT table as its listener, and because it
        // is what happens on a real connection: Device Information is asked for after the login, never instead.
        login.begin()
        login.readDeviceInfo()
        gatt.answerServices([TimeFlipUUIDs.deviceInformationString])
        gatt.answerCharacteristics(
            [TimeFlipUUIDs.manufacturerNameString, TimeFlipUUIDs.modelNumberString],
            ofService: TimeFlipUUIDs.deviceInformationString
        )

        gatt.deliver(Data("DI_LABS".utf8), from: TimeFlipUUIDs.manufacturerNameString)
        gatt.deliver(Data("2.0".utf8), from: TimeFlipUUIDs.modelNumberString)

        let info = try #require(reportedInfo, "reported once the two it has are in, not held for the other two")
        #expect(info.manufacturer == "DI_LABS")
        #expect(info.firmware == nil)
    }

    // MARK: - the rows a scripted check reads

    /// **The row that broke, and the test that would have caught it.** `51-device-connect` waits on
    /// `Found characteristic commandResult%` to decide whether what it connected to is a TimeFlip at all.
    ///
    /// Moving this file into the core on 2026-09-10 changed that row to `Found characteristic command result`,
    /// because the core held a second naming table nothing had ever called and the login started resolving to it.
    /// Everything compiled, all 1846 hermetic tests passed, and the run failed on hardware.
    @Test func testEachCharacteristicIsLoggedUnderTheNameTheTraceIsReadBackBy() throws {
        let database = TemporaryDatabase()
        defer { database.remove() }
        try database.bootstrap()
        let log = DebugLog(databaseURL: database.debugURL, isRecording: true)

        reachThePINPrompt(login(debugLog: log))

        let rows = database.debugString("SELECT group_concat(message, ' | ') FROM debug_log;") ?? ""
        #expect(rows.contains("Found characteristic commandResult"), "\(rows)")
        #expect(rows.contains("Found characteristic password"), "\(rows)")
        #expect(!rows.contains("command result"), "the spelling nothing reads back")
    }
}

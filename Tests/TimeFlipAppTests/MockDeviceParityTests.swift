@testable import TimeFlipApp
import Foundation
import XCTest

/// Functions the real `TimeFlipBLEDevice` offers that the mock now offers too, so a workflow can
/// exercise them without hardware. See `docs/TODO-mock-device-parity.md`.
@MainActor
final class MockDeviceParityTests: XCTestCase {
    private func makeDevice(loggedIn: Bool) async -> MockTimeFlipDevice {
        let device = MockTimeFlipDevice(configuration: .init(emitInitialStatus: false))
        if loggedIn {
            _ = await device.login(password: TimeFlipConstants.defaultPassword)
        }
        return device
    }

    // MARK: - readDeviceTime

    func testReadDeviceTimeReturnsNilWhenNotLoggedIn() async {
        let device = await makeDevice(loggedIn: false)
        let time = await device.readDeviceTime()
        XCTAssertNil(time, "an unauthenticated session gets no answer, as on the real device")
    }

    func testReadDeviceTimeReflectsTheDevicesOwnClock() async throws {
        let device = await makeDevice(loggedIn: true)
        let deviceNow = Date(timeIntervalSince1970: 1_700_000_000)
        device.setDeviceTime(deviceNow)

        let readTime = await device.readDeviceTime()
        let read = try XCTUnwrap(readTime)

        // The device's clock, not the host's -- they differ by design until a session syncs them.
        XCTAssertEqual(read.timeIntervalSince1970, deviceNow.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertGreaterThan(abs(read.timeIntervalSinceNow), 60, "should not just be the host clock")
    }
}

// MARK: - Password rotation

extension MockDeviceParityTests {
    func testRotatingThePasswordRequiresBeingLoggedIn() async {
        let device = await makeDevice(loggedIn: false)
        let rotated = await device.rotateDevicePassword()
        XCTAssertNil(rotated, "an unauthenticated session cannot set a password")
    }

    func testRotatingThePasswordLeavesTheNewOneWorkingAndTheOldOneRejected() async throws {
        let device = await makeDevice(loggedIn: true)

        let rotatedValue = await device.rotateDevicePassword()
        let rotated = try XCTUnwrap(rotatedValue, "rotation should succeed and report the new password")
        XCTAssertNotEqual(rotated, TimeFlipConstants.defaultPassword)

        // The confirming re-login is the point: the new password must genuinely work...
        let newWorks = await device.login(password: rotated)
        XCTAssertTrue(newWorks)
        // ...and the old one must not, or the device would be left reachable on a stale secret.
        let oldWorks = await device.login(password: TimeFlipConstants.defaultPassword)
        XCTAssertFalse(oldWorks, "the previous password should stop working once rotated")
    }

    func testResettingThePasswordPutsTheDefaultBack() async throws {
        let device = await makeDevice(loggedIn: true)
        let rotatedValue = await device.rotateDevicePassword()
        let rotated = try XCTUnwrap(rotatedValue)

        let reset = await device.resetDevicePasswordToDefault()
        XCTAssertTrue(reset)

        let defaultWorks = await device.login(password: TimeFlipConstants.defaultPassword)
        XCTAssertTrue(defaultWorks, "Forget Device must not strand the cube on a password nobody has")
        let rotatedStillWorks = await device.login(password: rotated)
        XCTAssertFalse(rotatedStillWorks)
    }

    func testResettingThePasswordRequiresBeingLoggedIn() async {
        let device = await makeDevice(loggedIn: false)
        let reset = await device.resetDevicePasswordToDefault()
        XCTAssertFalse(reset)
    }

    /// A password reset is not a factory reset: history and pairing are untouched.
    func testResettingThePasswordDoesNotTouchHistoryOrPairing() async {
        let device = await makeDevice(loggedIn: true)
        device.seedHistory([
            TimeFlipHistoryEntry(
                eventNumber: 1234,
                faceID: 3,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 60,
                isPaused: false
            )
        ])

        _ = await device.resetDevicePasswordToDefault()

        XCTAssertEqual(device.history.count, 1, "history must survive a password reset")
        XCTAssertTrue(device.isPaired, "and the device stays paired")
    }
}

// MARK: - Task/pomodoro parameters and device name (0x13, 0x14, 0x15, 0xFE)
//
// COMMENTED OUT ON PURPOSE. The driver and the mock both implement these four commands, completing
// the spec's command set, but **the app has no task/pomodoro or device-name feature** -- nothing in
// the UI or the data model uses them. Testing them now would assert behaviour no product decision
// has been made about yet, and those assertions would have to be rewritten the moment one is.
//
// Kept rather than deleted because the commands are real, the wire formats below were written
// against `docs/TimeFlip2 BLE Protocol v4.3.md`, and re-deriving them later is wasted work.
// Uncomment when the feature lands; they compile as written (the `await`s are hoisted out of the
// XCTAssert autoclosures, which is a compile error otherwise).
//
// extension MockDeviceParityTests {
//     func testTaskParametersRoundTrip() async throws {
//         let device = await makeDevice(loggedIn: true)
//         let written = FaceTaskParameters(faceID: 3, mode: .pomodoro, limitSeconds: 1_500)
//
//         let ok = await device.setFaceTaskParameters(written)
//         XCTAssertTrue(ok)
//
//         let value = await device.readFaceTaskParameters(faceID: 3)
//         let readBack = try XCTUnwrap(value)
//         XCTAssertEqual(readBack, written, "what comes back should be what went in")
//     }
//
//     func testAFaceNeverConfiguredReadsAsSimpleWithNoLimit() async throws {
//         let device = await makeDevice(loggedIn: true)
//         let value = await device.readFaceTaskParameters(faceID: 7)
//         let params = try XCTUnwrap(value)
//         XCTAssertEqual(params.mode, .simple)
//         XCTAssertEqual(params.limitSeconds, 0)
//     }
//
//     /// The elapsed field is the only reason 0x14 differs from what was written, so it has to
//     /// track the device's own clock rather than being echoed back as zero.
//     func testElapsedSecondsAdvancesWithTheDeviceClock() async throws {
//         let device = await makeDevice(loggedIn: true)
//         let start = Date(timeIntervalSince1970: 1_700_000_000)
//         device.setDeviceTime(start)
//         _ = await device.setFaceTaskParameters(
//             FaceTaskParameters(faceID: 2, mode: .pomodoro, limitSeconds: 600)
//         )
//
//         let atStart = await device.readFaceTaskParameters(faceID: 2)
//         XCTAssertEqual(try XCTUnwrap(atStart).elapsedSeconds, 0)
//
//         device.setDeviceTime(start.addingTimeInterval(90))
//         let later = await device.readFaceTaskParameters(faceID: 2)
//         XCTAssertEqual(try XCTUnwrap(later).elapsedSeconds, 90)
//     }
//
//     func testTaskParametersRequireBeingLoggedIn() async {
//         let device = await makeDevice(loggedIn: false)
//         let written = await device.setFaceTaskParameters(
//             FaceTaskParameters(faceID: 1, mode: .pomodoro, limitSeconds: 60)
//         )
//         XCTAssertFalse(written)
//         let read = await device.readFaceTaskParameters(faceID: 1)
//         XCTAssertNil(read)
//     }
//
//     func testAnInvalidFaceIsRejected() async {
//         let device = await makeDevice(loggedIn: true)
//         let written = await device.setFaceTaskParameters(
//             FaceTaskParameters(faceID: 99, mode: .pomodoro, limitSeconds: 60)
//         )
//         XCTAssertFalse(written, "face 99 doesn't exist on a 12-face cube")
//     }
//
//     /// An unrecognised mode is preserved rather than coerced, so a read-modify-write against
//     /// newer firmware can't silently downgrade a mode this build doesn't know about.
//     func testAnUnknownModeSurvivesARoundTrip() async throws {
//         let device = await makeDevice(loggedIn: true)
//         _ = await device.setFaceTaskParameters(
//             FaceTaskParameters(faceID: 4, mode: .unknown(7), limitSeconds: 30)
//         )
//         let value = await device.readFaceTaskParameters(faceID: 4)
//         XCTAssertEqual(try XCTUnwrap(value).mode, .unknown(7))
//     }
//
//     /// 0xFE is not 0xFF. Modelling it is only worth anything if it stays narrow.
//     func testResettingTaskInfoClearsTasksAndNothingElse() async throws {
//         let device = await makeDevice(loggedIn: true)
//         _ = await device.setFaceTaskParameters(
//             FaceTaskParameters(faceID: 5, mode: .pomodoro, limitSeconds: 900)
//         )
//         _ = await device.setDeviceName("Desk cube")
//         device.seedHistory([
//             TimeFlipHistoryEntry(
//                 eventNumber: 42,
//                 faceID: 5,
//                 startedAt: Date(timeIntervalSince1970: 1_700_000_000),
//                 duration: 60,
//                 isPaused: false
//             )
//         ])
//
//         let reset = await device.resetTaskInfoToDefault()
//         XCTAssertTrue(reset)
//
//         let value = await device.readFaceTaskParameters(faceID: 5)
//         XCTAssertEqual(try XCTUnwrap(value).mode, .simple)
//         // Everything a factory reset would take, and this must not:
//         XCTAssertEqual(device.history.count, 1, "history survives a task reset")
//         XCTAssertTrue(device.isPaired, "pairing survives")
//         XCTAssertEqual(device.deviceName, "Desk cube", "the name survives")
//     }
//
//     func testAFactoryResetAlsoClearsTaskInfo() async throws {
//         let device = await makeDevice(loggedIn: true)
//         _ = await device.setFaceTaskParameters(
//             FaceTaskParameters(faceID: 6, mode: .pomodoro, limitSeconds: 300)
//         )
//
//         _ = await device.factoryReset()
//         device.pair()
//         _ = await device.login(password: TimeFlipConstants.defaultPassword)
//
//         let value = await device.readFaceTaskParameters(faceID: 6)
//         XCTAssertEqual(try XCTUnwrap(value).mode, .simple, "0xFF takes task info too")
//     }
//
//     func testSettingTheDeviceName() async {
//         let device = await makeDevice(loggedIn: true)
//         let ok = await device.setDeviceName("Harry's cube")
//         XCTAssertTrue(ok)
//         XCTAssertEqual(device.deviceName, "Harry's cube")
//     }
//
//     func testANameOverEighteenCharactersIsRejected() async {
//         let device = await makeDevice(loggedIn: true)
//         let tooLong = await device.setDeviceName(String(repeating: "a", count: 19))
//         XCTAssertFalse(tooLong)
//         let atLimit = await device.setDeviceName(String(repeating: "a", count: 18))
//         XCTAssertTrue(atLimit, "18 is the spec's maximum, and is allowed")
//     }
//
//     func testANonASCIINameIsRejected() async {
//         let device = await makeDevice(loggedIn: true)
//         // Fits in 18 characters but not 18 bytes -- the payload declares a byte count, so a
//         // multi-byte character would make the declared length disagree with what was sent.
//         let accepted = await device.setDeviceName("café ☕")
//         XCTAssertFalse(accepted)
//     }
// }
//
// // Wire format, straight from the spec -- worth keeping verbatim, since re-deriving byte layouts
// // from the PDF is the slow part.
// extension MockDeviceParityTests {
//     func testTheWritePayloadMatchesTheSpecLayout() {
//         let params = FaceTaskParameters(faceID: 3, mode: .pomodoro, limitSeconds: 1_500)
//         // 0x13 0xNN 0xPP 0xTT 0xTT 0xTT 0xTT, big-endian; 1500 == 0x000005DC.
//         XCTAssertEqual([UInt8](params.commandPayload()), [0x13, 0x03, 0x01, 0x00, 0x00, 0x05, 0xDC])
//     }
//
//     func testParsingAReadResponseMatchesTheSpecLayout() throws {
//         // 0x14 0xNN 0xPP 0xTT x4 0xCC x4 -- face 9, pomodoro, limit 3600, elapsed 120.
//         let frame = Data([0x14, 0x09, 0x01, 0x00, 0x00, 0x0E, 0x10, 0x00, 0x00, 0x00, 0x78])
//         let parsed = try XCTUnwrap(FaceTaskParameters.parse(frame))
//         XCTAssertEqual(parsed.faceID, 9)
//         XCTAssertEqual(parsed.mode, .pomodoro)
//         XCTAssertEqual(parsed.limitSeconds, 3_600)
//         XCTAssertEqual(parsed.elapsedSeconds, 120)
//     }
//
//     func testAMalformedResponseParsesAsNilRatherThanAHalfFilledValue() {
//         XCTAssertNil(FaceTaskParameters.parse(Data([0x14, 0x09])), "too short")
//         XCTAssertNil(FaceTaskParameters.parse(Data(repeating: 0x17, count: 11)), "wrong opcode")
//         XCTAssertNil(FaceTaskParameters.parse(Data()), "empty")
//     }
//
//     /// A `Data` slice off a characteristic read keeps its parent's `startIndex`, so parsing that
//     /// indexes from 0 would read the wrong bytes or trap outright.
//     func testParsingWorksOnASlicedData() throws {
//         let padded = Data([0xFF, 0xFF])
//             + Data([0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x05])
//         let parsed = try XCTUnwrap(FaceTaskParameters.parse(padded.dropFirst(2)))
//         XCTAssertEqual(parsed.faceID, 2)
//         XCTAssertEqual(parsed.limitSeconds, 42)
//     }
//
//     /// `elapsedSeconds` is a running clock, so equality has to ignore it or a value read a second
//     /// apart wouldn't equal itself and "did the write take?" couldn't be asserted.
//     func testEqualityIgnoresTheRunningElapsedClock() {
//         let a = FaceTaskParameters(faceID: 1, mode: .pomodoro, limitSeconds: 60, elapsedSeconds: 5)
//         let b = FaceTaskParameters(faceID: 1, mode: .pomodoro, limitSeconds: 60, elapsedSeconds: 55)
//         XCTAssertEqual(a, b)
//     }
// }

// MARK: - Discovery and pairing

extension MockDeviceParityTests {
    private func scannedDevice(named name: String) -> DiscoveredBLEDevice {
        DiscoveredBLEDevice(id: UUID(), name: name)
    }

    func testScanningReportsEachStagedDeviceThroughTheCallback() async {
        let device = MockTimeFlipDevice(configuration: .init(emitInitialStatus: false))
        device.discoverableDevices = [scannedDevice(named: "TimeFlip v2.0"), scannedDevice(named: "TimeFlip v2.0")]
        var found: [DiscoveredBLEDevice] = []
        device.onDeviceDiscovered = { found.append($0) }

        await device.startDiscoveryScan(filterToTimeFlip: true)

        XCTAssertEqual(found.count, 2)
    }

    func testScanningWithNothingInRangeReportsNothing() async {
        let device = MockTimeFlipDevice(configuration: .init(emitInitialStatus: false))
        device.discoverableDevices = []
        var found: [DiscoveredBLEDevice] = []
        device.onDeviceDiscovered = { found.append($0) }

        await device.startDiscoveryScan(filterToTimeFlip: true)

        XCTAssertTrue(found.isEmpty, "no cube in range is a case worth being able to test")
    }

    func testTheTimeFlipFilterExcludesOtherDevices() async {
        let device = MockTimeFlipDevice(configuration: .init(emitInitialStatus: false))
        device.discoverableDevices = [scannedDevice(named: "Someone's Headphones"), scannedDevice(named: "TimeFlip v2.0")]
        var filtered: [DiscoveredBLEDevice] = []
        device.onDeviceDiscovered = { filtered.append($0) }
        await device.startDiscoveryScan(filterToTimeFlip: true)
        XCTAssertEqual(filtered.map(\.name), ["TimeFlip v2.0"])

        var unfiltered: [DiscoveredBLEDevice] = []
        device.onDeviceDiscovered = { unfiltered.append($0) }
        await device.startDiscoveryScan(filterToTimeFlip: false)
        XCTAssertEqual(unfiltered.count, 2, "the show-everything pairing path should see both")
    }

    func testStoppingAScanFiresTheStoppedCallbackOnlyOnce() async {
        let device = MockTimeFlipDevice(configuration: .init(emitInitialStatus: false))
        var stops = 0
        device.onDiscoveryScanStopped = { stops += 1 }

        await device.startDiscoveryScan(filterToTimeFlip: true)
        device.stopDiscoveryScan()
        device.stopDiscoveryScan()

        XCTAssertEqual(stops, 1, "a second stop with no scan running is a no-op")
    }

    func testConnectingToAScannedDeviceLogsInAndPairs() async {
        let device = MockTimeFlipDevice(configuration: .init(isInitiallyPaired: false, emitInitialStatus: false))
        let target = scannedDevice(named: "TimeFlip v2.0")
        device.discoverableDevices = [target]

        let outcome = await device.connectToDiscoveredDevice(id: target.id, password: TimeFlipConstants.defaultPassword)

        XCTAssertEqual(outcome, .connected)
        XCTAssertTrue(device.isPaired, "a successful pair should leave the device paired")
    }

    func testAWrongPasswordIsReportedDistinctlyFromOtherFailures() async {
        let device = MockTimeFlipDevice(configuration: .init(isInitiallyPaired: false, emitInitialStatus: false))
        let target = scannedDevice(named: "TimeFlip v2.0")
        device.discoverableDevices = [target]

        let outcome = await device.connectToDiscoveredDevice(id: target.id, password: "999999")

        // Distinct from .failed on purpose: the UI says "Wrong PIN" for one and not the other.
        XCTAssertEqual(outcome, .wrongPassword)
        XCTAssertFalse(device.isPaired)
    }

    func testConnectingToSomethingThatWasNeverScannedIsNotATimeFlip() async {
        let device = MockTimeFlipDevice(configuration: .init(isInitiallyPaired: false, emitInitialStatus: false))
        device.discoverableDevices = []

        let outcome = await device.connectToDiscoveredDevice(id: UUID(), password: TimeFlipConstants.defaultPassword)

        XCTAssertEqual(outcome, .notTimeFlip)
    }

    func testCancellingBeforeConnectingReportsCancelled() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.connect = .milliseconds(80, 120)
        let device = MockTimeFlipDevice(
            configuration: .init(isInitiallyPaired: false, emitInitialStatus: false, latency: latency)
        )
        let target = scannedDevice(named: "TimeFlip v2.0")
        device.discoverableDevices = [target]

        async let outcome = device.connectToDiscoveredDevice(id: target.id, password: TimeFlipConstants.defaultPassword)
        try? await Task.sleep(for: .milliseconds(10))
        device.cancelConnectionAttempt()

        // Cancel lands between steps, as it does on hardware -- not by tearing down mid-operation.
        let result = await outcome
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(device.isPaired, "a cancelled attempt must not leave the device paired")
    }
}

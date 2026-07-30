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

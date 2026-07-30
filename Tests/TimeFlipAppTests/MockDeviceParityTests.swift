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

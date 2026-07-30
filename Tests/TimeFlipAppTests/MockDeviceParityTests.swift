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

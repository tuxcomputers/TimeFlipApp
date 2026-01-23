import CoreBluetooth
@testable import TimeFlipApp
import XCTest

// swiftlint:disable discouraged_optional_collection
@MainActor
final class BLEManagerTests: XCTestCase {
    func testStartsScanningWhenPoweredOn() {
        let mockCentral = MockCentralManager()
        let manager = BLEManager(central: mockCentral)

        manager.handleStateChange(.poweredOn)

        XCTAssertTrue(mockCentral.scanCalled)
    }

    func testDoesNotScanWhenPoweredOff() {
        let mockCentral = MockCentralManager()
        let manager = BLEManager(central: mockCentral)

        manager.handleStateChange(.poweredOff)

        XCTAssertFalse(mockCentral.scanCalled)
    }
}

private final class MockCentralManager: CentralManaging {
    var delegate: CBCentralManagerDelegate?
    var state: CBManagerState = .unknown

    private(set) var scanCalled = false
    private(set) var stopCalled = false

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        scanCalled = true
    }

    func stopScan() {
        stopCalled = true
    }

    func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {}

    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
}
// swiftlint:enable discouraged_optional_collection

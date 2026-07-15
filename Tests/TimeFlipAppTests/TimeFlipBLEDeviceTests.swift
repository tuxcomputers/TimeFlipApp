@preconcurrency import CoreBluetooth
@testable import TimeFlipApp
import XCTest

// swiftlint:disable discouraged_optional_collection

/// Records calls without ever invoking CBCentralManagerDelegate callbacks itself — tests drive
/// TimeFlipBLEDevice's response to connection/discovery outcomes by calling its internal
/// `handleMain*`/`scheduleTimeout` seams directly, since CoreBluetooth's own delegate callbacks
/// require a concrete `CBPeripheral`/`CBCentralManager` that can't be constructed in a test.
final class FakeCentralManager: CentralManaging, @unchecked Sendable {
    var delegate: CBCentralManagerDelegate?
    var state: CBManagerState
    private(set) var scanCalls = 0
    private(set) var stopScanCalls = 0
    private(set) var connectCalls = 0
    private(set) var cancelCalls = 0

    init(state: CBManagerState = .poweredOn) {
        self.state = state
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        scanCalls += 1
    }

    func stopScan() {
        stopScanCalls += 1
    }

    func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        connectCalls += 1
    }

    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        cancelCalls += 1
    }
}

/// A plain `PeripheralManaging` double — unlike `CBPeripheral`, our own protocol has no
/// CoreBluetooth-imposed initializer restriction, so this can be a normal fake. It never calls
/// back into its delegate, simulating a device that stops responding mid-command.
final class FakePeripheralManaging: PeripheralManaging, @unchecked Sendable {
    var delegate: CBPeripheralDelegate?
    var services: [CBService]?
    var state: CBPeripheralState = .connected
    var identifier = UUID()
    var name: String? = "Fake TimeFlip"
    private(set) var writeValueCalls: [(data: Data, uuid: CBUUID)] = []
    private(set) var readValueCalls: [CBUUID] = []
    private(set) var setNotifyValueCalls: [(enabled: Bool, uuid: CBUUID)] = []

    func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}

    func readValue(for characteristic: CBCharacteristic) {
        readValueCalls.append(characteristic.uuid)
    }

    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writeValueCalls.append((data, characteristic.uuid))
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        setNotifyValueCalls.append((enabled, characteristic.uuid))
    }
}

@MainActor
final class TimeFlipBLEDeviceTests: XCTestCase {
    /// `CBCharacteristic` itself can't be constructed either, but `CBMutableCharacteristic`
    /// (part of the peripheral-manager/GATT-server API) has a public initializer and upcasts
    /// cleanly — a legitimate, safe stand-in, unlike hand-rolling a `CBPeripheral` subclass.
    private func fakeCharacteristic(_ uuid: CBUUID) -> CBCharacteristic {
        CBMutableCharacteristic(type: uuid, properties: .notify, value: nil, permissions: .readable)
    }

    // MARK: - Item 1: pending continuations must not hang forever past a disconnect

    func testDisconnectDuringCommandFailsThePendingCommandInsteadOfHanging() async {
        let device = TimeFlipBLEDevice(central: FakeCentralManager(), deviceOperationTimeoutSeconds: 30)
        let fakePeripheral = FakePeripheralManaging()
        device.test_configureConnectedState(
            peripheral: fakePeripheral,
            characteristics: [
                TimeFlipUUIDs.password: fakeCharacteristic(TimeFlipUUIDs.password),
                TimeFlipUUIDs.commandResult: fakeCharacteristic(TimeFlipUUIDs.commandResult)
            ]
        )

        // login() writes the password then awaits a commandResult read; the fake peripheral
        // never calls back, so without the disconnect fix this would hang for the full 30s
        // timeout (or forever, pre-fix) instead of resolving quickly.
        async let loginResult = device.login(password: "123456")
        try? await Task.sleep(nanoseconds: 50_000_000)

        device.handleMainDisconnect(error: nil)

        let result = await loginResult
        XCTAssertFalse(result, "login should fail promptly once its pending continuations are torn down")
    }

    // MARK: - Item 8: a stale timeout must not fire after being superseded

    func testStaleTimeoutIsCancelledAndDoesNotFireAfterBeingSuperseded() async {
        let device = TimeFlipBLEDevice(central: FakeCentralManager(), deviceOperationTimeoutSeconds: 1)

        var firstFired = false
        var secondFired = false
        device.scheduleTimeout("connection") { _ in firstFired = true }
        // A second attempt reusing the same slot (e.g. the broad-scan retry) must cancel the
        // first attempt's watchdog — pre-fix, both bare Tasks would fire independently and the
        // stale one could kill the second attempt's continuation.
        device.scheduleTimeout("connection") { _ in secondFired = true }

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertFalse(firstFired, "the superseded watchdog must have been cancelled, not fired")
        XCTAssertTrue(secondFired, "the current watchdog should still fire on its own timeout")
    }

    func testResumingBeforeTimeoutCancelsTheWatchdog() async {
        let device = TimeFlipBLEDevice(central: FakeCentralManager(), deviceOperationTimeoutSeconds: 1)

        var fired = false
        device.scheduleTimeout("connection") { _ in fired = true }
        device.cancelTimeout("connection")

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertFalse(fired, "a cancelled watchdog must never fire")
    }
}
// swiftlint:enable discouraged_optional_collection

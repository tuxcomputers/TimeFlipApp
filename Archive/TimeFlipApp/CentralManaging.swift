import CoreBluetooth

// The CB API uses optionals for service/option arguments; keep signatures aligned with SDK.
// swiftlint:disable discouraged_optional_collection
protocol CentralManaging: AnyObject {
    var delegate: CBCentralManagerDelegate? { get set }
    var state: CBManagerState { get }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)
    func stopScan()
    func connect(_ peripheral: CBPeripheral, options: [String: Any]?)
    func cancelPeripheralConnection(_ peripheral: CBPeripheral)
}
// swiftlint:enable discouraged_optional_collection

extension CBCentralManager: CentralManaging {}

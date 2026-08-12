import CoreBluetooth

// CBPeripheral API uses optionals for services/characteristics; mirror SDK signatures.
// swiftlint:disable discouraged_optional_collection
protocol PeripheralManaging: AnyObject {
    var delegate: CBPeripheralDelegate? { get set }
    var services: [CBService]? { get }
    var state: CBPeripheralState { get }
    var identifier: UUID { get }
    var name: String? { get }

    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService)
    func readValue(for characteristic: CBCharacteristic)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
}
// swiftlint:enable discouraged_optional_collection

extension CBPeripheral: PeripheralManaging {}

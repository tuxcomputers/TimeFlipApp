import CoreBluetooth
import FacetCore

/// The macOS slot in the radio square: a `CBPeripheral` and its delegate, behind `CubeGatt`.
///
/// **It decides nothing.** Every call is a translation and a trace: a UUID string in, a `CBCharacteristic` out
/// of the table below, the call made, and the answer handed back as a UUID string. The sequence, the read-back
/// discipline, the deadlines and the parsing are `DeviceLogin`'s and are not CoreBluetooth's business.
///
/// **The table is why this type exists at all.** `CBCharacteristic` is a live object CoreBluetooth hands out
/// during discovery and it cannot be named from anywhere else, so something has to remember which object is
/// which UUID. Doing it here means nothing above ever holds one.
///
/// **`peripheral.delegate` is one delegate and this is it**, which is the same constraint the login had before:
/// a second reader would have to take it away mid-connection.
///
/// **All the wire tracing lives here too**, `BLETrace` being about bytes on a radio. That is a move rather than
/// a loss: the trace used to be spread between the login's five outbound calls and its five delegate methods,
/// and both halves are now in one file, which is what makes a one-sided conversation impossible to write.
@MainActor
final class CoreBluetoothGatt: NSObject, CubeGatt {
    weak var events: CubeGattEvents?

    private let peripheral: CBPeripheral
    private let debugLog: DebugLog?

    /// Every characteristic discovered so far, by canonical UUID.
    ///
    /// **Canonical, because the vendor writes the standard ones in 16-bit shorthand and CoreBluetooth answers
    /// with whichever form it was given.** `2A19` and `00002a19-0000-1000-8000-00805f9b34fb` are one
    /// characteristic, and a table keyed on the raw string would miss it under the other spelling.
    private var characteristics: [String: CBCharacteristic] = [:]

    init(peripheral: CBPeripheral, debugLog: DebugLog?) {
        self.peripheral = peripheral
        self.debugLog = debugLog
        super.init()
        peripheral.delegate = self
    }

    // MARK: - what a caller asks for

    func discoverServices(_ uuids: [String]) {
        let asked = uuids.map { CBUUID(string: $0) }
        debugLog?.discovering(services: asked)
        peripheral.discoverServices(asked)
    }

    func discoverCharacteristics(_ uuids: [String]?, ofService service: String) {
        guard let found = peripheral.services?.first(where: { TimeFlipUUIDs.match($0.uuid.uuidString, service) })
        else {
            // **Answered rather than dropped.** A caller waiting on a discovery that was never made waits for
            // ever, and this is reachable: a service asked about before the services came back is not there yet.
            debugLog?.record(.login, "No service \(service) to discover characteristics of")
            events?.characteristicsDiscovered([], ofService: service, failed: "the service was not found")
            return
        }
        let asked = uuids?.map { CBUUID(string: $0) }
        debugLog?.discovering(characteristics: asked, of: found.uuid)
        peripheral.discoverCharacteristics(asked, for: found)
    }

    func read(_ characteristic: String) {
        guard let found = characteristics[TimeFlipUUIDs.canonical(characteristic)] else {
            events?.valueArrived(nil, from: characteristic, failed: "the characteristic was not found")
            return
        }
        debugLog?.requested(found.uuid)
        peripheral.readValue(for: found)
    }

    func subscribe(to characteristic: String) {
        guard let found = characteristics[TimeFlipUUIDs.canonical(characteristic)] else {
            events?.valueArrived(nil, from: characteristic, failed: "the characteristic was not found")
            return
        }
        debugLog?.subscribing(true, to: found.uuid)
        peripheral.setNotifyValue(true, for: found)
    }

    func write(_ payload: Data, to characteristic: String, expectingAcknowledgement: Bool) {
        guard let found = characteristics[TimeFlipUUIDs.canonical(characteristic)] else {
            events?.writeAcknowledged(to: characteristic, failed: "the characteristic was not found")
            return
        }
        let type: CBCharacteristicWriteType = expectingAcknowledgement ? .withResponse : .withoutResponse
        debugLog?.transmitted(payload, to: found.uuid, type: type)
        peripheral.writeValue(payload, for: found, type: type)
        // **`.withoutResponse` is acknowledged here, because nothing else will.** CoreBluetooth calls
        // `didWriteValueFor` only for `.withResponse`, so a caller waiting on the port's own acknowledgement
        // would wait for ever on the other kind. Saying it immediately is honest: for an unacknowledged write
        // the bytes leaving is the whole of what can ever be known.
        if !expectingAcknowledgement {
            events?.writeAcknowledged(to: characteristic, failed: nil)
        }
    }
}

// `@preconcurrency`, for the reason given on `BluetoothRadio`'s conformance: the manager is created with
// `queue: .main`, so these arrive on the main thread, and a `CBPeripheral` has no value form to carry across.
extension CoreBluetoothGatt: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let found = peripheral.services?.map(\.uuid) ?? []
        debugLog?.discovered(services: found, error: error)
        // **Everything found so far, not just this answer.** `peripheral.services` accumulates, and nothing in
        // the callback says which request it belongs to, so the caller is given the accumulated set and decides.
        events?.servicesDiscovered(found.map { TimeFlipUUIDs.canonical($0.uuidString) }, failed: error?.localizedDescription)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let found = service.characteristics ?? []
        debugLog?.discovered(characteristics: found.map(\.uuid), of: service.uuid, error: error)
        for characteristic in found {
            characteristics[TimeFlipUUIDs.canonical(characteristic.uuid.uuidString)] = characteristic
        }
        events?.characteristicsDiscovered(
            found.map {
                DiscoveredCharacteristic(uuid: $0.uuid.uuidString, canNotify: $0.properties.contains(.notify))
            },
            ofService: TimeFlipUUIDs.canonical(service.uuid.uuidString),
            failed: error?.localizedDescription
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        debugLog?.acknowledged(characteristic.uuid, error: error)
        events?.writeAcknowledged(
            to: TimeFlipUUIDs.canonical(characteristic.uuid.uuidString), failed: error?.localizedDescription
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        debugLog?.received(characteristic.value, from: characteristic.uuid, error: error)
        events?.valueArrived(
            characteristic.value,
            from: TimeFlipUUIDs.canonical(characteristic.uuid.uuidString),
            failed: error?.localizedDescription
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        debugLog?.notifying(characteristic.uuid, isNotifying: characteristic.isNotifying, error: error)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        guard let name = peripheral.name, !name.isEmpty else { return }
        events?.nameArrived(name)
    }
}

import CoreBluetooth
import FacetCore
import Foundation

/// CoreBluetooth's spelling of the trace rows, and nothing else.
///
/// **Every wording moved into `FacetCore.BLETrace` on 2026-09-11**, when BlueZ became a second radio that has to
/// write the same rows. What is left here is the translation `CBUUID` needs: a `CBCharacteristic` is a live object
/// this platform hands out and its `uuidString` is what the core's table is keyed on, so each of these turns one
/// into the other and forwards.
///
/// **Why the wordings could not stay here.** They are read back out of `debug_log` by `Tests/Scripted` with SQL
/// `LIKE` and `GLOB` patterns, which makes them interface. Two copies of an interface diverge one row at a time and
/// nothing fails when they do -- and this file has already paid for exactly that once, holding a second UUID-name
/// table that spelled `commandResult` as `command result` (see `TimeFlipUUIDs.named`).
///
/// **The errors are turned into strings here too.** `localizedDescription` is Foundation's on both platforms, but a
/// `CBError` is not something the core should have to name, and BlueZ hands its failures over as strings already --
/// so the core's rows take `failed: String?` and each side says what a failure is in its own terms.
extension DebugLog {
    /// A write on its way out.
    func transmitted(_ data: Data, to uuid: CBUUID, type: CBCharacteristicWriteType) {
        transmitted(data, to: uuid.uuidString, acknowledged: type == .withResponse)
    }

    /// A value arriving: the answer to a read, or a notification the cube sent unasked.
    func received(_ data: Data?, from uuid: CBUUID, error: Error?) {
        received(data, from: uuid.uuidString, failed: error?.localizedDescription)
    }

    /// A write the cube acknowledged, or refused.
    func acknowledged(_ uuid: CBUUID, error: Error?) {
        acknowledged(uuid.uuidString, failed: error?.localizedDescription)
    }

    /// A read on its way out.
    func requested(_ uuid: CBUUID) {
        requested(uuid.uuidString)
    }

    /// A subscription being turned on or off.
    func subscribing(_ enabled: Bool, to uuid: CBUUID) {
        subscribing(enabled, to: uuid.uuidString)
    }

    /// What the cube made of it.
    func notifying(_ uuid: CBUUID, isNotifying: Bool, error: Error?) {
        notifying(uuid.uuidString, isNotifying: isNotifying, failed: error?.localizedDescription)
    }

    /// A discovery on its way out.
    func discovering(services uuids: [CBUUID]) {
        discovering(services: uuids.map(\.uuidString))
    }

    func discovering(characteristics uuids: [CBUUID]?, of service: CBUUID) {
        discovering(characteristics: uuids?.map(\.uuidString), of: service.uuidString)
    }

    /// What came back.
    func discovered(services uuids: [CBUUID], error: Error?) {
        discovered(services: uuids.map(\.uuidString), failed: error?.localizedDescription)
    }

    func discovered(characteristics uuids: [CBUUID], of service: CBUUID, error: Error?) {
        discovered(
            characteristics: uuids.map(\.uuidString), of: service.uuidString, failed: error?.localizedDescription
        )
    }
}

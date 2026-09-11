#if canImport(CDBus)
import Foundation
@testable import FacetCore
@testable import FacetLinux

/// A `BlueZLink` that answers whatever a test decides, and hands out `InMemoryGatt`s.
///
/// **The second adapter under `BlueZCubeRadio`.** The real one needs a daemon, an adapter and a cube; what sits
/// above it is the reach -- which devices to try, in what order, with which PIN, and what a refusal means -- and
/// that is the part with the archive's hardest-won rule in it.
///
/// **The GATT tables it hands out are `InMemoryGatt`s**, which is what makes a whole login drivable from here: a
/// test says which devices answered the scan and then answers the login's own questions, so the reach can be taken
/// all the way to `.loggedIn` with nothing real anywhere in it.
@MainActor
final class FakeBlueZLink: BlueZLink {
    /// Whether the adapter powers on, and the failure `powerOn` throws instead.
    var powersOn = true
    var powerFailure: (any Error)?
    var discoveryFailure: (any Error)?
    var connectFailure: (any Error)?

    /// What the scan sees, and what BlueZ says about each device.
    var devices: [ScannedDevice] = []
    var records: [UUID: BlueZObjectTree.Device] = [:]

    private(set) var poweredOn = 0
    private(set) var discoveriesStarted = 0
    private(set) var discoveriesStopped = 0
    private(set) var connects: [DeviceHandle] = []
    private(set) var disconnects: [DeviceHandle] = []

    /// One `InMemoryGatt` per device the reach got as far as, newest last.
    private(set) var gatts: [InMemoryGatt] = []

    func powerOn() throws -> Bool {
        poweredOn += 1
        if let powerFailure { throw powerFailure }
        return powersOn
    }

    func startDiscovery() throws {
        discoveriesStarted += 1
        if let discoveryFailure { throw discoveryFailure }
    }

    func stopDiscovery() throws {
        discoveriesStopped += 1
    }

    func scannedDevices() throws -> [ScannedDevice] {
        devices
    }

    func device(_ id: DeviceHandle) throws -> BlueZObjectTree.Device? {
        records[id]
    }

    func connect(_ id: DeviceHandle) throws {
        connects.append(id)
        if let connectFailure { throw connectFailure }
        // A real `Connect` is answered before the services resolve, so this leaves the record alone: a test that
        // wants the login to begin says so with `resolve(_:)`.
        if var record = records[id] {
            record = BlueZObjectTree.Device(
                path: record.path,
                address: record.address,
                name: record.name,
                isConnected: true,
                areServicesResolved: record.areServicesResolved,
                isPaired: record.isPaired,
                signalStrength: record.signalStrength,
                serviceUUIDs: record.serviceUUIDs
            )
            records[id] = record
        }
    }

    func disconnect(_ id: DeviceHandle) throws {
        disconnects.append(id)
        guard let record = records[id] else { return }
        records[id] = BlueZObjectTree.Device(
            path: record.path,
            address: record.address,
            name: record.name,
            isConnected: false,
            areServicesResolved: false,
            isPaired: record.isPaired,
            signalStrength: record.signalStrength,
            serviceUUIDs: record.serviceUUIDs
        )
    }

    func gatt(for device: BlueZObjectTree.Device) -> CubeGatt {
        let gatt = InMemoryGatt()
        gatts.append(gatt)
        return gatt
    }

    // MARK: - what a test makes BlueZ say

    /// A device BlueZ knows about, listed by the scan and answering to this address.
    func add(_ id: DeviceHandle, named name: String, address: String = "E8:DB:D8:CF:F9:0F") {
        devices.append(
            ScannedDevice(
                id: id, peripheralName: name, advertisedName: name, advertisesTimeFlipService: false
            )
        )
        records[id] = BlueZObjectTree.Device(
            path: "/org/bluez/hci0/dev_\(address.replacingOccurrences(of: ":", with: "_"))",
            address: address,
            name: name,
            isConnected: false,
            areServicesResolved: false,
            isPaired: false,
            signalStrength: -60,
            serviceUUIDs: []
        )
    }

    /// BlueZ finishing reading the GATT tree, which is the moment a login may begin.
    func resolve(_ id: DeviceHandle) {
        guard let record = records[id] else { return }
        records[id] = BlueZObjectTree.Device(
            path: record.path,
            address: record.address,
            name: record.name,
            isConnected: true,
            areServicesResolved: true,
            isPaired: record.isPaired,
            signalStrength: record.signalStrength,
            serviceUUIDs: record.serviceUUIDs
        )
    }

    /// The cube going away, which BlueZ reports by the device no longer being connected.
    func drop(_ id: DeviceHandle) {
        try? disconnect(id)
        disconnects.removeLast()
    }
}
#endif

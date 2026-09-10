import FacetCore
import Foundation

/// What BlueZ's object tree says, read as records rather than as nested dictionaries.
///
/// `GetManagedObjects` answers one flat map of object path to interface to property, and everything the
/// radio needs to know is a query over it: which adapter, which device, which characteristic.
///
/// **Found by properties rather than by path shape.** BlueZ names a characteristic
/// `/org/bluez/hci0/dev_XX/serviceNNNN/charNNNN`, and it would be easy to take that apart -- but the
/// documented links are the `Device` property on a service and the `Service` property on a characteristic,
/// and the path shape is an implementation detail nothing promises. `scripts/linux-ble-probe.py` walks it
/// the same way for the same reason.
///
/// **Pure**, so every one of these answers is testable without a radio. The mistakes this layer can make
/// are all silent ones -- a UUID compared in the wrong spelling finds no characteristic and reports
/// nothing missing -- which is exactly what wants a test rather than a run.
package struct BlueZObjectTree: Equatable, Sendable {
    package static let adapterInterface = "org.bluez.Adapter1"
    package static let deviceInterface = "org.bluez.Device1"
    package static let serviceInterface = "org.bluez.GattService1"
    package static let characteristicInterface = "org.bluez.GattCharacteristic1"

    /// Object path to interface name to properties, as `GetManagedObjects` gives it.
    private let objects: [String: DBusValue]

    package init(_ objects: [String: DBusValue]) {
        self.objects = objects
    }

    /// The reply to `GetManagedObjects`, whose one argument is the tree.
    package init(reply: [DBusValue]) {
        self.init(reply.first?.members ?? [:])
    }

    // MARK: - the adapter

    /// Every adapter, in path order so the answer does not depend on dictionary ordering.
    package var adapters: [Adapter] {
        objects.keys.sorted().compactMap { path in
            guard let properties = objects[path]?[Self.adapterInterface]?.members else { return nil }
            return Adapter(
                path: path,
                address: properties["Address"]?.text ?? "",
                isPowered: properties["Powered"]?.flag ?? false,
                isDiscovering: properties["Discovering"]?.flag ?? false
            )
        }
    }

    package struct Adapter: Equatable, Sendable {
        package let path: String
        package let address: String
        package let isPowered: Bool
        package let isDiscovering: Bool
    }

    // MARK: - devices

    /// Every device the adapter currently knows, in path order.
    ///
    /// **BlueZ forgets an unpaired device that is not connected**, some time after discovery stops, so
    /// this is a view of the cache rather than of what exists. Measured 2026-09-07: after a boot the cube
    /// was absent until a scan rediscovered it.
    package var devices: [Device] {
        objects.keys.sorted().compactMap { device(at: $0) }
    }

    package func device(at path: String) -> Device? {
        guard let properties = objects[path]?[Self.deviceInterface]?.members else { return nil }
        return Device(
            path: path,
            address: properties["Address"]?.text ?? "",
            name: properties["Alias"]?.text ?? properties["Name"]?.text ?? "",
            isConnected: properties["Connected"]?.flag ?? false,
            areServicesResolved: properties["ServicesResolved"]?.flag ?? false,
            isPaired: properties["Paired"]?.flag ?? false,
            signalStrength: properties["RSSI"]?.number.map(Int.init),
            serviceUUIDs: properties["UUIDs"]?.strings ?? []
        )
    }

    /// The device with this address, however either side spells it.
    ///
    /// **Case-insensitive on purpose.** BlueZ answers `E8:DB:D8:CF:F9:0F` in upper case and puts the same
    /// bytes in a path as `dev_E8_DB_D8_CF_F9_0F`, but a stored address arriving from anywhere else has no
    /// such guarantee, and a pairing that failed to match on case would look exactly like a cube that had
    /// gone away.
    package func device(withAddress address: String) -> Device? {
        let wanted = address.uppercased()
        return devices.first { $0.address.uppercased() == wanted }
    }

    package struct Device: Equatable, Sendable {
        package let path: String
        package let address: String
        /// `Alias` if there is one, `Name` otherwise: BlueZ's alias is the name unless somebody renamed it.
        package let name: String
        package let isConnected: Bool
        /// **Not the same as connected**, and the difference is several round trips: a device is connected
        /// before its GATT tree has been read, and nothing may be looked up by UUID until this is true.
        package let areServicesResolved: Bool
        package let isPaired: Bool
        /// Absent rather than zero when the device has not been seen in this discovery.
        package let signalStrength: Int?
        /// What the advertisement claimed. **Empty for this cube**, which advertises its name and no
        /// service UUID at all -- finding 12, and why a scan must not filter on one.
        package let serviceUUIDs: [String]
    }

    // MARK: - the GATT tree

    /// The services belonging to a device: path and UUID.
    package func services(ofDevice devicePath: String) -> [(path: String, uuid: String)] {
        objects.keys.sorted().compactMap { path in
            guard let properties = objects[path]?[Self.serviceInterface]?.members,
                  properties["Device"]?.text == devicePath,
                  let uuid = properties["UUID"]?.text
            else { return nil }
            return (path, uuid)
        }
    }

    /// Every characteristic belonging to a device, through the services that belong to it.
    package func characteristics(ofDevice devicePath: String) -> [Characteristic] {
        let servicePaths = Set(services(ofDevice: devicePath).map(\.path))
        guard !servicePaths.isEmpty else { return [] }
        return objects.keys.sorted().compactMap { path in
            guard let properties = objects[path]?[Self.characteristicInterface]?.members,
                  let servicePath = properties["Service"]?.text,
                  servicePaths.contains(servicePath),
                  let uuid = properties["UUID"]?.text
            else { return nil }
            return Characteristic(
                path: path,
                uuid: uuid,
                servicePath: servicePath,
                flags: properties["Flags"]?.strings ?? []
            )
        }
    }

    /// The characteristic with this UUID on this device, whichever spelling either side uses.
    ///
    /// **This is what `TimeFlipUUIDs.canonical` exists for.** The app names the standard characteristics
    /// in 16-bit shorthand and BlueZ never does, so a plain string comparison finds nothing -- and finds
    /// nothing quietly, which reads as a cube that does not have the characteristic.
    package func characteristic(ofDevice devicePath: String, uuid: String) -> Characteristic? {
        characteristics(ofDevice: devicePath).first { TimeFlipUUIDs.match($0.uuid, uuid) }
    }

    package struct Characteristic: Equatable, Sendable {
        package let path: String
        package let uuid: String
        package let servicePath: String
        /// BlueZ's own words: `read`, `write`, `write-without-response`, `notify`, `indicate`. The radio
        /// subscribes to everything that says `notify`, which is how a cube offering something this app
        /// has never named is still listened to.
        package let flags: [String]

        package var canNotify: Bool { flags.contains("notify") || flags.contains("indicate") }
        package var canWrite: Bool { flags.contains("write") || flags.contains("write-without-response") }
        package var canRead: Bool { flags.contains("read") }
    }
}

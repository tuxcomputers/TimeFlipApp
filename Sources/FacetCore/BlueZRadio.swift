#if canImport(CDBus)
import Foundation

/// The radio, over BlueZ. **Discovery and the link**; the GATT half comes with the characteristics.
///
/// **Every decision in here is somebody else's.** Which advertisement is a cube is `DeviceScanRules`,
/// which is the same rule CoreBluetooth's side asks, so a renamed cube is found or lost identically on
/// both platforms rather than by two rules that have to be kept in step. What this type does is turn
/// BlueZ objects into the values those rules take, and make the calls.
package final class BlueZRadio {
    package enum Failure: Error, Equatable {
        case noAdapter
        case notFound(String)
        case refused(String)
    }

    private let bus: SystemBus
    private let properties = "org.freedesktop.DBus.Properties"

    package init(bus: SystemBus) {
        self.bus = bus
    }

    package convenience init() throws {
        self.init(bus: try SystemBus())
    }

    // MARK: - the object tree

    /// Everything BlueZ currently knows, read fresh.
    ///
    /// **Read at the point of use, every time**, which is `CLAUDE.md`'s first rule pointed at the radio
    /// rather than at the database: BlueZ's tree changes underneath this process as devices appear, resolve
    /// and are forgotten, and a held copy would be a second answer to a question the bus already answers.
    package func tree() throws -> BlueZObjectTree {
        BlueZObjectTree(reply: try bus.call(
            destination: "org.bluez",
            path: "/",
            interface: "org.freedesktop.DBus.ObjectManager",
            method: "GetManagedObjects"
        ))
    }

    /// The first adapter BlueZ has, or a failure saying there is none.
    package func adapter() throws -> BlueZObjectTree.Adapter {
        guard let adapter = try tree().adapters.first else { throw Failure.noAdapter }
        return adapter
    }

    // MARK: - powering and discovery

    /// Turns the adapter on if it is off, and answers whether it is on now.
    ///
    /// **Read back rather than assumed**, which is the same rule the cube's own commands are held to: a
    /// `Set` that returned without error and did not take is exactly the disagreement worth ruling out.
    @discardableResult
    package func powerOn() throws -> Bool {
        let adapter = try self.adapter()
        guard !adapter.isPowered else { return true }
        try bus.call(
            destination: "org.bluez",
            path: adapter.path,
            interface: properties,
            method: "Set",
            arguments: [
                .string(BlueZObjectTree.adapterInterface),
                .string("Powered"),
                .variant(.boolean(true)),
            ]
        )
        return try self.adapter().isPowered
    }

    /// Starts discovery. **No UUID filter, ever.**
    ///
    /// A 128-bit UUID costs 16 of the 31 bytes an advertisement has and this cube spends them on its name
    /// instead, so a scan filtered on the service UUID sees nothing at all -- finding 12 in
    /// `docs/timeflip2-firmware-observations.md`, and the same reason `BluetoothRadio` passes
    /// `withServices: nil` on the other platform. BlueZ takes the filter as a `SetDiscoveryFilter` call,
    /// which is simply never made.
    package func startDiscovery() throws {
        let adapter = try self.adapter()
        guard !adapter.isDiscovering else { return }
        do {
            try bus.call(
                destination: "org.bluez", path: adapter.path,
                interface: BlueZObjectTree.adapterInterface, method: "StartDiscovery"
            )
        } catch let failure as SystemBus.Failure {
            // Already discovering is the state asked for, not a problem.
            guard case let .callFailed(name, message) = failure, name.hasSuffix(".InProgress") else {
                throw Failure.refused(Self.describe(failure))
            }
            _ = message
        }
    }

    package func stopDiscovery() throws {
        let adapter = try self.adapter()
        guard adapter.isDiscovering else { return }
        do {
            try bus.call(
                destination: "org.bluez", path: adapter.path,
                interface: BlueZObjectTree.adapterInterface, method: "StopDiscovery"
            )
        } catch let failure as SystemBus.Failure {
            guard case let .callFailed(name, _) = failure, name.hasSuffix(".Failed") else {
                throw Failure.refused(Self.describe(failure))
            }
        }
    }

    // MARK: - what a scan found

    /// Everything BlueZ knows, as the values `DeviceScanRules` decides about.
    ///
    /// **The two names are mapped rather than equated, and this is the part still unverified.** On Darwin
    /// they come from different places: the advertisement's local name never changes, while
    /// `CBPeripheral.name` is the GAP name a rename moves (finding 1, seven renames). BlueZ has `Name`,
    /// which is the remote device's own name, and `Alias`, which is a *local* override defaulting to it --
    /// so `Name` is the closer analogue of the advertised name and `Alias` of what to show. **Whether a
    /// `0x15` rename moves BlueZ's `Name` the way it moves CoreBluetooth's has not been measured**, and it
    /// is the first thing to check when a cube is renamed on this platform.
    package func scannedDevices() throws -> [ScannedDevice] {
        try tree().devices.compactMap { device in
            guard let id = BlueZAddress.identifier(forAddress: device.address) else { return nil }
            let remoteName = device.name.isEmpty ? nil : device.name
            return ScannedDevice(
                id: id,
                peripheralName: remoteName,
                advertisedName: remoteName,
                advertisesTimeFlipService: device.serviceUUIDs.contains {
                    TimeFlipUUIDs.match($0, TimeFlipUUIDs.serviceString)
                }
            )
        }
    }

    // MARK: - the link

    /// Connects, and answers once BlueZ says the GATT tree has been read.
    ///
    /// **Connected and resolved are different facts** and the app needs the second: nothing can be looked
    /// up by UUID until the services are resolved, which is several round trips after the connection is
    /// reported. The same distinction as `isLinkSettled` on the other platform.
    package func connect(address: String, resolveTimeout: TimeInterval = 20) throws -> BlueZObjectTree.Device {
        guard let device = try tree().device(withAddress: address) else {
            throw Failure.notFound(address)
        }
        if !device.isConnected {
            try attemptConnect(to: device.path)
        }

        let deadline = Date().addingTimeInterval(resolveTimeout)
        while Date() < deadline {
            if let current = try tree().device(withAddress: address), current.areServicesResolved {
                return current
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw Failure.refused("connected but the services were not resolved within \(Int(resolveTimeout))s")
    }

    /// **`le-connection-abort-by-local` is a transient, and retrying is the answer.** Measured
    /// 2026-09-07: a `Connect` made a few seconds after disconnecting the same cube is refused with it,
    /// because BlueZ is still tidying up the previous link -- and the next attempt succeeds. Treating it
    /// as a refusal would make a reconnect fail for the one reason a reconnect is most likely to happen.
    ///
    /// **Bounded, and everything else is thrown.** A retry loop that swallowed every error would turn a
    /// cube that is out of range into a thirty-second pause with no explanation.
    private func attemptConnect(to path: String, attempts: Int = 4) throws {
        for attempt in 1 ... attempts {
            do {
                try bus.call(
                    destination: "org.bluez", path: path,
                    interface: BlueZObjectTree.deviceInterface, method: "Connect",
                    timeoutMilliseconds: 30_000
                )
                return
            } catch let failure as SystemBus.Failure {
                guard case let .callFailed(_, message) = failure,
                      message.contains("le-connection-abort-by-local"),
                      attempt < attempts
                else {
                    throw Failure.refused(Self.describe(failure))
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    package func disconnect(address: String) throws {
        guard let device = try tree().device(withAddress: address) else { return }
        guard device.isConnected else { return }
        do {
            try bus.call(
                destination: "org.bluez", path: device.path,
                interface: BlueZObjectTree.deviceInterface, method: "Disconnect"
            )
        } catch let failure as SystemBus.Failure {
            throw Failure.refused(Self.describe(failure))
        }
    }

    /// Drops BlueZ's cached object for a device, so the next scan rediscovers it from nothing.
    ///
    /// **What `--clear-cache` in `scripts/linux-ble-probe.py` is for**: a stale `Device1` carrying old
    /// properties is the difference between a connect that works and one that fails on a name or a service
    /// list BlueZ has not re-read.
    package func forget(address: String) throws {
        let adapter = try self.adapter()
        guard let device = try tree().device(withAddress: address) else { return }
        _ = try? bus.call(
            destination: "org.bluez", path: adapter.path,
            interface: BlueZObjectTree.adapterInterface, method: "RemoveDevice",
            arguments: [.objectPath(device.path)]
        )
    }

    private static func describe(_ failure: SystemBus.Failure) -> String {
        switch failure {
        case let .callFailed(name, message): return "\(name): \(message)"
        case let .noBus(message), let .unexpectedReply(message), let .matchFailed(message): return message
        }
    }
}
#endif

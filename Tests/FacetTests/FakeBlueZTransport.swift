#if canImport(CDBus)
import Foundation
@testable import FacetCore
@testable import FacetLinux

/// A `BlueZGattTransport` that records what was asked of it and answers whatever a test decides.
///
/// **The second adapter under `BlueZCubeGatt`, and the only thing that makes it testable at all.** The real one is
/// `BlueZBusTransport`, which needs a daemon, an adapter and a cube on the desk; everything above it is
/// translation -- a UUID to an object path, a signal to an event, a blocking call to an answer handed back later --
/// and every mistake that layer can make is a silent one. A characteristic looked for in the wrong spelling is not
/// an error, it is a cube that appears not to have it.
///
/// **It answers a tree rather than answers about one.** The queries are `BlueZObjectTree`'s and are tested in
/// `BlueZObjectTreeTests`; what a test sets here is the tree BlueZ would have, so the two suites do not both own
/// the same shapes.
@MainActor
final class FakeBlueZTransport: BlueZGattTransport {
    /// What `tree()` answers, or the failure it throws instead.
    var objectTree = BlueZObjectTree([:])
    var treeFailure: (any Error)?

    /// What a read of a path answers, and the failure a path throws instead.
    var values: [String: [UInt8]] = [:]
    var readFailures: [String: any Error] = [:]
    var writeFailure: (any Error)?
    var notifyFailure: (any Error)?

    private(set) var reads: [String] = []
    private(set) var writes: [(path: String, bytes: [UInt8], acknowledged: Bool)] = []
    private(set) var notifying: [String] = []
    private(set) var watched: [String] = []

    /// Signals waiting on the bus, oldest first. `nextSignal` takes one per call, which is what libdbus does.
    var signals: [SystemBus.Signal] = []

    func tree() throws -> BlueZObjectTree {
        if let treeFailure { throw treeFailure }
        return objectTree
    }

    func read(path: String) throws -> [UInt8] {
        reads.append(path)
        if let failure = readFailures[path] { throw failure }
        return values[path] ?? []
    }

    func write(path: String, bytes: [UInt8], acknowledged: Bool) throws {
        writes.append((path, bytes, acknowledged))
        if let writeFailure { throw writeFailure }
    }

    func startNotifying(path: String) throws {
        notifying.append(path)
        if let notifyFailure { throw notifyFailure }
    }

    func watchProperties(path: String) throws {
        watched.append(path)
    }

    func nextSignal() -> SystemBus.Signal? {
        signals.isEmpty ? nil : signals.removeFirst()
    }

    // MARK: - what a test makes the bus say

    /// A `PropertiesChanged` carrying a characteristic's new value, as BlueZ sends one.
    func pushValue(_ bytes: [UInt8], from path: String) {
        signals.append(
            SystemBus.Signal(
                path: path,
                interface: "org.freedesktop.DBus.Properties",
                member: "PropertiesChanged",
                arguments: [
                    .string(BlueZObjectTree.characteristicInterface),
                    .dictionary(["Value": .bytes(bytes)]),
                    .array([]),
                ]
            )
        )
    }

    /// A `PropertiesChanged` on the device itself, which is where a name arrives.
    func pushDeviceProperties(_ properties: [String: DBusValue], from path: String) {
        signals.append(
            SystemBus.Signal(
                path: path,
                interface: "org.freedesktop.DBus.Properties",
                member: "PropertiesChanged",
                arguments: [
                    .string(BlueZObjectTree.deviceInterface),
                    .dictionary(properties),
                    .array([]),
                ]
            )
        )
    }

    /// Something else entirely, which a real bus sends whether or not anybody asked: the daemon's own
    /// `NameAcquired` arrives on every new connection.
    func pushNoise() {
        signals.append(
            SystemBus.Signal(
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                member: "NameAcquired",
                arguments: [.string(":1.42")]
            )
        )
    }
}
#endif

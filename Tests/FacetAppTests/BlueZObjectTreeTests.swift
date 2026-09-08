import Foundation
import Testing
@testable import FacetCore

/// `BlueZObjectTree`: reading BlueZ's object tree as records.
///
/// **Hand-built trees, because the shapes that matter cannot all be captured.** The adapter half is
/// checked against the real bus in `SystemBusTests`; a connected cube's services and characteristics need
/// the cube, so those are built here from the shapes BlueZ documents and the app's own UUIDs. What is
/// being tested is the querying, and every mistake it can make is a silent one -- a characteristic looked
/// for in the wrong spelling is not an error, it is a cube that appears not to have it.
@Suite
struct BlueZObjectTreeTests {
    // MARK: - building a tree to ask about

    private func interfaces(_ pairs: [String: [String: DBusValue]]) -> DBusValue {
        .dictionary(pairs.mapValues { .dictionary($0.mapValues { .variant($0) }) })
    }

    private var adapterOnly: BlueZObjectTree {
        BlueZObjectTree([
            "/org/bluez": interfaces(["org.bluez.AgentManager1": [:]]),
            "/org/bluez/hci0": interfaces([
                BlueZObjectTree.adapterInterface: [
                    "Address": .string("88:E9:FE:5F:1B:52"),
                    "Powered": .boolean(true),
                    "Discovering": .boolean(false),
                ],
            ]),
        ])
    }

    /// A cube, connected and resolved, with the vendor service and two of its characteristics plus the
    /// standard battery one -- which is the case the UUID spellings differ in.
    private var connectedCube: BlueZObjectTree {
        let device = "/org/bluez/hci0/dev_E8_DB_D8_CF_F9_0F"
        return BlueZObjectTree([
            "/org/bluez/hci0": interfaces([
                BlueZObjectTree.adapterInterface: [
                    "Address": .string("88:E9:FE:5F:1B:52"), "Powered": .boolean(true),
                    "Discovering": .boolean(false),
                ],
            ]),
            device: interfaces([
                BlueZObjectTree.deviceInterface: [
                    "Address": .string("E8:DB:D8:CF:F9:0F"),
                    "Alias": .string("TimeFlip v2.0"),
                    "Connected": .boolean(true),
                    "ServicesResolved": .boolean(true),
                    "Paired": .boolean(false),
                    "RSSI": .integer(-62),
                    "UUIDs": .array([]),
                ],
            ]),
            "\(device)/service000a": interfaces([
                BlueZObjectTree.serviceInterface: [
                    "Device": .objectPath(device),
                    "UUID": .string("f1196f50-71a4-11e6-bdf4-0800200c9a66"),
                ],
            ]),
            "\(device)/service000a/char000b": interfaces([
                BlueZObjectTree.characteristicInterface: [
                    "Service": .objectPath("\(device)/service000a"),
                    "UUID": .string("f1196f54-71a4-11e6-bdf4-0800200c9a66"),
                    "Flags": .array([.string("write"), .string("read")]),
                ],
            ]),
            "\(device)/service000a/char000d": interfaces([
                BlueZObjectTree.characteristicInterface: [
                    "Service": .objectPath("\(device)/service000a"),
                    "UUID": .string("f1196f52-71a4-11e6-bdf4-0800200c9a66"),
                    "Flags": .array([.string("read"), .string("notify")]),
                ],
            ]),
            "\(device)/service0010": interfaces([
                BlueZObjectTree.serviceInterface: [
                    "Device": .objectPath(device),
                    // As BlueZ spells the Battery Service, which is not how this app spells it.
                    "UUID": .string("0000180f-0000-1000-8000-00805f9b34fb"),
                ],
            ]),
            "\(device)/service0010/char0011": interfaces([
                BlueZObjectTree.characteristicInterface: [
                    "Service": .objectPath("\(device)/service0010"),
                    "UUID": .string("00002a19-0000-1000-8000-00805f9b34fb"),
                    "Flags": .array([.string("read"), .string("notify")]),
                ],
            ]),
        ])
    }

    // MARK: - the adapter

    @Test func theAdapterIsFoundByItsInterfaceRatherThanItsName() {
        let adapters = adapterOnly.adapters
        #expect(adapters.count == 1, "the manager object carries no Adapter1 and must not be counted")
        #expect(adapters.first?.path == "/org/bluez/hci0")
        #expect(adapters.first?.address == "88:E9:FE:5F:1B:52")
        #expect(adapters.first?.isPowered == true)
        #expect(adapters.first?.isDiscovering == false)
    }

    @Test func aTreeWithNoAdapterAnswersNothingRatherThanGuessing() {
        #expect(BlueZObjectTree([:]).adapters.isEmpty)
        #expect(BlueZObjectTree([:]).devices.isEmpty)
    }

    // MARK: - devices

    @Test func aDeviceCarriesWhatTheRadioBranchesOn() throws {
        let device = try #require(connectedCube.device(withAddress: "E8:DB:D8:CF:F9:0F"))
        #expect(device.name == "TimeFlip v2.0")
        #expect(device.isConnected)
        #expect(device.areServicesResolved)
        #expect(!device.isPaired, "no bond: the PIN is the whole of the authentication on this platform")
        #expect(device.signalStrength == -62)
        #expect(device.serviceUUIDs.isEmpty, "this cube advertises no service UUID at all")
    }

    /// **Case-insensitive, because a mismatch would look like a cube that had gone away.** BlueZ answers
    /// upper case; an address arriving from anywhere else has no such guarantee.
    @Test func aDeviceIsFoundHoweverTheAddressIsSpelled() {
        #expect(connectedCube.device(withAddress: "e8:db:d8:cf:f9:0f") != nil)
        #expect(connectedCube.device(withAddress: "E8:DB:D8:CF:F9:0F") != nil)
        #expect(connectedCube.device(withAddress: "E8:DB:D8:CF:F9:00") == nil, "one digit out is a different cube")
    }

    /// Connected and resolved are different facts, several round trips apart, and nothing may be looked up
    /// by UUID until the second is true.
    @Test func connectedIsNotTheSameAsResolved() {
        let midConnect = BlueZObjectTree([
            "/org/bluez/hci0/dev_AA": interfaces([
                BlueZObjectTree.deviceInterface: [
                    "Address": .string("AA:AA:AA:AA:AA:AA"),
                    "Connected": .boolean(true),
                    "ServicesResolved": .boolean(false),
                ],
            ]),
        ])
        let device = midConnect.devices.first
        #expect(device?.isConnected == true)
        #expect(device?.areServicesResolved == false)
        #expect(midConnect.characteristics(ofDevice: "/org/bluez/hci0/dev_AA").isEmpty)
    }

    // MARK: - the GATT tree

    @Test func servicesAndCharacteristicsAreFoundThroughTheirOwnProperties() {
        let device = "/org/bluez/hci0/dev_E8_DB_D8_CF_F9_0F"
        #expect(connectedCube.services(ofDevice: device).count == 2)
        #expect(connectedCube.characteristics(ofDevice: device).count == 3)
    }

    /// **The isolation case.** A characteristic hanging off another device's service must not be returned,
    /// which is what would happen if these were matched on path prefix rather than on the `Service` link.
    @Test func anotherDevicesCharacteristicsAreNotReturned() {
        var objects: [String: DBusValue] = [:]
        for (device, uuid) in [("dev_AA", "f1196f54-71a4-11e6-bdf4-0800200c9a66"),
                               ("dev_BB", "f1196f52-71a4-11e6-bdf4-0800200c9a66")] {
            let path = "/org/bluez/hci0/\(device)"
            objects[path] = interfaces([
                BlueZObjectTree.deviceInterface: ["Address": .string("AA:AA:AA:AA:AA:AA")],
            ])
            objects["\(path)/service0001"] = interfaces([
                BlueZObjectTree.serviceInterface: [
                    "Device": .objectPath(path), "UUID": .string("f1196f50-71a4-11e6-bdf4-0800200c9a66"),
                ],
            ])
            objects["\(path)/service0001/char0002"] = interfaces([
                BlueZObjectTree.characteristicInterface: [
                    "Service": .objectPath("\(path)/service0001"), "UUID": .string(uuid),
                ],
            ])
        }
        let tree = BlueZObjectTree(objects)
        let first = tree.characteristics(ofDevice: "/org/bluez/hci0/dev_AA")
        #expect(first.count == 1)
        #expect(first.first?.uuid == "f1196f54-71a4-11e6-bdf4-0800200c9a66")
    }

    /// **The reason `TimeFlipUUIDs.canonical` exists.** The app names the battery level `2A19`; BlueZ calls
    /// the same characteristic `00002a19-0000-1000-8000-00805f9b34fb`. A plain string comparison finds
    /// nothing and reports nothing missing.
    @Test func aCharacteristicIsFoundByTheAppsOwnSpellingOfItsUUID() throws {
        let device = "/org/bluez/hci0/dev_E8_DB_D8_CF_F9_0F"

        let battery = try #require(
            connectedCube.characteristic(ofDevice: device, uuid: TimeFlipUUIDs.batteryLevelString),
            "16-bit shorthand must match BlueZ's 128-bit form"
        )
        #expect(battery.path == "\(device)/service0010/char0011")

        // And the vendor's, which differ only by case.
        let command = try #require(
            connectedCube.characteristic(ofDevice: device, uuid: TimeFlipUUIDs.commandString)
        )
        #expect(command.path == "\(device)/service000a/char000b")
        #expect(
            connectedCube.characteristic(ofDevice: device, uuid: TimeFlipUUIDs.historyString) == nil,
            "a characteristic this cube does not expose is absent rather than wrongly matched"
        )
    }

    @Test func theFlagsSayWhatMayBeDoneWithIt() throws {
        let device = "/org/bluez/hci0/dev_E8_DB_D8_CF_F9_0F"
        let faces = try #require(connectedCube.characteristic(ofDevice: device, uuid: TimeFlipUUIDs.facesString))
        #expect(faces.canNotify, "the app subscribes to everything that says it can notify")
        #expect(faces.canRead)
        #expect(!faces.canWrite)

        let command = try #require(connectedCube.characteristic(ofDevice: device, uuid: TimeFlipUUIDs.commandString))
        #expect(command.canWrite)
        #expect(!command.canNotify)
    }
}

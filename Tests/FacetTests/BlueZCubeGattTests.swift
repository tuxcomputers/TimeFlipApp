#if canImport(CDBus)
import Foundation
import Testing
@testable import FacetCore
@testable import FacetLinux

/// Covers `BlueZCubeGatt`, the Linux slot behind `CubeGatt`.
///
/// **What is being checked is the translation and nothing else.** Whether BlueZ answers a `ReadValue` is BlueZ's
/// business and needs a cube; what this file pins is the part that goes wrong quietly -- a UUID compared in the
/// wrong spelling, an answer handed back inside the call that asked for it, a signal that is not a value read as
/// one, a failure that is dropped instead of reported.
///
/// **The spelling trap is the reason this exists at all.** The same move on the Mac introduced three bugs that all
/// compiled: `2A29` is not `00002a19-...`, so eleven `==` comparisons quietly answered false and the login would
/// have found its characteristics, presented no PIN and reported nothing. BlueZ answers in the expanded lowercase
/// form natively, so the trap here is the other way round -- the app names the standard characteristics in 16-bit
/// shorthand -- and it is the same trap.
@Suite @MainActor
struct BlueZCubeGattTests {
    private let devicePath = "/org/bluez/hci0/dev_E8_DB_D8_CF_F9_0F"

    private var commandPath: String { "\(devicePath)/service000a/char000b" }
    private var facesPath: String { "\(devicePath)/service000a/char000d" }
    private var batteryPath: String { "\(devicePath)/service0010/char0011" }

    private func interfaces(_ pairs: [String: [String: DBusValue]]) -> DBusValue {
        .dictionary(pairs.mapValues { .dictionary($0.mapValues { .variant($0) }) })
    }

    /// A cube, connected and resolved: the vendor service with `command` and `faces` on it, and the standard
    /// Battery Service, **which BlueZ spells in full and this app spells as `2A19`**.
    private var connectedCube: BlueZObjectTree {
        BlueZObjectTree([
            devicePath: interfaces([
                BlueZObjectTree.deviceInterface: [
                    "Address": .string("E8:DB:D8:CF:F9:0F"),
                    "Alias": .string("TimeFlip v2.0"),
                    "Connected": .boolean(true),
                    "ServicesResolved": .boolean(true),
                ],
            ]),
            "\(devicePath)/service000a": interfaces([
                BlueZObjectTree.serviceInterface: [
                    "Device": .objectPath(devicePath),
                    "UUID": .string("f1196f50-71a4-11e6-bdf4-0800200c9a66"),
                ],
            ]),
            commandPath: interfaces([
                BlueZObjectTree.characteristicInterface: [
                    "Service": .objectPath("\(devicePath)/service000a"),
                    "UUID": .string("f1196f54-71a4-11e6-bdf4-0800200c9a66"),
                    "Flags": .array([.string("write"), .string("read")]),
                ],
            ]),
            facesPath: interfaces([
                BlueZObjectTree.characteristicInterface: [
                    "Service": .objectPath("\(devicePath)/service000a"),
                    "UUID": .string("f1196f52-71a4-11e6-bdf4-0800200c9a66"),
                    "Flags": .array([.string("read"), .string("notify")]),
                ],
            ]),
            "\(devicePath)/service0010": interfaces([
                BlueZObjectTree.serviceInterface: [
                    "Device": .objectPath(devicePath),
                    "UUID": .string("0000180f-0000-1000-8000-00805f9b34fb"),
                ],
            ]),
            batteryPath: interfaces([
                BlueZObjectTree.characteristicInterface: [
                    "Service": .objectPath("\(devicePath)/service0010"),
                    "UUID": .string("00002a19-0000-1000-8000-00805f9b34fb"),
                    "Flags": .array([.string("read"), .string("notify")]),
                ],
            ]),
        ])
    }

    /// Everything the port ever answers, in the order it arrived.
    @MainActor
    private final class Heard: CubeGattEvents {
        var services: [(uuids: [String], failed: String?)] = []
        var characteristics: [(found: [DiscoveredCharacteristic], service: String, failed: String?)] = []
        var values: [(value: Data?, characteristic: String, failed: String?)] = []
        var writes: [(characteristic: String, failed: String?)] = []
        var names: [String] = []

        func servicesDiscovered(_ uuids: [String], failed: String?) {
            services.append((uuids, failed))
        }

        func characteristicsDiscovered(
            _ found: [DiscoveredCharacteristic], ofService service: String, failed: String?
        ) {
            characteristics.append((found, service, failed))
        }

        func valueArrived(_ value: Data?, from characteristic: String, failed: String?) {
            values.append((value, characteristic, failed))
        }

        func writeAcknowledged(to characteristic: String, failed: String?) {
            writes.append((characteristic, failed))
        }

        func nameArrived(_ name: String) {
            names.append(name)
        }
    }

    /// An adapter over a fake bus, with the cube's tree already in it, and somewhere for the answers to go.
    private func cube(
        tree: BlueZObjectTree? = nil
    ) -> (gatt: BlueZCubeGatt, transport: FakeBlueZTransport, clock: HandDrivenScheduler, heard: Heard) {
        let transport = FakeBlueZTransport()
        transport.objectTree = tree ?? connectedCube
        let clock = HandDrivenScheduler()
        let gatt = BlueZCubeGatt(
            devicePath: devicePath, transport: transport, scheduler: clock, debugLog: nil
        )
        let heard = Heard()
        gatt.events = heard
        return (gatt, transport, clock, heard)
    }

    // MARK: - nothing is answered inside the call that asked

    @Test func testAnAnswerArrivesOnALaterTurnRatherThanInsideTheCall() {
        // **The whole reason the queue exists.** BlueZ's calls block where CoreBluetooth's do not, so the naive
        // translation hands `valueArrived` back from inside `read` -- and `DeviceLogin`, written against a
        // delegate that always answers later, re-enters itself once per step of a twenty-five step login.
        let (gatt, transport, clock, heard) = cube()
        transport.values[facesPath] = [3]

        gatt.read(TimeFlipUUIDs.facesString)

        #expect(heard.values.isEmpty, "the answer must not arrive inside the call")
        #expect(transport.reads == [facesPath], "though the read itself has happened")

        clock.tickAll()
        #expect(heard.values.count == 1)
    }

    @Test func testAnswersKeepTheOrderTheyWereRaisedIn() {
        // One wake draining a queue, rather than a wake each: two wakes of zero seconds are not promised to fire
        // in the order they were arranged, and a value that overtook its own discovery would be an answer to a
        // question the login had not asked yet.
        let (gatt, transport, clock, heard) = cube()
        transport.values[facesPath] = [3]

        gatt.discoverServices([TimeFlipUUIDs.serviceString])
        gatt.read(TimeFlipUUIDs.facesString)
        gatt.write(Data([0x10]), to: TimeFlipUUIDs.commandString, expectingAcknowledgement: true)
        clock.tickAll()

        #expect(heard.services.count == 1)
        #expect(heard.values.count == 1)
        #expect(heard.writes.count == 1)
        #expect(clock.arranged == 1, "one wake for the three of them")
    }

    // MARK: - discovery

    @Test func testTheServicesAreWhateverTheTreeSays() {
        // BlueZ has no discovery to request: services are resolved as part of connecting. So this answers the
        // whole list, which is what the port asks for -- everything found so far, not just this answer.
        let (gatt, _, clock, heard) = cube()

        gatt.discoverServices([TimeFlipUUIDs.serviceString])
        clock.tickAll()

        #expect(heard.services.first?.failed == nil)
        #expect(heard.services.first?.uuids.contains(TimeFlipUUIDs.canonical(TimeFlipUUIDs.serviceString)) == true)
        #expect(
            heard.services.first?.uuids.contains(TimeFlipUUIDs.canonical(TimeFlipUUIDs.batteryServiceString)) == true,
            "the battery service is in the tree whether or not this call asked about it"
        )
    }

    @Test func testATreeThatCannotBeReadIsAFailureRatherThanAnEmptyAnswer() {
        // A cube with no services and a bus that would not answer are different situations, and only one of them
        // is worth telling somebody about.
        let (gatt, transport, clock, heard) = cube()
        transport.treeFailure = BlueZRadio.Failure.noAdapter

        gatt.discoverServices([TimeFlipUUIDs.serviceString])
        clock.tickAll()

        #expect(heard.services.first?.uuids.isEmpty == true)
        #expect(heard.services.first?.failed == "there is no Bluetooth adapter")
    }

    @Test func testTheCharacteristicsOfAServiceAreTheOnesOnThatService() {
        let (gatt, _, clock, heard) = cube()

        gatt.discoverCharacteristics(nil, ofService: TimeFlipUUIDs.serviceString)
        clock.tickAll()

        let answer = heard.characteristics.first
        #expect(answer?.failed == nil)
        #expect(answer?.service == TimeFlipUUIDs.canonical(TimeFlipUUIDs.serviceString))
        #expect(answer?.found.count == 2, "the battery characteristic is on the other service")
        #expect(answer?.found.contains(where: { $0.uuid == TimeFlipUUIDs.canonical(TimeFlipUUIDs.facesString) }) == true)
    }

    @Test func testWhatCanNotifyComesFromTheCubesOwnFlags() {
        // The listening phase subscribes to everything that says it can push, which is the cube's declaration and
        // cannot be worked out from a UUID.
        let (gatt, _, clock, heard) = cube()

        gatt.discoverCharacteristics(nil, ofService: TimeFlipUUIDs.serviceString)
        clock.tickAll()

        let found = heard.characteristics.first?.found ?? []
        let faces = found.first { $0.uuid == TimeFlipUUIDs.canonical(TimeFlipUUIDs.facesString) }
        let command = found.first { $0.uuid == TimeFlipUUIDs.canonical(TimeFlipUUIDs.commandString) }
        #expect(faces?.canNotify == true)
        #expect(command?.canNotify == false)
    }

    @Test func testAskingForNamedCharacteristicsAnswersOnlyThose() {
        let (gatt, _, clock, heard) = cube()

        gatt.discoverCharacteristics([TimeFlipUUIDs.commandString], ofService: TimeFlipUUIDs.serviceString)
        clock.tickAll()

        #expect(heard.characteristics.first?.found.map(\.uuid) == [TimeFlipUUIDs.canonical(TimeFlipUUIDs.commandString)])
    }

    @Test func testAServiceThatIsNotThereIsAnsweredRatherThanDropped() {
        // Answered, because a caller waiting on a discovery that was never made waits for ever -- and this is
        // reachable: a service asked about before the tree resolved looks exactly like a cube that has none.
        let (gatt, _, clock, heard) = cube(tree: BlueZObjectTree([:]))

        gatt.discoverCharacteristics(nil, ofService: TimeFlipUUIDs.serviceString)
        clock.tickAll()

        #expect(heard.characteristics.first?.found.isEmpty == true)
        #expect(heard.characteristics.first?.failed == "the service was not found")
    }

    // MARK: - the spelling

    @Test func testAStandardCharacteristicIsFoundThoughTheTwoSidesSpellItDifferently() {
        // **The bug the Mac's version of this move introduced three times over.** The app says `2A19`; BlueZ says
        // `00002a19-0000-1000-8000-00805f9b34fb`. A plain string comparison finds nothing, and finds it quietly.
        let (gatt, transport, clock, heard) = cube()
        transport.values[batteryPath] = [63]

        gatt.read(TimeFlipUUIDs.batteryLevelString)
        clock.tickAll()

        #expect(transport.reads == [batteryPath])
        #expect(heard.values.first?.value == Data([63]))
        #expect(
            heard.values.first?.characteristic == TimeFlipUUIDs.canonical(TimeFlipUUIDs.batteryLevelString),
            "and the answer comes back in the canonical spelling, whatever was asked for"
        )
    }

    // MARK: - reading

    @Test func testAReadOfSomethingTheCubeDoesNotHaveIsAFailedAnswer() {
        let (gatt, transport, clock, heard) = cube()

        gatt.read(TimeFlipUUIDs.historyString)
        clock.tickAll()

        #expect(transport.reads.isEmpty, "there was no path to read")
        #expect(heard.values.first?.value == nil)
        #expect(heard.values.first?.failed == "the characteristic was not found")
    }

    @Test func testARefusedReadCarriesWhatBlueZSaid() {
        let (gatt, transport, clock, heard) = cube()
        transport.readFailures[facesPath] = BlueZGatt.Failure.refused("org.bluez.Error.NotConnected: Not connected")

        gatt.read(TimeFlipUUIDs.facesString)
        clock.tickAll()

        #expect(heard.values.first?.failed == "org.bluez.Error.NotConnected: Not connected")
    }

    // MARK: - writing

    @Test func testAWriteGoesToThePathAndIsAcknowledged() {
        let (gatt, transport, clock, heard) = cube()

        gatt.write(Data([0x10]), to: TimeFlipUUIDs.commandString, expectingAcknowledgement: true)
        clock.tickAll()

        #expect(transport.writes.first?.path == commandPath)
        #expect(transport.writes.first?.bytes == [0x10])
        #expect(transport.writes.first?.acknowledged == true)
        #expect(heard.writes.first?.characteristic == TimeFlipUUIDs.canonical(TimeFlipUUIDs.commandString))
        #expect(heard.writes.first?.failed == nil)
    }

    @Test func testTheWriteKindTravelsRatherThanBeingLeftToBlueZ() {
        // `CubeGatt` carries the distinction because CoreBluetooth's two write types are not interchangeable. A
        // platform that let the daemon pick from the characteristic's flags would be the two-platforms-disagreeing
        // case the port exists to rule out.
        let (gatt, transport, clock, _) = cube()

        gatt.write(Data([0x10]), to: TimeFlipUUIDs.commandString, expectingAcknowledgement: false)
        clock.tickAll()

        #expect(transport.writes.first?.acknowledged == false)
    }

    @Test func testARefusedWriteIsReportedAsARefusal() {
        let (gatt, transport, clock, heard) = cube()
        transport.writeFailure = BlueZGatt.Failure.refused("org.bluez.Error.NotPermitted: Write not permitted")

        gatt.write(Data([0x10]), to: TimeFlipUUIDs.commandString, expectingAcknowledgement: true)
        clock.tickAll()

        #expect(heard.writes.first?.failed == "org.bluez.Error.NotPermitted: Write not permitted")
    }

    // MARK: - listening

    @Test func testSubscribingStartsNotifyingAndWatchesTheDeviceToo() {
        let (gatt, transport, clock, _) = cube()

        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        clock.tickAll()

        #expect(transport.notifying == [facesPath])
        #expect(transport.watched == [devicePath], "the name arrives on the device, not on a characteristic")
    }

    @Test func testARefusedSubscriptionIsReportedRatherThanLogged() {
        // Where this parts company with `CoreBluetoothGatt`, deliberately: there a failed `setNotifyValue` only
        // writes a line. A subscription that silently did not happen is a cube whose face turns never arrive.
        let (gatt, transport, clock, heard) = cube()
        transport.notifyFailure = BlueZGatt.Failure.refused("org.bluez.Error.Failed: Not supported")

        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        clock.tickAll()

        #expect(heard.values.first?.failed == "org.bluez.Error.Failed: Not supported")
    }

    @Test func testAPushedValueArrivesAsAValueFromTheRightCharacteristic() {
        let (gatt, transport, clock, heard) = cube()
        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        clock.tickAll()

        transport.pushValue([5], from: facesPath)
        clock.tickAll()   // the poll
        clock.tickAll()   // the queue the poll filled

        #expect(heard.values.map(\.value) == [Data([5])])
        #expect(heard.values.first?.characteristic == TimeFlipUUIDs.canonical(TimeFlipUUIDs.facesString))
    }

    @Test func testTheBusesOwnChatterIsNotAValue() {
        // A new connection is sent `NameAcquired` whatever it subscribed to, and a `PropertiesChanged` on a
        // characteristic can carry `Notifying` rather than `Value`. A signal counts only when it says what is
        // being looked for.
        let (gatt, transport, clock, heard) = cube()
        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        clock.tickAll()

        transport.pushNoise()
        transport.pushValue([5], from: facesPath)
        clock.tickAll()
        clock.tickAll()

        #expect(heard.values.map(\.value) == [Data([5])], "the noise is not an answer and not an error either")
    }

    @Test func testAValueFromSomethingThatIsNotThisCubeIsIgnored() {
        let (gatt, transport, clock, heard) = cube()
        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        clock.tickAll()

        transport.pushValue([9], from: "/org/bluez/hci0/dev_11_22_33_44_55_66/service0001/char0002")
        clock.tickAll()
        clock.tickAll()

        #expect(heard.values.isEmpty)
    }

    @Test func testTheCubeSayingItsNameArrivesAsAName() {
        // The one thing that ever confirms a rename, and it is GAP rather than a characteristic -- which is why
        // the port gives it its own event on both platforms.
        let (gatt, transport, clock, heard) = cube()
        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        clock.tickAll()

        transport.pushDeviceProperties(["Name": .string("Harrys cube")], from: devicePath)
        clock.tickAll()
        clock.tickAll()

        #expect(heard.names == ["Harrys cube"])
    }

    @Test func testADevicePropertyThatIsNotTheNameSaysNothing() {
        let (gatt, transport, clock, heard) = cube()
        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        clock.tickAll()

        transport.pushDeviceProperties(["RSSI": .integer(-62)], from: devicePath)
        clock.tickAll()
        clock.tickAll()

        #expect(heard.names.isEmpty)
    }

    @Test func testTheBusIsOnlyDrainedOnceHoweverManyThingsSubscribe() {
        // One poll, not one per characteristic: the login subscribes to everything the cube says can notify, and a
        // timer each would be five polls reading the same socket.
        let (gatt, _, clock, _) = cube()

        gatt.subscribe(to: TimeFlipUUIDs.facesString)
        gatt.subscribe(to: TimeFlipUUIDs.batteryLevelString)
        clock.tickAll()

        #expect(clock.wakes.filter(\.repeating).count == 1)
    }
}
#endif

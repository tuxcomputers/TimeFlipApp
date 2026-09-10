#if canImport(CDBus)
import FacetCore
import Foundation

/// The Linux slot in the radio square's GATT half: BlueZ's object tree behind `CubeGatt`.
///
/// **`CoreBluetoothGatt` is the reference and this is the same job.** A UUID string in, an object path out, the
/// D-Bus call made, and the answer handed back as a UUID string. `DeviceLogin` -- the login sequence, the PIN
/// rotation, the read-back discipline, the deadlines, the history fetch -- is core and cannot tell which of the
/// two it has.
///
/// **The one place it differs from the Mac's, and the difference is BlueZ's rather than a choice.**
/// `CoreBluetoothGatt` keeps a table of characteristics by UUID because a `CBCharacteristic` is a live object
/// CoreBluetooth hands out during discovery and cannot be named from anywhere else. A BlueZ characteristic is an
/// object *path* and the tree can be asked for it again at any moment, so there is no table here at all: every
/// call looks the path up from a tree read at that moment, which is `CLAUDE.md`'s first rule with nothing given
/// up for it. The Mac's table is CoreBluetooth's design showing through, not something an adapter needs.
///
/// **Every answer is deferred by a wake of zero seconds**, rather than being handed back inside the call that
/// asked for it. BlueZ's calls are blocking where CoreBluetooth's are not, so a naive translation would call
/// `valueArrived` from inside `read`, and `DeviceLogin` -- written against a delegate that always answers on a
/// later turn of the run loop -- would re-enter itself twenty-five times down a single login. The queue below is
/// what makes the two adapters answer the same way, and it keeps the order they were raised in: two wakes of
/// zero seconds are not promised to fire in the order they were arranged, but one wake draining a queue is.
@MainActor
final class BlueZCubeGatt: CubeGatt {
    weak var events: CubeGattEvents?

    private let transport: BlueZGattTransport
    private let scheduler: Scheduler
    private let debugLog: DebugLog?

    /// The device this adapter is the GATT table of, as an object path. **The path rather than the address**,
    /// because everything below is a lookup against it and BlueZ answers paths.
    private let devicePath: String

    /// Answers waiting to be handed over, oldest first, and the one wake that will hand them over.
    private var pending: [() -> Void] = []
    private var drain: ScheduledWake?

    /// The poll that turns BlueZ's signals into `valueArrived`, once anything has subscribed.
    private var listening: ScheduledWake?

    /// How often the bus is drained once something is subscribed.
    ///
    /// **A poll, and `CLAUDE.md` says such a thing has to declare itself.** libdbus dispatches either into its
    /// own main loop or when it is pumped, and pumping is the half that does not ask GLib and libdbus to share
    /// ownership of a file descriptor. What is read on the timer is the socket, not a fact: a face turn is
    /// still the cube's own event carrying the cube's own timestamp, and nothing here decides anything from the
    /// clock. The cost of the interval is how late a face turn reaches the menu bar, which the label already
    /// redraws once a second.
    static let pollSeconds: TimeInterval = 0.1

    /// A cap on how many signals one poll drains, so a bus that is talking faster than this can read cannot hold
    /// the main loop. Anything left over is there on the next tick, a tenth of a second later.
    static let signalsPerPoll = 32

    init(
        devicePath: String,
        transport: BlueZGattTransport,
        scheduler: Scheduler,
        debugLog: DebugLog?
    ) {
        self.devicePath = devicePath
        self.transport = transport
        self.scheduler = scheduler
        self.debugLog = debugLog
    }

    // MARK: - what a caller asks for

    /// **BlueZ has no discovery to request**, which is the whole of what is odd about this method here: services
    /// are resolved as part of connecting, and `BlueZRadio.connect` does not answer until they are. So the tree
    /// is read and the answer is every service the device has.
    ///
    /// Answering all of them rather than only those asked about is what the port already specifies -- "the list
    /// is everything found so far, not just this answer" -- and it is what CoreBluetooth does too, its
    /// `peripheral.services` accumulating across three separate discoveries in one login.
    func discoverServices(_ uuids: [String]) {
        debugLog?.discovering(services: uuids)
        let tree: BlueZObjectTree
        do {
            tree = try transport.tree()
        } catch {
            let failed = Self.describe(error)
            debugLog?.discovered(services: [], failed: failed)
            answer { $0.servicesDiscovered([], failed: failed) }
            return
        }
        let found = tree.services(ofDevice: devicePath).map { TimeFlipUUIDs.canonical($0.uuid) }
        debugLog?.discovered(services: found, failed: nil)
        answer { $0.servicesDiscovered(found, failed: nil) }
    }

    func discoverCharacteristics(_ uuids: [String]?, ofService service: String) {
        debugLog?.discovering(characteristics: uuids, of: service)
        let tree: BlueZObjectTree
        do {
            tree = try transport.tree()
        } catch {
            let failed = Self.describe(error)
            debugLog?.discovered(characteristics: [], of: service, failed: failed)
            answer { $0.characteristicsDiscovered([], ofService: service, failed: failed) }
            return
        }

        guard let servicePath = tree.services(ofDevice: devicePath)
            .first(where: { TimeFlipUUIDs.match($0.uuid, service) })?.path
        else {
            // Answered rather than dropped, for `CoreBluetoothGatt`'s reason: a caller waiting on a discovery
            // that was never made waits for ever, and a service asked about before the tree resolved is exactly
            // that case.
            debugLog?.discovered(characteristics: [], of: service, failed: "the service was not found")
            answer {
                $0.characteristicsDiscovered([], ofService: service, failed: "the service was not found")
            }
            return
        }

        // Filtered when a filter was given, for the same reason CoreBluetooth's discovery is: the listening
        // phase passes `nil` and wants whatever the cube offers, and everything else names what it needs.
        let wanted = uuids.map { asked in Set(asked.map(TimeFlipUUIDs.canonical)) }
        let found = tree.characteristics(ofDevice: devicePath)
            .filter { $0.servicePath == servicePath }
            .filter { wanted?.contains(TimeFlipUUIDs.canonical($0.uuid)) ?? true }
            .map { DiscoveredCharacteristic(uuid: $0.uuid, canNotify: $0.canNotify) }

        debugLog?.discovered(characteristics: found.map(\.uuid), of: service, failed: nil)
        answer {
            $0.characteristicsDiscovered(found, ofService: TimeFlipUUIDs.canonical(service), failed: nil)
        }
    }

    func read(_ characteristic: String) {
        let uuid = TimeFlipUUIDs.canonical(characteristic)
        debugLog?.requested(uuid)
        guard let path = pathOf(characteristic) else {
            debugLog?.received(nil, from: uuid, failed: "the characteristic was not found")
            answer { $0.valueArrived(nil, from: uuid, failed: "the characteristic was not found") }
            return
        }
        do {
            let value = Data(try transport.read(path: path))
            debugLog?.received(value, from: uuid, failed: nil)
            answer { $0.valueArrived(value, from: uuid, failed: nil) }
        } catch {
            let failed = Self.describe(error)
            debugLog?.received(nil, from: uuid, failed: failed)
            answer { $0.valueArrived(nil, from: uuid, failed: failed) }
        }
    }

    func subscribe(to characteristic: String) {
        let uuid = TimeFlipUUIDs.canonical(characteristic)
        debugLog?.subscribing(true, to: uuid)
        guard let path = pathOf(characteristic) else {
            debugLog?.notifying(uuid, isNotifying: false, failed: "the characteristic was not found")
            answer { $0.valueArrived(nil, from: uuid, failed: "the characteristic was not found") }
            return
        }
        do {
            try transport.startNotifying(path: path)
            debugLog?.notifying(uuid, isNotifying: true, failed: nil)
            startListening()
        } catch {
            // **Reported rather than logged**, which is where this parts company with `CoreBluetoothGatt`: there
            // a failed `setNotifyValue` arrives in `didUpdateNotificationStateFor`, which only writes a line. A
            // subscription that silently did not happen is a cube whose face turns never arrive, and the caller
            // is the only thing that can say what to do about that.
            let failed = Self.describe(error)
            debugLog?.notifying(uuid, isNotifying: false, failed: failed)
            answer { $0.valueArrived(nil, from: uuid, failed: failed) }
        }
    }

    func write(_ payload: Data, to characteristic: String, expectingAcknowledgement: Bool) {
        let uuid = TimeFlipUUIDs.canonical(characteristic)
        debugLog?.transmitted(payload, to: uuid, acknowledged: expectingAcknowledgement)
        guard let path = pathOf(characteristic) else {
            debugLog?.acknowledged(uuid, failed: "the characteristic was not found")
            answer { $0.writeAcknowledged(to: uuid, failed: "the characteristic was not found") }
            return
        }
        do {
            try transport.write(path: path, bytes: [UInt8](payload), acknowledged: expectingAcknowledgement)
            debugLog?.acknowledged(uuid, failed: nil)
            // **BlueZ returning is the acknowledgement, and it is worth naming what that is worth.** It says the
            // bytes reached the device at the ATT layer and nothing more: a cube refuses every command until a
            // PIN has been accepted, and refuses it after the write has already succeeded. See `CLAUDE.md`,
            // "A command the device can be asked about is read back before it is believed".
            answer { $0.writeAcknowledged(to: uuid, failed: nil) }
        } catch {
            let failed = Self.describe(error)
            debugLog?.acknowledged(uuid, failed: failed)
            answer { $0.writeAcknowledged(to: uuid, failed: failed) }
        }
    }

    // MARK: - finding a characteristic

    /// The object path of a characteristic on this device, read from the tree now.
    private func pathOf(_ characteristic: String) -> String? {
        guard let tree = try? transport.tree() else { return nil }
        return tree.characteristic(ofDevice: devicePath, uuid: characteristic)?.path
    }

    // MARK: - what the cube says without being asked

    /// Starts draining the bus, if it is not being drained already.
    ///
    /// **The device's own properties are watched from here too**, which is what makes a rename confirmable: BlueZ
    /// reports the name on `org.bluez.Device1` rather than as a characteristic, exactly as GAP is not a
    /// characteristic on the Mac either.
    private func startListening() {
        guard listening == nil else { return }
        do {
            try transport.watchProperties(path: devicePath)
        } catch {
            debugLog?.record(.status, "The device properties could not be watched: \(Self.describe(error))")
        }
        listening = scheduler.wake(in: Self.pollSeconds, repeating: true) { [weak self] in
            self?.drainTheBus()
        }
    }

    private func drainTheBus() {
        for _ in 0 ..< Self.signalsPerPoll {
            guard let signal = transport.nextSignal() else { return }
            deliver(signal)
        }
    }

    /// Turns one signal into an event, or ignores it.
    ///
    /// **Filtered by what it says rather than by what it is.** A `PropertiesChanged` on a characteristic can
    /// carry `Notifying` rather than `Value`, and the bus sends a new connection its own `NameAcquired` whatever
    /// it subscribed to -- so a signal counts only when it carries the thing being looked for.
    private func deliver(_ signal: SystemBus.Signal) {
        guard signal.member == "PropertiesChanged" else { return }
        guard let interface = signal.arguments.first?.text,
              let changed = signal.arguments.dropFirst().first?.members
        else { return }

        if interface == BlueZObjectTree.characteristicInterface, let bytes = changed["Value"]?.data {
            guard let uuid = uuidOf(characteristicPath: signal.path) else {
                debugLog?.record(
                    .receive, "A value arrived from \(signal.path), which is not a characteristic of this cube"
                )
                return
            }
            let value = Data(bytes)
            debugLog?.received(value, from: uuid, failed: nil)
            answer { $0.valueArrived(value, from: uuid, failed: nil) }
            return
        }

        if interface == BlueZObjectTree.deviceInterface, signal.path == devicePath {
            // **`Name` before `Alias`, and this is the part still unverified on hardware.** `Name` is the
            // remote device's own GAP name, which is what a `0x15` rename moves on the Mac and what confirms
            // one; `Alias` is a local override that defaults to it. Whether BlueZ moves `Name` on a rename has
            // not been measured -- `BlueZRadio.scannedDevices` carries the same open question, and this is the
            // first thing to check when a cube is renamed on this platform.
            guard let name = changed["Name"]?.text ?? changed["Alias"]?.text, !name.isEmpty else { return }
            answer { $0.nameArrived(name) }
        }
    }

    /// Which characteristic an object path is, read from the tree now.
    private func uuidOf(characteristicPath path: String) -> String? {
        guard let tree = try? transport.tree() else { return nil }
        return tree.characteristics(ofDevice: devicePath)
            .first { $0.path == path }
            .map { TimeFlipUUIDs.canonical($0.uuid) }
    }

    // MARK: - answering later rather than now

    /// Queues an answer and makes sure something will hand it over.
    private func answer(_ event: @escaping (CubeGattEvents) -> Void) {
        pending.append { [weak self] in
            guard let events = self?.events else { return }
            event(events)
        }
        guard drain == nil else { return }
        drain = scheduler.wake(in: 0) { [weak self] in
            self?.handOverWhatIsWaiting()
        }
    }

    private func handOverWhatIsWaiting() {
        drain = nil
        // Taken whole before anything runs, because an event handler answering the cube queues the next answer,
        // and draining into the list being appended to is a loop that ends when the login does.
        let waiting = pending
        pending.removeAll()
        for event in waiting { event() }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let failure as BlueZGatt.Failure:
            switch failure {
            case let .noSuchCharacteristic(uuid): return "there is no characteristic \(uuid)"
            case let .refused(message): return message
            }
        case let failure as BlueZRadio.Failure:
            switch failure {
            case .noAdapter: return "there is no Bluetooth adapter"
            case let .notFound(address): return "\(address) is not a device BlueZ knows"
            case let .refused(message): return message
            }
        default: return "\(error)"
        }
    }
}

/// What `BlueZCubeGatt` needs of BlueZ, and the seam its tests take the place of.
///
/// **Five things and no decisions**, which is the same standard the port above it is held to. The production
/// conformance is `BlueZBusTransport` below, which is `BlueZRadio` and `BlueZGatt` side by side and nothing
/// else; `FakeBlueZTransport` in the tests is the second, and is what lets every translation above be checked
/// with no adapter, no daemon and no cube.
@MainActor
package protocol BlueZGattTransport: AnyObject {
    /// Everything BlueZ currently knows, read fresh.
    func tree() throws -> BlueZObjectTree
    func read(path: String) throws -> [UInt8]
    func write(path: String, bytes: [UInt8], acknowledged: Bool) throws
    func startNotifying(path: String) throws
    /// Start hearing `PropertiesChanged` for one object, which for a device is how its name arrives.
    func watchProperties(path: String) throws
    /// The next signal already waiting, without blocking. `nil` when there is none.
    func nextSignal() -> SystemBus.Signal?
}

/// The real one: the two BlueZ types this app already had, side by side.
@MainActor
package final class BlueZBusTransport: BlueZGattTransport {
    private let bus: SystemBus
    private let radio: BlueZRadio
    private let gatt: BlueZGatt

    package init(bus: SystemBus, radio: BlueZRadio) {
        self.bus = bus
        self.radio = radio
        gatt = BlueZGatt(bus: bus)
    }

    package func tree() throws -> BlueZObjectTree { try radio.tree() }
    package func read(path: String) throws -> [UInt8] { try gatt.read(path: path) }

    package func write(path: String, bytes: [UInt8], acknowledged: Bool) throws {
        try gatt.write(path: path, bytes: bytes, acknowledged: acknowledged)
    }

    package func startNotifying(path: String) throws { try gatt.startNotifying(path: path) }

    package func watchProperties(path: String) throws {
        try bus.addMatch(
            "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties'"
                + ",member='PropertiesChanged',path='\(path)'"
        )
    }

    /// **Zero milliseconds, because the caller is a wake on the app's own clock.** Blocking here would be the
    /// main loop waiting on a socket, which is the thing a poll exists to avoid.
    package func nextSignal() -> SystemBus.Signal? {
        bus.nextSignal(waitingMilliseconds: 0)
    }
}
#endif

import CoreBluetooth
import Foundation

/// Why a scan is not running, in the words the tab shows.
///
/// Separate from "found nothing" on purpose: a radio that is off, or that the user has refused this app, produces an
/// empty list exactly like a room with no cube in it, and an empty list is the one thing all three states have in
/// common. Saying which is the difference between somebody turning Bluetooth on and somebody buying a new cube.
enum ScanUnavailable: Equatable {
    case bluetoothOff
    case unauthorised
    case unsupported

    var message: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off. Turn it on to look for a TimeFlip."
        case .unauthorised: return "Facet is not allowed to use Bluetooth. Grant it in System Settings > Privacy & Security."
        case .unsupported: return "This Mac has no Bluetooth radio that Facet can use."
        }
    }
}

/// The radio, and nothing else.
///
/// **It decides nothing.** Every judgement about an advertisement belongs to `DeviceScanRules` and every judgement
/// about a PIN to `DeviceLoginRules`, both of which work on values and so are testable with no hardware; this turns
/// CoreBluetooth's callbacks into those values, keeps the list, and drives the sequence. That is the same split as
/// `DailyLimitEnforcement` and `DailyLimitWatch`, and for the same reason: the part worth testing must not be the
/// part that needs a device on the desk. Sequencing is not deciding -- which PIN to try, and what the answer to it
/// means, are both asked of the rules.
///
/// **It was `BluetoothScanner`, and the rename is the honest one.** Scanning and connecting cannot be two objects:
/// CoreBluetooth will only connect a peripheral through the very `CBCentralManager` that discovered it, so one owner
/// of the manager is not a design preference but the framework's rule. The class doc always did say "the radio".
///
/// **Nothing here is written to a table, and that is not a breach of the first rule in `CLAUDE.md`.** A scan result is
/// not a fact about the user's setup, it is what a radio heard in the last few seconds: it goes stale by itself, it is
/// gone when the window closes, and a stored copy would be a list of devices that were in the room once. A live
/// connection is the same kind of thing one step further on. What *is* durable about pairing already has rows
/// (`paired`, `device_uuid`, `device_name`) and this writes none of them, because reaching a cube is not pairing with
/// it -- `paired` is described in `database/011_setting.sql` as surviving every drop and every refusal, which is only
/// coherent if connecting never touches it. The two names the filter needs are read from the table when a scan starts,
/// at the point of use, and not held between scans.
@MainActor
final class BluetoothRadio: NSObject {
    /// Called as the list changes, already ordered. The whole list rather than each arrival, so the tab redraws from
    /// one answer instead of accumulating its own copy.
    var onDevicesChanged: (([ScannedDevice]) -> Void)?

    /// Called when scanning starts or stops, including when it stops itself because the radio went away.
    var onScanningChanged: ((Bool) -> Void)?

    /// Called when a scan cannot run, or `nil` when the reason has cleared.
    var onUnavailable: ((ScanUnavailable?) -> Void)?

    /// Called when an attempt to reach a device starts, and again when it ends. The two are separate because the
    /// first is the only thing that can be said for the several seconds in between, and a control that reports
    /// nothing until it succeeds is one somebody presses twice.
    var onLoginBegan: ((UUID) -> Void)?
    var onLoginEnded: ((UUID, DeviceLoginOutcome) -> Void)?

    /// Called when a connection this app was keeping goes away on its own: the cube out of range, switched off, or
    /// its batteries out. Not called for a disconnect this app asked for.
    var onConnectionDropped: ((UUID) -> Void)?

    /// How long a scan runs before stopping itself.
    ///
    /// **A cube that is awake answers in about a second**, advertising intervals being fractions of one, so thirty
    /// seconds is well past the point where waiting longer adds anything. What the bound is really for is the other
    /// end: a scan with no timeout runs until somebody presses the button again, and the radio then stays listening
    /// for the rest of the session with nothing on screen saying so. It also lets the status line say "no devices
    /// found" and mean it, instead of "looking" for ever.
    static let timeoutSeconds: TimeInterval = 30

    /// How long a connect is given before it is called unreachable.
    ///
    /// **`CBCentralManager.connect` has no timeout of its own** and will sit there indefinitely waiting for a cube
    /// that is asleep or gone, so this is the only thing that ends it. Fifteen seconds against a measured worst case
    /// of 5.4 across 36 logged connects (`Archive/TimeFlipApp/TimeFlipConstants.swift`), which leaves room for a slow
    /// one without leaving somebody watching a button that will never come back.
    static let connectTimeoutSeconds: TimeInterval = 15

    /// The pause between a refused PIN and the next attempt.
    ///
    /// **Copied from the archive as it stands, and it is worth keeping verbatim.** A refused login drops the link on
    /// its way out, and an immediate reconnect to the same peripheral races that teardown and comes back as a failure
    /// before anything is sent -- which reads as "could not reach it" and abandons the candidate that would have
    /// worked. That is not reasoning, it is what happened on 2026-08-10: `000000` refused, no second login attempt in
    /// the log at all, and a cube on a rotated PIN left unreachable.
    static let settleSeconds: TimeInterval = 1

    private let debugLog: DebugLog?
    private var central: CBCentralManager?
    private var found: [UUID: ScannedDevice] = [:]
    private var timeout: Timer?

    /// The peripherals behind the values in `found`.
    ///
    /// **Held because CoreBluetooth requires it**: a `CBPeripheral` nobody retains is deallocated, and connecting to
    /// one needs the object the scan produced rather than its identifier. Cleared with the list at the start of each
    /// scan, except for one that is currently connected -- dropping that would sever a live link to tidy up a list.
    private var peripherals: [UUID: CBPeripheral] = [:]

    /// How many devices the scan now running has listed. What the tab's status line reports once it stops.
    var deviceCount: Int { found.count }

    /// What the filter is matching against for the scan now running. Held only for the length of a scan, which is the
    /// span of the question it answers: the next scan reads the table again.
    private var remembered: String?
    private var previouslyKnown: String?
    private var isFiltering = true

    private(set) var isScanning = false

    /// One run at reaching a device: which one, and which PINs are left to try on it.
    private struct Attempt {
        let id: UUID
        var remaining: [String]
        var presenting: String
    }

    private var attempt: Attempt?
    private var connectTimeout: Timer?
    private var settle: Timer?
    /// Set while a disconnect is this app's doing, so the delegate can tell one apart from a cube that went away.
    private var isDisconnectingDeliberately = false

    /// The conversation with the connected peripheral, kept for as long as the connection is.
    ///
    /// **`CBPeripheral.delegate` is weak**, so this reference is what keeps the login from being deallocated mid
    /// exchange -- and afterwards it is what keeps every byte the cube sends unasked reaching the trace.
    private var login: DeviceLogin?

    /// The device this app is currently logged in to, or `nil`.
    private(set) var connectedDevice: UUID?

    init(debugLog: DebugLog?) {
        self.debugLog = debugLog
        super.init()
    }

    // MARK: - looking

    /// Starts looking.
    ///
    /// **The manager is made here rather than at launch**, so an app nobody has asked to scan never touches the radio
    /// and never provokes the system's Bluetooth permission prompt. `centralManagerDidUpdateState` is what actually
    /// begins the scan, because a manager is not usable the instant it is created: its state arrives asynchronously,
    /// and scanning before `.poweredOn` is a call that silently does nothing.
    ///
    /// - Parameters:
    ///   - filterToTimeFlip: what the **All Devices** box turns off.
    ///   - remembered: `device_name.name`, read from the table by the caller at this moment.
    ///   - previouslyKnown: `device_name.previous_name`, likewise.
    func start(filterToTimeFlip: Bool, remembered: String?, previouslyKnown: String?) {
        self.isFiltering = filterToTimeFlip
        self.remembered = remembered
        self.previouslyKnown = previouslyKnown
        // A fresh list per scan: a device that has since been switched off should leave the list, and the only
        // honest way to know it has gone is to stop claiming to have seen it.
        found = [:]
        peripherals = peripherals.filter { $0.key == connectedDevice }
        onDevicesChanged?([])
        debugLog?.record(
            .scan,
            "Scan requested, \(filterToTimeFlip ? "TimeFlip only" : "all devices")"
                + ", remembered \"\(remembered ?? "")\", previously \"\(previouslyKnown ?? "")\""
        )

        if central == nil {
            // **Said out loud, because the gap it opens is otherwise silent.** Building the manager does not start a
            // scan: the state arrives on the delegate and `beginScanIfReady` runs there. That is usually immediate,
            // but the first time this app ever asks for the radio it is however long somebody takes to answer the
            // system's Bluetooth prompt -- once, on one machine, and never again once allowed. Without this row the
            // log jumps from "Scan requested" to nothing, and a button that has not changed looks broken rather than
            // waiting, which is exactly how run 24 read it.
            debugLog?.record(.scan, "Waiting for the radio: building the central manager")
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        beginScanIfReady()
    }

    func stop() {
        stop(because: "stopped")
    }

    /// Stops, saying why in the log. The reason is not shown to the user: what they see is the list and whether it
    /// is still growing, and "timed out" against a list with the cube in it would read as a failure.
    private func stop(because reason: String) {
        timeout?.invalidate()
        timeout = nil
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        debugLog?.record(.scan, "Scan \(reason), \(found.count) device(s) listed")
        onScanningChanged?(false)
    }

    private func beginScanIfReady() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            report(unavailable(for: central.state))
            return
        }
        onUnavailable?(nil)
        // **No service filter, deliberately, even though the service UUID is known.** This hardware does not reliably
        // advertise it (measured by the archive's diagnostic scan, and the reason its own scan matched on names), so
        // asking CoreBluetooth for that service would find nothing at all. The filtering happens above, in
        // `DeviceScanRules`, where it can also match the names.
        //
        // `allowDuplicates` is left off: a second advertisement from a device already in the list tells this nothing
        // it does not know, and the callback fires many times a second per device.
        central.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
        // **The row that says the radio is actually listening**, as opposed to `Scan requested`, which says only that
        // somebody asked. The two are separated by however long the manager takes to power on, and the only other
        // evidence of the gap closing was `Bluetooth state:` -- which `centralManagerDidUpdateState` writes when the
        // state *changes*, so it appears on the first scan of a session and never again. From the second scan onwards
        // there was nothing at all between the request and the first advertisement, which is how `14-device-connect`
        // failed the first time it ran: it waited 60 seconds for a row that had already been written by `13`.
        debugLog?.record(.scan, "Scan started, listening for advertisements")
        // Armed here rather than in `start`, because `start` may only have built the manager: the clock should
        // measure the time the radio was actually listening, not the wait for it to power on.
        timeout?.invalidate()
        timeout = Timer(timeInterval: Self.timeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(because: "timed out after \(Int(Self.timeoutSeconds))s") }
        }
        // `.common`, so a scan still ends on time while a menu is being held open.
        if let timeout { RunLoop.main.add(timeout, forMode: .common) }
        onScanningChanged?(true)
    }

    private func unavailable(for state: CBManagerState) -> ScanUnavailable? {
        switch state {
        case .poweredOn: return nil
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .unauthorised
        case .unsupported: return .unsupported
        // `.resetting` and `.unknown` are both "ask again shortly": the delegate fires again when it settles, so
        // saying anything now would put a message on screen that a moment later is wrong.
        default: return nil
        }
    }

    private func report(_ reason: ScanUnavailable?) {
        if isScanning {
            isScanning = false
            onScanningChanged?(false)
        }
        if let reason {
            debugLog?.record(.scan, "Scan unavailable: \(reason)")
        }
        onUnavailable?(reason)
    }

    private func publish() {
        onDevicesChanged?(
            DeviceScanRules.ordered(Array(found.values), remembered: remembered, previouslyKnown: previouslyKnown)
        )
    }

    // MARK: - reaching one

    /// Connects to a listed device and presents PINs to it until one is accepted or they run out.
    ///
    /// **The candidates are handed in rather than worked out here**, which keeps the rule about what to try in
    /// `DeviceLoginRules` where it can be tested without a cube. This drives the sequence and reports what came of it.
    ///
    /// **The scan stops first.** A radio doing both is slower at each, and the list is about to be acted on rather
    /// than added to.
    func connect(to id: UUID, presenting candidates: [String]) {
        guard peripherals[id] != nil else {
            debugLog?.record(.login, "Asked to connect to \(id.uuidString), which is not a device this scan found")
            return
        }
        guard attempt == nil else {
            debugLog?.record(.login, "Already reaching a device; ignoring the request for \(id.uuidString)")
            return
        }
        guard let first = candidates.first else {
            debugLog?.record(.login, "No PIN to present to \(id.uuidString)")
            end(id, .wrongPIN)
            return
        }
        stop(because: "stopped: a device was chosen")
        // Anything already connected goes, before rather than after: two live links would leave the app holding a
        // cube nobody chose, and the one thing worse than not reaching a device is reaching the wrong one silently.
        disconnect(because: "another device was chosen")
        attempt = Attempt(id: id, remaining: Array(candidates.dropFirst()), presenting: first)
        onLoginBegan?(id)
        beginConnect()
    }

    /// Drops the connection, if there is one. Says nothing when there is nothing to drop: this is called on every
    /// window close and every tab change.
    func disconnect(because reason: String) {
        cancelAttempt()
        guard let id = connectedDevice, let peripheral = peripherals[id] else { return }
        debugLog?.record(.login, "Disconnecting from \(id.uuidString): \(reason)")
        isDisconnectingDeliberately = true
        connectedDevice = nil
        login = nil
        central?.cancelPeripheralConnection(peripheral)
    }

    /// Abandons an attempt in flight without reporting an outcome, for the two moments that are not the cube's doing:
    /// the window closing, and another device being chosen.
    private func cancelAttempt() {
        connectTimeout?.invalidate()
        connectTimeout = nil
        settle?.invalidate()
        settle = nil
        guard let attempt else { return }
        self.attempt = nil
        login = nil
        if let peripheral = peripherals[attempt.id], connectedDevice != attempt.id {
            isDisconnectingDeliberately = true
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func beginConnect() {
        guard let attempt, let peripheral = peripherals[attempt.id], let central else { return }
        debugLog?.record(
            .login,
            "Connecting to \(DeviceScanRules.label(for: found[attempt.id] ?? placeholder(attempt.id)))"
                + " (\(attempt.id.uuidString))"
        )
        isDisconnectingDeliberately = false
        central.connect(peripheral, options: nil)
        connectTimeout?.invalidate()
        connectTimeout = Timer(timeInterval: Self.connectTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let attempt = self.attempt else { return }
                self.debugLog?.record(.login, "No answer after \(Int(Self.connectTimeoutSeconds))s")
                self.end(attempt.id, .unreachable)
            }
        }
        if let connectTimeout { RunLoop.main.add(connectTimeout, forMode: .common) }
    }

    /// Presents the next PIN, once the one before it has been refused.
    private func retry() {
        guard var attempt, !attempt.remaining.isEmpty else { return }
        attempt.presenting = attempt.remaining.removeFirst()
        self.attempt = attempt
        login = nil
        // The link goes down between candidates rather than a second PIN being written over the first. The cube
        // forgets the password characteristic on disconnect and asks again on reconnect (protocol v4.3), so a fresh
        // connection is the state the exchange is specified in -- and the command result characteristic is left
        // holding the refusal, which finding 2 in `docs/timeflip2-firmware-observations.md` says is exactly the
        // circumstance where a stale value gets read as an answer.
        if let peripheral = peripherals[attempt.id] {
            isDisconnectingDeliberately = true
            central?.cancelPeripheralConnection(peripheral)
        }
        settle?.invalidate()
        settle = Timer(timeInterval: Self.settleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginConnect() }
        }
        if let settle { RunLoop.main.add(settle, forMode: .common) }
    }

    /// Ends the attempt, one way or the other, and says so once.
    private func end(_ id: UUID, _ outcome: DeviceLoginOutcome) {
        connectTimeout?.invalidate()
        connectTimeout = nil
        settle?.invalidate()
        settle = nil
        attempt = nil
        debugLog?.record(.login, "\(id.uuidString): \(outcome)")
        if outcome != .loggedIn, let peripheral = peripherals[id], connectedDevice != id {
            isDisconnectingDeliberately = true
            central?.cancelPeripheralConnection(peripheral)
        }
        onLoginEnded?(id, outcome)
    }

    /// What to call a device in a message about it.
    ///
    /// **Asked of the radio rather than remembered by the tab**, which is the same reasoning as handing the tab the
    /// whole list on every change: the scan owns what was found, so a caller keeping names by it would be a second
    /// copy of a list that moves.
    func label(for id: UUID) -> String {
        DeviceScanRules.label(for: found[id] ?? placeholder(id))
    }

    /// Stands in for a device that has left the list while an attempt on it is still running, so a log line can name
    /// something rather than trailing off.
    private func placeholder(_ id: UUID) -> ScannedDevice {
        ScannedDevice(id: id, peripheralName: nil, advertisedName: nil, advertisesTimeFlipService: false)
    }
}

// **`@preconcurrency` rather than a hop to the main actor**, which is a change from the version of this file that only
// scanned. That one read the two names off each advertisement and carried the values across, precisely because
// `CBPeripheral` is not `Sendable`; connecting needs the peripheral object itself, and there is no value it reduces
// to. The manager is created with `queue: .main`, so every callback below already arrives on the main thread and the
// conformance's runtime check is the assertion of that rather than a hope.
extension BluetoothRadio: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debugLog?.record(.scan, "Bluetooth state: \(central.state.rawValue)")
        guard central.state == .poweredOn else {
            found = [:]
            publish()
            report(unavailable(for: central.state))
            return
        }
        // Only start on the state that made it possible: this also fires when the radio comes back mid-session,
        // and picking the scan up then is what the user asked for when they pressed the button.
        beginScanIfReady()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // Overflow and solicited lists as well as the plain one: a service can arrive in any of the three, and this
        // costs nothing when it arrives in none of them, which on this hardware is most of the time.
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
        let device = ScannedDevice(
            id: peripheral.identifier,
            peripheralName: peripheral.name,
            advertisedName: advertisedName,
            advertisesTimeFlipService: services.contains(TimeFlipUUIDs.service)
        )

        guard !isFiltering
            || DeviceScanRules.isEligible(device, remembered: remembered, previouslyKnown: previouslyKnown)
        else {
            return
        }
        // Logged once per device rather than per advertisement, which arrives several times a second. Both names
        // go in the line, because the list is exactly where they disagree and a label nobody chose is
        // explicable from this row and guesswork without it.
        if found[device.id] == nil {
            debugLog?.record(
                .scan,
                "Found \(device.id.uuidString): peripheral \"\(device.peripheralName ?? "")\", "
                    + "advertised \"\(device.advertisedName ?? "")\""
                    + (device.advertisesTimeFlipService ? ", TimeFlip service" : "")
            )
        }
        // Kept whether or not the value changed: the list is drawn from the values, and the object behind them is
        // what a connect needs.
        peripherals[device.id] = peripheral
        guard found[device.id] != device else { return }
        found[device.id] = device
        publish()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let attempt, attempt.id == peripheral.identifier else { return }
        connectTimeout?.invalidate()
        connectTimeout = nil
        debugLog?.record(.login, "Connected to \(peripheral.identifier.uuidString), presenting a PIN")
        let login = DeviceLogin(
            peripheral: peripheral,
            pin: attempt.presenting,
            debugLog: debugLog
        ) { [weak self] outcome in
            self?.finish(attempt.id, outcome)
        }
        self.login = login
        login.begin()
    }

    /// What `finish` does with a refusal is the one branch that does not end the attempt: there may be another PIN.
    private func finish(_ id: UUID, _ outcome: DeviceLoginOutcome) {
        guard let attempt, attempt.id == id else { return }
        if outcome == .wrongPIN, !attempt.remaining.isEmpty {
            debugLog?.record(.login, "Refused, and there is another PIN to try")
            retry()
            return
        }
        if outcome == .loggedIn {
            connectedDevice = id
        }
        end(id, outcome)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let attempt, attempt.id == peripheral.identifier else { return }
        debugLog?.record(.login, "Could not connect: \(error?.localizedDescription ?? "no reason given")")
        end(attempt.id, .unreachable)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        debugLog?.record(
            .login,
            "Disconnected from \(id.uuidString)"
                + (isDisconnectingDeliberately ? ", as asked" : ", unexpectedly")
                + (error.map { ": \($0.localizedDescription)" } ?? "")
        )
        // A disconnect this app asked for has already been accounted for by whoever asked. Only an unexpected one
        // has anything to report, and which of the two it is is the difference between a tidy close and a cube whose
        // batteries have just come out.
        guard !isDisconnectingDeliberately else {
            isDisconnectingDeliberately = false
            return
        }
        if let attempt, attempt.id == id {
            login = nil
            end(id, .unreachable)
            return
        }
        guard connectedDevice == id else { return }
        connectedDevice = nil
        login = nil
        onConnectionDropped?(id)
    }
}

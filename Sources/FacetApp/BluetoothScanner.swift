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
/// **It decides nothing.** Every judgement about an advertisement belongs to `DeviceScanRules`, which works on values
/// and so is testable with no hardware; this turns CoreBluetooth's callbacks into those values and keeps the list.
/// That is the same split as `DailyLimitEnforcement` and `DailyLimitWatch`, and for the same reason: the part worth
/// testing must not be the part that needs a device on the desk.
///
/// **Nothing here is written to a table, and that is not a breach of the first rule in `CLAUDE.md`.** A scan result is
/// not a fact about the user's setup, it is what a radio heard in the last few seconds: it goes stale by itself, it is
/// gone when the window closes, and a stored copy would be a list of devices that were in the room once. What *is*
/// durable about pairing already has rows (`paired`, `device_uuid`, `device_name`) and this writes none of them,
/// because scanning is not pairing. The two names the filter needs are read from the table when a scan starts, at the
/// point of use, and not held between scans.
@MainActor
final class BluetoothScanner: NSObject {
    /// Called as the list changes, already ordered. The whole list rather than each arrival, so the tab redraws from
    /// one answer instead of accumulating its own copy.
    var onDevicesChanged: (([ScannedDevice]) -> Void)?

    /// Called when scanning starts or stops, including when it stops itself because the radio went away.
    var onScanningChanged: ((Bool) -> Void)?

    /// Called when a scan cannot run, or `nil` when the reason has cleared.
    var onUnavailable: ((ScanUnavailable?) -> Void)?

    /// How long a scan runs before stopping itself.
    ///
    /// **A cube that is awake answers in about a second**, advertising intervals being fractions of one, so thirty
    /// seconds is well past the point where waiting longer adds anything. What the bound is really for is the other
    /// end: a scan with no timeout runs until somebody presses the button again, and the radio then stays listening
    /// for the rest of the session with nothing on screen saying so. It also lets the status line say "no devices
    /// found" and mean it, instead of "looking" for ever.
    static let timeoutSeconds: TimeInterval = 30

    private let debugLog: DebugLog?
    private var central: CBCentralManager?
    private var found: [UUID: ScannedDevice] = [:]
    private var timeout: Timer?

    /// How many devices the scan now running has listed. What the tab's status line reports once it stops.
    var deviceCount: Int { found.count }

    /// What the filter is matching against for the scan now running. Held only for the length of a scan, which is the
    /// span of the question it answers: the next scan reads the table again.
    private var remembered: String?
    private var previouslyKnown: String?
    private var isFiltering = true

    private(set) var isScanning = false

    init(debugLog: DebugLog?) {
        self.debugLog = debugLog
        super.init()
    }

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
        onDevicesChanged?([])
        debugLog?.record(
            .scan,
            "Scan requested, \(filterToTimeFlip ? "TimeFlip only" : "all devices")"
                + ", remembered \"\(remembered ?? "")\", previously \"\(previouslyKnown ?? "")\""
        )

        if central == nil {
            // **Said out loud, because the gap it opens is otherwise silent.** Building the manager does not start a
            // scan: the state arrives on the delegate and `beginScanIfReady` runs there, which on the very first use
            // can be a while, since this is the moment macOS asks the user whether Facet may use Bluetooth at all.
            // Without this row the log jumps from "Scan requested" to nothing, and a button that has not changed
            // looks broken rather than waiting (seen in run 24, where no state ever arrived).
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
}

extension BluetoothScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // The state is read out here and the manager itself is not carried across: `CBCentralManager` is not
        // `Sendable`, so handing the object to the main actor is a data race the compiler will not allow. This
        // object already holds the same manager in `central`, so there is nothing to carry.
        let state = central.state
        MainActor.assumeIsolated {
            debugLog?.record(.scan, "Bluetooth state: \(state.rawValue)")
            guard state == .poweredOn else {
                found = [:]
                publish()
                report(unavailable(for: state))
                return
            }
            // Only start on the state that made it possible: this also fires when the radio comes back mid-session,
            // and picking the scan up then is what the user asked for when they pressed the button.
            beginScanIfReady()
        }
    }

    nonisolated func centralManager(
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

        MainActor.assumeIsolated {
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
            guard found[device.id] != device else { return }
            found[device.id] = device
            publish()
        }
    }
}

/// The vendor's UUIDs, from `docs/TimeFlip2 BLE Protocol v4.3.md`.
///
/// Only the service is here, because only the service is what a scan can ask about. The characteristics arrive with
/// the feature that reads them.
enum TimeFlipUUIDs {
    /// The string is the constant and the `CBUUID` is built on demand: `CBUUID` is a class and is not `Sendable`, so
    /// held as a `static let` it is a shared mutable global and the compiler refuses it.
    static let serviceString = "F1196F50-71A4-11E6-BDF4-0800200C9A66"

    static var service: CBUUID { CBUUID(string: serviceString) }
}

@preconcurrency import CoreBluetooth
import Foundation
import OSLog

enum DeviceConnectOutcome: Sendable, Equatable {
    case connected
    case notTimeFlip
    case wrongPassword
    case failed
    case cancelled
}

@MainActor
final class TimeFlipBLEDevice: NSObject, TimeFlipSessionManaging {
    private enum DeviceError: Error, CustomStringConvertible {
        case bluetoothUnavailable
        case discoveryTimeout
        case connectionFailed
        case serviceDiscoveryFailed
        case missingCharacteristic(CBUUID)
        case readFailed(CBUUID)
        case writeFailed(CBUUID)
        case loginFailed
        case commandError(cmd: UInt8, code: UInt8)
        case cancelled
        case timedOut

        var description: String {
            switch self {
            case .bluetoothUnavailable:
                return "Bluetooth unavailable or powered off"
            case .discoveryTimeout:
                return "TimeFlip not found while scanning"
            case .connectionFailed:
                return "Failed to connect to TimeFlip"
            case .serviceDiscoveryFailed:
                return "Failed to discover TimeFlip services"
            case .missingCharacteristic(let uuid):
                return "Missing characteristic \(uuid.uuidString)"
            case .readFailed(let uuid):
                return "Read failed for \(uuid.uuidString)"
            case .writeFailed(let uuid):
                return "Write failed for \(uuid.uuidString)"
            case .loginFailed:
                return "Password rejected by device"
            case .commandError(let cmd, let code):
                return String(format: "Command 0x%02X failed with code 0x%02X", cmd, code)
            case .cancelled:
                return "Connection attempt cancelled"
            case .timedOut:
                return "Device did not respond in time"
            }
        }
    }

    private struct Continuations {
        var poweredOn: CheckedContinuation<Void, Error>?
        var connection: CheckedContinuation<Void, Error>?
        var services: CheckedContinuation<Void, Error>?
        var characteristics: CheckedContinuation<Void, Error>?
        var notification: [CBUUID: CheckedContinuation<Void, Error>] = [:]
        var reads: [CBUUID: CheckedContinuation<Data, Error>] = [:]
        var writes: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    }

    /// Fully isolated state for a candidate connection under test. None of this touches the
    /// active session's `peripheral`/`characteristics`/`continuations` — that stays untouched
    /// and fully functional until the probe proves the candidate connects, is a real TimeFlip,
    /// and accepts the given password. Only then does connectToDiscoveredDevice commit it.
    private final class ProbeSession {
        let peripheral: CBPeripheral
        var connection: CheckedContinuation<Void, Error>?
        var services: CheckedContinuation<Void, Error>?
        var characteristicsContinuation: CheckedContinuation<Void, Error>?
        var writes: [CBUUID: CheckedContinuation<Void, Error>] = [:]
        var reads: [CBUUID: CheckedContinuation<Data, Error>] = [:]
        var characteristics: [CBUUID: CBCharacteristic] = [:]

        init(peripheral: CBPeripheral) {
            self.peripheral = peripheral
        }
    }

    private let central: CentralManaging
    private var peripheral: PeripheralManaging?
    private var continuations = Continuations()
    // Timeout watchdogs for the continuations above, keyed so a stale watchdog from an earlier
    // attempt (e.g. "connection", "write:<uuid>") can be cancelled the moment its continuation
    // resumes instead of lingering to potentially fail a later attempt reusing the same slot.
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var activeProbe: ProbeSession?
    private var stream: AsyncStream<TimeFlipEvent>?
    private var continuation: AsyncStream<TimeFlipEvent>.Continuation?
    private var isLoggedIn = false
    // Set by cancelConnectionAttempt() so a login failure downstream of a cancelled
    // connect can be told apart from a genuine wrong-PIN rejection.
    private(set) var wasCancelled = false
    // Set when the device explicitly rejects a login (a real commandResult response with a
    // non-success code), as opposed to a connection-level failure (thrown error, no response) --
    // lets a caller tell "this password is wrong" apart from "couldn't reach the device at all",
    // e.g. to fall back to the factory default password on reconnect after an out-of-band reset.
    private(set) var wasWrongPassword = false
    // When true we accept peripherals that advertise the TimeFlip service or name.
    private var allowBroadDiscovery = false
    // When true, discovered peripherals are only reported via onDeviceDiscovered, never connected to.
    private var isDiscoveryScanning = false
    private var discoveryFilterToTimeFlip = true
    // The single timeout used for every BLE communication with the device (scanning, connecting,
    // service/characteristic discovery, notifications, writes, reads). On timeout, whatever step
    // was in flight is aborted and the peripheral is force-disconnected — see handleTimeout(_:).
    private let deviceOperationTimeoutSeconds: UInt64
    /// How long a connect scan waits before concluding the device isn't there, separately from the
    /// watchdog above. Defaults to the same value, and `ApplicationDelegate` lowers it for the
    /// startup attempts that decide whether to offer manual mode: those have to reach a verdict
    /// while someone is watching, and the long watchdog is sized for a device that is present but
    /// slow rather than one that is absent. Measured against a cube that is actually there,
    /// scan-and-link has never taken more than 5.4s across 36 logged connects (`conn-phase` rows in
    /// both databases, 2026-08-09), so the startup budget still leaves a wide margin.
    ///
    /// Restored to the full watchdog once a launch has connected: after that the app is reconnecting
    /// to a device it has already reached, and there is no dialog waiting on the answer.
    var connectScanTimeoutSeconds: UInt64
    /// What `connectScanTimeoutSeconds` goes back to. This instance's own watchdog rather than a
    /// second copy of the literal, so a device built with a shorter one for a test is restored to
    /// that and not to 30.
    var defaultConnectScanTimeoutSeconds: UInt64 { deviceOperationTimeoutSeconds }
    // Peripherals seen during a discovery scan, keyed by identifier, so a user-selected entry
    // can be connected to directly rather than re-scanning and grabbing the first match.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    /// Peripherals already written to the scan log in the current scan, one set per outcome, so a
    /// scan reports each peripheral once rather than once per advertisement callback.
    ///
    /// `CBCentralManagerScanOptionAllowDuplicatesKey: false` coalesces only *identical*
    /// advertisements, so anything that varies its payload is re-reported every time it changes.
    /// Measured 2026-08-09 during a factory-reset confirm: 254 scan rows for 8 peripherals across
    /// two 30-second scans, one TV alone accounting for 21 of them by alternating between carrying
    /// its local name and omitting it. The repetition said nothing the first line hadn't.
    ///
    /// Two sets rather than one, because that same varying payload decides the outcome: a
    /// peripheral whose packet arrives without either name is skipped, and the same peripheral is
    /// listed when the next packet carries one. Keying on the identifier alone would hide whichever
    /// of the two came second, which is exactly the disagreement worth seeing.
    private var loggedScanSkips: Set<UUID> = []
    private var loggedScanListings: Set<UUID> = []
    /// How often the eligibility scan checks whether the paired device has turned up. Short enough
    /// that the saving is the whole remaining window rather than most of it, long enough that a
    /// 30-second scan costs 120 wakeups and not 30,000.
    private let scanPollIntervalNanoseconds: UInt64 = 250_000_000
    var onDisconnect: (() -> Void)?
    /// Fires when CoreBluetooth notices the connected peripheral's GAP name has changed, which is
    /// the only authoritative signal this app gets that a rename actually took. Confirmed working
    /// on this hardware -- see `peripheralDidUpdateName`.
    var onDeviceNameChanged: ((String?) -> Void)?
    var onDeviceDiscovered: ((DiscoveredBLEDevice) -> Void)?
    var onDiscoveryScanStopped: (() -> Void)?
    private var snapshotState = TimeFlipDeviceSnapshot(
        faceID: TimeFlipConstants.unassignedFaceID,
        isPaused: true,
        isLocked: false,
        autoPauseMinutes: 0,
        batteryLevel: TimeFlipConstants.minBatteryLevel,
        systemState: .ok,
        deviceTime: Date(),
        deviceInfo: nil
    )
    private var historyStreamContinuation: AsyncStream<Data>.Continuation?
    private let defaultLEDBrightness: UInt8 = 50
    private let defaultBlinkIntervalSeconds: UInt8 = 5

    private let commandGate = AsyncGate()
    private let historyGate = AsyncGate()

    private let logger: Logger
    private let requiredCharacteristicUUIDs: Set<CBUUID> = [
        TimeFlipUUIDs.eventsData,
        TimeFlipUUIDs.faces,
        TimeFlipUUIDs.commandResult,
        TimeFlipUUIDs.command,
        TimeFlipUUIDs.doubleTap,
        TimeFlipUUIDs.systemState,
        TimeFlipUUIDs.password,
        TimeFlipUUIDs.history,
        TimeFlipUUIDs.batteryLevel
    ]

    init(
        central: CentralManaging? = nil,
        logger: Logger = Logger(subsystem: AppIdentifiers.subsystem, category: "ble-device"),
        deviceOperationTimeoutSeconds: UInt64 = 30
    ) {
        self.central = central ?? CBCentralManager()
        self.logger = logger
        self.deviceOperationTimeoutSeconds = deviceOperationTimeoutSeconds
        self.connectScanTimeoutSeconds = deviceOperationTimeoutSeconds
        super.init()
        self.central.delegate = self
    }

    #if DEBUG
    /// Test-only: establishes a connected session directly, bypassing the real discovery flow
    /// (which needs concrete `CBPeripheral`/`CBService` instances that only CoreBluetooth itself
    /// can construct). Lets tests reach "connected with known characteristics" so they can start
    /// a command and then exercise disconnect-cleanup or timeout behavior against it.
    func test_configureConnectedState(
        peripheral: PeripheralManaging,
        characteristics: [CBUUID: CBCharacteristic],
        isLoggedIn: Bool = true
    ) {
        self.peripheral = peripheral
        self.characteristics = characteristics
        self.isLoggedIn = isLoggedIn
    }
    #endif

    // MARK: TimeFlipSessionManaging

    var events: AsyncStream<TimeFlipEvent> {
        if let stream {
            return stream
        }
        let stream = AsyncStream<TimeFlipEvent> { continuation in
            self.continuation = continuation
        }
        self.stream = stream
        return stream
    }

    func start() {
        _ = events
        logger.notice("TimeFlipBLEDevice start requested")
    }

    func stop() {
        logger.notice("TimeFlipBLEDevice stopping; tearing down stream and connection")
        stopDiscoveryScan()
        if let peripheral = peripheral as? CBPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central.stopScan()
        failAllPendingContinuations(with: DeviceError.connectionFailed)
        historyStreamContinuation?.finish()
        historyStreamContinuation = nil
        isLoggedIn = false
        characteristics.removeAll()
        continuation?.finish()
        continuation = nil
        stream = nil
        logger.notice("TimeFlipBLEDevice stopped")
    }

    /// Scan for TimeFlip-like peripherals and report them via onDeviceDiscovered without connecting.
    func startDiscoveryScan(filterToTimeFlip: Bool) async {
        do {
            try await waitForBluetoothPower()
        } catch {
            logger.error("startDiscoveryScan: Bluetooth unavailable")
            return
        }
        guard !isDiscoveryScanning else { return }
        isDiscoveryScanning = true
        discoveryFilterToTimeFlip = filterToTimeFlip
        discoveredPeripherals.removeAll()
        beginScanLogging()
        logger.notice("Starting discovery-only scan (filterToTimeFlip=\(filterToTimeFlip, privacy: .public))")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        let timeoutNanoseconds = deviceOperationTimeoutSeconds * TimeConstants.nanosecondsPerSecond
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self?.stopDiscoveryScan()
        }
    }

    func stopDiscoveryScan() {
        guard isDiscoveryScanning else { return }
        isDiscoveryScanning = false
        central.stopScan()
        logger.notice("Stopped discovery-only scan")
        // Silent for an eligibility scan, for the same reason it doesn't announce what it finds:
        // the Device tab's scan button never started this one, so it must not see it end.
        guard !isCollectingEligibleOnly else { return }
        onDiscoveryScanStopped?()
    }

    func connect() async -> Bool {
        do {
            logger.notice("connect() begin")
            let clock = ContinuousClock()
            let begin = clock.now
            DeveloperMode.debugPrint(.connPhase, "connect begin")
            stopDiscoveryScan()

            try await waitForBluetoothPower()
            let powered = clock.now
            DeveloperMode.debugPrint(.connPhase, "connect radio powered: \(Self.elapsed(from: begin, to: powered))")

            try await scanAndConnect()
            let connected = clock.now
            DeveloperMode.debugPrint(.connPhase, "connect scan+link established: \(Self.elapsed(from: powered, to: connected))")

            try await discoverServicesAndCharacteristics()
            let discovered = clock.now
            DeveloperMode.debugPrint(.connPhase, "connect characteristics discovered: \(Self.elapsed(from: connected, to: discovered))")

            logger.notice("connect() completed")
            DeveloperMode.debugPrint(.connPhase, "connect complete, total: \(Self.elapsed(from: begin, to: discovered))")
            return true
        } catch {
            logger.error("BLE connect failed: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.connPhase, "connect failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Whole milliseconds between two `ContinuousClock` instants, rendered as e.g. `742ms`.
    ///
    /// A monotonic clock rather than `Date`, because these spans exist to calibrate the mock's
    /// delay ranges and a wall-clock adjustment mid-connect would silently corrupt the figure.
    /// `debug_log` already carries millisecond wall-clock timestamps, so the deltas are only
    /// logged where the boundary isn't already inferable from two adjacent rows.
    static func elapsed(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> String {
        let components = (end - start).components
        let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return "\(milliseconds)ms"
    }

    /// Every device this app could plausibly be paired to, from one scan window, best candidate
    /// first. The caller then tries to log in to each until one lets it in (see
    /// `ApplicationDelegate.connectToPairedDevice`).
    ///
    /// **This replaces connecting to whatever answered first.** The original driver stopped the
    /// scan and connected the instant any peripheral matched on name (`23fe40e`, the upstream
    /// initial release), which is fine with one cube on the desk and wrong everywhere else: in an
    /// office with several TimeFlips it grabs a colleague's, is refused at login because their PIN
    /// is not this app's, and gives up without ever having tried the user's own device sitting
    /// right there. The stored `device_uuid` could have settled it and was never consulted by the
    /// connect path at all.
    ///
    /// `preferring` is that uuid. It orders rather than filters: it is assigned by this Mac's
    /// CoreBluetooth stack, so it is the surest identification available when it is present, but a
    /// cube that has been re-paired or reset can legitimately no longer carry it and still be the
    /// user's device. Putting it first means the usual case costs exactly one login attempt.
    /// - Parameter mayEndEarly: whether finding the preferred device is allowed to cut the window
    ///   short. False while a factory reset is being confirmed, where the device that is present
    ///   right now is the wrong one: see `waitForScanWindow`.
    func scanForEligibleDevices(
        preferring pairedUUID: UUID?,
        mayEndEarly: Bool = true
    ) async -> [EligibleDevice] {
        isCollectingEligibleOnly = true
        defer { isCollectingEligibleOnly = false }
        await startDiscoveryScan(filterToTimeFlip: true)
        // `&&` short-circuits into an autoclosure, which cannot carry the await, so the branch is
        // spelled out.
        var endedEarly = false
        if mayEndEarly {
            endedEarly = await waitForScanWindow(preferring: pairedUUID)
        } else {
            try? await Task.sleep(
                nanoseconds: connectScanTimeoutSeconds * TimeConstants.nanosecondsPerSecond
            )
        }
        stopDiscoveryScan()

        let found = discoveredPeripherals.map { id, peripheral in
            EligibleDevice(id: id, name: peripheral.name ?? "Unknown Device")
        }
        let candidates = EligibleDevice.ordered(found, preferring: pairedUUID)
        let leadsWithPaired = candidates.first?.id == pairedUUID && pairedUUID != nil
        DeveloperMode.debugPrint(
            .scan,
            "eligible after scan: \(candidates.isEmpty ? "none" : candidates.map(\.name).joined(separator: ", "))"
                + (leadsWithPaired ? " (paired device first)" : "")
                + (endedEarly ? " (scan ended early: paired device found)" : "")
                + " paired_uuid=\(pairedUUID?.uuidString ?? "none")"
                + " seen=[\(discoveredPeripherals.keys.map(\.uuidString).sorted().joined(separator: ", "))]"
        )
        return candidates
    }

    /// Holds the scan open for its window, or until the paired device turns up, whichever is first.
    /// Reports whether it was the second.
    ///
    /// The window is there so every candidate is in hand before `ordered` ranks them, which matters
    /// in a room with more than one cube: connecting to whichever answered first is the bug that
    /// created this method. But `ordered` puts the paired uuid at the head of the list, so once that
    /// device has been seen there is nothing a later arrival could change. Waiting on past that
    /// point buys nothing and costs the rest of the window.
    ///
    /// The cost was measured on 2026-08-09, confirming a factory reset: the cube was in the scan
    /// results at 23:54:43.5 and the app did not act on it until 23:55:14.2, thirty-one seconds of
    /// a seventy-second confirm spent waiting for a window that had already found its answer.
    ///
    /// **Confirming a factory reset is the one case that must not use this**, which is what
    /// `mayEndEarly: false` is for, and it took hardware to find out. A cube does not stop
    /// advertising the instant `0xFF` is written: measured 2026-08-10, one was still in the scan
    /// results three seconds after the command and still accepted its pre-reset password eight
    /// seconds after. Ending the window early attached the app to that pre-reboot cube, and holding
    /// the connection then stopped it advertising, so every later scan of the confirm loop reported
    /// nothing while the app sat connected to the device it was looking for. The reset was declared
    /// unconfirmed after the full 120 seconds and the cube never reset at all.
    ///
    /// The old unconditional window survived this by luck rather than design, probing only at the
    /// end of thirty seconds, by which time the cube had usually gone. Waiting the window out is
    /// what actually makes the confirm correct, so here it is deliberate rather than incidental.
    ///
    /// Note this cannot help when the stored uuid is not the peripheral's real identifier.
    /// `AppState.recordPairing` falls back to a fresh random uuid when the pairing did not carry
    /// one, and such a value matches nothing, so the window runs its full length. The log line above
    /// prints the stored uuid next to the identifiers actually seen, which is what makes that case
    /// tellable from a genuine absence.
    private func waitForScanWindow(preferring pairedUUID: UUID?) async -> Bool {
        let deadline = ContinuousClock().now.advanced(
            by: .seconds(Int64(connectScanTimeoutSeconds))
        )
        while ContinuousClock().now < deadline {
            if let pairedUUID, discoveredPeripherals[pairedUUID] != nil { return true }
            try? await Task.sleep(nanoseconds: scanPollIntervalNanoseconds)
            // A cancelled sleep returns immediately, so without this the loop would spin the
            // remaining window at full tilt rather than ending with the task.
            if Task.isCancelled { return false }
        }
        return false
    }

    /// Connect to a peripheral the user picked from a discovery scan result, verifying it's
    /// actually a TimeFlip and that it accepts the given password — entirely via an isolated
    /// probe — before touching the active session at all. If anything about the candidate fails
    /// (wrong device, wrong password, timeout), the currently connected device (if any) is left
    /// completely untouched and still fully functional.
    func connectToDiscoveredDevice(id: UUID, password: String) async -> DeviceConnectOutcome {
        stopDiscoveryScan()
        wasCancelled = false
        guard let target = discoveredPeripherals[id] else {
            logger.error("connectToDiscoveredDevice: unknown peripheral id")
            return .failed
        }

        let probe = ProbeSession(peripheral: target)
        activeProbe = probe
        defer {
            if activeProbe === probe {
                activeProbe = nil
            }
        }

        do {
            try await waitForBluetoothPower()
            target.delegate = self
            try await probeConnect(probe)

            do {
                try await probeDiscoverTimeFlipCharacteristics(probe)
            } catch {
                central.cancelPeripheralConnection(target)
                if case DeviceError.cancelled = error {
                    return .cancelled
                }
                return .notTimeFlip
            }

            let loggedIn: Bool
            do {
                loggedIn = try await probeAttemptLogin(password: password, probe: probe)
            } catch {
                central.cancelPeripheralConnection(target)
                if case DeviceError.cancelled = error {
                    return .cancelled
                }
                return .failed
            }
            guard loggedIn else {
                central.cancelPeripheralConnection(target)
                return .wrongPassword
            }

            // Everything checks out — only now do we touch the active session, replacing
            // whatever was there before (if anything).
            if let oldPeripheral = self.peripheral as? CBPeripheral, oldPeripheral !== target {
                central.cancelPeripheralConnection(oldPeripheral)
            }
            self.peripheral = target
            self.characteristics = probe.characteristics
            self.isLoggedIn = true
            activeProbe = nil

            do {
                try await discoverServicesAndCharacteristics()
            } catch {
                if case DeviceError.cancelled = error {
                    return .cancelled
                }
                return .failed
            }
            logger.notice("connectToDiscoveredDevice: connected, verified TimeFlip, and login confirmed")
            return .connected
        } catch {
            central.cancelPeripheralConnection(target)
            if case DeviceError.cancelled = error {
                return .cancelled
            }
            logger.error("connectToDiscoveredDevice failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Cancel an in-progress connectToDiscoveredDevice attempt (user clicked the same or a
    /// different device mid-connect). If a probe is in flight, only it is torn down — the
    /// active session (if any) is never touched. Falls back to cancelling the active session's
    /// own connect attempt only when there's no probe (e.g. the very first pairing attempt).
    func cancelConnectionAttempt() {
        logger.notice("Cancelling in-progress connection attempt")
        wasCancelled = true
        if let probe = activeProbe {
            central.cancelPeripheralConnection(probe.peripheral)
            probe.connection?.resume(throwing: DeviceError.cancelled)
            probe.connection = nil
            probe.services?.resume(throwing: DeviceError.cancelled)
            probe.services = nil
            probe.characteristicsContinuation?.resume(throwing: DeviceError.cancelled)
            probe.characteristicsContinuation = nil
            for (_, continuation) in probe.writes {
                continuation.resume(throwing: DeviceError.cancelled)
            }
            probe.writes.removeAll()
            for (_, continuation) in probe.reads {
                continuation.resume(throwing: DeviceError.cancelled)
            }
            probe.reads.removeAll()
            activeProbe = nil
            return
        }
        if let cbPeripheral = peripheral as? CBPeripheral {
            central.cancelPeripheralConnection(cbPeripheral)
        }
        failAllPendingContinuations(with: DeviceError.cancelled)
    }

    private func probeConnect(_ probe: ProbeSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probe.connection = continuation
            central.connect(probe.peripheral, options: nil)
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.deviceOperationTimeoutSeconds * TimeConstants.nanosecondsPerSecond)
                if probe.connection != nil {
                    self.logger.error("Probe connect timed out")
                    DeveloperMode.debugPrint(.timeFlip, "TIMEOUT after \(self.deviceOperationTimeoutSeconds)s while: Probe connect")
                    self.central.cancelPeripheralConnection(probe.peripheral)
                    probe.connection?.resume(throwing: DeviceError.connectionFailed)
                    probe.connection = nil
                }
            }
        }
    }

    private func probeDiscoverTimeFlipCharacteristics(_ probe: ProbeSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probe.services = continuation
            probe.peripheral.discoverServices([TimeFlipUUIDs.service])
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.deviceOperationTimeoutSeconds * TimeConstants.nanosecondsPerSecond)
                if probe.services != nil {
                    self.logger.error("Probe service discovery timed out")
                    DeveloperMode.debugPrint(.timeFlip, "TIMEOUT after \(self.deviceOperationTimeoutSeconds)s while: Probe service discovery")
                    probe.services?.resume(throwing: DeviceError.serviceDiscoveryFailed)
                    probe.services = nil
                }
            }
        }
        guard let service = probe.peripheral.services?.first(where: { $0.uuid == TimeFlipUUIDs.service }) else {
            throw DeviceError.serviceDiscoveryFailed
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probe.characteristicsContinuation = continuation
            probe.peripheral.discoverCharacteristics([TimeFlipUUIDs.password, TimeFlipUUIDs.commandResult], for: service)
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.deviceOperationTimeoutSeconds * TimeConstants.nanosecondsPerSecond)
                if probe.characteristicsContinuation != nil {
                    self.logger.error("Probe characteristic discovery timed out")
                    DeveloperMode.debugPrint(.timeFlip, "TIMEOUT after \(self.deviceOperationTimeoutSeconds)s while: Probe characteristic discovery")
                    probe.characteristicsContinuation?.resume(throwing: DeviceError.serviceDiscoveryFailed)
                    probe.characteristicsContinuation = nil
                }
            }
        }
        guard probe.characteristics[TimeFlipUUIDs.password] != nil,
              probe.characteristics[TimeFlipUUIDs.commandResult] != nil else {
            throw DeviceError.serviceDiscoveryFailed
        }
    }

    private func probeWrite(_ data: Data, to uuid: CBUUID, probe: ProbeSession) async throws {
        guard let characteristic = probe.characteristics[uuid] else {
            throw DeviceError.missingCharacteristic(uuid)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            probe.writes[uuid] = continuation
            probe.peripheral.writeValue(data, for: characteristic, type: .withResponse)
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.deviceOperationTimeoutSeconds * TimeConstants.nanosecondsPerSecond)
                if probe.writes[uuid] != nil {
                    self.logger.error("Probe write timed out for \(uuid.uuidString, privacy: .public)")
                    DeveloperMode.debugPrint(.timeFlip, "TIMEOUT after \(self.deviceOperationTimeoutSeconds)s while: Probe write to \(uuid.uuidString)")
                    probe.writes[uuid]?.resume(throwing: DeviceError.writeFailed(uuid))
                    probe.writes[uuid] = nil
                }
            }
        }
    }

    private func probeRead(_ uuid: CBUUID, probe: ProbeSession) async throws -> Data? {
        guard let characteristic = probe.characteristics[uuid] else {
            throw DeviceError.missingCharacteristic(uuid)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            probe.reads[uuid] = continuation
            probe.peripheral.readValue(for: characteristic)
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.deviceOperationTimeoutSeconds * TimeConstants.nanosecondsPerSecond)
                if probe.reads[uuid] != nil {
                    self.logger.error("Probe read timed out for \(uuid.uuidString, privacy: .public)")
                    DeveloperMode.debugPrint(.timeFlip, "TIMEOUT after \(self.deviceOperationTimeoutSeconds)s while: Probe read from \(uuid.uuidString)")
                    probe.reads[uuid]?.resume(throwing: DeviceError.readFailed(uuid))
                    probe.reads[uuid] = nil
                }
            }
        }
    }

    private func probeAttemptLogin(password: String, probe: ProbeSession) async throws -> Bool {
        let passwordData = Data(password.utf8)
        // Logged the same way the session login is. Without this the probe was the one login path
        // in the app that recorded neither the password it sent nor the code it got back, so a
        // refusal here could not be told from a refusal there -- which is exactly what a
        // wrong-PIN diagnosis needs (2026-08-09).
        DeveloperMode.debugPrint(.timeFlip, "Probe logging in using password: \(passwordData.hexString())")
        try await probeWrite(passwordData, to: TimeFlipUUIDs.password, probe: probe)
        guard let response = try await probeRead(TimeFlipUUIDs.commandResult, probe: probe) else {
            DeveloperMode.debugPrint(.timeFlip, "Probe login: no commandResult response")
            return false
        }
        let code = response.first ?? 0
        DeveloperMode.debugPrint(.timeFlip, "Probe login commandResult raw bytes: \(response.hexString()) -> \(code == 0x02 ? "accepted" : "rejected")")
        return code == 0x02
    }

    /// Called whenever any single BLE communication (connect, service/characteristic discovery,
    /// notification, write, read, history stream) doesn't get a response within
    /// deviceOperationTimeoutSeconds. Unconditionally disconnects and fails whatever else is
    /// still pending — a timeout on any one step means we stop everything, no exceptions.
    private func handleTimeout(_ operation: String) {
        logger.error("\(operation, privacy: .public) timed out after \(self.deviceOperationTimeoutSeconds, privacy: .public)s; disconnecting")
        DeveloperMode.debugPrint(.timeFlip, "TIMEOUT after \(deviceOperationTimeoutSeconds)s while: \(operation) — disconnecting")
        if let cbPeripheral = peripheral as? CBPeripheral {
            central.cancelPeripheralConnection(cbPeripheral)
        }
        failAllPendingContinuations(with: DeviceError.timedOut)
    }

    private func failAllPendingContinuations(with error: Error) {
        continuations.connection?.resume(throwing: error)
        continuations.connection = nil
        continuations.services?.resume(throwing: error)
        continuations.services = nil
        continuations.characteristics?.resume(throwing: error)
        continuations.characteristics = nil
        for (_, continuation) in continuations.notification {
            continuation.resume(throwing: error)
        }
        continuations.notification.removeAll()
        for (_, continuation) in continuations.writes {
            continuation.resume(throwing: error)
        }
        continuations.writes.removeAll()
        for (_, continuation) in continuations.reads {
            continuation.resume(throwing: error)
        }
        continuations.reads.removeAll()
        cancelAllTimeouts()
    }

    /// Schedules a timeout watchdog under `key`, cancelling any previous watchdog registered
    /// under the same key first. `action` only runs if the watchdog isn't cancelled first.
    /// Not `private` so TimeFlipBLEDeviceTests can exercise the keyed-cancellation guarantee
    /// directly (the scan-timeout race this fixes has no reproduction path that doesn't need a
    /// real CBPeripheral, which can't be constructed outside CoreBluetooth).
    func scheduleTimeout(_ key: String, action: @escaping (TimeFlipBLEDevice) -> Void) {
        timeoutTasks[key]?.cancel()
        // The scan is the one phase that gets its own budget (see connectScanTimeoutSeconds). Every
        // other phase is talking to a device already known to be there, where the long watchdog is
        // the right answer; the scan is the phase that has to conclude the device is absent.
        let timeoutSeconds = key == "connection" ? connectScanTimeoutSeconds : deviceOperationTimeoutSeconds
        timeoutTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * TimeConstants.nanosecondsPerSecond)
            guard !Task.isCancelled, let self else { return }
            self.timeoutTasks[key] = nil
            action(self)
        }
    }

    func cancelTimeout(_ key: String) {
        timeoutTasks[key]?.cancel()
        timeoutTasks[key] = nil
    }

    private func cancelAllTimeouts() {
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
    }

    func disconnect() async {
        stop()
    }

    func login(password: String) async -> Bool {
        wasWrongPassword = false
        guard password.count == 6 else {
            logger.error("Password must be 6 characters")
            return false
        }
        do {
            return try await attemptLogin(with: password)
        } catch {
            logger.error("Login failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    private func attemptLogin(with password: String) async throws -> Bool {
        let passwordData = Data(password.utf8)
        logger.debug("Logging in using password (pwd=\(password, privacy: .private))")
        // This is the per-session LOGIN write, not a password change: the device wipes its Password
        // characteristic on every disconnect and demands it again on reconnect (BLE spec v4.3), so
        // this fires on every connect. Changing the PIN is the separate 0x30 command in
        // rotateDevicePassword ("Rotating device password to:" / "Device password confirmed set to:").
        DeveloperMode.debugPrint(.timeFlip, "Logging in using password: \(passwordData.hexString())")
        try await write(passwordData, to: TimeFlipUUIDs.password, type: .withResponse)
        DeveloperMode.debugPrint(.timeFlip, "Password sent; reading commandResult…")
        guard let response = try await read(TimeFlipUUIDs.commandResult) else {
            logger.error("TimeFlip login had no commandResult response")
            DeveloperMode.debugPrint(.timeFlip, "Login: no commandResult response (nil)")
            return false
        }
        DeveloperMode.debugPrint(.timeFlip, "Login commandResult raw bytes: \(response.hexString())")
        let code = response.first ?? 0
        // Vendor doc v4.3 states 0x01=correct/0x02=wrong, but real hardware observed here does
        // the opposite (confirmed via logging: wrong password -> 0x01, correct -> 0x02).
        if code == 0x02 {
            isLoggedIn = true
            logger.notice("TimeFlip login accepted (code=\(code))")
            DeveloperMode.debugPrint(.timeFlip, String(format: "Login accepted, code=0x%02X", code))
            return true
        } else {
            wasWrongPassword = true
            logger.error("TimeFlip login rejected code=\(code)")
            DeveloperMode.debugPrint(.timeFlip, String(format: "Login rejected, code=0x%02X", code))
            return false
        }
    }

    func enableNotifications() async {
        logger.debug("Enabling notifications for faces/doubleTap/system/events/battery")
        let clock = ContinuousClock()
        let begin = clock.now
        DeveloperMode.debugPrint(.connPhase, "enableNotifications begin (5 subscriptions)")
        await withNotification(TimeFlipUUIDs.faces, enabled: true)
        await withNotification(TimeFlipUUIDs.doubleTap, enabled: true)
        await withNotification(TimeFlipUUIDs.systemState, enabled: true)
        await withNotification(TimeFlipUUIDs.eventsData, enabled: true)
        await withNotification(TimeFlipUUIDs.batteryLevel, enabled: true)
        logger.notice("Notification subscriptions set")
        DeveloperMode.debugPrint(.connPhase, "enableNotifications complete: \(Self.elapsed(from: begin, to: clock.now))")
    }

    func initializeSession(hostTime: Date, desiredAutoPauseMinutes: UInt16) async {
        guard isLoggedIn else { return }
        logger.notice("Initializing session with hostTime \(hostTime.timeIntervalSince1970, privacy: .public)")
        let clock = ContinuousClock()
        let begin = clock.now
        DeveloperMode.debugPrint(.connPhase, "initializeSession begin")
        await setDeviceTime(hostTime)
        await refreshStatus()
        await AutoPauseNormalizer.normalize(
            currentMinutes: snapshotState.autoPauseMinutes,
            desiredMinutes: desiredAutoPauseMinutes,
            logger: logger
        ) { [weak self] minutes in
            guard let self else { return }
            await self.setAutoPause(minutes: minutes)
        }
        await refreshDeviceInfo()
        await primeSnapshot()
        await readSystemState(context: "post-initialize health check")
        DeveloperMode.debugPrint(.connPhase, "initializeSession complete: \(Self.elapsed(from: begin, to: clock.now))")
    }

    func setFaceColor(faceID: UInt8, components: ColorComponents) async {
        guard isLoggedIn else { return }
        guard TimeFlipConstants.isValidFaceID(faceID) else { return }
        let (r, g, b) = components.deviceRGB16
        var payload = Data(repeating: 0, count: 8)
        payload[0] = 0x11
        payload[1] = faceID
        payload[2] = UInt8(r >> 8); payload[3] = UInt8(r & 0xFF)
        payload[4] = UInt8(g >> 8); payload[5] = UInt8(g & 0xFF)
        payload[6] = UInt8(b >> 8); payload[7] = UInt8(b & 0xFF)
        do {
            logger.debug("Setting color face=\(faceID, privacy: .public) r=\(r) g=\(g) b=\(b)")
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to set color face=\(faceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Emulates the official app's apparent behavior of setting a private device password on
    /// connect (command 0x30), so a stranger with the default PIN can't pair with this device.
    /// The generated password is also printed so it's recoverable from the terminal if something
    /// goes wrong with saving/using it.
    ///
    /// In dev builds this always rotates to the same fixed `DeveloperMode.devicePassword` instead
    /// of a random password -- otherwise every pairing would leave the device on an unpredictable
    /// PIN, defeating the point of dev mode's fixed-PIN convenience (see AppState.init).
    ///
    /// **Deliberately the constant and not `config.json`'s PIN**, even though that file is what a
    /// paired connect presents. The constant is compiled into the pairing candidate list, so a cube
    /// this app has rotated is always reachable by a re-pair no matter what happens to the file.
    /// Rotating onto the file's value instead would put the cube on a PIN that only that file
    /// names, and an edit to it afterwards would strand the cube: pairing would have nothing left
    /// to guess, and neither Forget nor a factory reset can help, both needing a login first. The
    /// caller records this value into `config.json` (see `AppState.recordDevicePasswordInConfig`),
    /// which is how the file comes to hold what the cube is actually on.
    ///
    /// The new password is only returned (and therefore only saved by the caller) once the
    /// device has actually confirmed it via a real re-login attempt — the set-password command's
    /// own ack isn't treated as sufficient proof the device will honor it on the next connect.
    func rotateDevicePassword() async -> String? {
        guard isLoggedIn else { return nil }
        let generatedRandomPassword = DeveloperMode.isEnabled
            ? DeveloperMode.devicePassword
            : String(format: "%06d", Int.random(in: 0...999_999))
        DeveloperMode.debugPrint(.timeFlip, "Rotating device password to: \(generatedRandomPassword)")
        let clock = ContinuousClock()
        let begin = clock.now
        let payload = Data([0x30]) + Data(generatedRandomPassword.utf8)
        do {
            _ = try await performCommand(payload)
        } catch {
            logger.error("Set-password command failed: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to set new device password: \(error.localizedDescription)")
            return nil
        }
        let written = clock.now
        DeveloperMode.debugPrint(.connPhase, "password rotate 0x30 write: \(Self.elapsed(from: begin, to: written))")
        do {
            guard try await attemptLogin(with: generatedRandomPassword) else {
                logger.error("Device rejected re-login with new password; not saving")
                DeveloperMode.debugPrint(.timeFlip, "Device did NOT confirm new password \(generatedRandomPassword) — not saving")
                return nil
            }
        } catch {
            logger.error("Failed to confirm new device password: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to confirm new device password: \(error.localizedDescription)")
            return nil
        }
        logger.notice("Device password rotated and confirmed")
        DeveloperMode.debugPrint(.timeFlip, "Device password confirmed set to: \(generatedRandomPassword)")
        DeveloperMode.debugPrint(
            .connPhase,
            "password rotate confirm re-login: \(Self.elapsed(from: written, to: clock.now)), total: \(Self.elapsed(from: begin, to: clock.now))"
        )
        return generatedRandomPassword
    }

    /// Sets the device password back to the factory default before "Forget Device" clears our
    /// own pairing state, so the device isn't left behind on a private password nobody has.
    /// Returns true only once the reset is confirmed via a real re-login with the default
    /// password — the caller should not clear its stored password unless this returns true.
    @discardableResult
    func resetDevicePasswordToDefault() async -> Bool {
        guard isLoggedIn else { return false }
        DeveloperMode.debugPrint(.timeFlip, "Resetting device password to default: \(TimeFlipConstants.defaultPassword)")
        let clock = ContinuousClock()
        let begin = clock.now
        let payload = Data([0x30]) + Data(TimeFlipConstants.defaultPassword.utf8)
        do {
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to reset device password to default: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to reset device password to default: \(error.localizedDescription)")
            return false
        }
        let written = clock.now
        DeveloperMode.debugPrint(.connPhase, "password reset 0x30 write: \(Self.elapsed(from: begin, to: written))")
        do {
            guard try await attemptLogin(with: TimeFlipConstants.defaultPassword) else {
                logger.error("Device rejected re-login with default password; reset not confirmed")
                DeveloperMode.debugPrint(.timeFlip, "Device did NOT confirm default password reset — not clearing stored password")
                return false
            }
        } catch {
            logger.error("Failed to confirm default password reset: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to confirm default password reset: \(error.localizedDescription)")
            return false
        }
        logger.notice("Device password reset to default and confirmed")
        DeveloperMode.debugPrint(.timeFlip, "Device password confirmed reset to default: \(TimeFlipConstants.defaultPassword)")
        DeveloperMode.debugPrint(
            .connPhase,
            "password reset confirm re-login: \(Self.elapsed(from: written, to: clock.now)), total: \(Self.elapsed(from: begin, to: clock.now))"
        )
        return true
    }

    /// Full factory reset (command 0xFF): erases all flash-stored data on the device -- face
    /// colors, task/pomodoro parameters, name, password, everything -- back to factory settings.
    /// Per the vendor spec this is the same command the official app's "Disconnect TimeFlip"
    /// button triggers.
    ///
    /// Returns true once the 0xFF command has been written (the device sends no usable ack for it --
    /// see below). This only *sends* the reset; it does NOT confirm it. We deliberately do not
    /// re-login here to confirm: the device erases flash and reboots asynchronously (reverting the
    /// password to the factory default), so an immediate same-connection re-login races that reboot
    /// and comes back as a spurious wrong-password rejection (observed live: code 0x01). Instead the
    /// caller (ApplicationDelegate) drops the connection and confirms the reset out-of-band, by the
    /// device coming back on the factory default password on the next reconnect -- and treats that
    /// login as the reset confirmation, NOT as a pairing.
    @discardableResult
    func factoryReset() async -> Bool {
        guard isLoggedIn else { return false }
        DeveloperMode.debugPrint(.timeFlip, "Factory reset (0xFF) triggered")
        let clock = ContinuousClock()
        let begin = clock.now
        let payload = Data([0xFF])
        let result: Data
        do {
            result = try await performCommand(payload)
        } catch {
            logger.error("Failed to factory reset device: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to factory reset device: \(error.localizedDescription)")
            return false
        }
        // The device sends NO usable ack for 0xFF: verified live (bugfix/resetDevice), the command
        // result characteristic still held the *previous* command's response (a stale 0x17 double-tap
        // read: "17 3A 5A 3B 14 3C 32 3D 32 ...") -- the device reboots without writing a fresh result
        // for 0xFF. So there's nothing synchronous to confirm on; we treat the successful write as the
        // trigger to forget, and the reset is confirmed out-of-band (the 0x01 0x00 System State
        // notification and the default password being accepted on any later manual re-pair). The raw
        // read-back is still logged for regression visibility (performCommand's own log is
        // .debug-level os_log that macOS doesn't persist), but it is NOT a meaningful ack.
        logger.notice("Device factory reset (0xFF) sent; no ack expected, read-back=\(result.hexString(), privacy: .public) (likely stale)")
        DeveloperMode.debugPrint(.timeFlip, "Factory reset (0xFF) sent; device sends no ack, read-back=\(result.hexString()) (likely stale); awaiting device reboot to confirm via default-password login")
        // Only covers writing 0xFF. The erase-and-reboot the device then performs is deliberately
        // not waited on here (see above), so this is the command cost, not the reset's true cost --
        // that one is only observable as the delay before the device reappears on the default
        // password, which ApplicationDelegate bounds with factoryResetConfirmTimeout.
        DeveloperMode.debugPrint(.connPhase, "factory reset 0xFF write: \(Self.elapsed(from: begin, to: clock.now))")
        return true
    }

    /// See `TimeFlipDevice.deviceName`. CoreBluetooth refreshes this from the peripheral's GAP name
    /// once connected, so after a rename it reports the new name without the app re-reading
    /// anything.
    var deviceName: String? {
        peripheral?.name
    }

    /// See `TimeFlipDevice.deviceIdentifier`.
    var deviceIdentifier: String? {
        (peripheral as? CBPeripheral)?.identifier.uuidString
    }

    func snapshot() -> TimeFlipDeviceSnapshot {
        snapshotState
    }

    /// Read device time (command 0x07) for diagnostics.
    func readDeviceTime() async -> Date? {
        guard isLoggedIn else { return nil }
        do {
            let payload = Data([0x07])
            let response = try await performCommand(payload)
            let bytes = [UInt8](response)
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            guard bytes.count >= 5, bytes[0] == 0x07 else {
                logger.error("readDeviceTime: unexpected payload len=\(bytes.count) hex=\(hex, privacy: .public)")
                return nil
            }
            // Payload sometimes comes as 8 bytes with leading zeros then BE timestamp.
            let payloadBytes = Array(bytes.dropFirst())
            let candidate1 = payloadBytes.count >= 4 ? payloadBytes[0..<4] : []
            let candidate2 = payloadBytes.count >= 8 ? payloadBytes[4..<8] : []

            func toBE32(_ slice: ArraySlice<UInt8>) -> UInt32 {
                slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }

            let seconds: UInt32 = {
                let c1 = toBE32(candidate1)
                if c1 != 0 { return c1 }
                let c2 = toBE32(candidate2)
                if c2 != 0 { return c2 }
                // Fallback: use last 4 bytes
                if payloadBytes.count >= 4 {
                    return toBE32(payloadBytes.suffix(4))
                }
                return 0
            }()

            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            let drift = date.timeIntervalSinceNow
            logger.notice("Device time read seconds=\(seconds, privacy: .public) drift_s=\(drift, privacy: .public) raw=\(hex, privacy: .public)")
            return date
        } catch {
            logger.error("readDeviceTime failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry] {
        guard isLoggedIn else {
            logger.error("fetchHistory skipped: not logged in")
            return []
        }
        guard characteristics[TimeFlipUUIDs.history] != nil else {
            logger.error("fetchHistory skipped: history characteristic missing")
            return []
        }

        return await historyGate.withLock {
            let start = eventNumber ?? 0
            let entries = await streamHistory(startingFrom: start)
            return await fillHistoryGaps(entries, startingFrom: start)
        }
    }

    /// Per the vendor spec, the 0x02 stream only sends "intervals that lasted for at least 5 sec"
    /// -- confirmed against real hardware: a missing event number turned out to be a genuine,
    /// valid 4-second segment the device holds and will return via a single-event (0x01) read, but
    /// deliberately omits from the 0x02 stream. Below this duration, an "absent" event number is
    /// the device's own documented filtering, not something to recover.
    private static let minimumStreamedIntervalSeconds: TimeInterval = 5

    /// A BLE notification can also be dropped mid-stream (confirmed separately against real
    /// hardware) -- streamHistory has no way to tell "the device deliberately omitted this" or "we
    /// just didn't receive that notification" apart from "the device deliberately omitted this
    /// because it's under 5 seconds" vs either of those, so this checks for any event number in
    /// [startingFrom...last received] that's absent from the batch, and re-requests each one
    /// individually (the same single-event command readLastEvent uses, just with a real event
    /// number instead of the 0xFFFFFFFF sentinel). A recovered entry only gets kept if it meets the
    /// same minimum duration the stream itself requires -- otherwise it's the device's own filter
    /// working as documented, not a gap. Also recovers frames streamHistory itself skipped due to a
    /// local parse failure, since that takes the same "missing from entries" shape.
    private func fillHistoryGaps(_ entries: [TimeFlipHistoryEntry], startingFrom start: UInt32) async -> [TimeFlipHistoryEntry] {
        guard let lastEventNumber = entries.compactMap(\.eventNumber).max(), lastEventNumber >= start else {
            return entries
        }
        let received = Set(entries.compactMap(\.eventNumber))
        var filled = entries
        var recoveredAny = false

        for candidate in start...lastEventNumber where !received.contains(candidate) {
            guard let recovered = await readLastEventLocked(candidate) else {
                logger.error("History gap NOT recovered ev=\(candidate, privacy: .public)")
                DeveloperMode.debugPrint(.histGap, "history gap NOT recovered ev=\(candidate)")
                continue
            }
            guard recovered.duration >= Self.minimumStreamedIntervalSeconds else {
                logger.notice("History gap explained ev=\(candidate, privacy: .public) dur=\(recovered.duration, privacy: .public) (under 5s, device's own filter)")
                DeveloperMode.debugPrint(.histGap, "history gap explained: ev=\(candidate) dur=\(recovered.duration)s under 5s, device's own filter")
                continue
            }
            filled.append(recovered)
            recoveredAny = true
            logger.notice("History gap recovered ev=\(candidate, privacy: .public)")
            DeveloperMode.debugPrint(.histGap, "history gap recovered ev=\(candidate)")
        }

        if recoveredAny {
            filled.sort { ($0.eventNumber ?? 0) < ($1.eventNumber ?? 0) }
        }
        return filled
    }

    func readLastEvent() async -> TimeFlipHistoryEntry? {
        await readSingleEvent(0xFFFFFFFF)
    }

    private func readSingleEvent(_ eventNumber: UInt32) async -> TimeFlipHistoryEntry? {
        guard isLoggedIn else {
            logger.error("readSingleEvent skipped: not logged in")
            return nil
        }
        guard characteristics[TimeFlipUUIDs.history] != nil else {
            logger.error("readSingleEvent skipped: history characteristic missing")
            return nil
        }
        return await historyGate.withLock {
            await readLastEventLocked(eventNumber)
        }
    }

    // MARK: - Private helpers

    private func waitForBluetoothPower() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .poweredOff, .unauthorized, .unsupported:
            // Terminal states: no future centralManagerDidUpdateState will rescue us, so
            // waiting on a continuation here would hang forever.
            throw DeviceError.bluetoothUnavailable
        case .unknown, .resetting:
            break
        @unknown default:
            break
        }
        logger.debug("Waiting for Bluetooth power-on")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.poweredOn = continuation
        }
        if central.state != .poweredOn {
            throw DeviceError.bluetoothUnavailable
        }
    }

    /// The name the app last saw this Mac's device carrying, from the `device_name` setting. Set by
    /// `ApplicationDelegate` at startup and whenever a rename lands.
    ///
    /// Without it a renamed cube is simply lost: reconnecting is a **scan**, not a lookup of the
    /// stored peripheral uuid, so the only thing standing between the app and its device is a name
    /// match. Renaming to anything not containing "timeflip" then makes every scan time out, on
    /// every launch -- which is exactly what happened on 2026-08-01 with a cube renamed "Hazza".
    var rememberedDeviceName: String?

    /// The name this cube was called before `rememberedDeviceName`, from
    /// `device_name.previous_name`. Kept alongside it because the GAP name macOS reports is one
    /// connection stale after a rename, so the scan straight after one is still seeing the old
    /// name. Without this the app can lose the device at exactly the moment it renamed it.
    var previouslyKnownDeviceName: String?

    /// True while `scanForEligibleDevices` is using the discovery scan to build its own candidate
    /// list. Same collection, but the pairing UI must not hear about it: this scan runs on every
    /// launch, and its results appearing in the Device tab's "Scan for Devices" list would be a
    /// list nobody asked for, arriving while the user is looking at something else.
    private var isCollectingEligibleOnly = false

    /// Whether a discovered advertisement is from a device worth listing or connecting to.
    ///
    /// **Both filter sites go through this one function on purpose.** They used to inline the test
    /// separately, and the copies drifted: the connect path learned to check the advertised name
    /// while the discovery scan was left checking only `peripheral.name`, so a renamed cube could
    /// be connected to but not found by a scan. The rule itself lives in `DeviceNameRules`, where
    /// it can be tested without a CoreBluetooth scan.
    /// One line describing a scanned advertisement, naming **both** names it carries plus what the
    /// app is currently looking for. All three are needed to explain a match or a miss: the two
    /// names routinely disagree after a rename, and which one matched is the difference between a
    /// device being findable and not.
    private func describe(_ peripheral: CBPeripheral, _ advertisementData: [String: Any]) -> String {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let lookingFor = [rememberedDeviceName, previouslyKnownDeviceName]
            .compactMap { $0 }
            .joined(separator: "|")
        return "name=\(peripheral.name ?? "nil") advert=\(advertised ?? "nil") looking-for=\(lookingFor.isEmpty ? "nil" : lookingFor)"
    }

    private func isKnownDevice(_ peripheral: CBPeripheral, _ advertisementData: [String: Any]) -> Bool {
        DeviceNameRules.matchesKnownDevice(
            peripheralName: peripheral.name,
            advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            remembered: rememberedDeviceName,
            previouslyKnown: previouslyKnownDeviceName
        )
    }

    private func scanAndConnect() async throws {
        // Broad scan first: real hardware doesn't reliably advertise the TimeFlip service UUID
        // (confirmed via the diagnostic scan), so the OS-level service-filtered scan below would
        // just time out first. Broad scan matches on name-or-service, which actually works.
        do {
            try await performScan(filtered: false)
        } catch DeviceError.discoveryTimeout {
            logger.notice("Broad scan timed out; retrying with service-filtered scan")
            try await performScan(filtered: true)
        }
    }

    /// Starts a fresh page of the scan log. Called by both scan paths, since each
    /// `scanForPeripherals` call resets CoreBluetooth's own duplicate filter, and the log should
    /// follow the same boundary: one line per peripheral per scan.
    private func beginScanLogging() {
        loggedScanSkips.removeAll()
        loggedScanListings.removeAll()
    }

    private func performScan(filtered: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.connection = continuation
            allowBroadDiscovery = !filtered
            beginScanLogging()
            if filtered {
                logger.notice("Starting scan for TimeFlip service \(TimeFlipUUIDs.service.uuidString, privacy: .public)")
                central.scanForPeripherals(
                    withServices: [TimeFlipUUIDs.service],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            } else {
                logger.notice("Starting broad scan for TimeFlip devices (name or advertised service)")
                central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            }
            scheduleTimeout("connection") { device in
                if device.continuations.connection != nil {
                    // Nothing is connected yet at this point, so there's no peripheral to
                    // disconnect from — just stop the scan itself.
                    device.central.stopScan()
                    device.continuations.connection?.resume(throwing: DeviceError.discoveryTimeout)
                    device.continuations.connection = nil
                }
            }
        }
    }

    private func discoverServicesAndCharacteristics() async throws {
        guard let peripheral else { throw DeviceError.connectionFailed }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.services = continuation
            logger.debug("Discovering services on peripheral \(peripheral.identifier.uuidString, privacy: .public)")
            peripheral.discoverServices([
                TimeFlipUUIDs.service,
                TimeFlipUUIDs.batteryService,
                TimeFlipUUIDs.deviceInfoService
            ])
            scheduleTimeout("services") { device in
                if device.continuations.services != nil {
                    device.handleTimeout("Service discovery")
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.characteristics = continuation
            if let services = peripheral.services {
                for service in services {
                    if service.uuid == TimeFlipUUIDs.service {
                        logger.debug("Discovering TimeFlip characteristics")
                        peripheral.discoverCharacteristics(Array(requiredCharacteristicUUIDs), for: service)
                    } else if service.uuid == TimeFlipUUIDs.batteryService {
                        logger.debug("Discovering battery characteristics")
                        peripheral.discoverCharacteristics([TimeFlipUUIDs.batteryLevel], for: service)
                    } else if service.uuid == TimeFlipUUIDs.deviceInfoService {
                        logger.debug("Discovering device info characteristics")
                        peripheral.discoverCharacteristics([
                            TimeFlipUUIDs.manufacturerName,
                            TimeFlipUUIDs.modelNumber,
                            TimeFlipUUIDs.hardwareRevision,
                            TimeFlipUUIDs.firmwareRevision,
                            TimeFlipUUIDs.systemID
                        ], for: service)
                    }
                }
            } else {
                continuation.resume(throwing: DeviceError.serviceDiscoveryFailed)
            }
            scheduleTimeout("characteristics") { device in
                if device.continuations.characteristics != nil {
                    device.handleTimeout("Characteristic discovery")
                }
            }
        }
    }

    private func characteristic(for uuid: CBUUID) throws -> CBCharacteristic {
        guard let characteristic = characteristics[uuid] else {
            throw DeviceError.missingCharacteristic(uuid)
        }
        return characteristic
    }

    private func write(_ data: Data, to uuid: CBUUID, type: CBCharacteristicWriteType) async throws {
        let characteristic = try characteristic(for: uuid)
        logger.debug("Write \(data.hexString(), privacy: .public) to \(uuid.uuidString, privacy: .public)")
        DeveloperMode.debugPrint(
            .bleTx,
            "write \(TimeFlipUUIDs.name(for: uuid)) \(type == .withResponse ? "ack" : "no-ack") <- \(data.hexString())"
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if continuations.writes[uuid] != nil {
                logger.error("Write already pending for \(uuid.uuidString, privacy: .public); rejecting overlapping write")
                continuation.resume(throwing: DeviceError.writeFailed(uuid))
                return
            }
            continuations.writes[uuid] = continuation
            peripheral?.writeValue(data, for: characteristic, type: type)
            scheduleTimeout("write:\(uuid.uuidString)") { device in
                if device.continuations.writes[uuid] != nil {
                    device.handleTimeout("Write to \(uuid.uuidString)")
                }
            }
        }
    }

    private func read(_ uuid: CBUUID) async throws -> Data? {
        let characteristic = try characteristic(for: uuid)
        logger.debug("Read request for \(uuid.uuidString, privacy: .public)")
        DeveloperMode.debugPrint(.bleTx, "read request \(TimeFlipUUIDs.name(for: uuid))")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            if continuations.reads[uuid] != nil {
                logger.error("Read already pending for \(uuid.uuidString, privacy: .public); rejecting overlapping read")
                continuation.resume(throwing: DeviceError.readFailed(uuid))
                return
            }
            continuations.reads[uuid] = continuation
            peripheral?.readValue(for: characteristic)
            scheduleTimeout("read:\(uuid.uuidString)") { device in
                if device.continuations.reads[uuid] != nil {
                    device.handleTimeout("Read from \(uuid.uuidString)")
                }
            }
        }
    }

    private func readString(_ uuid: CBUUID) async throws -> String? {
        guard let data = try await read(uuid), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Perform a command-channel write followed by the mandatory commandResult read.
    private func performCommand(_ payload: Data) async throws -> Data {
        try await commandGate.withLock {
            let cmd = payload.first ?? 0
            logger.debug("Command write cmd=0x\(String(format: "%02X", cmd), privacy: .public) payload=\(payload.hexString(), privacy: .public)")
            try await write(payload, to: TimeFlipUUIDs.command, type: .withResponse)
            guard let response = try await read(TimeFlipUUIDs.commandResult) else {
                throw DeviceError.readFailed(TimeFlipUUIDs.commandResult)
            }
            logger.debug("Command result cmd=0x\(String(format: "%02X", cmd), privacy: .public) resp=\(response.hexString(), privacy: .public)")
            // Index via first/last so Data slices (nonzero startIndex) are handled correctly.
            if response.count == 2, response.first == cmd {
                let status = response.last ?? 0
                if status != 0x02 {
                    throw DeviceError.commandError(cmd: cmd, code: status)
                }
            } else if response.count == 1 {
                let status = response.first ?? 0
                if status != 0x02 {
                    throw DeviceError.commandError(cmd: cmd, code: status)
                }
            }
            return response
        }
    }

    private func streamHistory(startingFrom startEvent: UInt32) async -> [TimeFlipHistoryEntry] {
        var entries: [TimeFlipHistoryEntry] = []
        let sentinel20 = Data(repeating: 0, count: 20)
        var cursor = startEvent

        // Frame arrival times, accumulated in memory and emitted as a single line once the stream
        // ends. Deliberately not one debug_log row per frame: each row is a SQLite insert, which
        // would add its own latency to the very inter-frame gap being measured. These feed the
        // mock's `historyRead` (command round trip) and `historyPerRecord` (per-frame) ranges.
        let clock = ContinuousClock()
        var lastFrameAt = clock.now
        var frameGapsMilliseconds: [Int64] = []

        let stream = AsyncStream<Data> { continuation in
            historyStreamContinuation = continuation
        }
        defer {
            historyStreamContinuation?.finish()
            historyStreamContinuation = nil
        }

        do {
            await withNotification(TimeFlipUUIDs.history, enabled: true)

            var command = Data(repeating: 0, count: 5)
            command[0] = 0x02
            command.replaceSubrange(1..<5, with: withUnsafeBytes(of: cursor.bigEndian, Array.init))

            logger.debug("History stream request startFrom=\(cursor, privacy: .public)")
            // Reset here, not at declaration: the enable-notification hop above is a real BLE
            // round trip, and folding it into the first frame's gap would inflate the command
            // round-trip figure the mock is calibrated against.
            lastFrameAt = clock.now
            try await write(command, to: TimeFlipUUIDs.history, type: .withResponse)
        } catch {
            logger.error("History stream start failed: \(error.localizedDescription, privacy: .public)")
            await withNotification(TimeFlipUUIDs.history, enabled: false)
            return []
        }

        // Idle timeout, not a total-duration cap: a long stream that's actively receiving frames
        // never trips this: each frame received pushes the deadline back. Only silence for the
        // full timeout window (device stopped responding entirely) triggers it.
        var idleWatchdog: Task<Void, Never>?
        func resetIdleWatchdog() {
            idleWatchdog?.cancel()
            idleWatchdog = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.deviceOperationTimeoutSeconds * TimeConstants.nanosecondsPerSecond)
                guard !Task.isCancelled else { return }
                self.historyStreamContinuation?.finish()
                self.handleTimeout("History stream (no frame received)")
            }
        }
        resetIdleWatchdog()
        defer { idleWatchdog?.cancel() }

        for await frame in stream {
            resetIdleWatchdog()
            let arrivedAt = clock.now
            let gap = (arrivedAt - lastFrameAt).components
            frameGapsMilliseconds.append(gap.seconds * 1_000 + gap.attoseconds / 1_000_000_000_000_000)
            lastFrameAt = arrivedAt
            // Treat any frame with eventNumber==0 as sentinel.
            if frame.count >= 4 {
                let evNum = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if evNum == 0 {
                    logger.debug("History sentinel (eventNumber=0) reached at cursor \(cursor)")
                    break
                }
            }

            if frame == sentinel20 {
                logger.debug("History sentinel (all zero frame) reached at cursor \(cursor)")
                break
            }

            if let entry = TimeFlipHistoryParser.parse(frame) {
                let ev = entry.eventNumber ?? cursor
                logger.debug("History frame parsed ev=\(ev) face=\(entry.faceID) dur=\(entry.duration)")
                entries.append(entry)
                cursor = ev &+ 1
            } else {
                let hex = frame.hexString()
                logger.error("History frame parse failed startFrom=\(cursor, privacy: .public) len=\(frame.count, privacy: .public) hex=\(hex, privacy: .public)")
                cursor = cursor &+ 1 // avoid getting stuck on malformed frame
            }

            if entries.count >= 2048 {
                logger.warning("History stream stopped at cap 2048 entries")
                break
            }
        }

        idleWatchdog?.cancel()
        await withNotification(TimeFlipUUIDs.history, enabled: false)

        if let commandRoundTrip = frameGapsMilliseconds.first {
            // First gap is the command round trip (write acknowledged -> first frame); the rest are
            // the device's own per-frame spacing, which is what a mock streaming a backlog has to
            // reproduce. The trailing sentinel frame is included, so the list is one longer than
            // the record count.
            let perFrame = frameGapsMilliseconds.dropFirst()
            let summary = perFrame.isEmpty
                ? "none"
                : "\(perFrame.map(String.init).joined(separator: ",")) (min=\(perFrame.min() ?? 0) max=\(perFrame.max() ?? 0) mean=\(perFrame.reduce(0, +) / Int64(perFrame.count)))"
            DeveloperMode.debugPrint(
                .histTime,
                "history stream from=\(startEvent) records=\(entries.count) frames=\(frameGapsMilliseconds.count) round_trip=\(commandRoundTrip)ms per_frame_ms=\(summary)"
            )
        } else {
            DeveloperMode.debugPrint(.histTime, "history stream from=\(startEvent) received no frames")
        }

        return entries
    }

    /// Per the vendor spec, requesting event 0xFFFFFFFF via command 0x01 substitutes the real
    /// last event's complete "History block" frame (same layout a single-event read would
    /// return -- event number, face, start time, duration). Unlike 0x02, whose response is
    /// explicitly documented as "data flow with notification", 0x01's response isn't described as
    /// a notification at all -- confirmed empirically too: waiting on a notification here reliably
    /// timed out against real hardware, while an explicit read of the characteristic's value right
    /// after the write works. So this writes the command, then reads the characteristic directly,
    /// rather than waiting on historyStreamContinuation the way streamHistory does.
    private func readLastEventLocked(_ eventNumber: UInt32) async -> TimeFlipHistoryEntry? {
        var command = Data(repeating: 0, count: 5)
        command[0] = 0x01
        command.replaceSubrange(1..<5, with: withUnsafeBytes(of: eventNumber.bigEndian, Array.init))
        do {
            logger.debug("History single-event request ev=\(eventNumber, privacy: .public)")
            try await write(command, to: TimeFlipUUIDs.history, type: .withResponse)
        } catch {
            logger.error("readSingleEvent write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let data = await readHistoryValueWithoutDisconnect() else {
            logger.error("readSingleEvent timed out or failed waiting for response")
            return nil
        }
        return TimeFlipHistoryParser.parse(data)
    }

    /// Reads the history characteristic's current value directly, using its own short timeout
    /// rather than the shared read(_:) helper's -- a failure here should just fall back to the
    /// full 0x02 stream, not disconnect the whole device the way handleTimeout (triggered by
    /// read(_:)'s scheduleTimeout) does. Returns nil on any failure/timeout instead of throwing,
    /// since callers treat this as a best-effort optimization, never a required step.
    private func readHistoryValueWithoutDisconnect() async -> Data? {
        guard let characteristic = characteristics[TimeFlipUUIDs.history] else { return nil }
        guard continuations.reads[TimeFlipUUIDs.history] == nil else { return nil }
        let uuid = TimeFlipUUIDs.history

        return try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            continuations.reads[uuid] = continuation
            peripheral?.readValue(for: characteristic)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5 * TimeConstants.nanosecondsPerSecond)
                guard let self else { return }
                if let pending = self.continuations.reads.removeValue(forKey: uuid) {
                    pending.resume(throwing: DeviceError.readFailed(uuid))
                }
            }
        }
    }

    private func withNotification(_ uuid: CBUUID, enabled: Bool) async {
        guard let characteristic = characteristics[uuid] else { return }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                continuations.notification[uuid] = continuation
                peripheral?.setNotifyValue(enabled, for: characteristic)
                scheduleTimeout("notify:\(uuid.uuidString)") { device in
                    if device.continuations.notification[uuid] != nil {
                        device.handleTimeout("Set notify (\(enabled ? "on" : "off")) for \(uuid.uuidString)")
                    }
                }
            }
            logger.debug("Notify \(enabled ? "ON" : "OFF") for \(uuid.uuidString, privacy: .public)")
        } catch {
            logger.error("Notification \(enabled ? "enable" : "disable") failed for \(uuid.uuidString, privacy: .public)")
        }
    }

    private func setDeviceTime(_ date: Date) async {
        let seconds = UInt64(date.timeIntervalSince1970)
        var payload = Data(repeating: 0, count: 9)
        payload[0] = 0x08
        payload.replaceSubrange(1..<9, with: withUnsafeBytes(of: seconds.bigEndian, Array.init))
        do {
            logger.debug("Setting device time to \(seconds, privacy: .public)")
            _ = try await performCommand(payload)
            snapshotState = snapshotStateUpdating(deviceTime: date)
            // Read back for diagnostics to confirm device applied the time.
            _ = await readDeviceTime()
        } catch {
            logger.error("Failed to set device time: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setLEDBrightness(percent: UInt8) async {
        let clamped = max(1, min(100, percent))
        let payload = Data([0x09, clamped])
        do {
            logger.debug("Setting LED brightness to \(clamped, privacy: .public)%")
            DeveloperMode.debugPrint(.ledBright, "Brightness set to \(clamped)% triggered")
            _ = try await performCommand(payload)
            // No verification here -- unlike auto-pause/lock/double-tap, the protocol has no read
            // command for LED brightness (only the "sync required" flag, which just means
            // "re-push your stored value", not an actual device readback), so there's nothing to
            // read back and compare against. See docs/TimeFlip2 BLE Protocol v4.3.md's command
            // table (0x09) and system-state notify flags.
            DeveloperMode.debugPrint(.ledBright, "Brightness written to \(clamped)% (no device read-back available)")
        } catch {
            logger.error("Failed to set LED brightness: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.ledBright, "Brightness command failed: \(error.localizedDescription)")
        }
    }

    func setBlinkInterval(seconds: UInt8) async {
        let clamped = max(5, min(60, seconds))
        let payload = Data([0x0A, clamped])
        do {
            logger.debug("Setting LED blink interval to \(clamped, privacy: .public)s")
            DeveloperMode.debugPrint(.ledBlink, "Blink interval set to \(clamped)s triggered")
            _ = try await performCommand(payload)
            // Same lack of a read-back command as brightness above (0x0A has no counterpart read).
            DeveloperMode.debugPrint(.ledBlink, "Blink interval written to \(clamped)s (no device read-back available)")
        } catch {
            logger.error("Failed to set LED blink interval: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.ledBlink, "Blink interval command failed: \(error.localizedDescription)")
        }
    }

    func setDoubleTapParameters(_ params: DoubleTapParameters) async {
        let payload = Data([
            0x16,
            0x3A, params.clickThreshold,
            0x3B, params.limit,
            0x3C, params.latency,
            0x3D, params.window
        ])
        let summary = "ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)"
        do {
            logger.debug("Setting double-tap params \(summary, privacy: .public)")
            DeveloperMode.debugPrint(.doubleTap, "Writing \(summary)")
            _ = try await performCommand(payload)
            // Read back via cmd 0x17 to confirm the write actually took effect, per
            // docs/timeflip.md's "confirming a command actually took effect" guidance.
            let confirmedParams = await readDoubleTapParameters()
            let confirmed = confirmedParams == params
            let actualSummary = confirmedParams.map {
                "ths=\($0.clickThreshold) lim=\($0.limit) lat=\($0.latency) win=\($0.window)"
            } ?? "no response"
            logger.debug("Double-tap verification confirmed=\(confirmed, privacy: .public) actual=\(actualSummary, privacy: .public)")
            DeveloperMode.debugPrint(
                .doubleTap,
                "Verification \(confirmed ? "confirmed" : "MISMATCH"): requested \(summary); actual \(actualSummary)"
            )
        } catch {
            logger.error("Failed to set double-tap params: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.doubleTap, "Write failed: \(error.localizedDescription)")
        }
    }

    func readDoubleTapParameters() async -> DoubleTapParameters? {
        do {
            let response = try await performCommand(Data([0x17]))
            guard response.count >= 9, response[0] == 0x17 else {
                logger.error("Unexpected double-tap read response len=\(response.count) resp=\(response.hexString(), privacy: .public)")
                DeveloperMode.debugPrint(.doubleTap, "Unexpected read response len=\(response.count) resp=\(response.hexString())")
                return nil
            }
            let params = DoubleTapParameters(
                clickThreshold: response[2],
                limit: response[4],
                latency: response[6],
                window: response[8]
            )
            logger.debug("Read double-tap params ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)")
            DeveloperMode.debugPrint(.doubleTap, "Read ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)")
            return params
        } catch {
            logger.error("Failed to read double-tap params: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.doubleTap, "Read failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Task/pomodoro parameters and device name (0x13, 0x14, 0x15, 0xFE)
    //
    // The device runs a per-face countdown on its own and asks the host to push parameters via the
    // `taskParametersSyncRequired` system-state notification, which this driver decoded and then
    // ignored because it had no way to answer. These four commands complete the spec's command set.

    /// Sets a face's task parameters (command 0x13).
    ///
    /// Face numbers are validated against the app's own range rather than the spec's stated 0-24:
    /// the protocol document describes a 24-facet variant, while this app targets the 12-face
    /// TimeFlip2 and `TimeFlipConstants.isValidFaceID` is the single place that decision lives.
    @discardableResult
    func setFaceTaskParameters(_ params: FaceTaskParameters) async -> Bool {
        guard isLoggedIn else { return false }
        guard TimeFlipConstants.isValidFaceID(params.faceID) else {
            logger.error("setFaceTaskParameters rejected invalid face \(params.faceID, privacy: .public)")
            return false
        }
        do {
            DeveloperMode.debugPrint(
                .faceTask,
                "Face \(params.faceID) task set to mode=\(params.mode.rawValue) limit=\(params.limitSeconds)s triggered"
            )
            _ = try await performCommand(params.commandPayload())
            DeveloperMode.debugPrint(.faceTask, "Face \(params.faceID) task written")
            return true
        } catch {
            logger.error("Failed to set face task params: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.faceTask, "Face \(params.faceID) task write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reads a face's task parameters (command 0x14), including how long its timer has been running.
    func readFaceTaskParameters(faceID: UInt8) async -> FaceTaskParameters? {
        guard isLoggedIn else { return nil }
        guard TimeFlipConstants.isValidFaceID(faceID) else { return nil }
        do {
            let response = try await performCommand(Data([0x14, faceID]))
            guard let params = FaceTaskParameters.parse(response) else {
                logger.error("Unexpected 0x14 response len=\(response.count) resp=\(response.hexString(), privacy: .public)")
                DeveloperMode.debugPrint(.faceTask, "Face \(faceID) task read unexpected: \(response.hexString())")
                return nil
            }
            DeveloperMode.debugPrint(
                .faceTask,
                "Face \(faceID) task read mode=\(params.mode.rawValue) limit=\(params.limitSeconds)s elapsed=\(params.elapsedSeconds.map(String.init) ?? "nil")s"
            )
            return params
        } catch {
            logger.error("Failed to read face task params: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.faceTask, "Face \(faceID) task read failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sets the device's advertised name (command 0x15).
    ///
    /// The spec caps the name at 18 ASCII characters and puts the length in the byte after the
    /// opcode. Non-ASCII is rejected rather than lossily transcoded: the payload is a raw byte count
    /// and a multi-byte character would make the declared length disagree with the bytes sent,
    /// which is the kind of thing that bricks a name field rather than failing cleanly.
    @discardableResult
    func setDeviceName(_ name: String) async -> Bool {
        guard isLoggedIn else { return false }
        guard let ascii = name.data(using: .ascii), !ascii.isEmpty else {
            logger.error("setDeviceName rejected non-ASCII or empty name")
            DeveloperMode.debugPrint(.faceTask, "Device name rejected (non-ASCII or empty): \(name)")
            return false
        }
        guard ascii.count <= Self.maximumDeviceNameLength else {
            logger.error("setDeviceName rejected \(ascii.count, privacy: .public) chars, max \(Self.maximumDeviceNameLength, privacy: .public)")
            DeveloperMode.debugPrint(.faceTask, "Device name rejected (\(ascii.count) chars, max \(Self.maximumDeviceNameLength))")
            return false
        }
        do {
            DeveloperMode.debugPrint(.faceTask, "Device name set to '\(name)' triggered")
            _ = try await performCommand(Data([0x15, UInt8(ascii.count)]) + ascii)
            // "Written", not "accepted": the device never updates the command result characteristic
            // for 0x15, so `performCommand` returning is proof the bytes went out and nothing more.
            // Established rather than assumed -- a re-read ladder at +250ms, +500ms, +1s and +2s
            // found the previous command's response still sitting there every time, so it is not a
            // race that waiting longer would win. That ladder lives on the
            // `timeflip2-firmware-diagnosis` branch, which is where it belongs: it added four
            // seconds to every rename. See docs/timeflip2-firmware-observations.md.
            DeveloperMode.debugPrint(.faceTask, "Device name written: '\(name)'")
            return true
        } catch {
            logger.error("Failed to set device name: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.faceTask, "Device name write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Per the spec, 18 ASCII symbols maximum. Defers to `DeviceNameRules`, which the rename field
    /// also limits itself by, so the field cannot allow a name this write would then refuse.
    static let maximumDeviceNameLength = DeviceNameRules.maximumLength

    /// Resets every face's task info to default (command 0xFE).
    ///
    /// Narrower than `factoryReset`: task parameters only. History, pairing, password, colours and
    /// the device name are untouched, so unlike 0xFF this needs no reboot and no re-pair.
    @discardableResult
    func resetTaskInfoToDefault() async -> Bool {
        guard isLoggedIn else { return false }
        do {
            DeveloperMode.debugPrint(.faceTask, "Task info reset (0xFE) triggered")
            _ = try await performCommand(Data([0xFE]))
            DeveloperMode.debugPrint(.faceTask, "Task info reset (0xFE) accepted")
            return true
        } catch {
            logger.error("Failed to reset task info: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.faceTask, "Task info reset failed: \(error.localizedDescription)")
            return false
        }
    }

    func setAutoPause(minutes: UInt16) async {
        let high = UInt8(minutes >> 8)
        let low = UInt8(minutes & 0xFF)
        let payload = Data([0x05, high, low])
        do {
            logger.debug("Setting auto-pause to \(minutes, privacy: .public)m")
            DeveloperMode.debugPrint(.autoPause, "Auto-pause set to \(minutes)m triggered")
            _ = try await performCommand(payload)
            snapshotState = snapshotStateUpdating(autoPauseMinutes: minutes)
            // Read back via status (cmd 0x10) to confirm the write actually took effect, per
            // docs/timeflip.md's "confirming a command actually took effect" guidance -- same as
            // setLock's verification below. The caller (ApplicationDelegate) already debounces
            // how often this method itself gets invoked, so no additional debounce is needed here.
            await refreshStatus()
            let actual = snapshotState.autoPauseMinutes
            let confirmed = actual == minutes
            logger.debug("Auto-pause verification confirmed=\(confirmed, privacy: .public) actual=\(actual, privacy: .public)")
            DeveloperMode.debugPrint(
                .autoPause,
                "Auto-pause verification \(confirmed ? "confirmed" : "MISMATCH"): requested=\(minutes)m actual=\(actual)m"
            )
        } catch {
            logger.error("Failed to set auto-pause: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.autoPause, "Auto-pause command failed: \(error.localizedDescription)")
        }
    }

    func setPause(_ on: Bool) async {
        guard isLoggedIn else { return }
        let payload = Data([0x06, on ? 0x01 : 0x02])
        do {
            logger.debug("Setting pause \(on ? "ON" : "OFF")")
            _ = try await performCommand(payload)
            // Optimistically update snapshot for debugging/mock device support
            snapshotState = snapshotStateUpdating(isPaused: on)
            // No event emission - state will come from history
        } catch {
            logger.error("Failed to set pause: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setLock(_ on: Bool) async {
        guard isLoggedIn else { return }
        let payload = Data([0x04, on ? 0x01 : 0x02])
        do {
            logger.debug("Setting lock \(on ? "ON" : "OFF")")
            DeveloperMode.debugPrint(.timeFlip, "Lock \(on ? "ON" : "OFF") triggered")
            _ = try await performCommand(payload)
            // Read back via status (cmd 0x10) to confirm the lock actually took effect, per
            // docs/timeflip.md's "confirming a command actually took effect" guidance.
            await refreshStatus()
            let confirmed = snapshotState.isLocked == on
            logger.debug("Lock verification confirmed=\(confirmed, privacy: .public) actual=\(self.snapshotState.isLocked, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Lock verification \(confirmed ? "confirmed" : "MISMATCH"): requested=\(on ? "ON" : "OFF") actual=\(snapshotState.isLocked ? "ON" : "OFF")")
        } catch {
            logger.error("Failed to set lock: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Lock command failed: \(error.localizedDescription)")
        }
    }

    func refreshLockState() async -> Bool {
        await refreshStatus()
        return snapshotState.isLocked
    }

    func refreshDeviceInfo() async {
        do {
            let manufacturer = try await readString(TimeFlipUUIDs.manufacturerName)
            let model = try await readString(TimeFlipUUIDs.modelNumber)
            let hardware = try await readString(TimeFlipUUIDs.hardwareRevision)
            let firmware = try await readString(TimeFlipUUIDs.firmwareRevision)
            // Unlike the other Device Information characteristics above, System ID (0x2A23) is a
            // standard Bluetooth SIG characteristic defined as raw binary -- a 5-byte
            // manufacturer-assigned ID + 3-byte IEEE OUI, not UTF-8 text -- so it's hex-encoded
            // here instead of decoded with readString(), which would produce garbage.
            let systemID = try await read(TimeFlipUUIDs.systemID)?.hexString(separator: ":")
            let info = TimeFlipDeviceInfo(
                manufacturer: manufacturer,
                modelNumber: model,
                hardwareRevision: hardware,
                firmwareRevision: firmware,
                systemID: systemID
            )
            snapshotState = snapshotStateUpdating(deviceInfo: info)
            emit(.deviceInfo(info))
        } catch {
            logger.error("Device info read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshStatus() async {
        do {
            let command = Data([0x10])
            logger.debug("Refreshing status via command 0x10")
            let data = try await performCommand(command)
            guard data.count >= 4 else {
                logger.error("Status read returned insufficient data")
                return
            }
            let locked = data[0] == 0x01
            let paused = locked ? true : data[1] == 0x01
            let autoPause = UInt16(data[2]) << 8 | UInt16(data[3])
            logger.debug("Status locked=\(locked, privacy: .public) paused=\(paused, privacy: .public) autoPause=\(autoPause, privacy: .public)m")
            snapshotState = snapshotStateUpdating(
                isPaused: paused,
                isLocked: locked,
                autoPauseMinutes: autoPause
            )
            emit(.autoPauseMinutes(autoPause))
            emit(.lockChanged(locked))

            // Pull system state alongside status so we can validate health immediately.
            _ = await readSystemState(context: "status refresh")
        } catch {
            logger.error("Status refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func primeSnapshot() async {
        do {
            _ = await readSystemState(context: "prime snapshot", emitEvent: false)
            if let faceData = try await read(TimeFlipUUIDs.faces)?.first {
                snapshotState = snapshotStateUpdating(faceID: faceData)
                logger.debug("Initial face \(faceData)")
                emit(.faceChanged(faceID: faceData))
            }
            if let battery = try await read(TimeFlipUUIDs.batteryLevel)?.first {
                snapshotState = snapshotStateUpdating(batteryLevel: battery)
                logger.debug("Initial battery \(battery)")
                emit(.batteryLevel(battery))
            }
        } catch {
            logger.error("Failed to prime snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func readSystemState(context: String, emitEvent: Bool = true, reconcile: Bool = true) async -> TimeFlipSystemState? {
        do {
            guard let data = try await read(TimeFlipUUIDs.systemState) else {
                logger.error("System state read returned nil [\(context)]")
                return nil
            }
            let system = handleSystemStatePayload(data, context: context, emitEvent: emitEvent)
            if reconcile, let system {
                return await reconcileSystemState(system, context: context, emitEvent: emitEvent)
            }
            return system
        } catch {
            logger.error("System state read failed [\(context)]: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    private func handleSystemStatePayload(_ data: Data, context: String, emitEvent: Bool = true) -> TimeFlipSystemState? {
        guard data.count >= 4 else {
            logger.error("System state payload too short [\(context)] len=\(data.count) raw=\(data.hexString(), privacy: .public)")
            return nil
        }
        let status = UInt16(data[0]) << 8 | UInt16(data[1])
        let hardware = UInt16(data[2]) << 8 | UInt16(data[3])
        let system = TimeFlipSystemState(rawStatus: status, rawHardware: hardware)
        let hex = data.hexString()
        let statusHex = String(format: "%04X", Int(status))
        let hardwareHex = String(format: "%04X", Int(hardware))
        logger.notice("SystemState[\(context, privacy: .public)] raw=\(hex, privacy: .public) status=0x\(statusHex, privacy: .public) hw=0x\(hardwareHex, privacy: .public) sync=\(system.syncStatus, privacy: .public) hwStatus=\(system.hardwareStatus, privacy: .public)")
        if system.syncStatus != .ok || system.hardwareStatus != .ok {
            logger.error("SystemState not OK [\(context, privacy: .public)] sync=\(system.syncStatus, privacy: .public) hw=\(system.hardwareStatus, privacy: .public)")
        }
        snapshotState = snapshotStateUpdating(systemState: system)
        if emitEvent {
            emit(.systemState(system))
        }
        return system
    }

    @discardableResult
    private func reconcileSystemState(_ system: TimeFlipSystemState, context: String, emitEvent: Bool) async -> TimeFlipSystemState? {
        switch system.syncStatus {
        case .ok:
            return system
        case .timeSyncRequired:
            await setDeviceTime(Date())
        case .autoPauseSyncRequired:
            await setAutoPause(minutes: snapshotState.autoPauseMinutes)
        case .ledBrightnessSyncRequired:
            await setLEDBrightness(percent: defaultLEDBrightness)
        case .blinkIntervalSyncRequired:
            await setBlinkInterval(seconds: defaultBlinkIntervalSeconds)
        case .faceColorSyncRequired:
            // Answered a layer up: the colours come from the DB (face -> category -> colour), which
            // this driver has no access to, so ApplicationDelegate handles the emitted
            // .systemState event and re-sends all 12 faces.
            logger.notice("SystemState \(system.syncStatus) deferred to app-level face colour resync [\(context, privacy: .public)]")
        case .factoryReset, .taskParametersSyncRequired, .unknown:
            // We can't automatically restore task params without persisted data; surface via logs.
            logger.warning("SystemState \(system.syncStatus) needs manual sync [\(context, privacy: .public)]")
        }

        // Re-read once after attempting reconciliation to validate state.
        return await readSystemState(context: "\(context) post-reconcile", emitEvent: emitEvent, reconcile: false)
    }

    private func snapshotStateUpdating(
        faceID: UInt8? = nil,
        isPaused: Bool? = nil,
        isLocked: Bool? = nil,
        autoPauseMinutes: UInt16? = nil,
        batteryLevel: UInt8? = nil,
        systemState: TimeFlipSystemState? = nil,
        deviceTime: Date? = nil,
        deviceInfo: TimeFlipDeviceInfo? = nil
    ) -> TimeFlipDeviceSnapshot {
        TimeFlipDeviceSnapshot(
            faceID: faceID ?? snapshotState.faceID,
            isPaused: isPaused ?? snapshotState.isPaused,
            isLocked: isLocked ?? snapshotState.isLocked,
            autoPauseMinutes: autoPauseMinutes ?? snapshotState.autoPauseMinutes,
            batteryLevel: batteryLevel ?? snapshotState.batteryLevel,
            systemState: systemState ?? snapshotState.systemState,
            deviceTime: deviceTime ?? Date(),
            deviceInfo: deviceInfo ?? snapshotState.deviceInfo
        )
    }

    private func emit(_ event: TimeFlipEvent) {
        continuation?.yield(event)
        switch event {
        case .faceChanged, .doubleTap:
            // Don't update snapshot from events - history is source of truth
            break
        case .autoPauseMinutes(let minutes):
            snapshotState = snapshotStateUpdating(autoPauseMinutes: minutes)
        case .batteryLevel(let level):
            snapshotState = snapshotStateUpdating(batteryLevel: level)
        case .systemState(let state):
            snapshotState = snapshotStateUpdating(systemState: state)
        case .deviceInfo(let info):
            snapshotState = snapshotStateUpdating(deviceInfo: info)
        case .eventLog:
            break
        case .lockChanged(let locked):
            snapshotState = snapshotStateUpdating(isLocked: locked)
        }
        logger.debug("event \(event.description, privacy: .public)")
    }
}

// MARK: - CBCentralManagerDelegate

@MainActor
extension TimeFlipBLEDevice: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        logger.debug("Central state updated: \(state.rawValue, privacy: .public)")
        switch state {
        case .poweredOn:
            continuations.poweredOn?.resume(returning: ())
            continuations.poweredOn = nil
        case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
            continuations.poweredOn?.resume(throwing: DeviceError.bluetoothUnavailable)
            continuations.poweredOn = nil
        @unknown default:
            continuations.poweredOn?.resume(throwing: DeviceError.bluetoothUnavailable)
            continuations.poweredOn = nil
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        _ = RSSI
        logger.notice("Discovered peripheral \(peripheral.identifier.uuidString, privacy: .public) name=\(peripheral.name ?? "nil", privacy: .public) adv=\(advertisementData)")

        let advertisedServices = (
            advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        ) + (
            advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        ) + (
            advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
        )
        let serviceMatches = advertisedServices.contains(TimeFlipUUIDs.service)

        if isDiscoveryScanning {
            if discoveryFilterToTimeFlip {
                // The service UUID isn't reliably present in this device's advertisement packet,
                // so fall back to matching on the names too. See `isKnownDevice` for why both are
                // checked, and why this branch checking only one of them was a real bug.
                guard serviceMatches || isKnownDevice(peripheral, advertisementData) else {
                    logger.debug("Discovery scan: skipping peripheral \(peripheral.identifier.uuidString, privacy: .public) (no service/name match)")
                    if loggedScanSkips.insert(peripheral.identifier).inserted {
                        DeveloperMode.debugPrint(.scan, "skipped: \(describe(peripheral, advertisementData))")
                    }
                    return
                }
            }
            // Both names, always, because the scan list is exactly where they disagree: the label
            // comes from `peripheral.name`, which lags a connection behind a rename, while the
            // advertised name never changes at all. A list showing a name the user did not choose
            // is explicable from this line and guesswork without it.
            if loggedScanListings.insert(peripheral.identifier).inserted {
                DeveloperMode.debugPrint(
                    .scan,
                    "listed: \(describe(peripheral, advertisementData))\(serviceMatches ? " serviceMatch" : "")"
                )
            }
            discoveredPeripherals[peripheral.identifier] = peripheral
            // Collected either way; only announced when a person asked for a device list.
            guard !isCollectingEligibleOnly else { return }
            // `peripheral.name` first: it is the name the user actually set, even when the cache is
            // a connection behind. The advertised name is a fallback rather than the primary,
            // because on this hardware it never changes, so preferring it would show every renamed
            // cube as "TimeFlip v2.0".
            onDeviceDiscovered?(
                DiscoveredBLEDevice(
                    id: peripheral.identifier,
                    name: peripheral.name
                        ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                        ?? "Unknown Device"
                )
            )
            return
        }

        if allowBroadDiscovery {
            // Service UUID isn't reliably advertised by real hardware (confirmed via the
            // diagnostic scan), so also accept a name match to actually find the device.
            //
            // Both names are checked, and the advertised one is the load-bearing half. A rename
            // (0x15) changes the GAP Device Name that `peripheral.name` reflects, but this hardware
            // goes on advertising `TimeFlip v2.0` in its packet regardless -- measured live on
            // 2026-08-01, where a cube whose `peripheral.name` read "Hazza cuber" was still
            // advertising "TimeFlip v2.0". Matching only `peripheral.name` is therefore what made a
            // renamed cube undiscoverable.
            guard serviceMatches || isKnownDevice(peripheral, advertisementData) else {
                logger.debug("Skipping peripheral \(peripheral.identifier.uuidString, privacy: .public) (no service/name match)")
                if loggedScanSkips.insert(peripheral.identifier).inserted {
                    DeveloperMode.debugPrint(.scan, "connect scan skipped: \(describe(peripheral, advertisementData))")
                }
                return
            }
        }
        DeveloperMode.debugPrint(.scan, "connect scan matched: \(describe(peripheral, advertisementData))")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let probe = activeProbe, peripheral === probe.peripheral {
            logger.notice("Probe connected to \(peripheral.identifier.uuidString, privacy: .public)")
            probe.connection?.resume(returning: ())
            probe.connection = nil
            return
        }
        logger.notice("Connected to TimeFlip \(peripheral.identifier.uuidString, privacy: .public)")
        cancelTimeout("connection")
        continuations.connection?.resume(returning: ())
        continuations.connection = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        if let probe = activeProbe, peripheral === probe.peripheral {
            logger.error("Probe failed to connect: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            probe.connection?.resume(throwing: DeviceError.connectionFailed)
            probe.connection = nil
            return
        }
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        cancelTimeout("connection")
        continuations.connection?.resume(throwing: DeviceError.connectionFailed)
        continuations.connection = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if let probe = activeProbe, peripheral === probe.peripheral {
            logger.notice("Probe peripheral disconnected: \(error?.localizedDescription ?? "none", privacy: .public)")
            probe.connection?.resume(throwing: DeviceError.connectionFailed)
            probe.connection = nil
            return
        }
        handleMainDisconnect(error: error)
    }

    /// The actual disconnect-cleanup logic for the active (non-probe) session, split out from
    /// the delegate callback above so it can be exercised directly in tests — CoreBluetooth's
    /// `CBPeripheral` has no accessible initializer outside the framework's own factories, so
    /// this method deliberately doesn't need one: it tears down state unconditionally regardless
    /// of which peripheral disconnected.
    func handleMainDisconnect(error: Error?) {
        logger.warning("Disconnected from TimeFlip: \(error?.localizedDescription ?? "none", privacy: .public)")
        failAllPendingContinuations(with: error ?? DeviceError.connectionFailed)
        historyStreamContinuation?.finish()
        historyStreamContinuation = nil
        isLoggedIn = false
        characteristics.removeAll()
        self.peripheral = nil
        onDisconnect?()
    }
}

// MARK: - CBPeripheralDelegate

@MainActor
extension TimeFlipBLEDevice: @preconcurrency CBPeripheralDelegate {
    /// CoreBluetooth telling us the peripheral's GAP name changed underneath us.
    ///
    /// The only authoritative confirmation available that a `0x15` write took effect. Reading
    /// `CBPeripheral.name` straight after the write cannot do it: that value is cached and refreshes
    /// only on the next connection, so immediately after a rename it still reports the previous
    /// name (measured 2026-08-01).
    ///
    /// **This does fire on the real hardware**, about two seconds into the connection *after* a
    /// rename, once CoreBluetooth has re-read GAP and seen the difference. Observed on all three of
    /// three renames on 2026-08-01. It cannot fire during the connection the rename happened on,
    /// which is why a 30-second poll in that session saw nothing and briefly suggested it never
    /// fired at all.
    ///
    /// That timing makes it load-bearing rather than decorative: a first pairing adopts whatever
    /// name the peripheral reports, which is the stale cached one, and this is what corrects it.
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        logger.notice("Peripheral name updated to \(peripheral.name ?? "nil", privacy: .public)")
        DeveloperMode.debugPrint(.deviceName, "device reported a new name: \(peripheral.name ?? "nil")")
        onDeviceNameChanged?(peripheral.name)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let probe = activeProbe, peripheral === probe.peripheral {
            if let error {
                logger.error("Probe service discovery failed: \(error.localizedDescription, privacy: .public)")
                probe.services?.resume(throwing: DeviceError.serviceDiscoveryFailed)
            } else {
                probe.services?.resume(returning: ())
            }
            probe.services = nil
            return
        }
        cancelTimeout("services")
        if let error {
            logger.error("Service discovery failed: \(error.localizedDescription, privacy: .public)")
            continuations.services?.resume(throwing: DeviceError.serviceDiscoveryFailed)
        } else {
            logger.debug("Services discovered: \(String(describing: peripheral.services?.map { $0.uuid.uuidString }))")
            continuations.services?.resume(returning: ())
        }
        continuations.services = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        // Names every characteristic the cube actually exposes, including any this app never
        // touches -- the inventory that says what traffic is even possible, alongside the traffic
        // itself. An unnamed UUID here is one the vendor spec should be checked for.
        DeveloperMode.debugPrint(
            .bleRx,
            "characteristics on \(TimeFlipUUIDs.name(for: service.uuid)): "
                + ((service.characteristics ?? []).map { TimeFlipUUIDs.name(for: $0.uuid) }.joined(separator: ", "))
                + (error.map { " ERROR \($0.localizedDescription)" } ?? "")
        )
        if let probe = activeProbe, peripheral === probe.peripheral {
            if let chars = service.characteristics {
                for characteristic in chars {
                    probe.characteristics[characteristic.uuid] = characteristic
                }
            }
            if let error {
                logger.error("Probe characteristic discovery failed: \(error.localizedDescription, privacy: .public)")
                probe.characteristicsContinuation?.resume(throwing: DeviceError.serviceDiscoveryFailed)
                probe.characteristicsContinuation = nil
            } else if probe.characteristics[TimeFlipUUIDs.password] != nil,
                      probe.characteristics[TimeFlipUUIDs.commandResult] != nil {
                probe.characteristicsContinuation?.resume(returning: ())
                probe.characteristicsContinuation = nil
            }
            return
        }
        if let chars = service.characteristics {
            for characteristic in chars {
                characteristics[characteristic.uuid] = characteristic
            }
            let ids = chars.map { $0.uuid.uuidString }.joined(separator: ",")
            logger.debug("Discovered chars for service \(service.uuid.uuidString, privacy: .public): \(ids, privacy: .public)")
        }
        let haveAll = requiredCharacteristicUUIDs.allSatisfy { characteristics[$0] != nil }
        if let error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription, privacy: .public)")
            cancelTimeout("characteristics")
            continuations.characteristics?.resume(throwing: DeviceError.serviceDiscoveryFailed)
            continuations.characteristics = nil
        } else if haveAll {
            cancelTimeout("characteristics")
            continuations.characteristics?.resume(returning: ())
            continuations.characteristics = nil
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        // Logged here, at the top, before the probe branch and before any dispatch below: this is
        // the single point every inbound byte passes through, so anything the app has no handler
        // for is still recorded rather than silently dropped a few lines further down.
        let isProbe = activeProbe.map { peripheral === $0.peripheral } ?? false
        DeveloperMode.debugPrint(
            .bleRx,
            "\(TimeFlipUUIDs.name(for: uuid)) -> \(characteristic.value?.hexString() ?? "nil")"
                + (isProbe ? " (probe)" : "")
                + (error.map { " ERROR \($0.localizedDescription)" } ?? "")
        )
        if let probe = activeProbe, peripheral === probe.peripheral {
            if let continuation = probe.reads.removeValue(forKey: uuid) {
                if error != nil {
                    continuation.resume(throwing: DeviceError.readFailed(uuid))
                } else {
                    continuation.resume(returning: characteristic.value ?? Data())
                }
            }
            return
        }
        let valueHex = characteristic.value?.hexString() ?? "nil"
        logger.debug("didUpdateValue uuid=\(uuid.uuidString, privacy: .public) value=\(valueHex, privacy: .public) err=\(String(describing: error))")
        if let continuation = continuations.reads.removeValue(forKey: uuid) {
            cancelTimeout("read:\(uuid.uuidString)")
            if error != nil {
                continuation.resume(throwing: DeviceError.readFailed(uuid))
            } else {
                continuation.resume(returning: characteristic.value ?? Data())
            }
            return
        }
        guard error == nil, let data = characteristic.value else { return }
        switch uuid {
        case TimeFlipUUIDs.faces:
            guard let face = data.first else { return }
            emit(.faceChanged(faceID: face))
        case TimeFlipUUIDs.doubleTap:
            guard let raw = data.first else { return }
            emit(.doubleTap(TimeFlipDoubleTapPayload(rawValue: raw)))
        case TimeFlipUUIDs.systemState:
            if let system = handleSystemStatePayload(data, context: "notification") {
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.reconcileSystemState(system, context: "notification", emitEvent: true)
                }
            }
        case TimeFlipUUIDs.history:
            if let continuation = historyStreamContinuation {
                continuation.yield(data)
            } else {
                logger.debug("History frame dropped (no active stream) len=\(data.count, privacy: .public) hex=\(data.hexString(), privacy: .public)")
            }
        case TimeFlipUUIDs.eventsData:
            if let message = String(data: data, encoding: .utf8) {
                emit(.eventLog(message))
            }
        case TimeFlipUUIDs.batteryLevel:
            if let level = data.first {
                emit(.batteryLevel(level))
            }
        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        // The device's acknowledgement of a write. Logged for the same reason as the inbound values
        // above: it is traffic, and a write that is never acked looks identical to one that was
        // until the timeout fires.
        DeveloperMode.debugPrint(
            .bleRx,
            "write ack \(TimeFlipUUIDs.name(for: uuid))"
                + (error.map { " ERROR \($0.localizedDescription)" } ?? "")
        )
        if let probe = activeProbe, peripheral === probe.peripheral {
            if let continuation = probe.writes.removeValue(forKey: uuid) {
                if error != nil {
                    continuation.resume(throwing: DeviceError.writeFailed(uuid))
                } else {
                    continuation.resume(returning: ())
                }
            }
            return
        }
        logger.debug("didWriteValue uuid=\(uuid.uuidString, privacy: .public) err=\(String(describing: error))")
        if let continuation = continuations.writes.removeValue(forKey: uuid) {
            cancelTimeout("write:\(uuid.uuidString)")
            if let error {
                logger.error("Write failed \(uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continuation.resume(throwing: DeviceError.writeFailed(uuid))
            } else {
                continuation.resume(returning: ())
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        logger.debug("didUpdateNotificationState uuid=\(uuid.uuidString, privacy: .public) notifying=\(characteristic.isNotifying) err=\(String(describing: error))")
        DeveloperMode.debugPrint(
            .bleRx,
            "notify \(characteristic.isNotifying ? "on" : "off") \(TimeFlipUUIDs.name(for: uuid))"
                + (error.map { " ERROR \($0.localizedDescription)" } ?? "")
        )
        if let continuation = continuations.notification.removeValue(forKey: uuid) {
            cancelTimeout("notify:\(uuid.uuidString)")
            if error != nil {
                continuation.resume(throwing: DeviceError.writeFailed(uuid))
            } else {
                continuation.resume(returning: ())
            }
        }
    }
}

// MARK: - Async helpers

/// Minimal async gate to serialize critical BLE operations (one-at-a-time).
@MainActor
final class AsyncGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await wait()
        defer { signal() }
        return try await operation()
    }

    private func wait() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func signal() {
        if let continuation = waiters.first {
            waiters.removeFirst()
            continuation.resume()
        } else {
            locked = false
        }
    }
}

private extension Data {
    /// Render as uppercase hex bytes, space-separated by default.
    func hexString(separator: String = " ") -> String {
        map { String(format: "%02X", $0) }.joined(separator: separator)
    }
}

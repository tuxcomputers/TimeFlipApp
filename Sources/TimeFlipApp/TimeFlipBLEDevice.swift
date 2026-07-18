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
    // When true we accept peripherals that advertise the TimeFlip service or name.
    private var allowBroadDiscovery = false
    // When true, discovered peripherals are only reported via onDeviceDiscovered, never connected to.
    private var isDiscoveryScanning = false
    private var discoveryFilterToTimeFlip = true
    // The single timeout used for every BLE communication with the device (scanning, connecting,
    // service/characteristic discovery, notifications, writes, reads). On timeout, whatever step
    // was in flight is aborted and the peripheral is force-disconnected — see handleTimeout(_:).
    private let deviceOperationTimeoutSeconds: UInt64
    // Peripherals seen during a discovery scan, keyed by identifier, so a user-selected entry
    // can be connected to directly rather than re-scanning and grabbing the first match.
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    var onDisconnect: (() -> Void)?
    var onDeviceDiscovered: ((DiscoveredBLEDevice) -> Void)?
    var onDiscoveryScanStopped: (() -> Void)?
    private var snapshotState = TimeFlipDeviceSnapshot(
        facetID: TimeFlipConstants.unassignedFacetID,
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
        TimeFlipUUIDs.facets,
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
        onDiscoveryScanStopped?()
    }

    func connect() async -> Bool {
        do {
            logger.notice("connect() begin")
            stopDiscoveryScan()
            try await waitForBluetoothPower()
            try await scanAndConnect()
            try await discoverServicesAndCharacteristics()
            logger.notice("connect() completed")
            return true
        } catch {
            logger.error("BLE connect failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
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
        try await probeWrite(passwordData, to: TimeFlipUUIDs.password, probe: probe)
        guard let response = try await probeRead(TimeFlipUUIDs.commandResult, probe: probe) else {
            return false
        }
        let code = response.first ?? 0
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
        let timeoutSeconds = deviceOperationTimeoutSeconds
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
        logger.debug("Writing password to device (pwd=\(password, privacy: .private))")
        DeveloperMode.debugPrint(.timeFlip, "Writing password to device: \(passwordData.hexString())")
        try await write(passwordData, to: TimeFlipUUIDs.password, type: .withResponse)
        DeveloperMode.debugPrint(.timeFlip, "Password write acknowledged; reading commandResult…")
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
            logger.error("TimeFlip login rejected code=\(code)")
            DeveloperMode.debugPrint(.timeFlip, String(format: "Login rejected, code=0x%02X", code))
            return false
        }
    }

    func enableNotifications() async {
        logger.debug("Enabling notifications for facets/doubleTap/system/events/battery")
        await withNotification(TimeFlipUUIDs.facets, enabled: true)
        await withNotification(TimeFlipUUIDs.doubleTap, enabled: true)
        await withNotification(TimeFlipUUIDs.systemState, enabled: true)
        await withNotification(TimeFlipUUIDs.eventsData, enabled: true)
        await withNotification(TimeFlipUUIDs.batteryLevel, enabled: true)
        logger.notice("Notification subscriptions set")
    }

    func initializeSession(hostTime: Date, desiredAutoPauseMinutes: UInt16) async {
        guard isLoggedIn else { return }
        logger.notice("Initializing session with hostTime \(hostTime.timeIntervalSince1970, privacy: .public)")
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
    }

    func setFacetColor(facetID: UInt8, components: ColorComponents) async {
        guard isLoggedIn else { return }
        guard TimeFlipConstants.isValidFacetID(facetID) else { return }
        let r = UInt16(max(0, min(65535, Int(components.red * 65535))))
        let g = UInt16(max(0, min(65535, Int(components.green * 65535))))
        let b = UInt16(max(0, min(65535, Int(components.blue * 65535))))
        var payload = Data(repeating: 0, count: 8)
        payload[0] = 0x11
        payload[1] = facetID
        payload[2] = UInt8(r >> 8); payload[3] = UInt8(r & 0xFF)
        payload[4] = UInt8(g >> 8); payload[5] = UInt8(g & 0xFF)
        payload[6] = UInt8(b >> 8); payload[7] = UInt8(b & 0xFF)
        do {
            logger.debug("Setting color facet=\(facetID, privacy: .public) r=\(r) g=\(g) b=\(b)")
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to set color facet=\(facetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Emulates the official app's apparent behavior of setting a private device password on
    /// connect (command 0x30), so a stranger with the default PIN can't pair with this device.
    /// The generated password is also printed so it's recoverable from the terminal if something
    /// goes wrong with saving/using it.
    ///
    /// The new password is only returned (and therefore only saved by the caller) once the
    /// device has actually confirmed it via a real re-login attempt — the set-password command's
    /// own ack isn't treated as sufficient proof the device will honor it on the next connect.
    func rotateDevicePassword() async -> String? {
        guard isLoggedIn else { return nil }
        let generatedRandomPassword = String(format: "%06d", Int.random(in: 0...999_999))
        DeveloperMode.debugPrint(.timeFlip, "Generated random device password: \(generatedRandomPassword)")
        let payload = Data([0x30]) + Data(generatedRandomPassword.utf8)
        do {
            _ = try await performCommand(payload)
        } catch {
            logger.error("Set-password command failed: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to set new device password: \(error.localizedDescription)")
            return nil
        }
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
        return generatedRandomPassword
    }

    /// Sets the device password back to the factory default before "Forget Device" clears our
    /// own pairing state, so the device isn't left behind on a private password nobody has.
    /// Returns true only once the reset is confirmed via a real re-login with the default
    /// password — the caller should not clear its stored password unless this returns true.
    @discardableResult
    func resetDevicePasswordToDefault() async -> Bool {
        guard isLoggedIn else { return false }
        let payload = Data([0x30]) + Data(TimeFlipConstants.defaultPassword.utf8)
        do {
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to reset device password to default: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to reset device password to default: \(error.localizedDescription)")
            return false
        }
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
        return true
    }

    /// Full factory reset (command 0xFF): erases all flash-stored data on the device -- facet
    /// colors, task/pomodoro parameters, name, password, everything -- back to factory settings.
    /// Per the vendor spec this is the same command the official app's "Disconnect TimeFlip"
    /// button triggers, which implies the device may drop the BLE connection or reboot afterward;
    /// that behavior isn't documented and hasn't been verified live yet, so the confirmation
    /// re-login below may simply fail with a connection error rather than a clean "wrong
    /// password" rejection in that case -- either way, this only returns true once the reset is
    /// confirmed via a real re-login with the factory default password, same guarantee as
    /// `resetDevicePasswordToDefault()`. The caller must not clear pairing state unless this
    /// returns true.
    @discardableResult
    func factoryReset() async -> Bool {
        guard isLoggedIn else { return false }
        let payload = Data([0xFF])
        do {
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to factory reset device: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to factory reset device: \(error.localizedDescription)")
            return false
        }
        do {
            guard try await attemptLogin(with: TimeFlipConstants.defaultPassword) else {
                logger.error("Device rejected re-login with default password after factory reset; reset not confirmed")
                DeveloperMode.debugPrint(.timeFlip, "Factory reset NOT confirmed — device did not accept default password")
                return false
            }
        } catch {
            logger.error("Failed to confirm factory reset: \(error.localizedDescription, privacy: .public)")
            DeveloperMode.debugPrint(.timeFlip, "Failed to confirm factory reset (device may have disconnected): \(error.localizedDescription)")
            return false
        }
        logger.notice("Device factory reset and confirmed")
        DeveloperMode.debugPrint(.timeFlip, "Device factory reset confirmed, password back to default: \(TimeFlipConstants.defaultPassword)")
        return true
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
                DeveloperMode.debugPrint(.history, "history gap NOT recovered ev=\(candidate)")
                continue
            }
            guard recovered.duration >= Self.minimumStreamedIntervalSeconds else {
                logger.notice("History gap explained ev=\(candidate, privacy: .public) dur=\(recovered.duration, privacy: .public) (under 5s, device's own filter)")
                DeveloperMode.debugPrint(.history, "history gap explained: ev=\(candidate) dur=\(recovered.duration)s under 5s, device's own filter")
                continue
            }
            filled.append(recovered)
            recoveredAny = true
            logger.notice("History gap recovered ev=\(candidate, privacy: .public)")
            DeveloperMode.debugPrint(.history, "history gap recovered ev=\(candidate)")
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

    private func performScan(filtered: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.connection = continuation
            allowBroadDiscovery = !filtered
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
                logger.debug("History frame parsed ev=\(ev) facet=\(entry.facetID) dur=\(entry.duration)")
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
        return entries
    }

    /// Per the vendor spec, requesting event 0xFFFFFFFF via command 0x01 substitutes the real
    /// last event's complete "History block" frame (same layout a single-event read would
    /// return -- event number, facet, start time, duration). Unlike 0x02, whose response is
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
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to set LED brightness: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setBlinkInterval(seconds: UInt8) async {
        let clamped = max(5, min(60, seconds))
        let payload = Data([0x0A, clamped])
        do {
            logger.debug("Setting LED blink interval to \(clamped, privacy: .public)s")
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to set LED blink interval: \(error.localizedDescription, privacy: .public)")
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

    func setAutoPause(minutes: UInt16) async {
        let high = UInt8(minutes >> 8)
        let low = UInt8(minutes & 0xFF)
        let payload = Data([0x05, high, low])
        do {
            logger.debug("Setting auto-pause to \(minutes, privacy: .public)m")
            _ = try await performCommand(payload)
            snapshotState = snapshotStateUpdating(autoPauseMinutes: minutes)
        } catch {
            logger.error("Failed to set auto-pause: \(error.localizedDescription, privacy: .public)")
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
            if let facetData = try await read(TimeFlipUUIDs.facets)?.first {
                snapshotState = snapshotStateUpdating(facetID: facetData)
                logger.debug("Initial facet \(facetData)")
                emit(.facetChanged(facetID: facetData))
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
        case .factoryReset, .facetColorSyncRequired, .taskParametersSyncRequired, .unknown:
            // We can't automatically restore facet colors/task params without persisted data; surface via logs.
            logger.warning("SystemState \(system.syncStatus) needs manual sync [\(context, privacy: .public)]")
        }

        // Re-read once after attempting reconciliation to validate state.
        return await readSystemState(context: "\(context) post-reconcile", emitEvent: emitEvent, reconcile: false)
    }

    private func snapshotStateUpdating(
        facetID: UInt8? = nil,
        isPaused: Bool? = nil,
        isLocked: Bool? = nil,
        autoPauseMinutes: UInt16? = nil,
        batteryLevel: UInt8? = nil,
        systemState: TimeFlipSystemState? = nil,
        deviceTime: Date? = nil,
        deviceInfo: TimeFlipDeviceInfo? = nil
    ) -> TimeFlipDeviceSnapshot {
        TimeFlipDeviceSnapshot(
            facetID: facetID ?? snapshotState.facetID,
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
        case .facetChanged, .doubleTap:
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
                // so fall back to matching on the (now-confirmed-reliable) advertised name too.
                let nameMatches = (peripheral.name ?? "").lowercased().contains("timeflip")
                guard serviceMatches || nameMatches else {
                    logger.debug("Discovery scan: skipping peripheral \(peripheral.identifier.uuidString, privacy: .public) (no service/name match)")
                    return
                }
            }
            discoveredPeripherals[peripheral.identifier] = peripheral
            onDeviceDiscovered?(
                DiscoveredBLEDevice(id: peripheral.identifier, name: peripheral.name ?? "Unknown Device")
            )
            return
        }

        if allowBroadDiscovery {
            // Service UUID isn't reliably advertised by real hardware (confirmed via the
            // diagnostic scan), so also accept a name match to actually find the device.
            let nameMatches = (peripheral.name ?? "").lowercased().contains("timeflip")
            guard serviceMatches || nameMatches else {
                logger.debug("Skipping peripheral \(peripheral.identifier.uuidString, privacy: .public) (no service/name match)")
                return
            }
        }
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
        case TimeFlipUUIDs.facets:
            guard let facet = data.first else { return }
            emit(.facetChanged(facetID: facet))
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

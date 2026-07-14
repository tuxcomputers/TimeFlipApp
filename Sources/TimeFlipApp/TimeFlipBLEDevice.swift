@preconcurrency import CoreBluetooth
import Foundation
import OSLog

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

    private let central: CentralManaging
    private var peripheral: PeripheralManaging?
    private var continuations = Continuations()
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var stream: AsyncStream<TimeFlipEvent>?
    private var continuation: AsyncStream<TimeFlipEvent>.Continuation?
    private var isLoggedIn = false
    // When true we accept peripherals that advertise the TimeFlip service or name.
    private var allowBroadDiscovery = false
    var onDisconnect: (() -> Void)?
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
    private let discoveryTimeoutSeconds: UInt64 = 12
    private let fallbackTimeoutSeconds: UInt64 = 12
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
        logger: Logger = Logger(subsystem: AppIdentifiers.subsystem, category: "ble-device")
    ) {
        self.central = central ?? CBCentralManager()
        self.logger = logger
        super.init()
        self.central.delegate = self
    }

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
        if let peripheral = peripheral as? CBPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central.stopScan()
        if let connection = continuations.connection {
            connection.resume(throwing: DeviceError.connectionFailed)
            continuations.connection = nil
        }
        continuation?.finish()
        continuation = nil
        stream = nil
        logger.notice("TimeFlipBLEDevice stopped")
    }

    func connect() async -> Bool {
        do {
            logger.notice("connect() begin")
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

    func disconnect() async {
        stop()
    }

    func login(password: String) async -> Bool {
        guard password.count == 6 else {
            logger.error("Password must be 6 characters")
            return false
        }
        do {
            if try await attemptLogin(with: password) {
                return true
            }
            // Fallback: retry with factory default if user-supplied failed
            if password != TimeFlipConstants.defaultPassword {
                logger.notice("Retrying login with factory default password")
                return try await attemptLogin(with: TimeFlipConstants.defaultPassword)
            }
        } catch {
            logger.error("Login failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    private func attemptLogin(with password: String) async throws -> Bool {
        let passwordData = Data(password.utf8)
        logger.debug("Writing password to device (pwd=\(password, privacy: .private))")
        try await write(passwordData, to: TimeFlipUUIDs.password, type: .withResponse)
        guard let response = try await read(TimeFlipUUIDs.commandResult) else {
            logger.error("TimeFlip login had no commandResult response")
            return false
        }
        let code = response.first ?? 0
        // Vendor docs conflict: some firmware returns 0x01 or 0x02 for success.
        if code == 0x01 || code == 0x02 {
            isLoggedIn = true
            logger.notice("TimeFlip login accepted (code=\(code))")
            return true
        } else {
            logger.error("TimeFlip login rejected code=\(code)")
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
            await streamHistory(startingFrom: eventNumber ?? 0)
        }
    }

    // MARK: - Private helpers

    private func waitForBluetoothPower() async throws {
        if central.state == .poweredOn { return }
        logger.debug("Waiting for Bluetooth power-on")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations.poweredOn = continuation
        }
        if central.state != .poweredOn {
            throw DeviceError.bluetoothUnavailable
        }
    }

    private func scanAndConnect() async throws {
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
            Task { [weak self] in
                guard let self else { return }
                let delaySeconds = filtered ? discoveryTimeoutSeconds : fallbackTimeoutSeconds
                try? await Task.sleep(nanoseconds: delaySeconds * TimeConstants.nanosecondsPerSecond)
                if self.continuations.connection != nil {
                    self.central.stopScan()
                    self.continuations.connection?.resume(throwing: DeviceError.discoveryTimeout)
                    self.continuations.connection = nil
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
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: fallbackTimeoutSeconds * TimeConstants.nanosecondsPerSecond)
                if let pending = self.continuations.characteristics {
                    logger.error("Characteristic discovery timed out; failing connect")
                    pending.resume(throwing: DeviceError.serviceDiscoveryFailed)
                    self.continuations.characteristics = nil
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

        for await frame in stream {
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

        await withNotification(TimeFlipUUIDs.history, enabled: false)
        return entries
    }

    private func withNotification(_ uuid: CBUUID, enabled: Bool) async {
        guard let characteristic = characteristics[uuid] else { return }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                continuations.notification[uuid] = continuation
                peripheral?.setNotifyValue(enabled, for: characteristic)
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
        do {
            logger.debug("Setting double-tap params ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)")
            _ = try await performCommand(payload)
        } catch {
            logger.error("Failed to set double-tap params: \(error.localizedDescription, privacy: .public)")
        }
    }

    func readDoubleTapParameters() async -> DoubleTapParameters? {
        do {
            let response = try await performCommand(Data([0x17]))
            guard response.count >= 9, response[0] == 0x17 else {
                logger.error("Unexpected double-tap read response len=\(response.count) resp=\(response.hexString(), privacy: .public)")
                return nil
            }
            let params = DoubleTapParameters(
                clickThreshold: response[2],
                limit: response[4],
                latency: response[6],
                window: response[8]
            )
            logger.debug("Read double-tap params ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)")
            return params
        } catch {
            logger.error("Failed to read double-tap params: \(error.localizedDescription, privacy: .public)")
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

    func refreshDeviceInfo() async {
        do {
            let manufacturer = try await readString(TimeFlipUUIDs.manufacturerName)
            let model = try await readString(TimeFlipUUIDs.modelNumber)
            let hardware = try await readString(TimeFlipUUIDs.hardwareRevision)
            let firmware = try await readString(TimeFlipUUIDs.firmwareRevision)
            let systemID = try await readString(TimeFlipUUIDs.systemID)
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
        if allowBroadDiscovery {
            let loweredName = (peripheral.name ?? "").lowercased()
            let nameMatches = loweredName.contains("timeflip")

            let advertisedServices = (
                advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            ) + (
                advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
            ) + (
                advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
            )
            let serviceMatches = advertisedServices.contains(TimeFlipUUIDs.service)

            guard nameMatches || serviceMatches else {
                logger.debug("Skipping peripheral \(loweredName, privacy: .public) (no name/service match)")
                return
            }
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.notice("Connected to TimeFlip \(peripheral.identifier.uuidString, privacy: .public)")
        continuations.connection?.resume(returning: ())
        continuations.connection = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        continuations.connection?.resume(throwing: DeviceError.connectionFailed)
        continuations.connection = nil
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.warning("Disconnected from TimeFlip: \(error?.localizedDescription ?? "none", privacy: .public)")
        continuations.connection?.resume(throwing: DeviceError.connectionFailed)
        continuations.connection = nil
        onDisconnect?()
    }
}

// MARK: - CBPeripheralDelegate

@MainActor
extension TimeFlipBLEDevice: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
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
            continuations.characteristics?.resume(throwing: DeviceError.serviceDiscoveryFailed)
            continuations.characteristics = nil
        } else if haveAll {
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
        let valueHex = characteristic.value?.hexString() ?? "nil"
        logger.debug("didUpdateValue uuid=\(uuid.uuidString, privacy: .public) value=\(valueHex, privacy: .public) err=\(String(describing: error))")
        if let continuation = continuations.reads.removeValue(forKey: uuid) {
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
        logger.debug("didWriteValue uuid=\(uuid.uuidString, privacy: .public) err=\(String(describing: error))")
        if let continuation = continuations.writes.removeValue(forKey: uuid) {
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
    /// Render as uppercase hex bytes separated by spaces.
    func hexString() -> String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

import Foundation
import OSLog

@MainActor
final class MockTimeFlipDevice: TimeFlipSessionManaging, TimeFlipMockControlling {
    private enum Constants {
        static let defaultInitialFacetID: UInt8 = 4
        static let defaultBatteryLevel: UInt8 = 95
        static let historySample1FacetID: UInt8 = 5
        static let historySample2FacetID: UInt8 = 4
        static let historySample1OffsetMinutes: TimeInterval = 8
        static let historySample1DurationMinutes: TimeInterval = 6
        static let historySample2OffsetMinutes: TimeInterval = 2
        static let historySample2DurationMinutes: TimeInterval = 2
    }

    struct Configuration: Sendable {
        var initialFacetID: UInt8
        var batteryLevel: UInt8
        var systemState: TimeFlipSystemState
        var isPaused: Bool
        var isLocked: Bool
        var isInitiallyPaired: Bool
        var autoPauseMinutes: UInt16
        var emitInitialStatus: Bool

        init(
            initialFacetID: UInt8 = Constants.defaultInitialFacetID,
            batteryLevel: UInt8 = Constants.defaultBatteryLevel,
            systemState: TimeFlipSystemState = .ok,
            isPaused: Bool = true,
            isLocked: Bool = false,
            isInitiallyPaired: Bool = true,
            autoPauseMinutes: UInt16 = 0,
            emitInitialStatus: Bool = true
        ) {
            self.initialFacetID = initialFacetID
            self.batteryLevel = batteryLevel
            self.systemState = systemState
            self.isPaused = isPaused
            self.isLocked = isLocked
            self.isInitiallyPaired = isInitiallyPaired
            self.autoPauseMinutes = autoPauseMinutes
            self.emitInitialStatus = emitInitialStatus
        }
    }

    private struct ActiveSession {
        var facetID: UInt8
        var start: Date
        var isPaused: Bool
    }

    private let logger: Logger
    private let configuration: Configuration
    private var stream: AsyncStream<TimeFlipEvent>?
    private var continuation: AsyncStream<TimeFlipEvent>.Continuation?
    private var autoPauseTask: Task<Void, Never>?
    private var deviceTimeOffset: TimeInterval = 0
    private var activeSession: ActiveSession?
    private(set) var history: [TimeFlipHistoryEntry] = []
    private var historyNotificationsEnabled: Bool = false
    private var brightnessPercent: UInt8 = 100
    private var blinkIntervalSeconds: UInt8 = 5
    private var doubleTapParameters: DoubleTapParameters = .default
    private var facetConfigurations: [UInt8: (mode: UInt8, pomodoroSeconds: UInt32)] = [:]
    private var devicePassword: String = TimeFlipConstants.defaultPassword
    private var facetColors: [UInt8: ColorComponents] = [:]
    private var deviceName: String = "TimeFlip"
    // Exposed for tests to seed realistic history entries.
    func seedHistory(_ entries: [TimeFlipHistoryEntry]) {
        history = entries
    }

    // Convenience for tests to query the last event number, mirrors device request for 0xFF FF FF FF.
    var lastEventNumber: UInt32? {
        history.compactMap { $0.eventNumber }.max()
    }

    private var eventLog: [String] = []
    private(set) var isPaired: Bool
    private var isLoggedIn: Bool = false
    private var notificationsEnabled: Bool = false

    private var state: TimeFlipDeviceSnapshot

    init(
        configuration: Configuration = Configuration(),
        logger: Logger = Logger(subsystem: AppIdentifiers.subsystem, category: "mock-device")
    ) {
        self.configuration = configuration
        self.logger = logger
        self.isPaired = configuration.isInitiallyPaired
        let now = Date()
        let initialFacetID = TimeFlipConstants.isValidFacetID(configuration.initialFacetID)
            ? configuration.initialFacetID
            : TimeFlipConstants.unassignedFacetID
        let batteryLevel = min(
            max(configuration.batteryLevel, TimeFlipConstants.minBatteryLevel),
            TimeFlipConstants.maxBatteryLevel
        )
        self.state = TimeFlipDeviceSnapshot(
            facetID: initialFacetID,
            isPaused: configuration.isPaused,
            isLocked: configuration.isLocked,
            autoPauseMinutes: configuration.autoPauseMinutes,
            batteryLevel: batteryLevel,
            systemState: configuration.systemState,
            deviceTime: now,
            deviceInfo: TimeFlipDeviceInfo(
                manufacturer: "TimeFlip",
                modelNumber: "TimeFlip2",
                hardwareRevision: "1.0",
                firmwareRevision: "1.0.0",
                systemID: "mock"
            )
        )
        let historyEnd = now
        let sample1Start = historyEnd.addingTimeInterval(-Constants.historySample1OffsetMinutes * TimeConstants.secondsPerMinute)
        let sample2Start = historyEnd.addingTimeInterval(-Constants.historySample2OffsetMinutes * TimeConstants.secondsPerMinute)

        history.append(
            TimeFlipHistoryEntry(
                eventNumber: UInt32(sample1Start.timeIntervalSince1970),
                facetID: Constants.historySample1FacetID,
                startedAt: sample1Start,
                duration: Constants.historySample1DurationMinutes * TimeConstants.secondsPerMinute,
                isPaused: false
            )
        )
        history.append(
            TimeFlipHistoryEntry(
                eventNumber: UInt32(sample2Start.timeIntervalSince1970),
                facetID: Constants.historySample2FacetID,
                startedAt: sample2Start,
                duration: Constants.historySample2DurationMinutes * TimeConstants.secondsPerMinute,
                isPaused: false
            )
        )
        if TimeFlipConstants.isValidFacetID(initialFacetID) {
            self.activeSession = ActiveSession(
                facetID: initialFacetID,
                start: now,
                isPaused: configuration.isPaused
            )
        }
    }

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
        logger.notice("Mock TimeFlip device started (no transport)")
    }

    func stop() {
        autoPauseTask?.cancel()
        autoPauseTask = nil
        continuation?.finish()
        continuation = nil
        stream = nil
        logger.notice("Mock TimeFlip device stopped")
    }

    // MARK: - Session management (parity with real device)

    func connect() async -> Bool {
        // No transport; keep for API parity
        logger.debug("Mock connect")
        return true
    }

    func disconnect() async {
        stop()
    }

    func login(password: String) async -> Bool {
        // Accept only the configured six-character password.
        guard password.count == 6, password == devicePassword else {
            logger.warning("Mock login rejected")
            return false
        }
        isLoggedIn = true
        logger.debug("Mock login accepted")
        return true
    }

    func enableNotifications() async {
        // Notifications always active once paired & logged
        notificationsEnabled = true
        logger.debug("Mock notifications enabled")
    }

    func initializeSession(hostTime: Date, desiredAutoPauseMinutes: UInt16) async {
        synchronizeTimeWithHost(date: hostTime)
        applyAutoPause(minutes: desiredAutoPauseMinutes)
        emitInitialStatusIfNeeded()
        scheduleAutoPauseIfNeeded()
    }

    func setFacetColor(facetID: UInt8, components: ColorComponents) async {
        facetColors[facetID] = components
        logger.debug("Mock set color facet=\(facetID, privacy: .public) r=\(components.red) g=\(components.green) b=\(components.blue)")
    }

    func snapshot() -> TimeFlipDeviceSnapshot {
        stateWithUpdatedDeviceTime()
    }

    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry] {
        fetchHistorySync(startingFrom: eventNumber)
    }

    func pair() {
        guard !isPaired else { return }
        isPaired = true
        if isLoggedIn {
            emitInitialStatusIfNeeded()
            scheduleAutoPauseIfNeeded()
        }
        logger.notice("Mock TimeFlip device paired")
    }

    func forget() {
        guard isPaired else { return }
        isPaired = false
        isLoggedIn = false
        notificationsEnabled = false
        logger.notice("Mock TimeFlip device unpaired")
    }

    // MARK: - Configuration commands (mirrors v4 opcode set)

    func setBrightness(percent: UInt8) {
        brightnessPercent = min(100, percent)
        appendEventLog("brightness=\(brightnessPercent)")
    }

    func setBlinkInterval(seconds: UInt8) {
        applyBlinkInterval(seconds: seconds)
    }

    func setFacetConfiguration(facetID: UInt8, mode: UInt8, pomodoroSeconds: UInt32) {
        guard TimeFlipConstants.isValidFacetID(facetID) else {
            appendEventLog("facet_config_ignored_invalid facet=\(facetID)")
            return
        }
        facetConfigurations[facetID] = (mode: mode, pomodoroSeconds: pomodoroSeconds)
        appendEventLog("facet_config facet=\(facetID) mode=\(mode) pomo=\(pomodoroSeconds)")
    }

    func setDeviceName(_ name: String) {
        deviceName = name
        appendEventLog("device_name=\(name)")
    }

    func setPassword(_ password: String) {
        guard password.count == 6 else {
            appendEventLog("password_ignored_invalid length=\(password.count)")
            return
        }
        devicePassword = password
        appendEventLog("password_updated")
    }

    /// Enable history notifications so new history frames can be pulled or emitted in tests.
    func enableHistoryNotifications() {
        historyNotificationsEnabled = true
        appendEventLog("history_notify_on")
    }

    /// Encode history entries into 20-byte frames that mirror v4 history_data characteristic.
    func historyFrames(startingFrom eventNumber: UInt32?) -> [Data] {
        let filtered = fetchHistorySync(startingFrom: eventNumber)
        let frames: [Data] = filtered.map { entry in
            var data = Data(repeating: 0, count: 20)
            let eventNum = entry.eventNumber ?? UInt32(entry.startedAt.timeIntervalSince1970)
            data.replaceSubrange(0..<4, with: withUnsafeBytes(of: eventNum.bigEndian, Array.init))
            data[4] = entry.facetID
            let timestamp = UInt64(entry.startedAt.timeIntervalSince1970)
            data.replaceSubrange(5..<13, with: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
            let duration = UInt32(max(0, entry.duration))
            var durationBytes = withUnsafeBytes(of: duration.littleEndian, Array.init)
            if durationBytes.count < 5 {
                durationBytes.append(contentsOf: repeatElement(0, count: 5 - durationBytes.count))
            }
            data.replaceSubrange(13..<18, with: durationBytes.prefix(5))
            return data
        }
        // Append sentinel of zeros to mark end of history (per v4 spec)
        return frames + [Data(repeating: 0, count: 20)]
    }

    private func fetchHistorySync(startingFrom eventNumber: UInt32?) -> [TimeFlipHistoryEntry] {
        guard let eventNumber else { return history }
        return history.filter { entry in
            guard let entryNumber = entry.eventNumber else { return false }
            return entryNumber >= eventNumber
        }
    }

    func flip(to facetID: UInt8) {
        guard !state.isLocked else {
            appendEventLog("flip_ignored_locked facet=\(facetID)")
            return
        }
        guard TimeFlipConstants.isValidFacetID(facetID) else {
            appendEventLog("flip_ignored_invalid facet=\(facetID)")
            return
        }
        let now = deviceTime()
        finalizeActiveSession(at: now)
        state = TimeFlipDeviceSnapshot(
            facetID: facetID,
            isPaused: state.isPaused,
            isLocked: state.isLocked,
            autoPauseMinutes: state.autoPauseMinutes,
            batteryLevel: state.batteryLevel,
            systemState: state.systemState,
            deviceTime: now,
            deviceInfo: state.deviceInfo
        )
        beginSession(facetID: facetID, paused: state.isPaused, at: now)
        emit(.facetChanged(facetID: facetID))
        appendEventLog("flip facet=\(facetID)")
        scheduleAutoPauseIfNeeded(resetTimer: true)
    }

    func doubleTap(targetFacetID: UInt8?) {
        if let targetFacetID, !TimeFlipConstants.isValidFacetID(targetFacetID) {
            appendEventLog("double_tap_ignored_invalid facet=\(targetFacetID)")
            return
        }
        let facetID = targetFacetID ?? state.facetID
        let newPauseState = !state.isPaused
        setPaused(newPauseState, emitDoubleTap: true, facetIDOverride: facetID, reason: "double_tap")
    }

    func setPaused(_ paused: Bool) {
        setPaused(paused, emitDoubleTap: true, facetIDOverride: state.facetID, reason: "pause_command")
    }

    func setLocked(_ locked: Bool) {
        state = stateWithUpdatedDeviceTime(isLocked: locked)
        appendEventLog("lock=\(locked)")
    }

    func setAutoPause(minutes: UInt16) {
        applyAutoPause(minutes: minutes)
    }

    func setAutoPause(minutes: UInt16) async {
        applyAutoPause(minutes: minutes)
    }

    func setPause(_ on: Bool) async {
        setPaused(on, emitDoubleTap: false, facetIDOverride: state.facetID, reason: "pause_cmd")
    }

    func setLEDBrightness(percent: UInt8) async {
        setBrightness(percent: percent)
    }

    func setBlinkInterval(seconds: UInt8) async {
        applyBlinkInterval(seconds: seconds)
    }

    private func applyBlinkInterval(seconds: UInt8) {
        blinkIntervalSeconds = min(60, max(5, seconds))
        appendEventLog("blink_interval=\(blinkIntervalSeconds)")
    }

    func setDoubleTapParameters(_ params: DoubleTapParameters) async {
        doubleTapParameters = params
        appendEventLog("double_tap_params ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)")
    }

    func readDoubleTapParameters() async -> DoubleTapParameters? {
        doubleTapParameters
    }

    func refreshDeviceInfo() async {
        emit(.deviceInfo(state.deviceInfo ?? TimeFlipDeviceInfo(
            manufacturer: "TimeFlip",
            modelNumber: "TimeFlip2",
            hardwareRevision: "1.0",
            firmwareRevision: "1.0.0",
            systemID: "mock"
        )))
    }

    func setBatteryLevel(_ level: UInt8) {
        guard level >= TimeFlipConstants.minBatteryLevel, level <= TimeFlipConstants.maxBatteryLevel else {
            appendEventLog("battery_ignored_invalid level=\(level)")
            return
        }
        state = stateWithUpdatedDeviceTime(batteryLevel: level)
        emit(.batteryLevel(level))
        appendEventLog("battery=\(level)")
    }

    func setSystemState(_ state: TimeFlipSystemState) {
        self.state = stateWithUpdatedDeviceTime(systemState: state)
        emit(.systemState(state))
        appendEventLog("system_state=\(state.syncStatus.description)")
    }

    func setDeviceTime(_ date: Date) {
        deviceTimeOffset = date.timeIntervalSince(Date())
        state = stateWithUpdatedDeviceTime(deviceTimeValue: date)
        appendEventLog("device_time=\(date.timeIntervalSince1970)")
    }

    func appendEventLog(_ message: String) {
        eventLog.append(message)
        emit(.eventLog(message))
    }

    private func applyAutoPause(minutes: UInt16) {
        state = stateWithUpdatedDeviceTime(autoPauseMinutes: minutes)
        emit(.autoPauseMinutes(minutes))
        appendEventLog("auto_pause_minutes=\(minutes)")
        scheduleAutoPauseIfNeeded(resetTimer: true)
    }

    private func setPaused(
        _ paused: Bool,
        emitDoubleTap: Bool,
        facetIDOverride: UInt8,
        reason: String
    ) {
        guard state.isPaused != paused else { return }
        let now = deviceTime()
        let effectiveFacetID = TimeFlipConstants.isValidFacetID(facetIDOverride) ? facetIDOverride : state.facetID
        finalizeActiveSession(at: now)
        state = stateWithUpdatedDeviceTime(isPaused: paused, deviceTimeValue: now)
        beginSession(facetID: state.facetID, paused: paused, at: now)
        if emitDoubleTap {
            emit(.doubleTap(TimeFlipDoubleTapPayload(facetID: effectiveFacetID, pauseOn: paused)))
        }
        appendEventLog("\(reason)=\(paused)")
        scheduleAutoPauseIfNeeded(resetTimer: true)
    }

    private func scheduleAutoPauseIfNeeded(resetTimer: Bool = false) {
        if resetTimer {
            autoPauseTask?.cancel()
            autoPauseTask = nil
        }
        guard !state.isPaused, state.autoPauseMinutes > 0 else { return }
        let delay = TimeInterval(state.autoPauseMinutes) * TimeConstants.secondsPerMinute
        autoPauseTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * Double(TimeConstants.nanosecondsPerSecond))
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                self?.setPaused(
                    true,
                    emitDoubleTap: true,
                    facetIDOverride: self?.state.facetID ?? TimeFlipConstants.unassignedFacetID,
                    reason: "auto_pause"
                )
            }
        }
    }

    private func emit(_ event: TimeFlipEvent) {
        guard isPaired, isLoggedIn, notificationsEnabled else { return }
        continuation?.yield(event)
        logger.debug("Mock event emitted: \(event.description, privacy: .public)")
    }

    private func emitInitialStatusIfNeeded() {
        guard configuration.emitInitialStatus, isPaired, isLoggedIn, notificationsEnabled else { return }
        emit(.systemState(state.systemState))
        emit(.batteryLevel(state.batteryLevel))
        emit(.facetChanged(facetID: state.facetID))
        if state.isPaused {
            emit(.doubleTap(TimeFlipDoubleTapPayload(facetID: state.facetID, pauseOn: true)))
        }
    }

    private func deviceTime() -> Date {
        Date().addingTimeInterval(deviceTimeOffset)
    }

    /// Mirrors firmware expectation: host sets device clock on connection using command 0x08.
    private func synchronizeTimeWithHost(date: Date = Date()) {
        deviceTimeOffset = date.timeIntervalSince(Date())
        state = stateWithUpdatedDeviceTime(deviceTimeValue: date)
        appendEventLog("time_sync=\(UInt64(date.timeIntervalSince1970))")
    }

    private func stateWithUpdatedDeviceTime(
        facetID: UInt8? = nil,
        isPaused: Bool? = nil,
        isLocked: Bool? = nil,
        autoPauseMinutes: UInt16? = nil,
        batteryLevel: UInt8? = nil,
        systemState: TimeFlipSystemState? = nil,
        deviceTimeValue: Date? = nil,
        deviceInfo: TimeFlipDeviceInfo? = nil
    ) -> TimeFlipDeviceSnapshot {
        let time = deviceTimeValue ?? deviceTime()
        return TimeFlipDeviceSnapshot(
            facetID: facetID ?? state.facetID,
            isPaused: isPaused ?? state.isPaused,
            isLocked: isLocked ?? state.isLocked,
            autoPauseMinutes: autoPauseMinutes ?? state.autoPauseMinutes,
            batteryLevel: batteryLevel ?? state.batteryLevel,
            systemState: systemState ?? state.systemState,
            deviceTime: time,
            deviceInfo: deviceInfo ?? state.deviceInfo
        )
    }

    private func finalizeActiveSession(at date: Date) {
        guard let activeSession else { return }
        let duration = max(0, date.timeIntervalSince(activeSession.start))
        history.append(
            TimeFlipHistoryEntry(
                eventNumber: UInt32(activeSession.start.timeIntervalSince1970),
                facetID: activeSession.facetID,
                startedAt: activeSession.start,
                duration: duration,
                isPaused: activeSession.isPaused
            )
        )
        self.activeSession = nil
    }

    private func beginSession(facetID: UInt8, paused: Bool, at date: Date) {
        guard TimeFlipConstants.isValidFacetID(facetID) else { return }
        activeSession = ActiveSession(facetID: facetID, start: date, isPaused: paused)
    }
}

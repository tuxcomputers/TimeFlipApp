import Foundation
import OSLog

@MainActor
final class MockTimeFlipDevice: TimeFlipSessionManaging, TimeFlipMockControlling {
    private enum Constants {
        static let defaultInitialFaceID: UInt8 = 4
        static let defaultBatteryLevel: UInt8 = 95
        static let historySample1FaceID: UInt8 = 5
        static let historySample2FaceID: UInt8 = 4
        static let historySample1OffsetMinutes: TimeInterval = 8
        static let historySample1DurationMinutes: TimeInterval = 6
        static let historySample2OffsetMinutes: TimeInterval = 2
        static let historySample2DurationMinutes: TimeInterval = 2
    }

    /// How long the mock takes to answer, so it behaves like a device on a radio link rather than a
    /// function call. A real TimeFlip never answers instantly: connecting means scan plus connect plus
    /// service and characteristic discovery, and every command is a write followed by a notification
    /// coming back.
    ///
    /// This matters beyond realism for its own sake. With zero latency, a caller that forgets to
    /// `await` a step before depending on it still passes, because the work already finished before
    /// the next line ran. Give the operations real duration and that ordering bug shows up.
    ///
    /// Default is `.instant`, so existing callers are unaffected and fast tests stay fast; opt into
    /// `.realistic()` where the timing is the point.
    ///
    /// ## Where the numbers come from
    ///
    /// Measured from `debug_log` on a real device (`real.sqlite`, 252 history fetches and 39 logins),
    /// not invented. `logged_at` only has second resolution, so each figure is estimated from how
    /// often a pair of rows straddles a second boundary: for a duration under one second with start
    /// times spread evenly through the second, the fraction that straddle *is* the duration. Rows
    /// were paired adjacently, because pairing "next matching message" makes a failed login line up
    /// with a much later successful retry and reports absurd gaps (43s, 57s, 922s were all this).
    ///
    ///  - `historyRead` 130ms -- a fetch where the cheap check found nothing new (21 of 166 straddled)
    ///  - a fetch that actually transferred 340ms (29 of 86 straddled), so ~210ms of streaming on top
    ///  - `login` 260ms for the whole sequence (10 of 39); the single write-then-notify leg inside it
    ///    ("Password sent" to "raw bytes") is 120ms (5 of 42)
    ///  - `write` 110ms, from back-to-back LED colour writes (47 of 444)
    ///  - a verified write, lock plus read-back, is 290ms -- consistent with `write` + `read`
    ///
    /// `connect`, `enableNotifications` and `initializeSession` are **estimates**: nothing logs the
    /// start of a scan or connect, so there is no pair to measure. They're flagged individually below.
    /// Scale the profile down rather than editing the figures, so the relative costs stay in
    /// proportion.
    struct Latency: Sendable {
        /// Scan, connect, then discover services and characteristics. **Estimated** -- nothing logs
        /// the start of a scan, so this is unmeasured. Much the slowest step in practice.
        var connect: Duration
        /// Password write plus the device's reply. Measured: 260ms.
        var login: Duration
        /// Subscribing to each notification characteristic in turn. **Estimated.**
        var enableNotifications: Duration
        /// Time sync plus the initial status burst. **Estimated** (roughly two round trips).
        var initializeSession: Duration
        /// A command write and its acknowledgement (auto-pause, lock, brightness, colour). Measured:
        /// 110ms. A write that also reads back to verify costs this *plus* `read`.
        var write: Duration
        /// A characteristic read (lock state, double-tap parameters, device info). Measured: 130ms.
        var read: Duration
        /// The fixed cost of any history fetch, including one that finds nothing new. Measured: 130ms.
        var historyRead: Duration
        /// Charged per entry on top of `historyRead`, because history streams back frame by frame.
        /// **Inferred**: the ~210ms difference between a no-op and a transferring fetch, divided over a
        /// backlog of roughly twenty entries. The split between fixed and per-entry is an inference;
        /// only the two totals were measured.
        var historyPerEntry: Duration

        /// Everything answers immediately. The default, and what every caller got before `Latency`
        /// existed.
        static let instant = Latency(
            connect: .zero,
            login: .zero,
            enableNotifications: .zero,
            initializeSession: .zero,
            write: .zero,
            read: .zero,
            historyRead: .zero,
            historyPerEntry: .zero
        )

        /// The measured timings above, multiplied by `scale`. Use a small scale in CI (`0.1` keeps a
        /// whole workflow well under a second) -- the operations still genuinely suspend and
        /// interleave, which is what catches ordering bugs; the wall-clock size is not the point.
        static func realistic(scale: Double = 1.0) -> Latency {
            func ms(_ milliseconds: Double) -> Duration {
                .microseconds(Int(milliseconds * 1000 * scale))
            }
            return Latency(
                connect: ms(800),
                login: ms(260),
                enableNotifications: ms(150),
                initializeSession: ms(250),
                write: ms(110),
                read: ms(130),
                historyRead: ms(130),
                historyPerEntry: ms(10)
            )
        }
    }

    struct Configuration: Sendable {
        var initialFaceID: UInt8
        var batteryLevel: UInt8
        var systemState: TimeFlipSystemState
        var isPaused: Bool
        var isLocked: Bool
        var isInitiallyPaired: Bool
        var autoPauseMinutes: UInt16
        var emitInitialStatus: Bool
        var latency: Latency

        init(
            initialFaceID: UInt8 = Constants.defaultInitialFaceID,
            batteryLevel: UInt8 = Constants.defaultBatteryLevel,
            systemState: TimeFlipSystemState = .ok,
            isPaused: Bool = true,
            isLocked: Bool = false,
            isInitiallyPaired: Bool = true,
            autoPauseMinutes: UInt16 = 0,
            emitInitialStatus: Bool = true,
            latency: Latency = .instant
        ) {
            self.initialFaceID = initialFaceID
            self.batteryLevel = batteryLevel
            self.systemState = systemState
            self.isPaused = isPaused
            self.isLocked = isLocked
            self.isInitiallyPaired = isInitiallyPaired
            self.autoPauseMinutes = autoPauseMinutes
            self.emitInitialStatus = emitInitialStatus
            self.latency = latency
        }
    }

    private struct ActiveSession {
        var faceID: UInt8
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
    private var brightnessPercent: UInt8 = 100
    private var blinkIntervalSeconds: UInt8 = 5
    private var doubleTapParameters: DoubleTapParameters = .default
    private var devicePassword: String = TimeFlipConstants.defaultPassword
    private var faceColors: [UInt8: ColorComponents] = [:]
    // Real firmware uses a monotonic counter; timestamp-derived numbers collide
    // when two sessions start within the same second.
    private var nextEventNumber: UInt32 = 0
    // Exposed for tests to seed realistic history entries.
    func seedHistory(_ entries: [TimeFlipHistoryEntry]) {
        history = entries
        let maxSeeded = entries.compactMap { $0.eventNumber }.max() ?? 0
        nextEventNumber = max(nextEventNumber, maxSeeded + 1)
    }

    private func allocateEventNumber() -> UInt32 {
        defer { nextEventNumber += 1 }
        return nextEventNumber
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
        let initialFaceID = TimeFlipConstants.isValidFaceID(configuration.initialFaceID)
            ? configuration.initialFaceID
            : TimeFlipConstants.unassignedFaceID
        let batteryLevel = min(
            max(configuration.batteryLevel, TimeFlipConstants.minBatteryLevel),
            TimeFlipConstants.maxBatteryLevel
        )
        self.state = TimeFlipDeviceSnapshot(
            faceID: initialFaceID,
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

        // Seed the counter with realistic device-like magnitudes.
        nextEventNumber = UInt32(now.timeIntervalSince1970)
        history.append(
            TimeFlipHistoryEntry(
                eventNumber: allocateEventNumber(),
                faceID: Constants.historySample1FaceID,
                startedAt: sample1Start,
                duration: Constants.historySample1DurationMinutes * TimeConstants.secondsPerMinute,
                isPaused: false
            )
        )
        history.append(
            TimeFlipHistoryEntry(
                eventNumber: allocateEventNumber(),
                faceID: Constants.historySample2FaceID,
                startedAt: sample2Start,
                duration: Constants.historySample2DurationMinutes * TimeConstants.secondsPerMinute,
                isPaused: false
            )
        )
        if TimeFlipConstants.isValidFaceID(initialFaceID) {
            self.activeSession = ActiveSession(
                faceID: initialFaceID,
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

    // MARK: - Simulated radio latency

    /// Suspends for `duration`, so the mock answers on the same sort of timescale a device on a radio
    /// link does. Zero under `.instant` (the default), where `Task.sleep` returns immediately.
    ///
    /// A rejected command still costs time: the real device is asked and answers no, so the caller
    /// waits either way. Latency is therefore charged *before* the guards, not after them.
    private func waitForRadio(_ duration: Duration) async {
        guard duration > .zero else { return }
        try? await Task.sleep(for: duration)
    }

    // MARK: - Session management (parity with real device)

    func connect() async -> Bool {
        // No transport, but a real connect is scan + connect + service/characteristic discovery.
        await waitForRadio(configuration.latency.connect)
        logger.debug("Mock connect")
        return true
    }

    func disconnect() async {
        stop()
    }

    func login(password: String) async -> Bool {
        await waitForRadio(configuration.latency.login)
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
        await waitForRadio(configuration.latency.enableNotifications)
        // Notifications always active once paired & logged
        notificationsEnabled = true
        logger.debug("Mock notifications enabled")
    }

    func initializeSession(hostTime: Date, desiredAutoPauseMinutes: UInt16) async {
        await waitForRadio(configuration.latency.initializeSession)
        synchronizeTimeWithHost(date: hostTime)
        applyAutoPause(minutes: desiredAutoPauseMinutes)
        emitInitialStatusIfNeeded()
        scheduleAutoPauseIfNeeded()
    }

    func setFaceColor(faceID: UInt8, components: ColorComponents) async {
        await waitForRadio(configuration.latency.write)
        faceColors[faceID] = components
        logger.debug("Mock set color face=\(faceID, privacy: .public) r=\(components.red) g=\(components.green) b=\(components.blue)")
    }

    func snapshot() -> TimeFlipDeviceSnapshot {
        stateWithUpdatedDeviceTime()
    }

    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry] {
        let entries = fetchHistorySync(startingFrom: eventNumber)
        // A fixed cost even when there's nothing new, plus streaming time per entry returned -- the
        // measured difference between a no-op fetch and one that actually transferred.
        let latency = configuration.latency
        await waitForRadio(latency.historyRead + latency.historyPerEntry * entries.count)
        return entries
    }

    func readLastEvent() async -> TimeFlipHistoryEntry? {
        await waitForRadio(configuration.latency.historyRead)
        return history.max { ($0.eventNumber ?? 0) < ($1.eventNumber ?? 0) }
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

    private func fetchHistorySync(startingFrom eventNumber: UInt32?) -> [TimeFlipHistoryEntry] {
        guard let eventNumber else { return history }
        return history.filter { entry in
            guard let entryNumber = entry.eventNumber else { return false }
            return entryNumber >= eventNumber
        }
    }

    func flip(to faceID: UInt8) {
        guard !state.isLocked else {
            appendEventLog("flip_ignored_locked face=\(faceID)")
            return
        }
        guard TimeFlipConstants.isValidFaceID(faceID) else {
            appendEventLog("flip_ignored_invalid face=\(faceID)")
            return
        }
        let now = deviceTime()
        finalizeActiveSession(at: now)
        state = TimeFlipDeviceSnapshot(
            faceID: faceID,
            isPaused: state.isPaused,
            isLocked: state.isLocked,
            autoPauseMinutes: state.autoPauseMinutes,
            batteryLevel: state.batteryLevel,
            systemState: state.systemState,
            deviceTime: now,
            deviceInfo: state.deviceInfo
        )
        beginSession(faceID: faceID, paused: state.isPaused, at: now)
        emit(.faceChanged(faceID: faceID))
        appendEventLog("flip face=\(faceID)")
        scheduleAutoPauseIfNeeded(resetTimer: true)
    }

    func doubleTap(targetFaceID: UInt8?) {
        if let targetFaceID, !TimeFlipConstants.isValidFaceID(targetFaceID) {
            appendEventLog("double_tap_ignored_invalid face=\(targetFaceID)")
            return
        }
        let faceID = targetFaceID ?? state.faceID
        let newPauseState = !state.isPaused
        setPaused(newPauseState, emitDoubleTap: true, faceIDOverride: faceID, reason: "double_tap")
    }

    func setPaused(_ paused: Bool) {
        setPaused(paused, emitDoubleTap: true, faceIDOverride: state.faceID, reason: "pause_command")
    }

    func setLocked(_ locked: Bool) {
        state = stateWithUpdatedDeviceTime(isLocked: locked)
        appendEventLog("lock=\(locked)")
        emit(.lockChanged(locked))
    }

    func setAutoPause(minutes: UInt16) {
        applyAutoPause(minutes: minutes)
    }

    func setAutoPause(minutes: UInt16) async {
        await waitForRadio(configuration.latency.write)
        applyAutoPause(minutes: minutes)
    }

    func setPause(_ on: Bool) async {
        await waitForRadio(configuration.latency.write)
        setPaused(on, emitDoubleTap: false, faceIDOverride: state.faceID, reason: "pause_cmd")
    }

    func setLock(_ on: Bool) async {
        await waitForRadio(configuration.latency.write)
        setLocked(on)
    }

    func refreshLockState() async -> Bool {
        await waitForRadio(configuration.latency.read)
        return state.isLocked
    }

    func setLEDBrightness(percent: UInt8) async {
        await waitForRadio(configuration.latency.write)
        setBrightness(percent: percent)
    }

    func setBlinkInterval(seconds: UInt8) async {
        await waitForRadio(configuration.latency.write)
        applyBlinkInterval(seconds: seconds)
    }

    private func applyBlinkInterval(seconds: UInt8) {
        blinkIntervalSeconds = min(60, max(5, seconds))
        appendEventLog("blink_interval=\(blinkIntervalSeconds)")
    }

    func setDoubleTapParameters(_ params: DoubleTapParameters) async {
        await waitForRadio(configuration.latency.write)
        doubleTapParameters = params
        appendEventLog("double_tap_params ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)")
    }

    func readDoubleTapParameters() async -> DoubleTapParameters? {
        await waitForRadio(configuration.latency.read)
        return doubleTapParameters
    }

    func refreshDeviceInfo() async {
        await waitForRadio(configuration.latency.read)
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
        faceIDOverride: UInt8,
        reason: String
    ) {
        guard state.isPaused != paused else { return }
        let now = deviceTime()
        let effectiveFaceID = TimeFlipConstants.isValidFaceID(faceIDOverride) ? faceIDOverride : state.faceID
        finalizeActiveSession(at: now)
        state = stateWithUpdatedDeviceTime(isPaused: paused, deviceTimeValue: now)
        beginSession(faceID: state.faceID, paused: paused, at: now)
        if emitDoubleTap {
            emit(.doubleTap(TimeFlipDoubleTapPayload(faceID: effectiveFaceID, pauseOn: paused)))
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
                    faceIDOverride: self?.state.faceID ?? TimeFlipConstants.unassignedFaceID,
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
        emit(.faceChanged(faceID: state.faceID))
        if state.isPaused {
            emit(.doubleTap(TimeFlipDoubleTapPayload(faceID: state.faceID, pauseOn: true)))
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
        faceID: UInt8? = nil,
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
            faceID: faceID ?? state.faceID,
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
                eventNumber: allocateEventNumber(),
                faceID: activeSession.faceID,
                startedAt: activeSession.start,
                duration: duration,
                isPaused: activeSession.isPaused
            )
        )
        self.activeSession = nil
    }

    private func beginSession(faceID: UInt8, paused: Bool, at date: Date) {
        guard TimeFlipConstants.isValidFaceID(faceID) else { return }
        activeSession = ActiveSession(faceID: faceID, start: date, isPaused: paused)
    }
}

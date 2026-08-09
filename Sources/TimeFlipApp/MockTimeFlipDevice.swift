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

    /// A span a real operation takes, as the range it varies across rather than one number. Sampling
    /// uniformly between the bounds is what makes a run of history records come back 184ms, 198ms,
    /// 163ms, ... instead of the same figure every time -- which is how the device behaves, and which
    /// stops a caller from accidentally depending on a delay being constant.
    ///
    /// `lower == upper` gives a fixed delay; `.none` gives no delay at all.
    struct DelayRange: Sendable, Equatable {
        var lower: Duration
        var upper: Duration

        static let none = DelayRange(lower: .zero, upper: .zero)

        /// A span that doesn't vary. Use when a real measurement shows no meaningful spread, not as a
        /// placeholder for "haven't measured it yet" -- an honest wide range is better than a fake
        /// precise one.
        static func fixed(_ duration: Duration) -> DelayRange {
            DelayRange(lower: duration, upper: duration)
        }

        /// Milliseconds, the unit every figure here was measured in.
        static func milliseconds(_ lower: Double, _ upper: Double) -> DelayRange {
            DelayRange(lower: .microseconds(Int(lower * 1000)), upper: .microseconds(Int(upper * 1000)))
        }

        /// Whole microseconds in a `Duration`, counting both components -- a range may exceed a second
        /// once scaled up, so the seconds part can't be ignored.
        private static func microseconds(_ duration: Duration) -> Int64 {
            duration.components.seconds * 1_000_000
                + duration.components.attoseconds / 1_000_000_000_000
        }

        func scaled(by factor: Double) -> DelayRange {
            DelayRange(
                lower: .microseconds(Int64(Double(Self.microseconds(lower)) * factor)),
                upper: .microseconds(Int64(Double(Self.microseconds(upper)) * factor))
            )
        }

        /// A value in `[lower, upper]`, drawn from `generator` so a run is reproducible.
        func sample(using generator: inout some RandomNumberGenerator) -> Duration {
            let low = Self.microseconds(lower)
            let high = Self.microseconds(upper)
            guard high > low else { return lower }
            return .microseconds(Int64.random(in: low...high, using: &generator))
        }
    }

    /// Deterministic PRNG (SplitMix64) so a run with realistic latency is reproducible.
    ///
    /// Randomised delays are the point -- a real device doesn't answer in the same time twice -- but
    /// unreproducible ones would be a liability: a failure that only appears for some draws could not
    /// be replayed. Seeding fixes that, so the same seed always yields the same sequence and a failing
    /// run can be re-run exactly.
    struct SeededGenerator: RandomNumberGenerator, Sendable {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// How consecutive history frames arrive.
    ///
    /// Not a plain delay range, because the gaps are not smoothly distributed. BLE delivers on
    /// connection events, so a gap is a whole number of connection intervals: measured on real
    /// hardware over 105 inter-frame gaps, the arrivals fit a 14.5ms grid with a residual standard
    /// deviation of 1.32ms, distributed
    ///
    ///     0 intervals   3.8%   (two frames in one connection event, gap 0-1ms)
    ///     1 interval   62.9%   (12-18ms)
    ///     2 intervals  29.5%   (27-31ms)
    ///     3 intervals   3.8%   (41-45ms)
    ///
    /// giving a mean of 19.4ms per record, which held at 19 in every one of the five runs.
    ///
    /// The count multiplies a *single* interval draw rather than summing that many independent ones:
    /// the observed spread does not grow with the count (one interval spans 6ms, two spans 4ms,
    /// three spans 4ms), so the jitter is in the grid's phase, not accumulated per interval.
    ///
    /// This shape matters. Two frames landing in the same connection event, then a 3-interval pause,
    /// is exactly the burst a consumer that assumes evenly-paced arrivals gets wrong, and a uniform
    /// range can never produce it.
    struct FrameCadence: Sendable, Equatable {
        /// One BLE connection interval.
        var interval: DelayRange
        /// How many intervals a gap spans, as relative weights indexed by that count: element 0 is
        /// the chance two frames share a connection event, element 1 one interval, and so on.
        var intervalWeights: [Double]

        static let none = FrameCadence(interval: .none, intervalWeights: [])

        /// Measured distribution above. Weights are relative, so they need not sum to 1.
        static func realistic(scale: Double = 1.0) -> FrameCadence {
            FrameCadence(
                interval: DelayRange.milliseconds(12, 18).scaled(by: scale),
                intervalWeights: [0.038, 0.629, 0.295, 0.038]
            )
        }

        func sample(using generator: inout some RandomNumberGenerator) -> Duration {
            let total = intervalWeights.reduce(0, +)
            guard interval.upper > .zero, total > 0 else { return .zero }

            var remaining = Double.random(in: 0..<total, using: &generator)
            var count = intervalWeights.count - 1
            for (index, weight) in intervalWeights.enumerated() {
                remaining -= weight
                if remaining < 0 {
                    count = index
                    break
                }
            }
            guard count > 0 else { return .zero }
            return interval.sample(using: &generator) * count
        }
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
    /// Every figure below was **measured directly** on real hardware on 2026-07-31, against a
    /// `debug_log` recording milliseconds, with the app timing its own spans on a `ContinuousClock`
    /// (tags `conn-phase` and `hist-time`). Nine connect/login sequences and five full 21-record
    /// history dumps.
    ///
    /// This replaced an earlier set inferred from second-resolution logs by counting how often a
    /// pair of rows straddled a second boundary. That method gives a centre and no spread at all,
    /// and it turned out to be wrong by a factor of three on the phases that dominate: measured
    /// `connect` is 2.2-4.6s against an assumed 0.6-1.0s, `initializeSession` 1.1-1.3s against an
    /// assumed 0.2-0.3s. Bringing a session up really costs about four seconds, not one.
    ///
    /// A cross-check that the legs are self-consistent: `lock` performs a write plus a read-back and
    /// measures 173-224ms (p50 186), against `write` p50 118 + `read` p50 62 = 180.
    ///
    /// ## `read` vs `write` is really fresh-link vs settled-link
    ///
    /// Worth knowing before trusting either figure. `write` (115-152ms) was measured from LED writes
    /// during pairing, and `read` (53-79ms) from the cheap history check mid-session -- so the two
    /// samples differ in *when* they ran as much as in what they did, and `read` is within noise of
    /// `settledWrite` (54-79ms).
    ///
    /// Probing 0x13/0x14/0x15/0xFE on 2026-07-31 separated the two, because those commands ran in a
    /// single sequence that crossed the boundary. A *read*-shaped command (0x14) on a fresh link cost
    /// 116-151ms, and a *write*-shaped one (0xFE) on a settled link cost 58-89ms -- the opposite way
    /// round from what an intrinsic read/write difference would predict. The direction of the command
    /// does not matter; the age of the connection does.
    ///
    /// `read` and `settledWrite` are therefore very likely the same quantity measured twice, and
    /// could be merged. Left separate for now because collapsing them means re-deciding what every
    /// existing caller should charge, which is a bigger change than this one.
    ///
    /// Scale the profile down rather than editing the figures, so the relative costs stay in
    /// proportion.
    struct Latency: Sendable {
        /// Scan, connect, then discover services and characteristics. Measured 2232-4550ms (n=9),
        /// and much the slowest step by a wide margin. The spread is almost entirely in finding the
        /// device: scan+link alone ranged 1182-3306ms, while characteristic discovery was steady at
        /// 1047-1197ms and waiting for the radio to power up was 0-46ms.
        var connect: DelayRange
        /// Password write plus the device's reply plus the accept decision. Measured 239-270ms (n=9),
        /// which splits 177-210 / 58-61 / 1-2.
        var login: DelayRange
        /// Subscribing to each of the five notification characteristics in turn. Measured 595-715ms
        /// (n=9), so roughly 125ms per subscription.
        var enableNotifications: DelayRange
        /// Time sync, status refresh, auto-pause normalisation, device info and the health check.
        /// Measured 1137-1289ms (n=9).
        var initializeSession: DelayRange
        /// A command write and its acknowledgement (auto-pause, lock, brightness, colour). Measured
        /// 115-152ms (n=9). A write that also reads back to verify costs this *plus* `read`.
        var write: DelayRange
        /// The same command round trip, but on a link that has been up for a while rather than one
        /// just established. Measured 54-79ms (n=6) -- roughly **half** `write`.
        ///
        /// This split is not a property of any particular command, it is a property of the link, and
        /// it showed up independently three times on 2026-07-31: the password reset's 0x30 write cost
        /// 54-79ms on a settled session against the rotation's 113-144ms on the pairing probe, their
        /// confirming re-logins split 60-61 against 120-123, and login overall measured 59ms
        /// established against 245ms at connect. Presumably the connection parameters the central
        /// negotiates on a fresh link differ from the settled ones.
        ///
        /// Kept as a separate figure rather than widening `write` to 54-152ms, because the two modes
        /// are bimodal and predictable from context, not one broad distribution.
        var settledWrite: DelayRange
        /// A characteristic read (lock state, double-tap parameters, device info). Measured 53-79ms
        /// (n=117), from the cheap single-event check each history fetch begins with.
        var read: DelayRange
        /// The fixed cost of a history fetch before records start arriving. Measured 30-240ms (n=25),
        /// and genuinely **bimodal** rather than merely broad: a fetch issued right after connect came
        /// back in 30-45ms, one issued mid-session in 155-240ms. Modelled as the full span, since the
        /// mock has no notion of how long the session has been up.
        var historyRead: DelayRange
        /// How records arrive once the stream starts. See `FrameCadence` -- gaps quantise to whole
        /// BLE connection intervals rather than varying smoothly, so this is not a plain range.
        var historyFrames: FrameCadence
        /// How long the device spends erasing flash and rebooting after a factory reset, during
        /// which it is unreachable and then briefly still honours its **old** password. Measured
        /// once at 13,544ms end to end (0xFF sent to the device reappearing on the default), with
        /// the old PIN still accepted 2s in and rejected by 9s.
        ///
        /// One sample, so treated as a single figure rather than a fitted range -- widen it when
        /// there is more than one reset to average. Three orders of magnitude above every other
        /// operation here, which is the point: nothing else makes the device vanish for that long.
        var factoryResetReboot: DelayRange

        /// Everything answers immediately. The default, and what every caller got before `Latency`
        /// existed.
        static let instant = Latency(
            connect: .none,
            login: .none,
            enableNotifications: .none,
            initializeSession: .none,
            write: .none,
            settledWrite: .none,
            read: .none,
            historyRead: .none,
            historyFrames: .none,
            factoryResetReboot: .none
        )

        /// The measured timings, as ranges, multiplied by `scale`. Use a small scale in CI (`0.1`
        /// keeps a whole workflow well under a second) -- the operations still genuinely suspend and
        /// interleave, which is what catches ordering bugs; the wall-clock size is not the point.
        ///
        /// Each range is the observed min-to-max, not a percentile band: the samples came from a
        /// single device on a single afternoon, so the tails are more likely under-explored than
        /// over-stated. Widen them if a second device disagrees.
        ///
        /// A whole `.realistic()` session is roughly four seconds of connect, notifications and
        /// initialisation before the first history record arrives, which is why CI uses a scale.
        static func realistic(scale: Double = 1.0) -> Latency {
            func range(_ lower: Double, _ upper: Double) -> DelayRange {
                DelayRange.milliseconds(lower, upper).scaled(by: scale)
            }
            return Latency(
                connect: range(2232, 4550),
                login: range(239, 270),
                enableNotifications: range(595, 715),
                initializeSession: range(1137, 1289),
                write: range(115, 152),
                settledWrite: range(54, 79),
                read: range(53, 79),
                historyRead: range(30, 240),
                historyFrames: .realistic(scale: scale),
                factoryResetReboot: range(13_544, 13_544)
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
        /// Whether the two invented segments below are put in the history log at init.
        ///
        /// On by default, because a test asking this device for history wants some. Off for a
        /// manual-mode session, which is the one caller whose history reaches a **real** database:
        /// those two would be ingested as segments the user never worked, against faces they never
        /// flipped, and land in their totals and their Report as fact.
        var seedsSampleHistory: Bool
        /// Whether a history fetch ends with the **running** segment, the way a real one does.
        ///
        /// `docs/timeflip.md` §5: "the last frame in every history dump is the current interval
        /// snapshot, even when paused". This device has never done that -- its history holds only
        /// finished segments -- which is a standing parity gap, off by default here so the suite
        /// that grew up around the old behaviour keeps testing what it was written against.
        ///
        /// Manual mode turns it on because without it a running segment exists nowhere but in
        /// memory until something closes it, and quitting the app is the documented way *out* of
        /// manual mode -- so every session would lose whatever it was timing at the moment the user
        /// left. With it on, the growing frame is re-reported on each refresh and
        /// `recordDeviceEvent` keeps the open row up to date on disk.
        var reportsOpenSegment: Bool
        /// Seed for the delay sampler. Fixed by default so a run is reproducible; vary it only to
        /// deliberately explore different draws.
        var randomSeed: UInt64

        init(
            initialFaceID: UInt8 = Constants.defaultInitialFaceID,
            batteryLevel: UInt8 = Constants.defaultBatteryLevel,
            systemState: TimeFlipSystemState = .ok,
            isPaused: Bool = true,
            isLocked: Bool = false,
            isInitiallyPaired: Bool = true,
            autoPauseMinutes: UInt16 = 0,
            emitInitialStatus: Bool = true,
            latency: Latency = .instant,
            seedsSampleHistory: Bool = true,
            reportsOpenSegment: Bool = false,
            randomSeed: UInt64 = 0x5EED
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
            self.seedsSampleHistory = seedsSampleHistory
            self.reportsOpenSegment = reportsOpenSegment
            self.randomSeed = randomSeed
        }
    }

    private struct ActiveSession {
        /// Claimed when the segment opens, so it keeps one identity from open to close.
        var eventNumber: UInt32
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
    /// Draws every simulated delay. Seeded from `Configuration.randomSeed`.
    private var delayGenerator: SeededGenerator
    /// Every delay actually drawn, in order -- lets a test assert the spread and the per-record count
    /// rather than just the elapsed total.
    private(set) var sampledDelays: [Duration] = []

    /// Discards the delays drawn so far, so a test can measure one phase of a session without the
    /// setup that preceded it (e.g. the cost of a password rotation, not the login that enabled it).
    func clearSampledDelays() {
        sampledDelays.removeAll()
    }

    /// A factory reset the device has accepted but not finished applying.
    ///
    /// The real device erases flash and reboots asynchronously, and the gap between the two is not
    /// an implementation detail to smooth over -- it is the behaviour worth modelling. Confirmed on
    /// hardware 2026-07-31: two seconds after 0xFF the cube **still accepted the old PIN**, and only
    /// by nine seconds was it rejected and the default accepted.
    private struct PendingFactoryReset {
        /// When the reboot finishes and the wipe becomes observable.
        var completesAt: ContinuousClock.Instant
        /// The password in force when 0xFF was sent, still honoured until then.
        var oldPassword: String
    }
    private var pendingFactoryReset: PendingFactoryReset?

    private var brightnessPercent: UInt8 = 100
    private var blinkIntervalSeconds: UInt8 = 5
    private var doubleTapParameters: DoubleTapParameters = .default
    /// Per-face task config (0x13/0x14). Absent means the face is `.simple` with no limit, which is
    /// what a device reports for a face that has never been configured.
    private var faceTaskParameters: [UInt8: FaceTaskParameters] = [:]
    /// When each face's timer started, on the *device's* clock, so 0x14's elapsed field advances
    /// with `setDeviceTime` instead of the host's wall clock.
    private var faceTaskStartedAt: [UInt8: Date] = [:]
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
        self.delayGenerator = SeededGenerator(seed: configuration.randomSeed)
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
        if configuration.seedsSampleHistory {
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
        }
        if TimeFlipConstants.isValidFaceID(initialFaceID) {
            self.activeSession = ActiveSession(
                eventNumber: allocateEventNumber(),
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

    /// Suspends for a value drawn from `range`, so the mock answers on the same sort of timescale a
    /// device on a radio link does, and varies the way one does. No-op under `.instant` (the default).
    ///
    /// A rejected command still costs time: the real device is asked and answers no, so the caller
    /// waits either way. Latency is therefore charged *before* the guards, not after them.
    @discardableResult
    private func waitForRadio(_ range: DelayRange) async -> Duration {
        guard range.upper > .zero else { return .zero }
        return await suspend(for: range.sample(using: &delayGenerator))
    }

    /// The frame-arrival counterpart, drawing from a quantised cadence rather than a flat range.
    @discardableResult
    private func waitForFrame(_ cadence: FrameCadence) async -> Duration {
        guard cadence.interval.upper > .zero else { return .zero }
        return await suspend(for: cadence.sample(using: &delayGenerator))
    }

    private func suspend(for duration: Duration) async -> Duration {
        sampledDelays.append(duration)
        // A zero draw is real -- two frames sharing one connection event -- and is recorded as a
        // sample, but there is nothing to sleep for.
        if duration > .zero {
            try? await Task.sleep(for: duration)
        }
        return duration
    }

    // MARK: - Session management (parity with real device)

    func connect() async -> Bool {
        // No transport, but a real connect is scan + connect + service/characteristic discovery.
        await waitForRadio(configuration.latency.connect)
        // A reconnect is the usual way the app first observes a completed reset: it drops the link
        // when 0xFF goes out and comes back to find a factory-default device.
        applyFactoryResetIfDue()
        logger.debug("Mock connect")
        return true
    }

    func disconnect() async {
        stop()
    }

    func login(password: String) async -> Bool {
        await waitForRadio(configuration.latency.login)
        return applyLogin(password: password)
    }

    /// The login decision with no radio cost attached, so a caller that has already charged the
    /// appropriate round trip doesn't pay twice.
    ///
    /// Needed because `latency.login` is the *connect-time* figure (239-270ms), and the confirming
    /// re-login inside a password change happens on an already-open link, where it measured 120-123ms
    /// during pairing and 60-61ms on a settled session.
    private func applyLogin(password: String) -> Bool {
        applyFactoryResetIfDue()

        // Mid-reboot after a factory reset: the device has not applied the wipe yet, so it still
        // answers to the password it had when 0xFF was sent, and does *not* yet answer to the
        // default. That asymmetry is what makes gating confirmation on the default password a
        // correct test -- accepting any successful login here would confirm the reset seconds
        // before it happened.
        if let pending = pendingFactoryReset {
            guard password == pending.oldPassword else {
                logger.warning("Mock login rejected (device still rebooting after factory reset)")
                return false
            }
            isLoggedIn = true
            logger.debug("Mock login accepted on the pre-reset password; reboot still in progress")
            return true
        }

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

    /// See `TimeFlipDevice.deviceName`. Whatever the configuration was given, or whatever a
    /// `setDeviceName` write has since changed it to -- the mock stands in for the cube, so a
    /// rename has to be visible here the way it is on real hardware.
    var deviceName: String? {
        mockDeviceName
    }

    /// No radio, so no peripheral and no identifier. `confirmConnected` keeps whatever is already
    /// stored when this is nil, which is what a mock run wants: it must not overwrite a real
    /// device's uuid, and it has nothing truthful to put there.
    var deviceIdentifier: String? { nil }

    func snapshot() -> TimeFlipDeviceSnapshot {
        applyFactoryResetIfDue()
        return stateWithUpdatedDeviceTime()
    }

    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry] {
        applyFactoryResetIfDue()
        let entries = fetchHistorySync(startingFrom: eventNumber)
        let latency = configuration.latency
        // The command round trip before any record arrives -- paid even when there is nothing new.
        await waitForRadio(latency.historyRead)
        // Then one gap *per record*, because the device streams them frame by frame. Each is drawn
        // independently from the connection-interval cadence, so a fifty-record backlog is fifty
        // draws and lands in bursts, the way a real transfer does, rather than at a clean tempo.
        for _ in entries {
            await waitForFrame(latency.historyFrames)
        }
        return entries
    }

    func readLastEvent() async -> TimeFlipHistoryEntry? {
        // The cheap single-event check, which is a characteristic read rather than a stream: it pays
        // `read`, not the stream's command round trip.
        await waitForRadio(configuration.latency.read)
        applyFactoryResetIfDue()
        // The device's *current* record, which is the running segment when there is one -- the same
        // frame `fetchHistory` ends on, so the ingestor's cheap check can recognise the segment it
        // already has on record and refresh its duration without pulling the whole stream.
        if configuration.reportsOpenSegment, let activeSession {
            return openSegmentFrame(for: activeSession, at: deviceTime())
        }
        return history.max { ($0.eventNumber ?? 0) < ($1.eventNumber ?? 0) }
    }

    // MARK: - Discovery and pairing (parity with the real device)

    /// Devices a scan will report. Set this to stage what the pairing UI should find -- an empty list
    /// models "no cube in range", which is a case worth being able to test.
    var discoverableDevices: [DiscoveredBLEDevice] = [
        DiscoveredBLEDevice(id: UUID(uuidString: "5EED0000-0000-0000-0000-00000000C0BE")!, name: "TimeFlip v2.0")
    ]
    /// Mirrors `TimeFlipBLEDevice`'s callbacks so the same UI code can drive either.
    var onDeviceDiscovered: ((DiscoveredBLEDevice) -> Void)?
    var onDiscoveryScanStopped: (() -> Void)?
    private(set) var isDiscoveryScanning = false
    private var cancelledConnectionAttempt = false

    /// Reports each staged device through `onDeviceDiscovered`, one at a time, taking radio time
    /// between them -- results trickle in on a real scan rather than arriving as a complete list.
    ///
    /// `filterToTimeFlip` mirrors the real parameter: when true, only devices named like a TimeFlip
    /// are reported, so the "show everything" pairing path can be exercised too.
    func startDiscoveryScan(filterToTimeFlip: Bool) async {
        isDiscoveryScanning = true
        cancelledConnectionAttempt = false
        for candidate in discoverableDevices {
            guard isDiscoveryScanning else { return }
            if filterToTimeFlip, !candidate.name.lowercased().contains("timeflip") { continue }
            await waitForRadio(configuration.latency.read)
            guard isDiscoveryScanning else { return }
            onDeviceDiscovered?(candidate)
        }
    }

    func stopDiscoveryScan() {
        guard isDiscoveryScanning else { return }
        isDiscoveryScanning = false
        onDiscoveryScanStopped?()
    }

    /// Connect to a scanned device and log in, reporting the same outcomes the real driver does so a
    /// caller has to handle `wrongPassword` and `notTimeFlip` distinctly rather than treating every
    /// failure alike.
    func connectToDiscoveredDevice(id: UUID, password: String) async -> DeviceConnectOutcome {
        stopDiscoveryScan()
        guard discoverableDevices.contains(where: { $0.id == id }) else { return .notTimeFlip }
        guard await connect() else { return .failed }
        if cancelledConnectionAttempt { return .cancelled }
        guard await login(password: password) else { return .wrongPassword }
        if cancelledConnectionAttempt { return .cancelled }
        await enableNotifications()
        pair()
        return .connected
    }

    /// Abandons an in-flight connection attempt. Checked at each await point in
    /// `connectToDiscoveredDevice`, so a cancel lands between steps the way it does on real hardware
    /// rather than tearing down mid-operation.
    func cancelConnectionAttempt() {
        cancelledConnectionAttempt = true
        stopDiscoveryScan()
    }

    /// Sets a new device password (command 0x30) and confirms it by re-logging in with it, returning
    /// the new password, or `nil` if anything failed.
    ///
    /// The confirming re-login is the part worth modelling: `TimeFlipBLEDevice` will not report success
    /// -- and the caller must not store the new password -- until the device has actually accepted it.
    /// A mock that just swapped the password and returned it would let a caller pass while skipping the
    /// step that stops the device being left on a password nobody holds.
    ///
    /// In Developer Mode the real driver rotates to a fixed `123456` rather than a random value, so the
    /// mock does the same and stays predictable for tests.
    /// Timing: measured 236-266ms end to end (n=6), splitting 113-144ms for the 0x30 write and
    /// 120-123ms for the confirming re-login. Both legs cost a `write` rather than one costing a
    /// full `login`, because rotation only ever runs inside the pairing flow, on the freshly
    /// connected probe -- a routine reconnect reuses the stored password and never gets here.
    func rotateDevicePassword() async -> String? {
        await waitForRadio(configuration.latency.write)
        guard isLoggedIn else { return nil }
        let newPassword = DeveloperMode.isEnabled
            ? "123456"
            : String(format: "%06d", Int.random(in: 0...999_999, using: &delayGenerator))
        devicePassword = newPassword
        // Confirm the way the real one does, by actually logging in again.
        await waitForRadio(configuration.latency.write)
        guard applyLogin(password: newPassword) else { return nil }
        logger.notice("Mock device password rotated and confirmed")
        return newPassword
    }

    /// Puts the password back to the factory default (command 0x30) and confirms it with a real
    /// re-login, so "Forget Device" can't leave the device on a password nobody has.
    ///
    /// This is the *password* reset, not a factory reset -- no history is touched and the device stays
    /// paired. `factoryReset` is deliberately not modelled; see `docs/TODO-mock-device-parity.md`.
    /// Timing: measured 116-141ms end to end (n=6), splitting 54-79ms for the 0x30 write and
    /// 60-61ms for the confirming re-login -- about half the rotation's cost. Both legs are charged
    /// `settledWrite`, not `write`, because Forget Device runs on a session that has been up a
    /// while, where every round trip is roughly half what it costs on a fresh link.
    @discardableResult
    func resetDevicePasswordToDefault() async -> Bool {
        await waitForRadio(configuration.latency.settledWrite)
        guard isLoggedIn else { return false }
        devicePassword = TimeFlipConstants.defaultPassword
        await waitForRadio(configuration.latency.settledWrite)
        guard applyLogin(password: TimeFlipConstants.defaultPassword) else { return false }
        logger.notice("Mock device password reset to default and confirmed")
        return true
    }

    // MARK: - Task/pomodoro parameters and device name (0x13, 0x14, 0x15, 0xFE)

    /// Sets a face's task parameters (0x13).
    @discardableResult
    func setFaceTaskParameters(_ params: FaceTaskParameters) async -> Bool {
        await waitForRadio(configuration.latency.write)
        guard isLoggedIn else { return false }
        guard TimeFlipConstants.isValidFaceID(params.faceID) else { return false }
        // Stored without `elapsedSeconds`: 0x13 has no field for it, so a write cannot set it, and
        // keeping a caller-supplied value would let a test "read back" something never sent.
        faceTaskParameters[params.faceID] = FaceTaskParameters(
            faceID: params.faceID,
            mode: params.mode,
            limitSeconds: params.limitSeconds
        )
        faceTaskStartedAt[params.faceID] = deviceTime()
        appendEventLog("face_task face=\(params.faceID) mode=\(params.mode.rawValue) limit=\(params.limitSeconds)")
        return true
    }

    /// Reads a face's task parameters (0x14).
    ///
    /// `elapsedSeconds` is computed from the device's own clock rather than stored, so it advances
    /// as `setDeviceTime` moves -- a caller polling a running countdown sees it count, which is the
    /// only reason the field exists on the wire.
    func readFaceTaskParameters(faceID: UInt8) async -> FaceTaskParameters? {
        // `write`, not `read`, despite the name: 0x14 is a command (write the opcode, then read the
        // command-result characteristic), not a plain characteristic read, and it measured
        // 116-151ms on hardware -- squarely `write`'s 115-152ms range.
        await waitForRadio(configuration.latency.write)
        guard isLoggedIn else { return nil }
        guard TimeFlipConstants.isValidFaceID(faceID) else { return nil }
        let stored = faceTaskParameters[faceID] ?? .simple(faceID: faceID)
        let elapsed = faceTaskStartedAt[faceID].map { max(0, deviceTime().timeIntervalSince($0)) } ?? 0
        return FaceTaskParameters(
            faceID: stored.faceID,
            mode: stored.mode,
            limitSeconds: stored.limitSeconds,
            elapsedSeconds: UInt32(elapsed)
        )
    }

    /// Sets the advertised device name (0x15), rejecting anything the real device would.
    @discardableResult
    func setDeviceName(_ name: String) async -> Bool {
        await waitForRadio(configuration.latency.write)
        guard isLoggedIn else { return false }
        guard let ascii = name.data(using: .ascii), !ascii.isEmpty,
              ascii.count <= TimeFlipBLEDevice.maximumDeviceNameLength else {
            return false
        }
        mockDeviceName = name
        appendEventLog("device_name=\(name)")
        return true
    }

    /// The name the device advertises. Mirrors the real device's Generic Access name, which is what
    /// a discovery scan shows.
    /// The name the mock cube is carrying. Surfaced through the protocol's optional `deviceName`
    /// just below, since a real peripheral has none until it is known. Seeded with what the
    /// hardware ships advertising.
    private(set) var mockDeviceName: String = "TimeFlip v2.0"

    /// Resets every face's task info (0xFE), and nothing else.
    @discardableResult
    func resetTaskInfoToDefault() async -> Bool {
        await waitForRadio(configuration.latency.write)
        guard isLoggedIn else { return false }
        // Deliberately narrow. A test asserting that 0xFE is *not* 0xFF is the point of modelling
        // it: history, pairing, password, colours and the name all have to survive.
        faceTaskParameters.removeAll()
        faceTaskStartedAt.removeAll()
        appendEventLog("task_info_reset")
        return true
    }

    /// Erases everything on the device (command 0xFF) and reboots it.
    ///
    /// Returns whether the command was **sent**, never whether the reset happened -- matching
    /// `TimeFlipBLEDevice`, which cannot do better: the device writes no fresh command result for
    /// 0xFF (the characteristic still holds the *previous* command's response) and then reboots. So
    /// there is nothing synchronous to confirm against, and the caller must confirm out of band by
    /// the device reappearing on the factory-default password.
    ///
    /// The reboot is deliberately *not* awaited here, because the real one isn't either. What the
    /// mock reproduces is the window it opens:
    ///
    ///  - the 0xFF write is cheap (78ms measured) and unacknowledged
    ///  - for `latency.factoryResetReboot` afterwards the device still answers to its **old**
    ///    password and not to the default (measured: old PIN accepted at +2s, rejected by +9s)
    ///  - only then does the password revert, history clear, the event counter restart and the
    ///    device return to never-paired
    ///
    /// A caller that treats the write, or an immediate re-login, as proof of a wipe will therefore
    /// fail against this mock exactly as it would against hardware.
    @discardableResult
    func factoryReset() async -> Bool {
        // Charged before the guard: a rejected command still costs a round trip.
        await waitForRadio(configuration.latency.settledWrite)
        guard isLoggedIn else { return false }

        let reboot = configuration.latency.factoryResetReboot.sample(using: &delayGenerator)
        pendingFactoryReset = PendingFactoryReset(
            completesAt: ContinuousClock().now + reboot,
            oldPassword: devicePassword
        )
        logger.notice("Mock factory reset (0xFF) sent; device rebooting for \(reboot)")
        // Under `.instant` the window is zero-width, so the wipe is already due and the very next
        // operation observes it -- no waiting, and no behaviour that only appears with latency on.
        applyFactoryResetIfDue()
        return true
    }

    /// Ends a pending reboot now rather than waiting the measured 13.5 seconds out.
    func completeFactoryResetReboot() {
        guard pendingFactoryReset != nil else { return }
        pendingFactoryReset?.completesAt = ContinuousClock().now
        applyFactoryResetIfDue()
    }

    /// Applies a pending wipe once its reboot has elapsed.
    ///
    /// Lazy rather than scheduled on a `Task`: a timer would make the moment the state flips
    /// non-deterministic, and a test asserting "the old PIN still works" would be racing it. Every
    /// operation that observes device state calls this first, so the wipe lands at a well-defined
    /// point -- the next thing the caller does after the reboot is up.
    private func applyFactoryResetIfDue() {
        guard let pending = pendingFactoryReset, ContinuousClock().now >= pending.completesAt else {
            return
        }
        pendingFactoryReset = nil

        devicePassword = TimeFlipConstants.defaultPassword
        history = []
        // Restarts at 1, which is why AppDataStore derives its ingest position from device_event
        // instead of storing a high-water mark that a reset would strand above the live counter.
        //
        // One, not zero, and not merely to match the hardware (observed going nil -> 1 -> 2 after a
        // real reset): `TimeFlipBLEDevice.streamHistory` treats an event number of 0 as the
        // end-of-stream sentinel, so a device that allocated 0 would terminate its own history
        // stream on its first record.
        nextEventNumber = 1
        // A rebooted cube is still lying on a face, so it starts timing again straight away -- but
        // that segment isn't an *event* until a flip closes it. Hence the familiar post-reset
        // behaviour of the app showing an idle, frozen duration until the cube is first moved:
        // correct, not a bug. Leaving no session at all would lose the first segment entirely.
        beginSession(faceID: state.faceID, paused: state.isPaused, at: deviceTime())
        faceColors = [:]
        brightnessPercent = 100
        blinkIntervalSeconds = 5
        doubleTapParameters = .default
        // Ends never-paired, not reconnected: the app drops the connection and the reset is
        // confirmed by a default-password login, which is deliberately not treated as a pairing.
        isPaired = false
        isLoggedIn = false
        notificationsEnabled = false
        logger.notice("Mock factory reset applied; device is back to factory settings")
    }

    /// The device's own clock (command 0x07), which drifts from the host's until `initializeSession`
    /// syncs it -- `setDeviceTime` is what moves it in a test.
    ///
    /// Returns `nil` when not logged in, matching `TimeFlipBLEDevice.readDeviceTime`: the real device
    /// won't answer a command from an unauthenticated session, and a caller that treats a `nil` here
    /// as "clock at zero" rather than "not logged in yet" is a bug worth catching in a test.
    func readDeviceTime() async -> Date? {
        await waitForRadio(configuration.latency.read)
        guard isLoggedIn else { return nil }
        return deviceTime()
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
        var frames = history
        // Last, and only when configured to: a real dump ends with the current interval snapshot
        // (`docs/timeflip.md` §5), and the ingestor reads the final frame as the open segment.
        if configuration.reportsOpenSegment, let activeSession {
            frames.append(openSegmentFrame(for: activeSession, at: deviceTime()))
        }
        guard let eventNumber else { return frames }
        return frames.filter { entry in
            guard let entryNumber = entry.eventNumber else { return false }
            return entryNumber >= eventNumber
        }
    }

    func flip(to faceID: UInt8) {
        guard !state.isLocked else {
            appendEventLog("flip_ignored_locked face=\(faceID)")
            return
        }
        // The stored bound, not the cube's: this is the one entry point manual mode drives, and the
        // face it flips to is 13. Every other guard in here stays at 12, because they emulate what
        // hardware does -- lighting a face, waking on a double tap -- and there is no thirteenth
        // face to do any of that to.
        guard TimeFlipConstants.isValidStoredFaceID(faceID) else {
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
        history.append(openSegmentFrame(for: activeSession, at: date))
        self.activeSession = nil
    }

    private func beginSession(faceID: UInt8, paused: Bool, at date: Date) {
        guard TimeFlipConstants.isValidStoredFaceID(faceID) else { return }
        // The number is claimed when the segment opens, not when it closes, so the same segment
        // carries one identity throughout. That is what lets the open frame below be re-reported as
        // it grows: `AppDataStore.recordDeviceEvent` matches on (event_number, start_epoch) and
        // updates the row in place, where a fresh number each fetch would insert a new row per
        // refresh and record one segment several times over.
        activeSession = ActiveSession(
            eventNumber: allocateEventNumber(),
            faceID: faceID,
            start: date,
            isPaused: paused
        )
    }

    /// The running segment as a history frame, with its duration as of `date`.
    ///
    /// **Whole seconds**, because that is the only resolution a real device has: the history frame's
    /// duration field is a count of seconds (`docs/TimeFlip2 BLE Protocol v4.3.md`), so a real
    /// segment never arrives with a fraction on it and `device_event.duration_seconds` never held
    /// one. Subtracting two `Date`s does, and manual mode is the first path where those reach the
    /// database -- a segment closed a moment after it opened was recording durations like
    /// `0.0000919103622437` seconds.
    ///
    /// To the **nearest** second rather than truncated. Truncating is the tempting reading -- a
    /// counter reports the seconds it has ticked through -- but what is being recorded here is
    /// elapsed wall time, and dropping the remainder loses up to a second from every segment in the
    /// same direction. Those segments feed the daily totals, so the loss accumulates across a day
    /// rather than cancelling out. Nearest is unbiased.
    private func openSegmentFrame(for session: ActiveSession, at date: Date) -> TimeFlipHistoryEntry {
        TimeFlipHistoryEntry(
            eventNumber: session.eventNumber,
            faceID: session.faceID,
            startedAt: session.start,
            duration: max(0, date.timeIntervalSince(session.start)).rounded(),
            isPaused: session.isPaused
        )
    }
}

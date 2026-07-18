import Foundation

@MainActor
protocol TimeFlipEventSource: AnyObject {
    var events: AsyncStream<TimeFlipEvent> { get }

    func start()
    func stop()
}

@MainActor
protocol TimeFlipDevice: TimeFlipEventSource {
    func snapshot() -> TimeFlipDeviceSnapshot
    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry]
    /// Cheap single-frame read of the device's actual current record (history characteristic
    /// command 0x01, sentinel value 0xFFFFFFFF) without pulling the full history stream. Per the
    /// vendor spec this returns a complete History block (event number, facet, start time,
    /// duration) for the device's last event, not just the bare number, so the caller can refresh
    /// its stored duration for that entry even when nothing else has changed. Returns nil if the
    /// read fails or times out.
    func readLastEvent() async -> TimeFlipHistoryEntry?
}

/// Session-layer operations that mirror the real device's connection/login/notify flow.
@MainActor
protocol TimeFlipSessionManaging: TimeFlipDevice {
    /// Connect to the device transport (BLE in production, no-op for mock).
    func connect() async -> Bool
    /// Disconnect from the device transport.
    func disconnect() async
    /// Send the password to the device. Returns false if authentication fails.
    func login(password: String) async -> Bool
    /// Subscribe to notification characteristics (facet/event/history) on the device.
    func enableNotifications() async
    /// Host-driven initialization: synchronize time and emit status so the app can seed state.
    func initializeSession(hostTime: Date, desiredAutoPauseMinutes: UInt16) async
    /// Update the LED color for a facet (command 0x11). No-op if unsupported.
    func setFacetColor(facetID: UInt8, components: ColorComponents) async
    /// Configure auto-pause duration (command 0x05). 0 disables auto-pause.
    func setAutoPause(minutes: UInt16) async
    /// Refresh Device Information service fields (manufacturer/model/firmware/hardware/system ID).
    func refreshDeviceInfo() async
    // swiftlint:disable identifier_name
    /// Toggle pause mode on the device (cmd 0x06); parameter name mirrors device payload.
    func setPause(_ on: Bool) async
    /// Toggle lock mode on the device (cmd 0x04); parameter name mirrors device payload.
    func setLock(_ on: Bool) async
    // swiftlint:enable identifier_name
    /// Reads the device's current lock state fresh (status command 0x10) and returns it. Used
    /// right before a lock/unlock toggle so the decision is based on the device's actual state,
    /// not a possibly-stale cached value.
    func refreshLockState() async -> Bool
    /// Tune LED brightness 1–100 %.
    func setLEDBrightness(percent: UInt8) async
    /// Tune LED blink interval 5–60 seconds (cmd 0x0A).
    func setBlinkInterval(seconds: UInt8) async
    /// Set accelerometer double-tap parameters (cmd 0x16).
    func setDoubleTapParameters(_ params: DoubleTapParameters) async
    /// Read accelerometer double-tap parameters (cmd 0x17).
    func readDoubleTapParameters() async -> DoubleTapParameters?
}

@MainActor
protocol TimeFlipMockControlling: AnyObject {
    var isPaired: Bool { get }
    var lastEventNumber: UInt32? { get }

    func pair()
    func forget()
    func flip(to facetID: UInt8)
    func doubleTap(targetFacetID: UInt8?)
    func setPaused(_ paused: Bool)
    func setLocked(_ locked: Bool)
    func setAutoPause(minutes: UInt16)
    func setBatteryLevel(_ level: UInt8)
    func setSystemState(_ state: TimeFlipSystemState)
    func setDeviceTime(_ date: Date)
    func appendEventLog(_ message: String)
    func snapshot() -> TimeFlipDeviceSnapshot
}

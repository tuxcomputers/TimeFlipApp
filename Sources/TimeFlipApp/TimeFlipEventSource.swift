import Foundation

@MainActor
protocol TimeFlipEventSource: AnyObject {
    var events: AsyncStream<TimeFlipEvent> { get }

    func start()
    func stop()
}

@MainActor
protocol TimeFlipDevice: TimeFlipEventSource {
    /// The name the cube itself is carrying -- its GAP Device Name, `0x2A00`, which is what command
    /// `0x15` writes.
    ///
    /// Read through `CBPeripheral.name` rather than by discovering the characteristic: Apple does
    /// not expose the Generic Access service (`0x1800`) to apps at all, so there is nothing to
    /// discover and `name` is the platform's own reading of `0x2A00`. `nil` before a peripheral is
    /// known.
    ///
    /// Not part of `TimeFlipDeviceSnapshot`, which is per-event device *state*; this changes only
    /// when the cube is renamed.
    var deviceName: String? { get }

    func snapshot() -> TimeFlipDeviceSnapshot
    func fetchHistory(startingFrom eventNumber: UInt32?) async -> [TimeFlipHistoryEntry]
    /// Cheap single-frame read of the device's actual current record (history characteristic
    /// command 0x01, sentinel value 0xFFFFFFFF) without pulling the full history stream. Per the
    /// vendor spec this returns a complete History block (event number, face, start time,
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
    /// Subscribe to notification characteristics (face/event/history) on the device.
    func enableNotifications() async
    /// Host-driven initialization: synchronize time and emit status so the app can seed state.
    func initializeSession(hostTime: Date, desiredAutoPauseMinutes: UInt16) async
    /// Update the LED color for a face (command 0x11). No-op if unsupported.
    func setFaceColor(faceID: UInt8, components: ColorComponents) async
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
    /// Erase everything on the device and reboot it (cmd 0xFF).
    ///
    /// Returns whether the command was *sent*, not whether the reset happened -- the device
    /// acknowledges nothing and reboots asynchronously, so the wipe can only be confirmed
    /// out-of-band by the device reappearing on the factory-default password. On the protocol
    /// rather than only on `TimeFlipBLEDevice` so the mock can stand in for it; the caller has no
    /// business knowing which implementation it holds.
    @discardableResult
    func factoryReset() async -> Bool
    /// Set a face's task/pomodoro parameters (cmd 0x13).
    @discardableResult
    func setFaceTaskParameters(_ params: FaceTaskParameters) async -> Bool
    /// Read a face's task parameters, including elapsed timer seconds (cmd 0x14).
    func readFaceTaskParameters(faceID: UInt8) async -> FaceTaskParameters?
    /// Set the device's advertised name, 18 ASCII characters maximum (cmd 0x15).
    @discardableResult
    func setDeviceName(_ name: String) async -> Bool
    /// Reset every face's task info to default (cmd 0xFE). Narrower than `factoryReset`: history,
    /// pairing, password, colours and name all survive.
    @discardableResult
    func resetTaskInfoToDefault() async -> Bool
}

@MainActor
protocol TimeFlipMockControlling: AnyObject {
    var isPaired: Bool { get }
    var lastEventNumber: UInt32? { get }

    func pair()
    func forget()
    func flip(to faceID: UInt8)
    func doubleTap(targetFaceID: UInt8?)
    func setPaused(_ paused: Bool)
    func setLocked(_ locked: Bool)
    func setAutoPause(minutes: UInt16)
    func setBatteryLevel(_ level: UInt8)
    func setSystemState(_ state: TimeFlipSystemState)
    func setDeviceTime(_ date: Date)
    func appendEventLog(_ message: String)
    func snapshot() -> TimeFlipDeviceSnapshot
    /// Ends a pending factory-reset reboot immediately, applying the wipe.
    ///
    /// Lets a test cross the reboot boundary without sleeping through it -- the measured reboot is
    /// 13.5 seconds, which no test should spend. No-op when no reset is pending.
    func completeFactoryResetReboot()
}

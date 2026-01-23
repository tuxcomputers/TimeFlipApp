import Foundation

/// High-level events surfaced by the TimeFlip2 BLE characteristics.
/// "Notifications about events in TimeFlip, saved to events log. Sent in ASCI text format."
enum TimeFlipEvent: Equatable, Sendable {
    /// "ID of a notified facet (1 - 12)"
    case facetChanged(facetID: UInt8)
    /// "When double-tap is detected (recognized) by the device, it sets tracking on pause and sends notification to the mobile app."
    case doubleTap(TimeFlipDoubleTapPayload)
    /// Auto-pause timer duration, in minutes, reported from status read (command 0x10).
    case autoPauseMinutes(UInt16)
    /// "Battery charge in percentage (1-100)"
    case batteryLevel(UInt8)
    /// "System state is calibration characteristics."
    case systemState(TimeFlipSystemState)
    /// Device information read from the Device Information service (0x180A).
    case deviceInfo(TimeFlipDeviceInfo)
    /// "Notifications about events in TimeFlip, saved to events log. Sent in ASCI text format."
    case eventLog(String)

    var isFacetOrPauseChange: Bool {
        switch self {
        case .facetChanged, .doubleTap:
            return true
        default:
            return false
        }
    }
}

/// Double-tap payload encoding.
/// "If the received value is less than 128, then it is the facet ID and pause is "off"."
struct TimeFlipDoubleTapPayload: Equatable, Sendable {
    let facetID: UInt8
    let pauseOn: Bool

    init(facetID: UInt8, pauseOn: Bool) {
        self.facetID = facetID
        self.pauseOn = pauseOn
    }

    /// "If the received value is less than 128, then it is the facet ID and pause is "off"."
    init(rawValue: UInt8) {
        if rawValue >= TimeFlipConstants.doubleTapPauseMask {
            self.facetID = rawValue &- TimeFlipConstants.doubleTapPauseMask
            self.pauseOn = true
        } else {
            self.facetID = rawValue
            self.pauseOn = false
        }
    }

    /// "Otherwise, 128 shall be subtracted from the received value to yield actual facet ID with the pause "on"."
    var rawValue: UInt8 {
        pauseOn ? facetID &+ TimeFlipConstants.doubleTapPauseMask : facetID
    }
}

/// "System state is calibration characteristics."
struct TimeFlipSystemState: Equatable, Sendable {
    enum SyncStatus: Equatable, Sendable {
        case ok
        case factoryReset
        case timeSyncRequired
        case facetColorSyncRequired
        case ledBrightnessSyncRequired
        case blinkIntervalSyncRequired
        case taskParametersSyncRequired
        case autoPauseSyncRequired
        case unknown(code: UInt16)
    }

    /// "The second two bytes are responsible for hardware issues:"
    enum HardwareStatus: Equatable, Sendable {
        case ok
        case accelerometerError
        case flashMemoryError
        case accelerometerAndFlashError
        case unknown(code: UInt16)
    }

    let syncStatus: SyncStatus
    let hardwareStatus: HardwareStatus
    let rawStatus: UInt16
    let rawHardware: UInt16

    /// "The first two bytes are responsible for the status:"
    init(statusBytes: (UInt8, UInt8), hardwareBytes: (UInt8, UInt8)) {
        let status = (UInt16(statusBytes.0) << 8) | UInt16(statusBytes.1)
        let hardware = (UInt16(hardwareBytes.0) << 8) | UInt16(hardwareBytes.1)
        self.init(rawStatus: status, rawHardware: hardware)
    }

    init(rawStatus: UInt16, rawHardware: UInt16) {
        self.rawStatus = rawStatus
        self.rawHardware = rawHardware
        self.syncStatus = SyncStatus(rawValue: rawStatus)
        self.hardwareStatus = HardwareStatus(rawValue: rawHardware)
    }

    static var ok: TimeFlipSystemState {
        TimeFlipSystemState(rawStatus: 0x0000, rawHardware: 0x0000)
    }
}

extension TimeFlipSystemState.SyncStatus {
    init(rawValue: UInt16) {
        switch rawValue {
        case 0x0000:
            self = .ok
        case 0x0100:
            self = .factoryReset
        case 0x0201:
            self = .timeSyncRequired
        case 0x0202:
            self = .facetColorSyncRequired
        case 0x0203:
            self = .ledBrightnessSyncRequired
        case 0x0204:
            self = .blinkIntervalSyncRequired
        case 0x0205:
            self = .taskParametersSyncRequired
        case 0x0206:
            self = .autoPauseSyncRequired
        default:
            self = .unknown(code: rawValue)
        }
    }
}

extension TimeFlipSystemState.HardwareStatus {
    init(rawValue: UInt16) {
        switch rawValue {
        case 0x0000:
            self = .ok
        case 0x0201:
            self = .accelerometerError
        case 0x0202:
            self = .flashMemoryError
        case 0x0203:
            self = .accelerometerAndFlashError
        default:
            self = .unknown(code: rawValue)
        }
    }
}

extension TimeFlipEvent: CustomStringConvertible {
    var description: String {
        switch self {
        case .facetChanged(let facetID):
            return "facetChanged(\(facetID))"
        case .doubleTap(let payload):
            return "doubleTap(facet=\(payload.facetID), pauseOn=\(payload.pauseOn))"
        case .autoPauseMinutes(let minutes):
            return "autoPauseMinutes(\(minutes))"
        case .batteryLevel(let level):
            return "batteryLevel(\(level))"
        case .systemState(let state):
            return "systemState(status=\(state.syncStatus), hardware=\(state.hardwareStatus))"
        case .deviceInfo(let info):
            let m = info.manufacturer ?? "nil"
            let model = info.modelNumber ?? "nil"
            let hw = info.hardwareRevision ?? "nil"
            let fw = info.firmwareRevision ?? "nil"
            return "deviceInfo(manu=\(m), model=\(model), hw=\(hw), fw=\(fw))"
        case .eventLog(let message):
            return "eventLog(\(message))"
        }
    }
}

extension TimeFlipSystemState.SyncStatus: CustomStringConvertible {
    var description: String {
        switch self {
        case .ok:
            return "ok"
        case .factoryReset:
            return "factoryReset"
        case .timeSyncRequired:
            return "timeSyncRequired"
        case .facetColorSyncRequired:
            return "facetColorSyncRequired"
        case .ledBrightnessSyncRequired:
            return "ledBrightnessSyncRequired"
        case .blinkIntervalSyncRequired:
            return "blinkIntervalSyncRequired"
        case .taskParametersSyncRequired:
            return "taskParametersSyncRequired"
        case .autoPauseSyncRequired:
            return "autoPauseSyncRequired"
        case .unknown(let code):
            return String(format: "unknown(0x%04X)", code)
        }
    }
}

extension TimeFlipSystemState.HardwareStatus: CustomStringConvertible {
    var description: String {
        switch self {
        case .ok:
            return "ok"
        case .accelerometerError:
            return "accelerometerError"
        case .flashMemoryError:
            return "flashMemoryError"
        case .accelerometerAndFlashError:
            return "accelerometerAndFlashError"
        case .unknown(let code):
            return String(format: "unknown(0x%04X)", code)
        }
    }
}

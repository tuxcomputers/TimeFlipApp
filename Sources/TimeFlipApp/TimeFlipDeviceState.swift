import Foundation

struct TimeFlipDeviceSnapshot: Equatable, Sendable {
    let facetID: UInt8
    let isPaused: Bool
    let isLocked: Bool
    let autoPauseMinutes: UInt16
    let batteryLevel: UInt8
    let systemState: TimeFlipSystemState
    let deviceTime: Date
    let deviceInfo: TimeFlipDeviceInfo?
}

struct TimeFlipHistoryEntry: Equatable, Sendable {
    let eventNumber: UInt32?
    let facetID: UInt8
    let startedAt: Date
    let duration: TimeInterval
    let isPaused: Bool
}

extension TimeFlipDeviceSnapshot {
    func jsonString() -> String {
        let formatter = ISO8601DateFormatter()
        let timeString = formatter.string(from: deviceTime)
        let status = systemState.syncStatus.description
        let hardware = systemState.hardwareStatus.description
        return """
        {"facetID":\(facetID),"paused":\(isPaused),"locked":\(isLocked),"autoPauseMinutes":\(autoPauseMinutes),"battery":\(batteryLevel),"systemStatus":"\(status)","hardwareStatus":"\(hardware)","deviceTime":"\(timeString)"}
        """
    }
}

struct TimeFlipDeviceInfo: Equatable, Sendable {
    let manufacturer: String?
    let modelNumber: String?
    let hardwareRevision: String?
    let firmwareRevision: String?
    let systemID: String?
}

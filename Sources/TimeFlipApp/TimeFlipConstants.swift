import Foundation

enum TimeFlipConstants {
    static let minFacetID: UInt8 = 1
    static let maxFacetID: UInt8 = 12
    static let facetCount = Int(maxFacetID - minFacetID + 1)
    static let facetIDs: [UInt8] = Array(minFacetID...maxFacetID)
    static let unassignedFacetID: UInt8 = 0
    static let doubleTapPauseMask: UInt8 = 0x80
    static let minBatteryLevel: UInt8 = 1
    static let maxBatteryLevel: UInt8 = 100
    static let defaultPassword = "000000"

    static func isValidFacetID(_ facetID: UInt8) -> Bool {
        facetID >= minFacetID && facetID <= maxFacetID
    }
}

enum TimeConstants {
    static let secondsPerMinute: TimeInterval = 60
    static let secondsPerHour: TimeInterval = 60 * 60
    static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    static let defaultTimerTolerance: TimeInterval = 1
}

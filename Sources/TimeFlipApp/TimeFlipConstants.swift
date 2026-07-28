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
    /// The highest low-battery warning level a user is allowed to set.
    ///
    /// The device runs on AA cells, so the warning does not need to leave time to source a battery
    /// the way a hard-to-find cell would -- what it needs to leave time for is choosing *when* to
    /// swap them, because taking the batteries out resets every device setting to defaults (see
    /// `docs/TimeFlip2 BLE Protocol v4.3.md`). Being warned at 20% is ample notice to replace them
    /// at the end of a session rather than being caught mid-tracking.
    ///
    /// Capped rather than left open because a threshold much above this would keep the warning lit
    /// for most of the cells' usable life, which only teaches the user to ignore it.
    static let maxLowBatteryWarningPercent: Int = 20

    /// Bounds for the periodic history-fetch interval, in **seconds** -- the unit the setting is
    /// stored in and the unit every part of the app works in. Only the App tab's control presents it
    /// as minutes, dividing to display and multiplying to save. An hour is the far end of useful:
    /// the periodic fetch is a safety net behind the live facet/pause events, not the main path.
    static let minFetchHistoryIntervalSeconds: Int = 60
    static let maxFetchHistoryIntervalSeconds: Int = 3600

    /// The low-battery ceiling actually enforced. Developer mode lifts it to the full reportable
    /// range so a warning can be forced on a healthy battery for testing, which is also why a
    /// stored value above the cap is left alone while developer mode is on.
    static var effectiveMaxLowBatteryWarningPercent: Int {
        DeveloperMode.isEnabled ? Int(maxBatteryLevel) : maxLowBatteryWarningPercent
    }
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

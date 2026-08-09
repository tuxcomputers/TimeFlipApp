import Foundation

enum TimeFlipConstants {
    static let minFaceID: UInt8 = 1
    static let maxFaceID: UInt8 = 12
    static let faceCount = Int(maxFaceID - minFaceID + 1)
    static let faceIDs: [UInt8] = Array(minFaceID...maxFaceID)
    static let unassignedFaceID: UInt8 = 0
    /// The `Unassigned` sentinel category seeded at `category_id` 0 (`database/007_category.sql`).
    /// What a face points at when it has nothing on it, and so what a face is put back on when the
    /// category it held is retired (see `AppDataStore.updateCategoryActive`).
    static let unassignedCategoryID = 0
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

    /// Where the low-battery warning sits until someone changes it, matching the `low_battery_level`
    /// seed in `database/011_setting.sql`. Held here as well so the fallbacks in code (a missing or
    /// malformed row, `AppState`'s own default) can't drift away from what a fresh database gets.
    static let defaultLowBatteryWarningPercent: Int = 10

    /// Bounds for the periodic history-fetch interval, in **seconds** -- the unit the setting is
    /// stored in and the unit every part of the app works in. Only the App tab's control presents it
    /// as minutes, dividing to display and multiplying to save. An hour is the far end of useful:
    /// the periodic fetch is a safety net behind the live face/pause events, not the main path.
    static let minFetchHistoryIntervalSeconds: Int = 60
    static let maxFetchHistoryIntervalSeconds: Int = 3600

    /// Where the periodic fetch sits until someone changes it, matching the
    /// `fetch_history_interval_seconds` seed in `database/011_setting.sql`. Named for the same reason
    /// as `defaultLowBatteryWarningPercent` and `defaultBlipTimeSeconds`: the loader needs a value
    /// when the row is missing or malformed, and a bare literal there is a copy of the seed that
    /// nothing links back to it. It was one, until this.
    ///
    /// Below `minFetchHistoryIntervalSeconds` deliberately -- sub-minute polling makes history arrive
    /// quickly while testing, so the seed is a developer's value and production floors it. See
    /// `AppDataStore.loadFetchHistoryIntervalSeconds`.
    static let defaultFetchHistoryIntervalSeconds: Int = 10

    /// Bounds for `blip_time`, in seconds -- how short a segment has to be before it is treated as
    /// the cube being turned past a face rather than time spent on it.
    ///
    /// `0` disables the filter, the same way `auto_pause_minutes` uses `0`, so every segment counts.
    /// The default of 5 is the vendor's own number: the spec's `0x02` history stream carries "all
    /// intervals that lasted for at least 5 sec", so matching it means this app discards exactly
    /// what a bulk history read would never have shown it in the first place.
    ///
    /// The ceiling is deliberately low. Measured blips are 0 to 3 seconds, so anything much beyond
    /// the default is discarding real work, and a mistyped 90 that silently threw away a
    /// minute-and-a-half of tracked time would be a bad thing to have to notice later.
    static let minBlipTimeSeconds: Int = 0
    static let maxBlipTimeSeconds: Int = 30
    static let defaultBlipTimeSeconds: Int = 5

    /// How long each startup connect scan waits before concluding the device isn't there, while a
    /// launch has never reached it (`TimeFlipBLEDevice.connectScanTimeoutSeconds`).
    ///
    /// Shorter than the 30-second watchdog every other phase uses, because these attempts are the
    /// ones deciding whether to offer manual mode and somebody is watching an app that appears to
    /// be doing nothing. The watchdog is sized for a device that is present but slow; this one has
    /// to conclude a device is absent. Measured against a cube that is actually there, scan-and-link
    /// has never exceeded 5.4 seconds across 36 logged connects (`conn-phase` rows, 2026-08-09), so
    /// ten still leaves nearly double the slowest real case.
    static let startupConnectScanTimeoutSeconds: UInt64 = 10

    /// Bounds for how many consecutive failed reconnect attempts pass before the app offers manual
    /// mode (the `manual_mode` setting's `prompt_after_attempts`; see `database/011_setting.sql`).
    ///
    /// The floor is 1, not 0: the offer is meant to follow a device that isn't answering, and 0
    /// would raise it before a single attempt had been made. The ceiling comes from what the
    /// backoff actually costs -- `ApplicationDelegate.scheduleReconnect` waits
    /// `min(2 * (attempt + 1), 30)` seconds, so 20 attempts is around six and a half minutes, and
    /// anything past that is an offer the user would never see in a session where they had already
    /// given up and reached for the app.
    static let minManualModePromptAfterAttempts: Int = 1
    static let maxManualModePromptAfterAttempts: Int = 20

    /// Where the manual-mode offer sits until someone changes it, matching the `manual_mode` seed
    /// in `database/011_setting.sql`. Held here for the same reason as
    /// `defaultLowBatteryWarningPercent`: the loader needs a value when the row is missing or
    /// malformed, and a bare literal there is a copy of the seed that nothing links back to it.
    static let defaultManualModePromptAfterAttempts: Int = 3

    /// The low-battery ceiling actually enforced. Developer mode lifts it to the full reportable
    /// range so a warning can be forced on a healthy battery for testing, which is also why a
    /// stored value above the cap is left alone while developer mode is on.
    static var effectiveMaxLowBatteryWarningPercent: Int {
        DeveloperMode.isEnabled ? Int(maxBatteryLevel) : maxLowBatteryWarningPercent
    }
    static let defaultPassword = "000000"

    static func isValidFaceID(_ faceID: UInt8) -> Bool {
        faceID >= minFaceID && faceID <= maxFaceID
    }
}

enum TimeConstants {
    static let secondsPerMinute: TimeInterval = 60
    static let secondsPerHour: TimeInterval = 60 * 60
    static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    static let defaultTimerTolerance: TimeInterval = 1
}

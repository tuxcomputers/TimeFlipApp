import Foundation

/// The stretch of time "today" means for tracked time. **Decisions only, no database.**
///
/// It does not start at midnight. The `daily_reset_time` setting is seeded to 03:00 for a stated reason: a
/// session running across midnight should not be cut in half by the calendar. So a day is the span from the
/// most recent occurrence of that local time up to now, and a total is what falls inside it.
enum DayWindow {
    /// Where `daily_reset_time` sits when the row is missing or holds something that is not a number, and the
    /// bounds a hand-edited row is held to. Matches `database/011_setting.sql`.
    static let defaultHour = 3
    static let defaultMinute = 0

    /// The reset time in force, from what the row says.
    static func resetTime(hour: Int?, minute: Int?) -> (hour: Int, minute: Int) {
        (
            hour: min(23, max(0, hour ?? defaultHour)),
            minute: min(59, max(0, minute ?? defaultMinute))
        )
    }

    /// The most recent reset boundary at or before `now`: the start of the day `now` falls in.
    ///
    /// Through `Calendar` rather than arithmetic on seconds, so a day that is not 24 hours long -- the two
    /// daylight-saving changes -- still starts at the right wall-clock time.
    static func start(at now: Date, resetHour: Int, resetMinute: Int, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = resetHour
        components.minute = resetMinute
        components.second = 0
        components.nanosecond = 0
        guard let todaysReset = calendar.date(from: components) else { return now }
        if now >= todaysReset { return todaysReset }
        // Before today's reset, so the day that is running started at yesterday's.
        return calendar.date(byAdding: .day, value: -1, to: todaysReset) ?? todaysReset
    }

    /// How much of a **still running** stretch falls inside the window, in seconds: it has no recorded end, so
    /// it runs to now by definition.
    static func elapsedInside(startEpoch: Double, windowStart: Date, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - max(startEpoch, windowStart.timeIntervalSince1970))
    }

    /// How much of a stretch falls inside the window, in seconds.
    ///
    /// Clipped at both ends: a segment that began before the window contributes only the part inside it, and
    /// one whose recorded end is somehow in the future contributes only up to now. Zero when it falls outside
    /// altogether, which is the honest answer rather than a negative one.
    static func overlap(
        startEpoch: Double,
        durationSeconds: Double,
        windowStart: Date,
        now: Date
    ) -> TimeInterval {
        let from = max(startEpoch, windowStart.timeIntervalSince1970)
        let to = min(startEpoch + durationSeconds, now.timeIntervalSince1970)
        return max(0, to - from)
    }
}

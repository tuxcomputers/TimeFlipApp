import Foundation

/// Accumulated active seconds **per category** within a sliding "day" window that starts at a
/// configurable local time, defaulting to the `daily_reset_time` setting (seeded to 03:00; see
/// `database/011_setting.sql` and `AppDataStore.loadDailyResetTime()`).
///
/// **Per category, not per face**, which is the question the app actually asks of these numbers: a
/// `daily_limit` is set on a category (`database/007_category.sql`), so two faces assigned the same
/// category share one budget and their time has to be added together to spend it. Keyed by face, a
/// 60-minute limit was not reached by 40 minutes on one face and 40 on another -- each face counted
/// alone, so the limit fired late or never. The menu bar draws the category's name, so a per-face
/// figure beside it was the same disagreement in the duration itself.
///
/// Totals are re-derived from `time_entry` on every seed rather than nudged as segments arrive; see
/// `AppDataStore.loadTimeEntries(overlappingSince:)` for why that table and not `device_event`.
@MainActor
final class DailyCategoryTotals {
    private let dataStore: AppDataStore
    private let calendar: Calendar
    private(set) var resetHour: Int
    private(set) var resetMinute: Int

    private(set) var windowStart: Date
    /// Keyed by `category.category_id`. Includes the `Unassigned` sentinel (id `0`), which pools the
    /// time from every face with no category of its own -- one category, one total, the same rule as
    /// any other.
    private(set) var totals: [Int: TimeInterval] = [:]

    /// - Parameters:
    ///   - resetHour: Local hour (0-23) the day window rolls over at. Defaults to the
    ///     `daily_reset_time` setting's seeded value (3:00 AM); see `database/011_setting.sql`
    ///     and `AppDataStore.loadDailyResetTime()`.
    ///   - resetMinute: Local minute (0-59) the day window rolls over at, alongside `resetHour`.
    init(
        dataStore: AppDataStore,
        calendar: Calendar = .current,
        resetHour: Int? = nil,
        resetMinute: Int? = nil,
        now: Date = Date()
    ) {
        self.dataStore = dataStore
        self.calendar = calendar
        let configured = dataStore.loadDailyResetTime()
        self.resetHour = resetHour ?? configured.hour
        self.resetMinute = resetMinute ?? configured.minute
        self.windowStart = DailyCategoryTotals.computeWindowStart(
            now: now,
            calendar: calendar,
            resetHour: self.resetHour,
            resetMinute: self.resetMinute
        )
    }

    /// Compute the most recent reset boundary at or before `now`.
    static func computeWindowStart(now: Date, calendar: Calendar, resetHour: Int, resetMinute: Int = 0) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = resetHour
        components.minute = resetMinute
        components.second = 0
        components.nanosecond = 0
        guard let todayReset = calendar.date(from: components) else { return now }
        if now >= todayReset {
            return todayReset
        }
        return calendar.date(byAdding: .day, value: -1, to: todayReset) ?? todayReset
    }

    /// Update the local reset time (hour 0-23, minute 0-59) after the user edits it in Settings.
    /// Only stores the new values; the caller re-seeds the window (`resetWindow`) and re-arms the
    /// day-reset timer so the change takes effect immediately.
    func updateResetTime(hour: Int, minute: Int) {
        resetHour = max(0, min(23, hour))
        resetMinute = max(0, min(59, minute))
    }

    /// Next scheduled reset boundary after the current window start.
    var nextResetDate: Date {
        calendar.date(byAdding: .day, value: 1, to: windowStart)
            ?? windowStart.addingTimeInterval(TimeConstants.secondsPerHour * 24)
    }

    /// Re-seed the in-memory totals from recorded time entries for the current window.
    ///
    /// The still-open segment has no entry yet, so it is absent here and the menu bar adds its
    /// elapsed time on top -- which is what stops it counting twice. Paused segments are never
    /// converted, so no `isPaused` test is needed: a pause simply has no row to find.
    func seedFromHistory(now: Date = Date()) {
        totals = [:]
        for record in dataStore.loadTimeEntries(overlappingSince: windowStart) {
            accumulate(start: record.startedAt, duration: record.duration, categoryID: record.categoryID, now: now)
        }
    }

    /// Reset the window to cover the day that contains `now` (using `resetHour`/`resetMinute`)
    /// and repopulate totals from recorded history.
    func resetWindow(now: Date = Date()) {
        windowStart = DailyCategoryTotals.computeWindowStart(
            now: now,
            calendar: calendar,
            resetHour: resetHour,
            resetMinute: resetMinute
        )
        seedFromHistory(now: now)
    }

    /// Add one entry's span to its category's total, clipping it to the current window.
    /// Returns the seconds actually added (`0` when the span falls entirely outside the window).
    @discardableResult
    func accumulate(start: Date, duration: TimeInterval, categoryID: Int, now: Date = Date()) -> TimeInterval {
        let end = start.addingTimeInterval(duration)
        guard end > windowStart else { return 0 }
        let clampedStart = max(start, windowStart)
        let clampedEnd = min(end, now)
        let delta = clampedEnd.timeIntervalSince(clampedStart)
        guard delta > 0 else { return 0 }
        totals[categoryID, default: 0] += delta
        return delta
    }
}

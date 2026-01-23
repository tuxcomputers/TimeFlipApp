import Foundation

/// Maintains per-facet accumulated active seconds within a sliding "day" window
/// that starts at a configurable hour (default 03:00 local). Uses the logbook
/// only on startup/reset; subsequent updates are fed in-memory to avoid extra I/O.
@MainActor
final class DailyFacetTotals {
    private let dataStore: AppDataStore
    private let calendar: Calendar
    private let resetHour: Int

    private(set) var windowStart: Date
    private(set) var totals: [UInt8: TimeInterval] = [:]

    init(
        dataStore: AppDataStore,
        calendar: Calendar = .current,
        resetHour: Int = 3,
        now: Date = Date()
    ) {
        self.dataStore = dataStore
        self.calendar = calendar
        self.resetHour = resetHour
        self.windowStart = DailyFacetTotals.computeWindowStart(
            now: now,
            calendar: calendar,
            resetHour: resetHour
        )
    }

    /// Compute the most recent reset boundary at or before `now`.
    static func computeWindowStart(now: Date, calendar: Calendar, resetHour: Int) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = resetHour
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        guard let todayReset = calendar.date(from: components) else { return now }
        if now >= todayReset {
            return todayReset
        }
        return calendar.date(byAdding: .day, value: -1, to: todayReset) ?? todayReset
    }

    /// Next scheduled reset boundary after the current window start.
    var nextResetDate: Date {
        calendar.date(byAdding: .day, value: 1, to: windowStart)
            ?? windowStart.addingTimeInterval(TimeConstants.secondsPerHour * 24)
    }

    /// Re-seed the in-memory totals from the logbook for the current window.
    func seedFromLogbook(now: Date = Date()) {
        totals = [:]
        let records = dataStore.loadEvents(overlappingSince: windowStart)
        for record in records {
            accumulate(start: record.startedAt, duration: record.duration, facetID: record.facetID, now: now)
        }
    }

    /// Reset the window to cover the day that contains `now` (using `resetHour`)
    /// and repopulate totals from logbook.
    func resetWindow(now: Date = Date()) {
        windowStart = DailyFacetTotals.computeWindowStart(
            now: now,
            calendar: calendar,
            resetHour: resetHour
        )
        seedFromLogbook(now: now)
    }

    /// Add a finalized segment to the accumulator, clipping it to the current window.
    /// Returns the amount of seconds actually added (may be 0 if fully outside window).
    @discardableResult
    func accumulate(start: Date, duration: TimeInterval, facetID: UInt8, now: Date = Date()) -> TimeInterval {
        let end = start.addingTimeInterval(duration)
        guard end > windowStart else { return 0 }
        let clampedStart = max(start, windowStart)
        let clampedEnd = min(end, now)
        let delta = clampedEnd.timeIntervalSince(clampedStart)
        guard delta > 0 else { return 0 }
        totals[facetID, default: 0] += delta
        return delta
    }
}

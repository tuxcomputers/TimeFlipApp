import Foundation

/// What a picked range came to: the boundary it is measured against, the totals inside it, and the entries behind
/// any one of them.
///
/// **Three reads, and none of them is held**, which is the whole of why this is a type rather than three calls at a
/// surface: the day boundary can be changed on the App tab, the entries grow as time is recorded, and whether a
/// figure carries seconds is a setting -- so a total is only true as of the moment it was summed.
///
/// **`bounds` in one place, because two things ask.** The totals are summed over it, and so are the entries behind
/// whichever total is opened. A boundary worked out twice is a boundary that can be worked out differently, and the
/// symptom would be a column of figures that does not add up to the number above it.
///
/// **A picked day or range is a question, not a setting.** Nothing here writes anything and nothing is stored: the
/// selection lasts as long as the window is open, which is why it is the surface's to hold and this takes it as an
/// argument every time.
///
/// **The range covers the app's own days, not calendar days**: 5 August to 7 August means 5 August at the daily
/// reset up to 8 August at the daily reset, so a one-day report shows exactly what the menu bar showed on that day.
/// That is `ReportRangeRules.bounds`, and this is what reads the reset out of the table for it.
@MainActor
package final class ReportReadout {
    private let entries: TimeEntryStore
    private let settings: SettingStore

    package init(entries: TimeEntryStore, settings: SettingStore) {
        self.entries = entries
        self.settings = settings
    }

    /// The instants a picked range covers, measured against the daily reset **read now**.
    ///
    /// The reset comes from the table rather than from the App tab's copy of it, and the two cannot disagree: a
    /// changed row is written straight through and read back before that pane adopts it (see the source-of-truth
    /// rule in `CLAUDE.md`), so they differ for no longer than one write.
    package func bounds(start: Date, end: Date?) -> (start: Date, end: Date) {
        let reset = DayWindow.resetTime(
            hour: settings.integer("daily_reset_time", field: "hour"),
            minute: settings.integer("daily_reset_time", field: "minute")
        )
        return ReportRangeRules.bounds(start: start, end: end, resetHour: reset.hour, resetMinute: reset.minute)
    }

    /// What each category recorded over the range. Only the categories that recorded something are in it.
    package func totals(start: Date, end: Date?) -> [CategoryTotal] {
        let window = bounds(start: start, end: end)
        return entries.totals(from: window.start, to: window.end)
    }

    /// The stretches behind one total, over the same range.
    ///
    /// **Read when a group is opened rather than alongside the totals**, which is what makes a tab of twelve
    /// categories one query instead of thirteen -- and what makes the rows inside a group current as of the moment
    /// somebody looked at them.
    package func entries(for categoryID: Int, start: Date, end: Date?) -> [TimeEntryRecord] {
        let window = bounds(start: start, end: end)
        return entries.entries(categoryID: categoryID, from: window.start, to: window.end)
    }

    /// Whether the figures carry seconds, read at the moment they are drawn like every other setting: the App tab
    /// can change it while this window is open, and the next read is what carries it.
    package var showsSeconds: Bool {
        settings.flag("display_seconds", field: "enabled") ?? true
    }
}

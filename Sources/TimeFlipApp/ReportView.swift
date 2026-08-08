import AppKit
import SwiftUI

/// The Report tab: a date range across the top, and what each category took over it.
///
/// The two calendars are a start and an end, in that order. The end is **optional** and starts
/// unset, which is not a missing value to fill in but the common case said in one click: pick a day
/// on the left, get that day. Clicking a date in the right calendar turns the selection into a
/// range. Because the right calendar is bounded at the start day -- every earlier date drawn greyed
/// out and unclickable -- a range can never be inverted, so there is no error state to report for
/// one and no way to be told off for a selection the UI allowed.
///
/// Both calendars stop at today: this is a time recorder, not a time planner, so a future date is
/// not a report anyone can ask for. Allowing one would only ever answer "nothing tracked", which is
/// indistinguishable from a real day on which nothing was.
///
/// **The month arrows still page past that bound, and that is accepted rather than unnoticed.** A
/// bound governs which dates can be *selected*, not which month is *displayed*, so paging forward
/// reaches a month with every date greyed and nothing selectable. This is not a limitation of the
/// SwiftUI wrapper: measured 2026-08-08 by setting `minDate`/`maxDate` on a bare AppKit
/// `NSDatePicker` and clicking its forward arrow, which behaved identically. Nothing short of
/// hand-building the month grid changes it, and that would mean owning localisation, week-start
/// conventions, keyboard navigation and accessibility to tidy up a month in which nothing can be
/// picked. Don't re-investigate this without new evidence that the platform has changed.
struct ReportView: View {
    @ObservedObject var appState: AppState
    let loadCategoryTotals: (Date, Date) -> [CategoryTotalRecord]

    @State private var startDate = Date()
    /// `nil` until the right picker is used: a start on its own reports that single day. It is never
    /// cleared back to `nil` afterwards -- once a user has asked for a range, silently dropping back
    /// to one day because they moved the start would be the screen changing the question.
    @State private var endDate: Date?
    @State private var totals: [CategoryTotalRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pickers
            Divider()
            if totals.isEmpty {
                emptyState
            } else {
                totalsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: reload)
        .onChange(of: startDate) { _, newValue in
            DeveloperMode.debugPrint(.field, "Field changed: Report start date -> \(Self.debugDate(newValue))")
            // The end picker's lower bound stops a *new* end landing before the start, but the start
            // moving forward past an end already chosen would strand it behind. Carry it along.
            if let endDate, endDate < newValue {
                self.endDate = newValue
            }
            reload()
        }
        .onChange(of: endDate) { _, newValue in
            let shown = newValue.map(Self.debugDate) ?? "not set"
            DeveloperMode.debugPrint(.field, "Field changed: Report end date -> \(shown)")
            reload()
        }
        // A day boundary that moves changes what every range here means, so re-read rather than
        // leave figures on screen that were measured against the old one.
        .onChange(of: appState.dailyResetHour) { _, _ in reload() }
        .onChange(of: appState.dailyResetMinute) { _, _ in reload() }
    }

    // MARK: - Date range

    @ViewBuilder private var pickers: some View {
        let latest = ReportDateRange.latestSelectableDay()
        // Never later than `latest`, so the closed range below cannot be inverted -- a ClosedRange
        // with an upper bound below its lower one traps at runtime. The From picker's own bound
        // already keeps `startDate` inside today, so this only guards against a start arriving from
        // somewhere else (a stale value, a clock that moved backwards).
        let earliestEnd = min(Calendar.current.startOfDay(for: startDate), latest)
        HStack(alignment: .top, spacing: SettingsLayoutConstants.Report.pickerSpacing) {
            // Bounded above at today: a report can only cover time already recorded, so a future
            // start would report nothing and read as "nothing tracked" rather than as a date that
            // can't be asked about.
            calendar(title: "From", subtitle: nil) {
                DatePicker("", selection: $startDate, in: ...latest, displayedComponents: .date)
            }
            // Bounded below at the start day, which greys out every earlier date rather than merely
            // rejecting one after it is clicked, and above at today for the same reason as the start.
            // `startOfDay` rather than `startDate` itself: the raw value carries whatever time of day
            // it was seeded with, and a bound in the middle of the start day would put that same day
            // out of reach as an end.
            calendar(title: "To", subtitle: endDate == nil ? "not set, reporting one day" : nil) {
                DatePicker(
                    "",
                    selection: endBinding,
                    in: earliestEnd...latest,
                    displayedComponents: .date
                )
            }
            Spacer(minLength: 0)
        }
        .padding(SettingsLayoutConstants.Report.padding)
    }

    /// One titled calendar. The label goes above rather than through `DatePicker`'s own, which the
    /// graphical style puts beside the grid and pushes the two calendars out of line with each other.
    @ViewBuilder private func calendar(
        title: String,
        subtitle: String?,
        @ViewBuilder picker: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayoutConstants.Report.titleSpacing) {
            HStack(spacing: SettingsLayoutConstants.Report.titleSpacing) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            picker()
                .datePickerStyle(.graphical)
                .labelsHidden()
        }
    }

    /// Writes through to `endDate` and, by being written to at all, marks the end as set. Reads back
    /// as the start while unset, so the picker shows the single day it is actually reporting rather
    /// than a blank or an unrelated date.
    private var endBinding: Binding<Date> {
        Binding(
            get: { endDate ?? startDate },
            set: { endDate = max($0, startDate) }
        )
    }

    // MARK: - Totals

    @ViewBuilder private var emptyState: some View {
        VStack {
            Text("No time recorded in this range.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var totalsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(totals) { total in
                    ReportRow(
                        name: total.name,
                        duration: Self.formattedDuration(
                            total.seconds,
                            showingSeconds: appState.displaySecondsEnabled
                        ),
                        iconName: appState.iconOptions.first { $0.iconId == total.iconID }?.iconName,
                        colour: appState.colourOptions.first { $0.colourId == total.colourID }
                    )
                    if total.id != totals.last?.id {
                        Divider()
                    }
                }
            }
            .padding(SettingsLayoutConstants.Report.padding)
        }
    }

    // MARK: - Loading

    private func reload() {
        let range = ReportDateRange.bounds(
            start: startDate,
            end: endDate,
            resetHour: appState.dailyResetHour,
            resetMinute: appState.dailyResetMinute
        )
        totals = loadCategoryTotals(range.start, range.end)
        DeveloperMode.debugPrint(
            .report,
            "Report \(Self.debugDate(range.start)) -> \(Self.debugDate(range.end)): \(totals.count) categories"
        )
    }

    /// `H:MM`, or `H:MM:SS` when "Show seconds in the menu bar" is on -- the same format the menu bar
    /// itself uses (`MenuBarController.formattedDuration`), driven by the same setting, so a span
    /// never reads one way there and another way here.
    ///
    /// That setting also earns its keep on this screen rather than merely being obeyed by it: at
    /// `H:MM` every total under a minute reads `0:00`, which is indistinguishable from a category
    /// that was opened and left. Turning seconds on is what tells those apart.
    ///
    /// Hours are never dropped: a category with 7 minutes reads `0:07` rather than `7`, which would
    /// be ambiguous against the hours in the rows beside it.
    static func formattedDuration(_ seconds: TimeInterval, showingSeconds: Bool) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / Int(TimeConstants.secondsPerHour)
        let minutes = (totalSeconds % Int(TimeConstants.secondsPerHour)) / Int(TimeConstants.secondsPerMinute)
        // Hours are unpadded below 10 (e.g. "1:23") but keep two digits once double-digit, matching
        // the menu bar.
        if showingSeconds {
            return String(format: "%d:%02d:%02d", hours, minutes, totalSeconds % Int(TimeConstants.secondsPerMinute))
        }
        return String(format: "%d:%02d", hours, minutes)
    }

    /// Local `yyyy-MM-dd HH:mm` for the debug log, so a logged range can be read against the
    /// timestamps around it without converting from an epoch.
    private static func debugDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// One category's line in the report: its icon and name, with the time on the right.
private struct ReportRow: View {
    let name: String
    let duration: String
    /// `nil` for the None icon (`icon_id` 0), a sentinel rather than a bundled asset.
    let iconName: String?
    /// `nil` for the None colour (`colour_id` 0), which has no hex of its own.
    let colour: ActivityColorOption?

    var body: some View {
        HStack(spacing: SettingsLayoutConstants.FaceList.rowSpacing) {
            // Same treatment as the Faces tab's list: a category with no icon still fills the slot
            // with a hollow square, so every name lines up whether or not one is set.
            Group {
                if let iconName {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: SettingsLayoutConstants.FaceList.iconBackgroundCornerRadius
                        )
                        .fill(colour?.color ?? Color(NSColor.controlBackgroundColor))
                        ActivityIconView(
                            iconName: iconName,
                            tint: (colour?.usesWhiteLines ?? false) ? .white : .black,
                            size: SettingsLayoutConstants.FaceList.iconSize
                        )
                    }
                } else {
                    RoundedRectangle(
                        cornerRadius: SettingsLayoutConstants.FaceList.iconBackgroundCornerRadius
                    )
                    .stroke(Color.black)
                }
            }
            .frame(
                width: SettingsLayoutConstants.FaceList.iconBackgroundSize,
                height: SettingsLayoutConstants.FaceList.iconBackgroundSize
            )

            Text(name)

            Spacer(minLength: SettingsLayoutConstants.Report.pickerSpacing)

            // Monospaced digits so the colon sits in the same place down the column and the figures
            // can be compared by eye rather than read one at a time.
            Text(duration)
                .monospacedDigit()
        }
        .frame(height: SettingsLayoutConstants.faceRowHeight)
        .padding(.horizontal, SettingsLayoutConstants.FaceList.horizontalPadding)
    }
}

import AppKit

/// The App tab: how the app itself behaves, as opposed to what it is timing.
///
/// **The section at the top is the archive's "App settings", with all six of its rows** and its wording
/// (`Archive/TimeFlipApp/ReportSettingsView.swift`). The Google section that sat above it there is not here: it
/// belongs to an integration this app has not rebuilt, and drawing an empty one would promise something.
///
/// **Nothing here writes yet.** The values are read from the `setting` table when the tab is shown, as every other
/// pane's are, and a change bounces back to what the table says -- which is the database rule applied exactly as it
/// is written for a refused write: a field showing what was typed while the table holds something else is the
/// two-answers problem the rule exists to prevent. So the rows can be laid out and judged now, and each one becomes
/// live when its writer lands.
@MainActor
final class AppSettingsPane: NSView {
    enum Identifier {
        static let section = "app-settings-section"
        static let heading = "app-settings-section-heading"
        static let showSeconds = "app-show-seconds"
        static let pauseOnLock = "app-pause-on-lock"
        static let dailyReset = "app-daily-reset"
        static let batteryWarning = "app-battery-warning"
        static let fetchInterval = "app-fetch-interval"
        static let blipTime = "app-blip-time"
    }

    private enum Layout {
        /// The Categories tab's numbers, so the two tabs sit at the same rhythm.
        static let padding: CGFloat = 20
        static let headingSpacing: CGFloat = 12
        static let cornerRadius: CGFloat = 8
        /// Inside the panel, to the left of a label and to the right of a control. The rows themselves run the whole
        /// width, which is what puts a separator's ends where the archive's are.
        static let rowInset: CGFloat = 20
        /// Above and below a row's content. What makes the number rows taller than the switch rows is the fields
        /// inside them, not a second measurement -- the archive's rows sized to their contents the same way.
        static let rowPadding: CGFloat = 11
        /// The least a row can be, so two switches in a row do not read as a tighter list than the fields under them.
        static let minimumRowHeight: CGFloat = 38
        static let separatorHeight: CGFloat = 1
    }

    /// What the table says, at the moment the tab was shown. Every field is what is stored, in the unit it is stored
    /// in -- the conversions to what a row displays are `AppSettingsRules`', so they cannot be done differently in
    /// two places.
    struct Values: Equatable {
        var showsSeconds: Bool
        var pausesOnLock: Bool
        var dailyResetHour24: Int
        var batteryWarningPercent: Int
        var fetchIntervalSeconds: Int
        var blipSeconds: Int

        /// What a database with none of these rows would give, which is what the seeds give
        /// (`database/011_setting.sql`). Named here rather than at each call site so one missing row cannot come to
        /// mean two different things.
        static let seeded = Values(
            showsSeconds: true,
            pausesOnLock: true,
            dailyResetHour24: AppSettingsRules.defaultResetHour24,
            batteryWarningPercent: AppSettingsRules.defaultBatteryWarningPercent,
            fetchIntervalSeconds: AppSettingsRules.defaultFetchIntervalSeconds,
            blipSeconds: AppSettingsRules.defaultBlipSeconds
        )
    }

    /// Called when a row is changed, with the row's identifier and the number or flag it was changed to.
    ///
    /// **A request, and one nothing answers yet.** The window records it and reads the tab again, which puts the row
    /// back to what the table holds. When a setting gains a writer, this is where it is wired.
    var onChange: ((String, String) -> Void)?

    private(set) var values = Values.seeded
    private let rows = NSStackView()
    private var showSecondsBox: NSButton!
    private var pauseOnLockBox: NSButton!
    private var dailyResetField: SteppedNumberField!
    private var batteryWarningField: SteppedNumberField!
    private var fetchIntervalField: SteppedNumberField!
    private var blipTimeField: SteppedNumberField!

    init() {
        super.init(frame: .zero)
        addSection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Draws what the table says. Rebuilt rather than patched, for the reason every other pane is: the values arrive
    /// whole from one read, so reconciling them against what is on screen would be work in service of nothing.
    func show(_ values: Values) {
        self.values = values
        showSecondsBox.state = values.showsSeconds ? .on : .off
        pauseOnLockBox.state = values.pausesOnLock ? .on : .off
        dailyResetField.value = AppSettingsRules.hour12(from: values.dailyResetHour24)
        batteryWarningField.value = values.batteryWarningPercent
        fetchIntervalField.value = AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds)
        fetchIntervalField.suffix = AppSettingsRules.unit("min", "mins", for: fetchIntervalField.value)
        blipTimeField.value = values.blipSeconds
        blipTimeField.suffix = AppSettingsRules.unit("sec", "secs", for: values.blipSeconds)
    }

    private func addSection() {
        // **The pane keeps its autoresizing frame**, so it is as wide as the window and the panel inside it spans that
        // width (see `CLAUDE.md`). The tab view hands each pane the content rect and resizes it from there;
        // `translatesAutoresizingMaskIntoConstraints = false` here would throw that away and leave the pane sized to
        // its own contents, which is a panel stopping short of the right-hand edge. It did, until this.
        let heading = NSTextField(labelWithString: "App settings")
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier(Identifier.heading)

        // The same tinted panel the Categories tab's lists sit on, which is what the previous app drew every group of
        // settings on (`image/preferences-device.png`).
        let panel = NSBox()
        panel.boxType = .custom
        panel.fillColor = .quaternarySystemFill
        panel.borderWidth = 0
        panel.cornerRadius = Layout.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier(Identifier.section)

        rows.orientation = .vertical
        rows.alignment = .leading
        // No gap: the rows are a list with hairlines between them, not separate controls, and the padding inside each
        // row is what keeps them apart. The archive's grouped form again.
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addRows()

        addSubview(heading)
        addSubview(panel)
        panel.contentView?.addSubview(rows)
        guard let content = panel.contentView else { return }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.padding),

            panel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Layout.headingSpacing),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),

            // Flush to the panel on all four sides: a row runs the whole width, and its own inset is what holds the
            // label and the control off the edges. That is what puts a separator's ends where the archive's are.
            rows.topAnchor.constraint(equalTo: content.topAnchor),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// The archive's six rows, in the archive's order: the two switches first, then the four numbers.
    private func addRows() {
        showSecondsBox = box(identifier: Identifier.showSeconds, action: #selector(showSecondsChanged))
        pauseOnLockBox = box(identifier: Identifier.pauseOnLock, action: #selector(pauseOnLockChanged))

        dailyResetField = field(
            identifier: Identifier.dailyReset,
            value: AppSettingsRules.hour12(from: values.dailyResetHour24),
            range: AppSettingsRules.resetHours,
            suffix: AppSettingsRules.resetSuffix
        )
        batteryWarningField = field(
            identifier: Identifier.batteryWarning,
            value: values.batteryWarningPercent,
            range: AppSettingsRules.batteryWarningPercent,
            suffix: AppSettingsRules.batterySuffix
        )
        fetchIntervalField = field(
            identifier: Identifier.fetchInterval,
            value: AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds),
            range: AppSettingsRules.fetchIntervalMinutes,
            suffix: AppSettingsRules.unit("min", "mins", for: AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds))
        )
        blipTimeField = field(
            identifier: Identifier.blipTime,
            value: values.blipSeconds,
            range: AppSettingsRules.blipSeconds,
            suffix: AppSettingsRules.unit("sec", "secs", for: values.blipSeconds)
        )

        let built: [(String, NSView)] = [
            ("Show seconds in the menu bar", showSecondsBox),
            ("Pause the device when locking it", pauseOnLockBox),
            ("Daily reset at", dailyResetField),
            ("Battery warning at", batteryWarningField),
            ("Fetch history every", fetchIntervalField),
            // Turning the cube to the face somebody wants drags it past the others, and each pass-over is a real
            // segment the device reports. This is how short one has to be to count as getting there rather than as
            // time spent.
            ("Ignore flips under", blipTimeField),
        ]
        for (index, (title, control)) in built.enumerated() {
            // No hairline under the last one: it would draw against the panel's own bottom edge and read as a row
            // that failed to load rather than as a divider.
            let view = row(title, control, separated: index < built.count - 1)
            rows.addView(view, in: .top)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    /// One row of the grouped form: the label against the left inset, the control against the right one, and a
    /// hairline under it.
    ///
    /// **The control is pinned to the trailing edge rather than following the label**, which is what the archive's
    /// form did and what makes the column of controls line up down the right-hand side however long the words in
    /// front of them are. A fixed label column would line them up too, and put them in the middle of the panel with
    /// dead space beyond -- which is not what that tab looked like.
    private func row(_ title: String, _ control: NSView, separated: Bool) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // The label gives way before the control does: a window narrow enough to squeeze one of these should
            // truncate the words, not shrink the field somebody types into.
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -Layout.rowInset),

            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Layout.rowInset),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor, constant: Layout.rowPadding),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Layout.rowPadding),

            row.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumRowHeight),
        ])
        guard separated else { return row }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            // From the label's left edge to the control's right one, which is where the archive drew it: a hairline
            // running the full width would cut the panel in two rather than dividing a list.
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Layout.rowInset),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: Layout.separatorHeight),
        ])
        return row
    }

    private func box(identifier: String, action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: "", target: self, action: action)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.identifier = NSUserInterfaceItemIdentifier(identifier)
        box.setAccessibilityIdentifier(identifier)
        return box
    }

    private func field(identifier: String, value: Int, range: ClosedRange<Int>, suffix: String) -> SteppedNumberField {
        let field = SteppedNumberField(value: value, range: range, suffix: suffix, identifier: identifier)
        field.onChange = { [weak self] changed in
            self?.onChange?(identifier, String(changed))
        }
        return field
    }

    @objc
    private func showSecondsChanged() {
        onChange?(Identifier.showSeconds, showSecondsBox.state == .on ? "on" : "off")
    }

    @objc
    private func pauseOnLockChanged() {
        onChange?(Identifier.pauseOnLock, pauseOnLockBox.state == .on ? "on" : "off")
    }
}

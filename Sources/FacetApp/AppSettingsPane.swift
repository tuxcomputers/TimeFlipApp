import AppKit

/// The App tab: how the app itself behaves, as opposed to what it is timing.
///
/// **Two sections: "App settings" first, with all six of the archive's rows in its order and its wording
/// (`Archive/TimeFlipApp/ReportSettingsView.swift`), then Google underneath.**
///
/// The archive put Google at the top. It is at the bottom here, which is the better place for it on merit: the six
/// settings above are what somebody opens this tab to change, and the Google section is a connection you make once
/// and then read occasionally.
///
/// The Google section is **much smaller than the archive's**, and `GoogleAccountRules` carries the reasons: the
/// credentials now ship with the build so there is nothing to paste in, and the calendar picker is gone because
/// choosing an existing calendar needs sensitive scopes this app deliberately does not ask for. What is left is the
/// part that was always the point, which is saying which account is connected.
///
/// **Signing in is not built.** The button is drawn and disabled with the reason under it, which is the shape the
/// archive used when its own credentials were missing. Disconnecting works, because clearing a row is something this
/// app can do without a network.
///
/// **The values are read once, when the window opens, and this pane then holds them** -- see the source-of-truth rule
/// in `CLAUDE.md` for why a Settings window is the one place that is allowed to. A change is written straight through
/// and read back by the window; this pane adopts it only once the table has it, and puts the row back if the table
/// refused. So the two copies can only differ for as long as one write takes.
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
        static let googleSection = "app-google-section"
        static let googleHeading = "app-google-section-heading"
        static let googleStatus = "app-google-status"
        static let googleAccount = "app-google-account"
        static let googleEmail = "app-google-email"
        static let googleButton = "app-google-button"
        static let googleCalendar = "app-google-calendar"
        static let googleCalendarCreate = "app-google-calendar-create"
        static let googleNote = "app-google-note"
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
        /// Between one section's panel and the next section's heading. Wider than `headingSpacing`, so a heading
        /// reads as belonging to the panel under it rather than to the one it follows.
        static let sectionSpacing: CGFloat = 24
        /// How much of the Calendar row the name may take. Wide enough for a name somebody chose, and fixed so the
        /// row does not change width when the name does.
        static let calendarNameWidth: CGFloat = 240
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
        /// Who is signed in, from the `google_account` row. Part of this struct rather than read separately because
        /// it is read in the same pass: opening the window reads every value the window shows, in one go.
        var googleAccount = GoogleAccountRules.Account.none
        /// Whether this build has an OAuth client in it at all. Not a setting: it comes from the bundle and the
        /// override file, and it decides whether the button can do anything.
        var googleCredentialsAvailable = false
        /// The calendar Facet owns, from the same row as the identity.
        var googleCalendar = GoogleCalendarRules.Calendar.none

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

    /// One row's new value, named for the row rather than for the setting it lands in: which row this came from is
    /// what the pane knows, and which column that maps to is `AppSettingsRules`' to say.
    ///
    /// Each number is in the unit the *row* shows -- a 12-hour face, whole minutes -- rather than the unit the table
    /// stores, for the same reason: converting is a rule, and doing it here would be a second place it happens.
    enum Change: Equatable {
        case showsSeconds(Bool)
        case pausesOnLock(Bool)
        case dailyResetHour12(Int)
        case batteryWarningPercent(Int)
        case fetchIntervalMinutes(Int)
        case blipSeconds(Int)
        /// Sign out: clear the connected identity. Carries no value because it is not a row being set to something,
        /// it is a row being emptied, and "emptied" has only one meaning.
        case googleDisconnected
        /// Sign in. **A request with no value at all**: what the account turns out to be is Google's to say, and comes
        /// back as `googleConnected`.
        case googleSignInRequested
        /// The identity the table now holds, after a sign-in was written and read back.
        case googleConnected(GoogleAccountRules.Account)
        /// A new name for the calendar, typed and committed. **A request**: it is a rename at Google, not a label.
        case googleCalendarNamed(String)
        /// Make the calendar. Only reachable when there is none, which is a recovery rather than the usual path.
        case googleCalendarCreateRequested
        /// The calendar the table now holds, after Google answered and the write was read back.
        case googleCalendarChanged(GoogleCalendarRules.Calendar)
    }

    /// Called when a row is changed. **A request**: the window writes it, checks the table took it, and says so if it
    /// did not. What the row shows is left alone either way -- it is showing what somebody just typed.
    var onChange: ((Change) -> Void)?

    /// Called as the calendar name is opened for editing and closed again, so the window can lend Escape to the
    /// field. A key equivalent is dispatched before the focused field ever sees the key, so without this the Close
    /// button wins and shuts the window instead of abandoning the name. The Categories tab makes the same loan.
    var onCalendarEditingChanged: ((Bool) -> Void)?

    /// The calendar name's cell while the section is showing one, for a test to reach and for the window to close an
    /// edit on. `nil` whenever there is no calendar, since the row is then a Create button.
    private(set) var calendarCell: EditableNameCell?

    private(set) var values = Values.seeded
    private let rows = NSStackView()
    private let googleRows = NSStackView()
    private let googleNote = NSTextField(labelWithString: "")
    /// Transient, and deliberately not in `Values`: it is what the app is doing, not what the table says.
    private var isSigningIn = false
    private var showSecondsBox: NSButton!
    private var pauseOnLockBox: NSButton!
    private var dailyResetField: SteppedNumberField!
    private var batteryWarningField: SteppedNumberField!
    private var fetchIntervalField: SteppedNumberField!
    private var blipTimeField: SteppedNumberField!

    init() {
        super.init(frame: .zero)
        addSections()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Takes on a change the table accepted, so what this pane holds is what the table holds.
    ///
    /// The controls are not redrawn: they are already showing it, and rebuilding a row around the value somebody just
    /// typed takes the field out from under them. This is the in-memory half of the window's source of truth (see
    /// `CLAUDE.md`), kept true by only ever adopting a change that has been read back.
    func adopt(_ change: Change) {
        switch change {
        case let .showsSeconds(value): values.showsSeconds = value
        case let .pausesOnLock(value): values.pausesOnLock = value
        case let .dailyResetHour12(value): values.dailyResetHour24 = AppSettingsRules.hour24(fromFace: value)
        case let .batteryWarningPercent(value): values.batteryWarningPercent = value
        case let .fetchIntervalMinutes(value): values.fetchIntervalSeconds = AppSettingsRules.seconds(fromMinutes: value)
        case let .blipSeconds(value): values.blipSeconds = value
        case .googleSignInRequested:
            // Nothing to take on: the answer arrives as `googleConnected` once the table has it.
            break
        case let .googleConnected(account):
            values.googleAccount = account
            showGoogle()
        case .googleCalendarNamed, .googleCalendarCreateRequested:
            // Requests. What the calendar becomes arrives as `googleCalendarChanged`.
            break
        case let .googleCalendarChanged(calendar):
            values.googleCalendar = calendar
            showGoogle()
        case .googleDisconnected:
            values.googleAccount = .none
            // **The calendar is not forgotten here.** The id survives a sign-out so that signing back in on the same
            // account keeps the calendar and its history; it is checked on the way back in rather than trusted, and
            // only cleared once Google has said it is gone.
            // The one change here that *does* redraw its rows. The reason the others do not is that somebody is
            // typing in them, and taking a field out from under them is the harm being avoided. Nobody types into a
            // status line, and leaving it reading "Connected" under a button that just disconnected would be the
            // window showing something the table no longer says.
            showGoogle()
        }
    }

    /// Puts every row back to what this pane holds, which is what a refused write needs: the row is showing something
    /// the table does not.
    func restore() {
        show(values)
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
        showGoogle()
    }

    /// Draws the Google section for the account this pane holds.
    ///
    /// **Rebuilt from nothing each time rather than patched**, because the section's *shape* changes with the state
    /// and not just its words: connected shows an account and an email that are simply absent otherwise. Reconciling
    /// two rows that may or may not exist against two that may or may not be wanted is more code than building three
    /// labels, and it is the version that goes wrong.
    private func showGoogle() {
        for view in googleRows.views {
            googleRows.removeView(view)
        }
        // The rows are rebuilt from scratch, so any cell held from the last build is about to be thrown away. Kept in
        // step here rather than left pointing at a view that is no longer in the window.
        calendarCell = nil

        let account = values.googleAccount
        var built: [NSView] = [
            row("Status", label(GoogleAccountRules.status(for: account), identifier: Identifier.googleStatus),
                separated: true),
        ]
        if let name = account.name {
            built.append(row("Account", label(name, identifier: Identifier.googleAccount), separated: true))
        }
        if let email = account.email {
            built.append(row("Email", label(email, identifier: Identifier.googleEmail), separated: true))
        }

        if account.isConnected {
            built.append(calendarRow())
        }

        let hasCredentials = values.googleCredentialsAvailable
        let button = NSButton(
            title: GoogleAccountRules.buttonTitle(for: account, isSigningIn: isSigningIn),
            target: self,
            action: #selector(googleButtonPressed)
        )
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = GoogleAccountRules.isButtonEnabled(
            for: account, hasCredentials: hasCredentials, isSigningIn: isSigningIn
        )
        button.setAccessibilityIdentifier(Identifier.googleButton)
        built.append(row(account.isConnected ? "Account" : "Google", button, separated: false))

        for view in built {
            googleRows.addView(view, in: .top)
            view.widthAnchor.constraint(equalTo: googleRows.widthAnchor).isActive = true
        }
        let note = GoogleAccountRules.note(for: account, hasCredentials: hasCredentials)
        googleNote.stringValue = note ?? ""
        // **Nothing is anchored below this**, which is what makes hiding it enough. A hidden view keeps its height
        // in Auto Layout (`Tests/Methods.md`), so while the Google section sat above App settings this had to swap
        // two constraints to stop the empty note pushing the heading under it down. Being last removed that.
        googleNote.isHidden = note == nil
    }

    /// The Calendar row: the name, editable, or a button to make one when there is none.
    ///
    /// **Editable only once the calendar exists.** Naming something that has not been created yet would be a field
    /// whose value has nowhere to go, and the create path uses the default name rather than asking for one at the
    /// moment somebody is trying to connect an account.
    private func calendarRow() -> NSView {
        guard values.googleCalendar.exists else {
            let button = NSButton(
                title: "Create calendar", target: self, action: #selector(googleCalendarCreatePressed)
            )
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isEnabled = !isSigningIn
            button.setAccessibilityIdentifier(Identifier.googleCalendarCreate)
            return row("Calendar", button, separated: true)
        }

        // **The same cell a category name uses**, so renaming the calendar is the same act as renaming a category:
        // click the name, it becomes a field, Return commits and Escape abandons. It used to be a permanently live
        // text field, which looked like a form to fill in rather than a name to correct, and behaved differently in
        // the way that matters -- an `NSTextField`'s action fires on losing focus as well as on Return, so tabbing
        // out of it or clicking elsewhere spent a request to Google on a rename nobody asked for.
        let cell = EditableNameCell(
            name: values.googleCalendar.name ?? GoogleCalendarRules.defaultName,
            width: Layout.calendarNameWidth,
            identifier: Identifier.googleCalendar,
            alignment: .right
        )
        cell.onCommit = { [weak self] typed in self?.calendarNamed(typed) }
        cell.onEditingChanged = { [weak self] isEditing in self?.onCalendarEditingChanged?(isEditing) }
        calendarCell = cell
        return row("Calendar", cell, separated: true)
    }

    private func calendarNamed(_ typed: String) {
        let name = GoogleCalendarRules.name(fromTyped: typed)
        // Unchanged is not a rename. Committing a name somebody opened and thought better of should not spend a
        // request to Google.
        guard name != values.googleCalendar.name else { return }
        onChange?(.googleCalendarNamed(name))
    }

    @objc
    private func googleCalendarCreatePressed() {
        onChange?(.googleCalendarCreateRequested)
    }

    private func label(_ text: String, identifier: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier(identifier)
        return label
    }

    /// Shows that a sign-in is under way, so the button cannot be pressed again while a browser window is open on it.
    func setSigningIn(_ signingIn: Bool) {
        isSigningIn = signingIn
        showGoogle()
    }

    @objc
    private func googleButtonPressed() {
        guard !isSigningIn else { return }
        onChange?(values.googleAccount.isConnected ? .googleDisconnected : .googleSignInRequested)
    }

    /// Two sections, App settings above Google.
    ///
    /// **The pane keeps its autoresizing frame**, so it is as wide as the window and both panels span that width (see
    /// `CLAUDE.md`). The tab view hands each pane the content rect and resizes it from there;
    /// `translatesAutoresizingMaskIntoConstraints = false` here would throw that away and leave the pane sized to its
    /// own contents, which is a panel stopping short of the right-hand edge. It did, until this.
    ///
    /// **Neither section folds**, so each heading sits above its panel and names it rather than operating it, which is
    /// what `CLAUDE.md` reserves the heading-inside-the-panel shape for.
    private func addSections() {
        let googleHeading = heading("Google", identifier: Identifier.googleHeading)
        let googlePanel = panel(identifier: Identifier.googleSection)
        stack(googleRows)
        showGoogle()

        googleNote.translatesAutoresizingMaskIntoConstraints = false
        googleNote.font = .preferredFont(forTextStyle: .footnote)
        googleNote.textColor = .secondaryLabelColor
        googleNote.lineBreakMode = .byWordWrapping
        googleNote.maximumNumberOfLines = 0
        googleNote.setAccessibilityIdentifier(Identifier.googleNote)

        let appHeading = heading("App settings", identifier: Identifier.heading)
        let appPanel = panel(identifier: Identifier.section)
        stack(rows)
        addRows()

        for view in [googleHeading, googlePanel, googleNote, appHeading, appPanel] {
            addSubview(view)
        }
        googlePanel.contentView?.addSubview(googleRows)
        appPanel.contentView?.addSubview(rows)
        guard let googleContent = googlePanel.contentView, let appContent = appPanel.contentView else { return }

        // Written out rather than composed with `+` and `flatMap`: the composed version was one expression the type
        // checker gave up on ("unable to type-check in reasonable time"), and a build error is a worse price than
        // repetition.
        NSLayoutConstraint.activate([
            appHeading.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            appPanel.topAnchor.constraint(equalTo: appHeading.bottomAnchor, constant: Layout.headingSpacing),
            googleHeading.topAnchor.constraint(equalTo: appPanel.bottomAnchor, constant: Layout.sectionSpacing),
            googlePanel.topAnchor.constraint(equalTo: googleHeading.bottomAnchor, constant: Layout.headingSpacing),
            googleNote.topAnchor.constraint(equalTo: googlePanel.bottomAnchor, constant: Layout.headingSpacing / 2),
        ])

        // A heading may be shorter than the pane; a panel and the note always span it.
        for view in [googleHeading, appHeading] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
                view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.padding),
            ])
        }
        for view in [googlePanel as NSView, googleNote, appPanel] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            ])
        }

        // Flush to the panel on all four sides: a row runs the whole width, and its own inset is what holds the
        // label and the control off the edges. That is what puts a separator's ends where the archive's are.
        for (stack, content) in [(googleRows, googleContent), (rows, appContent)] {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

    }

    private func heading(_ title: String, identifier: String) -> NSTextField {
        let heading = NSTextField(labelWithString: title)
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier(identifier)
        return heading
    }

    /// The same tinted panel the Categories tab's lists sit on, which is what the previous app drew every group of
    /// settings on (`image/preferences-device.png`).
    private func panel(identifier: String) -> NSBox {
        let panel = NSBox()
        panel.boxType = .custom
        panel.fillColor = .quaternarySystemFill
        panel.borderWidth = 0
        panel.cornerRadius = Layout.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier(identifier)
        return panel
    }

    private func stack(_ view: NSStackView) {
        view.orientation = .vertical
        view.alignment = .leading
        // No gap: the rows are a list with hairlines between them, not separate controls, and the padding inside each
        // row is what keeps them apart. The archive's grouped form again.
        view.spacing = 0
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The archive's six rows, in the archive's order: the two switches first, then the four numbers.
    private func addRows() {
        showSecondsBox = box(identifier: Identifier.showSeconds, action: #selector(showSecondsChanged))
        pauseOnLockBox = box(identifier: Identifier.pauseOnLock, action: #selector(pauseOnLockChanged))

        dailyResetField = field(
            identifier: Identifier.dailyReset,
            value: AppSettingsRules.hour12(from: values.dailyResetHour24),
            range: AppSettingsRules.resetHours,
            suffix: AppSettingsRules.resetSuffix,
            change: Change.dailyResetHour12
        )
        batteryWarningField = field(
            identifier: Identifier.batteryWarning,
            value: values.batteryWarningPercent,
            range: AppSettingsRules.batteryWarningPercent,
            suffix: AppSettingsRules.batterySuffix,
            change: Change.batteryWarningPercent
        )
        fetchIntervalField = field(
            identifier: Identifier.fetchInterval,
            value: AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds),
            range: AppSettingsRules.fetchIntervalMinutes,
            suffix: AppSettingsRules.unit("min", "mins", for: AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds)),
            change: Change.fetchIntervalMinutes
        )
        blipTimeField = field(
            identifier: Identifier.blipTime,
            value: values.blipSeconds,
            range: AppSettingsRules.blipSeconds,
            suffix: AppSettingsRules.unit("sec", "secs", for: values.blipSeconds),
            change: Change.blipSeconds
        )

        let built: [(String, NSView)] = [
            ("Show seconds", showSecondsBox),
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

    private func field(
        identifier: String,
        value: Int,
        range: ClosedRange<Int>,
        suffix: String,
        change: @escaping (Int) -> Change
    ) -> SteppedNumberField {
        let field = SteppedNumberField(value: value, range: range, suffix: suffix, identifier: identifier)
        field.onChange = { [weak self, weak field] changed in
            // The two rows whose unit is a word keep it in step with the number as it moves: "1 min" against
            // "2 mins". Done as the value changes rather than on the read-back, since the read-back is what does not
            // happen while a window is open.
            switch change(changed) {
            case .fetchIntervalMinutes:
                field?.suffix = AppSettingsRules.unit("min", "mins", for: changed)
            case .blipSeconds:
                field?.suffix = AppSettingsRules.unit("sec", "secs", for: changed)
            default:
                break
            }
            self?.onChange?(change(changed))
        }
        return field
    }

    @objc
    private func showSecondsChanged() {
        onChange?(.showsSeconds(showSecondsBox.state == .on))
    }

    @objc
    private func pauseOnLockChanged() {
        onChange?(.pausesOnLock(pauseOnLockBox.state == .on))
    }
}

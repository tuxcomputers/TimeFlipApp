import AppKit

/// The App tab: how the app itself behaves, as opposed to what it is timing.
///
/// **Three sections: "App settings" first, in the archive's order and its wording
/// (`Archive/TimeFlipApp/ReportSettingsView.swift`), then Google, then Debug.** Each folds away behind its own
/// triangle, on the same `PanelSection` the Categories tab's two lists sit on.
///
/// **Debug is this tab's own, with nothing behind it in the archive**, whose only debug switch was a compile-time
/// flag and a `config.json` a developer edited by hand. It carries the two fields of the `debug` setting: whether
/// the trace is gathered, and which folder `debug.sqlite` is kept in -- the second being the answer to "where is
/// the file to send me", which is what the trace is for.
///
/// **Four of the archive's six rows.** "Pause the device when locking it" and "Battery warning at" are on the
/// Device tab, the first two rows of its Settings section, and they are the departure from that view's contents:
/// one decides what happens to the cube when the app locks it and the other what counts as the cube running flat,
/// so both sit with the rest of what is said about the cube rather than among the app's own behaviour. Their
/// wording and their controls are the archive's still, and only the tab is not.
///
/// **The archive did not fold these**, and that is worth saying rather than leaving as a silent departure: its App
/// tab was two plain `Section`s of a grouped form, and it reserved `DisclosureGroup` for the Device tab's *More*,
/// *LED* and *Double tap*. The intent it had is the one kept here -- a fold is for a group somebody is not working
/// in -- and what changed is only that this tab now has two groups big enough for that to be worth offering.
///
/// The archive put Google at the top. It is at the bottom here, which is the better place for it on merit: the four
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
        /// The tinted box inside the section, which is `PanelSection`'s to name. Spelled out here because a test
        /// measures it, and because deriving it at the call site would be a second copy of that type's convention.
        static let panel = "app-settings-section-panel"
        static let showSeconds = "app-show-seconds"
        static let dailyReset = "app-daily-reset"
        static let fetchInterval = "app-fetch-interval"
        static let blipTime = "app-blip-time"
        static let googleSection = "app-google-section"
        static let googleHeading = "app-google-section-heading"
        static let googlePanel = "app-google-section-panel"
        static let googleStatus = "app-google-status"
        static let googleAccount = "app-google-account"
        static let googleEmail = "app-google-email"
        static let googleButton = "app-google-button"
        static let googleCalendar = "app-google-calendar"
        static let googleCalendarCreate = "app-google-calendar-create"
        static let googleCalendarDelete = "app-google-calendar-delete"
        static let googleNote = "app-google-note"
        static let debugSection = "app-debug-section"
        static let debugHeading = "app-debug-section-heading"
        static let debugPanel = "app-debug-section-panel"
        static let debugEnabled = "app-debug-enabled"
        static let debugDirectory = "app-debug-directory"
        static let debugDirectoryChoose = "app-debug-directory-choose"
        static let debugReveal = "app-debug-reveal"
        static let debugCopy = "app-debug-copy"
        static let debugClear = "app-debug-clear"
        static let debugNote = "app-debug-note"
    }

    private enum Layout {
        /// **Every number here comes from `SettingsMetrics`**, which is where the look of a tab is decided. This tab
        /// used to carry its own copies, measured against the Categories tab by eye, and they had drifted: a 46pt
        /// row against that tab's 32, with hairlines it never had.
        static let padding = SettingsMetrics.tabPadding
        static let headingSpacing = SettingsMetrics.headingSpacing
        /// **No row inset and no row height here any more.** Both moved to `SettingsRow`, which is what builds a
        /// row on this tab and on the Device tab: the panel insets the list, exactly as it does on the Categories
        /// tab, and the height is the one `SettingsMetrics` sets for every tab.
        /// Between one row and the next, which is what divides them now that nothing is drawn between them.
        static let rowSpacing = SettingsMetrics.rowSpacing
        static let sectionSpacing = SettingsMetrics.sectionSpacing
        /// How much of the Calendar row the name may take. Wide enough for a name somebody chose, and fixed so the
        /// row does not change width when the name does.
        static let calendarNameWidth: CGFloat = 240
    }

    /// What the table says, at the moment the tab was shown. Every field is what is stored, in the unit it is stored
    /// in -- the conversions to what a row displays are `AppSettingsRules`', so they cannot be done differently in
    /// two places.
    struct Values: Equatable {
        var showsSeconds: Bool
        var dailyResetHour24: Int
        var fetchIntervalSeconds: Int
        var blipSeconds: Int
        /// Who is signed in, from the `google_account` row. Part of this struct rather than read separately because
        /// it is read in the same pass: opening the window reads every value the window shows, in one go.
        var googleAccount = GoogleAccountRules.Account.none
        /// Whether the Keychain holds a token for that account, which the row cannot say. Read in the same pass as
        /// the row: one of them without the other is exactly the half-answer this section used to draw.
        var googleCredential = GoogleAccountRules.Credential.missing
        /// What Google last said about the token. Starts `notAsked` because opening a window is not asking Google
        /// anything; the window fills this in when the check comes back.
        var googleVerification = GoogleAccountRules.Verification.notAsked
        /// Whether this build has an OAuth client in it at all. Not a setting: it comes from the bundle and the
        /// override file, and it decides whether the button can do anything.
        var hasGoogleCredentials = false
        /// The calendar Facet owns, from the same row as the identity.
        var googleCalendar = GoogleCalendarRules.Calendar.none
        /// Whether the debug trace is being gathered, from the `debug` row.
        var isDebugEnabled = DebugTraceRules.defaultEnabled
        /// Which folder the trace is kept in, **as it is stored**: a leading `~` is expanded where the file is
        /// opened, not here (`DebugTraceRules`).
        var debugDirectory = DebugTraceRules.defaultDirectory
        /// Whether there is a trace file to act on. **Not a setting**, and **not `isDebugEnabled`**: the file
        /// outlives both the launch that wrote it and logging being on, which is most of a support conversation --
        /// somebody turns logging on, reproduces the fault, quits, and sends the file from a launch that is
        /// recording nothing. Keying these buttons to whether a logger exists left all three dead beside an 800KB
        /// trace. With no file there is nothing to reveal, copy or empty, and they are dead for that reason instead.
        var hasDebugTrace = false

        /// What a database with none of these rows would give, which is what the seeds give
        /// (`database/011_setting.sql`). Named here rather than at each call site so one missing row cannot come to
        /// mean two different things.
        static let seeded = Values(
            showsSeconds: true,
            dailyResetHour24: AppSettingsRules.defaultResetHour24,
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
        case dailyResetHour12(Int)
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
        /// Make the calendar. **The only thing that makes one**: connecting an account does not, so this is the
        /// usual path rather than a recovery, and it stays available for as long as there is no calendar.
        case googleCalendarCreateRequested
        /// Delete the calendar, at Google. **The one request here that destroys something**, so the window confirms it
        /// before carrying it out. Carries no value: there is one calendar and only one thing to do to it.
        case googleCalendarDeleteRequested
        /// The calendar the table now holds, after Google answered and the write was read back.
        case googleCalendarChanged(GoogleCalendarRules.Calendar)
        /// What the Keychain now says. **Not a request and not a setting**: nobody edits this in the window, it is
        /// the other half of a fact the row only tells half of.
        case googleCredentialChanged(GoogleAccountRules.Credential)
        /// What Google said when asked whether the token still works. Arrives once per ask and is never stored,
        /// because it is true of a moment rather than of the account.
        case googleVerified(GoogleAccountRules.Verification)
        /// Whether the trace is gathered at all.
        case debugEnabled(Bool)
        /// Pick the folder the trace is kept in. **A request**: choosing one is a panel the window runs, this pane
        /// having no business putting anything modal on screen.
        case debugDirectoryRequested
        /// The folder that was picked, in the form the setting stores.
        case debugDirectory(String)
        /// Show the trace in the Finder. **A request**, and one that stores nothing: it opens somebody else's window.
        case debugRevealRequested
        /// Save a copy of the trace somewhere, to send in. **A request** for the same reason the folder is.
        case debugCopyRequested
        /// Empty the trace. **A request, and the destructive one**: the window confirms it before carrying it out.
        case debugClearRequested
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
    private let debugRows = NSStackView()

    /// The tab's sections, each folding away behind its own triangle. Exposed so a test can measure one without a
    /// window on screen.
    private(set) var appSection: PanelSection!
    private(set) var googleSection: PanelSection!
    /// The third section, folded when the tab is built. Exposed for the same reason the other two are.
    private(set) var debugSection: PanelSection!

    /// Where the Debug section hangs when the Google footnote is on show, and where it hangs when it is not.
    ///
    /// **Exactly one is active at a time.** A hidden view keeps its height in Auto Layout, so a Debug section
    /// anchored to the note would be pushed down by a sentence nobody can see -- which is the gap the note used to
    /// leave behind before anything was drawn under it.
    private var debugBelowNote: NSLayoutConstraint?
    private var debugBelowGoogle: NSLayoutConstraint?

    /// Called when either section opens or closes, so the window can record it. The Device tab hands its folds out
    /// the same way, identifier and all.
    ///
    /// **The pane keeps each section's own `onToggle` for itself**, and calls this from inside it. The Google section
    /// has work of its own to do on a fold (its footnote goes with it), so letting the window take that callback
    /// would silently replace the pane's handler with one that does not do it -- a fold that worked until the day
    /// somebody wired the window to it.
    var onSectionToggle: ((String, Bool) -> Void)?
    /// Transient, and deliberately not in `Values`: it is what the app is doing, not what the table says.
    private var isSigningIn = false
    private var showSecondsBox: NSButton!
    private var debugEnabledBox: NSButton!
    private var debugDirectoryValue: NSTextField!
    private var debugNote: NSTextField!
    private var debugRevealButton: NSButton!
    private var debugCopyButton: NSButton!
    private var debugClearButton: NSButton!
    private var dailyResetField: SteppedNumberField!
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
        case let .dailyResetHour12(value): values.dailyResetHour24 = AppSettingsRules.hour24(fromFace: value)
        case let .fetchIntervalMinutes(value): values.fetchIntervalSeconds = AppSettingsRules.seconds(fromMinutes: value)
        case let .blipSeconds(value): values.blipSeconds = value
        case .googleSignInRequested:
            // Nothing to take on: the answer arrives as `googleConnected` once the table has it.
            break
        case let .googleConnected(account):
            values.googleAccount = account
            // A sign-in that got this far stored a token, so both halves move together. Asserting the credential
            // here rather than leaving it at whatever it was is the difference between the section saying Connected
            // because it just watched it happen and saying it out of habit.
            values.googleCredential = .present
            values.googleVerification = .working
            showGoogle()
        case let .googleCredentialChanged(credential):
            values.googleCredential = credential
            showGoogle()
        case let .googleVerified(verification):
            values.googleVerification = verification
            showGoogle()
        case .googleCalendarNamed, .googleCalendarCreateRequested, .googleCalendarDeleteRequested:
            // Requests. What the calendar becomes arrives as `googleCalendarChanged`, including a deletion,
            // which arrives as the calendar becoming none.
            break
        case let .googleCalendarChanged(calendar):
            values.googleCalendar = calendar
            showGoogle()
        case .googleDisconnected:
            values.googleAccount = .none
            // Signing out clears the token as well as the identity, so both halves are put back together. Leaving
            // the credential at `.present` would leave the section one read away from claiming a connection to an
            // account it has just forgotten.
            values.googleCredential = .missing
            values.googleVerification = .notAsked
            // **The calendar is not forgotten here.** The id survives a sign-out so that signing back in on the same
            // account keeps the calendar and its history; it is checked on the way back in rather than trusted, and
            // only cleared once Google has said it is gone.
            // The one change here that *does* redraw its rows. The reason the others do not is that somebody is
            // typing in them, and taking a field out from under them is the harm being avoided. Nobody types into a
            // status line, and leaving it reading "Connected" under a button that just disconnected would be the
            // window showing something the table no longer says.
            showGoogle()
        case let .debugEnabled(on): values.isDebugEnabled = on
        case .debugDirectoryRequested:
            // A request. Which folder was picked arrives as `debugDirectory` once the table has it.
            break
        case .debugRevealRequested, .debugCopyRequested, .debugClearRequested:
            // None of them is a value. All three act on the file and leave every row on this tab as it was.
            break
        case let .debugDirectory(path):
            values.debugDirectory = path
            // Redrawn for the reason the status line above is: nobody types into this row, so there is no field to
            // take out from under anybody, and leaving it naming the previous folder would be the window showing
            // something the table no longer says.
            showDebugDirectory()
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
        dailyResetField.value = AppSettingsRules.hour12(from: values.dailyResetHour24)
        fetchIntervalField.value = AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds)
        fetchIntervalField.suffix = AppSettingsRules.unit("min", "mins", for: fetchIntervalField.value)
        blipTimeField.value = values.blipSeconds
        blipTimeField.suffix = AppSettingsRules.unit("sec", "secs", for: values.blipSeconds)
        debugEnabledBox.state = values.isDebugEnabled ? .on : .off
        showDebugDirectory()
        showDebugTrace()
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
        // Worked out once, at the top, and everything below reads it. Deriving it per control is how the status
        // label and the button came to be able to disagree in the first place.
        let state = GoogleAccountRules.state(
            for: account, credential: values.googleCredential, verification: values.googleVerification
        )
        var built: [NSView] = [
            SettingsRow.make(
                "Status", label(GoogleAccountRules.status(for: state), identifier: Identifier.googleStatus)
            ),
        ]
        if let name = account.name {
            built.append(SettingsRow.make("Account", label(name, identifier: Identifier.googleAccount)))
        }
        if let email = account.email {
            built.append(SettingsRow.make("Email", label(email, identifier: Identifier.googleEmail)))
        }

        if GoogleAccountRules.showsCalendar(for: state) {
            built.append(calendarRow())
        }

        let hasGoogleCredentials = values.hasGoogleCredentials
        let button = NSButton(
            title: GoogleAccountRules.buttonTitle(for: state, isSigningIn: isSigningIn),
            target: self,
            action: #selector(googleButtonPressed)
        )
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = GoogleAccountRules.isButtonEnabled(
            for: state, hasGoogleCredentials: hasGoogleCredentials, isSigningIn: isSigningIn
        )
        button.setAccessibilityIdentifier(Identifier.googleButton)
        let isForgetting = GoogleAccountRules.action(for: state) == .disconnect
        built.append(SettingsRow.make(isForgetting ? "Account" : "Google", button))

        for view in built {
            googleRows.addView(view, in: .top)
            view.widthAnchor.constraint(equalTo: googleRows.widthAnchor).isActive = true
        }
        googleNote.stringValue = GoogleAccountRules.note(
            for: state, hasGoogleCredentials: hasGoogleCredentials, verification: values.googleVerification
        ) ?? ""
        showGoogleNote()
    }

    /// Whether the footnote under the Google panel is on show.
    ///
    /// **Two things can take it away and both have to be asked**, which is why this is one place rather than a line
    /// in each. There may be nothing to say (`GoogleAccountRules.note` answering `nil`), or the section may be folded,
    /// in which case the button the sentence is about is not on screen to explain. Setting it from `showGoogle`
    /// alone would put the note back every time the account was redrawn, folded section or not.
    ///
    /// **What hangs below it moves with it**, which is why this is where the swap lives. A hidden view keeps its
    /// height in Auto Layout (`Tests/Methods.md`), so the Debug section is anchored either to the note or, when there
    /// is no note on show, to the Google section itself -- and hiding the sentence without moving that anchor would
    /// hold the section down the tab by the height of something nobody can see.
    private func showGoogleNote() {
        let isShowing = !googleNote.stringValue.isEmpty && googleSection?.isExpanded != false
        googleNote.isHidden = !isShowing
        // Deactivated before activating, always: both pin the same top edge, so the moment they overlap is an
        // unsatisfiable pair and a broken layout in the log.
        debugBelowNote?.isActive = false
        debugBelowGoogle?.isActive = false
        (isShowing ? debugBelowNote : debugBelowGoogle)?.isActive = true
    }

    /// Draws the folder the trace is kept in, in the form the setting stores it.
    private func showDebugDirectory() {
        debugDirectoryValue.stringValue = DebugTraceRules.display(values.debugDirectory)
        debugDirectoryValue.toolTip = debugDirectoryValue.stringValue
    }

    /// Lets a footnote be squeezed to the panel's width (`LabelWidth`), the measured 763pt demand behind that
    /// being the Debug note's.
    ///
    /// **The height needs nothing alongside it.** `NSTextFieldCell` sizes a wrapped label against the width it is
    /// actually given -- measured at 26pt for this two-line footnote inside a 588pt row, while
    /// `intrinsicContentSize` was still reporting the one-line 13. A `preferredMaxLayoutWidth` dance was written
    /// here first and taken out again: it reads frames that `super.layout()` has not yet resized, so it is always
    /// one pass behind on a window that is being dragged.
    private func wrap(_ note: NSTextField) {
        LabelWidth.mayGiveWay(note)
    }

    /// Takes on whether there is a trace file, which is not a setting and not something this pane can see: the file
    /// comes into being the moment logging starts writing, and goes when somebody moves it out from under the app.
    func showTrace(exists: Bool) {
        values.hasDebugTrace = exists
        showDebugTrace()
    }

    /// Dead when there is no trace file, there being nothing for any of the three to act on.
    private func showDebugTrace() {
        for button in [debugRevealButton, debugCopyButton, debugClearButton] {
            button?.isEnabled = values.hasDebugTrace
        }
    }

    /// The Calendar row: the name, editable, or a button to make one when there is none.
    ///
    /// **Editable only once the calendar exists.** Naming something that has not been created yet would be a field
    /// whose value has nowhere to go, and the create path uses the default name rather than asking for one: renaming
    /// it afterwards is the same act and is already here.
    ///
    /// **The button is the ordinary state of this row, not a fault.** An account connects without a calendar, so this
    /// is what a fresh sign-in shows, and it stays until somebody presses it.
    private func calendarRow() -> NSView {
        guard values.googleCalendar.exists else {
            let button = NSButton(
                title: "Create calendar", target: self, action: #selector(googleCalendarCreatePressed)
            )
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isEnabled = !isSigningIn
            button.setAccessibilityIdentifier(Identifier.googleCalendarCreate)
            return SettingsRow.make("Calendar", button)
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

        // **Beside the name, because it is the same subject.** The app can make this calendar and rename it, and
        // without this it could not undo either: a calendar made by mistake stayed in the account for good, and the
        // app went on holding something it does not own. It is the account's calendar, not Facet's.
        //
        // Destructive, so it says so rather than looking like the rest of the row, and the window confirms it.
        let delete = NSButton(title: "Delete", target: self, action: #selector(googleCalendarDeletePressed))
        delete.bezelStyle = .rounded
        delete.controlSize = .small
        delete.translatesAutoresizingMaskIntoConstraints = false
        delete.isEnabled = !isSigningIn
        delete.toolTip = "Delete this calendar and everything Facet has written to it"
        delete.setAccessibilityIdentifier(Identifier.googleCalendarDelete)

        let pair = NSStackView(views: [cell, delete])
        pair.orientation = .horizontal
        pair.spacing = Layout.headingSpacing
        pair.translatesAutoresizingMaskIntoConstraints = false
        return SettingsRow.make("Calendar", pair)
    }

    @objc
    private func googleCalendarDeletePressed() {
        onChange?(.googleCalendarDeleteRequested)
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
        let state = GoogleAccountRules.state(
            for: values.googleAccount,
            credential: values.googleCredential,
            verification: values.googleVerification
        )
        // The same state the title was drawn from, so the button cannot say one thing and do another. It used to be
        // decided from the identity alone, which meant a row with no token behind it offered Disconnect.
        onChange?(GoogleAccountRules.action(for: state) == .disconnect ? .googleDisconnected : .googleSignInRequested)
    }

    /// Two sections, App settings above Google, each folding away behind its own triangle.
    ///
    /// **The pane keeps its autoresizing frame**, so it is as wide as the window and both sections span that width
    /// (see `CLAUDE.md`). The tab view hands each pane the content rect and resizes it from there;
    /// `translatesAutoresizingMaskIntoConstraints = false` here would throw that away and leave the pane sized to its
    /// own contents, which is a panel stopping short of the right-hand edge. It did, until this.
    ///
    /// **The first two open and Debug does not**, and each section owns which it is (`CollapsibleSection`). App
    /// settings and Google are what somebody opens this tab to change, so a tab that showed only headings would be
    /// showing nothing to change; Debug is the Categories tab's Inactive case instead -- a group to go looking in
    /// occasionally, whose two rows are of no interest until something needs looking into. The fold is a gesture for
    /// getting one section out of the way while working in another, and a gesture does not outlive the window that
    /// made it.
    ///
    /// **The heading is now on the panel rather than above it**, which is what `CLAUDE.md` requires the moment a
    /// group folds: a heading that operates its panel belongs to it, and one floating above a panel it folds reads as
    /// a caption instead of a control.
    private func addSections() {
        stack(googleRows)
        showGoogle()

        googleNote.translatesAutoresizingMaskIntoConstraints = false
        googleNote.font = .preferredFont(forTextStyle: .footnote)
        googleNote.textColor = .secondaryLabelColor
        googleNote.lineBreakMode = .byWordWrapping
        googleNote.maximumNumberOfLines = 0
        googleNote.setAccessibilityIdentifier(Identifier.googleNote)
        wrap(googleNote)

        stack(rows)
        addRows()

        stack(debugRows)
        addDebugRows()

        let app = section(title: "App settings", identifier: Identifier.section, content: rows)
        let google = section(title: "Google", identifier: Identifier.googleSection, content: googleRows)
        let debug = section(
            title: "Debug", identifier: Identifier.debugSection, content: debugRows, isExpanded: false
        )
        appSection = app
        googleSection = google
        debugSection = debug

        app.onToggle = { [weak self] expanded in
            self?.onSectionToggle?(Identifier.section, expanded)
        }
        google.onToggle = { [weak self] expanded in
            self?.onSectionToggle?(Identifier.googleSection, expanded)
        }
        debug.onToggle = { [weak self] expanded in
            self?.onSectionToggle?(Identifier.debugSection, expanded)
        }
        // **The note goes with the section it explains.** It says why the button above it cannot be pressed, so a
        // folded Google section that left the sentence behind would be an explanation of something no longer on
        // screen. Nothing is anchored below it, so hiding it is the whole of taking it away.
        //
        // **Hung off the state and not off the gesture**, which is the difference between the two hooks: the window
        // folds these back to open every time Settings is shown, and that path is silent.
        google.onExpandedChanged = { [weak self] _ in self?.showGoogleNote() }

        // **App settings first, because that is the order they are drawn in.** Subview order is what
        // accessibility reads, and it is not the constraints: the Google section moved to the bottom of the
        // tab, and adding it first left VoiceOver announcing it before the four settings sitting above it on
        // screen. Nothing looks wrong, which is exactly why it stayed wrong -- it was found by a script
        // dumping the tree, not by looking at the tab.
        for view in [app as NSView, google, googleNote, debug] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            app.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            google.topAnchor.constraint(equalTo: app.bottomAnchor, constant: Layout.sectionSpacing),
            googleNote.topAnchor.constraint(equalTo: google.bottomAnchor, constant: Layout.headingSpacing / 2),
        ])

        // **Two ways for Debug to hang, because the note above it comes and goes.** A hidden view keeps its height,
        // so anchoring only to the note would leave a sentence nobody can see holding this section down the tab.
        // `showGoogleNote` is the one place that decides which, the note having two reasons to be away.
        debugBelowNote = debug.topAnchor.constraint(
            equalTo: googleNote.bottomAnchor, constant: Layout.sectionSpacing
        )
        debugBelowGoogle = debug.topAnchor.constraint(
            equalTo: google.bottomAnchor, constant: Layout.sectionSpacing
        )
        showGoogleNote()

        for view in [app as NSView, google, googleNote, debug] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            ])
        }
    }

    /// One of the tab's two sections.
    ///
    /// **Nothing is overridden any more, which is the whole of what makes this tab match the Categories tab.** It
    /// used to pass `contentInset: 0` and inset each row itself with `rowInset`, so that the hairlines between rows
    /// ended where the archive's did. There are no hairlines now, so that exception buys nothing and costs the one
    /// thing worth having: a row starting at the same x on both tabs. Everything a section is -- where the triangle
    /// sits, the gap under the heading, the corner, the inset -- now comes from `SettingsMetrics` for all three.
    ///
    /// **No label is passed**, because "App settings", "Google" and "Debug" already say what they are. The
    /// Categories tab passes one; "Active" announced on its own does not mean anything.
    ///
    /// - Parameter isExpanded: what the section is built as, and so what opening Settings puts it back to.
    private func section(
        title: String, identifier: String, content: NSView, isExpanded: Bool = true
    ) -> PanelSection {
        PanelSection(
            title: title,
            identifier: identifier,
            isExpanded: isExpanded,
            content: content
        )
    }

    private func stack(_ view: NSStackView) {
        view.orientation = .vertical
        view.alignment = .leading
        // **The gap is what divides the rows**, which is how the Categories tab has always done it. This was 0 while
        // hairlines did the dividing and the padding inside each row held them apart -- which is what made the rows
        // here half again as tall as that tab's.
        view.spacing = Layout.rowSpacing
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The archive's rows, in the archive's order: the switch first, then the three numbers.
    ///
    /// **Two of the archive's six are not here**, both of them now on the Device tab: "Pause the device when locking
    /// it" above Auto-pause, and "Battery warning at" under it. Both are about the cube rather than about the app,
    /// which is what that tab's Settings section is.
    private func addRows() {
        showSecondsBox = box(identifier: Identifier.showSeconds, action: #selector(showSecondsChanged))

        dailyResetField = field(
            identifier: Identifier.dailyReset,
            value: AppSettingsRules.hour12(from: values.dailyResetHour24),
            range: AppSettingsRules.resetHours,
            suffix: AppSettingsRules.resetSuffix,
            change: Change.dailyResetHour12
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
            ("Daily reset at", dailyResetField),
            ("Fetch history every", fetchIntervalField),
            // Turning the cube to the face somebody wants drags it past the others, and each pass-over is a real
            // segment the device reports. This is how short one has to be to count as getting there rather than as
            // time spent.
            ("Ignore flips under", blipTimeField),
        ]
        for (title, control) in built {
            let view = SettingsRow.make(title, control)
            rows.addView(view, in: .top)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    /// The Debug section: whether the trace is gathered, the folder it is kept in, and getting hold of the file.
    ///
    /// **Three rows and a sentence, and the sentence is the part that has to be there.** What the folder holds is a
    /// file with a name nobody picked, and a folder changed here is not the folder this launch opened -- the trace
    /// database is open from launch to quit, so the change lands on the next one. Both of those are invisible from
    /// the rows themselves.
    ///
    /// **The third row is why the folder does not have to be findable.** Somebody who has been asked to send their
    /// trace in presses Reveal in Finder and the file is selected in front of them, or presses Save a copy and picks
    /// where it goes. Neither asks them to navigate to a path, which is what the folder would otherwise be for.
    ///
    /// **Clear is beside them because it belongs to the same gesture**: the useful thing to do before reproducing a
    /// fault is to empty the trace, so what gets sent is the fault and not a fortnight of everything else. It is the
    /// destructive one, so the window confirms it.
    ///
    /// **Inside the panel rather than under it**, unlike the Google footnote: this one has no reason to outlive its
    /// section, so being a row of the list is the whole of making it fold.
    private func addDebugRows() {
        debugEnabledBox = box(identifier: Identifier.debugEnabled, action: #selector(debugEnabledChanged))

        debugDirectoryValue = NSTextField(labelWithString: "")
        debugDirectoryValue.translatesAutoresizingMaskIntoConstraints = false
        // The path is the longest thing on this tab and the one row that cannot be shortened by rewording. Truncated
        // in the middle, since both ends carry the answer: which volume it is on, and which folder it ends in.
        debugDirectoryValue.lineBreakMode = .byTruncatingMiddle
        debugDirectoryValue.setAccessibilityIdentifier(Identifier.debugDirectory)
        showDebugDirectory()

        let choose = NSButton(title: "Choose", target: self, action: #selector(debugDirectoryPressed))
        choose.bezelStyle = .rounded
        choose.controlSize = .small
        choose.translatesAutoresizingMaskIntoConstraints = false
        choose.setAccessibilityIdentifier(Identifier.debugDirectoryChoose)

        let pair = NSStackView(views: [debugDirectoryValue, choose])
        pair.orientation = .horizontal
        pair.spacing = Layout.headingSpacing
        pair.translatesAutoresizingMaskIntoConstraints = false

        debugRevealButton = traceButton(
            "Reveal in Finder", identifier: Identifier.debugReveal, action: #selector(debugRevealPressed)
        )
        debugCopyButton = traceButton(
            "Save a copy", identifier: Identifier.debugCopy, action: #selector(debugCopyPressed)
        )
        debugCopyButton.toolTip = "Write a copy of the trace to send in"
        debugClearButton = traceButton(
            "Clear", identifier: Identifier.debugClear, action: #selector(debugClearPressed)
        )
        debugClearButton.toolTip = "Empty the trace, so what follows starts from nothing"
        let buttons = NSStackView(views: [debugRevealButton, debugCopyButton, debugClearButton])
        buttons.orientation = .horizontal
        buttons.spacing = Layout.headingSpacing
        buttons.translatesAutoresizingMaskIntoConstraints = false
        showDebugTrace()

        let note = NSTextField(
            labelWithString: "Logging starts and stops as this is switched, and is kept in a file called "
                + "debug.sqlite in this folder. A folder chosen here is used from the next time Facet starts."
        )
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.setAccessibilityIdentifier(Identifier.debugNote)
        wrap(note)
        debugNote = note

        let built: [NSView] = [
            SettingsRow.make("Debug logging", debugEnabledBox),
            SettingsRow.make("Directory", pair),
            SettingsRow.make("Trace file", buttons),
            note,
        ]
        for view in built {
            debugRows.addView(view, in: .top)
            view.widthAnchor.constraint(equalTo: debugRows.widthAnchor).isActive = true
        }
    }

    @objc
    private func debugEnabledChanged() {
        onChange?(.debugEnabled(debugEnabledBox.state == .on))
    }

    @objc
    private func debugDirectoryPressed() {
        onChange?(.debugDirectoryRequested)
    }

    @objc
    private func debugRevealPressed() {
        onChange?(.debugRevealRequested)
    }

    @objc
    private func debugCopyPressed() {
        onChange?(.debugCopyRequested)
    }

    @objc
    private func debugClearPressed() {
        onChange?(.debugClearRequested)
    }

    private func traceButton(_ title: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(identifier)
        return button
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

}

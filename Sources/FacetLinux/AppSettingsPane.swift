import CGtk
import FacetCore
import Foundation

/// The App tab: the app's own preferences, and the debug trace.
///
/// **Three sections, as of 2026-09-18**: the app's preferences, the Google account, and the debug trace. The
/// Google one was absent until the listener became a port with an adapter this platform could be handed
/// (item 16's Linux half), because drawing a Connect button that cannot connect would be the control that looks
/// live and does nothing, which this app refuses everywhere else.
///
/// **What the Google section does and does not do.** It signs in, says who is connected and whether there is a
/// token behind that, and disconnects. It does **not** manage the calendar -- create, rename or delete -- which is
/// another ~200 lines of `SettingsWindowController` and is named in `docs/linux-port.md` rather than half-built
/// here. A sweep still reaches the calendar the table already names, `CalendarSync` needing no window.
///
/// **Every row is written straight through and read back**, which is `CLAUDE.md`'s licence for an open Settings
/// window: the window holds what it read when it opened, a changed field is written through `AppSettingWrite`, and
/// the row is put back with an alert if the table refuses it. What is decided about a change -- which setting, which
/// field, which type, and the conversion between what a control offers and what the row holds -- is
/// `AppSettingsRules`', in the core, for both platforms.
///
/// **The values are read once, on open.** That is the one place this app holds a setting rather than re-reading it,
/// and the conditions are the rule's own: every tab's settings in one go, written through, read back, and given up
/// when the window closes. Here the window is destroyed on close, so giving up happens by itself.
@MainActor
final class AppSettingsPane {
    let widget: UnsafeMutablePointer<GtkWidget>

    private let settings: SettingStore
    private let debugLog: DebugLog?
    private let dialogues: DialoguePresenter
    private let timingChanged: () -> Void

    /// Connecting and disconnecting a Google account, which is core: every ordering in a sign-in -- what is refused
    /// before a browser opens, when the token is saved against when the rows are written, what is read back
    /// afterwards -- is `GoogleConnection`'s, and the same module the Mac is asked to adopt.
    private let google: GoogleConnection

    /// The calendar Facet owns in that account, which is a second subject rather than more of the first: an account
    /// is who is signed in, and a calendar is a thing in it that this app writes to. Signing out keeps the calendar
    /// deliberately, so the two have different lifetimes.
    private let calendar: GoogleCalendar

    /// What Google last said about the saved sign-in, and what the calendar is. **Held for as long as the window is
    /// open and never written down**, which is the point: both are true of the moment they were asked, and a
    /// `setting` row holding either would be the stale copy the check exists to prevent.
    private var signInCheck: GoogleCalendar.SignInCheck?
    private var storedCalendar = GoogleCalendarRules.Calendar.none

    /// Whether a request is out right now -- a sign-in, a create, a rename, a delete. Not a row: it is what the app
    /// is doing, and the controls say so rather than looking pressable twice.
    private var isWorking = false

    /// Told when an account is connected, so a sweep can happen: somebody who signs in after a week of recorded
    /// time has a week to send, and nothing else would ask.
    private let googleConnected: () -> Void

    /// Whether a sign-in is out right now, which is the one thing here that is not a row: it is what the app is
    /// doing, and the button says so rather than looking pressable twice.
    private var isSigningIn = false

    private let preferences: UnsafeMutablePointer<GtkWidget>
    private let googleRows: UnsafeMutablePointer<GtkWidget>
    private let debugRows: UnsafeMutablePointer<GtkWidget>
    private var signals = GtkSignals()

    /// What the table said when the window opened, and what the rows are drawn from.
    ///
    /// **The one held copy in this window**, under the conditions `CLAUDE.md` sets for one: read in a single pass on
    /// open, updated only after a write has been read back, and gone when the window closes. A value the table gains
    /// meanwhile is overwritten, which is the rule's fourth condition -- this window read the setting when it opened
    /// and has been the answer since.
    private var values = Values.seeded

    /// What the App tab shows, in one struct, so opening the window is one pass over the table rather than a read
    /// per control.
    struct Values: Equatable {
        var showsSeconds: Bool
        var dailyResetHour24: Int
        var fetchIntervalSeconds: Int
        var blipSeconds: Int
        var isDebugEnabled: Bool
        var debugDirectory: String
        /// Whether there is a trace file to act on. **Not a setting, and not `isDebugEnabled`**: the file outlives
        /// both the launch that wrote it and logging being on, which is most of a support conversation -- somebody
        /// turns logging on, reproduces the fault, quits, and sends the file from a launch that is recording
        /// nothing.
        var hasDebugTrace: Bool

        /// What a database with none of these rows would give, which is what the seeds give
        /// (`database/011_setting.sql`).
        static let seeded = Values(
            showsSeconds: AppSettingsRules.defaultShowsSeconds,
            dailyResetHour24: AppSettingsRules.defaultResetHour24,
            fetchIntervalSeconds: AppSettingsRules.defaultFetchIntervalSeconds,
            blipSeconds: AppSettingsRules.defaultBlipSeconds,
            isDebugEnabled: DebugTraceRules.defaultEnabled,
            debugDirectory: DebugTraceRules.defaultDirectory,
            hasDebugTrace: false
        )
    }

    init(
        settings: SettingStore,
        dialogues: DialoguePresenter,
        google: GoogleConnection,
        calendar: GoogleCalendar,
        googleConnected: @escaping () -> Void,
        debugLog: DebugLog?,
        timingChanged: @escaping () -> Void
    ) {
        self.settings = settings
        self.dialogues = dialogues
        self.google = google
        self.calendar = calendar
        self.googleConnected = googleConnected
        self.debugLog = debugLog
        self.timingChanged = timingChanged

        widget = SettingsWidgets.column(spacing: Int(SettingsMetrics.sectionSpacing))
        SettingsWidgets.identify(widget, SettingsTab.app.paneIdentifier)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(widget, Int32(SettingsMetrics.tabPadding))
        }
        preferences = SettingsWidgets.column()
        debugRows = SettingsWidgets.column()

        let preferencesSection = PanelSection(
            title: "App settings",
            identifier: "app-settings-section",
            isExpanded: true,
            content: preferences
        )
        googleRows = SettingsWidgets.column()
        let googleSection = PanelSection(
            title: "Google",
            identifier: "app-google-section",
            isExpanded: true,
            content: googleRows
        )
        googleSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "App section Google \(isExpanded ? "opened" : "folded")")
        }

        let debugSection = PanelSection(
            title: "Debug",
            identifier: "app-debug-section",
            // **Closed, because it is not an everyday control.** The trace is a thing somebody is asked to turn on
            // during a support conversation, and it costs disk while it is on.
            isExpanded: false,
            content: debugRows
        )
        preferencesSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "App section App settings \(isExpanded ? "opened" : "folded")")
        }
        debugSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "App section Debug \(isExpanded ? "opened" : "folded")")
        }
        sections = [preferencesSection, googleSection, debugSection]
        facet_box_pack_start(widget, preferencesSection.widget, 0, 1, 0)
        facet_box_pack_start(widget, googleSection.widget, 0, 1, 0)
        facet_box_pack_start(widget, debugSection.widget, 0, 1, 0)
    }

    /// Held because a `PanelSection` owns its own handlers, and GTK retains the widgets rather than the Swift object
    /// around them.
    private var sections: [PanelSection] = []

    /// The calendar's name cell, held because it owns its own handlers.
    private var calendarNameCell: EditableNameCell?

    /// Reads every value this tab shows, in one go, and draws them.
    ///
    /// **One pass rather than a read per control**, which is the rule's first condition for a window that may hold
    /// what it shows. Each row falls back to what a fresh database would have seeded, because `SettingStore` answers
    /// `nil` for a missing or malformed row and refuses to guess what absence means.
    func reload() {
        let seeded = Values.seeded
        values = Values(
            showsSeconds: settings.flag("display_seconds", field: "enabled") ?? seeded.showsSeconds,
            dailyResetHour24: settings.integer("daily_reset_time", field: "hour") ?? seeded.dailyResetHour24,
            fetchIntervalSeconds: settings.integer("fetch_history_interval_seconds", field: "seconds")
                ?? seeded.fetchIntervalSeconds,
            blipSeconds: settings.integer("blip_time", field: "seconds") ?? seeded.blipSeconds,
            isDebugEnabled: settings.flag(DebugTraceRules.setting, field: DebugTraceRules.enabledField)
                ?? seeded.isDebugEnabled,
            debugDirectory: settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)
                ?? seeded.debugDirectory,
            hasDebugTrace: DebugTraceFile.inUse(
                by: debugLog,
                directory: settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)
                    ?? seeded.debugDirectory
            ).exists
        )
        storedCalendar = calendar.stored()
        redraw()
        checkTheSignIn()
    }

    /// Asks Google whether the saved sign-in still works, and draws what came back.
    ///
    /// **It never puts anything on screen but a row.** No alert, no failure dialogue: opening a tab is not somebody
    /// asking for a calendar, and a check that could interrupt would make this tab a thing you brace for.
    ///
    /// **Nothing to verify without an identity**, which is not a skipped step: asking Google about an account nobody
    /// named is a request that cannot have an answer, and the section already says *Not connected*.
    private func checkTheSignIn() {
        guard google.stored().hasGoogleIdentity else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            signInCheck = await calendar.check()
            redraw()
        }
    }

    private func redraw() {
        for child in SettingsWidgets.children(of: preferences)
            + SettingsWidgets.children(of: googleRows)
            + SettingsWidgets.children(of: debugRows)
        {
            gtk_widget_destroy(child)
        }
        signals = GtkSignals()
        drawPreferences()
        drawGoogle()
        drawDebug()
        gtk_widget_show_all(widget)
    }

    // MARK: - the Google account

    /// **Two readings and one control**, and both readings are read at the moment they are drawn: who the table
    /// says is connected, and whether the secret store has a token behind that. One without the other is the
    /// half-answer that let this section say Connected with nothing behind it on the Mac.
    ///
    /// **The status wording is `GoogleAccountRules`'**, including the distinction the whole thing turns on: a store
    /// that could not be read is not somebody who is signed out, and saying so would push them through a browser
    /// consent to fix a keyring that was merely locked.
    private func drawGoogle() {
        let account = google.stored()
        let state = GoogleAccountRules.state(
            for: account,
            credential: credential(),
            verification: verification()
        )
        let status = GoogleAccountRules.status(for: state)
        facet_box_pack_start(googleRows, reading("Account", account.email ?? status, "app-google-account"), 0, 1, 0)
        facet_box_pack_start(googleRows, reading("Status", status, "app-google-status"), 0, 1, 0)

        if account.hasGoogleIdentity {
            facet_box_pack_start(googleRows, calendarRow(), 0, 1, 0)
        }

        let hasCredentials = GoogleCredentials.resolve() != nil
        let button = gtk_button_new_with_label(
            isSigningIn ? "Connecting…" : (account.hasGoogleIdentity ? "Disconnect" : "Connect")
        )!
        SettingsWidgets.identify(button, account.hasGoogleIdentity ? "app-google-disconnect" : "app-google-connect")
        // **Dead where this build has no OAuth client in it**, which is not a setting and cannot be fixed from
        // here: `GoogleCredentials.resolve` reads the bundle and an override file, and a Connect button in a build
        // with neither is one that can only fail.
        gtk_widget_set_sensitive(button, hasCredentials && !isSigningIn ? 1 : 0)
        gtk_widget_set_tooltip_text(
            button,
            hasCredentials ? nil : "This build has no Google client in it, so there is nothing to connect to"
        )
        signals.connect(button, "clicked") { [weak self] in
            guard let self else { return }
            account.hasGoogleIdentity ? disconnect() : signIn()
        }
        facet_box_pack_start(googleRows, row("", control: button), 0, 1, 0)
    }

    /// The calendar row: its name, and the one control that fits what there is.
    ///
    /// **Create when there is none, and that is a state rather than a gap.** Signing in connects an account; it is
    /// not somebody asking for a calendar in it. Pressing Create late costs nothing -- every entry recorded since is
    /// swept into the new calendar, oldest first.
    private func calendarRow() -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row()
        gtk_widget_set_size_request(line, -1, Int32(SettingsMetrics.rowHeight))
        facet_box_pack_start(line, SettingsWidgets.label("Calendar"), 0, 1, 0)

        guard let id = storedCalendar.id, !id.isEmpty else {
            let create = gtk_button_new_with_label(isWorking ? "Working…" : "Create calendar")!
            SettingsWidgets.identify(create, "app-google-calendar-create")
            gtk_widget_set_sensitive(create, isWorking ? 0 : 1)
            signals.connect(create, "clicked") { [weak self] in self?.createCalendar() }
            facet_box_pack_end(line, create, 0, 0, 0)
            return line
        }

        let delete = gtk_button_new_with_label("Delete")!
        SettingsWidgets.identify(delete, "app-google-calendar-delete")
        gtk_widget_set_sensitive(delete, isWorking ? 0 : 1)
        signals.connect(delete, "clicked") { [weak self] in self?.deleteCalendar() }
        facet_box_pack_end(line, delete, 0, 0, 0)

        // The name, renamed in place: the same cell the Categories tab and the Device tab use, so a name edited
        // anywhere in this app behaves the same way.
        let cell = EditableNameCell(
            name: storedCalendar.name ?? GoogleCalendarRules.defaultName,
            identifier: "app-google-calendar-name",
            isEnabled: !isWorking
        )
        cell.onCommit = { [weak self] typed in self?.renameCalendar(to: typed) }
        calendarNameCell = cell
        facet_box_pack_end(line, cell.widget, 0, 0, 0)
        return line
    }

    /// What the store says about the token, which the row cannot say.
    private func credential() -> GoogleAccountRules.Credential {
        switch signInCheck {
        case .notSignedIn: return .missing
        case .storeUnavailable: return .unavailable
        case nil, .working, .unreachable, .refused: return google.credential()
        }
    }

    /// What Google last said, which is `notAsked` until it has been asked -- and stays that way for an account with
    /// no identity, because there is nothing to ask about.
    private func verification() -> GoogleAccountRules.Verification {
        switch signInCheck {
        case .working: return .working
        case let .unreachable(reason): return .unreachable(reason)
        case let .refused(reason): return .refused(reason)
        case nil, .notSignedIn, .storeUnavailable: return .notAsked
        }
    }

    private func createCalendar() {
        debugLog?.record(.click, "Button clicked: Create calendar")
        work { await self.calendar.create() }
    }

    private func renameCalendar(to typed: String) {
        work { await self.calendar.rename(to: typed) }
    }

    private func deleteCalendar() {
        debugLog?.record(.click, "Button clicked: Delete calendar")
        // **Asked before it is done, and the asking is the core's.** It is the only thing this app destroys.
        calendar.delete { [weak self] settled in self?.adopt(settled) }
    }

    /// Runs one calendar request, with the controls dead while it is out.
    private func work(_ request: @escaping () async -> GoogleCalendar.Settled) {
        isWorking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            redraw()
            let settled = await request()
            isWorking = false
            adopt(settled)
        }
    }

    /// Takes what a calendar request came to: the row follows the table, and a failure says so.
    private func adopt(_ settled: GoogleCalendar.Settled) {
        isWorking = false
        switch settled {
        case let .calendar(calendar):
            storedCalendar = calendar
            // **A calendar becoming available is a sweep's moment**, and nothing else would ask: every entry
            // recorded before it existed is waiting.
            googleConnected()
        case .none:
            storedCalendar = .none
        case let .failed(notice):
            // Read back rather than assumed: a failed rename leaves the row showing what the table holds.
            storedCalendar = calendar.stored()
            dialogues.tell(notice)
        }
        redraw()
    }

    /// Opens a browser and waits for the redirect.
    ///
    /// **The browser is the one line this platform owns**, which is what `GoogleSignIn.run` says by refusing a
    /// default for it: `xdg-open` here, `NSWorkspace` there, and the whole of the rest is core.
    private func signIn() {
        isSigningIn = true
        debugLog?.record(.click, "Button clicked: Connect Google")
        redraw()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = await google.signIn(
                open: { [weak self] url in self?.openInABrowser(url) },
                listening: { try SocketLoopbackListener(expectedState: $0) }
            )
            isSigningIn = false
            switch answer {
            case let .connected(_, accessToken):
                // **Settling a calendar is checking the stored one, never making a new one**: signing in is an
                // account being connected, not a calendar being asked for. The access token is already in hand, so
                // this costs no refresh.
                adopt(await calendar.settle(accessToken: accessToken))
                // **A week of recorded time may be waiting**, and nothing else would ask: a sweep happens when an
                // entry is recorded, and somebody who signs in afterwards has already missed all of them.
                googleConnected()
                checkTheSignIn()
            case let .failed(notice):
                dialogues.tell(notice)
            }
            redraw()
        }
    }

    /// Hands the sign-in URL to the desktop's browser, and says what became of that.
    ///
    /// **The URL is written to the trace every time, not only on failure**, and that is a decision rather than
    /// debugging left in. A desktop can report success and show nobody anything -- measured on this box
    /// 2026-09-19, where `xdg-open` exits 0 and the Firefox it hands the URL to has no visible window -- and at
    /// that point the sign-in is live, the loopback listener is up, and the only thing missing is a person seeing
    /// the page. The URL in the trace is what lets them finish it by pasting it somewhere they can see.
    ///
    /// **It carries no secret.** The client id is public by design for an installed app, the redirect is
    /// `127.0.0.1`, and what stands in for the secret is the PKCE *challenge* -- a hash whose verifier never
    /// leaves this process (`GoogleOAuthRules.pkce`).
    ///
    /// **Waited for, rather than launched and forgotten.** `xdg-open` returns as soon as it has handed off, so the
    /// wait is short, and its exit status is the only thing that distinguishes a desktop that took the URL from
    /// one with no handler for `https` at all. A status nobody reads is the swallowed failure `CLAUDE.md` names
    /// twice.
    private func openInABrowser(_ url: URL) {
        debugLog?.record(.field, "The sign-in URL is \(url.absoluteString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else {
                debugLog?.record(.field, "The desktop was given the sign-in URL")
                return
            }
            debugLog?.record(
                .field,
                "xdg-open refused the sign-in URL, exit \(process.terminationStatus)"
            )
        } catch {
            debugLog?.record(.field, "A browser could not be opened: \(error.localizedDescription)")
        }
        dialogues.tell(Dialogue(
            title: "Facet could not open a browser",
            message: """
            The sign-in is waiting and the page could not be opened here. The address is in the debug trace: \
            open it in a browser on this machine to finish signing in.
            """
        ))
    }

    private func disconnect() {
        debugLog?.record(.click, "Button clicked: Disconnect Google")
        if let notice = google.disconnect() {
            dialogues.tell(notice)
        }
        redraw()
    }

    /// One reading: the words on the left, the value on the right, as the Device tab draws its readings.
    private func reading(
        _ label: String,
        _ value: String,
        _ identifier: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row()
        gtk_widget_set_size_request(line, -1, Int32(SettingsMetrics.rowHeight))
        facet_box_pack_start(line, SettingsWidgets.label(label), 0, 1, 0)
        let text = SettingsWidgets.label(value)
        SettingsWidgets.identify(text, identifier, saying: value)
        facet_box_pack_end(line, text, 0, 0, 0)
        return line
    }

    // MARK: - the preferences

    private func drawPreferences() {
        facet_box_pack_start(preferences, secondsRow(), 0, 1, 0)
        facet_box_pack_start(preferences, resetRow(), 0, 1, 0)
        facet_box_pack_start(preferences, fetchRow(), 0, 1, 0)
        facet_box_pack_start(preferences, blipRow(), 0, 1, 0)
    }

    private func secondsRow() -> UnsafeMutablePointer<GtkWidget> {
        let box = gtk_check_button_new_with_label("Show seconds in the menu bar")!
        SettingsWidgets.identify(box, "app-display-seconds")
        facet_toggle_set_active(box, values.showsSeconds ? 1 : 0)
        signals.connect(box, "toggled") { [weak self] in
            guard let self else { return }
            let wanted = facet_toggle_get_active(box) != 0
            guard wanted != values.showsSeconds else { return }
            apply(.showsSeconds(wanted)) { [weak self] in self?.values.showsSeconds = wanted }
        }
        return row("", control: box)
    }

    /// The hour the app's day turns over, on a clock face.
    ///
    /// **12 on the control and 24 in the row**, which is `AppSettingsRules`' conversion in both directions: the
    /// archive offered a clock-face hour, and the table holds what a comparison needs.
    private func resetRow() -> UnsafeMutablePointer<GtkWidget> {
        let field = gtk_spin_button_new_with_range(1, 12, 1)!
        SettingsWidgets.identify(field, "app-daily-reset")
        facet_spin_set_value(field, Double(AppSettingsRules.hour12(from: values.dailyResetHour24)))
        signals.connect(field, "value-changed") { [weak self] in
            guard let self else { return }
            let hour12 = Int(facet_spin_get_value_as_int(field))
            guard hour12 != AppSettingsRules.hour12(from: values.dailyResetHour24) else { return }
            apply(.dailyResetHour12(hour12)) { [weak self] in
                self?.values.dailyResetHour24 = AppSettingsRules.hour24(fromFace: hour12)
            }
        }
        return row("The day starts at", control: field, suffix: "am")
    }

    private func fetchRow() -> UnsafeMutablePointer<GtkWidget> {
        let minutes = AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds)
        let field = gtk_spin_button_new_with_range(1, 60, 1)!
        SettingsWidgets.identify(field, "app-fetch-interval")
        facet_spin_set_value(field, Double(minutes))
        signals.connect(field, "value-changed") { [weak self] in
            guard let self else { return }
            let wanted = Int(facet_spin_get_value_as_int(field))
            guard wanted != AppSettingsRules.minutes(fromSeconds: values.fetchIntervalSeconds) else { return }
            apply(.fetchIntervalMinutes(wanted)) { [weak self] in
                self?.values.fetchIntervalSeconds = AppSettingsRules.seconds(fromMinutes: wanted)
            }
        }
        return row("Ask the cube for its history every", control: field, suffix: "min")
    }

    private func blipRow() -> UnsafeMutablePointer<GtkWidget> {
        let field = gtk_spin_button_new_with_range(0, 60, 1)!
        SettingsWidgets.identify(field, "app-blip-time")
        facet_spin_set_value(field, Double(values.blipSeconds))
        signals.connect(field, "value-changed") { [weak self] in
            guard let self else { return }
            let wanted = Int(facet_spin_get_value_as_int(field))
            guard wanted != values.blipSeconds else { return }
            apply(.blipSeconds(wanted)) { [weak self] in self?.values.blipSeconds = wanted }
        }
        return row("Ignore turns shorter than", control: field, suffix: "sec")
    }

    // MARK: - the debug trace

    private func drawDebug() {
        let box = gtk_check_button_new_with_label("Record a debug trace")!
        SettingsWidgets.identify(box, "app-debug-enabled")
        facet_toggle_set_active(box, values.isDebugEnabled ? 1 : 0)
        signals.connect(box, "toggled") { [weak self] in
            guard let self else { return }
            let wanted = facet_toggle_get_active(box) != 0
            guard wanted != values.isDebugEnabled else { return }
            apply(.debugEnabled(wanted)) { [weak self] in
                guard let self else { return }
                values.isDebugEnabled = wanted
                // **Told here, and only here, and only now.** `DebugLog.isRecording` is a copy of this row held in
                // memory; what keeps it honest is that this is the single place it is set, and that it is set after
                // the write has been read back. A logger told before the table agreed would be recording on the
                // strength of a write that did not happen.
                debugLog?.setRecording(wanted)
                // Turning it on writes the first row, which brings the file into being -- and the buttons below are
                // drawn from whether there is a file.
                values.hasDebugTrace = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory).exists
                redraw()
            }
        }
        facet_box_pack_start(debugRows, row("", control: box), 0, 1, 0)

        let directory = gtk_entry_new()!
        SettingsWidgets.identify(directory, "app-debug-directory")
        facet_entry_set_text(directory, values.debugDirectory)
        facet_entry_set_placeholder(directory, DebugTraceRules.defaultDirectory)
        signals.connect(directory, "activate") { [weak self] in
            guard let self else { return }
            let typed = String(cString: facet_entry_get_text(directory))
            guard typed != values.debugDirectory else { return }
            apply(.debugDirectory(typed)) { [weak self] in
                guard let self else { return }
                values.debugDirectory = typed
                values.hasDebugTrace = DebugTraceFile.inUse(by: debugLog, directory: typed).exists
                redraw()
            }
        }
        facet_box_pack_start(debugRows, row("Kept in", control: directory), 0, 1, 0)

        // **Two buttons where the Mac has three.** Reveal opens the folder in whatever this desktop uses for one;
        // Empty clears the trace. There is no Copy, which on the Mac puts the file on the clipboard through
        // `NSPasteboard` -- the Linux equivalent is a save dialogue, and a file manager already has one.
        let buttons = SettingsWidgets.row(spacing: Int(SettingsMetrics.rowSpacing))
        let reveal = gtk_button_new_with_label("Show the folder")!
        SettingsWidgets.identify(reveal, "app-debug-reveal")
        gtk_widget_set_sensitive(reveal, values.hasDebugTrace ? 1 : 0)
        signals.connect(reveal, "clicked") { [weak self] in self?.revealTrace() }
        facet_box_pack_start(buttons, reveal, 0, 0, 0)

        let clear = gtk_button_new_with_label("Empty the trace")!
        SettingsWidgets.identify(clear, "app-debug-clear")
        gtk_widget_set_sensitive(clear, values.hasDebugTrace ? 1 : 0)
        signals.connect(clear, "clicked") { [weak self] in self?.clearTrace() }
        facet_box_pack_start(buttons, clear, 0, 0, 0)
        facet_box_pack_start(debugRows, row("", control: buttons), 0, 1, 0)
    }

    /// Opens the folder the trace is in.
    ///
    /// **`xdg-open`, which is this platform's `NSWorkspace`**: the desktop's own answer to "show me this", and the
    /// one thing here that is genuinely a platform capability rather than a row.
    private func revealTrace() {
        let file = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [file.url.deletingLastPathComponent().path]
        do {
            try process.run()
            debugLog?.record(.click, "Button clicked: Show the folder, \(file.url.deletingLastPathComponent().path)")
        } catch {
            // **Said rather than swallowed.** A button that silently does nothing is the fault `CLAUDE.md` names
            // twice, and a desktop without `xdg-open` is a real machine rather than a hypothetical one.
            debugLog?.record(.click, "The folder could not be opened: \(error.localizedDescription)")
            dialogues.tell(Dialogue(
                title: "The folder could not be opened",
                message: "Facet asked the desktop to show \(file.url.deletingLastPathComponent().path) and it "
                    + "refused. The trace is still there and can be opened by hand."
            ))
        }
    }

    /// Empties the trace file.
    private func clearTrace() {
        let file = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory)
        debugLog?.record(.click, "Button clicked: Empty the trace")
        guard file.clear() else {
            dialogues.tell(Dialogue(
                title: "The trace could not be emptied",
                message: "Facet could not empty \(file.url.path). It may be open in something else."
            ))
            return
        }
        values.hasDebugTrace = DebugTraceFile.inUse(by: debugLog, directory: values.debugDirectory).exists
        redraw()
    }

    // MARK: - writing

    /// Writes a change, and adopts it only once the table has it.
    ///
    /// **A refused write puts the row back and says so in an alert**, which is the third of `CLAUDE.md`'s conditions
    /// for an open window holding a setting: a field still showing what was typed while the table holds something
    /// else is the two-answers problem itself. Putting it back here is a redraw from `values`, which is what the
    /// table last agreed to.
    private func apply(_ change: AppSettingsChange, adopt: @escaping () -> Void) {
        switch AppSettingWrite.apply(change, to: settings, debugLog: debugLog) {
        case .stored:
            adopt()
            // The status item draws from settings too -- `display_seconds` decides whether its figure carries them
            // -- and it repaints on a tick that only runs while something is being timed. So a setting changed
            // against a paused session would be stored and not shown, which reads as a control that did nothing.
            timingChanged()
        case let .refused(title):
            redraw()
            dialogues.tell(Dialogue(
                title: title,
                message: "Facet could not store that. The row is back to what it was."
            ))
        case .notASetting:
            break
        }
    }

    /// One labelled row: the words down the left, the control and its unit pinned to the right-hand edge.
    ///
    /// **The archive's shape, measured off `image/preferences-device.png`**, and the same one the Device tab draws:
    /// these are the two tabs made of settings rows, and two tabs of rows that sat at different rhythms would read
    /// as two windows. A control sitting wherever its label happened to end is what that looks like when it is
    /// wrong -- which it was here until it was seen on screen.
    private func row(
        _ label: String,
        control: UnsafeMutablePointer<GtkWidget>,
        suffix: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row()
        gtk_widget_set_size_request(line, -1, Int32(SettingsMetrics.rowHeight))
        if !label.isEmpty {
            facet_box_pack_start(line, SettingsWidgets.label(label), 0, 1, 0)
        }
        if let suffix {
            facet_box_pack_end(line, SettingsWidgets.secondary(suffix), 0, 0, 0)
        }
        // A row with no label of its own -- a check box, which carries its own words -- fills the line instead, or
        // it would be a tick floating at the right-hand edge with nothing to its left.
        if label.isEmpty {
            facet_box_pack_start(line, control, 1, 1, 0)
        } else {
            facet_box_pack_end(line, control, 0, 0, 0)
        }
        return line
    }
}

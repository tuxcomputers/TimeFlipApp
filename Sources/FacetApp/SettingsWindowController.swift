import AppKit

/// The Settings window: one tab per `SettingsTab`, each pane empty.
///
/// Owns the window and nothing else. Which tabs exist is `SettingsTab`'s business, and what goes in
/// them is each pane's, once there is anything to put there.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTabViewDelegate {
    /// Accessibility identifiers for the parts a script needs to address. The tabs themselves are
    /// addressed by their titles, which `SettingsTab` already owns.
    enum Identifier {
        static let window = "settings-window"
        static let tabs = "settings-tabs"
        static let panes = "settings-panes"
        static let close = "close-settings"
    }

    private enum Layout {
        // Provisional, and deliberately generous rather than fitted to five empty panes: the window
        // is sized for the content it is about to hold so the numbers do not have to be re-tuned as
        // each pane arrives. The tab that ends up needing the most room is what should set these,
        // measured, once it exists.
        static let defaultWidth: CGFloat = 640
        static let defaultHeight: CGFloat = 680
        static let minimumWidth: CGFloat = 560
        static let minimumHeight: CGFloat = 400
        /// Around the Close button, and between it and the panes above.
        static let buttonPadding: CGFloat = 12
        static let buttonSpacing: CGFloat = 6
        /// The air around the tab bar: above it to the title bar, and below it to the top of the box.
        /// One constant used on both sides, because equal gaps are the point -- the bar should read as
        /// sitting in a band of its own rather than resting on the content.
        static let tabBarMargin: CGFloat = 5
        /// The box's inset from the window's left and right edges.
        static let panesSideInset: CGFloat = 4
    }

    /// Built on first open, not at launch: a window nobody opens should not exist. Reused after that --
    /// closing orders it out rather than destroying it, so it reopens where it was left on screen.
    ///
    /// The *tab* it was left on is deliberately not kept: every open selects `tabOnOpen`. See there.
    private lazy var window: NSWindow = makeWindow()

    /// `nil` in a build without the dev flag.
    private let debugLog: DebugLog?

    /// Where the Faces tab's list comes from, and what a new category is written through. `nil` leaves the
    /// list empty, which is what a test that only cares about layout wants.
    private let categories: CategoryStore?

    /// Held so Escape can be lent to a name field while one is open.
    private var closeButton: NSButton?

    /// Which category each face holds, including the manual face. `nil` in a test that only cares about
    /// layout.
    private let faces: FaceStore?

    /// Where a segment goes. `nil` in a test that only cares about layout, and in that case a click times
    /// without recording anything -- which is the difference between the window's own behaviour and what it
    /// leaves behind, and worth being able to test apart.
    private let deviceEvents: DeviceEventRecorder?

    /// What is being timed, for drawing. `nil` draws an idle column, which is what a layout test wants.
    private let timing: TimingReadout?

    /// Recorded time, for the one thing this window asks of it: when a retired category was last used.
    private let entries: TimeEntryStore?

    /// The artwork a category can be given. A reference table, so this only ever reads.
    private let icons: IconStore?

    /// The palette a category can be given. A reference table, so this only ever reads.
    private let colours: ColourStore?

    /// The `setting` table, for the App tab. Read when that tab is shown, never held.
    private let settings: SettingStore?

    /// Whether the category on show has spent its `daily_limit`, which is what `togglePause` refuses a resume on.
    ///
    /// **A question rather than a flag**, so nothing here holds a copy of an answer that moves: the limit lands part
    /// way through a session, and a boolean set when the window opened would refuse the wrong thing.
    var isLimitReached: () -> Bool = { false }

    /// The icon grid while it is open. Held because `NSPopover` needs an owner for as long as it is on screen, and
    /// because a second click on another row's icon should replace it rather than stack a second one behind it.
    private var iconPicker: NSPopover?

    /// The colour list while it is open, held for the same two reasons.
    private var colourPicker: NSPopover?

    /// Called when this window changes what is being timed, so the status item can repaint at the same moment.
    ///
    /// A settable property rather than a constructor argument because the two need each other: the item's menu is
    /// what opens this window. Set from `main.swift` once both exist, which is also where the closure keeps this
    /// class from knowing the menu bar's type.
    var onTimingChanged: (@MainActor () -> Void)?

    /// Called once the Google calendar is settled: made, adopted or confirmed still there.
    ///
    /// The moment a backlog becomes deliverable. Every entry recorded before somebody connected is still sitting at
    /// `synced_to_google_calendar = 0`, and nothing else would look at them until the next flip.
    ///
    /// **Only from the paths where the calendar is known good.** Not from the one that forgets a calendar that no
    /// longer resolves, which leaves nowhere to sync to.
    var onGoogleCalendarSettled: (@MainActor () -> Void)?

    /// Redraws the figure while the window is open. Only while it is open: a clock nobody can see does not need
    /// repainting, and the figure is worked out from what is recorded rather than counted up, so nothing is lost
    /// by not ticking.
    private var tick: Timer?

    init(
        debugLog: DebugLog?,
        categories: CategoryStore?,
        faces: FaceStore?,
        deviceEvents: DeviceEventRecorder? = nil,
        timing: TimingReadout? = nil,
        entries: TimeEntryStore? = nil,
        icons: IconStore? = nil,
        colours: ColourStore? = nil,
        settings: SettingStore? = nil
    ) {
        self.debugLog = debugLog
        self.categories = categories
        self.faces = faces
        self.deviceEvents = deviceEvents
        self.timing = timing
        self.entries = entries
        self.icons = icons
        self.colours = colours
        self.settings = settings
        super.init()
    }

    /// Reads what the visible pane shows, now.
    ///
    /// Called when the window opens and again on every switch between tabs, which is the database rule
    /// applied literally (see `CLAUDE.md`): the values a window shows are read when it is about to show
    /// them, so closing and reopening it, or leaving a tab and coming back, reads the table again rather
    /// than redrawing what was true the first time.
    private func reloadSelectedPane() {
        // Only the pane on show is read. The others are read when they are switched to, which is the same rule
        // applied one level down: a tab nobody is looking at has no values worth having.
        //
        // Each branch asks for what it needs rather than one guard covering all of them: the App tab reads the
        // `setting` table and nothing else, so a controller with no `CategoryStore` -- which is what a layout test
        // builds -- must still be able to draw it.
        switch panes.selectedTabViewItem?.view {
        case let pane as FacesPane:
            guard let categories else { return }
            pane.show(categories.activeCategories())
            redrawTiming()

        case let pane as CategoriesPane:
            guard let categories else { return }
            wire(pane)
            pane.show(active: categories.activeCategories(), inactive: categories.inactiveCategories())

        case let pane as AppSettingsPane:
            // **Not re-read here.** The App tab's values were read when the window opened and this pane has held them
            // since; re-reading on a tab switch would undo a change made a moment ago if the write is still the only
            // thing that knows about it, and would make leaving the tab and coming back a different answer from
            // staying on it. See the source-of-truth rule in `CLAUDE.md`.
            wire(pane)

        case let pane as ReportPane:
            // Nothing to read: the range is a question somebody is asking, not a setting. Today moves, though, and
            // today is what both calendars are bounded by, so a window left open across midnight gets the new bounds
            // when the tab is next shown rather than going on refusing today.
            pane.refresh()

        default:
            break
        }
    }

    /// Reads every tab's settings once, as the window opens, and hands them over.
    ///
    /// **Every tab, not the one on show**, which is the half of the rule a per-tab read cannot give: from here until
    /// the window closes, what the window holds is the answer, so all of it has to be true at the same moment. The
    /// lists on the Faces and Categories tabs are not settings and are still read as they are drawn -- which rows
    /// belong in a list is a different question from what a value is.
    private func readSettingsIntoPanes() {
        for item in panes.tabViewItems {
            guard let pane = item.view as? AppSettingsPane else { continue }
            wire(pane)
            pane.show(appSettings())
        }
    }

    /// What the `setting` table says about the App tab, now.
    ///
    /// Each row falls back to what a fresh database would have seeded, because `SettingStore` answers `nil` for a
    /// missing or malformed row and refuses to guess what absence means -- rightly, since what a sensible fallback is
    /// depends entirely on the setting. `AppSettingsPane.Values.seeded` is where that guess is made, once.
    private func appSettings() -> AppSettingsPane.Values {
        let seeded = AppSettingsPane.Values.seeded
        guard let settings else { return seeded }
        return AppSettingsPane.Values(
            showsSeconds: settings.flag("display_seconds", field: "enabled") ?? seeded.showsSeconds,
            pausesOnLock: settings.flag("pause_on_lock", field: "enabled") ?? seeded.pausesOnLock,
            dailyResetHour24: settings.integer("daily_reset_time", field: "hour") ?? seeded.dailyResetHour24,
            batteryWarningPercent: settings.integer("low_battery_level", field: "percent")
                ?? seeded.batteryWarningPercent,
            fetchIntervalSeconds: settings.integer("fetch_history_interval_seconds", field: "seconds")
                ?? seeded.fetchIntervalSeconds,
            blipSeconds: settings.integer("blip_time", field: "seconds") ?? seeded.blipSeconds,
            googleAccount: GoogleAccountRules.account(
                name: settings.string(GoogleAccountRules.setting, field: GoogleAccountRules.nameField),
                email: settings.string(GoogleAccountRules.setting, field: GoogleAccountRules.emailField)
            ),
            googleCredentialsAvailable: GoogleCredentials.resolve() != nil,
            googleCalendar: GoogleCalendarRules.calendar(
                id: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField),
                name: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField)
            )
        )
    }

    /// Points the App tab's rows at the table they write to.
    private func wire(_ pane: AppSettingsPane) {
        pane.onChange = { [weak self, weak pane] change in
            guard let pane else { return }
            self?.store(change, from: pane)
        }
        pane.onCalendarEditingChanged = { [weak self] isEditing in
            // The same loan a category name gets, for the same reason: a key equivalent is dispatched before the
            // focused field ever sees the key, so without this Escape closes the window instead of abandoning the
            // name somebody was part way through typing.
            self?.closeButton?.keyEquivalent = isEditing ? "" : "\u{1b}"
        }
    }

    /// Writes a changed row, and says so if the table did not take it.
    ///
    /// **The write is checked by reading the value back** (`SettingStore.write`), not by trusting the statement: a
    /// write that reported success and did not happen would leave the window holding a value the table does not, and
    /// the window is the source of truth until it closes -- so the one thing that cannot be allowed is for the two to
    /// part company without anybody noticing.
    ///
    /// The row is only adopted once the table has it, and put back when it has not. Nothing is re-read either way:
    /// the row is showing what somebody typed, and a reload would take the field out from under them.
    ///
    /// **A value the table already held is overwritten**, deliberately. If something changes the row while this
    /// window is open, this write wins: the window read the setting when it opened and has been the answer since,
    /// and merging a change nobody in this window made would mean a control that quietly does something other than
    /// what it says.
    private func store(_ change: AppSettingsPane.Change, from pane: AppSettingsPane) {
        guard let settings else { return }
        if case .googleDisconnected = change {
            disconnectGoogle(from: pane, using: settings)
            return
        }
        if case .googleSignInRequested = change {
            signInToGoogle(from: pane, using: settings)
            return
        }
        if case let .googleCalendarNamed(name) = change {
            renameGoogleCalendar(to: name, from: pane, using: settings)
            return
        }
        if case .googleCalendarDeleteRequested = change {
            deleteGoogleCalendar(from: pane, using: settings)
            return
        }
        if case .googleCalendarCreateRequested = change {
            createGoogleCalendar(from: pane, using: settings)
            return
        }
        if case .googleCalendarChanged = change {
            pane.adopt(change)
            return
        }
        if case .googleConnected = change {
            // Only ever produced by this controller, after a write it has already read back.
            pane.adopt(change)
            return
        }
        guard let (setting, field, value) = AppSettingsRules.destination(for: change) else { return }
        let stored: Bool
        switch value {
        case let .flag(flag):
            stored = settings.write(setting, field: field, flag)
        case let .number(number):
            stored = settings.write(setting, field: field, number)
        }
        debugLog?.record(
            .field,
            "App setting \(setting).\(field) -> \(value)\(stored ? "" : " REFUSED, the table does not hold it")"
        )
        guard stored else {
            // Back to what the window holds first, so the row is not still showing a number the table refused while
            // an alert is up in front of it.
            pane.restore()
            showSettingRefused(change)
            return
        }
        pane.adopt(change)
        // The status item draws from settings too -- `display_seconds` decides whether its figure carries them -- and
        // it repaints on a tick that only runs while something is being timed. So a setting changed against a paused
        // session would be stored and not shown, which reads as a control that did nothing. Measured, on a paused
        // session: the table said `false` and the menu bar went on showing seconds.
        onTimingChanged?()
    }

    /// Runs the sign-in, and writes what comes back.
    ///
    /// **The window is not held open by this.** The flow can sit unfinished for as long as somebody leaves a browser
    /// tab open, so the task takes what it needs and checks the pane is still there afterwards rather than assuming.
    ///
    /// **The refresh token is stored before the identity.** If the token cannot be saved there is no usable
    /// connection, and writing a name and an email first would leave the section saying "Connected" over a Keychain
    /// with nothing in it -- an app that believes it is signed in and cannot act.
    private func signInToGoogle(from pane: AppSettingsPane, using settings: SettingStore) {
        guard let credentials = GoogleCredentials.resolve() else {
            showGoogleFailed(GoogleOAuthRules.Failure.noCredentials)
            return
        }
        pane.setSigningIn(true)
        debugLog?.record(.field, "Google sign-in started")
        Task { @MainActor [weak self, weak pane] in
            defer { pane?.setSigningIn(false) }
            do {
                let tokens = try await GoogleSignIn.run(credentials: credentials)
                guard let refresh = tokens.refreshToken, GoogleTokenStore.save(refreshToken: refresh) else {
                    throw GoogleOAuthRules.Failure.exchangeFailed("the token could not be saved to your Keychain")
                }
                let wroteName = settings.write(
                    GoogleAccountRules.setting, field: GoogleAccountRules.nameField, tokens.name ?? ""
                )
                let wroteEmail = settings.write(
                    GoogleAccountRules.setting, field: GoogleAccountRules.emailField, tokens.email ?? ""
                )
                guard wroteName, wroteEmail else {
                    throw GoogleOAuthRules.Failure.exchangeFailed("the database would not record the account")
                }
                // Read back rather than trusting what Google said, which is the same rule every row on this tab
                // follows: the table is what the window then holds.
                let account = GoogleAccountRules.account(
                    name: settings.string(GoogleAccountRules.setting, field: GoogleAccountRules.nameField),
                    email: settings.string(GoogleAccountRules.setting, field: GoogleAccountRules.emailField)
                )
                self?.debugLog?.record(.field, "Google sign-in finished, account \(account.email ?? "unnamed")")
                pane?.adopt(.googleConnected(account))
                // The calendar is made here rather than behind a button, so the only way to reach "connected with
                // nowhere to sync" is a failure. The access token is already in hand, so this costs no refresh.
                if let pane {
                    await self?.settleGoogleCalendar(
                        accessToken: tokens.accessToken, from: pane, using: settings
                    )
                }
            } catch {
                self?.debugLog?.record(.field, "Google sign-in failed: \(error.localizedDescription)")
                self?.showGoogleFailed(error)
            }
        }
    }

    /// Makes the calendar and records it, given a token that is already valid.
    ///
    /// **The id is written before the name**, and the calendar is only treated as existing once the id reads back. A
    /// name stored against no id would be a label for something that cannot be written to.
    ///
    /// **It creates rather than looking first.** This used to ask `calendarList.list` whether the account already had a
    /// Facet calendar, so that a database with no stored id could adopt one instead of making a second. That lookup
    /// does not work: with `calendar_id` blanked and a known-good calendar sitting in the account, a reconnect logged
    /// "created" rather than "reused" and produced a duplicate, so `calendarList.list` returns nothing usable under
    /// `calendar.app.created` (measured 2026-08-15). It failed safe, which is why it survived as long as it did, and
    /// its own comment claimed a protection that was not there.
    ///
    /// What is left is honest: reaching here means the app has no calendar, and it makes one. The case the lookup was
    /// written for has also largely gone, since signing out now **keeps** the stored id -- only a fresh database or a
    /// hand-cleared row gets here with an account that already has a calendar, and the duplicate that follows is
    /// visible in the user's own calendar list rather than silent.
    private func makeGoogleCalendar(
        named name: String,
        accessToken: String,
        from pane: AppSettingsPane,
        using settings: SettingStore
    ) async {
        do {
            let made = try await GoogleCalendarClient.create(name: name, accessToken: accessToken)
            guard let id = made.id,
                  settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, id),
                  settings.write(
                      GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, made.name ?? name
                  )
            else {
                throw GoogleCalendarRules.Failure.createFailed("the database would not record it")
            }
            let stored = GoogleCalendarRules.calendar(
                id: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField),
                name: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField)
            )
            debugLog?.record(.field, "Google calendar created, \(stored.name ?? "unnamed")")
            pane.adopt(.googleCalendarChanged(stored))
            onGoogleCalendarSettled?()
        } catch {
            debugLog?.record(.field, "Google calendar creation failed: \(error.localizedDescription)")
            showGoogleFailed(error)
        }
    }

    /// Works out which calendar this account should use, now that somebody has signed in.
    ///
    /// **The stored id is checked, not trusted.** It survives a sign-out on purpose, so the usual case -- the same
    /// person signing back in -- keeps the calendar and its history. But the same stored id is also what a *different*
    /// person meets, and what somebody who deleted the calendar at Google meets, and in both of those it addresses
    /// nothing. Those two are indistinguishable from here, which is why the question asked is the same one and the
    /// wording names both possibilities rather than guessing.
    private func settleGoogleCalendar(
        accessToken: String,
        from pane: AppSettingsPane,
        using settings: SettingStore
    ) async {
        let storedID = settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField)
        guard let id = GoogleCalendarRules.calendar(id: storedID, name: nil).id else {
            await makeGoogleCalendar(
                named: GoogleCalendarRules.defaultName, accessToken: accessToken, from: pane, using: settings
            )
            return
        }
        do {
            // Proves it exists and brings back its current name in the same request, so a rename made at Google is
            // adopted here without anything ever polling for it.
            let found = try await GoogleCalendarClient.get(id: id, accessToken: accessToken)
            _ = settings.write(
                GoogleAccountRules.setting, field: GoogleCalendarRules.nameField,
                found.name ?? GoogleCalendarRules.defaultName
            )
            let stored = GoogleCalendarRules.calendar(
                id: id, name: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField)
            )
            debugLog?.record(.field, "Google calendar confirmed, \(stored.name ?? "unnamed")")
            pane.adopt(.googleCalendarChanged(stored))
            onGoogleCalendarSettled?()
        } catch is CalendarGone {
            await forgetAndOfferGoogleCalendar(accessToken: accessToken, from: pane, using: settings)
        } catch {
            // Something else went wrong. The calendar is not known to be gone, so nothing is forgotten and nothing is
            // made: the id stays, and the next attempt can settle it.
            debugLog?.record(.field, "Google calendar could not be checked: \(error.localizedDescription)")
            showGoogleFailed(error)
        }
    }

    /// The stored calendar does not resolve. Forget it, say so, and offer to make another.
    ///
    /// **The id is cleared here and only here**, once Google has said it is gone. Clearing it because a write failed
    /// or a request timed out is how somebody ends up with a second "Facet", and a third.
    private func forgetAndOfferGoogleCalendar(
        accessToken: String,
        from pane: AppSettingsPane,
        using settings: SettingStore
    ) async {
        _ = settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, "")
        _ = settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, "")
        pane.adopt(.googleCalendarChanged(.none))
        debugLog?.record(.field, "Google calendar no longer resolves, forgotten")

        guard await askAboutMissingGoogleCalendar() else { return }
        await makeGoogleCalendar(
            named: GoogleCalendarRules.defaultName, accessToken: accessToken, from: pane, using: settings
        )
    }

    /// Asks whether to make another calendar, and answers `true` if so.
    ///
    /// **It does not claim to know which happened.** A calendar deleted at Google and an id belonging to a different
    /// account both come back as "not found", and a message that picked one would be wrong half the time.
    private func askAboutMissingGoogleCalendar() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Facet cannot find its calendar"
        alert.informativeText = """
        The calendar Facet was using is not in this Google account. It may have been deleted, or this may be a \
        different account from the one it was made in.

        Facet can make a new one. Anything already written to the old calendar stays where it is.
        """
        alert.addButton(withTitle: "Create Calendar")
        alert.addButton(withTitle: "Not Now")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    /// The recovery path: the button that only appears when there is no calendar.
    private func createGoogleCalendar(from pane: AppSettingsPane, using settings: SettingStore) {
        pane.setSigningIn(true)
        Task { @MainActor [weak self, weak pane] in
            defer { pane?.setSigningIn(false) }
            guard let self, let pane else { return }
            do {
                let token = try await self.googleAccessToken()
                await self.makeGoogleCalendar(
                    named: GoogleCalendarRules.defaultName, accessToken: token, from: pane, using: settings
                )
            } catch {
                self.showGoogleFailed(error)
            }
        }
    }

    /// Asks whether to delete the calendar, and does it.
    ///
    /// **The only thing this window destroys, so it is the only one that asks first.** Everything else here can be
    /// undone by doing it again -- a name can be renamed back, a sign-out can be signed back into. This takes the
    /// calendar and every event Facet has written to it, out of an account Facet does not own, and Google keeps
    /// nothing to go back to. So the question names what goes rather than asking whether somebody is sure.
    ///
    /// **The recorded time itself is untouched.** Every `time_entry` stays exactly where it is; what is lost is the
    /// copy of it in the calendar. That distinction is the whole of what somebody needs to decide, so it is said.
    private func deleteGoogleCalendar(from pane: AppSettingsPane, using settings: SettingStore) {
        guard let id = pane.values.googleCalendar.id else { return }
        let name = pane.values.googleCalendar.name ?? GoogleCalendarRules.defaultName

        let alert = NSAlert()
        alert.messageText = "Delete the \"\(name)\" calendar?"
        alert.informativeText = """
        This deletes the calendar from your Google account, along with every event Facet has written to it. \
        It cannot be undone from here.

        Your recorded time is not affected: it stays in Facet, and a new calendar can be made and filled from it.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Calendar")
        // **Return must not delete anything, and adding Cancel first is not enough to arrange that.** AppKit puts a
        // button titled "Cancel" on the left whatever order it went in, so the rightmost button -- the one Return
        // activates -- ends up being the destructive one. Measured 2026-08-16: the buttons read back as
        // "Delete Calendar", "Cancel", not the order they were added in.
        //
        // So the key equivalents are set rather than inferred from position: Return dismisses, Escape dismisses, and
        // deleting takes a deliberate click. The answer is still read by addition order, which is unaffected.
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else {
                self?.debugLog?.record(.field, "Button clicked: Cancel, \"\(name)\" calendar not deleted")
                return
            }
            self?.carryOutGoogleCalendarDelete(id: id, named: name, from: pane, using: settings)
        }
    }

    /// Deletes it at Google first and forgets it afterwards, in that order.
    ///
    /// **Google is asked first and the row follows**, as a rename is: clearing the id before the request would leave
    /// the app unable to name what it failed to delete, and a calendar nothing points at any more is exactly the
    /// orphan this is meant to avoid.
    private func carryOutGoogleCalendarDelete(
        id: String,
        named name: String,
        from pane: AppSettingsPane,
        using settings: SettingStore
    ) {
        Task { @MainActor [weak self, weak pane] in
            guard let self, let pane else { return }
            do {
                let token = try await self.googleAccessToken()
                try await GoogleCalendarClient.delete(id: id, accessToken: token)
                guard
                    settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, ""),
                    settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, "")
                else {
                    throw GoogleCalendarRules.Failure.deleteFailed("the database would not forget it")
                }
                self.debugLog?.record(.field, "Google calendar deleted, \(name)")
                pane.adopt(.googleCalendarChanged(.none))
            } catch {
                // The id stays, because the calendar may well still be there. Forgetting it on a failed request is how
                // somebody ends up with an orphan they can no longer name.
                self.debugLog?.record(.field, "Google calendar delete failed: \(error.localizedDescription)")
                self.showGoogleFailed(error)
            }
        }
    }

    /// Renames the calendar at Google, then records what it ended up being called.
    ///
    /// **Google is asked first and the row follows.** The calendar belongs to the user's account, so the name there is
    /// the real one; a row updated first would be Facet claiming a rename that may not have happened.
    private func renameGoogleCalendar(to name: String, from pane: AppSettingsPane, using settings: SettingStore) {
        guard let id = pane.values.googleCalendar.id else { return }
        Task { @MainActor [weak self, weak pane] in
            guard let self, let pane else { return }
            do {
                let token = try await self.googleAccessToken()
                let renamed = try await GoogleCalendarClient.rename(id: id, to: name, accessToken: token)
                guard settings.write(
                    GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, renamed.name ?? name
                ) else {
                    throw GoogleCalendarRules.Failure.renameFailed("the database would not record it")
                }
                let stored = GoogleCalendarRules.calendar(
                    id: id, name: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField)
                )
                self.debugLog?.record(.field, "Google calendar renamed to \(stored.name ?? "unnamed")")
                pane.adopt(.googleCalendarChanged(stored))
            } catch is CalendarGone {
                // Deleted at Google while Facet was connected. The same situation a sign-in meets, so the same
                // question, rather than a second way of saying it.
                let token = try? await self.googleAccessToken()
                await self.forgetAndOfferGoogleCalendar(
                    accessToken: token ?? "", from: pane, using: settings
                )
            } catch {
                // The field is showing what somebody typed; put the row back to what is stored.
                pane.adopt(.googleCalendarChanged(pane.values.googleCalendar))
                self.showGoogleFailed(error)
            }
        }
    }

    /// A usable access token, from the refresh token in the Keychain. The same one the background sweep asks for, so
    /// there is one answer to "who is signed in" rather than a window's and a sweep's.
    private func googleAccessToken() async throws -> String {
        try await GoogleCalendarClient.currentAccessToken()
    }

    /// What a failed sign-in says. The message comes from `GoogleOAuthRules.Failure`, which is where the wording lives
    /// so that one failure cannot be described two ways.
    private func showGoogleFailed(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Facet could not connect to Google"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Signs the Google account out: clears the identity, and nothing else in the row.
    ///
    /// **Both fields have to go, and the section is only allowed to say so once both have.** `database/011_setting.sql`
    /// is explicit that sign-out clears the name and the email alone -- `calendar_id`, `calendar_name` and `client_id`
    /// share this row and are configuration rather than identity, so they survive a sign-out and are still right when
    /// the same account signs back in.
    ///
    /// A half-done clear is the case worth spelling out: if the name goes and the email does not, the account is still
    /// connected as far as `GoogleAccountRules` is concerned, and saying "disconnected" would be a window disagreeing
    /// with its own table. So this adopts the change only when both writes read back.
    private func disconnectGoogle(from pane: AppSettingsPane, using settings: SettingStore) {
        let clearedName = settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.nameField, "")
        let clearedEmail = settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.emailField, "")
        // **The calendar is deliberately kept.** Signing out and back in on the same account is the common case, and
        // forgetting the id would make a second "Facet" beside the first with the history split across the two. The
        // id is checked on the way back in rather than trusted, so a sign-in by somebody else finds it does not
        // resolve and is asked what to do -- which is the same conversation as a calendar that was deleted.
        let stored = clearedName && clearedEmail
        debugLog?.record(
            .field,
            "Google account disconnected\(stored ? "" : " REFUSED, the table still holds an identity")"
        )
        guard stored else {
            pane.restore()
            showSettingRefused(.googleDisconnected)
            return
        }
        // The token goes with the identity. Leaving it behind would mean a Keychain still holding the ability to act
        // on an account the app says it is not connected to.
        GoogleTokenStore.clear()
        pane.adopt(.googleDisconnected)
    }

    /// What a refused setting says. It names the row rather than the column, since nobody reading this knows what
    /// `low_battery_level` is, and says what the app did about it -- the row went back -- so the number on screen is
    /// accounted for.
    private func showSettingRefused(_ change: AppSettingsPane.Change) {
        let alert = NSAlert()
        alert.messageText = "That setting was not saved"
        alert.informativeText = """
        The database would not take the new value for "\(AppSettingsRules.title(for: change))", so the setting is \
        unchanged and the row has gone back to what is stored.

        Nothing else has been affected. Trying again is safe.
        """
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Points the Categories tab's edits at the tables they write to.
    ///
    /// Set on every reload rather than once, because it costs nothing and because a pane wired in only one place is a
    /// pane that draws dead controls the day something else builds it.
    ///
    /// **A write is not followed by a re-read here, and the retire is the exception.** Settings reads the database
    /// when it opens and what it shows is then the answer until it closes, so a limit typed into a field is already on
    /// screen and re-reading would only rebuild the row -- taking the field out from under whoever is still typing in
    /// it. Retiring is different in kind: it changes *which* rows belong in the list, so the list is read again and
    /// the row leaves because the table no longer calls it active.
    private func wire(_ pane: CategoriesPane) {
        pane.activeTable.facesHolding = { [weak self] category in
            self?.faces?.facesHolding(categoryID: category.id) ?? []
        }
        pane.activeTable.onSetDailyLimit = { [weak self] category, minutes in
            self?.setDailyLimit(minutes, on: category)
        }
        pane.activeTable.onRetire = { [weak self] category in
            self?.retire(category)
        }
        pane.activeTable.onPickIcon = { [weak self] category, anchor in
            self?.pickIcon(for: category, from: anchor)
        }
        pane.activeTable.onPickColour = { [weak self] category, anchor in
            self?.pickColour(for: category, from: anchor)
        }
        pane.activeTable.onRename = { [weak self] category, typed in
            self?.rename(category, to: typed)
        }
        pane.activeTable.onRenameEditingChanged = { [weak self] isEditing in
            // The same loan the create control gets, for the same reason: a key equivalent is dispatched before the
            // focused field ever sees the key, so without this Escape closes the window instead of abandoning a name.
            self?.closeButton?.keyEquivalent = isEditing ? "" : "\u{1b}"
        }
        // Read per row as the Inactive list is drawn, which is why it is a closure rather than a field on the record:
        // an active category draws no date at all, so joining it onto every category read would cost a subquery on
        // the reads that happen once a second.
        pane.retiredTable.lastUsed = { [weak self] category in
            self?.entries?.lastUsed(categoryID: category.id)
        }
        pane.retiredTable.onReinstate = { [weak self] category in
            self?.reinstate(category)
        }
        // **The same handler the Active list's rename reaches**, given the retired record. Everything that differs
        // between the two is a question about the record -- `CategoryRenameRules.decision` reads `isActive` to tell an
        // index violation from a name the table will take -- so a second handler here would be a second answer to a
        // question one already answers.
        pane.retiredTable.onRename = { [weak self] category, typed in
            self?.rename(category, to: typed)
        }
        pane.retiredTable.onRenameEditingChanged = { [weak self] isEditing in
            self?.closeButton?.keyEquivalent = isEditing ? "" : "\u{1b}"
        }
        pane.activeSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "Categories section Active \(isExpanded ? "opened" : "folded")")
        }
        pane.inactiveSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "Categories section Inactive \(isExpanded ? "opened" : "folded")")
        }
        wire(pane.createControl)
    }

    /// Opens the icon grid under a category's icon.
    ///
    /// A popover, as the archive had it: the grid belongs to the row it was opened from, and a sheet or a window
    /// would take that connection away and have to say which category it was for.
    ///
    /// **The picker closes on a pick.** One choice is the whole of what it is for, so leaving it open would mean
    /// asking somebody to dismiss a thing they have finished with.
    private func pickIcon(for category: CategoryRecord, from anchor: NSView) {
        guard let icons else { return }
        let grid = IconGrid(icons: icons.all(), selected: category.iconName)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = grid
        grid.onPick = { [weak self, weak popover] iconID in
            popover?.close()
            self?.setIcon(iconID, on: category)
        }
        iconPicker = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Stores a category's artwork, which includes clearing it: re-clicking the icon a category already has answers
    /// `0`, and that is a write like any other (see `CategoryEditRules.iconSelection`).
    private func setIcon(_ iconID: Int, on category: CategoryRecord) {
        guard let categories else { return }
        let stored = categories.setIcon(id: category.id, iconID: iconID)
        debugLog?.record(
            .click,
            "Category \"\(category.name)\" icon -> icon_id \(iconID)\(stored ? "" : " REFUSED")"
        )
        // Read back, which is what redraws the row's icon: this changes what a row says about itself rather than a
        // value the row is already showing, so there is nothing being typed into for a reload to interrupt.
        reloadSelectedPane()
    }

    /// Opens the palette under a category's swatch, on the same terms as the icon grid: a popover belonging to the row
    /// it was opened from, closing on the one choice it exists to take.
    private func pickColour(for category: CategoryRecord, from anchor: NSView) {
        guard let colours else { return }
        let list = ColourList(colours: colours.all(), selected: category.colourID)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = list
        list.onPick = { [weak self, weak popover] colourID in
            popover?.close()
            self?.setColour(colourID, on: category)
        }
        colourPicker = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Stores a category's colour, which includes clearing it: re-clicking the colour a category already has answers
    /// `0`, and that is a write like any other (see `CategoryEditRules.colourSelection`).
    private func setColour(_ colourID: Int, on category: CategoryRecord) {
        guard let categories else { return }
        let stored = categories.setColour(id: category.id, colourID: colourID)
        debugLog?.record(
            .click,
            "Category \"\(category.name)\" colour -> colour_id \(colourID)\(stored ? "" : " REFUSED")"
        )
        // Read back, which is what redraws the row's swatch: this changes what a row says about itself rather than a
        // value the row is already showing, so there is nothing being typed into for a reload to interrupt.
        reloadSelectedPane()
    }

    /// Acts on a name typed into a row, which always means asking first.
    ///
    /// **Every rename is confirmed**, even to a name nothing else holds, because of what a rename does to what is
    /// already recorded: everything references a category by id, so a report covering last month will show the new
    /// name too. That is not a loss and there is nothing to backfill, but it is not necessarily expected.
    ///
    /// The decision is `CategoryRenameRules`', taken against the whole `category` table rather than either list on
    /// screen, since the name may be held by a row this tab is not showing.
    private func rename(_ category: CategoryRecord, to typed: String) {
        guard let categories else { return }
        let decision = CategoryRenameRules.decision(
            rawName: typed,
            current: category,
            matching: categories.matching(name:)
        )
        let choices = CategoryRenameRules.choices(for: decision)
        guard
            let title = CategoryRenameRules.title(for: decision),
            let message = CategoryRenameRules.message(for: decision, currentName: category.name)
        else {
            // `.ignore`: nothing typed, or the name already reads that way. The field has closed itself, and a
            // dialogue saying nothing happened would be worse than nothing happening.
            debugLog?.record(.field, "Category \"\(category.name)\" rename ignored, nothing changed")
            return
        }
        // `nil` for the dead end, which raises the same dialogue with nothing but Cancel in it: an active category
        // holds the name, so there is something to say and nothing to decide.
        let name = renamedName(from: decision)
        debugLog?.record(
            .field,
            "Category \"\(category.name)\" rename -> \"\(CategoryCreateRules.normalise(typed))\", asking: \(title)"
        )

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for choice in choices {
            alert.addButton(withTitle: choice.buttonTitle)
        }
        // **Return has to be put on Cancel, not merely aimed at it by adding Cancel first.** AppKit relocates a button
        // titled "Cancel" to the left, which takes it out of the rightmost place Return fires, so the button that
        // agrees becomes the default one. Measured on 2026-08-16: this sheet listed "Cancel | Rename anyway" while the
        // calendar delete, which does set its key equivalents, listed "Delete Calendar | Cancel" -- the two differing
        // in nothing else. Left alone, Return here agreed to a rename.
        //
        // The same trap and the same fix as `carryOutGoogleCalendarDelete`, and for the same reason: the answer that
        // changes something already recorded must not be the one a stray Return lands on.
        for (index, choice) in choices.enumerated() where index < alert.buttons.count {
            alert.buttons[index].keyEquivalent = choice == .cancel ? "\r" : ""
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let name else {
                self?.debugLog?.record(.click, "Button clicked: Cancel, \"\(category.name)\" rename refused, name taken")
                return
            }
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            self?.act(
                on: CategoryRenameRules.choice(forButtonIndex: index, offering: choices),
                renaming: category,
                to: name,
                in: categories
            )
        }
    }

    /// The name a decision would write, or `nil` for one that writes nothing. The refusal carries a name too -- the
    /// one that is taken -- and it is not a name to write, which is why this asks the decision rather than the text.
    private func renamedName(from decision: CategoryRenameRules.Decision) -> String? {
        switch decision {
        case .ignore, .refuse:
            return nil
        case let .confirm(name), let .confirmAgainstRetired(name, _), let .confirmAgainstActive(name, _):
            return name
        }
    }

    private func act(
        on choice: CategoryRenameRules.Choice?,
        renaming category: CategoryRecord,
        to name: String,
        in categories: CategoryStore
    ) {
        // `nil` is a response no button of ours produced -- a sheet dismissed by something else -- and it means the
        // same as Cancel: a name was typed and nothing came of it.
        guard choice?.isRename == true else {
            debugLog?.record(.click, "Button clicked: Cancel, \"\(category.name)\" not renamed")
            return
        }
        let stored = categories.setName(id: category.id, name: name)
        debugLog?.record(
            .click,
            "Button clicked: \(choice?.buttonTitle ?? "") \"\(category.name)\" -> \"\(name)\""
                + "\(stored ? "" : " REFUSED by the index")"
        )
        // Read back either way. A rename re-sorts the list, and a refused one leaves a row showing a name the table
        // never took.
        reloadSelectedPane()
        // What is being timed may be this category, and its name is on the status item.
        onTimingChanged?()
    }

    /// Stores a category's daily limit.
    ///
    /// A refused write is the one case that reads the row back. The field is showing what was typed, and if the table
    /// did not take it then the screen and the database now disagree -- which is the whole thing the first rule in
    /// `CLAUDE.md` exists to prevent. Losing the field's focus is the smaller cost of the two.
    private func setDailyLimit(_ minutes: Int, on category: CategoryRecord) {
        guard let categories else { return }
        let allowed = CategoryEditRules.dailyLimitMinutes(minutes)
        let stored = categories.setDailyLimit(id: category.id, minutes: allowed)
        debugLog?.record(
            .field,
            "Category \"\(category.name)\" daily limit -> \(allowed)min\(stored ? "" : " REFUSED")"
        )
        guard stored else {
            reloadSelectedPane()
            return
        }
        // **The limit just edited may be the limit the app is refusing against, and the refusal has no tick of its own
        // to notice.** `DailyLimitWatch` stands itself down when the clock stops, which is exactly what a spent limit
        // does to it, so raising the limit here is a change nothing was left watching for. The edit says so itself
        // instead: the menu bar redraws and its red clears, the dropdown's Resume comes back, and the watch re-arms if
        // there is anything to watch. This is the same funnel a rename uses two methods up, for the same reason.
        onTimingChanged?()
    }

    /// Retires a category and takes it off the faces holding it.
    ///
    /// **Both, or neither.** A retired category left on a face would still be what that face is timing while being
    /// absent from every list a category can be picked from, which is a state nothing else in the app is prepared to
    /// explain. The archive did the same, and the faces are cleared after the retire rather than before so a refused
    /// retire leaves the faces alone.
    ///
    /// Nothing here has to check for a locked face: `CategoryEditRules` decided that before the box was drawn, and a
    /// locked face's box is disabled, so this is not reachable for one.
    private func retire(_ category: CategoryRecord) {
        guard let categories else { return }
        guard categories.setActive(id: category.id, false) else {
            debugLog?.record(.click, "Category \"\(category.name)\" retire REFUSED")
            return
        }
        let cleared = (faces?.facesHolding(categoryID: category.id) ?? []).filter { faces?.clear(face: $0.face) == true }
        debugLog?.record(
            .click,
            "Category \"\(category.name)\" retired, cleared from face(s) \(cleared.map(\.face))"
        )
        // The list is read again because retiring changes which rows belong in it, not merely what one of them says.
        reloadSelectedPane()
        // The Faces tab and the status item draw from the same tables, and a face this cleared may be the one being
        // timed.
        onTimingChanged?()
    }

    /// Brings a retired category back, or says why it cannot come back.
    ///
    /// **The name is checked before the write.** Only one active category may hold a name, and the unique index
    /// would refuse this anyway -- but a refused write cannot say *which* category is in the way, and that is the
    /// whole of what somebody needs to hear. `CategoryEditRules` answers it against the whole table rather than
    /// against either list on screen, since the clash may be with a row this tab is not showing.
    ///
    /// The index still has the last word. If the check and the index ever disagree, the index is the one that is
    /// right, so a refusal from the write is reported too rather than assumed impossible.
    ///
    /// Nothing is put on any face by this, which is why a locked face is no bar here as it is to retiring.
    private func reinstate(_ category: CategoryRecord) {
        guard let categories else { return }
        switch CategoryEditRules.reinstateDecision(
            for: category,
            matching: categories.matching(name: category.name)
        ) {
        case let .refuse(namesake):
            debugLog?.record(
                .click,
                "Category \"\(category.name)\" reinstate REFUSED: category_id \(namesake.id) is active under that name"
            )
            // Redrawn before the alert, so the box the click ticked goes back to unticked: it claimed something the
            // table never agreed to.
            reloadSelectedPane()
            showNameTaken(category)

        case .reinstate:
            let stored = categories.setActive(id: category.id, true)
            debugLog?.record(
                .click,
                "Category \"\(category.name)\" reinstated\(stored ? "" : " REFUSED by the index")"
            )
            // Read again either way: reinstating changes which list the row belongs in, and a refusal has to put the
            // box back.
            reloadSelectedPane()
        }
    }

    /// The dead end for a name an active category already holds. Wording carried over from the previous app.
    private func showNameTaken(_ category: CategoryRecord) {
        let alert = NSAlert()
        alert.messageText = "That name is already in use"
        alert.informativeText = """
        An active category is already called "\(category.name)", so this one cannot be reinstated under that name.

        Rename one of them first, then try again.
        """
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Draws the session: which category, whether it is running, and how much time that category has.
    ///
    /// Every part of that is read at this moment, and read by `TimingReadout` rather than here -- because the
    /// status item asks the same question and the two must not answer it separately. See there for what each
    /// piece is read from and why the figure is the category's total for the day rather than this session's
    /// stopwatch.
    private func redrawTiming() {
        draw(timing?.read() ?? .idle)
    }

    /// Re-reads the Report tab's totals, for the two moments that turn a stretch into an entry: a pause, and a switch
    /// to another category. Both can happen while the Report tab is the one on show -- the status item pauses from
    /// anywhere -- and unlike the Faces tab, a list of totals has no tick to repaint it.
    ///
    /// Only when that tab is showing. A read for a tab nobody is looking at is a read whose answer is thrown away, and
    /// the tab reads itself when it is switched to.
    private func redrawTotals() {
        guard let report = panes.selectedTabViewItem?.view as? ReportPane else { return }
        report.refresh()
    }

    /// Draws a reading already taken, which is what the tick wants: it has to look at the state anyway to decide
    /// whether to keep going, and reading twice for one repaint would be two answers where one will do.
    private func draw(_ reading: TimingReadout.Reading) {
        guard let pane = panes.selectedTabViewItem?.view as? FacesPane else { return }
        pane.timingView.show(
            category: reading.category,
            state: reading.state,
            elapsed: reading.seconds,
            isLimitReached: isLimitReached()
        )
    }

    /// The manual face in use right now, which is `DeviceEventRecorder`'s answer to give: it owns the table the
    /// rotation is read out of.
    private func currentManualFace() -> Int {
        deviceEvents?.currentManualFace() ?? ManualFace.first
    }

    /// A category was clicked: the segment that was running ends, the **next** manual face takes the new
    /// category, and a new segment starts on it.
    ///
    /// One moment is read for the whole gesture, so the segment that ends and the one that begins meet exactly
    /// rather than overlapping or leaving a gap nobody timed.
    ///
    /// **The new category goes on a different face from the one the finished segment named**, which is what
    /// makes the outgoing segment's category safe no matter when anything reads it. Closing before writing the
    /// face is still the right order and still done, but it is no longer the only thing standing between a
    /// finished stretch and being filed under the category that replaced it -- see `ManualFace`.
    ///
    /// What each step means for the rows is `DeviceEventRecorder`'s, not this method's: it is handed a moment
    /// and decides the rest.
    private func startTiming(_ category: CategoryRecord) {
        guard let faces else { return }
        // Already timing this one, so the click has nothing to ask for: the clock is where it should be, and
        // restarting it would rotate the face and close a segment for a gesture that asked for no change. Ahead of
        // the face write as well as the segment, since the face already holds this category too.
        //
        // Recorded even though nothing happened. A click that deliberately did nothing and a click that never
        // landed look identical afterwards unless one of them leaves a row, and telling those apart is the
        // difference between this working and the list having stopped responding.
        if timing?.read().isTiming(category.id) == true {
            debugLog?.record(.mode, "Timing: already timing \"\(category.name)\", so the click changes nothing")
            return
        }
        let moment = Date()
        // Read before anything is written, so the face the finished segment is on is not the face about to be
        // reassigned.
        let face = ManualFace.next(after: deviceEvents?.latestFace(in: ManualFace.all))
        deviceEvents?.closeOpenSegment(at: moment)
        // A refused write here leaves the outgoing segment closed with no new one open, and the clock still
        // claiming to run. That is worth naming rather than guarding: the close is right on its own terms (the
        // stretch did end when the click arrived), and the only way to reach this is the database refusing an
        // update -- the app's own faces are never locked, being reassigned is the whole point of them.
        guard faces.assign(categoryID: category.id, toFace: face) else {
            debugLog?.record(.mode, "Timing: face \(face) refused category \"\(category.name)\"")
            return
        }
        deviceEvents?.startSegment(face: face, at: moment)
        debugLog?.record(.mode, "Timing: started \"\(category.name)\" (category_id \(category.id)) on face \(face)")
        redrawTiming()
        redrawTotals()
        onTimingChanged?()
        startTicking()
    }

    /// Stop the clock, or start it again.
    ///
    /// **One path for both ways in**: the control in the Timing column and the dropdown's Pause item both end
    /// here, so they cannot come to disagree about what pausing means. The previous app had them as two
    /// implementations and they did exactly that.
    ///
    /// It lives here because this was the only thing that drew a session. The status item draws one now too, and
    /// both reach this same method, so this is that coordinator: the decision is here, what it changed is read back
    /// out of the table by whoever draws.
    ///
    /// **Pausing ends the segment; resuming begins another.** A segment's duration is the wall time from its
    /// start, so a pause left sitting inside one would be counted as time spent -- and it was, until this: the
    /// clock read 14 seconds against a row claiming 20. Ending it at the pause is also what hands the stretch
    /// to the time entry module, which is the moment it can be asked whether it counts.
    ///
    /// **Which of the two this is comes from the table**, not from a flag: an open segment is what running means.
    /// So a launch that inherits a paused session can resume it, which an in-memory flag could not -- a new launch
    /// started that flag empty, and the toggle refused, leaving a category on show that could not be started.
    func togglePause() {
        // Read before anything is written, since it is what decides which of the two this is.
        let before = timing?.read() ?? .idle
        // Nothing being timed means no clock and no row, so there is nothing here to stop or start. The same
        // question the dropdown's Pause item and the status item's right side ask, and the same answer.
        // **The refusal itself.** Every path in -- the dropdown item, the status item's right half, the Timing
        // column's glyph -- lands here, so a limit that stopped the clock cannot be undone by finding another
        // button. The two controls also grey themselves, but that is the courtesy; this is the enforcement.
        guard ManualTimerRules.isClickable(before.state, isLimitReached: isLimitReached()) else {
            debugLog?.record(
                .limit,
                "Resume refused, \"\(before.category?.name ?? "nothing")\" has spent its daily limit"
            )
            return
        }
        // One moment for both halves, so the segment that ends and the one that begins meet exactly.
        let moment = Date()
        if before.state == .running {
            deviceEvents?.closeOpenSegment(at: moment)
        } else {
            // The same face the paused stretch was on, not the next one, and nothing is written to it. Rotating
            // exists to stop a face's category changing under a finished segment, and resuming does not change
            // it: this is the same category continuing. Reusing the face is therefore safe, and it keeps a
            // pause-heavy session from cycling the pool for no reason.
            deviceEvents?.startSegment(face: currentManualFace(), at: moment)
        }
        // Read back rather than assumed, which is the rule applied to the app's own writes as well as to what it
        // shows: this says what the table now holds, so a write that did not take says so here.
        let after = timing?.read() ?? .idle
        debugLog?.record(
            .mode,
            "Timing: \(after.state == .running ? "running" : "stopped") "
                + "\"\(after.category?.name ?? "nothing")\", \(Int(after.seconds))s today"
        )
        draw(after)
        redrawTotals()
        onTimingChanged?()
        if after.state == .running {
            startTicking()
        } else {
            // Nothing left to repaint once it is stopped: the figure cannot change again until it is started, and
            // the redraw above has already shown its final value.
            stopTicking()
        }
    }

    private func startTicking() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reading = self.timing?.read() ?? .idle
                // Stopped behind our back -- there is no such path today, every pause going through `togglePause`
                // above, and a clock that kept repainting a frozen figure would be the sort of thing nobody
                // notices. So the tick asks rather than trusting it was stopped.
                guard reading.state == .running else {
                    self.stopTicking()
                    return
                }
                self.draw(reading)
            }
        }
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    func show() {
        // An accessory app has no application menu, and the standard editing shortcuts (⌘X/⌘C/⌘V,
        // ⌘W) live in it -- so a text field in this window would have no way to be pasted into.
        // `.regular` borrows a real one for as long as the window is open, at the cost of a Dock icon
        // appearing while it is. The alternative is to build a hidden main menu and stay `.accessory`
        // throughout; worth revisiting when the first editable field lands here, which is the point
        // at which the difference is testable rather than theoretical.
        NSApp.setActivationPolicy(.regular)
        // Before the window is on screen, so it never appears on one tab and switches to another.
        select(Self.tabOnOpen)
        // Logged here rather than left to the tab view's delegate, which does not fire for a tab that is already
        // selected -- and since Faces became the *first* tab, that is now every ordinary open. The row is the only
        // evidence of which tab an open landed on, so it says so itself rather than depending on a change happening.
        debugLog?.record(.tab, "Settings opened on \(Self.tabOnOpen.title)")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Every tab's settings, read here and held until this window closes. See `readSettingsIntoPanes`.
        readSettingsIntoPanes()
        reloadSelectedPane()
        if timing?.read().state == .running {
            startTicking()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app, so the Dock icon goes away with the window that needed it.
        NSApp.setActivationPolicy(.accessory)
        // The clock keeps running; only the repainting stops. The figure comes from what is recorded rather than
        // from anything counting up in here, so a closed window costs nothing and misses nothing.
        stopTicking()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.defaultWidth, height: Layout.defaultHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Facet Settings"
        window.identifier = NSUserInterfaceItemIdentifier(Identifier.window)
        window.contentMinSize = NSSize(width: Layout.minimumWidth, height: Layout.minimumHeight)
        // Survives its own close, which is what makes the window reusable: without this, closing it
        // deallocates it and `window` above would be rebuilt on the next open, losing the selected
        // tab and the position on screen.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContentView()
        window.center()
        return window
    }

    /// The tab bar, the box of panes under it, and the Close button on its own row at the bottom.
    ///
    /// **Why the tab bar is a segmented control of our own** rather than the one `NSTabView` draws: with
    /// its tabs on top, `NSTabView` centres the bar on the top edge of its box, so the box begins
    /// half-way up the buttons and the shading starts mid-tab. `tabViewBorderType` cannot fix that while
    /// the tabs are on top -- it only applies when the tab position is `.none`, measured by setting it and
    /// watching nothing move. So the tab position *is* `.none` here: the tab view keeps only the panes and
    /// the switching between them, and the bar above is ours to place.
    ///
    /// With the box gone as well, a pane sits on the window's white, which is what the previous app looked
    /// like. The bar has the same gap under it as over it, so it reads as a band of its own.
    private func makeContentView() -> NSView {
        let content = NSView()
        let close = makeCloseButton()
        content.addSubview(tabBar)
        content.addSubview(panes)
        content.addSubview(close)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.tabBarMargin),
            tabBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            panes.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: Layout.tabBarMargin),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.panesSideInset),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.panesSideInset),
            panes.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -Layout.buttonSpacing),

            // Bottom right, where a window's dismissal belongs on this platform.
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.buttonPadding),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Layout.buttonPadding),
        ])
        return content
    }

    private func makeCloseButton() -> NSButton {
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.translatesAutoresizingMaskIntoConstraints = false
        close.identifier = NSUserInterfaceItemIdentifier(Identifier.close)
        close.setAccessibilityIdentifier(Identifier.close)
        closeButton = close
        // Escape closes the window, which is what a Close button is expected to answer to, and matters
        // more than usual here: an accessory app has no application menu, so ⌘W does not exist.
        //
        // It will need giving up once this window has text fields in it. A key equivalent is dispatched
        // before the focused field sees the key, so Escape would close the window out from under
        // somebody cancelling an edit, and the field cannot win that on its own.
        close.keyEquivalent = "\u{1b}"
        return close
    }

    /// The tab bar: one segment per tab, addressed **by its label, which arrives as `AXDescription`**.
    ///
    /// A label is the only name a tab button can have, whichever control draws it: a segmented control
    /// has no per-segment identifier, and `NSTabView`'s own bar has none either (`NSTabViewItem.identifier`
    /// does not reach `AXIdentifier`, and the item has no `setAccessibilityIdentifier` at all). The
    /// control itself is named, and each tab's *pane* carries the identifier that confirms a switch landed.
    ///
    /// So a script matches on `description`: `radio button "Report"` finds nothing, while `first radio
    /// button whose description is "Report"` finds it (measured, both ways round). That is the same
    /// contract the previous app exposed and the one `Archive/Tests/Methods.md` Method 10 is already written
    /// against -- `NSTabView`'s own bar, with its `AXTitle`s, was the odd one out. The path is one level
    /// shorter here: the segments are `radio group 1 of window`, where they used to be inside
    /// `group 1 of toolbar 1`, so that method needs its path updated when the checklists come back.
    lazy var tabBar: NSSegmentedControl = {
        let bar = NSSegmentedControl(
            labels: SettingsTab.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabBarChanged)
        )
        bar.selectedSegment = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setAccessibilityIdentifier(Identifier.tabs)
        // No focus ring. It draws around the selected segment once the bar has keyboard focus, and on
        // the first and last segments it is visible on the inward side only -- the outward side is
        // clipped by the bar's own edge -- so it reads as a gap opening beside the pill rather than a
        // ring around it. Measured both ways: with the window active the halo is there, and it
        // disappears entirely when another app takes focus.
        //
        // What this gives up is the indication that the tab bar is the focused control, which is nothing
        // while it is the only control up there. Worth re-examining when this window has fields to tab
        // between, at which point the ring is what says where the keyboard is pointing.
        bar.focusRingType = .none
        return bar
    }()

    /// The five panes, and the box drawn around them. No tab bar of its own -- see `makeContentView`.
    lazy var panes: NSTabView = {
        let panes = NSTabView()
        panes.translatesAutoresizingMaskIntoConstraints = false
        panes.setAccessibilityIdentifier(Identifier.panes)
        panes.tabPosition = .none
        // No box and no border, so a pane sits on the window's own white. Measured against the previous
        // app (`image/preferences-device.png`, `image/preferences-faces.png`): its content area was pure
        // white, and the only grey in the window was the section panels *inside* a pane. A bezel here
        // tinted the whole pane instead, which is the tinge that made the tab bar look like it was
        // resting on a shelf.
        panes.tabViewBorderType = .none
        for tab in SettingsTab.allCases {
            // Does not surface to accessibility, but it is how `tabViewItem(withIdentifier:)` finds a
            // tab from code, which is a different question from how a script finds one.
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = makePane(for: tab)
            panes.addTabViewItem(item)
        }
        // Set after the items are added, so the first tab landing selected as a side effect of being
        // added is not logged as somebody choosing it.
        panes.delegate = self
        return panes
    }()

    /// The tab every open lands on.
    ///
    /// **Faces, always**, whatever the window was last left on. It is where the time is: the category list,
    /// the clock, and starting or stopping it are all there and nowhere else, so it is what somebody opening
    /// this window came for. The previous app forced it only in manual mode and otherwise reopened wherever
    /// the user left off -- reasoning that moving somebody's window under them is worse than useless -- but
    /// that left a glance at Report costing a click to get back to the tab that does the work.
    ///
    /// A single value rather than a rule taking arguments, because there is nothing yet to weigh against it.
    /// The archive's version answered a second case (jump to Device while a low battery is blinking); when
    /// something here has a claim that strong, this becomes a decision again.
    static let tabOnOpen: SettingsTab = .faces

    /// Shows a tab, moving the bar and the pane together.
    ///
    /// Through the bar's selection rather than the tab view's, so the two cannot disagree: `tabBarChanged`
    /// is what drives the panes, and it is the only thing that does.
    ///
    /// Internal so what `show()` does to the tabs can be asserted without putting a window on somebody's
    /// screen, which is the only other thing `show()` does that a test would have to tolerate.
    func select(_ tab: SettingsTab) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab) else { return }
        tabBar.selectedSegment = index
        tabBarChanged()
    }

    @objc
    private func tabBarChanged() {
        guard tabBar.selectedSegment >= 0 else { return }
        // The switch itself is logged by the tab view's delegate, which fires for this and for a tab
        // chosen in code alike.
        panes.selectTabViewItem(at: tabBar.selectedSegment)
    }

    /// Records the tab that is now showing.
    ///
    /// "Selected", not "clicked": this fires for a tab chosen in code as well as one clicked, and the
    /// app does choose one itself (see `show`). A message that said "clicked" would then be a lie in
    /// exactly the case worth investigating.
    ///
    /// **It fires on a change, not on a selection.** Choosing the tab already showing is not a change, so this says
    /// nothing at all on an ordinary open now that Faces is both the first tab and the tab every open lands on --
    /// which is why `show` logs the open itself rather than leaving the evidence to this.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let label = tabViewItem?.label else { return }
        debugLog?.record(.tab, "Settings tab selected: \(label)")
        reloadSelectedPane()
    }

    private func makeFacesPane() -> FacesPane {
        let faces = FacesPane()
        faces.categoryList.onSelect = { [weak self] category in
            self?.startTiming(category)
        }
        faces.timingView.onTogglePause = { [weak self] in
            self?.togglePause()
        }
        wire(faces.createControl)
        return faces
    }

    /// The Report tab: the date range, and the totals it asks for.
    ///
    /// The range itself is not a setting and is not written anywhere -- it is a question, and it lasts as long as the
    /// window is open. What is read is the answer, every time the question changes.
    private func makeReportPane() -> ReportPane {
        let report = ReportPane()
        report.onRangeChange = { [weak self] start, end in
            self?.debugLog?.record(
                .report,
                "Report range \(Self.day(start)) -> \(end.map(Self.day) ?? "not set, reporting one day")"
            )
        }
        report.onShowMonth = { [weak self] calendar, month in
            self?.debugLog?.record(.report, "\(calendar) calendar showing \(Self.month(month))")
        }
        report.onNeedTotals = { [weak self, weak report] start, end in
            guard let report else { return }
            self?.loadTotals(into: report, start: start, end: end)
        }
        // Read when a group is opened, against the range on screen at that moment: the same bounds the total above the
        // entries was summed over, worked out the same way, so the rows add up to it.
        report.totalsList.entries = { [weak self, weak report] total in
            guard let self, let report, let entries = self.entries else { return [] }
            let bounds = self.reportBounds(start: report.start, end: report.end)
            return entries.entries(categoryID: total.categoryID, from: bounds.start, to: bounds.end)
        }
        report.totalsList.onToggle = { [weak self] total, isExpanded in
            self?.debugLog?.record(
                .report,
                "Report category \"\(total.name)\" \(isExpanded ? "opened" : "closed")"
            )
        }
        report.totalsList.onSort = { [weak self] order in
            self?.debugLog?.record(
                .report,
                "Report sorted by \(order.column == .time ? "time" : "category"), "
                    + "\(order.direction == .ascending ? "ascending" : "descending")"
            )
        }
        return report
    }

    /// The instants a picked range covers, measured against the daily reset **read now**.
    ///
    /// One place, because two things ask: the totals, and the entries behind whichever of them is opened. A boundary
    /// worked out twice is a boundary that can be worked out differently, and the symptom would be a column of figures
    /// that does not add up to the number above it.
    private func reportBounds(start: Date, end: Date?) -> (start: Date, end: Date) {
        let reset = DayWindow.resetTime(
            hour: settings?.integer("daily_reset_time", field: "hour"),
            minute: settings?.integer("daily_reset_time", field: "minute")
        )
        return ReportRangeRules.bounds(start: start, end: end, resetHour: reset.hour, resetMinute: reset.minute)
    }

    /// Reads what the picked range came to, and draws it.
    ///
    /// **Three reads, all of them here and now**: the day boundary the range is measured against, the entries inside
    /// it, and whether the figures carry seconds. None of them is held, which is the point -- the boundary can be
    /// changed on the App tab and the entries grow as time is recorded, so a total is only true as of the moment it
    /// was summed.
    ///
    /// The reset time comes from the table rather than from the App tab's copy of it, and the two cannot disagree: a
    /// changed row is written straight through and read back before that pane adopts it (see the source-of-truth rule
    /// in `CLAUDE.md`), so they differ for no longer than one write.
    private func loadTotals(into pane: ReportPane, start: Date, end: Date?) {
        // Both or neither: a range measured against a default boundary while the table holds another would be a figure
        // that looks right and is not. A controller built without them -- which is what a layout test builds -- draws
        // the calendars and no totals.
        guard let entries, let settings else { return }
        let bounds = reportBounds(start: start, end: end)
        let totals = entries.totals(from: bounds.start, to: bounds.end)
        pane.show(totals, showingSeconds: settings.flag("display_seconds", field: "enabled") ?? true)
        debugLog?.record(
            .report,
            "Report totals \(Self.dayAndTime(bounds.start)) -> \(Self.dayAndTime(bounds.end)): \(totals.count) categories"
        )
    }

    /// Local `yyyy-MM-dd` for the log, so a logged range reads against the timestamps around it rather than as an
    /// epoch.
    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// With the time, for the two ends of a range: the boundary is the point of them, so a log line that dropped it
    /// would not show whether the reset time was honoured.
    private static func dayAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Points a create control at the rules and the writer, wherever it is drawn.
    ///
    /// Both tabs offer one and both end here: the Faces tab because that is where the list is picked from, so it is
    /// where somebody notices a category is missing, and the Categories tab because that is where a category is made
    /// and looked after. Two ways in, one implementation, which is the same reason the three ways to pause end in one
    /// method.
    private func wire(_ control: CategoryCreateControl) {
        control.onSave = { [weak self, weak control] typed in
            guard let control else { return }
            self?.saveNewCategory(typed, from: control)
        }
        control.onEditingChanged = { [weak self] isEditing in
            // Escape belongs to whichever of the two needs it more. While a name is being typed that is
            // the field, since a key equivalent is dispatched before the focused field ever sees the key
            // -- so without this, Escape would close the window instead of abandoning the name, and the
            // field could not win that on its own.
            self?.closeButton?.keyEquivalent = isEditing ? "" : "\u{1b}"
        }
    }

    /// Acts on a typed category name.
    ///
    /// The decision is `CategoryCreateRules`', taken against the whole `category` table rather than the
    /// list on screen -- which shows only active categories, so a retired namesake is invisible to it and
    /// the one thing standing between a typo and two identical categories would be missing.
    ///
    /// The control that raised it is handed in rather than looked up, since there is now more than one and only the
    /// one that was typed into should fold up.
    private func saveNewCategory(_ typed: String, from control: CategoryCreateControl) {
        guard let categories else { return }
        switch CategoryCreateRules.decision(rawName: typed, matching: categories.matching(name:)) {
        case .ignore:
            control.collapse()

        case let .insert(name):
            let created = categories.insert(name: name)
            debugLog?.record(
                .click,
                "Button clicked: Save new category \"\(name)\" -> \(created.map { "category_id \($0)" } ?? "refused")"
            )
            control.collapse()
            // Re-read rather than adding the new row to the list by hand: the database is what the list
            // shows, and a row put there by the writer would be a second answer to what it holds.
            reloadSelectedPane()

        case let .retiredNamesakes(existing):
            debugLog?.record(
                .click,
                "Button clicked: Save new category \"\(existing[0].name)\" -> asking, \(existing.count) retired "
                    + "under that name: \(existing.map(\.id))"
            )
            control.collapse()
            askAboutRetiredNamesakes(existing)

        case let .alreadyActive(existing):
            debugLog?.record(
                .click,
                "Button clicked: Save new category \"\(existing.name)\" -> already active as category_id \(existing.id)"
            )
            control.collapse()
            showAlreadyActive(existing)
        }
    }

    /// Asks what to do about a name a retired category already holds, and does it.
    ///
    /// **Three answers, because two of them are legitimate.** Bringing the old one back keeps its history, which is
    /// usually what typing a name used before means; making a new one leaves that history where it is under a name
    /// being reused deliberately, which the database allows since only *active* names are unique. Nothing in the app
    /// can tell which was meant, so it asks rather than choosing -- this used to reactivate silently, which quietly
    /// took the second option away.
    ///
    /// The buttons and what they mean are `CategoryCreateRules`', in one list, so their order on screen and the
    /// meaning of the answer cannot drift apart.
    ///
    /// **With more than one retired namesake the Reactivate button is not offered at all**, since there is no answer
    /// to which of them to bring back: they share a name and nothing distinguishes them on a button. The dialogue
    /// still appears, saying how many there are, and offers the answer that is still available -- creating a new one
    /// -- or nothing. Somebody who wants a particular one back goes to the Inactive list, where each row carries the
    /// date that tells them apart.
    private func askAboutRetiredNamesakes(_ existing: [CategoryRecord]) {
        guard let categories, let first = existing.first else { return }
        let choices = CategoryCreateRules.choices(retiredNamesakes: existing.count)
        let alert = NSAlert()
        alert.messageText = CategoryCreateRules.retiredNamesakeMessage(name: first.name)
        alert.informativeText = CategoryCreateRules.retiredNamesakeCount(existing.count)
        for choice in choices {
            alert.addButton(withTitle: choice.buttonTitle)
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            self?.act(
                on: CategoryCreateRules.choice(forButtonIndex: index, offering: choices),
                about: first,
                named: first.name,
                in: categories
            )
        }
    }

    private func act(
        on choice: CategoryCreateRules.RetiredNamesakeChoice?,
        about existing: CategoryRecord,
        named name: String,
        in categories: CategoryStore
    ) {
        switch choice {
        case .reactivate:
            let succeeded = categories.setActive(id: existing.id, true)
            debugLog?.record(
                .click,
                "Button clicked: Reactivate \"\(existing.name)\" -> category_id \(existing.id)"
                    + "\(succeeded ? "" : " REFUSED")"
            )

        case .createNew:
            let created = categories.insert(name: name)
            debugLog?.record(
                .click,
                "Button clicked: Create new one \"\(name)\" -> \(created.map { "category_id \($0)" } ?? "refused")"
                    + ", leaving category_id \(existing.id) retired"
            )

        case .cancel, nil:
            // `nil` is a response no button of ours produced -- a sheet dismissed by something else -- and it means
            // the same as Cancel: the name was typed and nothing came of it.
            debugLog?.record(.click, "Button clicked: Cancel, \"\(name)\" not created")
            return
        }
        // Only the two that wrote get here: either changes which rows belong in which list.
        reloadSelectedPane()
    }

    /// The dead end: an active category already holds the name, so there is nothing to decide and only
    /// something to say. Wording carried over from the previous app.
    private func showAlreadyActive(_ existing: CategoryRecord) {
        let alert = NSAlert()
        alert.messageText = "That category already exists"
        alert.informativeText = "\"\(existing.name)\" is already in the Active list. Scroll up -- it is right there."
        alert.addButton(withTitle: "Ok")
        alert.beginSheetModal(for: window)
    }

    @objc
    private func closeWindow() {
        debugLog?.record(.click, "Button clicked: Close (Settings window)")
        window.performClose(nil)
    }

    /// An empty pane, named so a script can confirm which tab it is looking at.
    ///
    /// All three calls are load-bearing, and the first is the one that is easy to miss: an ordinary
    /// `NSView` is not an accessibility element, so without `setAccessibilityElement(true)` the role
    /// and identifier below are simply never asked for and the pane is absent from the tree (measured:
    /// it came back as an untitled `AXGroup` with no identifier). `.group` is what an empty container
    /// should be anyway -- it is about to hold this tab's controls.
    private func makePane(for tab: SettingsTab) -> NSView {
        let pane: NSView
        switch tab {
        case .faces: pane = makeFacesPane()
        case .categories: pane = CategoriesPane()
        case .app: pane = AppSettingsPane()
        case .report: pane = makeReportPane()
        // Empty, and it becomes its own view when there is something to put in it.
        case .device: pane = NSView()
        }
        // The tab view hands each pane the content rect and resizes it from there, so the pane keeps
        // its autoresizing frame rather than being pinned by constraints from out here.
        pane.autoresizingMask = [.width, .height]
        pane.setAccessibilityElement(true)
        pane.setAccessibilityRole(.group)
        pane.setAccessibilityIdentifier(tab.paneIdentifier)
        pane.setAccessibilityLabel(tab.title)
        return pane
    }
}

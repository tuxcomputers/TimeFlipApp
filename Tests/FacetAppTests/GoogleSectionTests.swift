@testable import FacetApp
import AppKit
import XCTest

/// The App tab's Google section: what it says for a given `google_account` row, and what the one working button does.
@MainActor
final class GoogleSectionTests: XCTestCase {
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func view(_ identifier: String, in root: NSView) -> NSView? {
        descendants(of: root).first { $0.accessibilityIdentifier() == identifier }
    }

    private func text(_ identifier: String, in root: NSView) -> String? {
        (view(identifier, in: root) as? NSTextField)?.stringValue
    }

    /// `credential` defaults to `.present`, so a test that names an account gets the ordinary case: somebody signed
    /// in and the token is where it was left. The states where the two halves disagree are asked for explicitly,
    /// which is the point of them being separate arguments at all.
    private func pane(
        name: String? = nil,
        email: String? = nil,
        credentials: Bool = true,
        credential: GoogleAccountRules.Credential = .present,
        verification: GoogleAccountRules.Verification = .notAsked,
        calendar: GoogleCalendarRules.Calendar = .none
    ) -> AppSettingsPane {
        let pane = AppSettingsPane()
        var values = AppSettingsPane.Values.seeded
        values.googleAccount = GoogleAccountRules.account(name: name, email: email)
        values.googleCredential = credential
        values.googleVerification = verification
        values.googleCredentialsAvailable = credentials
        values.googleCalendar = calendar
        pane.show(values)
        return pane
    }

    // MARK: - the calendar row

    func testThereIsNoCalendarRowUntilThereIsAnAccount() {
        // A calendar belongs to an account. Offering to make one before there is somewhere to make it would be a
        // button that can only fail.
        XCTAssertNil(view(AppSettingsPane.Identifier.googleCalendar, in: pane()))
        XCTAssertNil(view(AppSettingsPane.Identifier.googleCalendarCreate, in: pane()))
    }

    func testAConnectedAccountWithNoCalendarOffersToMakeOne() throws {
        // The recovery path. It is normally unreachable, because signing in makes the calendar.
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au")

        XCTAssertNil(view(AppSettingsPane.Identifier.googleCalendar, in: pane), "nothing to name yet")
        let button = try XCTUnwrap(
            view(AppSettingsPane.Identifier.googleCalendarCreate, in: pane) as? NSButton
        )
        XCTAssertEqual(button.title, "Create calendar")

        var requested: [AppSettingsPane.Change] = []
        pane.onChange = { requested.append($0) }
        button.performClick(nil)
        XCTAssertEqual(requested, [.googleCalendarCreateRequested])
    }

    func testAnExistingCalendarIsShownByNameAndCanBeRenamed() throws {
        let pane = self.pane(
            name: "Harry", email: "harry@tux.com.au",
            calendar: GoogleCalendarRules.calendar(id: "abc@group.calendar.google.com", name: "Facet")
        )
        var requested: [AppSettingsPane.Change] = []
        pane.onChange = { requested.append($0) }

        // The same cell a category name uses, so the name is read from the cell rather than from a live field.
        let cell = try XCTUnwrap(pane.calendarCell)
        XCTAssertEqual(cell.name, "Facet")
        XCTAssertEqual(cell.alignment, .right, "the App tab puts every value against the right edge")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleCalendarCreate, in: pane), "nothing to create")

        cell.onCommit?("  Work time  ")
        XCTAssertEqual(requested, [.googleCalendarNamed("Work time")], "trimmed on the way out")
    }

    func testCommittingAnUnchangedNameSpendsNothing() throws {
        // Opening the name and pressing Return without changing it must not become a request to Google. This mattered
        // more when the row was a live text field, whose action fires on losing focus as well: tabbing past the
        // calendar spent a rename. The cell only commits on Return now, and this still holds the line.
        let pane = self.pane(
            name: "Harry", email: "harry@tux.com.au",
            calendar: GoogleCalendarRules.calendar(id: "abc", name: "Facet")
        )
        var requested: [AppSettingsPane.Change] = []
        pane.onChange = { requested.append($0) }

        let cell = try XCTUnwrap(pane.calendarCell)
        cell.onCommit?("Facet")

        XCTAssertEqual(requested, [])
    }

    func testEscapeIsLentToTheCalendarNameWhileItIsBeingEdited() throws {
        // A key equivalent is dispatched before the focused field ever sees the key, so without the loan Escape would
        // close the window instead of abandoning a half-typed name. The Categories tab makes the same loan.
        let pane = self.pane(
            name: "Harry", email: "harry@tux.com.au",
            calendar: GoogleCalendarRules.calendar(id: "abc", name: "Facet")
        )
        var editing: [Bool] = []
        pane.onCalendarEditingChanged = { editing.append($0) }

        let cell = try XCTUnwrap(pane.calendarCell)
        cell.beginEditing()
        cell.endEditing()

        XCTAssertEqual(editing, [true, false])
    }

    func testDisconnectingKeepsTheCalendar() {
        // Signing out and back in on the same account is the common case, and forgetting the id would make a second
        // "Facet" beside the first with the history split across the two. The id is checked on the way back in rather
        // than trusted, so a different person's sign-in finds it does not resolve and is asked what to do.
        let pane = self.pane(
            name: "Harry", email: "harry@tux.com.au",
            calendar: GoogleCalendarRules.calendar(id: "abc", name: "Facet")
        )

        pane.adopt(.googleDisconnected)

        XCTAssertTrue(pane.values.googleCalendar.exists, "the pointer survives the sign-out")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleCalendar, in: pane),
                     "but there is nothing to show, since the section has no account to show it under")
    }

    func testAForgottenCalendarLeavesTheCreateButton() {
        // What a sign-in meets when the stored id does not resolve, and the user answers "Not Now": the app must not
        // be left holding an id it knows is dead.
        let pane = self.pane(
            name: "Harry", email: "harry@tux.com.au",
            calendar: GoogleCalendarRules.calendar(id: "abc", name: "Facet")
        )

        pane.adopt(.googleCalendarChanged(.none))

        XCTAssertFalse(pane.values.googleCalendar.exists)
        XCTAssertNotNil(view(AppSettingsPane.Identifier.googleCalendarCreate, in: pane))
    }

    // MARK: - what the row holds

    func testAnAccountWithNeitherNameNorEmailHasNoIdentity() {
        // The row is seeded as `{}` and stays that way until a sign-in fills it, so "no fields" is the normal state
        // rather than an error, and it has to read as not connected rather than as a connection with blanks in it.
        XCTAssertFalse(GoogleAccountRules.account(name: nil, email: nil).hasIdentity)
        XCTAssertEqual(GoogleAccountRules.status(for: .notConnected), "Not connected")
    }

    func testEitherFieldAloneIsStillAnIdentity() {
        // The userinfo endpoint can answer with no name on the profile. That is a connected account with one thing
        // to show, not a broken one.
        XCTAssertTrue(GoogleAccountRules.account(name: nil, email: "h@tux.com.au").hasIdentity)
        XCTAssertTrue(GoogleAccountRules.account(name: "Harry", email: nil).hasIdentity)
    }

    func testABlankFieldCountsAsAbsent() {
        // Signing out writes empty strings rather than deleting the keys, since the row's other fields have to
        // survive. So an empty string has to mean the same as a missing one, or a sign-out would leave the section
        // claiming a connection to an account called "".
        XCTAssertFalse(GoogleAccountRules.account(name: "", email: "   ").hasIdentity)
    }

    // MARK: - an identity is not a connection

    func testAnIdentityWithNoTokenIsNotConnected() {
        // **The fault this whole type was reshaped for, measured on 2026-08-26.** `google_account` held a name, an
        // email, a calendar id and a calendar name, the App tab read Connected, and the Keychain had no item at all.
        // The row was never wrong; it was only ever half the answer.
        let account = GoogleAccountRules.account(name: "Harry", email: "harry@tux.com.au")
        XCTAssertTrue(account.hasIdentity, "the row still names somebody")
        XCTAssertEqual(GoogleAccountRules.state(for: account, credential: .missing), .signedOut)
        XCTAssertEqual(GoogleAccountRules.status(for: .signedOut), "Signed out")
    }

    func testAKeychainThatWillNotAnswerIsNotAnAbsentToken() {
        // The two used to be indistinguishable, because every non-success status collapsed to `nil`. They have
        // opposite remedies: one is fixed by signing in, the other by finding out why the item cannot be read, and
        // sending somebody through a browser consent for the second throws away a connection that works.
        let account = GoogleAccountRules.account(name: "Harry", email: "harry@tux.com.au")
        XCTAssertEqual(GoogleAccountRules.state(for: account, credential: .unavailable), .unreadable)
        XCTAssertEqual(GoogleAccountRules.status(for: .unreadable), "Cannot be checked")
        XCTAssertEqual(GoogleAccountRules.action(for: .unreadable), .disconnect,
                       "nobody is told to sign in again over a question that was never answered")
    }

    func testBeingOfflineIsNotBeingSignedOut() {
        // A check that cannot be made says nothing, and must not read as an answer. Rendering "Not connected" at
        // somebody on a plane would have them re-consent in a browser to fix a connection that is fine.
        let account = GoogleAccountRules.account(name: "Harry", email: "harry@tux.com.au")
        let state = GoogleAccountRules.state(
            for: account, credential: .present, verification: .unreachable("offline")
        )
        XCTAssertEqual(state, .unreachable)
        XCTAssertEqual(GoogleAccountRules.status(for: state), "Connected, not checked")
        XCTAssertEqual(GoogleAccountRules.action(for: state), .disconnect)
        XCTAssertTrue(GoogleAccountRules.showsCalendar(for: state), "still the best answer anyone has")
    }

    func testGoogleRefusingTheTokenOffersASignIn() {
        // The one state where Google has actually spoken against the stored token. Nothing local fixes it.
        let account = GoogleAccountRules.account(name: "Harry", email: "harry@tux.com.au")
        let state = GoogleAccountRules.state(
            for: account, credential: .present, verification: .refused("invalid_grant")
        )
        XCTAssertEqual(state, .expired)
        XCTAssertEqual(GoogleAccountRules.status(for: state), "Sign-in expired")
        XCTAssertEqual(GoogleAccountRules.action(for: state), .signIn)
        XCTAssertFalse(GoogleAccountRules.showsCalendar(for: state),
                       "a Create that is going to be refused is a button that can only fail")
    }

    func testAStoredTokenReadsAsConnectedBeforeAnyoneHasAsked() {
        // Opening a window is not asking Google anything, and the instant before the answer comes back must not
        // flicker through "Not connected". The token being there is a real local fact, and strictly more than the
        // old code knew.
        let account = GoogleAccountRules.account(name: "Harry", email: "harry@tux.com.au")
        XCTAssertEqual(GoogleAccountRules.state(for: account, credential: .present), .unverified)
        XCTAssertEqual(GoogleAccountRules.status(for: .unverified), "Connected")
    }

    func testNoIdentityOutranksWhateverTheKeychainSays() {
        // A token with no account named beside it is not something to offer a Disconnect for. Whatever it is, it is
        // not a connection anybody can see.
        let none = GoogleAccountRules.Account.none
        XCTAssertEqual(GoogleAccountRules.state(for: none, credential: .present), .notConnected)
        XCTAssertEqual(GoogleAccountRules.state(for: none, credential: .unavailable), .notConnected)
    }

    // MARK: - what the section draws in each of them

    func testASignedOutSectionSaysSoAndOffersASignIn() throws {
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au", credential: .missing)

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Signed out")
        let button = try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton)
        XCTAssertEqual(button.title, "Sign in with Google")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleCalendarCreate, in: pane),
                     "no calendar can be made without a token")
        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.googleNote, in: pane) as? NSTextField)
        XCTAssertTrue(note.stringValue.contains("remembered but its sign-in is not"))
    }

    func testPressingTheButtonWhileSignedOutAsksForASignInNotADisconnect() throws {
        // The button used to be decided from the identity alone, so this state offered Disconnect: a control that
        // said one thing and did another.
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au", credential: .missing)
        var requested: [AppSettingsPane.Change] = []
        pane.onChange = { requested.append($0) }

        try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton).performClick(nil)

        XCTAssertEqual(requested, [.googleSignInRequested])
    }

    func testAnUnreadableKeychainSaysWhatItCannotDoRatherThanBlamingTheAccount() throws {
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au", credential: .unavailable)

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Cannot be checked")
        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.googleNote, in: pane) as? NSTextField)
        XCTAssertTrue(note.stringValue.contains("Keychain"))
    }

    func testAdoptingAVerdictRedrawsTheSection() throws {
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au")
        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Connected")

        pane.adopt(.googleVerified(.refused("invalid_grant")))

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Sign-in expired")
        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.googleNote, in: pane) as? NSTextField)
        XCTAssertTrue(note.stringValue.contains("invalid_grant"), "says what Google actually said")
    }

    func testDisconnectingForgetsBothHalvesAtOnce() throws {
        // Leaving the credential at `.present` would leave the section one read away from claiming a connection to
        // an account it has just let go of.
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au", verification: .working)

        pane.adopt(.googleDisconnected)

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Not connected")
        XCTAssertEqual(pane.values.googleCredential, .missing)
        XCTAssertEqual(pane.values.googleVerification, .notAsked)
    }

    // MARK: - what the section draws

    func testAnUnconnectedSectionOffersSignIn() throws {
        let pane = self.pane()

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Not connected")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleAccount, in: pane), "no account row to show")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleEmail, in: pane), "and no email row")

        let button = try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton)
        XCTAssertEqual(button.title, "Sign in with Google")
        XCTAssertTrue(button.isEnabled)
        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.googleNote, in: pane) as? NSTextField)
        XCTAssertFalse(note.isHidden)
        XCTAssertTrue(note.stringValue.contains("calendar it makes itself"),
                      "says what pressing it does, and how little it touches")
    }

    func testABuildWithNoCredentialsCannotSignInAndSaysSo() throws {
        // A real state rather than a hypothetical: the client id and secret are injected at build time, so a copy
        // built without them exists. A dead button with no reason reads as a bug.
        let pane = self.pane(credentials: false)

        let button = try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton)
        XCTAssertFalse(button.isEnabled)
        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.googleNote, in: pane) as? NSTextField)
        XCTAssertTrue(note.stringValue.contains("without Google credentials"))
    }

    func testDisconnectingNeedsNoCredentials() throws {
        // Signing out is clearing a row and a Keychain item. A build that cannot sign in must still be able to let go
        // of an account it is already holding.
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au", credentials: false)
        XCTAssertTrue(try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton).isEnabled)
    }

    func testTheButtonIsOffWhileASignInIsRunning() throws {
        // Otherwise a second press opens a second browser window on a second listener, and the first one is orphaned.
        let pane = self.pane()
        pane.setSigningIn(true)

        let button = try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton)
        XCTAssertEqual(button.title, "Signing in...")
        XCTAssertFalse(button.isEnabled)
    }

    func testPressingSignInAsksRatherThanActs() throws {
        let pane = self.pane()
        var requested: [AppSettingsPane.Change] = []
        pane.onChange = { requested.append($0) }

        try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton).performClick(nil)

        XCTAssertEqual(requested, [.googleSignInRequested])
        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Not connected",
                       "nothing changes until the table says it did")
    }

    func testAdoptingAConnectionDrawsTheAccount() throws {
        let pane = self.pane()

        pane.adopt(.googleConnected(GoogleAccountRules.account(name: "Harry", email: "harry@tux.com.au")))

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Connected")
        XCTAssertEqual(text(AppSettingsPane.Identifier.googleEmail, in: pane), "harry@tux.com.au")
        XCTAssertEqual(pane.values.googleCredential, .present,
                       "a sign-in that got this far stored a token, so both halves move together")
    }

    func testAConnectedSectionNamesTheAccountAndOffersDisconnect() throws {
        let pane = self.pane(name: "Harry Phillips", email: "harry@tux.com.au")

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Connected")
        XCTAssertEqual(text(AppSettingsPane.Identifier.googleAccount, in: pane), "Harry Phillips")
        XCTAssertEqual(text(AppSettingsPane.Identifier.googleEmail, in: pane), "harry@tux.com.au")

        let button = try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton)
        XCTAssertEqual(button.title, "Disconnect")
        XCTAssertTrue(button.isEnabled, "disconnecting is something this app can do on its own")
        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.googleNote, in: pane) as? NSTextField)
        XCTAssertTrue(note.isHidden, "nothing to explain when the button works")
    }

    func testTheSectionSitsBelowAppSettings() throws {
        // The archive put Google first. It is last here: the six settings above are what somebody opens this tab to
        // change, and a connection made once belongs under them.
        let pane = self.pane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 700)
        pane.layoutSubtreeIfNeeded()

        let google = try XCTUnwrap(view(AppSettingsPane.Identifier.googleSection, in: pane))
        let app = try XCTUnwrap(view(AppSettingsPane.Identifier.section, in: pane))
        XCTAssertFalse(pane.isFlipped, "if this ever flips, the comparison below turns around")
        XCTAssertLessThan(google.frame.minY, app.frame.minY, "AppKit's origin is bottom-left: lower down is a smaller y")
    }

    func testBothPanelsSpanTheWidthOfTheTab() throws {
        // `CLAUDE.md`: every panel on every tab runs the full width, inset by the tab's own padding and nothing more.
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au")
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 700)
        pane.layoutSubtreeIfNeeded()

        for identifier in [AppSettingsPane.Identifier.googleSection, AppSettingsPane.Identifier.section] {
            let panel = try XCTUnwrap(view(identifier, in: pane))
            XCTAssertEqual(panel.frame.width, 640 - 40, accuracy: 0.5, "\(identifier) stops short of the edge")
        }
    }

    // MARK: - disconnecting

    func testPressingDisconnectAsksRatherThanActs() throws {
        // Every row on this tab is a request: the window writes it, reads it back, and only then does the pane adopt
        // it. The section must not put itself into the disconnected state on the press.
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au")
        var requested: [AppSettingsPane.Change] = []
        pane.onChange = { requested.append($0) }

        try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton).performClick(nil)

        XCTAssertEqual(requested, [.googleDisconnected])
        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Connected",
                       "still connected until the table says otherwise")
    }

    func testAdoptingTheDisconnectRedrawsTheSection() throws {
        let pane = self.pane(name: "Harry", email: "harry@tux.com.au")

        pane.adopt(.googleDisconnected)

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Not connected")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleAccount, in: pane))
        XCTAssertNil(view(AppSettingsPane.Identifier.googleEmail, in: pane))
        XCTAssertEqual(
            (view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton)?.title,
            "Sign in with Google"
        )
    }

    func testDisconnectingHasNoSingleDestination() {
        // It empties two fields, so it cannot go through the one-field mapping every other row uses. Returning nil
        // is what keeps the window from writing half of it.
        XCTAssertNil(AppSettingsRules.destination(for: .googleDisconnected))
        XCTAssertEqual(AppSettingsRules.title(for: .googleDisconnected), "Google account")
    }
}

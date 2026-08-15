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

    private func pane(
        name: String? = nil,
        email: String? = nil,
        credentials: Bool = true,
        calendar: GoogleCalendarRules.Calendar = .none
    ) -> AppSettingsPane {
        let pane = AppSettingsPane()
        var values = AppSettingsPane.Values.seeded
        values.googleAccount = GoogleAccountRules.account(name: name, email: email)
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

        let field = try XCTUnwrap(view(AppSettingsPane.Identifier.googleCalendar, in: pane) as? NSTextField)
        XCTAssertEqual(field.stringValue, "Facet")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleCalendarCreate, in: pane), "nothing to create")

        field.stringValue = "  Work time  "
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(requested, [.googleCalendarNamed("Work time")], "trimmed on the way out")
    }

    func testCommittingAnUnchangedNameSpendsNothing() throws {
        // Tabbing out of a field commits it. That must not become a request to Google.
        let pane = self.pane(
            name: "Harry", email: "harry@tux.com.au",
            calendar: GoogleCalendarRules.calendar(id: "abc", name: "Facet")
        )
        var requested: [AppSettingsPane.Change] = []
        pane.onChange = { requested.append($0) }

        let field = try XCTUnwrap(view(AppSettingsPane.Identifier.googleCalendar, in: pane) as? NSTextField)
        field.sendAction(field.action, to: field.target)

        XCTAssertEqual(requested, [])
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

    func testAnAccountWithNeitherNameNorEmailIsNotAConnection() {
        // The row is seeded as `{}` and stays that way until a sign-in fills it, so "no fields" is the normal state
        // rather than an error, and it has to read as not connected rather than as a connection with blanks in it.
        XCTAssertFalse(GoogleAccountRules.account(name: nil, email: nil).isConnected)
        XCTAssertEqual(GoogleAccountRules.status(for: .none), "Not connected")
    }

    func testEitherFieldAloneIsStillAConnection() {
        // The userinfo endpoint can answer with no name on the profile. That is a connected account with one thing
        // to show, not a broken one.
        XCTAssertTrue(GoogleAccountRules.account(name: nil, email: "h@tux.com.au").isConnected)
        XCTAssertTrue(GoogleAccountRules.account(name: "Harry", email: nil).isConnected)
    }

    func testABlankFieldCountsAsAbsent() {
        // Signing out writes empty strings rather than deleting the keys, since the row's other fields have to
        // survive. So an empty string has to mean the same as a missing one, or a sign-out would leave the section
        // claiming a connection to an account called "".
        XCTAssertFalse(GoogleAccountRules.account(name: "", email: "   ").isConnected)
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

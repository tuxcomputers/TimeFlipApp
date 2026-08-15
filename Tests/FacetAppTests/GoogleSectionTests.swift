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

    private func pane(name: String? = nil, email: String? = nil) -> AppSettingsPane {
        let pane = AppSettingsPane()
        var values = AppSettingsPane.Values.seeded
        values.googleAccount = GoogleAccountRules.account(name: name, email: email)
        pane.show(values)
        return pane
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

    func testAnUnconnectedSectionOffersSignInAndSaysWhyItCannot() throws {
        let pane = self.pane()

        XCTAssertEqual(text(AppSettingsPane.Identifier.googleStatus, in: pane), "Not connected")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleAccount, in: pane), "no account row to show")
        XCTAssertNil(view(AppSettingsPane.Identifier.googleEmail, in: pane), "and no email row")

        let button = try XCTUnwrap(view(AppSettingsPane.Identifier.googleButton, in: pane) as? NSButton)
        XCTAssertEqual(button.title, "Sign in with Google")
        // Disabled rather than absent, and with the reason beside it: the archive did the same when its credentials
        // were missing. A button that is off and says why beats one that is on and does nothing.
        XCTAssertFalse(button.isEnabled)
        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.googleNote, in: pane) as? NSTextField)
        XCTAssertFalse(note.isHidden)
        XCTAssertTrue(note.stringValue.contains("not built yet"))
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

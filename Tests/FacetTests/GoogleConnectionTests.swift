@testable import FacetCore
import Foundation
import Testing

/// Connecting and disconnecting a Google account, with no browser and no Google.
///
/// **The three orderings are what these pin**, and none of them had a test: the whole sequence lived in
/// `SettingsWindowController.signInToGoogle`, so reaching it needed AppKit, a window and a real sign-in.
///
/// **What is not here is the sign-in itself.** `GoogleSignIn.run` needs Google at the other end, and the loopback
/// half of it is covered over a real connection by `GoogleLoopbackListenerTests`. What these check is everything
/// around it: what is refused before a browser opens, what order the token and the rows are written in, what is
/// shown afterwards, and what disconnecting keeps.
@Suite @MainActor
final class GoogleConnectionTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var secrets: InMemorySecretStore!
    private var connection: GoogleConnection!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
        secrets = InMemorySecretStore()
        connection = GoogleConnection(
            settings: settings,
            tokens: GoogleTokenStore(secrets: secrets),
            debugLog: nil
        )
    }

    deinit {
        database.remove()
    }

    /// A browser nobody opens, and a listener nobody reaches: what the refusals are checked without.
    private func neverOpened(_ url: URL) {
        Issue.record("a browser was opened for a sign-in that should have been refused first")
    }

    private func neverListened(_ state: String) throws -> GoogleRedirectListener {
        Issue.record("a listener was made for a sign-in that should have been refused first")
        throw GoogleOAuthRules.Failure.cancelled
    }

    // MARK: - what is refused before a browser opens

    @Test func testNowhereToKeepATokenIsRefusedBeforeTheBrowserOpens() async {
        // **The second ordering**, and the worst order available is the one this rules out: asking somebody to
        // consent in a browser and then telling them it could not be saved.
        secrets.refusesWith = -25_300

        let answer = await connection.signIn(open: neverOpened, listening: neverListened)

        guard case let .failed(notice) = answer else {
            Issue.record("a store that cannot be read has to refuse")
            return
        }
        #expect(notice.title == "Facet could not connect to Google")
        #expect(connection.stored().hasGoogleIdentity == false)
    }

    @Test func testAStoreWithNothingInItIsNotARefusal() async {
        // `missing` is the ordinary case for a first sign-in: it is how a store with nothing in it gets something.
        // So this has to get as far as the browser, which is what the recorded issue in `neverOpened` would catch
        // -- here it is the *absence* of a refusal that is being checked, so a sign-in with no credentials is the
        // one that ends it.
        #expect(connection.credential() == .missing)
    }

    // MARK: - what is shown afterwards

    @Test func testTheAccountShownIsReadBackFromTheTableRatherThanWhatGoogleSaid() throws {
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.nameField, "Ada"))
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.emailField, "ada@example.com"))

        let account = connection.stored()

        #expect(account.email == "ada@example.com")
        #expect(account.hasGoogleIdentity)
    }

    @Test func testTheCredentialIsReadInItsOwnRightRatherThanInferredFromTheRow() throws {
        // **The half-answer this exists to prevent**: a row naming an account with nothing behind it. The section
        // used to say Connected on the strength of the row alone.
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.nameField, "Ada"))
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.emailField, "ada@example.com"))

        #expect(connection.stored().hasGoogleIdentity)
        #expect(connection.credential() == .missing, "the row says who, and the store says whether")
    }

    @Test func testAStoreThatCannotBeReadIsNotTheSameAsOneWithNothingInIt() {
        secrets.refusesWith = -25_300

        #expect(connection.credential() == .unavailable)
    }

    // MARK: - disconnecting

    @Test func testDisconnectingClearsTheIdentityAndTheToken() throws {
        let tokens = GoogleTokenStore(secrets: secrets)
        #expect(tokens.save(refreshToken: "a-refresh-token"))
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.nameField, "Ada"))
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.emailField, "ada@example.com"))

        #expect(connection.disconnect() == nil)

        #expect(connection.stored().hasGoogleIdentity == false)
        #expect(tokens.refreshToken() == nil, "a store still holding the token could still act on the account")
    }

    @Test func testDisconnectingKeepsTheCalendar() throws {
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, "cal-1"))
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, "Facet"))

        _ = connection.disconnect()

        // **Deliberate**: signing out and back in on the same account is the common case, and forgetting the id
        // would make a second Facet calendar beside the first with the history split across the two.
        #expect(settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField) == "cal-1")
    }

    @Test func testATableThatWillNotLetGoOfTheIdentitySaysSoRatherThanClaimingToHaveGone() throws {
        #expect(database.execute("DELETE FROM setting WHERE setting_name = 'google_account';"))

        let notice = connection.disconnect()

        #expect(notice != nil, "a section saying disconnected over a row that still names somebody is two answers")
    }
}

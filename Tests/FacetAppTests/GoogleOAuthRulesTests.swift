@testable import FacetApp
import CryptoKit
import Foundation
import XCTest

/// The sign-in flow's decisions, checked without a browser, a socket or a Google account.
///
/// What is deliberately **not** here: the round trip itself. Opening a URL, binding a port and two HTTPS requests can
/// only be checked against the real thing, which is a live-app run rather than `swift test`.
final class GoogleOAuthRulesTests: XCTestCase {
    // MARK: - PKCE

    func testTheChallengeIsTheSha256OfTheVerifier() throws {
        // The one thing actually protecting the exchange, given that the client secret ships in the binary. If the
        // challenge did not match the verifier, Google would reject every sign-in; if it were the verifier itself,
        // anybody intercepting the redirect could complete the exchange.
        let pkce = GoogleOAuthRules.pkce()
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pkce.challenge, expected)
    }

    func testTheVerifierIsUrlSafeAndLongEnough() {
        // RFC 7636 wants 43 to 128 characters from an unreserved alphabet. Padding or a "+" would be re-encoded in
        // the query string and stop matching.
        let pkce = GoogleOAuthRules.pkce()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertNil(pkce.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testEveryAttemptGetsItsOwnVerifierAndState() {
        // A reused verifier is a reused secret, and a reused state cannot tell one attempt's redirect from another's.
        XCTAssertNotEqual(GoogleOAuthRules.pkce().verifier, GoogleOAuthRules.pkce().verifier)
        XCTAssertNotEqual(GoogleOAuthRules.state(), GoogleOAuthRules.state())
    }

    // MARK: - the authorization URL

    func testTheAuthorizationUrlAsksForOfflineAccessAndConsent() throws {
        let url = GoogleOAuthRules.authorizationURL(
            clientID: "abc.apps.googleusercontent.com",
            redirect: "http://127.0.0.1:51234",
            pkce: GoogleOAuthRules.PKCE(verifier: "v", challenge: "c"),
            state: "s"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        // Without both of these Google returns no refresh token on a second sign-in, and the app quietly loses the
        // ability to sync an hour later.
        XCTAssertEqual(value("access_type"), "offline")
        XCTAssertEqual(value("prompt"), "consent")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), "c")
        XCTAssertEqual(value("state"), "s")
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:51234")
    }

    func testItAsksForExactlyTheFourScopesTheConsoleHas() throws {
        // Asking for more than the console is configured with is rejected outright; asking for less gets a token that
        // cannot make the calendar. Both are silent until somebody tries to sign in.
        let url = GoogleOAuthRules.authorizationURL(
            clientID: "abc", redirect: "http://127.0.0.1:1", pkce: .init(verifier: "v", challenge: "c"), state: "s"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let scopes = try XCTUnwrap(items.first { $0.name == "scope" }?.value).split(separator: " ").map(String.init)
        XCTAssertEqual(Set(scopes), [
            "openid",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
            "https://www.googleapis.com/auth/calendar.app.created",
        ])
        XCTAssertFalse(scopes.contains { $0.hasSuffix("/calendar.events") || $0.hasSuffix("/calendar.readonly") },
                       "the two sensitive ones, which are what keep this app out of verification")
    }

    // MARK: - the redirect

    func testTheCodeIsReadFromTheRequestLine() {
        let line = "GET /?state=abc&code=4/0AeanS0 HTTP/1.1"
        XCTAssertEqual(GoogleOAuthRules.redirect(fromRequestLine: line, expectedState: "abc"), .code("4/0AeanS0"))
    }

    func testAMismatchedStateIsIgnoredRatherThanFailed() {
        // Anything that can reach the loopback port could otherwise cancel somebody's sign-in by connecting to it.
        // "Not the redirect I am waiting for" is the honest reading.
        let line = "GET /?state=somebody-elses&code=4/0AeanS0 HTTP/1.1"
        XCTAssertEqual(GoogleOAuthRules.redirect(fromRequestLine: line, expectedState: "abc"), .ignored)
    }

    func testTheBrowsersFaviconRequestIsIgnored() {
        // It arrives beside the redirect on the same port. Treating it as the answer ends the sign-in on whichever
        // request happened to land second.
        XCTAssertEqual(
            GoogleOAuthRules.redirect(fromRequestLine: "GET /favicon.ico HTTP/1.1", expectedState: "abc"),
            .ignored
        )
    }

    func testPressingCancelAtGoogleComesBackAsDenied() {
        let line = "GET /?error=access_denied&state=abc HTTP/1.1"
        XCTAssertEqual(
            GoogleOAuthRules.redirect(fromRequestLine: line, expectedState: "abc"),
            .denied("access_denied")
        )
        XCTAssertEqual(
            GoogleOAuthRules.Failure.denied("access_denied").errorDescription,
            "Sign-in was cancelled at the Google page."
        )
    }

    // MARK: - the token response

    private func idToken(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    func testTheIdentityComesOutOfTheIdTokenRatherThanASecondRequest() throws {
        // The userinfo endpoint would be one more request per sign-in against the project's own quota, for something
        // already in hand.
        let token = try idToken(["name": "Harry Phillips", "email": "harry@tux.com.au"])
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": "at", "refresh_token": "rt", "id_token": token,
        ])

        let tokens = try XCTUnwrap(GoogleOAuthRules.tokens(fromTokenResponse: body))
        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertEqual(tokens.refreshToken, "rt")
        XCTAssertEqual(tokens.name, "Harry Phillips")
        XCTAssertEqual(tokens.email, "harry@tux.com.au")
    }

    func testAnIdTokenWhosePayloadNeedsPaddingStillDecodes() throws {
        // base64url drops the padding and Foundation's decoder insists on it. A claim set whose length is not a
        // multiple of four is the common case, not the corner one.
        let token = try idToken(["email": "a@b.co"])
        XCTAssertEqual(GoogleOAuthRules.claims(fromIDToken: token)?["email"] as? String, "a@b.co")
    }

    func testAResponseWithNoRefreshTokenIsReadAsSuch() throws {
        // Google decides whether to issue one. Treating its absence as success gives an app that syncs for an hour
        // and then silently cannot.
        let body = try JSONSerialization.data(withJSONObject: ["access_token": "at"])
        XCTAssertNil(try XCTUnwrap(GoogleOAuthRules.tokens(fromTokenResponse: body)).refreshToken)
    }

    func testRubbishIsNotMistakenForTokens() {
        XCTAssertNil(GoogleOAuthRules.tokens(fromTokenResponse: Data("not json".utf8)))
        XCTAssertNil(GoogleOAuthRules.claims(fromIDToken: "one.two"))
    }

    // MARK: - credentials

    func testTheConsolesDownloadIsReadAsItComes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-client-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: [
            "installed": ["client_id": "abc.apps.googleusercontent.com", "client_secret": "GOCSPX-x"],
        ]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let credentials = try XCTUnwrap(GoogleCredentials.fromJSON(at: url))
        XCTAssertEqual(credentials.clientID, "abc.apps.googleusercontent.com")
        XCTAssertEqual(credentials.clientSecret, "GOCSPX-x")
    }

    func testAWebClientsJsonIsRefusedRatherThanHalfAccepted() throws {
        // A Desktop client's download is keyed "installed". A "web" key means the wrong client type was created, and
        // it would fail much later, at the redirect, with an error about the redirect URI.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-client-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: [
            "web": ["client_id": "abc", "client_secret": "x"],
        ]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(GoogleCredentials.fromJSON(at: url))
    }

    func testAMissingFileIsSimplyNoCredentials() {
        XCTAssertNil(GoogleCredentials.fromJSON(at: URL(fileURLWithPath: "/nowhere/facet.json")))
    }

    // MARK: - which of the three sources answers
    //
    // `resolve` takes its home directory and its bundled pair as arguments precisely so these can run on any
    // machine. Reading the real `~/.config/facet/google-client.json` would make the suite pass or fail on whether
    // whoever ran it happens to have a Google project, which is not a property of the code.

    /// A home with no `google-client.json` in it, so the second source cannot answer.
    private func emptyHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeClientJSON(id: String, secret: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-client-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: [
            "installed": ["client_id": id, "client_secret": secret],
        ]).write(to: url)
        return url
    }

    func testTheEnvironmentOverrideWinsOverEverything() throws {
        let override = try writeClientJSON(id: "from-env", secret: "s1")
        defer { try? FileManager.default.removeItem(at: override) }
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = GoogleCredentials.resolve(
            environment: ["FACET_GOOGLE_CLIENT_JSON": override.path],
            home: home,
            bundled: GoogleCredentials(clientID: "built-in", clientSecret: "s3")
        )
        XCTAssertEqual(found?.clientID, "from-env")
    }

    func testTheHomeDirectoryFileWinsOverWhatWasBuiltIn() throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".config/facet")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "installed": ["client_id": "from-home", "client_secret": "s2"],
        ]).write(to: config.appendingPathComponent("google-client.json"))

        let found = GoogleCredentials.resolve(
            environment: [:],
            home: home,
            bundled: GoogleCredentials(clientID: "built-in", clientSecret: "s3")
        )
        XCTAssertEqual(found?.clientID, "from-home")
    }

    /// The case the whole feature exists for: somebody who is not the developer, so neither override is there.
    func testWhatWasBuiltInAnswersWhenNeitherOverrideIsThere() throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = GoogleCredentials.resolve(
            environment: [:],
            home: home,
            bundled: GoogleCredentials(clientID: "built-in", clientSecret: "s3")
        )
        XCTAssertEqual(found?.clientID, "built-in")
    }

    /// A fork with no Google project. It must be `nil` rather than a half-filled pair, because `nil` is what the App
    /// tab renders as "this copy of Facet was built without Google credentials".
    func testNoSourceAtAllIsNoCredentialsRatherThanEmptyOnes() throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertNil(GoogleCredentials.resolve(environment: [:], home: home, bundled: nil))
    }

    /// An override naming a file that is not there falls through rather than answering nothing at all. Somebody who
    /// mistypes `FACET_GOOGLE_CLIENT_JSON` gets the build's own client, not a dead app.
    func testAnOverridePointingAtNothingFallsThrough() throws {
        let home = try emptyHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = GoogleCredentials.resolve(
            environment: ["FACET_GOOGLE_CLIENT_JSON": "/nowhere/facet.json"],
            home: home,
            bundled: GoogleCredentials(clientID: "built-in", clientSecret: "s3")
        )
        XCTAssertEqual(found?.clientID, "built-in")
    }
}

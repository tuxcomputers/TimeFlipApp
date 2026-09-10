import Foundation
// `URLSession` and its request and response types live in `FoundationNetworking` on the corelibs
// Foundation Linux uses, and in `Foundation` itself on Darwin. A shim rather than a port by the test in
// `CLAUDE.md`: the same code reaching the same Foundation through a different spelling, not a second
// implementation. `GoogleCalendarClient` and `GoogleEventClient` carry the same three lines.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs the sign-in, start to finish.
///
/// **Putting the URL in front of a browser is the one thing here the platform has to do**, and it arrives as
/// `open` rather than being reached for. That single argument is what makes the rest of this file core: the
/// authorization URL, PKCE, the loopback redirect and the token exchange are the same on every platform, and
/// `GoogleLoopbackListener` already carries a Berkeley-sockets half for the ones with no `Network`.
@MainActor
package enum GoogleSignIn {
    /// How long a sign-in is allowed to sit unfinished before the port is given back.
    package static let timeout: Duration = .seconds(300)

    /// Opens the browser, waits for the redirect, and exchanges the code for tokens.
    ///
    /// **Nothing is written here.** This answers with what Google said and leaves storing it to the caller, so the
    /// window keeps its one rule: write, read back, and only then believe it.
    /// - Parameter open: hands the sign-in URL to whatever shows the user a browser. **No default**, which is
    ///   what obliges a caller to supply one: a default would be this module choosing a platform.
    package static func run(
        credentials: GoogleCredentials,
        open: (URL) -> Void,
        session: URLSession = .shared
    ) async throws -> GoogleOAuthRules.Tokens {
        let pkce = GoogleOAuthRules.pkce()
        let state = GoogleOAuthRules.state()
        let listener = try GoogleLoopbackListener(expectedState: state)
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        open(GoogleOAuthRules.authorizationURL(
            clientID: credentials.clientID, redirect: redirectURI, pkce: pkce, state: state
        ))

        let redirect = await withTaskGroup(of: GoogleOAuthRules.Redirect?.self) { group in
            group.addTask { await listener.redirect() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                listener.cancel(with: .ignored)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        switch redirect {
        case let .code(code):
            return try await exchange(
                code: code, verifier: pkce.verifier, redirect: redirectURI,
                credentials: credentials, session: session
            )
        case let .denied(reason):
            throw GoogleOAuthRules.Failure.denied(reason)
        case .ignored, .none:
            throw GoogleOAuthRules.Failure.cancelled
        }
    }

    /// Trades the authorization code for tokens.
    ///
    /// The client secret goes in the body, which is what Google's installed-app flow expects and is not a
    /// confidentiality claim: it ships in the binary. **PKCE is what makes this safe**, and the verifier is the one
    /// value here that never left this process.
    private static func exchange(
        code: String,
        verifier: String,
        redirect: String,
        credentials: GoogleCredentials,
        session: URLSession
    ) async throws -> GoogleOAuthRules.Tokens {
        var request = URLRequest(url: GoogleOAuthRules.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GoogleOAuthRules.Failure.exchangeFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Google puts a machine-readable reason in the body, and it is the only thing that distinguishes "your
            // project is suspended" from "that code was already used".
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw GoogleOAuthRules.Failure.exchangeFailed(reason ?? "the request was refused")
        }
        guard let tokens = GoogleOAuthRules.tokens(fromTokenResponse: data) else {
            throw GoogleOAuthRules.Failure.exchangeFailed("the reply could not be read")
        }
        guard tokens.refreshToken != nil else {
            throw GoogleOAuthRules.Failure.noRefreshToken
        }
        return tokens
    }
}

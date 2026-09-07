// **AppKit for one line, and it is why this file stays on the platform side.** `NSWorkspace.shared.open`
// is the default argument that puts the sign-in URL in front of a browser. Everything else here is
// portable, and the loopback listener that used to live in this file has moved to `FacetCore` -- see
// `GoogleLoopbackListener`, which has a Berkeley-sockets half for platforms with no `Network`.
import AppKit
import FacetCore
import Foundation
// `URLSession` and its request and response types live in `FoundationNetworking` on the corelibs
// Foundation Linux uses, and in `Foundation` itself on Darwin. The module does not exist here, so
// `canImport` is false and this compiles to nothing: the condition is what makes the file portable
// without changing what it does on macOS.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs the sign-in, start to finish.
@MainActor
enum GoogleSignIn {
    /// How long a sign-in is allowed to sit unfinished before the port is given back.
    static let timeout: Duration = .seconds(300)

    /// Opens the browser, waits for the redirect, and exchanges the code for tokens.
    ///
    /// **Nothing is written here.** This answers with what Google said and leaves storing it to the caller, so the
    /// window keeps its one rule: write, read back, and only then believe it.
    static func run(
        credentials: GoogleCredentials,
        open: (URL) -> Void = { NSWorkspace.shared.open($0) },
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

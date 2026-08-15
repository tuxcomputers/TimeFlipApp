import CryptoKit
import Foundation

/// The parts of Google sign-in that are decisions rather than input and output.
///
/// **Everything here is pure, so the flow is testable without a browser, a socket or a Google account.** What is left
/// in `GoogleOAuthClient` is opening a URL, listening on a port and making two HTTPS requests -- the parts that can
/// only be checked against the real thing.
///
/// **Not AppAuth**, which is what the archive used (`Archive/TimeFlipApp/GoogleAuthService.swift`). That library is
/// built around iOS view controllers, and its macOS loopback path is the least-exercised part of it. The flow for an
/// installed app is small enough that owning it is cheaper than depending on it, and this way the parts that matter
/// are ordinary Swift with tests on them rather than calls into a framework.
enum GoogleOAuthRules {
    /// Google's endpoints. Fixed rather than discovered, deliberately: one request saved on every sign-in, and these
    /// two have not moved in the lifetime of OAuth 2.0. If they ever do, the discovery document at
    /// `accounts.google.com/.well-known/openid-configuration` is the thing to read.
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Exactly what the console is configured with. Asking for more than this at runtime gets the request rejected,
    /// and asking for less gets a token that cannot do the job.
    static let scopes = [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/calendar.app.created",
    ]

    /// A PKCE pair: the secret kept in memory and the digest sent out.
    ///
    /// **This is what actually protects the exchange**, given that the client secret ships inside the binary and is
    /// not a secret at all (see `docs/google-oauth-setup.md`). The verifier never leaves this process until the token
    /// request, so an authorization code intercepted on its way back is worthless without it.
    struct PKCE: Equatable {
        let verifier: String
        let challenge: String
    }

    /// A fresh verifier and its S256 challenge.
    ///
    /// 32 random bytes, base64url encoded, which lands at 43 characters: the shortest length RFC 7636 allows, and the
    /// one Google's own samples use. `SystemRandomNumberGenerator` is a CSPRNG.
    static func pkce() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        let verifier = base64URL(Data(bytes))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    /// An opaque value echoed back by Google, so a redirect that did not come from the request this process made can
    /// be told apart from one that did.
    static func state() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return base64URL(Data(bytes))
    }

    /// base64url, per RFC 4648 §5: the URL-safe alphabet with the padding removed.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The URL the browser is sent to.
    ///
    /// `access_type=offline` with `prompt=consent` is what makes Google return a **refresh** token rather than only an
    /// access token good for an hour. Without both, a second sign-in on the same account returns no refresh token at
    /// all, and the app silently loses the ability to sync the moment the first one expires.
    static func authorizationURL(clientID: String, redirect: String, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// What came back on the loopback redirect.
    enum Redirect: Equatable {
        case code(String)
        /// Google said no, or the person pressed Cancel, which arrives as `error=access_denied`.
        case denied(String)
        /// A request that is not the redirect at all: a favicon fetch, a stray probe, a state that does not match.
        case ignored
    }

    /// Reads the redirect out of an HTTP request line, checking the state as it goes.
    ///
    /// **A mismatched state is `ignored` rather than an error**, because that is what it means: some other request
    /// arrived on this port, and the one being waited for has not come yet. Failing the sign-in on it would let
    /// anything that can reach the loopback port cancel somebody's sign-in.
    static func redirect(fromRequestLine line: String, expectedState: String) -> Redirect {
        // "GET /callback?code=...&state=... HTTP/1.1"
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: String(parts[1])) else { return .ignored }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let state = value("state"), state == expectedState else { return .ignored }
        if let error = value("error") { return .denied(error) }
        guard let code = value("code"), !code.isEmpty else { return .ignored }
        return .code(code)
    }

    /// What the browser is left looking at. Plain and final: the flow is over and the app has what it needs.
    static func redirectResponse(_ body: String) -> String {
        let html = """
        <!doctype html><meta charset="utf-8"><title>Facet</title>
        <style>body{font:17px -apple-system,system-ui,sans-serif;margin:4rem auto;max-width:26rem;color:#1c1d21}</style>
        <h1 style="font-size:1.4rem">\(body)</h1>
        <p style="color:#55575e">You can close this tab and go back to Facet.</p>
        """
        return """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
    }

    /// The tokens and the identity, out of the token endpoint's reply.
    struct Tokens: Equatable {
        let accessToken: String
        /// **Absent is a real answer and a bad one.** Google only issues a refresh token when it feels like it, which
        /// is why `access_type=offline` and `prompt=consent` are both on the authorization URL. Without one the app
        /// can sync for an hour and then silently cannot.
        let refreshToken: String?
        let name: String?
        let email: String?
    }

    /// Reads the token response, taking the identity from the `id_token` rather than asking for it.
    ///
    /// **The identity comes free.** With `openid`, `email` and `profile` granted, the ID token already carries the
    /// name and the email, so calling the userinfo endpoint would be a second request for something already in hand,
    /// on every sign-in, against the project's own quota.
    ///
    /// **The ID token is not verified, and that is correct here.** OpenID Connect says a token taken directly from the
    /// token endpoint over TLS needs no signature check, because the channel already establishes who sent it. The
    /// check exists for tokens that arrived by some other route, which this one cannot have.
    static func tokens(fromTokenResponse data: Data) -> Tokens? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String
        else {
            return nil
        }
        let claims = (object["id_token"] as? String).flatMap(claims(fromIDToken:)) ?? [:]
        return Tokens(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            name: claims["name"] as? String,
            email: claims["email"] as? String
        )
    }

    /// The payload of a JWT, which is the middle of three dot-separated base64url segments.
    static func claims(fromIDToken token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url drops the padding; Foundation's decoder insists on it.
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// What went wrong, in words somebody can act on.
    ///
    /// **Named here rather than at each throw site** so the same failure cannot be described two ways, and so the
    /// wording can say whose problem it is. A suspended project and a closed browser tab are both "sign-in failed",
    /// and only one of them is worth trying again.
    enum Failure: LocalizedError, Equatable {
        case noCredentials
        case denied(String)
        case listenerFailed(String)
        case exchangeFailed(String)
        case noRefreshToken
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "This copy of Facet has no Google credentials built into it, so it cannot sign in."
            case let .denied(reason) where reason == "access_denied":
                return "Sign-in was cancelled at the Google page."
            case let .denied(reason):
                return "Google refused the sign-in: \(reason)."
            case let .listenerFailed(reason):
                return "Facet could not open a local port to receive the sign-in: \(reason)."
            case let .exchangeFailed(reason):
                return "Google would not complete the sign-in: \(reason)."
            case .noRefreshToken:
                return "Google did not return a refresh token, so the connection would stop working within the hour. "
                    + "Removing Facet at myaccount.google.com/permissions and signing in again usually fixes it."
            case .cancelled:
                return "Sign-in was cancelled."
            }
        }
    }
}

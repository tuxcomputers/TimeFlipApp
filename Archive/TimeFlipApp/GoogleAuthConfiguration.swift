import Foundation

struct GoogleAuthConfiguration: Sendable, Equatable {
    private static let requiredScopes: Set<String> = [
        // Calendar: read the user's existing calendars, and read/write events on them.
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.readonly",
        // Create (and fully manage) a dedicated secondary calendar for TimeFlip. app.created is the
        // least-privilege calendar-creation scope: it only grants access to calendars this app
        // itself creates, never the user's other calendars.
        "https://www.googleapis.com/auth/calendar.app.created",
        // Identity: the signed-in account's email and name (via an OpenID Connect ID token).
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile"
    ]

    static let defaultScopes = Array(requiredScopes).sorted()
    static let defaultIssuer: URL = {
        guard let url = URL(string: "https://accounts.google.com") else {
            preconditionFailure("Invalid default issuer URL")
        }
        return url
    }()

    let clientID: String
    let clientSecret: String?
    let scopes: [String]
    let issuer: URL

    init(
        clientID: String,
        clientSecret: String?,
        scopes: [String] = GoogleAuthConfiguration.defaultScopes,
        issuer: URL = GoogleAuthConfiguration.defaultIssuer
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.issuer = issuer
    }

    static func loadFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GoogleAuthConfiguration {
        guard let clientID = env["GOOGLE_OAUTH_CLIENT_ID"], !clientID.isEmpty else {
            throw GoogleAuthError.missingEnvironmentVariable("GOOGLE_OAUTH_CLIENT_ID")
        }

        let clientSecret = Self.optionalValue(from: env["GOOGLE_OAUTH_CLIENT_SECRET"])
        let scopes = Self.scopes(from: env["GOOGLE_OAUTH_SCOPES"])
        let issuerString = env["GOOGLE_OAUTH_ISSUER"] ?? GoogleAuthConfiguration.defaultIssuer.absoluteString
        guard let issuer = URL(string: issuerString) else {
            throw GoogleAuthError.invalidIssuer(issuerString)
        }

        return GoogleAuthConfiguration(
            clientID: clientID,
            clientSecret: clientSecret,
            scopes: scopes,
            issuer: issuer
        )
    }

    private static func scopes(from raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else {
            return defaultScopes
        }
        let tokens = raw
            .split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
            .map { String($0) }
        let provided = Set(tokens)
        let merged = requiredScopes.union(provided)
        return merged.isEmpty ? defaultScopes : Array(merged).sorted()
    }

    private static func optionalValue(from raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
    }

}

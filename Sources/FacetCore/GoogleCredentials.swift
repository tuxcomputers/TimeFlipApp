import Foundation

/// The OAuth client this build signs in as.
///
/// **Resolved at the moment it is needed, not held from launch.** Three places are tried, override first, which is
/// `docs/google-oauth-setup.md` Part 2 step 2: it lets a developer point at a second project without a release build,
/// and gives somebody a way out if the bundled project is ever suspended.
struct GoogleCredentials: Equatable {
    let clientID: String
    let clientSecret: String

    /// `FACET_GOOGLE_CLIENT_JSON`, then `~/.config/facet/google-client.json`, then what was built in.
    ///
    /// **The first two are a file on one machine; only the third travels with the binary.** They are the console's
    /// own download, unedited, so there is nothing to transcribe, and they are what a developer resolves through --
    /// which is exactly why they cannot be the whole answer: a `.app` handed to somebody else finds neither.
    ///
    /// The third is `scripts/generate-credentials.sh`'s doing. It copies the same download to
    /// `Resources/google-client.json`, gitignored, so neither value is committed. **Absent, this is simply `nil`**,
    /// which is what lets a fresh clone build and run with no credentials and no generator run -- the app works,
    /// and the App tab says in words that this copy cannot sign in.
    ///
    /// Overrides ahead of it rather than behind it, deliberately: it lets a developer point at a second project
    /// without a release build, and gives somebody a way out if the bundled project is ever suspended.
    ///
    /// **It used to read two `Info.plist` keys here**, which no build step ever wrote, so the third source was dead
    /// and a distributed build could not sign in at all.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundled: GoogleCredentials? = .builtIn
    ) -> GoogleCredentials? {
        if let path = environment["FACET_GOOGLE_CLIENT_JSON"],
           let found = fromJSON(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) {
            return found
        }
        if let found = fromJSON(at: home.appendingPathComponent(".config/facet/google-client.json")) {
            return found
        }
        return bundled
    }

    /// What the generator built in, or `nil` when it had nothing to build in.
    ///
    /// **Read through `fromJSON`, the same reader the two overrides use**, because it is the same file: the
    /// generator copies the console's download verbatim rather than rewriting it, so there is one format and one
    /// parser rather than two that can drift.
    ///
    /// `Bundle.main` then `Bundle.module`, which is `DatabaseBootstrap.bundledDDLDirectory`'s order and for its
    /// reason: the first finds it inside a built `.app`, the second under `swift run` and `swift test`.
    ///
    /// A default argument on `resolve` rather than a read inside it, so a test can pass its own and never depend on
    /// whether the machine running the suite happens to have credentials sitting in its build directory.
    static var builtIn: GoogleCredentials? {
        guard
            let url = Bundle.main.url(forResource: "google-client", withExtension: "json")
                ?? Bundle.module.url(forResource: "google-client", withExtension: "json")
        else {
            return nil
        }
        return fromJSON(at: url)
    }

    /// Reads the console's download. Its top-level key is `installed` for a Desktop client, which is the type this app
    /// uses; a `web` key would mean the wrong one was made, and is treated as no credentials at all rather than being
    /// half-accepted.
    static func fromJSON(at url: URL) -> GoogleCredentials? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let installed = object["installed"] as? [String: Any],
            let id = installed["client_id"] as? String,
            let secret = installed["client_secret"] as? String
        else {
            return nil
        }
        return GoogleCredentials(clientID: id, clientSecret: secret)
    }
}

import Foundation

/// Connecting a Google account, and disconnecting it: the sequence, not the browser and not the section.
///
/// **Core because both platforms sign in.** Every step below was a decision inside `SettingsWindowController` --
/// which order the token and the rows are written in, what counts as having failed, what is kept on the way out --
/// and none of it is a question about AppKit or GTK. What a platform still owns is one line: handing a URL to a
/// browser.
///
/// **The orderings are the point, and there are three.**
///
/// 1. **Nowhere to keep a token is refused before the browser opens**, not after somebody has authorised in it.
///    Asking a person to consent and then telling them it could not be saved is the worst order available.
/// 2. **The token is saved before the identity is written.** A row naming an account the app cannot act on is worse
///    than no row: the section would say Connected over a Keychain with nothing in it, which is the two-answers
///    fault the first design rule exists to prevent.
/// 3. **What is shown comes from reading the rows back**, never from what Google said. Google's answer is what was
///    written; the table is what the app now holds, and those are different claims.
///
/// **Disconnecting keeps the calendar id deliberately.** Signing out and back in on the same account is the common
/// case, and forgetting the id would make a second *Facet* calendar beside the first with the history split across
/// the two. The id is checked on the way back in rather than trusted, so a sign-in by somebody else finds it does
/// not resolve and is asked about -- the same conversation as a calendar that was deleted.
@MainActor
package final class GoogleConnection {
    private let settings: SettingStore
    private let tokens: GoogleTokenStore
    private let debugLog: DebugLog?

    package init(settings: SettingStore, tokens: GoogleTokenStore, debugLog: DebugLog?) {
        self.settings = settings
        self.tokens = tokens
        self.debugLog = debugLog
    }

    /// What a sign-in came to.
    package enum SignIn: Equatable {
        /// Connected, and this is what the table now says -- read back, not what Google answered with.
        ///
        /// `accessToken` rides along because the caller usually wants it next, to settle a calendar without
        /// paying for a refresh it does not need.
        case connected(GoogleAccountRules.Account, accessToken: String)
        /// It did not happen, and this is what to tell somebody. **A `Dialogue` rather than an error**, so the two
        /// platforms cannot word the same failure differently.
        case failed(Dialogue)
    }

    /// Runs a sign-in and records it.
    ///
    /// - Parameter open: hands the sign-in URL to a browser. **No default**, which is what obliges a caller to
    ///   supply one -- `NSWorkspace` on a Mac, `xdg-open` here -- and is the same rule `GoogleSignIn.run` states.
    /// - Parameter listening: makes the loopback listener the redirect arrives on, which is the platform's port
    ///   (`GoogleRedirectListener`).
    package func signIn(
        open: @escaping (URL) -> Void,
        listening: @escaping (String) throws -> GoogleRedirectListener
    ) async -> SignIn {
        guard let credentials = GoogleCredentials.resolve() else {
            debugLog?.record(.field, "Google sign-in refused, this build has no OAuth client in it")
            return .failed(Self.notice(GoogleOAuthRules.Failure.noCredentials))
        }
        // **Before the browser opens.** See the second ordering above.
        // `unavailable` carries the store's own status code, so this asks which case it is rather than comparing
        // against a value -- and `missing` is fine here: a sign-in is how a store with nothing in it gets something.
        if case .unavailable = tokens.lookUp() {
            debugLog?.record(.field, "Google sign-in refused, there is nowhere to keep the token")
            return .failed(Self.notice(
                GoogleOAuthRules.Failure.exchangeFailed("there is nowhere to keep the token")
            ))
        }
        debugLog?.record(.field, "Google sign-in started")
        do {
            let answer = try await GoogleSignIn.run(
                credentials: credentials,
                open: open,
                listening: listening
            )
            guard let refresh = answer.refreshToken, tokens.save(refreshToken: refresh) else {
                throw GoogleOAuthRules.Failure.exchangeFailed("the token could not be saved")
            }
            let wroteName = settings.write(
                GoogleAccountRules.setting, field: GoogleAccountRules.nameField, answer.name ?? ""
            )
            let wroteEmail = settings.write(
                GoogleAccountRules.setting, field: GoogleAccountRules.emailField, answer.email ?? ""
            )
            guard wroteName, wroteEmail else {
                throw GoogleOAuthRules.Failure.exchangeFailed("the database would not record the account")
            }
            let account = stored()
            debugLog?.record(.field, "Google sign-in finished, account \(account.email ?? "unnamed")")
            return .connected(account, accessToken: answer.accessToken)
        } catch {
            debugLog?.record(.field, "Google sign-in failed: \(error.localizedDescription)")
            return .failed(Self.notice(error))
        }
    }

    /// Gives the account up.
    ///
    /// - Returns: `nil` when it went, or what to tell somebody when the table would not let go of the identity.
    @discardableResult
    package func disconnect() -> Dialogue? {
        let clearedName = settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.nameField, "")
        let clearedEmail = settings.write(GoogleAccountRules.setting, field: GoogleAccountRules.emailField, "")
        let stored = clearedName && clearedEmail
        debugLog?.record(
            .field,
            "Google account disconnected\(stored ? "" : " REFUSED, the table still holds an identity")"
        )
        guard stored else {
            return Dialogue(
                title: AppSettingsRules.title(for: .googleDisconnected),
                message: "Facet could not store that. The row is back to what it was."
            )
        }
        // **The token goes with the identity.** Leaving it behind would mean a secret store still holding the
        // ability to act on an account the app says it is not connected to.
        _ = tokens.clear()
        return nil
    }

    /// Who the table says is connected, read now.
    package func stored() -> GoogleAccountRules.Account {
        GoogleAccountRules.account(
            name: settings.string(GoogleAccountRules.setting, field: GoogleAccountRules.nameField),
            email: settings.string(GoogleAccountRules.setting, field: GoogleAccountRules.emailField)
        )
    }

    /// Whether there is a token behind the identity, which the row cannot say.
    ///
    /// **Read in the same pass as the identity wherever both are wanted**: one without the other is the
    /// half-answer that let a section say Connected with nothing behind it.
    package func credential() -> GoogleAccountRules.Credential {
        switch tokens.lookUp() {
        case .found: return .present
        case .missing: return .missing
        case .unavailable: return .unavailable
        }
    }

    /// What to say about a failure. **One wording for both platforms**, which is the whole reason a `Dialogue`
    /// crosses this boundary rather than an `Error`.
    private static func notice(_ error: any Error) -> Dialogue {
        // **The Mac's own title and message**, kept word for word: `showGoogleFailed` said exactly this, and a
        // failure reworded on the way into the core would be a sentence somebody has already read differently.
        Dialogue(
            title: "Facet could not connect to Google",
            message: error.localizedDescription
        )
    }
}

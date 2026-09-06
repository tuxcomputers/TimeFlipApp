import Foundation

/// What the App tab's Google section says, given what the `google_account` row holds.
///
/// **Kept out of the pane so the questions are answerable without a window.** Whether an account counts as connected
/// is a rule about the data, not a property of a label, and the pane is where it would otherwise be decided by the
/// order two `if`s happen to run in.
///
/// **The archive asked for more than this and is deliberately not copied** (`ReportSettingsView.swift`):
///
/// - Its **Client ID and Client Secret fields are gone**. Those existed because every user had to make their own
///   Google Cloud project and paste the results in. The project is now ours and the credentials ship with the build,
///   which is the whole point of `docs/google-oauth-setup.md`, so a field asking for them would be asking a question
///   the app already knows the answer to.
/// - Its **calendar picker is gone**, and that one is not a simplification but a consequence. Listing somebody's
///   calendars needs `calendar.readonly`, and writing to one they already own needs `calendar.events`. Both are
///   *sensitive* scopes, and dropping them is what keeps this app out of Google's verification process entirely.
///   Facet makes its own calendar under `calendar.app.created` instead, so there is nothing to choose.
///
/// What survives is the part that was always the section's job: saying which account is connected.
enum GoogleAccountRules {
    /// The `setting` row this section reads, and the two fields of it that hold the identity.
    ///
    /// The row carries `calendar_id`, `calendar_name` and `client_id` as well, which this section does not touch.
    /// `database/011_setting.sql` is explicit that **only the identity is cleared on sign-out**, so that a later
    /// sign-in with a different account re-fetches, while the configuration beside it survives.
    static let setting = "google_account"
    static let nameField = "name"
    static let emailField = "email"

    /// The identity the `google_account` row carries, which is **half** of a connection.
    ///
    /// Both fields are optional and independently so: the row starts as `{}`, and the userinfo endpoint can return a
    /// profile with no name on it. So an identity exists if *either* is there, not if both are.
    struct Account: Equatable {
        var name: String?
        var email: String?

        /// **Whether the row names somebody, and nothing more than that.**
        ///
        /// This used to be called `isCubeConnected` and was the whole of the answer, which is the fault the rest of this
        /// file exists to correct: the identity is in the database and the token that makes it usable is in the
        /// Keychain, so a row can name an account perfectly while the app has no way to act as it. Measured on
        /// 2026-08-26: a complete row, an App tab reading Connected, and no Keychain item at all.
        var hasGoogleIdentity: Bool {
            name != nil || email != nil
        }

        static let none = Account(name: nil, email: nil)
    }

    /// Reads an account out of what the table gave back, treating blank as absent.
    ///
    /// **A field of spaces is not a name.** Sign-out writes empty strings rather than deleting the keys, so an empty
    /// string has to mean the same as a missing key or signing out would leave the section claiming a connection to
    /// an account called "".
    static func account(name: String?, email: String?) -> Account {
        Account(name: trimmedOrNil(name), email: trimmedOrNil(email))
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The other half: whether the Keychain holds a token for the account the row names.
    ///
    /// A straight mirror of `GoogleTokenStore.Lookup`, kept as its own type so this file can be reasoned about, and
    /// tested, without a Keychain anywhere near it.
    enum Credential: Equatable {
        case present
        case missing
        /// The Keychain would not answer. **Nothing is known**, which is not the same as knowing there is nothing.
        case unavailable
    }

    /// What Google said, the last time it was asked.
    ///
    /// **Never stored, deliberately.** Whether a refresh token still works is a fact held at Google, not here: it can
    /// be revoked at myaccount.google.com, expire through disuse, or die with a password change, and the stored bytes
    /// read identically in every case. So this is the answer to a question asked at the point of use, and it goes
    /// stale the moment it is given, which is why it is a parameter rather than a field on anything.
    enum Verification: Equatable {
        /// Nobody has asked yet. The ordinary state for the instant a window opens.
        case notAsked
        case working
        /// Google was asked and refused the token.
        case refused(String)
        /// Google could not be asked. **Being offline is not being signed out**, and treating it as such would push
        /// somebody through a browser consent to fix a problem they do not have.
        case unreachable(String)
    }

    /// What the section actually is, from both halves plus whatever Google last said.
    ///
    /// **One value, computed, rather than a pile of booleans read in whatever order two `if`s happen to run in.**
    /// Every string, every button and the calendar row all come from this, so they cannot disagree with each other.
    enum State: Equatable {
        /// Nothing stored. Never signed in, or signed out cleanly.
        case notConnected
        /// The row names an account and there is no token for it. A fresh sign-in is the whole of the fix.
        case signedOut
        /// Both halves present, and Google has not been asked. Strictly more than the old code knew, which is why it
        /// still reads as connected: the token really is there.
        case unverified
        /// Both halves present and Google confirmed the token works. The only state that has been proved.
        case connected
        /// Google refused the token. Signing in again is the fix; nothing local will help.
        case expired
        /// Both halves present, Google unreachable. Connected as far as anything here knows.
        case unreachable
        /// The row names an account and the Keychain would not say whether there is a token. Nothing is known, and
        /// in particular the user has *not* been told to sign in again.
        case unreadable
    }

    /// The one place the state is decided.
    static func state(
        for account: Account,
        credential: Credential,
        verification: Verification = .notAsked
    ) -> State {
        guard account.hasGoogleIdentity else { return .notConnected }
        switch credential {
        case .missing: return .signedOut
        case .unavailable: return .unreadable
        case .present:
            switch verification {
            case .notAsked: return .unverified
            case .working: return .connected
            case .refused: return .expired
            case .unreachable: return .unreachable
            }
        }
    }

    /// The Status row's value.
    ///
    /// The archive's two words survive for the two states they were true of. The rest say what is actually the case,
    /// because "Not connected" in front of somebody whose Keychain merely would not answer is a false statement with
    /// an expensive remedy attached.
    static func status(for googleAccountState: State) -> String {
        switch googleAccountState {
        case .notConnected: return "Not connected"
        case .signedOut: return "Signed out"
        case .unverified, .connected: return "Connected"
        case .expired: return "Sign-in expired"
        case .unreachable: return "Connected, not checked"
        case .unreadable: return "Cannot be checked"
        }
    }

    /// What pressing the button will do. Named rather than inferred, so the pane does not have to re-derive it from
    /// the title it is about to draw.
    enum Action: Equatable {
        case signIn
        case disconnect
    }

    static func action(for googleAccountState: State) -> Action {
        switch googleAccountState {
        case .notConnected, .signedOut, .expired: return .signIn
        case .unverified, .connected, .unreachable, .unreadable: return .disconnect
        }
    }

    /// What the button offers. One button, whose meaning flips with the googleAccountState, rather than two with one always
    /// disabled.
    static func buttonTitle(for googleAccountState: State, isSigningIn: Bool = false) -> String {
        if isSigningIn { return "Signing in..." }
        return action(for: googleAccountState) == .disconnect ? "Disconnect" : "Sign in with Google"
    }

    /// Whether the button can be pressed.
    ///
    /// **Off while a sign-in is running**, so a second browser window cannot be opened on top of the first, and off
    /// when this build has no credentials in it, which is a real googleAccountState: the client id and secret are injected at build
    /// time and a copy built without them cannot sign in at all. Disconnecting needs neither.
    static func isButtonEnabled(for googleAccountState: State, hasGoogleCredentials: Bool, isSigningIn: Bool = false) -> Bool {
        if isSigningIn { return false }
        return action(for: googleAccountState) == .disconnect || hasGoogleCredentials
    }

    /// Whether the calendar row belongs on screen.
    ///
    /// **Only where a calendar request could actually succeed.** Offering Create or Delete in a googleAccountState where every
    /// request is going to be refused is a button that can only fail, which is the same reason the row has always
    /// been withheld until there is an account to make one in.
    static func showsCalendar(for googleAccountState: State) -> Bool {
        switch googleAccountState {
        case .unverified, .connected, .unreachable: return true
        case .notConnected, .signedOut, .expired, .unreadable: return false
        }
    }

    /// The line under the button, or `nil` when the button speaks for itself.
    ///
    /// Says what pressing it will do, or what went wrong and whose problem it is. **Every googleAccountState that needs an action
    /// says which**, and the two that need none say nothing.
    static func note(for googleAccountState: State, hasGoogleCredentials: Bool, verification: Verification = .notAsked) -> String? {
        switch googleAccountState {
        case .connected, .unverified:
            return nil
        case .notConnected, .signedOut:
            guard hasGoogleCredentials else { return Self.noCredentialsNote }
            if googleAccountState == .signedOut {
                return "The account is remembered but its sign-in is not. Signing in again restores it."
            }
            return Self.signInNote
        case .expired:
            guard hasGoogleCredentials else { return Self.noCredentialsNote }
            if case let .refused(reason) = verification, !reason.isEmpty {
                return "Google would not accept the saved sign-in (\(reason)). Signing in again restores it."
            }
            return "Google would not accept the saved sign-in. Signing in again restores it."
        case .unreachable:
            if case let .unreachable(reason) = verification, !reason.isEmpty {
                return "Facet could not reach Google to check this (\(reason)), so it is showing what it has."
            }
            return "Facet could not reach Google to check this, so it is showing what it has."
        case .unreadable:
            return "Facet could not read its sign-in from your Keychain, so it cannot say whether this works."
        }
    }

    private static let noCredentialsNote =
        "This copy of Facet was built without Google credentials, so it cannot sign in."
    private static let signInNote =
        "Opens your browser to approve. Facet only ever touches a calendar it makes itself, and never the "
            + "ones you already have."
}

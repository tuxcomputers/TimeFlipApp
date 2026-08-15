import Foundation

/// What the App tab's Google section says, given what the `google_account` row holds.
///
/// **Kept out of the pane so the questions are answerable without a window.** Whether an account counts as connected
/// is a rule about the data, not a property of a label, and the pane is where it would otherwise be decided by the
/// order two `if`s happen to run in.
///
/// **The archive asked for more than this and is deliberately not copied** (`Archive/TimeFlipApp/ReportSettingsView.swift`):
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

    /// The connected account, as far as the table knows.
    ///
    /// Both fields are optional and independently so: the row starts as `{}`, and the userinfo endpoint can return a
    /// profile with no name on it. Connection is therefore decided by having *either*, not by having both.
    struct Account: Equatable {
        var name: String?
        var email: String?

        /// **Nothing at all means nothing to show.** An account with neither a name nor an email is indistinguishable
        /// from never having signed in, so it is reported as not connected rather than as a connection with empty
        /// labels under it.
        var isConnected: Bool {
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

    /// The Status row's value. The archive's two words, kept: they are what somebody is scanning the section for.
    static func status(for account: Account) -> String {
        account.isConnected ? "Connected" : "Not connected"
    }

    /// What the button offers. One button, whose meaning flips with the state, rather than two with one always
    /// disabled.
    static func buttonTitle(for account: Account) -> String {
        account.isConnected ? "Disconnect" : "Sign in with Google"
    }

    /// Whether the button can be pressed.
    ///
    /// **Disconnecting works today; signing in does not.** Clearing a row is something this app can do on its own,
    /// where signing in needs the OAuth flow that has not been rebuilt yet (`docs/google-oauth-setup.md`, Part 2).
    /// The archive disabled this same button for its own reason, with the reason written beside it, which is the
    /// shape being kept: a button that is off and says why beats one that is on and does nothing.
    static func isButtonEnabled(for account: Account) -> Bool {
        account.isConnected
    }

    /// The line under a disabled button, or `nil` when there is nothing to explain.
    ///
    /// It says what is missing rather than apologising, and names the thing that will change, so the section is
    /// honest about being unfinished instead of looking broken.
    static func note(for account: Account) -> String? {
        account.isConnected ? nil : "Signing in is not built yet. When it is, this connects one Google account and "
            + "Facet syncs your time into a calendar it makes itself."
    }
}

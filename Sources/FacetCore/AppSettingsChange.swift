import Foundation

/// One row's new value, named for the row rather than for the setting it lands in: which row this came from is
/// what the pane knows, and which column that maps to is `AppSettingsRules`' to say.
///
/// Each number is in the unit the *row* shows -- a 12-hour face, whole minutes -- rather than the unit the table
/// stores, for the same reason: converting is a rule, and doing it here would be a second place it happens.
package enum AppSettingsChange: Equatable {
    case showsSeconds(Bool)
    case dailyResetHour12(Int)
    case fetchIntervalMinutes(Int)
    case blipSeconds(Int)
    /// Sign out: clear the connected identity. Carries no value because it is not a row being set to something,
    /// it is a row being emptied, and "emptied" has only one meaning.
    case googleDisconnected
    /// Sign in. **A request with no value at all**: what the account turns out to be is Google's to say, and comes
    /// back as `googleConnected`.
    case googleSignInRequested
    /// The identity the table now holds, after a sign-in was written and read back.
    case googleConnected(GoogleAccountRules.Account)
    /// A new name for the calendar, typed and committed. **A request**: it is a rename at Google, not a label.
    case googleCalendarNamed(String)
    /// Make the calendar. **The only thing that makes one**: connecting an account does not, so this is the
    /// usual path rather than a recovery, and it stays available for as long as there is no calendar.
    case googleCalendarCreateRequested
    /// Delete the calendar, at Google. **The one request here that destroys something**, so the window confirms it
    /// before carrying it out. Carries no value: there is one calendar and only one thing to do to it.
    case googleCalendarDeleteRequested
    /// The calendar the table now holds, after Google answered and the write was read back.
    case googleCalendarChanged(GoogleCalendarRules.Calendar)
    /// What the Keychain now says. **Not a request and not a setting**: nobody edits this in the window, it is
    /// the other half of a fact the row only tells half of.
    case googleCredentialChanged(GoogleAccountRules.Credential)
    /// What Google said when asked whether the token still works. Arrives once per ask and is never stored,
    /// because it is true of a moment rather than of the account.
    case googleVerified(GoogleAccountRules.Verification)
    /// Whether the trace is gathered at all.
    case debugEnabled(Bool)
    /// Pick the folder the trace is kept in. **A request**: choosing one is a panel the window runs, this pane
    /// having no business putting anything modal on screen.
    case debugDirectoryRequested
    /// The folder that was picked, in the form the setting stores.
    case debugDirectory(String)
    /// Show the trace in the Finder. **A request**, and one that stores nothing: it opens somebody else's window.
    case debugRevealRequested
    /// Save a copy of the trace somewhere, to send in. **A request** for the same reason the folder is.
    case debugCopyRequested
    /// Empty the trace. **A request, and the destructive one**: the window confirms it before carrying it out.
    case debugClearRequested
}

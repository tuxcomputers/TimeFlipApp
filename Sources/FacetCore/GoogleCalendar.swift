import Foundation

/// The calendar Facet owns in somebody's Google account: settling it, making one, renaming it, deleting it.
///
/// **The companion to `GoogleConnection`, and a second subject rather than more of the first.** An account is who
/// is signed in; a calendar is a thing in that account that this app writes to, and the two have different
/// lifetimes -- signing out keeps the calendar id deliberately, so the same person signing back in keeps their
/// history rather than starting a second *Facet* beside the first.
///
/// **Every one of these was a method on `SettingsWindowController`**, so none of them had a test and none of them
/// could run on this platform. What is here is the sequence and the wording; what a surface still owns is a row
/// and a button.
///
/// **Google is asked first and the row follows, everywhere.** The calendar lives in the user's account, so what is
/// there is the real answer and a row updated first would be this app claiming something that may not have
/// happened. That ordering is the same one the cube's settings follow for the same reason.
@MainActor
package final class GoogleCalendar {
    private let settings: SettingStore
    private let tokens: GoogleTokenStore
    private let dialogues: DialoguePresenter
    private let debugLog: DebugLog?

    package init(
        settings: SettingStore,
        tokens: GoogleTokenStore,
        dialogues: DialoguePresenter,
        debugLog: DebugLog?
    ) {
        self.settings = settings
        self.tokens = tokens
        self.dialogues = dialogues
        self.debugLog = debugLog
    }

    /// What the calendar is now, or what to say about why it is not known.
    package enum Settled: Equatable {
        /// There is one, and this is what the table holds for it -- read back rather than what Google answered.
        case calendar(GoogleCalendarRules.Calendar)
        /// There is none, and that is a state rather than a failure: the row becomes a Create button.
        case none
        /// Something went wrong, and this is what to tell somebody.
        case failed(Dialogue)
    }

    /// What asking Google about the saved sign-in came back with.
    ///
    /// **`<name>State` because it has five answers**, which is `docs/state-reference.md`'s convention, and it is
    /// registered there as `googleSignInState`. It is not `GoogleAccountRules.Verification`: that one is what the
    /// *account* is, worked out from this plus whether there is a token at all.
    ///
    /// **Offline is not signed out**, which is the distinction the whole thing turns on: a `URLError` means the
    /// question could not be put, and answering it as "you are signed out" would push somebody through a browser
    /// consent to fix a connection that was never broken.
    package enum SignInState: Equatable {
        case working
        /// Nothing stored to check. The store answered, and it has nothing.
        case notSignedIn
        /// The store would not answer, which is not the same as having nothing.
        case storeUnavailable(Int32)
        case unreachable(String)
        case refused(String)
    }

    /// Asks Google whether the saved sign-in still works.
    ///
    /// **This is the device rule applied to Google.** `CLAUDE.md` says a command the cube can be asked about is read
    /// back before it is believed, because an in-memory copy of what was last sent is a second answer that can
    /// disagree. A refresh token is the same shape and freer to disagree: it can be revoked, expire through disuse,
    /// or die with a password change, and the bytes read identically in every one of those cases.
    ///
    /// **Nothing is stored.** The answer is true of the moment it was given, so it lives in the surface until the
    /// window closes and is asked again next time. Writing it to a row would recreate exactly the stale-copy fault
    /// this is about.
    package func check() async -> SignInState {
        do {
            _ = try await GoogleCalendarClient.currentAccessToken(tokens: tokens)
            debugLog?.record(.field, "Google sign-in checked and works")
            return .working
        } catch GoogleCalendarRules.Failure.notSignedIn {
            debugLog?.record(.field, "Google sign-in checked: there is no saved sign-in")
            return .notSignedIn
        } catch let GoogleCalendarRules.Failure.keychainUnavailable(status) {
            debugLog?.record(.field, "Google sign-in checked: the secret store would not answer, error \(status)")
            return .storeUnavailable(status)
        } catch let error as URLError {
            debugLog?.record(.field, "Google sign-in could not be checked: \(error.localizedDescription)")
            return .unreachable(error.localizedDescription)
        } catch {
            debugLog?.record(.field, "Google sign-in checked and refused: \(error.localizedDescription)")
            return .refused(error.localizedDescription)
        }
    }

    /// Works out which calendar this account should use, now that somebody has signed in.
    ///
    /// **The stored id is checked, not trusted.** It survives a sign-out on purpose, so the usual case -- the same
    /// person signing back in -- keeps the calendar and its history. But the same stored id is what a *different*
    /// person meets, and what somebody who deleted the calendar at Google meets, and from here those two are
    /// indistinguishable. So the question asked is the same one and its wording names both possibilities rather
    /// than guessing.
    ///
    /// **No stored id means no calendar, and nothing is made.** Signing in connects an account; it is not somebody
    /// asking for a calendar in it. Nothing is lost by waiting: entries recorded meanwhile stay unsynced, and
    /// creating the calendar sweeps every one of them into it, oldest first.
    package func settle(accessToken: String) async -> Settled {
        let storedID = settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField)
        let id: String
        switch GoogleCalendarRules.settlement(forStoredID: storedID) {
        case .leaveToTheUser:
            debugLog?.record(.field, "Google account connected with no calendar, none made")
            return .none
        case let .check(storedCalendarID):
            id = storedCalendarID
        }
        do {
            // Proves it exists and brings back its current name in the same request, so a rename made at Google is
            // adopted here without anything ever polling for it.
            let found = try await GoogleCalendarClient.get(id: id, accessToken: accessToken)
            _ = settings.write(
                GoogleAccountRules.setting,
                field: GoogleCalendarRules.nameField,
                found.name ?? GoogleCalendarRules.defaultName
            )
            let stored = self.stored(id: id)
            debugLog?.record(.field, "Google calendar confirmed, \(stored.name ?? "unnamed")")
            return .calendar(stored)
        } catch is CalendarGone {
            return await forgetAndOffer(accessToken: accessToken)
        } catch {
            // Something else went wrong. The calendar is not known to be gone, so nothing is forgotten and nothing
            // is made: the id stays, and the next attempt can settle it.
            debugLog?.record(.field, "Google calendar could not be checked: \(error.localizedDescription)")
            return .failed(Self.notice(error))
        }
    }

    /// Makes the calendar and records it.
    ///
    /// **The id is written before the name**, and the calendar is only treated as existing once the id reads back:
    /// a name stored against no id would be a label for something that cannot be written to.
    ///
    /// **It creates rather than looking first.** Asking `calendarList.list` whether the account already has a Facet
    /// calendar does not work under `calendar.app.created` -- measured 2026-08-15, where a reconnect with the id
    /// blanked logged "created" against a known-good calendar and produced a duplicate. Reaching here means the app
    /// has no calendar, and it makes one.
    package func create(named name: String = GoogleCalendarRules.defaultName) async -> Settled {
        do {
            let token = try await accessToken()
            return await make(named: name, accessToken: token)
        } catch {
            return .failed(Self.notice(error))
        }
    }

    private func make(named name: String, accessToken: String) async -> Settled {
        do {
            let made = try await GoogleCalendarClient.create(name: name, accessToken: accessToken)
            guard let id = made.id,
                  settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, id),
                  settings.write(
                      GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, made.name ?? name
                  )
            else {
                throw GoogleCalendarRules.Failure.createFailed("the database would not record it")
            }
            let stored = self.stored(id: id)
            debugLog?.record(.field, "Google calendar created, \(stored.name ?? "unnamed")")
            return .calendar(stored)
        } catch {
            debugLog?.record(.field, "Google calendar creation failed: \(error.localizedDescription)")
            return .failed(Self.notice(error))
        }
    }

    /// Renames it at Google, then records what it ended up being called.
    package func rename(to typed: String) async -> Settled {
        guard let id = settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField),
              !id.isEmpty
        else {
            return .none
        }
        let name = GoogleCalendarRules.name(fromTyped: typed)
        do {
            let token = try await accessToken()
            let renamed = try await GoogleCalendarClient.rename(id: id, to: name, accessToken: token)
            guard settings.write(
                GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, renamed.name ?? name
            ) else {
                throw GoogleCalendarRules.Failure.renameFailed("the database would not record it")
            }
            let stored = self.stored(id: id)
            debugLog?.record(.field, "Google calendar renamed to \(stored.name ?? "unnamed")")
            return .calendar(stored)
        } catch is CalendarGone {
            // Deleted at Google while Facet was connected. The same situation a sign-in meets, so the same
            // question rather than a second way of saying it.
            let token = try? await accessToken()
            return await forgetAndOffer(accessToken: token ?? "")
        } catch {
            debugLog?.record(.field, "Google calendar rename failed: \(error.localizedDescription)")
            // The field is showing what somebody typed, so the surface puts the row back to what is stored.
            return .failed(Self.notice(error))
        }
    }

    /// Asks whether to delete the calendar, and does it.
    ///
    /// **The only thing this app destroys, so the only one that asks first.** Everything else can be undone by doing
    /// it again -- a name renamed back, a sign-out signed back into. This takes the calendar and every event Facet
    /// has written to it out of an account Facet does not own, and Google keeps nothing to go back to.
    ///
    /// **The recorded time itself is untouched**, and the question says so: every `time_entry` stays where it is,
    /// and what is lost is the copy of it in the calendar. That distinction is the whole of what somebody needs to
    /// decide.
    package func delete(then settled: @escaping @MainActor (Settled) -> Void) {
        let calendar = stored()
        guard let id = calendar.id else { return settled(.none) }
        let name = calendar.name ?? GoogleCalendarRules.defaultName
        dialogues.ask(
            Dialogue(
                title: "Delete the \"\(name)\" calendar?",
                message: """
                This deletes the calendar from your Google account, along with every event Facet has written to \
                it. It cannot be undone from here.

                Your recorded time is not affected: it stays in Facet, and a new calendar can be made and filled \
                from it.
                """,
                choices: ["Cancel", "Delete Calendar"],
                wayOut: 0
            ),
            offering: [false, true]
        ) { [weak self] deletes in
            guard let self else { return }
            guard deletes == true else {
                debugLog?.record(.field, "Button clicked: Cancel, calendar \(name) not deleted")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                settled(await carryOutDelete(id: id, named: name))
            }
        }
    }

    /// Deletes it at Google first and forgets it afterwards, in that order.
    ///
    /// **The id stays on a failure, because the calendar may well still be there.** Forgetting it on a failed
    /// request is how somebody ends up with an orphan they can no longer name.
    private func carryOutDelete(id: String, named name: String) async -> Settled {
        do {
            let token = try await accessToken()
            try await GoogleCalendarClient.delete(id: id, accessToken: token)
            guard
                settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, ""),
                settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, "")
            else {
                throw GoogleCalendarRules.Failure.deleteFailed("the database would not forget it")
            }
            debugLog?.record(.field, "Google calendar deleted, \(name)")
            return .none
        } catch {
            debugLog?.record(.field, "Google calendar delete failed: \(error.localizedDescription)")
            return .failed(Self.notice(error))
        }
    }

    /// The stored calendar does not resolve. Forget it, say so, and offer to make another.
    ///
    /// **The id is cleared here and only here**, once Google has said it is gone. Clearing it because a write failed
    /// or a request timed out is how somebody ends up with a second *Facet*, and a third.
    private func forgetAndOffer(accessToken: String) async -> Settled {
        _ = settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, "")
        _ = settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, "")
        debugLog?.record(.field, "Google calendar no longer resolves, forgotten")

        // **It does not claim to know which happened.** A calendar deleted at Google and an id belonging to a
        // different account both come back as not found, and a message that picked one would be wrong half the time.
        //
        // **No `wayOut`**: neither answer changes anything already recorded -- making a calendar is additive and
        // Not Now does nothing.
        let asking = Dialogue(
            title: "Facet cannot find its calendar",
            message: """
            The calendar Facet was using is not in this Google account. It may have been deleted, or this may be \
            a different account from the one it was made in.

            Facet can make a new one. Anything already written to the old calendar stays where it is.
            """,
            choices: ["Create Calendar", "Not Now"]
        )
        let creates = await withCheckedContinuation { continuation in
            dialogues.ask(asking, offering: [true, false]) { answer in
                continuation.resume(returning: answer == true)
            }
        }
        guard creates else { return .none }
        return await make(named: GoogleCalendarRules.defaultName, accessToken: accessToken)
    }

    /// What the table holds for the calendar, read now.
    package func stored() -> GoogleCalendarRules.Calendar {
        GoogleCalendarRules.calendar(
            id: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField),
            name: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField)
        )
    }

    private func stored(id: String) -> GoogleCalendarRules.Calendar {
        GoogleCalendarRules.calendar(
            id: id,
            name: settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField)
        )
    }

    /// A usable access token, from the refresh token in the secret store. **The same one the background sweep asks
    /// for**, so there is one answer to "who is signed in" rather than a window's and a sweep's.
    package func accessToken() async throws -> String {
        try await GoogleCalendarClient.currentAccessToken(tokens: tokens)
    }

    private static func notice(_ error: any Error) -> Dialogue {
        Dialogue(title: "Facet could not connect to Google", message: error.localizedDescription)
    }
}

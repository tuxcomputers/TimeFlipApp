@testable import FacetCore
import Foundation
import Testing

/// The calendar Facet owns in a Google account, with no Google at the other end.
///
/// **What can be checked without a network, and it is most of what matters**: which of the three settlements a
/// stored id leads to, what a sign-out keeps, what a failure leaves behind, and that the question before a delete
/// is asked at all. The requests themselves are `GoogleCalendarClient`'s and need Google; what is here is the
/// sequence around them, which is where every decision was.
///
/// **None of this had a test.** It was six private methods on `SettingsWindowController`, reachable only through
/// AppKit and a signed-in account.
@Suite @MainActor
final class GoogleCalendarTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var secrets: InMemorySecretStore!
    private var dialogues: RecordingDialogues!
    private var calendar: GoogleCalendar!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
        secrets = InMemorySecretStore()
        dialogues = RecordingDialogues()
        calendar = GoogleCalendar(
            settings: settings,
            tokens: GoogleTokenStore(secrets: secrets),
            dialogues: dialogues,
            debugLog: nil
        )
    }

    deinit {
        database.remove()
    }

    private func store(id: String, name: String) {
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.idField, id))
        #expect(settings.write(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField, name))
    }

    // MARK: - what a stored id leads to

    @Test func testNoStoredCalendarSettlesOnNoneRatherThanMakingOne() async {
        // **Signing in connects an account; it is not somebody asking for a calendar in it.** Nothing is lost by
        // waiting: entries recorded meanwhile stay unsynced and a later Create sweeps all of them in.
        let settled = await calendar.settle(accessToken: "a-token")

        #expect(settled == .none)
        #expect(dialogues.asked.isEmpty, "there is nothing to ask about")
    }

    @Test func testAnEmptyStoredIdIsTheSameAsNoneRatherThanSomethingToCheck() async {
        store(id: "", name: "")

        #expect(await calendar.settle(accessToken: "a-token") == .none)
    }

    @Test func testTheStoredCalendarIsWhatTheTableHolds() {
        store(id: "cal-1", name: "Facet")

        let stored = calendar.stored()

        #expect(stored.id == "cal-1")
        #expect(stored.name == "Facet")
    }

    // MARK: - renaming

    @Test func testRenamingWithNoCalendarDoesNothingAtAll() async {
        let settled = await calendar.rename(to: "Work")

        #expect(settled == .none)
        #expect(settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField) == nil)
    }

    @Test func testAFailedRenameLeavesTheStoredNameAlone() async {
        store(id: "cal-1", name: "Facet")

        // No token in the store, so the request cannot even be made: the rename fails before Google is reached.
        let settled = await calendar.rename(to: "Work")

        guard case .failed = settled else {
            Issue.record("a rename with no sign-in behind it has to fail rather than claim a name")
            return
        }
        // **Google is asked first and the row follows**, so a request that never happened changes nothing.
        #expect(settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.nameField) == "Facet")
    }

    // MARK: - deleting

    @Test func testDeletingAsksFirstAndNamesWhatGoes() async {
        store(id: "cal-1", name: "Work log")
        dialogues.leavesUnanswered = true

        calendar.delete { _ in }

        let asked = try? #require(dialogues.asked.first)
        #expect(asked?.title == "Delete the \"Work log\" calendar?")
        // **The distinction somebody needs to decide**: the calendar goes and the recorded time does not.
        #expect(asked?.message.contains("Your recorded time is not affected") == true)
    }

    @Test func testCancellingADeleteKeepsTheCalendar() async {
        store(id: "cal-1", name: "Facet")
        dialogues.answersWith = 0   // Cancel, which is also the way out

        calendar.delete { _ in }

        #expect(settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField) == "cal-1")
    }

    @Test func testDeletingWithNoCalendarAsksNothing() {
        var answers: [GoogleCalendar.Settled] = []

        calendar.delete { answers.append($0) }

        #expect(answers == [.none])
        #expect(dialogues.asked.isEmpty)
    }

    @Test func testADeleteThatFailsKeepsTheIdSoTheCalendarCanStillBeNamed() async {
        store(id: "cal-1", name: "Facet")
        dialogues.answersWith = 1   // Delete Calendar

        calendar.delete { _ in }
        // The request cannot be made without a token, so it fails -- and the id has to survive that: forgetting it
        // on a failed request is how somebody ends up with an orphan they can no longer name.
        try? await Task.sleep(for: .milliseconds(200))

        #expect(settings.string(GoogleAccountRules.setting, field: GoogleCalendarRules.idField) == "cal-1")
    }

    // MARK: - checking the sign-in

    @Test func testAStoreWithNothingInItReadsAsNotSignedInRatherThanRefused() async {
        #expect(await calendar.check() == .notSignedIn)
    }

    @Test func testAStoreThatWillNotAnswerIsNotTheSameAsBeingSignedOut() async {
        secrets.refusesWith = -25_300

        guard case .storeUnavailable = await calendar.check() else {
            Issue.record("a locked keyring is not somebody who signed out, and saying so sends them to a browser")
            return
        }
    }
}

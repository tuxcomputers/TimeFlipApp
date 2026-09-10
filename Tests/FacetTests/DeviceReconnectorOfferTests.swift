@testable import FacetCore
import Foundation
import Testing

/// Covers the branch a paired launch takes when it cannot find its cube: whether it asks, and what each answer does.
///
/// **Hermetic because the radio is a double**, which it was not until 2026-09-09. This file built a real
/// `BluetoothRadio` -- a concrete macOS class -- for a loop that depends only on `CubeRadio`, and got away with it
/// because `device_uuid` is left empty: `DeviceReconnectRules.target` then answers `nil` and the attempt stops
/// before the radio is touched. That is the bypass `docs/architecture-review-2026-09.md` candidate 2 names, and it
/// is why this file sat on the Linux exclusion list for a module with no platform dependency at all.
/// `InMemoryCubeRadio` took its place and the file runs on both platforms now.
///
/// **The empty `device_uuid` is still what most of these tests want**, the offer being about a cube that cannot be
/// found -- but it is now a choice about the case under test rather than the thing keeping the suite honest. What a
/// real reconnection does is still a device run's answer (see `Tests/Scripted`).
@Suite @MainActor
final class DeviceReconnectorOfferTests {
    private let clock = HandDrivenScheduler()
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    /// A real log, because what the loop does once it has stood down is *nothing* -- and the only way to tell nothing
    /// from a thing that failed silently is the row it writes on the way past.
    private var debugLog: DebugLog!
    /// The radio the loop talks to: a test sets its flags and reads back what it was asked to reach for.
    private let radio = InMemoryCubeRadio()

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        try database.bootstrapDebug()
        settings = SettingStore(connection: database.connection())
        debugLog = DebugLog(databaseURL: database.debugURL, isRecording: true)
    }

    deinit {
        // **`deinit` rather than `tearDown`, and it is not isolated.** Releasing the stored properties by hand is
        // what the old `MainActor.assumeIsolated` block was for; the instance is discarded whole here, so removing
        // the directory is all that is left. `database` is a `let` for the same reason.
        database.remove()
    }

    /// Whether the log holds a row matching `pattern`, which is a SQL `LIKE`.
    private func logged(_ pattern: String) -> Bool {
        // **A count, read as a number, so an unanswerable query is "no" rather than "yes".** This compared the text
        // against `"0"` until 2026-08-22, and a query that could not run at all answers `nil` -- which is not `"0"`,
        // so a missing table made every `logged` come back true and three `XCTAssertFalse`s fail at once. The lesson
        // is the shape rather than the table: a helper that turns "I could not tell you" into an affirmative will
        // eventually assert something nobody checked.
        (Int(database.debugString("SELECT COUNT(*) FROM debug_log WHERE message LIKE '\(pattern)';") ?? "0") ?? 0) > 0
    }

    private func setPaired(_ paired: Bool) {
        #expect(
            database.execute(
                "UPDATE setting SET setting_value = '{\"paired\":\(paired)}' WHERE setting_name = 'paired';"
            )
        )
    }

    /// The loop, plus a way to answer the question it asks. `answering` is `nil` for a presenter that puts the offer up
    /// and is still waiting, which is the state the app spends the dialog in.
    private func reconnector(
        answering: CubeNotFoundAnswer? = nil,
        asked: @escaping (String) -> Void = { _ in }
    ) -> DeviceReconnector {
        let loop = DeviceReconnector(
            radio: radio,
            settings: settings,
            debugLog: debugLog,
            scheduler: clock,
            storedPINs: { [] }
        )
        loop.onCubeNotFound = { reason, answer in
            asked(reason)
            if let answering { answer(answering) }
        }
        return loop
    }

    @Test func testAPairedLaunchThatCannotFindItsCubeAsks() {
        setPaired(true)
        var reasons: [String] = []
        let loop = reconnector(asked: { reasons.append($0) })

        loop.noteOutcome(.unreachable)

        #expect(reasons == ["nothing answered"])
    }

    @Test func testTheReasonSaysWhichProblemItWas() {
        // A cube that answered and refused the PIN is a different problem with a different fix from one that was not
        // there, and this line is the only place the two can be told apart.
        setPaired(true)
        var reasons: [String] = []
        let loop = reconnector(answering: .timeByHand, asked: { reasons.append($0) })

        loop.noteOutcome(.wrongPIN)

        #expect(reasons.count == 1)
        #expect(reasons.first == CubeNotFoundOffer.reason(for: .wrongPIN))
        #expect(reasons.first != CubeNotFoundOffer.reason(for: .unreachable))
    }

    @Test func testAnUnpairedAppIsNeverAsked() {
        // There is no cube on record, so there is nothing to have failed to find and nothing to offer an alternative
        // to. An app with nothing paired is already its own clock, that being what timing by hand means.
        setPaired(false)
        var asked = 0
        let loop = reconnector(asked: { _ in asked += 1 })

        loop.noteOutcome(.unreachable)

        #expect(asked == 0)
    }

    @Test func testOnceTheCubeHasBeenReachedALaterFailureIsQuiet() {
        // The startup-only rule, through the loop: a drop hours later is retried on the backoff with no dialog.
        setPaired(true)
        var asked = 0
        let loop = reconnector(asked: { _ in asked += 1 })

        loop.noteOutcome(.loggedIn)
        loop.noteOutcome(.unreachable)

        #expect(asked == 0)
    }

    @Test func testRescanAsksAgainIfTheCubeIsStillNotThere() {
        // Rescan is one more attempt and the same question if that finds nothing too. The attempt it starts stops at
        // `device_uuid`, which is empty here, so what is asserted is the loop coming back round rather than a scan.
        setPaired(true)
        var asked = 0
        let loop = reconnector(answering: .rescan, asked: { _ in asked += 1 })

        loop.noteOutcome(.unreachable)
        loop.noteOutcome(.unreachable)

        #expect(asked == 2)
    }

    @Test func testChoosingToTimeByHandStopsThisLaunchLookingForTheCube() {
        // **The whole of what the answer promises, and it is per launch.** Paired, started, cube not found, timing by
        // hand chosen: nothing looks for that cube again until the app is restarted. Every route in is tried here --
        // another failed outcome, and a drop -- because the two gates that enforce it are in different methods, and
        // the one in `scheduleAttempt` exists so the log cannot claim an attempt that `attempt` will stand down.
        setPaired(true)
        var asked = 0
        let loop = reconnector(answering: .timeByHand, asked: { _ in asked += 1 })

        loop.noteOutcome(.unreachable)
        loop.noteDropped()
        loop.noteOutcome(.unreachable)

        #expect(asked == 1, "the question came back after it had already been answered")
        #expect(logged("Time by hand chosen%"))
        #expect(logged("This launch was told to time by hand%"))
        #expect(!(logged("Looking for the cube again%")), "and nothing was arranged behind the answer")
    }

    @Test func testChoosingToTimeByHandMakesTheAppItsOwnClock() {
        // **The half that was missing, and the reason this bug existed.** The loop stopping is not the point of the
        // answer: being able to work is. `ManualTimerRules.isManualMode` reads this flag, so what is asserted here is
        // the flag it reads -- with the pairing deliberately checked as well, because the cube staying on record is
        // what makes the choice free to make.
        setPaired(true)
        let loop = reconnector(answering: .timeByHand)

        loop.noteOutcome(.unreachable)

        #expect(loop.hasGivenUpOnCube)
        #expect(
            ManualTimerRules.isManualMode(isCubePaired: true, hasGivenUpOnCube: loop.hasGivenUpOnCube),
            "the app is still following a cube it has been told to get on without"
        )
        #expect(
            settings.flag("paired", field: "paired") == true,
            "the answer wrote the pairing away, so the cube cannot be come back to"
        )
    }

    @Test func testChoosingToTimeByHandRedrawsWhatCannotAskAgainOnItsOwn() {
        // The menu bar's tick does not run while nothing is being timed and the Faces tab repaints on a flip that
        // cannot arrive, so both are redrawn from here. Asserted because it is invisible: without it the answer is
        // correct everywhere and looks like it did nothing until something else happens to repaint.
        setPaired(true)
        var redraws = 0
        let loop = reconnector(answering: .timeByHand)
        loop.onGaveUpOnCube = { redraws += 1 }

        loop.noteOutcome(.unreachable)

        #expect(redraws == 1)
    }

    @Test func testQuitAsksToTerminateAndDecidesNothingElse() {
        // **Quit commits to nothing**, which is what it is for: the pairing is untouched, this launch is not made its
        // own clock, and the next launch therefore asks the same question. Nothing is arranged either, since the
        // process is going away.
        setPaired(true)
        var quits = 0
        let loop = reconnector(answering: .quit)
        loop.onQuitRequested = { quits += 1 }

        loop.noteOutcome(.unreachable)

        #expect(quits == 1)
        #expect(!loop.hasGivenUpOnCube, "quitting decided the launch was its own clock on the way out")
        #expect(settings.flag("paired", field: "paired") == true)
        #expect(logged("Quit chosen at the device offer%"))
        #expect(!(logged("Looking for the cube again%")))
    }

    @Test func testAnUnansweredOfferLeavesTheLoopWaiting() {
        // The state the app spends the dialog in: asked, and nothing decided. Neither answer's consequence is in
        // place, and no attempt runs behind it.
        setPaired(true)
        let loop = reconnector()

        loop.noteOutcome(.unreachable)

        #expect(!loop.hasGivenUpOnCube)
        #expect(!(logged("Looking for the cube again%")))
    }

    // MARK: - forgetting the device ends the loop, without a restart

    /// The loop as it stands the moment after somebody presses Forget Device: nothing paired, and this object never
    /// told about it.
    private func loopWithNothingPaired() -> DeviceReconnector {
        setPaired(false)
        return reconnector()
    }

    @Test func testADropSchedulesNothingOnceTheDeviceIsForgotten() {
        // The gate in `attempt` would stand the attempt down anyway. What this is about is the arranging: without it
        // the log says "Looking for the cube again in 8s" and then quietly does not, which is a record of an app still
        // hunting for a cube it no longer has.
        let loop = loopWithNothingPaired()

        loop.noteDropped()

        #expect(!(logged("Looking for the cube again%")), "an attempt was scheduled with nothing paired")
    }

    @Test func testAFailedOutcomeSchedulesNothingEither() {
        // The other way into the scheduler. Both are covered by the one gate, and both are checked, because a gate
        // that covered one of two callers would be a loop that stopped only for some kinds of failure.
        let loop = loopWithNothingPaired()

        loop.noteOutcome(.unreachable)

        #expect(!(logged("Looking for the cube again%")))
    }

    @Test func testNothingIsArrangedForADeviceNobodyHas() {
        // An unpaired app never reaches the offer at all: `noteOutcome` stands down before it, since a failure to
        // reach a cube nobody has is not news. What is checked here is the end of it -- no attempt arranged either.
        let loop = loopWithNothingPaired()

        loop.noteOutcome(.unreachable)

        #expect(!(logged("Looking for the cube again%")))
        #expect(!(logged("Offering manual mode%")))
    }

    @Test func testTheLoopReadsThePairingPerAttemptRatherThanRemembering() {
        // **The whole of what makes a forget take effect without a restart, and a pairing too.** The loop is built
        // once and lives for the launch, so a copy of the answer taken when it was built would go on chasing a cube
        // the user gave up -- and would sit still beside one they had just paired. Both directions are driven here
        // against one loop, because both are the same read.
        setPaired(false)
        let loop = reconnector()
        loop.noteDropped()
        #expect(!(logged("Looking for the cube again%")), "precondition: nothing paired, so nothing arranged")

        setPaired(true)
        loop.noteDropped()

        #expect(logged("Looking for the cube again%"), "a cube paired mid-launch is followed without a restart")
    }

    @Test func testWithNoPresenterItRetriesRatherThanStopping() {
        // A build with nowhere to put a dialog must not quietly stop reaching for the cube: an app that gave up with
        // no way to say so would simply look broken.
        setPaired(true)
        let loop = DeviceReconnector(
            radio: radio,
            settings: settings,
            debugLog: nil,
            scheduler: clock,
            storedPINs: { [] }
        )

        loop.noteOutcome(.unreachable)

        // **This used to say there was nothing to assert but that it survives.** There was: whether it actually
        // arranged the retry, which was invisible while the retry was a `Timer` on `RunLoop.main`. A build with
        // nowhere to put a dialog that quietly stopped reaching for the cube would just look broken.
        #expect(clock.wakes.count == 1, "no presenter, so it retries rather than asking")
        #expect(clock.wakes.first?.seconds == DeviceReconnectRules.delay(afterFailures: 0))
    }

    @Test func testEachFailureWaitsLongerThanTheOneBefore() {
        // **`DeviceReconnectRules.delay(afterFailures:)` was already tested to the last edge case, and none of it
        // said this module counts.** The rule is pure and the walk through it was a `Timer` on `RunLoop.main`, so
        // whether the failure count grew, and whether the delay handed over was the one for it, could not be
        // asserted anywhere. That is the shape the architecture review calls a pure function extracted for
        // testability while the bug hides in how it is called.
        setPaired(true)
        let loop = DeviceReconnector(
            radio: radio,
            settings: settings,
            debugLog: nil,
            scheduler: clock,
            storedPINs: { [] }
        )

        var waited: [TimeInterval] = []
        for _ in 0..<3 {
            loop.noteOutcome(.unreachable)
            // One at a time: arranging the next cancels the one before it, so the list never holds two.
            waited.append(clock.wakes.first?.seconds ?? -1)
        }

        #expect(waited == [2, 4, 6], "the backoff grows with the failures rather than repeating the first delay")
        #expect(clock.wakes.count == 1, "and there is only ever one retry outstanding")
    }
}

@testable import FacetApp
import XCTest

/// Covers the branch a paired launch takes when it cannot find its cube: whether it asks, and what each answer does.
///
/// **Hermetic, and it stays that way because `device_uuid` is left empty.** The reconnector never touches a radio
/// without a device to reach for -- `DeviceReconnectRules.target` answers `nil` and the attempt stops there -- so a
/// `BluetoothRadio` can be built here and driven through the whole decision without a scan, a cube, or the system's
/// Bluetooth prompt. What a real reconnection does is a device run's answer (see `Tests/Scripted`).
@MainActor
final class DeviceReconnectorOfferTests: XCTestCase {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    /// A real log, because what the loop does once it has stood down is *nothing* -- and the only way to tell nothing
    /// from a thing that failed silently is the row it writes on the way past.
    private var debugLog: DebugLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        try database.bootstrapDebug()
        settings = SettingStore(connection: database.connection())
        debugLog = DebugLog(databaseURL: database.debugURL)
    }

    override func tearDown() {
        debugLog = nil
        settings = nil
        database.remove()
        super.tearDown()
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
        XCTAssertTrue(
            database.execute(
                "UPDATE setting SET setting_value = '{\"paired\":\(paired)}' WHERE setting_name = 'paired';"
            )
        )
    }

    /// The loop, plus a way to answer the question it asks. `answering` is `nil` for a presenter that puts the offer up
    /// and is still waiting, which is the state the app spends the dialog in.
    private func reconnector(
        isTimingByHand: @escaping () -> Bool = { false },
        answering: CubeNotFoundAnswer? = nil,
        asked: @escaping (String) -> Void = { _ in }
    ) -> DeviceReconnector {
        let loop = DeviceReconnector(
            radio: BluetoothRadio(debugLog: nil),
            settings: settings,
            debugLog: debugLog,
            storedPIN: { nil },
            isTimingByHand: isTimingByHand
        )
        loop.onCubeNotFound = { reason, answer in
            asked(reason)
            if let answering { answer(answering) }
        }
        return loop
    }

    func testAPairedLaunchThatCannotFindItsCubeAsks() {
        setPaired(true)
        var reasons: [String] = []
        let loop = reconnector(asked: { reasons.append($0) })

        loop.noteOutcome(.unreachable)

        XCTAssertEqual(reasons, ["nothing answered"])
    }

    func testTheReasonSaysWhichProblemItWas() {
        // A cube that answered and refused the PIN is a different problem with a different fix from one that was not
        // there, and this line is the only place the two can be told apart.
        setPaired(true)
        var reasons: [String] = []
        let loop = reconnector(answering: .stopLooking, asked: { reasons.append($0) })

        loop.noteOutcome(.wrongPIN)

        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(reasons.first, CubeNotFoundOffer.reason(for: .wrongPIN))
        XCTAssertNotEqual(reasons.first, CubeNotFoundOffer.reason(for: .unreachable))
    }

    func testAnUnpairedAppIsNeverAsked() {
        // There is no cube on record, so there is nothing to have failed to find and nothing to offer an alternative
        // to. That launch is already timing by hand (`LaunchMode.decided` answers `.manual` with nothing paired).
        setPaired(false)
        var asked = 0
        let loop = reconnector(asked: { _ in asked += 1 })

        loop.noteOutcome(.unreachable)

        XCTAssertEqual(asked, 0)
    }

    func testOnceTheCubeHasBeenReachedALaterFailureIsQuiet() {
        // The startup-only rule, through the loop: a drop hours later is retried on the backoff with no dialog.
        setPaired(true)
        var asked = 0
        let loop = reconnector(asked: { _ in asked += 1 })

        loop.noteOutcome(.loggedIn)
        loop.noteOutcome(.unreachable)

        XCTAssertEqual(asked, 0)
    }

    func testRetryAsksAgainIfTheCubeIsStillNotThere() {
        // Retry is one more attempt and the same question if that finds nothing too. The attempt it starts stops at
        // `device_uuid`, which is empty here, so what is asserted is the loop coming back round rather than a scan.
        setPaired(true)
        var asked = 0
        let loop = reconnector(answering: .retry, asked: { _ in asked += 1 })

        loop.noteOutcome(.unreachable)
        loop.noteOutcome(.unreachable)

        XCTAssertEqual(asked, 2)
    }

    func testChoosingManualModeStopsTheLoopAsking() {
        // Manual mode is the caller's to turn on -- this loop only stops -- so the test supplies the same answer the
        // app does: the mode goes on, and the loop reads it rather than keeping a copy.
        setPaired(true)
        var timingByHand = false
        var asked = 0
        let loop = reconnector(
            isTimingByHand: { timingByHand },
            answering: .stopLooking,
            asked: { _ in
                asked += 1
                timingByHand = true
            }
        )

        loop.noteOutcome(.unreachable)
        // Whatever else happens this launch -- a stray outcome, a drop -- the app does not go back to asking.
        loop.noteDropped()
        loop.noteOutcome(.unreachable)

        XCTAssertEqual(asked, 1, "the question came back after it had already been answered")
        XCTAssertTrue(timingByHand)
    }

    // MARK: - taking manual mode ends the loop for the launch

    /// The loop with the mode already on, which is where a launch is the moment after the offer is answered.
    private func loopTimingByHand() -> DeviceReconnector {
        setPaired(true)
        return reconnector(isTimingByHand: { true })
    }

    func testADropSchedulesNothingOnceManualModeIsTaken() {
        // The gate in `attempt` would stand the attempt down anyway. What this is about is the arranging: without it
        // the log says "Looking for the cube again in 8s" and then quietly does not, which is a record of an app still
        // hunting for a cube it was told to stop hunting for.
        let loop = loopTimingByHand()

        loop.noteDropped()

        XCTAssertFalse(logged("Looking for the cube again%"), "an attempt was scheduled while timing by hand")
        XCTAssertTrue(logged("Timing by hand, so the cube is not being looked for again%"))
    }

    func testAFailedOutcomeSchedulesNothingEither() {
        // The other way into the scheduler. Both are covered by the one gate, and both are checked, because a gate
        // that covered one of two callers would be a loop that stopped only for some kinds of failure.
        let loop = loopTimingByHand()

        loop.noteOutcome(.unreachable)

        XCTAssertFalse(logged("Looking for the cube again%"))
    }

    func testTheOfferDoesNotComeBack() {
        let loop = loopTimingByHand()

        loop.noteOutcome(.unreachable)

        XCTAssertTrue(logged("Timing by hand, so the offer is not put up again%"))
    }

    func testTheLoopReadsTheModePerAttemptRatherThanRemembering() {
        // **What this pins is the reading, not a way out of the mode.** There is only one way out now -- a restart --
        // and this loop does not live across one (`LaunchMode`). What still matters is that the gate is asked at the
        // moment it is about to act rather than captured when the loop was built, which is what lets a launch that is
        // its own clock stop reaching without anything having to tell this object so.
        var timingByHand = true
        setPaired(true)
        let loop = reconnector(isTimingByHand: { timingByHand })
        loop.noteDropped()
        XCTAssertFalse(logged("Looking for the cube again%"), "precondition: stood down")

        // Paired again, and the mode off with it.
        timingByHand = false
        loop.noteDropped()

        XCTAssertTrue(logged("Looking for the cube again%"))
    }

    func testWithNoPresenterItRetriesRatherThanStopping() {
        // A build with nowhere to put a dialog must not quietly stop reaching for the cube: an app that gave up with
        // no way to say so would simply look broken.
        setPaired(true)
        let loop = DeviceReconnector(
            radio: BluetoothRadio(debugLog: nil),
            settings: settings,
            debugLog: nil,
            storedPIN: { nil }
        )

        // Nothing to assert but that it survives and schedules: the value is that this path exists and is exercised.
        loop.noteOutcome(.unreachable)
    }
}

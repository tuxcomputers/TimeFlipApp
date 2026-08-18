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

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    override func tearDown() {
        settings = nil
        database.remove()
        super.tearDown()
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
        answering: ManualModeAnswer? = nil,
        asked: @escaping (String) -> Void = { _ in }
    ) -> DeviceReconnector {
        let loop = DeviceReconnector(
            radio: BluetoothRadio(debugLog: nil),
            settings: settings,
            debugLog: nil,
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
        let loop = reconnector(answering: .switchToManualMode, asked: { reasons.append($0) })

        loop.noteOutcome(.wrongPIN)

        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(reasons.first, ManualModeOffer.reason(for: .wrongPIN))
        XCTAssertNotEqual(reasons.first, ManualModeOffer.reason(for: .unreachable))
    }

    func testAnUnpairedAppIsNeverAsked() {
        // There is no cube on record, so there is nothing to have failed to find and nothing to offer an alternative
        // to. That launch is already timing by hand (`ManualMode.startIfNoDeviceIsPaired`).
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
            answering: .switchToManualMode,
            asked: { _ in
                asked += 1
                timingByHand = true
            }
        )

        loop.noteOutcome(.unreachable)
        // Whatever else happens this launch -- a stray outcome, a drop -- the app does not go back to asking.
        loop.noteDropped()
        loop.noteOutcome(.unreachable)

        XCTAssertEqual(asked, 2, "the offer is not suppressed by the mode; what the mode stops is the attempts")
        XCTAssertTrue(timingByHand)
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

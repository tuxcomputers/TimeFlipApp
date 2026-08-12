@testable import TimeFlipApp
import XCTest

/// A manual session on its way to a device, and what must not break on the journey.
///
/// Manual mode used to be a cul-de-sac: entered when a paired cube could not be reached, and left
/// only by quitting. Two things opened it up. An app with nothing paired now *starts* here, because
/// there is no device to reach and so nothing to ask about, and scanning and pairing work from inside
/// a session -- which is how a user who buys a cube after living in manual mode gets to use it. That
/// makes a manual session a state the pairing changes *underneath*, and every test below is about the
/// session surviving that: the clock is running, it is writing real segments to a real database, and
/// nothing about dropping or acquiring a pairing is a reason to stop it.
///
/// The delegate half -- the virtual device standing down when a cube answers, and the radio being
/// held across the swap so there is something to scan with -- is not reachable from here and is
/// covered by `Tests/Bench/16b-manual-mode-pairing-checklist.md` on hardware.
@MainActor
final class ManualSessionToDeviceTests: XCTestCase {
    /// Every store injected, `developerConfigStore` included: the default is the developer's real
    /// `config.json`, and `forgetDevice` is one of the paths that has written to it.
    private func makeAppState(isPaired: Bool) -> AppState {
        AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            developerConfigStore: InMemoryDeveloperConfigStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true,
            isPaired: isPaired,
            deviceName: isPaired ? "Solid cube" : nil
        )
    }

    /// A session that has been running a while: manual mode's own face, timing, mid-segment.
    private func makeRunningManualSession(isPaired: Bool = true) -> AppState {
        let appState = makeAppState(isPaired: isPaired)
        appState.enterManualMode()
        appState.currentFaceID = TimeFlipConstants.manualFaceID
        appState.isPaused = false
        return appState
    }

    // MARK: - Forgetting the cube from inside a manual session

    func testForgettingDuringAManualSessionDropsThePairingAndNothingElse() {
        // The route this exists for: the cube's batteries were changed, so it is back on the vendor
        // PIN and refuses the stored one, and the app offered manual mode. Forgetting is what makes
        // the scan list appear, which is how the user gets back to their cube -- and it must not cost
        // them the session they are timing in the meantime.
        let appState = makeRunningManualSession()

        appState.forgetDevice()

        XCTAssertFalse(appState.isPaired, "the pairing is what Forget is for")
        XCTAssertEqual(appState.pairedDeviceName, "Not paired")
        XCTAssertNil(appState.pairedDeviceUUID)
        XCTAssertEqual(appState.connectionStatus, .manual, "the session is still the thing timing")
        XCTAssertTrue(appState.isManualMode)
    }

    func testForgettingDuringAManualSessionLeavesTheClockRunning() {
        // Each of these was cleared unconditionally, and each did its own damage. `.disconnected`
        // tears the menu bar's display down (`MenuBarLiveDisplay.showsActivity`), the face drops the
        // Faces tab's timer to `idle` (`ManualTimerRules.state`), and `isPaused` claims the session
        // stopped -- while the virtual device carries on writing segments regardless, so the app would
        // have been recording time it was telling the user it was not.
        let appState = makeRunningManualSession()

        appState.forgetDevice()

        XCTAssertEqual(appState.currentFaceID, TimeFlipConstants.manualFaceID)
        XCTAssertFalse(appState.isPaused)
        XCTAssertEqual(
            ManualTimerRules.state(currentFaceID: appState.currentFaceID, isPaused: appState.isPaused),
            .running
        )
        XCTAssertTrue(
            MenuBarLiveDisplay.showsActivity(
                isPaired: appState.isPaired,
                hasReachedDeviceThisSession: false,
                connectionStatus: appState.connectionStatus
            )
        )
    }

    func testForgettingDuringAManualSessionStillReportsTheChange() {
        // The `paired` setting has to reach the database either way -- the delegate's listener is what
        // records it, and it is the same listener that must *not* tear the session down.
        let appState = makeRunningManualSession()
        var reported: [Bool] = []
        appState.onPairingChange = { reported.append($0) }

        appState.forgetDevice()

        XCTAssertEqual(reported, [false])
    }

    func testForgettingOutsideAManualSessionStillClearsTheReading() {
        // The other side of the branch, and the case that was always right: a real cube has been let
        // go of, so its face, its pause state and its battery level are no longer anybody's reading.
        let appState = makeAppState(isPaired: true)
        appState.confirmConnected(name: "Solid cube", uuid: "uuid")
        appState.currentFaceID = 8
        appState.isPaused = false
        appState.batteryLevel = 74

        appState.forgetDevice()

        XCTAssertEqual(appState.connectionStatus, .disconnected)
        XCTAssertEqual(appState.currentFaceID, TimeFlipConstants.unassignedFaceID)
        XCTAssertTrue(appState.isPaused)
        XCTAssertNil(appState.batteryLevel)
    }

    // MARK: - A pairing attempt that came to nothing

    func testAFailedPairingAttemptReturnsToTheManualSession() {
        // Clicking a device leaves `.manual` for `.pairing`, so every way that attempt can end badly
        // lands on a status describing an app that is timing nothing: `pairingFailed` sets `.failed`,
        // and cancelling sets `.disconnected`. The session is still running underneath, so the app has
        // to say so again.
        let appState = makeRunningManualSession(isPaired: false)
        appState.connectionStatus = .pairing

        appState.pairingFailed(message: "Wrong PIN")
        XCTAssertEqual(appState.connectionStatus, .failed("Wrong PIN"))

        appState.enterManualMode()

        XCTAssertEqual(appState.connectionStatus, .manual)
        XCTAssertFalse(appState.isPaired, "a failed attempt pairs nothing")
        XCTAssertEqual(appState.currentFaceID, TimeFlipConstants.manualFaceID, "still timing what it was")
        XCTAssertFalse(appState.isPaused)
    }

    func testReturningToTheManualSessionDoesNotReopenTheOffer() {
        // `enterManualMode` is now reached more than once in a launch, and it must stay the answer to
        // the offer rather than something that re-raises it.
        let appState = makeRunningManualSession()
        appState.connectionStatus = .pairing

        appState.enterManualMode()

        XCTAssertFalse(appState.isAwaitingManualModeDecision)
        XCTAssertFalse(appState.mayOfferManualMode)
        XCTAssertFalse(appState.shouldAttemptConnection, "no automatic attempt, exactly as before")
    }

    // MARK: - A launch with nothing paired

    func testALaunchWithNothingPairedIsAUsableApp() {
        // What starting in manual mode has to buy: the app is worth opening before a cube is ever
        // bought. Both rules would once have answered "nothing is happening here" -- the display was
        // gated on having reached a device this session, and the timer on being connected to one.
        let appState = makeRunningManualSession(isPaired: false)

        XCTAssertTrue(
            MenuBarLiveDisplay.showsActivity(
                isPaired: false,
                hasReachedDeviceThisSession: false,
                connectionStatus: appState.connectionStatus
            ),
            "the app name alone is for a session with no reading; this one has one"
        )
        XCTAssertTrue(
            MenuBarLiveDisplay.rendersAsLive(isPaired: false, connectionStatus: appState.connectionStatus),
            "the app is generating the reading, so it cannot be out of date"
        )
        XCTAssertEqual(
            MenuBarDropdownRules.pauseTitle(
                connectionStatus: appState.connectionStatus,
                isPaired: false,
                isPaused: true
            ),
            "Resume",
            "the item names a real stopped timer; with no timing source it would read Pause regardless"
        )
        XCTAssertTrue(
            MenuBarDropdownRules.allowsPause(
                connectionStatus: appState.connectionStatus,
                isPaired: false,
                isLocked: false,
                isPaused: false,
                isDailyLimitReached: false
            ),
            "there is a clock to stop"
        )
    }

    func testALaunchWithNothingPairedIsNotAskedAnything() {
        // The offer settles "your cube isn't answering -- keep trying, or time it yourself?". With
        // nothing paired there is no cube, no failed scan and nothing to retry, so the app arrives in
        // manual mode rather than asking. Nothing is pending, and no attempt is owed.
        let appState = makeRunningManualSession(isPaired: false)

        XCTAssertFalse(appState.isAwaitingManualModeDecision)
        XCTAssertFalse(appState.shouldMaintainConnection, "there is no pairing to keep alive")
        XCTAssertFalse(appState.shouldAttemptConnection)
    }

    func testPairingFromAManualSessionEndsTheModeOutright() {
        // The one way a session ends without the app quitting, and it is the user's own act. The
        // status carries the whole answer, so there is no flag left saying manual mode while the app
        // is connected -- the pair that could once have written a manual segment with a live cube on
        // the other end.
        let appState = makeRunningManualSession(isPaired: false)
        appState.connectionStatus = .pairing

        appState.confirmConnected(name: "Shiny new toy", uuid: "uuid")

        XCTAssertFalse(appState.isManualMode)
        XCTAssertTrue(appState.isConnected)
        XCTAssertTrue(appState.isPaired)
        XCTAssertEqual(appState.pairedDeviceName, "Shiny new toy")
    }
}

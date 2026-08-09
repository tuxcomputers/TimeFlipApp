@testable import TimeFlipApp
import XCTest

/// The two gates that decide whether the app may reach for its device, and the difference between
/// them.
///
/// `shouldMaintainConnection` asks whether there is a pairing to reconnect to; a drop while it is
/// false is reported as a pairing failure. `shouldAttemptConnection` asks whether an attempt may
/// start right now, and is the one every retry path reads. Manual mode belongs to the second only:
/// reading it into the first would report a pairing failure for a device that is perfectly well
/// paired and merely out of range.
@MainActor
final class AppStateManualModeGateTests: XCTestCase {
    private func makePairedAppState() -> AppState {
        AppState(
            googleClientSecretStore: InMemoryGoogleClientSecretStore(),
            devicePasswordStore: InMemoryDevicePasswordStore(),
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            blinkIntervalSeconds: 15,
            doubleTapParameters: .default,
            isDoubleTapEnabled: true,
            isPaired: true,
            deviceName: "Solid cube"
        )
    }

    func testAPairedAppMayAttemptAConnection() {
        let appState = makePairedAppState()

        XCTAssertTrue(appState.shouldMaintainConnection)
        XCTAssertTrue(appState.shouldAttemptConnection)
    }

    func testNothingMayAttemptWhileTheOfferIsOnScreen() {
        let appState = makePairedAppState()

        appState.awaitManualModeDecision()

        XCTAssertFalse(
            appState.shouldAttemptConnection,
            "the backoff retry and the wake-from-sleep path both read this"
        )
        XCTAssertTrue(
            appState.shouldMaintainConnection,
            "the pairing is untouched -- a late failure here must not be reported as a pairing failure"
        )
    }

    func testRetryReopensTheGate() {
        let appState = makePairedAppState()
        appState.awaitManualModeDecision()

        appState.manualModeDeclined()

        XCTAssertTrue(appState.shouldAttemptConnection)
        XCTAssertFalse(appState.isManualMode)
    }

    func testManualModeClosesTheGateForGood() {
        let appState = makePairedAppState()
        appState.awaitManualModeDecision()

        appState.enterManualMode()

        XCTAssertFalse(appState.isAwaitingManualModeDecision, "the offer is answered, not still open")
        XCTAssertTrue(appState.isManualMode)
        XCTAssertFalse(appState.shouldAttemptConnection)
        XCTAssertTrue(appState.shouldMaintainConnection, "still paired to the same device")
        XCTAssertEqual(appState.connectionStatus, .disconnected)
    }

    func testManualModeStillReadsAsPairedRatherThanNotPaired() {
        // The Device tab renders "Not paired" from `isPaired`, and manual mode is a state the app
        // is in rather than an unpairing -- the device is still the user's device.
        let appState = makePairedAppState()

        appState.enterManualMode()

        XCTAssertTrue(appState.isPaired)
        XCTAssertNotEqual(appState.pairedDeviceName, "Not paired")
    }
}

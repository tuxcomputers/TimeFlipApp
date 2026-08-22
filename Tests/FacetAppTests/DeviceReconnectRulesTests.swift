@testable import FacetApp
import Foundation
import XCTest

/// The judgements a reconnect loop makes, which are the only part of it a hermetic suite can reach: `swift test` never
/// scans, so whether the app actually gets back to a cube is a device run's answer (see `Tests/Scripted`). What is
/// checked here is that it asks at the right times and waits the right amount, because a loop that decides wrongly does
/// so silently and for hours.
final class DeviceReconnectRulesTests: XCTestCase {
    private func shouldAttempt(
        isPaired: Bool = true,
        isConnected: Bool = false,
        isScanning: Bool = false,
        isReaching: Bool = false,
        isResetting: Bool = false,
        isAwaitingAnswer: Bool = false,
        isTimingByHand: Bool = false
    ) -> Bool {
        DeviceReconnectRules.shouldAttempt(
            isPaired: isPaired,
            isConnected: isConnected,
            isScanning: isScanning,
            isReaching: isReaching,
            isResetting: isResetting,
            isAwaitingAnswer: isAwaitingAnswer,
            isTimingByHand: isTimingByHand
        )
    }

    // MARK: - when to reach

    func testAPairedAppWithNoConnectionReaches() {
        XCTAssertTrue(shouldAttempt())
    }

    func testAnUnpairedAppNeverReaches() {
        // The whole licence to hold a connection is the pairing. Every other input says the radio is free, and it stays
        // free: an app with no device has nothing to look for, and a loop that scanned anyway would be a radio running
        // for the life of a launch that never had a cube.
        XCTAssertFalse(shouldAttempt(isPaired: false))
    }

    func testForgettingTheDeviceStopsTheLoopWithNothingHavingToTellIt() {
        // The same case as above, and it is here under its own name because it is the one that matters at runtime:
        // `isPaired` is read from the table per attempt, so Forget Device stops this without the button knowing the loop
        // exists. If this ever answers true, forgetting a cube leaves the app chasing it.
        XCTAssertFalse(shouldAttempt(isPaired: false, isConnected: false))
    }

    func testAConnectedAppDoesNotReachForWhatItAlreadyHas() {
        XCTAssertFalse(shouldAttempt(isConnected: true))
    }

    // MARK: - standing down while the radio is busy

    func testAScanSomebodyIsWatchingIsNotInterrupted() {
        // Two scans is one radio being asked two questions. Standing down is not giving up: a scan ends, and the answer
        // to the drop that started this is asked again after it.
        XCTAssertFalse(shouldAttempt(isScanning: true))
    }

    func testAnAttemptAlreadyInFlightIsNotDoubled() {
        XCTAssertFalse(shouldAttempt(isReaching: true))
    }

    func testACubeBeingResetIsNotReachedFor() {
        // A reset is the app being told to give the cube up, and its confirmation is a login this loop must not
        // interfere with -- presenting the stored PIN mid-wipe would either fail or, worse, succeed and be counted as
        // proof the wipe took. `BluetoothRadio.factoryReset` explains why only the vendor default may be offered there.
        XCTAssertFalse(shouldAttempt(isResetting: true))
    }

    // MARK: - standing down because the app has stopped

    func testNothingIsAttemptedWhileTheOfferIsOnScreen() {
        // Somebody who starts the app and walks away has to find the question exactly where they left it, rather than
        // a backoff retry having quietly started another run of attempts behind the dialog.
        XCTAssertFalse(shouldAttempt(isAwaitingAnswer: true))
    }

    func testNothingIsAttemptedOnceManualModeIsChosen() {
        // The whole of what choosing it means: the app looks for nothing on its own again this launch, so a cube
        // drifting into range for a few seconds cannot surprise anybody.
        XCTAssertFalse(shouldAttempt(isTimingByHand: true))
    }

    func testAnOfferAndAFreeRadioStillDoNotAttempt() {
        // The two halves are independent: a radio doing nothing is exactly the state the offer is up in, so a rule
        // that only asked whether the radio was busy would retry straight through the dialog.
        XCTAssertTrue(shouldAttempt(), "precondition: an idle radio would otherwise attempt")
        XCTAssertFalse(shouldAttempt(isAwaitingAnswer: true))
        XCTAssertFalse(shouldAttempt(isTimingByHand: true))
    }

    func testPairingIsStillWhatDecidesFirst() {
        // Manual mode does not touch the pairing and the pairing does not override the mode: an unpaired app has
        // nothing to reach for whatever else is true.
        XCTAssertFalse(shouldAttempt(isPaired: false, isAwaitingAnswer: false, isTimingByHand: false))
    }

    // MARK: - how long to wait

    func testTheFirstRetryIsQuick() {
        // The commonest failure by a distance is a cube that was asleep and has just been flipped.
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: 0), 2)
    }

    func testTheWaitGrowsBySteps() {
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: 1), 4)
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: 2), 6)
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: 5), 12)
    }

    func testTheWaitStopsGrowingAtThirtySeconds() {
        // The cap is what makes a cube left at home cheap rather than abandoned: half a minute a try, for as long as it
        // takes. An uncapped or doubling backoff would have a cube that comes back after lunch waiting until dinner.
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: 14), 30)
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: 15), 30)
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: 900), 30)
    }

    func testANegativeCountIsStillTheFirstWait() {
        // Nothing should ever pass one. It answers the first delay rather than a negative interval, because a timer
        // scheduled in the past fires immediately and would spin.
        XCTAssertEqual(DeviceReconnectRules.delay(afterFailures: -3), 2)
    }

    // MARK: - which cube

    func testTheStoredUUIDIsTheDeviceToReach() {
        let id = UUID()
        XCTAssertEqual(DeviceReconnectRules.target(from: id.uuidString), id)
    }

    func testARowThatNamesNoDeviceIsNothingToReachFor() {
        // `recordForget` empties this rather than removing it, so "" is the ordinary unpaired state and not a fault.
        XCTAssertNil(DeviceReconnectRules.target(from: ""))
        XCTAssertNil(DeviceReconnectRules.target(from: nil))
    }

    func testAMalformedUUIDIsNotGuessedAt() {
        // `paired` true beside an unparseable uuid is a half-landed write or a hand-edited database. There is no device
        // here, and scanning for ever for one nothing could connect to is worse than saying so.
        XCTAssertNil(DeviceReconnectRules.target(from: "not-a-uuid"))
        XCTAssertNil(DeviceReconnectRules.target(from: "6B29FC40-CA47-1067-B31D"))
    }
}

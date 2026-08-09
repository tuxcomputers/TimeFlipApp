@testable import TimeFlipApp
import XCTest

/// The rule deciding when a launch stops chasing an unreachable cube and asks instead.
///
/// Every edge here is one a person would otherwise have to reproduce by walking away from their
/// desk with the cube in a bag: three failures in a row, a retry that buys a fresh round, and the
/// point after which the offer must never appear again for that session.
final class ManualModeOfferTests: XCTestCase {
    func testItKeepsTryingUntilTheThresholdAndThenAsks() {
        var offer = ManualModeOffer(promptAfterAttempts: 3)

        XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
        XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
        XCTAssertEqual(
            offer.recordFailedAttempt(), .offerManualMode,
            "the third failure is the one that stops the retries"
        )
    }

    func testRetryBuysAnotherFullRound() {
        var offer = ManualModeOffer(promptAfterAttempts: 3)
        _ = offer.recordFailedAttempt()
        _ = offer.recordFailedAttempt()
        _ = offer.recordFailedAttempt()

        offer.retryChosen()

        // Not one more attempt and straight back to the dialog: the count starts over, so a user
        // who keeps choosing Retry gets the same patience every time rather than a shrinking one.
        XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
        XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
        XCTAssertEqual(offer.recordFailedAttempt(), .offerManualMode)
    }

    func testTheLoopHasNoLimit() {
        var offer = ManualModeOffer(promptAfterAttempts: 2)

        for round in 1...25 {
            XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying, "round \(round)")
            XCTAssertEqual(offer.recordFailedAttempt(), .offerManualMode, "round \(round)")
            offer.retryChosen()
        }
    }

    func testOnceConnectedItNeverAsksAgain() {
        // The whole point of the offer being a startup thing: losing the cube mid-session is a
        // different situation from not having it, and gets today's silent indefinite reconnect.
        var offer = ManualModeOffer(promptAfterAttempts: 3)
        _ = offer.recordFailedAttempt()

        offer.recordConnected()

        for _ in 1...10 {
            XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
        }
        XCTAssertTrue(offer.hasConnectedThisLaunch)
    }

    func testConnectingClearsAPartialCountRatherThanLeavingItToCarryOver() {
        // A connect on the second attempt must not leave one failure banked, or a much later drop
        // would sit one failure away from a threshold it should no longer be near.
        var offer = ManualModeOffer(promptAfterAttempts: 3)
        _ = offer.recordFailedAttempt()
        _ = offer.recordFailedAttempt()

        offer.recordConnected()

        XCTAssertEqual(offer.failedAttempts, 0)
    }

    func testAThresholdOfOneAsksOnTheFirstFailure() {
        var offer = ManualModeOffer(promptAfterAttempts: 1)

        XCTAssertEqual(offer.recordFailedAttempt(), .offerManualMode)
    }

    func testAZeroThresholdIsFlooredRatherThanAskingBeforeAnyAttempt() {
        // The setting loader clamps to 1-20, so this can only arrive from a caller that skipped it.
        // Flooring here means the worst case is an eager offer, not one raised before the app has
        // tried at all.
        var offer = ManualModeOffer(promptAfterAttempts: 0)

        XCTAssertEqual(offer.failedAttempts, 0)
        XCTAssertEqual(offer.recordFailedAttempt(), .offerManualMode)
    }
}

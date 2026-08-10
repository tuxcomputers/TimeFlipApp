@testable import TimeFlipApp
import XCTest

/// When a failed attempt on the paired device raises the retry-or-manual-mode offer, and when it is
/// retried quietly instead.
final class ManualModeOfferTests: XCTestCase {

    func testTheFirstFailureAsks() {
        // One scan is the whole attempt. There used to be a threshold here, from a `manual_mode`
        // setting, and it bought nothing: each round is the same scan over the same airspace, so
        // three of them find the same nothing three times while somebody watches an app that looks
        // like it is doing something. Retry is one click and is the same wait, chosen deliberately.
        var offer = ManualModeOffer()
        XCTAssertEqual(offer.recordFailedAttempt(), .offerManualMode)
    }

    func testItKeepsAskingForAsLongAsTheDeviceIsMissing() {
        // Retry has no limit: the loop runs until the device answers or manual mode is picked. Each
        // failure after a retry is another first failure, because nothing has connected yet.
        var offer = ManualModeOffer()
        for round in 1...5 {
            XCTAssertEqual(offer.recordFailedAttempt(), .offerManualMode, "round \(round)")
        }
    }

    // MARK: - Startup only

    func testOnceConnectedItNeverAsksAgain() {
        // Losing the cube mid-session is a different situation from never having had it: the app
        // knows the device is real and reachable, so it reconnects on the backoff indefinitely
        // rather than putting a dialog in front of someone who has walked away from their desk.
        var offer = ManualModeOffer()
        offer.recordConnected()
        for drop in 1...10 {
            XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying, "drop \(drop)")
        }
    }

    func testConnectingAfterAFailedRoundStillSettlesIt() {
        // The order that matters: asked, retried, connected. From there it is a settled session.
        var offer = ManualModeOffer()
        XCTAssertEqual(offer.recordFailedAttempt(), .offerManualMode)
        offer.recordConnected()
        XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
    }

    func testHasConnectedIsOneWay() {
        // Nothing sets it back, which is what makes the offer a startup-only thing rather than
        // something a long enough outage could bring back mid-session.
        var offer = ManualModeOffer()
        XCTAssertFalse(offer.hasConnectedThisLaunch)
        offer.recordConnected()
        _ = offer.recordFailedAttempt()
        XCTAssertTrue(offer.hasConnectedThisLaunch)
    }
}

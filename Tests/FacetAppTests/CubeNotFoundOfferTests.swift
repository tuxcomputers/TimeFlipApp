@testable import FacetApp
import XCTest

/// Covers when a failed attempt on the paired cube is put to the user, and when it is retried quietly.
///
/// **Worth testing away from the loop it drives**, which is the reason the rule is a struct rather than two lines
/// inside `DeviceReconnector`: every case here is a sequence of events, and reproducing them through the real loop
/// would need a radio, a run loop and ten seconds of waiting for each one.
final class CubeNotFoundOfferTests: XCTestCase {
    func testTheFirstFailureAsks() {
        // One attempt, and if the cube did not answer it, say so. The archive counted failures before asking and it
        // bought nothing: each round is the same scan over the same airspace, so three of them find the same nothing
        // three times while somebody watches an app that appears to be doing something.
        var offer = CubeNotFoundOffer()

        XCTAssertEqual(offer.recordFailedAttempt(), .ask)
    }

    func testItKeepsAskingUntilTheCubeIsReached() {
        // Retry is one more attempt, and the offer again if that finds nothing too. No limit, deliberately: each
        // answer is somebody deciding to wait again rather than the app deciding for them.
        var offer = CubeNotFoundOffer()

        XCTAssertEqual(offer.recordFailedAttempt(), .ask)
        XCTAssertEqual(offer.recordFailedAttempt(), .ask)
        XCTAssertEqual(offer.recordFailedAttempt(), .ask)
    }

    func testOnceTheCubeHasBeenReachedFailuresAreQuiet() {
        // The startup-only half of the rule. Losing a cube mid-session is a different situation from never having had
        // one: somebody who walked away from a working app must not come back to a dialog.
        var offer = CubeNotFoundOffer()
        offer.recordConnected()

        XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
    }

    func testReachingTheCubeSettlesItForTheWholeLaunch() {
        // One-way, which is what "startup only" means: an hour of drops later, it is still not asking.
        var offer = CubeNotFoundOffer()
        XCTAssertEqual(offer.recordFailedAttempt(), .ask, "precondition: it asks before anything is reached")

        offer.recordConnected()

        for _ in 0..<5 {
            XCTAssertEqual(offer.recordFailedAttempt(), .keepTrying)
        }
        XCTAssertTrue(offer.hasReachedCube)
    }

    func testNothingIsReachedUntilSomethingSaysSo() {
        XCTAssertFalse(CubeNotFoundOffer().hasReachedCube)
    }

    // MARK: - why it gave up

    func testNothingAnsweringReadsAsNothingAnswering() {
        XCTAssertEqual(CubeNotFoundOffer.reason(for: .unreachable), "nothing answered")
    }

    func testACubeThatWasFoundIsNotDescribedAsMissing() {
        // The distinction the archive got wrong twice, and the reason this is derived from the outcome rather than
        // passed in at a call site: "nothing was in range" and "it was right there and refused this app's PIN" are
        // different problems with different fixes, and the log line is where somebody looks first.
        for outcome in [DeviceLoginOutcome.wrongPIN, .newPINRefused, .timedOut] {
            XCTAssertTrue(
                CubeNotFoundOffer.reason(for: outcome).contains("cube"),
                "\(outcome) means the cube answered, so the reason must not read as an empty room"
            )
            XCTAssertNotEqual(CubeNotFoundOffer.reason(for: outcome), CubeNotFoundOffer.reason(for: .unreachable))
        }
    }

    func testEveryOutcomeHasSomethingToSay() {
        // A reason nobody wrote would be an empty parenthesis in the one line explaining why the app gave up.
        for outcome in [
            DeviceLoginOutcome.unreachable, .wrongPIN, .newPINRefused, .notATimeFlip, .timedOut, .loggedIn,
        ] {
            XCTAssertFalse(CubeNotFoundOffer.reason(for: outcome).isEmpty)
        }
    }

    // MARK: - one dialog, whatever the reason

    @MainActor
    func testTheOfferSaysTheSameThingWhateverTheReason() {
        // **The situation a person is in is the same in every case**: their cube is not usable, and they have to
        // decide whether to keep waiting for it. The distinctions the app can draw are about the radio.
        //
        // The guarantee is structural rather than a matter of keeping strings in step: `CubeNotFoundAlert.ask` takes no
        // reason at all, so there is nothing for a reason to vary. This pins the text it does use.
        XCTAssertEqual(CubeNotFoundAlert.messageText, "Unable to find your device")
        XCTAssertTrue(CubeNotFoundAlert.informativeText.hasPrefix("No TimeFlip answered:"))
    }

    @MainActor
    func testTheOfferNamesTheWayToTimingByHand() {
        // **A restart on its own comes straight back to this dialog**, the app still being paired and still unable to
        // find anything. The answer does not switch the running app either, so the text has to name what does --
        // forgetting the device, which is the whole of it now and takes effect without a relaunch.
        XCTAssertTrue(CubeNotFoundAlert.informativeText.contains("forget the device"), CubeNotFoundAlert.informativeText)
        XCTAssertFalse(
            CubeNotFoundAlert.informativeText.contains("Manual mode lets you"),
            "the offer no longer switches the running launch, so it must not read as though it does"
        )
    }

    @MainActor
    func testTheOfferDoesNotClaimTheCubeItFoundWasYours() {
        // **A cube that answers and refuses this app's PIN is very often not the user's at all** -- a colleague's on
        // the next desk, found because it is a TimeFlip in range, on the morning theirs was left at home. "Your
        // TimeFlip would not accept this app's PIN" asserts both that it was theirs and that theirs refused them, and
        // sends somebody hunting a PIN problem they do not have.
        let text = CubeNotFoundAlert.informativeText
        XCTAssertFalse(text.contains("Your TimeFlip"), text)
        XCTAssertFalse(text.contains("it would not accept"), text)
        XCTAssertTrue(text.contains("none of the ones found"), "the archive's wording names no device")
    }

    func testTheReasonIsStillDerivedForTheLog() {
        // Kept apart rather than dropped: it is a diagnosis, and "nothing was in range" and "it was right there and
        // refused" are different problems with different fixes. It reaches `debug_log` and nothing else.
        XCTAssertEqual(CubeNotFoundOffer.reason(for: .unreachable), "nothing answered")
        XCTAssertEqual(
            CubeNotFoundOffer.reason(for: .wrongPIN),
            "the cube was found and refused the PIN this app has"
        )
    }
}

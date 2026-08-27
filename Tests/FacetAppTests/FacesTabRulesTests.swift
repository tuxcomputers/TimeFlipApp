@testable import FacetApp
import XCTest

/// What a click on a category row does, and therefore whether the row is drawn live.
///
/// **The one answer two things read.** The Faces tab draws the list from it and the click acts on it, which is the
/// arrangement the archive had and this app was missing: a locked face refused a click and nothing on screen said so,
/// because only the click knew. Every case below is therefore two claims at once -- what happens, and what the list
/// looks like while it is true.
final class FacesTabRulesTests: XCTestCase {
    // MARK: - following a cube

    func testAnUnlockedFaceTakesTheCategory() {
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: 5, isFaceLocked: false, isManualMode: false),
            .assignToFace(5)
        )
    }

    func testALockedFaceKeepsWhatItHas() {
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: 5, isFaceLocked: true, isManualMode: false),
            .faceIsLocked(5)
        )
    }

    func testACubeWinsEvenWhileTimingByHand() {
        // Not reachable today -- the readout answers no face while timing by hand -- but the order is the one the tab
        // draws with, and a rule that disagreed with the picture would put the click somewhere nobody was looking.
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: 5, isFaceLocked: false, isManualMode: true),
            .assignToFace(5)
        )
    }

    // MARK: - no cube being followed

    func testTimingByHandStartsTheClock() {
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: nil, isFaceLocked: false, isManualMode: true),
            .startTiming
        )
    }

    func testAPairedAppThatIsNotTimingByHandIsStillLooking() {
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: nil, isFaceLocked: false, isManualMode: false),
            .waitingForTheDevice
        )
    }

    func testALockMeansNothingWithNoFaceToLock() {
        // `isFaceLocked` is about the face on show, so with none it has nothing to say. Pinned because the two
        // arguments arrive together from one reading and it would be easy to let a stale lock decide something.
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: nil, isFaceLocked: true, isManualMode: true),
            .startTiming
        )
    }

    // MARK: - what the list is drawn from

    func testTheTwoThatDoSomethingAreTheTwoThatDrawLive() {
        XCTAssertTrue(FacesTabRules.Click.assignToFace(5).doesAnything)
        XCTAssertTrue(FacesTabRules.Click.startTiming.doesAnything)
    }

    func testBothRefusalsDrawDead() {
        // The whole reason this is a value rather than two conditions: a refusal nobody can see reads as a list that
        // has stopped responding, which is what a locked face actually looked like on hardware.
        XCTAssertFalse(FacesTabRules.Click.faceIsLocked(5).doesAnything)
        XCTAssertFalse(FacesTabRules.Click.waitingForTheDevice.doesAnything)
    }

    // MARK: - the lock itself

    func testOnlyACubesFaceHasALock() {
        XCTAssertTrue(FacesTabRules.showsLock(cubeFace: 5))
    }

    func testManualModeHasNoLockToOffer() {
        // Its face is meant to be reassigned -- every category picked lands on it -- so a lock could only get in the
        // way of the one gesture the tab has. Hidden rather than shown open, which is the archive's choice too.
        XCTAssertFalse(FacesTabRules.showsLock(cubeFace: nil))
    }

    // MARK: - a cube that cannot be reached

    func testAFaceStillDrawnForAQuietCubeRefusesTheClick() {
        // **The regression this exists for.** Letting a paired cube keep its face after the link dropped -- so the
        // tab has the cube's own last word to draw instead of tearing down -- turned a refused click into an
        // assignment to a device nobody can hear. The face is worth showing; sending to it is not something the app
        // can carry out.
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: 5, isFaceLocked: false, isManualMode: false, isCubeConnected: false),
            .waitingForTheDevice
        )
    }

    func testAQuietCubeIsRefusedEvenWhereALockWouldHaveBeenReported() {
        // The lock is a fact about a face on a cube the app cannot ask, so it is not the reason to give: not being
        // able to reach it comes first, and answering `faceIsLocked` would explain the refusal with the wrong cause.
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: 5, isFaceLocked: true, isManualMode: false, isCubeConnected: false),
            .waitingForTheDevice
        )
    }

    func testAQuietCubeDoesNotStartTheAppsClockUnlessTimingByHand() {
        // Manual mode is still what decides that, and it is unchanged: a cube that has gone quiet is not somebody
        // having said to get on without it.
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: 5, isFaceLocked: false, isManualMode: true, isCubeConnected: false),
            .startTiming
        )
    }

    func testAReachableCubeIsUnaffected() {
        // The ordinary case, spelled out so the new parameter's default cannot quietly change it.
        XCTAssertEqual(
            FacesTabRules.click(cubeFace: 5, isFaceLocked: false, isManualMode: false),
            .assignToFace(5)
        )
    }
}

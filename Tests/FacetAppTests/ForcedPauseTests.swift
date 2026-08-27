@testable import FacetApp
import XCTest

/// Stopping the cube on a face with no category, and starting it again when the face is given one.
///
/// **Every one of these runs without a radio**, which is the point of the split: the decision is
/// `ForcedPause` and the sending is somebody else's, so every awkward sequence is reachable here -- the
/// flip that lifts the pause in firmware, a hand-pause that must not be claimed, a hand-resume on a face that still
/// has no category, and a daily limit holding the same cube.
///
/// **No archive to carry over from.** The previous app never connected a face's category to the cube's clock: it
/// paused on quit and on lock and nowhere else. These cases are written from the rule rather than inherited.
final class ForcedPauseTests: XCTestCase {
    private let unassigned = false
    private let assigned = true

    /// A cube that is connected, unlocked, and has no daily limit against it -- the ordinary bench. Each test names
    /// only what it is actually about.
    private func evaluate(
        _ subject: inout ForcedPause,
        face: Int?,
        hasCategory: Bool,
        isPaused: Bool,
        isLocked: Bool? = false,
        isConnected: Bool = true,
        limitIsHolding: Bool = false
    ) -> ForcedPauseAction {
        subject.evaluate(
            face: face,
            hasCategory: hasCategory,
            isPaused: isPaused,
            isLocked: isLocked,
            isConnected: isConnected,
            limitIsHolding: limitIsHolding
        )
    }

    // MARK: - the pause

    func testACountingCubeOnAFaceWithNoCategoryIsStopped() {
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false), .pause)
    }

    func testACountingCubeOnAFaceWithACategoryIsLeftAlone() {
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 2, hasCategory: assigned, isPaused: false), .none)
    }

    func testAnAlreadyStoppedCubeIsNotStoppedAgain() {
        // The frame after the pause reports the cube stopped on the same unassigned face. Sending `0x06 0x01` again
        // would be a command per history fetch for as long as it sits there.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false), .pause)
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: true), .none)
    }

    func testThePauseIsNotClaimedUntilTheCubeConfirmsIt() {
        // `.pause` is the ask; `pauseTook` is the answer. A command that was refused leaves nothing claimed, so the
        // category assigned next does not lift a pause that was never placed.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false), .pause)
        XCTAssertFalse(subject.isHoldingAPause)
        subject.pauseTook(onFace: 5)
        XCTAssertTrue(subject.isHoldingAPause)
    }

    // MARK: - the resume, which is only ever for a pause that survives

    func testGivingTheFaceACategoryStartsTheCubeAgain() {
        // The case the feature is for: the cube sits stopped on face 5, somebody assigns a category to face 5 on the
        // Faces tab, and nothing physical has happened that would lift the pause.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false), .pause)
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true), .resume)
    }

    func testTheClaimIsGivenUpOnceTheResumeIsConfirmed() {
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true), .resume)
        subject.resumeTook()
        XCTAssertFalse(subject.isHoldingAPause)
        // And it is not issued twice: the cube is running by the time the next frame arrives.
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: false), .none)
    }

    func testARefusedResumeIsTriedAgainRatherThanStrandingTheCube() {
        // The claim is held until the cube confirms. Given up at the moment `.resume` was decided, a refused resume
        // would leave a stopped cube nobody claimed: a face with a category, no claim, `.none`, and stopped for good.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true), .resume)
        // The command was refused, so nothing confirms it and the cube is still stopped.
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true), .resume)
        XCTAssertTrue(subject.isHoldingAPause)
    }

    func testAFlipOntoAnAssignedFaceNeedsNoCommandBecauseTheFirmwareLiftsIt() {
        // Measured 2026-08-12: a flip always resumes the cube. So the frame after the turn reports it already
        // running, and there is nothing to send.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 2, hasCategory: assigned, isPaused: false), .none)
        XCTAssertFalse(subject.isHoldingAPause)
    }

    func testAFlipOntoAnotherUnassignedFaceIsStoppedAgain() {
        // The firmware lifts the pause on the turn and the new face is no more attributable than the last, so it
        // stops again -- on the new face, which is the one a later category would lift it from.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 9, hasCategory: unassigned, isPaused: false), .pause)
        subject.pauseTook(onFace: 9)
        XCTAssertEqual(evaluate(&subject, face: 9, hasCategory: assigned, isPaused: true), .resume)
    }

    func testAPauseOnAFaceThisAppNeverStoppedIsNotLifted() {
        // Somebody paused the cube by hand on a face that has a category. Assigning categories elsewhere, or anything
        // else that brings this back round, must not undo it: a Pause item that undoes itself is not one.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 2, hasCategory: assigned, isPaused: true), .none)
        XCTAssertFalse(subject.isHoldingAPause)
    }

    func testAPauseClaimedOnOneFaceDoesNotLiftOnAnother() {
        // A locked cube refuses a flip, so this is the shape a double tap plus a turn can leave: the claim names
        // face 5 and the cube reports itself stopped on face 2. That pause is not the one this type placed.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 2, hasCategory: assigned, isPaused: true), .none)
    }

    // MARK: - a hand-resume on a face that still has no category

    func testStartingTheCubeByHandOnAnUnassignedFaceStopsItAgain() {
        // A double tap pauses and unpauses in firmware with no app involvement, and the single click sends `0x06 0x02`
        // directly. Either way the frame reports the cube running on a face with no category, and the refusal is the
        // whole feature: time the app cannot attribute is time it will not record.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false), .pause)
    }

    // MARK: - what it will not touch

    func testALockedCubeIsLeftAlone() {
        // The status read answers `pause (0x01/0x02 unless locked)`, so a locked cube reports itself paused whatever
        // its pause byte says. Nothing sent here could be read back and believed.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false, isLocked: true), .none)
    }

    func testACubeNobodyHasAskedAboutIsLeftAlone() {
        // `nil` is "no answer yet", not "unlocked". Guessing the other way is guessing about the one state that makes
        // the pause byte lie.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false, isLocked: nil), .none)
    }

    func testALockedCubeKeepsTheClaimRatherThanDroppingIt() {
        // Locking says nothing about who stopped the cube, so the claim survives it and the resume still lands once
        // the lock is off.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        _ = evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true, isLocked: true)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true, isLocked: false), .resume)
    }

    func testNothingIsDecidedWithNoLink() {
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false, isConnected: false), .none)
    }

    func testAClaimDoesNotSurviveTheLinkGoingDown() {
        // The cube could be double tapped, have its batteries out or be driven by the vendor's app while it is out of
        // reach, so a pause claimed before the drop is not one this app can still say it placed.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true, isConnected: false), .none)
        XCTAssertFalse(subject.isHoldingAPause)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true), .none)
    }

    func testACubeWithNoOpenSegmentIsLeftAlone() {
        // Reset and not yet flipped: it has not said where it is, so there is nothing to attribute or refuse.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: nil, hasCategory: unassigned, isPaused: false), .none)
    }

    func testTheAppsOwnFacesAreNotTheCubes() {
        // 13 and 14 are manual mode's, seeded Unassigned and meant to be. There is no cube to stop.
        var subject = ForcedPause()
        XCTAssertEqual(evaluate(&subject, face: 13, hasCategory: unassigned, isPaused: false), .none)
        XCTAssertEqual(evaluate(&subject, face: 14, hasCategory: unassigned, isPaused: false), .none)
    }

    // MARK: - the daily limit holds the same cube

    func testAPauseTheDailyLimitIsHoldingIsNotLifted() {
        // A hard limit has to win or it is not hard: lifting it by assigning a category would be a refusal with a way
        // round it.
        var subject = ForcedPause()
        subject.pauseTook(onFace: 5)
        XCTAssertEqual(
            evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true, limitIsHolding: true),
            .none
        )
        // And the claim is still there once the limit lets go, so the resume is not lost with it.
        XCTAssertTrue(subject.isHoldingAPause)
        XCTAssertEqual(evaluate(&subject, face: 5, hasCategory: assigned, isPaused: true), .resume)
    }

    func testTheLimitDoesNotStopTheCubeBeingStopped() {
        // `.pause` needs no guard: a cube already stopped is answered `.none` whoever stopped it, so the only cube
        // this can reach is one that is running.
        var subject = ForcedPause()
        XCTAssertEqual(
            evaluate(&subject, face: 5, hasCategory: unassigned, isPaused: false, limitIsHolding: true),
            .pause
        )
    }
}

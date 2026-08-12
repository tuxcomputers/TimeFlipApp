@testable import TimeFlipApp
import XCTest

/// The play/pause control on the Faces tab in manual mode: which of the three states it is in, what
/// it draws, and when a click on it means anything.
final class ManualTimerRulesTests: XCTestCase {
    private let manualFace = TimeFlipConstants.manualFaceID

    // MARK: - State

    func testNoFaceYetIsIdle() {
        // What manual mode looks like the moment it starts: the virtual device has no session, so
        // the app has no face, and nothing is being timed.
        XCTAssertEqual(ManualTimerRules.state(currentFaceID: TimeFlipConstants.unassignedFaceID, isPaused: true), .idle)
        XCTAssertEqual(ManualTimerRules.state(currentFaceID: TimeFlipConstants.unassignedFaceID, isPaused: false), .idle)
    }

    func testTheManualFaceRunningOrPaused() {
        XCTAssertEqual(ManualTimerRules.state(currentFaceID: manualFace, isPaused: false), .running)
        XCTAssertEqual(ManualTimerRules.state(currentFaceID: manualFace, isPaused: true), .paused)
    }

    func testARealCubeFaceIsNotThisControl() {
        // Belt and braces: this control is only ever drawn in manual mode, but the face it answers
        // for is 13 alone. A cube face arriving here is somebody else's state.
        for faceID in TimeFlipConstants.faceIDs {
            XCTAssertEqual(ManualTimerRules.state(currentFaceID: faceID, isPaused: false), .idle, "face \(faceID)")
        }
    }

    // MARK: - What it draws

    func testIdleDrawsNothingOnTheFace() {
        // The requirement in as many words: in manual mode the centre of the device starts empty.
        XCTAssertEqual(ManualTimerRules.centre(for: .idle), .empty)
    }

    func testRunningShowsPlayAndPausedShowsPause() {
        // The icons report state rather than offering an action -- play showing means time is being
        // recorded. Pinned because it is the opposite of a media player and reads as a bug otherwise.
        XCTAssertEqual(ManualTimerRules.centre(for: .running), .symbol("play.fill"))
        XCTAssertEqual(ManualTimerRules.centre(for: .paused), .symbol("pause.fill"))
    }

    func testTheThreeStatesNeverDrawTheSameThing() {
        let drawn = [ManualTimerState.idle, .running, .paused].map(ManualTimerRules.centre(for:))
        XCTAssertEqual(Set(drawn.map(String.init(describing:))).count, 3)
    }

    // MARK: - Clicking it

    func testAnEmptyFaceIsNotAButton() {
        // There is no timer to stop, and a click on a blank face names no category to start.
        XCTAssertFalse(ManualTimerRules.isCentreClickable(.idle))
    }

    func testBothRunningAndPausedAreClickable() {
        XCTAssertTrue(ManualTimerRules.isCentreClickable(.running))
        XCTAssertTrue(ManualTimerRules.isCentreClickable(.paused))
    }
}

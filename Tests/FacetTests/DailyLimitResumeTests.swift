@testable import FacetCore
import Foundation
import Testing

/// Covers `DailyLimitEnforcement.isResumeRefused`, and the four surfaces that ask it.
///
/// **The arithmetic is not what this tests, and was never the risk.** `isLimitReached` is three lines with 274
/// lines of tests behind it in `DailyLimitEnforcementTests`, and the live bypass on 2026-08-27 did not touch it.
/// What was wrong was which paths ask: the router and the menu consulted `ManualTimerRules.isClickable`, which
/// answers about this app's own clock, and a cube leaves that `.idle` however busy it is. So every cube click fell
/// straight past the only place the limit was consulted, and a second path was found the same day, a lock followed
/// by an unlock.
///
/// **So what is tested here is agreement.** `state-reference.md` said of this fact that naming it "does not merge
/// them; it makes the fact that they have to agree visible". Candidate 4 merged them, and these are what stop them
/// coming apart again.
@Suite @MainActor
struct DailyLimitResumeTests {
    // MARK: - the rule itself

    @Test("A resume is refused only when the budget is spent")
    func theTruthTable() {
        #expect(DailyLimitEnforcement.isResumeRefused(isLimitReached: true, isResuming: true))
        #expect(DailyLimitEnforcement.isResumeRefused(isLimitReached: true, isResuming: false) == false)
        #expect(DailyLimitEnforcement.isResumeRefused(isLimitReached: false, isResuming: true) == false)
        #expect(DailyLimitEnforcement.isResumeRefused(isLimitReached: false, isResuming: false) == false)
    }

    @Test("Pausing is never refused, whatever the budget says")
    func pausingIsNeverRefused() {
        // The asymmetry the whole feature turns on: a limit that trapped somebody into recording time would be the
        // opposite of what it is for. Stopping stays available at every surface, always.
        #expect(DailyLimitEnforcement.isResumeRefused(isLimitReached: true, isResuming: false) == false)

        #expect(ManualTimerRules.isClickable(.running, isLimitReached: true))
        #expect(
            PauseMenuRules.target(
                timingState: .idle,
                isCubeConnected: true,
                cubeLockState: .unlocked,
                cubePauseState: .running,
                isLimitReached: true
            ) == .cube
        )
        #expect(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                cubePauseState: .running,
                isLimitReached: true
            ) == .toggleCubePause
        )
    }

    // MARK: - the four surfaces agree

    @Test("With the budget spent and the cube stopped, every surface refuses to start it")
    func everySurfaceRefusesTheCubesResume() {
        // **Asked together on purpose.** Each of these was a separate expression in a separate file, and two of them
        // did not exist until a spent budget was bypassed on a live cube. Asserting them one suite at a time is what
        // let them disagree; this is the assertion that they cannot.
        #expect(
            PauseMenuRules.target(
                timingState: .idle,
                isCubeConnected: true,
                cubeLockState: .unlocked,
                cubePauseState: .paused,
                isLimitReached: true
            ) == .nothing
        )
        #expect(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                cubePauseState: .paused,
                isLimitReached: true
            ) == .ignore
        )
    }

    @Test("With the budget spent and a manual session stopped, the app's own clock refuses too")
    func theAppsOwnClockRefusesItsResume() {
        #expect(ManualTimerRules.isClickable(.paused, isLimitReached: true) == false)

        // And the two cube surfaces route to the app's clock rather than the cube while a session exists, so the
        // same refusal has to hold through them.
        #expect(
            PauseMenuRules.target(
                timingState: .paused,
                isCubeConnected: true,
                cubeLockState: .unlocked,
                cubePauseState: .running,
                isLimitReached: true
            ) == .nothing
        )
        #expect(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .paused,
                isCubeConnected: true,
                cubePauseState: .running,
                isLimitReached: true
            ) == .ignore
        )
    }

    @Test("With budget left, every surface allows the resume it refused a moment ago")
    func withBudgetLeftEverySurfaceAllowsIt() {
        // The mirror of the two above, so a rule that refused everything would fail rather than look correct.
        #expect(ManualTimerRules.isClickable(.paused, isLimitReached: false))
        #expect(
            PauseMenuRules.target(
                timingState: .idle,
                isCubeConnected: true,
                cubeLockState: .unlocked,
                cubePauseState: .paused,
                isLimitReached: false
            ) == .cube
        )
        #expect(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                cubePauseState: .paused,
                isLimitReached: false
            ) == .toggleCubePause
        )
    }

    // MARK: - the gesture that was the way round it

    @Test("Unlocking stays available with the budget spent, and does not start the cube")
    func unlockingIsNotRefused() {
        // **The 2026-08-27 second finding.** Locking and unlocking was the way round the limit, because `resume`
        // unlocks and then starts. Refusing the unlock is not the fix: it would strand the cube in the one state
        // this app cannot otherwise get it out of. The gesture stays, and it leaves the cube stopped.
        #expect(
            StatusItemClickRouter.action(
                isLeftSide: false,
                timingState: .idle,
                isCubeConnected: true,
                cubePauseState: .paused,
                isLimitReached: true,
                clickCount: 2
            ) == .toggleCubeLock
        )
    }
}

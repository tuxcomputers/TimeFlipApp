@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 03: a locked device refuses flips, and nothing reaches the database
///
/// **Preconditions:** connected, authenticated, notifications on, unlocked, and one open segment
/// established. Step 1 builds that rather than assuming it, so this workflow stands alone.
///
/// **What it converts:** `Tests/Interactive/04i-lock-and-pause-on-lock-checklist.md` Scenario A -- "the
/// device refuses a physical flip while locked" -- which is a `**(You)**` step today, needing a person
/// to pick the cube up and turn it. The mock implements the same refusal (`flip` returns early with
/// `flip_ignored_locked` when `state.isLocked`), so the *consequence* being checked -- no new segment,
/// no new `device_event` row, the timed segment carrying on undisturbed -- is fully checkable in CI.
///
/// It also covers `Tests/Bench/04b` Scenario E's substance: that while locked, the things that would
/// normally change state are no-ops rather than errors.
///
/// What this deliberately does **not** claim to cover: that the physical cube's own firmware refuses
/// the flip. That is a property of the hardware, not of this app, and only a real cube on a real desk
/// can demonstrate it. `04i` Scenario A should stay in the interactive suite for that reason -- this
/// workflow removes the need to re-check the *app's* half of it, not the device's.
@Suite(.serialized)
@MainActor
struct W03LockBlocksFlipsWorkflow {
    private var harness: WorkflowHarness { .shared("03-lock-blocks-flips") }

    @Test func step1_reachesAConnectedUnlockedStateWithOneOpenSegment() async throws {
        try await harness.step("1-preconditions") {
            try await harness.connect()
            harness.flip(to: 3, atSecondsFromBase: 30)
            await harness.ingestHistory(trigger: "startup")

            try #require(harness.openEventCount() == 1, "one segment should be in progress")
            let locked = await harness.device.refreshLockState()
            try #require(locked == false, "the device should start unlocked")
        }
    }

    @Test func step2_locksTheDevice() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-lock") {
            await harness.device.setLock(true)
            let locked = await harness.device.refreshLockState()
            try #require(locked, "the device should now report locked")
        }
    }

    @Test func step3_aFlipWhileLockedIsRefusedAndAddsNothing() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-flip-refused") {
            let deviceSegmentsBefore = harness.deviceHistoryEventNumbers()
            let storedBefore = harness.storedEventNumbers()
            let openBefore = harness.openEventNumber()

            harness.flip(to: 7, atSecondsFromBase: 90)
            await harness.ingestHistory(trigger: "face_change")

            try #require(
                harness.deviceHistoryEventNumbers() == deviceSegmentsBefore,
                "a locked device must not record a new segment"
            )
            #expect(harness.storedEventNumbers() == storedBefore, "so nothing new can reach the DB")
            #expect(harness.openEventCount() == 1, "and the open segment count is unchanged")
            #expect(harness.openEventNumber() == openBefore, "with the same segment still in progress")
        }
    }

    @Test func step4_theSegmentThatWasAlreadyRunningKeepsRunning() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-open-segment-undisturbed") {
            // The refused flip must not have closed off the segment that was already being timed.
            let open = try #require(harness.openEventNumber(), "a segment should still be open")
            let newest = try #require(harness.storedEventNumbers().last, "there should be stored events")
            #expect(Int64(newest) == open, "the open segment is still the newest row")
        }
    }

    @Test func step5_unlockingLetsFlipsThroughAgain() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-unlock-restores-flips") {
            await harness.device.setLock(false)
            let locked = await harness.device.refreshLockState()
            try #require(locked == false, "the device should report unlocked")

            let deviceSegmentsBefore = harness.deviceHistoryEventNumbers().count
            harness.flip(to: 7, atSecondsFromBase: 150)
            await harness.ingestHistory(trigger: "face_change")

            #expect(
                harness.deviceHistoryEventNumbers().count > deviceSegmentsBefore,
                "an unlocked device should record the flip that was refused while locked"
            )
            #expect(harness.openEventCount() == 1, "still exactly one segment in progress")
        }
    }
}

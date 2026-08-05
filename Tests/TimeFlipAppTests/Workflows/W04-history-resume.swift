@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 04: a relaunch resumes from the position derived from `device_event`
///
/// **Preconditions:** connected and authenticated, with a few committed segments and one open segment
/// already in the database. Step 1 builds that.
///
/// **What it converts:** `Tests/Bench/01b-history-refresh-checklist.md`, both scenarios:
///
///  - Scenario A, "nothing changes (skip path + duration refresh)": when the device's last event
///    number matches what the app already knows, the fetch takes the cheap path and commits nothing
///    new. Steps 2 and 3.
///  - Scenario B, "quit and relaunch resumes from the position derived from `device_event`": the
///    in-memory cursor is gone after a restart, so the resume position has to come back off the disk,
///    and it must not re-ingest what is already stored or skip what isn't. Steps 4 to 6.
///
/// `01b` drives that by genuinely quitting and relaunching the app and waiting on BLE reconnects, which
/// takes minutes of a run. Here a relaunch is a fresh `HistoryIngestor` against the same database --
/// the thing under test is the cursor derivation, and that is entirely app-side.
///
/// The bench file's own value that this does *not* replace: proving the real device's event counter
/// behaves as assumed, and that a real reconnect actually re-fetches. Those need hardware.
@Suite(.serialized)
@MainActor
struct W04HistoryResumeWorkflow {
    private var harness: WorkflowHarness { .shared("04-history-resume") }

    @Test func step1_buildsABacklogAndOneOpenSegment() async throws {
        try await harness.step("1-preconditions") {
            try await harness.connect()
            harness.flip(to: 2, atSecondsFromBase: 30)
            harness.flip(to: 4, atSecondsFromBase: 90)
            harness.flip(to: 6, atSecondsFromBase: 150)
            await harness.ingestHistory(trigger: "startup")

            try #require(harness.storedEventCount() >= 3, "the backlog should be stored")
            try #require(harness.openEventCount() == 1, "with one segment in progress")
        }
    }

    @Test func step2_aRefetchWithNothingNewCommitsNothing() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-cheap-skip-path") {
            let before = harness.storedEventNumbers()
            let committedBefore = harness.dataStore.latestRecordedEvent()?.eventNumber

            await harness.ingestHistory(trigger: "test")

            #expect(harness.storedEventNumbers() == before, "no new rows when the device has nothing new")
            #expect(
                harness.dataStore.latestRecordedEvent()?.eventNumber == committedBefore,
                "and the committed cursor should not move"
            )
        }
    }

    @Test func step3_repeatedRefetchesStayStable() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-repeat-refetch") {
            let before = harness.storedEventNumbers()
            for _ in 0..<3 {
                await harness.ingestHistory(trigger: "test")
            }
            #expect(harness.storedEventNumbers() == before, "three more fetches should change nothing")
            #expect(harness.openEventCount() == 1, "and must not open a second segment")
        }
    }

    @Test func step4_relaunchingDropsTheInMemoryCursor() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-relaunch") {
            let storedBefore = harness.storedEventNumbers()
            let committedBefore = harness.dataStore.latestRecordedEvent()?.eventNumber
            try #require(committedBefore != nil, "there should be a committed cursor on disk to resume from")

            harness.simulateRelaunch()
            await harness.ingestHistory(trigger: "startup")

            #expect(
                harness.storedEventNumbers() == storedBefore,
                "a relaunch must re-derive the position from device_event, not re-ingest the backlog"
            )
            #expect(harness.openEventCount() == 1, "and must not leave two segments open")
        }
    }

    @Test func step5_segmentsAddedWhileTheAppWasDownStillLand() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-missed-while-down") {
            let storedBefore = harness.storedEventCount()

            // Two more segments while nothing is listening, then a relaunch.
            harness.flip(to: 8, atSecondsFromBase: 210)
            harness.flip(to: 3, atSecondsFromBase: 270)
            harness.simulateRelaunch()
            await harness.ingestHistory(trigger: "startup")

            try #require(
                harness.storedEventCount() > storedBefore,
                "segments recorded while the app was down should be picked up after the relaunch"
            )
            let stored = harness.storedEventNumbers()
            #expect(Set(stored).count == stored.count, "and none of them stored twice")
            #expect(stored == stored.sorted(), "still in event-number order")
        }
    }

    @Test func step6_theResumePositionIsTheOpenSegmentAfterResuming() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("6-resume-position-is-open-segment") {
            #expect(harness.openEventCount() == 1, "exactly one segment in progress")

            let open = try #require(harness.openEventNumber(), "a segment should be open")
            let resume = harness.dataStore.latestRecordedEvent().map { Int64($0.eventNumber) }
            // This assertion used to be the opposite: the position had to differ from the open
            // segment, because it counted finalised rows only and the fetch added 1 to it to land
            // on the open one. The position is now the open segment itself and the fetch starts
            // there, which is the same request expressed without the indirection.
            #expect(
                resume == open,
                "the resume position is the still-growing segment, so the next fetch re-reads it and gets its updated duration"
            )
            let newest = try #require(harness.storedEventNumbers().last, "there should be stored events")
            #expect(Int64(newest) == open, "and the open segment is the newest row")
        }
    }
}

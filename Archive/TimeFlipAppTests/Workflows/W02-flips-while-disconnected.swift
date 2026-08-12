@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow: flips that happen while disconnected are backfilled on reconnect
///
/// **Preconditions:** a freshly created database with no `device_event` rows, and a paired but
/// not-yet-connected mock device sitting on face 1 with an empty history. Step 1 establishes and
/// asserts that rather than assuming it, the same rule the scripted checklists follow.
///
/// **What it covers:** the path a real cube takes when the app isn't listening. The device keeps
/// counting segments on its own; the app only finds out at the next `refreshHistory`. What has to
/// hold at the end is that every missed segment landed exactly once, in order, and exactly one row is
/// left open (`finalised = 0`) -- the segment still being timed.
///
/// Steps run in declaration order (`.serialized`) and share one `WorkflowHarness`, so the history
/// genuinely accumulates across them. Gating assertions use `try #require` so a failed step stops the
/// rest of the workflow instead of letting it run on false premises -- see `WorkflowHarness`.
@Suite(.serialized)
@MainActor
struct FlipsWhileDisconnectedWorkflowTests {
    private var harness: WorkflowHarness { .shared("flips-while-disconnected") }

    @Test func step1_startsFromAnEmptyDatabaseAndAnUnconnectedDevice() async throws {
        try await harness.step("1-preconditions") {
            try #require(harness.storedEventCount() == 0, "no device_event rows yet")
            try #require(harness.openEventCount() == 0, "nothing open yet")
            try #require(harness.device.history.isEmpty, "device history cleared of the mock's samples")
        }
    }

    @Test func step2_theDeviceRecordsSegmentsBeforeTheAppEverConnects() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-segments-before-connect") {
            harness.flip(to: 3, atSecondsFromBase: 30)
            harness.flip(to: 5, atSecondsFromBase: 90)

            try #require(harness.deviceHistoryEventNumbers().count == 2, "the device recorded both flips itself")
            try #require(harness.storedEventCount() == 0, "but nothing reached the DB -- the app never connected")
        }
    }

    @Test func step3_connectingIngestsThatBacklogAndLeavesOneSegmentOpen() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-connect-and-ingest") {
            try await harness.connect()
            await harness.ingestHistory(trigger: "startup")

            try #require(harness.storedEventCount() > 0, "connecting should have ingested the backlog")
            try #require(harness.openEventCount() == 1, "exactly one segment should be in progress")
        }
    }

    @Test func step4_aFlipWhileConnectedClosesThePreviousSegmentAndOpensANewOne() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-flip-while-connected") {
            let openBefore = harness.openEventNumber()
            let countBefore = harness.storedEventCount()

            harness.flip(to: 8, atSecondsFromBase: 150)
            await harness.ingestHistory(trigger: "face_change")

            try #require(harness.storedEventCount() > countBefore, "the flip should have added a segment")
            try #require(harness.openEventCount() == 1, "still exactly one open segment, not two")
            #expect(
                harness.openEventNumber() != openBefore,
                "the open segment should be the new one, not the segment the flip closed"
            )
        }
    }

    @Test func step5_disconnectsAndFlipsThreeTimesWithTheAppNotListening() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-flips-while-disconnected") {
            let storedBefore = harness.storedEventCount()
            let deviceBefore = harness.deviceHistoryEventNumbers().count
            await harness.device.disconnect()

            harness.flip(to: 2, atSecondsFromBase: 210)
            harness.flip(to: 6, atSecondsFromBase: 270)
            harness.flip(to: 4, atSecondsFromBase: 330)

            try #require(
                harness.deviceHistoryEventNumbers().count == deviceBefore + 3,
                "the device should have recorded all three itself"
            )
            try #require(
                harness.storedEventCount() == storedBefore,
                "disconnected flips must not appear in the DB until history is ingested"
            )
        }
    }

    @Test func step6_reconnectingBackfillsEveryMissedSegmentExactlyOnce() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("6-reconnect-and-backfill") {
            let storedBefore = harness.storedEventCount()
            try await harness.connect()
            await harness.ingestHistory(trigger: "startup")

            let stored = harness.storedEventNumbers()
            try #require(stored.count > storedBefore, "the backfill should have picked up the disconnected flips")
            #expect(stored == stored.sorted(), "events should be stored in event-number order")
            #expect(Set(stored).count == stored.count, "no event should be stored twice")
            // Every completed segment the device knows about should now be in the DB.
            let deviceCompleted = Set(harness.deviceHistoryEventNumbers())
            #expect(
                deviceCompleted.subtracting(Set(stored)).isEmpty,
                "every segment the device recorded should have landed"
            )
        }
    }

    @Test func step7_exactlyOneSegmentIsLeftOpenAndItIsTheNewest() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("7-one-open-segment") {
            try #require(harness.openEventCount() == 1, "exactly one segment may be in progress")

            let open = try #require(harness.openEventNumber(), "something should still be open")
            let newest = try #require(harness.storedEventNumbers().last, "there should be stored events")
            #expect(
                Int64(newest) == open,
                "the open segment must be the newest row, not an older one left unfinalised"
            )
            // And it is the resume position, so the next fetch asks for it again and picks up the
            // duration it finished on. (This asserted the opposite while the position counted
            // finalised rows only and the fetch added 1 to reach the open one.)
            #expect(
                harness.dataStore.latestRecordedEvent().map { Int64($0.eventNumber) } == open,
                "the open segment is where the next fetch resumes"
            )
        }
    }

    @Test func step8_reIngestingChangesNothing() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("8-idempotent-reingest") {
            let before = harness.storedEventNumbers()
            await harness.ingestHistory(trigger: "startup")

            #expect(harness.storedEventNumbers() == before, "a second ingest must not duplicate rows")
            #expect(harness.openEventCount() == 1, "and must not reopen a closed segment")
        }
    }
}

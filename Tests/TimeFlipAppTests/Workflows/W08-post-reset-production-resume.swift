@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 08: resuming against a database that never saw the factory reset
///
/// **Preconditions:** a database holding pre-reset history, as the *production* database does
/// after a normal week of use. Step 1 establishes that.
///
/// **What it covers:** the state the production database is left in by a device-test run. The
/// runner's end-of-run cleanup factory-resets the cube so the session's activity can't be
/// mistaken for real history, and re-pairs it. All of that happens while the app is pointed at
/// `test.sqlite`, so `production.sqlite` never records the reset -- it still ends at the high
/// event number it held beforehand, in one unbroken counter generation.
///
/// That used to strand it permanently. `AppDataStore.currentGenerationMaxEventNumber` recovers
/// from a reset by spotting the counter going *backwards* between two rows, which needs a
/// post-reset row in that same database; `HistoryIngestor` is the only writer of `device_event`
/// (live flips don't write rows) and it resumed from `lastCommittedEventNumber + 1`, above
/// anything the reset cube holds. The row that would create the boundary was gated behind the
/// boundary already existing, so the app silently ingested nothing until the cube's counter
/// climbed back past the old maximum.
///
/// The live `.factoryReset` sync-status event calls `resetCursors` and is the escape hatch, but
/// only for the session that receives it -- here that was the test-database session, days ago.
/// So `refreshHistory` now also treats *the device reporting a lower event number than we hold*
/// as a reset in its own right, and resumes from the start.
///
/// **What it does not cover:** the reset being witnessed live, which `W06` covers, and the
/// `logbook` purge that path performs -- deliberately not done here, because this database's
/// history is real data the app simply wasn't running to observe.
@Suite(.serialized)
@MainActor
struct W08PostResetProductionResumeWorkflow {
    private var harness: WorkflowHarness {
        .shared("08-post-reset-production-resume")
    }

    /// Stands in for a production database's accumulated history.
    private static let preResetEventCount: UInt32 = 112

    @Test func step1_productionHoldsPreResetHistory() async throws {
        try await harness.step("1-pre-reset-history") {
            try await harness.connect()
            let store = harness.dataStore
            // One unbroken generation, exactly as production looks having never seen a reset.
            //
            // Deliberately timestamped *before* `baseDate`, ending a minute short of it: the mock's
            // clock is synced to `baseDate` on connect, so its post-reset events start there. Real
            // post-reset activity happens after the history it follows, and the generation boundary
            // is found by walking `device_event` in `start_epoch` order -- seed this the other way
            // round and the new rows sort first, no drop is visible, and the test would be
            // measuring its own setup rather than the app.
            for eventNumber in 1...Self.preResetEventCount {
                let secondsBeforeBase = Double(Self.preResetEventCount - eventNumber + 1) * 60
                _ = store.recordDeviceEvent(
                    eventNumber: eventNumber,
                    deviceFace: 2,
                    startedAt: WorkflowHarness.baseDate.addingTimeInterval(-secondsBeforeBase),
                    durationSeconds: 60,
                    isPaused: false
                )
            }
            let known = try #require(store.latestDeviceEventNumber(), "history should be readable")
            try #require(known == Int64(Self.preResetEventCount),
                         "the whole table is one generation, so the max is the last event")
        }
    }

    @Test func step2_theCubeIsResetAndRepairedElsewhere() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-reset-happens-on-the-test-database") {
            // The cleanup reset. The app doing this was pointed at test.sqlite, so nothing about
            // it reaches the store under test here -- which is the whole point.
            _ = await harness.device.factoryReset()
            harness.device.completeFactoryResetReboot()
            _ = await harness.device.login(password: "000000")

            // A few flips afterwards: the cube is counting again, from the bottom.
            harness.device.flip(to: 8)
            harness.device.flip(to: 2)
            let latest = try #require(await harness.device.readLastEvent(),
                                      "the cube should report its current event")
            let number = try #require(latest.eventNumber)
            try #require(number < Self.preResetEventCount,
                         "the reset must have put the counter below production's high-water mark")
        }
    }

    @Test func step3_theBackwardsCounterIsTreatedAsAReset() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-resume-from-the-start") {
            let store = harness.dataStore
            let deviceNow = try #require(await harness.device.readLastEvent()?.eventNumber)

            // Exactly what launching the app against production does.
            await harness.ingestor.refreshHistory(trigger: "startup")

            // The pre-reset rows are never deleted -- they are real history. What changes is which
            // generation counts, so the reported max drops to the post-reset counter.
            let after = try #require(store.latestDeviceEventNumber(),
                                     "the store should still report a position")
            #expect(after == Int64(deviceNow),
                    "the post-reset events should have been ingested, moving the position down to the cube's own counter rather than leaving it stranded at \(Self.preResetEventCount)")
            #expect(harness.storedEventCount() > Int(Self.preResetEventCount),
                    "and they should be new rows on top of the pre-reset history, not a purge")
        }
    }

    @Test func step4_laterFlipsKeepIngestingNormally() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-normal-service-resumes") {
            let store = harness.dataStore
            let before = try #require(store.latestDeviceEventNumber())

            for face in 0..<20 {
                harness.device.flip(to: face.isMultiple(of: 2) ? 8 : 2)
            }
            await harness.ingestor.refreshHistory(trigger: "periodic")

            let after = try #require(store.latestDeviceEventNumber())
            #expect(after > before,
                    "once the generation boundary exists the ordinary resume path works again, so these flips should land without another reset being inferred")
            let deviceNow = try #require(await harness.device.readLastEvent()?.eventNumber)
            #expect(after == Int64(deviceNow), "and the app should be level with the cube")
        }
    }
}

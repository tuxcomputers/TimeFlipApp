@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 07: a settling value reaches the device once, not once per keystroke
///
/// **Preconditions:** a connected, logged-in device. Step 1 establishes that.
///
/// **What it covers:** `DeviceWriteDebouncer`, the mechanism every live-edited setting shares --
/// auto-pause, LED brightness, blink interval, double-tap parameters and face colours each own one
/// (`ApplicationDelegate`). A held stepper arrow or a fast run of keystrokes changes the value many
/// times per second; the debouncer is what stops each of those becoming a BLE write.
///
/// This is the substance of `Bench/03b` Scenario B, `05b` Scenarios B-C and `06b` Scenario B, which
/// between them assert "the value settles, *then* one write goes out". Until now the type behind all
/// three had no automated coverage at all -- the only thing exercising it was a human holding an
/// arrow key on real hardware.
///
/// **What it does not cover:** the AppKit gestures that drive it. A held stepper press and a text
/// field committing on focus-loss are real events against a real window (`Methods.md` Methods 7 and
/// 12), and stay in the checklists. What moves here is what happens *after* the value changes.
///
/// Deliberately runs with `.instant` latency and short delays: this workflow is about *when* a write
/// is issued, and adding radio time would only make the assertions slower without making them
/// sharper.
@Suite(.serialized)
@MainActor
struct W07DebouncedDeviceWritesWorkflow {
    private var harness: WorkflowHarness {
        .shared("07-debounced-writes")
    }

    /// Short enough to keep the suite fast, long enough that a burst of scheduling completes well
    /// inside one window. The production value is `DeviceWriteDebouncer.defaultDelay` (2s); what is
    /// under test is the coalescing behaviour, not the specific duration.
    private static let delay: TimeInterval = 0.20
    /// Comfortably past `delay`, so a settled write has certainly run.
    private static let settled = Duration.milliseconds(400)

    @Test func step1_theDeviceIsConnectedAndListening() async throws {
        try await harness.step("1-preconditions") {
            try await harness.connect()
            try #require(harness.device.snapshot().isLocked == false, "should start unlocked")
        }
    }

    @Test func step2_aBurstOfChangesReachesTheDeviceOnce() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-burst-coalesces") {
            let debouncer = DeviceWriteDebouncer()
            let writes = WriteCounter()

            // Stands in for a held stepper arrow: eleven values in quick succession.
            for minutes in 20...30 {
                debouncer.schedule(delay: Self.delay) {
                    await writes.record(minutes)
                }
            }
            try await Task.sleep(for: Self.settled)

            let recorded = await writes.values
            try #require(recorded.count == 1, "eleven changes should cost one write, got \(recorded.count)")
            #expect(recorded == [30], "and it should carry the value the user settled on, not the first")
        }
    }

    @Test func step3_theWriteWaitsForTheValueToStopMoving() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-write-is-deferred") {
            let debouncer = DeviceWriteDebouncer()
            let writes = WriteCounter()

            debouncer.schedule(delay: Self.delay) { await writes.record(1) }
            // Well inside the window: nothing should have gone out yet. Without this the test would
            // pass even if the debouncer wrote immediately and simply never wrote again.
            try await Task.sleep(for: .milliseconds(60))
            let duringWindow = await writes.values
            try #require(duringWindow.isEmpty, "the write fired immediately, defeating the debounce")

            try await Task.sleep(for: Self.settled)
            #expect(await writes.values == [1], "and then exactly once, after it settled")
        }
    }

    @Test func step4_cancellingDropsAStaleQueuedWrite() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-cancel-drops-stale") {
            let debouncer = DeviceWriteDebouncer()
            let writes = WriteCounter()

            debouncer.schedule(delay: Self.delay) { await writes.record(99) }
            // What the app does when the same setting has just been written outright: the queued
            // value is stale and must not land on top of the newer one.
            debouncer.cancel()
            try await Task.sleep(for: Self.settled)

            #expect(await writes.values.isEmpty, "a cancelled write must never reach the device")
        }
    }

    @Test func step5_separateSettingsDoNotCancelEachOther() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-independent-debouncers") {
            // ApplicationDelegate deliberately owns one debouncer per setting. Sharing a single one
            // would mean editing brightness silently dropped a blink-interval write that hadn't
            // fired yet -- a data-loss bug that would look like the device ignoring a setting.
            let brightness = DeviceWriteDebouncer()
            let blink = DeviceWriteDebouncer()
            let writes = WriteCounter()

            brightness.schedule(delay: Self.delay) { await writes.record(77) }
            blink.schedule(delay: Self.delay) { await writes.record(42) }
            try await Task.sleep(for: Self.settled)

            let recorded = await writes.values.sorted()
            #expect(recorded == [42, 77], "both settings should land, got \(recorded)")
        }
    }

    @Test func step6_theSettledValueIsWhatTheDeviceEndsUpHolding() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("6-device-holds-final-value") {
            let debouncer = DeviceWriteDebouncer()
            let device = harness.device

            // The whole point, end to end: a burst of edits, one write, and the device holding the
            // value the user stopped on. Double-tap is the setting used because it is the one with a
            // real device read-back (0x17) -- brightness and blink have none, so for those the app
            // can only assert what it sent.
            for threshold in UInt8(80)...UInt8(90) {
                debouncer.schedule(delay: Self.delay) {
                    await device.setDoubleTapParameters(
                        DoubleTapParameters(clickThreshold: threshold, limit: 20, latency: 50, window: 50)
                    )
                }
            }
            try await Task.sleep(for: Self.settled)

            let readBack = await device.readDoubleTapParameters()
            let params = try #require(readBack, "the device should answer a 0x17 read")
            #expect(params.clickThreshold == 90, "the device should hold the settled value")
        }
    }

    /// Actor because the debounced action runs on its own task.
    private actor WriteCounter {
        private(set) var values: [Int] = []
        func record(_ value: Int) { values.append(value) }
    }
}

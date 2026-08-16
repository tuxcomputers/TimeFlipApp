@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 06: factory reset, and the window where the old PIN still works
///
/// **Preconditions:** a paired, logged-in device holding some history, on a rotated (non-default)
/// PIN. Step 1 establishes that.
///
/// **What it covers:** the whole reset sequence as the app sees it -- 0xFF is sent and
/// acknowledges nothing, the device then spends a long time rebooting during which it *still
/// answers to its old password*, and only afterwards is the wipe observable: default PIN, no
/// history, counter restarted, never-paired.
///
/// The middle step is the point of the workflow. Measured on hardware 2026-07-31: two seconds after
/// 0xFF the cube accepted `123456`, and only by nine seconds did it reject it and accept `000000`.
/// `TimeFlipBLEDevice` therefore refuses to treat an immediate re-login as proof of a reset, and
/// `ApplicationDelegate` gates confirmation on the *default* password specifically. Those two
/// decisions look like defensive over-engineering until this window is modelled, at which point a
/// naive implementation fails here instead of stranding a real cube.
///
/// **What it does not cover:** the reconnect loop itself. `ApplicationDelegate` arms
/// `factoryResetConfirmDeadline`, tears the session down and drives `scheduleReconnect`, all of
/// which live in private AppKit-lifecycle code (see `Workflows/README.md`). This asserts what the
/// *device* does, which is what that loop is written against.
///
/// Runs with realistic latency scaled to 0.001, so the modelled 13.5-second reboot costs ~13ms of
/// wall clock while remaining an ordered, genuinely-suspending window rather than an instant flip.
@Suite(.serialized)
@MainActor
struct W06FactoryResetWorkflow {
    /// The PIN the device is rotated onto before the reset, standing in for a real paired cube: a
    /// reset from the factory default could not distinguish "old password still works" from "the
    /// reset already landed", which is exactly the ambiguity being tested.
    private static let rotatedPIN = "123456"

    private var harness: WorkflowHarness {
        .shared("06-factory-reset", latency: .realistic(scale: 0.001))
    }

    @Test func step1_startsPairedWithHistoryOnARotatedPin() async throws {
        try await harness.step("1-preconditions") {
            try await harness.connect()

            let rotated = await harness.device.rotateDevicePassword()
            try #require(rotated == Self.rotatedPIN, "expected the dev-mode fixed PIN, got \(rotated ?? "nil")")

            harness.flip(to: 3, atSecondsFromBase: 60)
            harness.flip(to: 5, atSecondsFromBase: 300)
            await harness.ingestHistory(trigger: "startup")

            try #require(harness.device.isPaired, "should start paired")
            try #require(harness.storedEventCount() > 0, "and with history to lose")
        }
    }

    @Test func step2_theResetCommandIsSentButConfirmsNothing() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-send-0xFF") {
            let sent = await harness.device.factoryReset()

            try #require(sent, "the 0xFF write should report as sent")
            // Sent is not done. The device acknowledges nothing and is still mid-reboot, so
            // everything about it must still look untouched at this instant.
            #expect(harness.device.isPaired, "the write alone must not unpair anything")
            #expect(harness.deviceHistoryEventNumbers().isEmpty == false, "nor wipe history yet")
        }
    }

    @Test func step3_theOldPinStillWorksWhileTheDeviceReboots() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-old-pin-during-reboot") {
            let oldStillWorks = await harness.device.login(password: Self.rotatedPIN)
            #expect(oldStillWorks, "the pre-reset PIN must still be accepted mid-reboot -- this is the trap")

            let defaultWorksYet = await harness.device.login(password: TimeFlipConstants.defaultPassword)
            #expect(defaultWorksYet == false,
                    "the default must NOT work yet, or confirming on it would fire before the wipe")
        }
    }

    @Test func step4_theWipeIsObservableOnceTheRebootFinishes() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-reboot-completes") {
            harness.device.completeFactoryResetReboot()

            let defaultWorks = await harness.device.login(password: TimeFlipConstants.defaultPassword)
            try #require(defaultWorks, "the device must come back on the factory default")

            let oldRejected = await harness.device.login(password: Self.rotatedPIN)
            #expect(oldRejected == false, "and must stop accepting the rotated PIN")
        }
    }

    @Test func step5_everythingStoredOnTheDeviceIsGone() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-device-wiped") {
            #expect(harness.deviceHistoryEventNumbers().isEmpty, "history should be erased")
            #expect(harness.device.isPaired == false, "a reset ends never-paired, not reconnected")
        }
    }

    @Test func step6_theAppsOwnRowsSurviveAndTheCounterRestarts() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("6-counter-restarts") {
            // The app's database is deliberately untouched: the reset erases the *cube*, not the
            // record of what was tracked on it. Confirmed on hardware, where device_event kept its
            // rows while the device reported no events at all.
            try #require(harness.storedEventCount() > 0, "the app's history must survive the device's")

            // No *event* yet, even though the rebooted cube is already timing a segment: a segment
            // only becomes an event when a flip closes it. This is why the app shows an idle,
            // frozen duration after a reset until the cube is first moved -- correct, not a bug.
            let beforeFirstFlip = harness.device.lastEventNumber
            #expect(beforeFirstFlip == nil, "a freshly reset device has no event until the first flip")

            harness.device.pair()
            _ = await harness.device.login(password: TimeFlipConstants.defaultPassword)
            harness.flip(to: 7, atSecondsFromBase: 600)

            // The counter restarting low is why AppDataStore derives its ingest position from
            // device_event rather than storing a high-water mark, which a reset would strand above
            // the live counter and skip every new event until it climbed back past it.
            let restarted = try #require(harness.device.lastEventNumber, "the first flip should close a segment")
            #expect(restarted <= 1, "the counter restarts from the bottom, got \(restarted)")
        }
    }
}

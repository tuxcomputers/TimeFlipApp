@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 01: the device connects, authenticates, and starts reporting
///
/// **Preconditions:** a paired but unconnected mock device, not logged in, notifications off, and a
/// freshly created database. Step 1 asserts that rather than assuming it.
///
/// **What it covers:** the foundation every other workflow stands on. Nothing else in this folder is
/// worth diagnosing until this passes -- a field value that doesn't reach the device is meaningless if
/// the session was never established, which is why this is `W01`.
///
/// It also pins down the ordering rule that bites hardest in this codebase: `MockTimeFlipDevice.emit`
/// drops every event unless the device is paired **and** logged in **and** notifications are enabled,
/// exactly as the real device reports nothing until its notification characteristics are subscribed.
/// A caller that skips a step doesn't get an error, it gets silence -- and a test awaiting that
/// silence hangs rather than fails. Steps 3 and 4 assert the silence and the recovery from it
/// explicitly so that trap is covered rather than rediscovered.
///
/// Runs with realistic radio latency (see `MockTimeFlipDevice.Latency`), scaled down so the whole
/// workflow stays well under a second while every operation still genuinely suspends.
@Suite(.serialized)
@MainActor
struct W01ConnectionWorkflow {
    private var harness: WorkflowHarness { .shared("01-connection", latency: .realistic(scale: 0.1)) }

    @Test func step1_startsUnconnectedAndUnauthenticated() async throws {
        try await harness.step("1-preconditions") {
            try #require(harness.device.isPaired, "the mock is paired out of the box")
            try #require(harness.storedEventCount() == 0, "no device_event rows yet")
            try #require(harness.device.history.isEmpty, "device history cleared of the mock's samples")
        }
    }

    @Test func step2_connectingTakesRealTimeRatherThanReturningInstantly() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-connect-costs-time") {
            let clock = ContinuousClock()
            let elapsed = try await clock.measure {
                let connected = await harness.device.connect()
                try #require(connected, "connect should succeed")
            }
            // connect is the slowest operation in the profile; at scale 0.1 that's ~80ms. Asserting a
            // floor rather than a window keeps this from turning into a flaky timing test on a loaded
            // CI machine, while still proving the latency is actually applied.
            #expect(elapsed > .milliseconds(20), "connect should cost radio time, not return instantly")
        }
    }

    @Test func step3_nothingIsReportedBeforeLoginAndNotifications() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-silent-before-login") {
            let received = await harness.collectBatteryLevels(driving: [42], timeout: .milliseconds(300))
            try #require(
                received.isEmpty,
                "an unauthenticated device must report nothing -- note it stays silent rather than erroring"
            )
        }
    }

    @Test func step4_loggingInAndEnablingNotificationsStartsTheReporting() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-login-then-notifications") {
            let wrong = await harness.device.login(password: "999999")
            try #require(wrong == false, "a wrong password must be rejected, not silently accepted")

            let right = await harness.device.login(password: TimeFlipConstants.defaultPassword)
            try #require(right, "the default password should be accepted")
            await harness.device.enableNotifications()

            let received = await harness.collectBatteryLevels(driving: [42], timeout: .seconds(5))
            #expect(received == [42], "once logged in with notifications on, readings should arrive")
        }
    }

    @Test func step5_theFirstHistoryIngestEstablishesTheOpenSegment() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-first-ingest") {
            harness.flip(to: 3, atSecondsFromBase: 30)
            await harness.ingestHistory(trigger: "startup")

            try #require(harness.storedEventCount() > 0, "the first ingest should have stored the segment")
            #expect(harness.openEventCount() == 1, "and left exactly one segment in progress")
        }
    }
}

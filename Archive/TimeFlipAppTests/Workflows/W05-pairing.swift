@testable import TimeFlipApp
import Foundation
import Testing

/// # Workflow 05: scanning, pairing, and the PIN round trip
///
/// **Preconditions:** an unpaired device that has not been scanned for, on the factory default PIN.
/// Step 1 asserts that.
///
/// **What it covers:** the pairing flow end to end -- scan, pick a result, connect, log in, pair, and
/// the password rotation that follows -- plus Forget putting the PIN back to the factory default so the
/// cube isn't stranded on a secret nobody holds.
///
/// This is the one flow where getting it wrong has a consequence outside the app: a rotation that sets
/// a new PIN but fails to confirm it leaves a real cube unreachable. `TimeFlipBLEDevice` guards that by
/// re-logging in before reporting success, and the mock does the same, so step 4 can assert the old PIN
/// genuinely stops working and step 5 that Forget restores the default.
///
/// Runs with realistic latency scaled to 0.1: pairing is the flow where results arrive over time rather
/// than at once, so instant responses would hide an ordering mistake.
@Suite(.serialized)
@MainActor
struct W05PairingWorkflow {
    private var harness: WorkflowHarness {
        .shared("05-pairing", latency: .realistic(scale: 0.1), startsPaired: false)
    }

    @Test func step1_startsUnpairedAndUnscanned() async throws {
        try await harness.step("1-preconditions") {
            try #require(harness.device.isPaired == false, "should start unpaired")
            try #require(harness.storedEventCount() == 0, "and with an empty database")
        }
    }

    @Test func step2_aScanReportsTheCubeOverTime() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("2-scan") {
            var found: [DiscoveredBLEDevice] = []
            harness.device.onDeviceDiscovered = { found.append($0) }

            await harness.device.startDiscoveryScan(filterToTimeFlip: true)

            try #require(found.isEmpty == false, "the scan should report the staged cube")
            #expect(found.allSatisfy { $0.name.lowercased().contains("timeflip") })
        }
    }

    @Test func step3_pairingWithTheDefaultPinSucceeds() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("3-pair") {
            let target = try #require(harness.device.discoverableDevices.first, "nothing staged to pair with")

            let outcome = await harness.device.connectToDiscoveredDevice(
                id: target.id,
                password: TimeFlipConstants.defaultPassword
            )

            try #require(outcome == .connected, "pairing on the factory default should succeed, got \(outcome)")
            #expect(harness.device.isPaired)
        }
    }

    @Test func step4_rotatingThePinLeavesOnlyTheNewOneWorking() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("4-rotate-pin") {
            let rotatedValue = await harness.device.rotateDevicePassword()
            let rotated = try #require(rotatedValue, "rotation should report the new PIN")

            let newWorks = await harness.device.login(password: rotated)
            #expect(newWorks, "the rotated PIN must work -- it's what gets stored")
            let defaultWorks = await harness.device.login(password: TimeFlipConstants.defaultPassword)
            #expect(defaultWorks == false, "the factory default must stop working once rotated")
        }
    }

    @Test func step5_forgettingPutsTheFactoryDefaultBack() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("5-reset-pin-on-forget") {
            let reset = await harness.device.resetDevicePasswordToDefault()
            try #require(reset, "the reset must confirm before the app clears its stored PIN")

            let defaultWorks = await harness.device.login(password: TimeFlipConstants.defaultPassword)
            #expect(defaultWorks, "a forgotten cube must be reachable on the factory default again")
        }
    }

    @Test func step6_aPairedSessionStillIngestsHistoryNormally() async throws {
        try harness.requirePreviousStepsPassed()
        try await harness.step("6-history-after-pairing") {
            harness.flip(to: 5, atSecondsFromBase: 60)
            await harness.ingestHistory(trigger: "startup")

            try #require(harness.storedEventCount() > 0, "pairing should leave a usable session behind")
            #expect(harness.openEventCount() == 1, "with exactly one segment in progress")
        }
    }
}

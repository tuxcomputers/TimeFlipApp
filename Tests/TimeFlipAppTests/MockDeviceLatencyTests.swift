@testable import TimeFlipApp
import Foundation
import XCTest

/// The mock's simulated radio timing: delays drawn from a range rather than fixed, one draw per
/// history record, and reproducible for a given seed.
@MainActor
final class MockDeviceLatencyTests: XCTestCase {
    private func makeDevice(
        latency: MockTimeFlipDevice.Latency,
        seed: UInt64 = 0x5EED
    ) -> MockTimeFlipDevice {
        MockTimeFlipDevice(
            configuration: .init(emitInitialStatus: false, latency: latency, randomSeed: seed)
        )
    }

    private func millis(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    // MARK: - Ranges

    func testASampledDelayAlwaysLiesInsideItsRange() {
        let range = MockTimeFlipDevice.DelayRange.milliseconds(160, 200)
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 1)
        for _ in 0..<500 {
            let drawn = millis(range.sample(using: &generator))
            XCTAssertGreaterThanOrEqual(drawn, 160)
            XCTAssertLessThanOrEqual(drawn, 200)
        }
    }

    func testDrawsVaryRatherThanRepeatingOneValue() {
        let range = MockTimeFlipDevice.DelayRange.milliseconds(160, 200)
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 1)
        let drawn = (0..<50).map { _ in millis(range.sample(using: &generator)) }
        // The whole point of a range: 184, 198, 163, ... not the same number every time.
        XCTAssertGreaterThan(Set(drawn).count, 10, "delays should spread across the range, got \(Set(drawn))")
    }

    func testAFixedRangeDoesNotVary() {
        let range = MockTimeFlipDevice.DelayRange.fixed(.milliseconds(50))
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 1)
        let drawn = (0..<20).map { _ in millis(range.sample(using: &generator)) }
        XCTAssertEqual(Set(drawn), [50])
    }

    func testScalingKeepsRangesProportionalAndSurvivesOverASecond() {
        let scaled = MockTimeFlipDevice.DelayRange.milliseconds(600, 1000).scaled(by: 2)
        // Over a second, so this catches a conversion that only reads the sub-second component.
        XCTAssertEqual(millis(scaled.lower), 1200, accuracy: 0.001)
        XCTAssertEqual(millis(scaled.upper), 2000, accuracy: 0.001)
    }

    // MARK: - Reproducibility

    func testTheSameSeedGivesTheSameSequence() {
        let range = MockTimeFlipDevice.DelayRange.milliseconds(160, 200)
        func sequence(seed: UInt64) -> [Double] {
            var generator = MockTimeFlipDevice.SeededGenerator(seed: seed)
            return (0..<20).map { _ in millis(range.sample(using: &generator)) }
        }
        XCTAssertEqual(sequence(seed: 99), sequence(seed: 99), "a seed must replay exactly")
        XCTAssertNotEqual(sequence(seed: 99), sequence(seed: 100), "different seeds should differ")
    }

    // MARK: - Per-record history streaming

    func testHistoryChargesOneGapPerRecordPlusTheCommandRoundTrip() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.historyRead = .milliseconds(1, 1)
        latency.historyFrames = .init(interval: .milliseconds(1, 2), intervalWeights: [0, 1])
        let device = makeDevice(latency: latency)
        device.seedHistory(Self.entries(count: 12))

        _ = await device.fetchHistory(startingFrom: nil)

        // One for the command round trip, then one per record streamed back.
        XCTAssertEqual(device.sampledDelays.count, 1 + 12)
    }

    func testAFetchWithNothingToReturnStillCostsTheCommandRoundTrip() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.historyRead = .milliseconds(1, 1)
        latency.historyFrames = .init(interval: .milliseconds(1, 2), intervalWeights: [0, 1])
        let device = makeDevice(latency: latency)
        device.seedHistory([])

        _ = await device.fetchHistory(startingFrom: nil)

        XCTAssertEqual(device.sampledDelays.count, 1, "the command is still sent and answered")
    }

    func testFrameGapsAreDrawnIndependently() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.historyFrames = .init(interval: .milliseconds(160, 200), intervalWeights: [0, 1])
        let device = makeDevice(latency: latency)
        device.seedHistory(Self.entries(count: 40))

        _ = await device.fetchHistory(startingFrom: nil)

        let drawn = device.sampledDelays.map(millis)
        XCTAssertEqual(drawn.count, 40)
        XCTAssertGreaterThan(Set(drawn).count, 10, "each record should get its own draw, not one repeated")
        for value in drawn {
            XCTAssertGreaterThanOrEqual(value, 160)
            XCTAssertLessThanOrEqual(value, 200)
        }
    }

    // MARK: - Frame cadence

    /// The property that a plain range cannot express: gaps land on whole multiples of the
    /// connection interval, including zero when two frames share one connection event.
    func testFrameGapsQuantiseToWholeConnectionIntervals() {
        let cadence = MockTimeFlipDevice.FrameCadence(
            interval: .fixed(.milliseconds(15)),
            intervalWeights: [1, 1, 1, 1]
        )
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 7)
        var counts: Set<Int> = []
        for _ in 0..<400 {
            let drawn = millis(cadence.sample(using: &generator))
            let intervals = drawn / 15
            XCTAssertEqual(intervals, intervals.rounded(), accuracy: 0.001,
                           "\(drawn)ms is not a whole number of 15ms intervals")
            counts.insert(Int(intervals.rounded()))
        }
        XCTAssertEqual(counts, [0, 1, 2, 3], "every weighted count should be reachable")
    }

    func testFrameGapWeightsGovernHowOftenEachCountAppears() {
        // Only single intervals allowed: a 0-weighted count must never be drawn.
        let cadence = MockTimeFlipDevice.FrameCadence(
            interval: .fixed(.milliseconds(15)),
            intervalWeights: [0, 1, 0, 0]
        )
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 7)
        let drawn = (0..<200).map { _ in millis(cadence.sample(using: &generator)) }
        XCTAssertEqual(Set(drawn), [15])
    }

    func testTheMeasuredCadenceReproducesItsRealWorldMean() {
        // Real hardware averaged 19.4ms per record across 105 gaps; the modelled weights should
        // land near that, or the profile is not the distribution it claims to be.
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 11)
        let cadence = MockTimeFlipDevice.FrameCadence.realistic()
        let drawn = (0..<5_000).map { _ in millis(cadence.sample(using: &generator)) }
        let mean = drawn.reduce(0, +) / Double(drawn.count)
        XCTAssertEqual(mean, 19.4, accuracy: 1.5, "modelled mean \(mean)ms should match the measured 19.4ms")
    }

    func testAnInstantCadenceCostsNothing() {
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 3)
        var cadence = MockTimeFlipDevice.FrameCadence.none
        XCTAssertEqual(millis(cadence.sample(using: &generator)), 0)
        // A cadence with an interval but no weights is also silent, rather than crashing on an
        // empty weight list.
        cadence = .init(interval: .milliseconds(10, 20), intervalWeights: [])
        XCTAssertEqual(millis(cadence.sample(using: &generator)), 0)
    }

    // MARK: - The default stays instant

    func testInstantIsTheDefaultAndCostsNothing() async {
        let device = MockTimeFlipDevice(configuration: .init(emitInitialStatus: false))
        device.seedHistory(Self.entries(count: 25))

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await device.fetchHistory(startingFrom: nil)
            _ = await device.login(password: TimeFlipConstants.defaultPassword)
        }

        XCTAssertTrue(device.sampledDelays.isEmpty, "instant should draw no delays at all")
        XCTAssertLessThan(elapsed, .milliseconds(100), "instant must not sleep")
    }

    func testRejectedCommandsStillCostARoundTrip() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.login = .milliseconds(1, 2)
        let device = makeDevice(latency: latency)

        let accepted = await device.login(password: "wrong!")

        XCTAssertFalse(accepted)
        XCTAssertEqual(device.sampledDelays.count, 1, "the device was still asked, and still answered")
    }

    // MARK: - Password operations charge both their legs

    /// Both password operations are a 0x30 write *plus* a confirming re-login, and the mock has to
    /// charge for both -- the whole reason the real driver re-logs in is that the write alone is not
    /// proof, so a mock that billed one round trip would understate the operation that matters most.
    func testRotatingThePasswordCostsTheWriteAndTheConfirmingLogin() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.write = .milliseconds(10, 10)
        let device = makeDevice(latency: latency)
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        device.clearSampledDelays()

        let rotated = await device.rotateDevicePassword()

        XCTAssertNotNil(rotated)
        XCTAssertEqual(device.sampledDelays.count, 2, "the 0x30 write and the confirming re-login")
        XCTAssertEqual(device.sampledDelays.map(millis), [10, 10])
    }

    func testResettingThePasswordUsesTheCheaperSettledLinkCost() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.write = .milliseconds(100, 100)
        latency.settledWrite = .milliseconds(10, 10)
        let device = makeDevice(latency: latency)
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        device.clearSampledDelays()

        let reset = await device.resetDevicePasswordToDefault()

        XCTAssertTrue(reset)
        // Forget Device runs on a session that has been up a while, so both legs are settled-link
        // round trips. Measured on hardware at roughly half a fresh-link write.
        XCTAssertEqual(device.sampledDelays.map(millis), [10, 10],
                       "a settled-session reset must not be billed at fresh-link rates")
    }

    func testTheRealisticProfileKeepsTheSettledLinkAboutHalfAFreshOne() {
        let profile = MockTimeFlipDevice.Latency.realistic()
        var generator = MockTimeFlipDevice.SeededGenerator(seed: 5)
        func mean(_ range: MockTimeFlipDevice.DelayRange) -> Double {
            let draws = (0..<2_000).map { _ in millis(range.sample(using: &generator)) }
            return draws.reduce(0, +) / Double(draws.count)
        }
        let ratio = mean(profile.write) / mean(profile.settledWrite)
        XCTAssertEqual(ratio, 2.0, accuracy: 0.35,
                       "measured 115-152ms fresh against 54-79ms settled, roughly 2x; got \(ratio)x")
    }

    // MARK: - Factory reset

    /// The write is charged; the reboot is not, because the real `factoryReset` returns as soon as
    /// 0xFF lands and never waits for the device to come back.
    func testFactoryResetChargesTheWriteOnlyNotTheReboot() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.settledWrite = .milliseconds(10, 10)
        latency.factoryResetReboot = .milliseconds(5_000, 5_000)
        let device = makeDevice(latency: latency)
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        device.clearSampledDelays()

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await device.factoryReset()
        }

        XCTAssertEqual(device.sampledDelays.map(millis), [10], "just the 0xFF write")
        XCTAssertLessThan(elapsed, .milliseconds(500), "must not block for the reboot")
    }

    /// The behaviour the whole model exists for, checked without the force-complete helper so the
    /// deadline itself is under test: the old password keeps working until the reboot elapses.
    func testTheOldPasswordKeepsWorkingUntilTheRebootElapses() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.factoryResetReboot = .milliseconds(200, 200)
        let device = makeDevice(latency: latency)
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        let rotated = await device.rotateDevicePassword()
        XCTAssertEqual(rotated, "123456")

        _ = await device.factoryReset()

        let oldDuringReboot = await device.login(password: "123456")
        XCTAssertTrue(oldDuringReboot, "the pre-reset PIN must still be accepted mid-reboot")
        let defaultDuringReboot = await device.login(password: TimeFlipConstants.defaultPassword)
        XCTAssertFalse(defaultDuringReboot, "the default must not work before the wipe lands")

        try? await Task.sleep(for: .milliseconds(300))

        let defaultAfter = await device.login(password: TimeFlipConstants.defaultPassword)
        XCTAssertTrue(defaultAfter, "once rebooted the device answers to the factory default")
        let oldAfter = await device.login(password: "123456")
        XCTAssertFalse(oldAfter, "and no longer to the rotated one")
    }

    /// Under `.instant` there is no window at all, so a caller that never opts into latency sees a
    /// reset that simply happened -- no behaviour that only exists when delays are switched on.
    func testAnInstantResetAppliesImmediately() async {
        let device = makeDevice(latency: .instant)
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        _ = await device.rotateDevicePassword()

        _ = await device.factoryReset()

        let oldWorks = await device.login(password: "123456")
        XCTAssertFalse(oldWorks, "no reboot window when everything is instant")
        XCTAssertFalse(device.isPaired, "a reset ends never-paired")
    }

    func testAFactoryResetWipesHistoryAndRestartsTheCounter() async {
        let device = makeDevice(latency: .instant)
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        device.seedHistory(Self.entries(count: 9))
        XCTAssertNotNil(device.lastEventNumber)

        _ = await device.factoryReset()

        XCTAssertTrue(device.history.isEmpty, "history is erased with everything else")
        XCTAssertNil(device.lastEventNumber, "and there is no event until a flip closes a segment")

        device.pair()
        _ = await device.login(password: TimeFlipConstants.defaultPassword)
        device.flip(to: 4)
        XCTAssertEqual(device.lastEventNumber, 1, "the counter restarts from the bottom")
    }

    func testAResetIsRefusedWhenNotLoggedIn() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.settledWrite = .milliseconds(10, 10)
        let device = makeDevice(latency: latency)

        let sent = await device.factoryReset()

        XCTAssertFalse(sent, "an unauthenticated session cannot erase the device")
        XCTAssertEqual(device.sampledDelays.count, 1, "but the command still cost a round trip")
    }

    private static func entries(count: Int) -> [TimeFlipHistoryEntry] {
        (0..<count).map { index in
            let number = UInt32(1000 + index)
            let face = UInt8(1 + (index % 12))
            let offset: TimeInterval = TimeInterval(index) * 60
            let start = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offset)
            return TimeFlipHistoryEntry(
                eventNumber: number,
                faceID: face,
                startedAt: start,
                duration: 60,
                isPaused: false
            )
        }
    }
}

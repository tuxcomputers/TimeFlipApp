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

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

    func testHistoryChargesOneDelayPerRecordPlusTheCommandRoundTrip() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.historyRead = .milliseconds(1, 1)
        latency.historyPerRecord = .milliseconds(1, 2)
        let device = makeDevice(latency: latency)
        device.seedHistory(Self.entries(count: 12))

        _ = await device.fetchHistory(startingFrom: nil)

        // One for the command round trip, then one per record streamed back.
        XCTAssertEqual(device.sampledDelays.count, 1 + 12)
    }

    func testAFetchWithNothingToReturnStillCostsTheCommandRoundTrip() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.historyRead = .milliseconds(1, 1)
        latency.historyPerRecord = .milliseconds(1, 2)
        let device = makeDevice(latency: latency)
        device.seedHistory([])

        _ = await device.fetchHistory(startingFrom: nil)

        XCTAssertEqual(device.sampledDelays.count, 1, "the command is still sent and answered")
    }

    func testPerRecordDelaysAreDrawnIndependently() async {
        var latency = MockTimeFlipDevice.Latency.instant
        latency.historyPerRecord = .milliseconds(160, 200)
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

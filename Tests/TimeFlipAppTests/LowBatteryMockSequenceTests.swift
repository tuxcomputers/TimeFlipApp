@testable import TimeFlipApp
import XCTest

/// The low-battery latch driven by a real stream of device battery readings, using
/// `MockTimeFlipDevice` as the device.
///
/// This replaces `Bench/07b`'s old "confirm the recovery margin, not just the bare threshold,
/// controls the latch" scenario, which is not merely awkward on real hardware but impossible on a
/// healthy one. That scenario needed the level to climb *above* the threshold while staying inside
/// the recovery margin, all within one app session. With fresh batteries the device reports a flat
/// 100% -- `TimeFlipConstants.maxBatteryLevel`, so there is no headroom to climb into and no second
/// value to flap between -- and the threshold cannot be moved instead, because
/// `MenuBarController.setLowBatteryThreshold` deliberately clears the latch on every change so a
/// lowered threshold can't leave a stale warning blinking. The sticky state the test exists to
/// observe therefore never survives. A mock device reports whatever level we ask for, so the whole
/// transition sequence becomes deterministic and runs in CI on every push.
///
/// `LowBatteryLatchTests` covers `LowBatteryLatch.updated` as a pure function, case by case. This
/// covers the same rules as a *sequence*, threading one persisted latch through readings that arrive
/// one at a time off the device's event stream -- the shape `MenuBarController`'s
/// `appState.$batteryLevel` subscription runs.
///
/// Note the mock only emits once paired, logged in and notified (`MockTimeFlipDevice.emit`'s guard).
/// Skipping that setup doesn't fail a stream-consuming test, it *hangs* it, so `reportedLevels`
/// collects through an `XCTestExpectation` with a hard timeout rather than awaiting the stream
/// directly -- a missing event has to fail the test, never stall CI.
@MainActor
final class LowBatteryMockSequenceTests: XCTestCase {
    private let threshold = 10
    private let recoveryMargin = 5
    /// Generous enough for a loaded CI machine, short enough that a genuinely absent event fails fast.
    private let streamTimeout: TimeInterval = 10

    /// Collects battery levels off the stream. An actor because the draining task and the test body
    /// touch it from different isolation domains.
    private actor LevelSink {
        private var levels: [UInt8] = []
        func append(_ level: UInt8) -> Int {
            levels.append(level)
            return levels.count
        }
        func all() -> [UInt8] { levels }
    }

    /// Reports `levels` through the mock and returns the levels the device actually emitted, so the
    /// assertions run against the event stream rather than numbers handed straight to the latch.
    private func reportedLevels(driving levels: [UInt8]) async -> [UInt8] {
        // The mock is paired by default but emits nothing until logged in with notifications on.
        let mock = MockTimeFlipDevice(
            configuration: .init(batteryLevel: levels[0], emitInitialStatus: false)
        )
        let stream = mock.events  // Creates the continuation; must exist before anything is emitted.
        let loggedIn = await mock.login(password: TimeFlipConstants.defaultPassword)
        XCTAssertTrue(loggedIn, "mock login failed")
        await mock.enableNotifications()

        let sink = LevelSink()
        let allArrived = expectation(description: "all \(levels.count) battery readings arrived")
        let expected = levels.count
        let consumer = Task {
            for await event in stream {
                if case .batteryLevel(let level) = event {
                    if await sink.append(level) == expected {
                        allArrived.fulfill()
                    }
                }
            }
        }
        defer { consumer.cancel() }

        for level in levels {
            mock.setBatteryLevel(level)
        }

        await fulfillment(of: [allArrived], timeout: streamTimeout)
        return await sink.all()
    }

    /// Runs the emitted readings through one persisted latch, returning its state after each.
    private func latchStates(over levels: [UInt8]) async -> [Bool] {
        let reported = await reportedLevels(driving: levels)
        XCTAssertEqual(reported, levels, "the mock should emit exactly the levels it was given")

        var latched = false
        return reported.map { level in
            latched = LowBatteryLatch.updated(
                latched: latched,
                currentLevel: level,
                threshold: threshold,
                recoveryMargin: recoveryMargin
            )
            return latched
        }
    }

    /// The full arc the bench scenario used to drive on hardware: threshold at 10%, the level drains
    /// past it, flaps either side of it without ever clearing, reaches the top of the recovery band
    /// still latched, and only clears once it goes strictly above.
    func testDrainThenFlapThenRecoverAcrossTheThreshold() async {
        let states = await latchStates(over: [9, 10, 11, 10, 11, 15, 16])

        XCTAssertEqual(states.count, 7, "every reported level should produce a latch decision")
        XCTAssertTrue(states[0], "9% is below the 10% threshold -- latches on")
        XCTAssertTrue(states[1], "10% is at the threshold -- stays on")
        XCTAssertTrue(states[2], "11% is above the threshold but inside the band -- stays on")
        XCTAssertTrue(states[3], "flapping back down to 10% -- stays on")
        XCTAssertTrue(states[4], "and back up to 11% -- stays on")
        XCTAssertTrue(states[5], "15% is the top of the band (threshold + 5) -- still on, not cleared")
        XCTAssertFalse(states[6], "16% is strictly above the recovery level -- clears")
    }

    /// The boundary the flap above brackets: the latch clears strictly *above*
    /// `threshold + recoveryMargin`, so 15% must not clear it and 16% must.
    func testRecoveryIsStrictlyAboveTheRecoveryLevelNotAtIt() async {
        let atTheBoundary = await latchStates(over: [9, 15])
        XCTAssertEqual(atTheBoundary, [true, true], "15% is not *above* 15, so the warning holds")

        let pastTheBoundary = await latchStates(over: [9, 16])
        XCTAssertEqual(pastTheBoundary, [true, false], "16% clears it")
    }

    /// Once cleared, a level back inside the band must not re-latch -- only dropping to or below the
    /// bare threshold does. Guards the asymmetry that makes this a Schmitt trigger rather than a
    /// plain comparison.
    func testBackInsideTheBandAfterRecoveryDoesNotRelatch() async {
        let states = await latchStates(over: [9, 16, 11, 10])

        XCTAssertFalse(states[1], "16% cleared it")
        XCTAssertFalse(states[2], "11% is inside the band but the latch is off -- stays off")
        XCTAssertTrue(states[3], "10% is at the threshold -- latches again")
    }

    /// The case that forced this test out of the bench suite: a fresh battery pegged at the reportable
    /// ceiling. The warning can still be *triggered* by setting the threshold to the level (which is
    /// what `07b` Scenario A does, and still works on hardware), but it can never recover, because
    /// recovery needs a reading above 105 and the device cannot report above 100. Asserted here so the
    /// impossibility is recorded rather than rediscovered next time the batteries are changed.
    func testAtTheReportableCeilingTheWarningCanTriggerButNeverRecover() async {
        let ceiling = TimeFlipConstants.maxBatteryLevel
        XCTAssertEqual(ceiling, 100, "the rest of this test assumes 100 is the ceiling")

        let reported = await reportedLevels(driving: [ceiling, ceiling, ceiling])
        XCTAssertEqual(reported, [ceiling, ceiling, ceiling], "a pegged battery reports one value")

        var latched = false
        for level in reported {
            latched = LowBatteryLatch.updated(
                latched: latched,
                currentLevel: level,
                threshold: Int(ceiling),
                recoveryMargin: recoveryMargin
            )
            XCTAssertTrue(latched, "threshold at the level latches, and nothing can clear it")
        }
    }
}

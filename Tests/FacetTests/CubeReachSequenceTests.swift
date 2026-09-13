@testable import FacetCore
import Foundation
import Testing

/// Going to find the paired cube, driven with no radio and no cube.
///
/// **None of this had a test.** It lived in `BluetoothRadio` behind a `CBCentralManager`, so the only thing
/// that ever ran it was ten of the device scripts with somebody watching. What those cannot arrange is a room
/// with several cubes in it, which is the case every decision here exists for.
///
/// **The subtle one is the shortcut being paid for**, and it had nothing checking it at all: the window is cut
/// short when the remembered handle turns up, that device then refuses the PIN, and the room is owed a proper
/// look before the answer may be "nothing is here".
@Suite @MainActor
struct CubeReachSequenceTests {
    /// Records what the sequence asked the platform to do, in order.
    @MainActor
    final class Wire {
        var tried: [String] = []
        var scans = 0
        var finished: [(DeviceHandle?, DeviceLoginOutcome)] = []

        func sequence(_ clock: HandDrivenScheduler) -> CubeReachSequence {
            CubeReachSequence(
                scheduler: clock,
                tryThis: { [self] id, _, _ in tried.append(id.value) },
                scanAgain: { [self] in scans += 1 },
                finished: { [self] preferred, outcome in finished.append((preferred, outcome)) },
                debugLog: nil
            )
        }
    }

    private static func device(_ name: String) -> ScannedDevice {
        ScannedDevice(
            id: DeviceHandle(name), peripheralName: "TimeFlip v2.0",
            advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
    }

    /// Runs the settle wait, which is what stands between a candidate being chosen and being tried.
    private static func settle(_ clock: HandDrivenScheduler) {
        clock.tickAll(after: CubeReachSequence.settleSeconds)
    }

    // MARK: - asking the room

    @Test func testEveryDeviceWithTheNameIsAskedUntilOneTakesThePIN() throws {
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(found: [Self.device("a"), Self.device("b")], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)
        #expect(wire.tried == ["a"])

        reach.candidateEnded(.wrongPIN)
        Self.settle(clock)

        #expect(wire.tried == ["a", "b"], "the next one with the name gets asked")
        #expect(wire.finished.isEmpty, "and a refusal is not an ending")
    }

    @Test func testALoginEndsTheReachWithoutReportingAnOutcome() throws {
        // The caller already knows: it is the thing that reported the login. Reporting again here would have the
        // reconnect loop hear about a reach that succeeded as though it had run out of devices.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(found: [Self.device("a")], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)
        reach.candidateEnded(.loggedIn)

        #expect(!reach.isRunning)
        #expect(wire.finished.isEmpty)
    }

    @Test func testADeviceAdvertisingTwiceIsNotAskedTwiceInOnePass() throws {
        // **Not remembered beyond the reach**, deliberately: the next one starts over, so a cube that refused for
        // a passing reason is picked up again rather than needing a restart.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(found: [Self.device("a")], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)
        reach.candidateEnded(.wrongPIN)
        // The same device turns up in a second window.
        reach.scanEnded(found: [Self.device("a")], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)

        #expect(wire.tried == ["a"], "asked once")
    }

    @Test func testNothingIsTriedWhileSomethingElseHasTheLink() throws {
        // Asked when the wait ends rather than when it began: whether the link was taken in the meantime is a
        // fact about the radio, and connecting on top of it would leave the app holding a cube nobody chose.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(
            found: [Self.device("a")], remembered: nil, previouslyKnown: nil, isBusy: { true }
        )
        Self.settle(clock)

        #expect(wire.tried.isEmpty)
    }

    // MARK: - which of the two answers it is

    @Test func testNothingAnsweringIsUnreachable() throws {
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(found: [], remembered: nil, previouslyKnown: nil)

        #expect(wire.finished.count == 1)
        #expect(wire.finished.first?.1 == .unreachable)
    }

    @Test func testCubesThatRefusedAreWrongPINRatherThanUnreachable() throws {
        // **"None of them was ours" is not "nothing was there".** Both leave the app without its cube and they
        // are different problems: one is a cube out of range, the other cubes in range this app cannot open.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(found: [Self.device("a")], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)
        reach.candidateEnded(.wrongPIN)
        Self.settle(clock)

        #expect(wire.finished.first?.1 == .wrongPIN)
    }

    @Test func testADeviceThatSimplyDidNotAnswerDoesNotMakeItWrongPIN() throws {
        // Only a refusal says a cube was there and would not open. A timeout says nothing about whose it was.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(found: [Self.device("a")], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)
        reach.candidateEnded(.unreachable)
        Self.settle(clock)

        #expect(wire.finished.first?.1 == .unreachable)
    }

    // MARK: - the shortcut, and paying for it

    @Test func testTheRememberedHandleTurningUpCutsTheWindowShortOnce() throws {
        // Nothing a later advertisement could add would go ahead of it, and holding the window open past that
        // point costs the rest of the window for nothing: thirty-one seconds, measured 2026-08-09.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)
        let ours = Self.device("ours")

        reach.begin(preferring: ours.id, candidates: ["000000"], rotatingTo: nil)

        #expect(reach.shouldCutTheWindowShort(for: ours))
        #expect(!reach.shouldCutTheWindowShort(for: ours), "once per reach, so the second look runs its window")
        #expect(!reach.shouldCutTheWindowShort(for: Self.device("somebody elses")))
    }

    @Test func testAShortcutThatTurnedOutWrongBuysTheRoomASecondLook() throws {
        // **The one nothing checked.** The window stopped after one answer because the remembered handle turned
        // up; that device then refused, so it was not this app's cube and the rest of the room has never been
        // looked at. Saying nothing is here would be saying it about a scan that stopped early.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)
        let ours = Self.device("ours")

        reach.begin(preferring: ours.id, candidates: ["000000"], rotatingTo: nil)
        #expect(reach.shouldCutTheWindowShort(for: ours))
        reach.scanEnded(found: [ours], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)
        reach.candidateEnded(.wrongPIN)
        Self.settle(clock)

        #expect(wire.scans == 1, "the room is looked at properly before anything is concluded")
        #expect(wire.finished.isEmpty, "and nothing is concluded yet")
    }

    @Test func testTheSecondLookIsTheLastAndThenItAnswers() throws {
        // Two scans is the most a reach ever does: `mayEndEarly` is false after the first, so the second window
        // runs out and the answer is given rather than a third being started.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)
        let ours = Self.device("ours")

        reach.begin(preferring: ours.id, candidates: ["000000"], rotatingTo: nil)
        #expect(reach.shouldCutTheWindowShort(for: ours))
        reach.scanEnded(found: [ours], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)
        reach.candidateEnded(.wrongPIN)
        Self.settle(clock)
        // The second window finds only the same cube, which has been tried.
        reach.scanEnded(found: [ours], remembered: nil, previouslyKnown: nil)
        Self.settle(clock)

        #expect(wire.scans == 1, "no third scan")
        #expect(wire.finished.first?.1 == .wrongPIN)
    }

    // MARK: - ending it from outside

    @Test func testAbandoningReportsNothing() throws {
        // The window closing, or another device being chosen. Nobody is waiting for an outcome.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.scanEnded(found: [Self.device("a")], remembered: nil, previouslyKnown: nil)
        reach.abandon()
        clock.tickAll()

        #expect(!reach.isRunning)
        #expect(wire.finished.isEmpty)
        #expect(wire.tried.isEmpty, "and the wait that was pending does not fire")
    }

    @Test func testGivingUpNamesTheHandleItWasAskedFor() throws {
        // The caller has to report the outcome against something, and a reach that found nothing still knows
        // which cube it was looking for.
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)
        let ours = Self.device("ours")

        reach.begin(preferring: ours.id, candidates: ["000000"], rotatingTo: nil)
        reach.giveUp(because: "cannot use the radio")

        #expect(wire.finished.first?.0 == ours.id)
    }

    @Test func testItAnswersExactlyOnce() throws {
        let wire = Wire()
        let clock = HandDrivenScheduler()
        let reach = wire.sequence(clock)

        reach.begin(preferring: nil, candidates: ["000000"], rotatingTo: nil)
        reach.giveUp(because: "cannot use the radio")
        reach.giveUp(because: "and again")
        reach.candidateEnded(.wrongPIN)
        clock.tickAll()

        #expect(wire.finished.count == 1)
    }
}

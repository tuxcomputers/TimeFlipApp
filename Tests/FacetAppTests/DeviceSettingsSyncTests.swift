@testable import FacetApp
import Foundation
import XCTest

/// Covers telling the cube what the app's device settings say: what goes out on a link coming up, what goes out
/// because the cube disagreed, and what deliberately does not go out at all.
///
/// **The comparisons are the part worth pinning.** Two of these settings can be read back and two cannot, so the
/// right behaviour is different for each pair -- and an implementation that sent everything every time would pass a
/// test that only looked at the bytes, while writing to flash on every reconnect for no reason.
@MainActor
final class DeviceSettingsSyncTests: XCTestCase {
    /// What the pretend cube was told, in order.
    private final class Wire {
        var sent: [Data] = []
        /// Completions not yet answered, for the tests that need a command to still be out.
        var waiting: [(Bool) -> Void] = []
        /// The command byte of each write, which is what says *which* setting went.
        var commands: [UInt8] { sent.compactMap(\.first) }
    }

    private final class Link {
        var isCubeConnected = true
    }

    private var held = DeviceSettingsSync.Stored(
        autoPauseMinutes: 15,
        ledBrightnessPercent: 60,
        ledBlinkSeconds: 10,
        doubleTap: DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 50),
        isDoubleTapEnabled: true
    )
    private var moment = Date(timeIntervalSince1970: 1_800_000_000)

    private func sync(
        connected: Bool = true,
        link: Link? = nil,
        answering: Bool = true,
        on wire: Wire
    ) -> DeviceSettingsSync {
        let link = link ?? Link()
        link.isCubeConnected = connected
        return DeviceSettingsSync(
            send: { command, reported in
                wire.sent.append(command)
                if answering {
                    reported(true)
                } else {
                    wire.waiting.append(reported)
                }
            },
            isCubeConnected: { link.isCubeConnected },
            stored: { [self] in held },
            now: { [self] in moment },
            debugLog: nil
        )
    }

    private func status(autoPause: Int) -> DeviceCommandRules.Status {
        DeviceCommandRules.Status(isLocked: false, isPaused: false, autoPauseMinutes: autoPause)
    }

    // MARK: - a link coming up

    func testTheTwoValuesNothingCanReadBackGoOutOnEveryLink() {
        // `0x09` and `0x0A` have no read command in the spec at all, so there is no such thing as knowing whether the
        // cube still has them. The only alternative is a note the app writes to itself, which is the second copy the
        // first rule in `CLAUDE.md` forbids.
        let wire = Wire()
        let sync = sync(on: wire)

        sync.linkSettled()

        XCTAssertEqual(wire.commands, [0x09, 0x0A])
    }

    func testTheSettingsTheCubeCanBeAskedAboutAreNotSentBlind() {
        // Auto-pause and the registers are read back by the login, so a write is only worth making when the answer
        // disagreed. Sending them here as well would be a flash write per reconnect for nothing.
        let wire = Wire()
        let sync = sync(on: wire)

        sync.linkSettled()

        XCTAssertFalse(wire.commands.contains(0x05), "auto-pause waits to be contradicted")
        XCTAssertFalse(wire.commands.contains(0x16), "and so do the double-tap registers")
    }

    func testSettlingTwiceOnOneConnectionSendsNothingMore() {
        let wire = Wire()
        let sync = sync(on: wire)

        sync.linkSettled()
        sync.linkSettled()

        XCTAssertEqual(wire.commands, [0x09, 0x0A])
    }

    func testSettlingOnACubeThatHasGoneSendsNothing() {
        let wire = Wire()
        let sync = sync(connected: false, on: wire)

        sync.linkSettled()

        XCTAssertEqual(wire.sent, [])
    }

    // MARK: - what the cube says about itself

    func testAnAutoPauseTheCubeDisagreesWithIsSent() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()

        sync.cubeReported(status: status(autoPause: 0))

        XCTAssertEqual(wire.commands.last, 0x05)
        XCTAssertEqual(wire.sent.last, DeviceCommandRules.autoPause(15), "carrying what the table holds")
    }

    func testAnAutoPauseTheCubeAgreesWithIsNotSent() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        let before = wire.sent.count

        sync.cubeReported(status: status(autoPause: 15))

        XCTAssertEqual(wire.sent.count, before)
    }

    func testRegistersTheCubeDisagreesWithAreSent() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()

        sync.cubeReported(doubleTap: DoubleTapParameters(threshold: 10, limit: 20, latency: 50, window: 50))

        XCTAssertEqual(wire.commands.last, 0x16)
    }

    func testRegistersAreComparedAgainstWhatShouldBeOnTheCubeRatherThanWhatIsStored() {
        // **The disable is faked by sending `window` 0**, the hardware having no switch for the gesture. So a cube
        // with the gesture off should be reporting the zeroed form, and comparing against the stored form would send
        // `0x16` on every single connection.
        held.isDoubleTapEnabled = false
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        let before = wire.sent.count

        sync.cubeReported(doubleTap: DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 0))

        XCTAssertEqual(wire.sent.count, before, "the cube already has what it should have")
    }

    func testAReportFromACubeThatHasGoneSendsNothing() {
        let wire = Wire()
        let link = Link()
        let sync = sync(link: link, on: wire)
        sync.linkSettled()
        let before = wire.sent.count
        link.isCubeConnected = false

        sync.cubeReported(status: status(autoPause: 0))

        XCTAssertEqual(wire.sent.count, before)
    }

    // MARK: - the cube asking

    func testEachRequestIsAnsweredWithTheOneSettingItNames() {
        for (request, command) in [
            (DeviceSystemStateRules.CubeSyncState.autoPauseRequired, UInt8(0x05)),
            (.ledBrightnessRequired, 0x09),
            (.blinkIntervalRequired, 0x0A),
            (.timeRequired, 0x08),
        ] {
            let wire = Wire()
            let sync = sync(on: wire)
            sync.linkSettled()

            sync.cubeAsked(for: request)

            XCTAssertEqual(wire.commands.last, command, "\(request)")
        }
    }

    func testARequestNothingCanAnswerSendsNothing() {
        // The cube can ask for its task parameters, which this app has never set. Saying so in the log is the honest
        // answer; sending something invented would be worse than silence.
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        let before = wire.sent.count

        sync.cubeAsked(for: .taskParametersRequired)

        XCTAssertEqual(wire.sent.count, before)
        XCTAssertNil(DeviceSettingsSync.setting(for: .taskParametersRequired))
    }

    func testFaceColoursAreSomebodyElsesRequest() {
        // `FaceColourSync` answers that one and knows how to pace twelve writes. Two answers to one request would be
        // two runs of commands.
        XCTAssertNil(DeviceSettingsSync.setting(for: .faceColoursRequired))
    }

    func testARequestBeforeTheLoginHasFinishedIsHeld() {
        // Measured on this cube: it asks while the login still has a read out, and that read does not set
        // `isCommandInFlight` -- so a command sent now would be written over an exchange already in the air.
        let wire = Wire()
        let sync = sync(on: wire)

        sync.cubeAsked(for: .ledBrightnessRequired)

        XCTAssertEqual(wire.sent, [], "nothing goes out until the login settles")
    }

    func testRepeatedAskingIsCollapsed() {
        // A cube that is failing to hold its settings asks on every notification and every re-read, and each answer
        // here is a flash write. The archive's own measurement of what one-for-one costs is in `FaceColourSync`.
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        sync.cubeAsked(for: .autoPauseRequired)
        let after = wire.sent.count

        sync.cubeAsked(for: .autoPauseRequired)
        sync.cubeAsked(for: .autoPauseRequired)

        XCTAssertEqual(wire.sent.count, after)
    }

    func testAskingAgainOnceTheCooldownIsOverIsAnswered() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        sync.cubeAsked(for: .autoPauseRequired)
        let after = wire.sent.count

        moment = moment.addingTimeInterval(DeviceSettingsSync.cooldownSeconds + 1)
        sync.cubeAsked(for: .autoPauseRequired)

        XCTAssertEqual(wire.sent.count, after + 1)
    }

    // MARK: - one at a time, and read when it is built

    func testASecondSettingWaitsForTheFirstToComeBack() {
        // `DeviceLogin` queues commands itself, but this queue is what makes the *value* right: each command is built
        // when its turn comes, not when it was asked for.
        let wire = Wire()
        let sync = sync(answering: false, on: wire)

        sync.linkSettled()

        XCTAssertEqual(wire.commands, [0x09], "the blink period waits")
        wire.waiting.removeFirst()(true)
        XCTAssertEqual(wire.commands, [0x09, 0x0A])
    }

    func testTheValueIsReadWhenTheCommandIsBuiltRatherThanWhenItIsQueued() {
        let wire = Wire()
        let sync = sync(answering: false, on: wire)
        sync.linkSettled()
        XCTAssertEqual(wire.sent.first, DeviceCommandRules.ledBrightness(60))

        held.ledBlinkSeconds = 45
        wire.waiting.removeFirst()(true)

        XCTAssertEqual(wire.sent.last, DeviceCommandRules.ledBlink(45), "the edit that arrived mid-run is what went")
    }

    // MARK: - the link going

    func testTheLinkGoingDropsWhatWasQueuedAndStandsTheRunDown() {
        // **Forgetting the second half is a stall rather than a lost write**: a command out when the link goes is
        // never completed, so a sending flag left true would make every later connection queue and send nothing.
        let wire = Wire()
        let link = Link()
        let sync = sync(link: link, answering: false, on: wire)
        sync.linkSettled()
        XCTAssertEqual(wire.sent.count, 1, "precondition: one out, one queued")

        sync.linkEnded()
        link.isCubeConnected = true
        sync.linkSettled()

        XCTAssertEqual(wire.commands, [0x09, 0x09], "the new connection starts its own run")
    }
}

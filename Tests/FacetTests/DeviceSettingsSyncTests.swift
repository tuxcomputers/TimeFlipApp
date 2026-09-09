@testable import FacetCore
import Foundation
import Testing

/// Covers telling the cube what the app's device settings say: what goes out on a link coming up, what goes out
/// because the cube disagreed, and what deliberately does not go out at all.
///
/// **The comparisons are the part worth pinning.** Two of these settings can be read back and two cannot, so the
/// right behaviour is different for each pair -- and an implementation that sent everything every time would pass a
/// test that only looked at the bytes, while writing to flash on every reconnect for no reason.
@Suite @MainActor
final class DeviceSettingsSyncTests {
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

    @Test func testTheTwoValuesNothingCanReadBackGoOutOnEveryLink() {
        // `0x09` and `0x0A` have no read command in the spec at all, so there is no such thing as knowing whether the
        // cube still has them. The only alternative is a note the app writes to itself, which is the second copy the
        // first rule in `CLAUDE.md` forbids.
        let wire = Wire()
        let sync = sync(on: wire)

        sync.linkSettled()

        #expect(wire.commands == [0x09, 0x0A])
    }

    @Test func testTheSettingsTheCubeCanBeAskedAboutAreNotSentBlind() {
        // Auto-pause and the registers are read back by the login, so a write is only worth making when the answer
        // disagreed. Sending them here as well would be a flash write per reconnect for nothing.
        let wire = Wire()
        let sync = sync(on: wire)

        sync.linkSettled()

        #expect(!wire.commands.contains(0x05), "auto-pause waits to be contradicted")
        #expect(!wire.commands.contains(0x16), "and so do the double-tap registers")
    }

    @Test func testSettlingTwiceOnOneConnectionSendsNothingMore() {
        let wire = Wire()
        let sync = sync(on: wire)

        sync.linkSettled()
        sync.linkSettled()

        #expect(wire.commands == [0x09, 0x0A])
    }

    @Test func testSettlingOnACubeThatHasGoneSendsNothing() {
        let wire = Wire()
        let sync = sync(connected: false, on: wire)

        sync.linkSettled()

        #expect(wire.sent == [])
    }

    // MARK: - what the cube says about itself

    @Test func testAnAutoPauseTheCubeDisagreesWithIsSent() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()

        sync.cubeReported(status: status(autoPause: 0))

        #expect(wire.commands.last == 0x05)
        #expect(wire.sent.last == DeviceCommandRules.autoPause(15), "carrying what the table holds")
    }

    @Test func testAnAutoPauseTheCubeAgreesWithIsNotSent() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        let before = wire.sent.count

        sync.cubeReported(status: status(autoPause: 15))

        #expect(wire.sent.count == before)
    }

    @Test func testRegistersTheCubeDisagreesWithAreSent() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()

        sync.cubeReported(doubleTap: DoubleTapParameters(threshold: 10, limit: 20, latency: 50, window: 50))

        #expect(wire.commands.last == 0x16)
    }

    @Test func testRegistersAreComparedAgainstWhatShouldBeOnTheCubeRatherThanWhatIsStored() {
        // **The disable is faked by sending `window` 0**, the hardware having no switch for the gesture. So a cube
        // with the gesture off should be reporting the zeroed form, and comparing against the stored form would send
        // `0x16` on every single connection.
        held.isDoubleTapEnabled = false
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        let before = wire.sent.count

        sync.cubeReported(doubleTap: DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 0))

        #expect(wire.sent.count == before, "the cube already has what it should have")
    }

    @Test func testAReportFromACubeThatHasGoneSendsNothing() {
        let wire = Wire()
        let link = Link()
        let sync = sync(link: link, on: wire)
        sync.linkSettled()
        let before = wire.sent.count
        link.isCubeConnected = false

        sync.cubeReported(status: status(autoPause: 0))

        #expect(wire.sent.count == before)
    }

    // MARK: - the cube asking

    @Test func testEachRequestIsAnsweredWithTheOneSettingItNames() {
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

            #expect(wire.commands.last == command, "\(request)")
        }
    }

    @Test func testARequestNothingCanAnswerSendsNothing() {
        // The cube can ask for its task parameters, which this app has never set. Saying so in the log is the honest
        // answer; sending something invented would be worse than silence.
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        let before = wire.sent.count

        sync.cubeAsked(for: .taskParametersRequired)

        #expect(wire.sent.count == before)
        #expect(DeviceSettingsSync.setting(for: .taskParametersRequired) == nil)
    }

    @Test func testFaceColoursAreSomebodyElsesRequest() {
        // `FaceColourSync` answers that one and knows how to pace twelve writes. Two answers to one request would be
        // two runs of commands.
        #expect(DeviceSettingsSync.setting(for: .faceColoursRequired) == nil)
    }

    @Test func testARequestBeforeTheLoginHasFinishedIsHeld() {
        // Measured on this cube: it asks while the login still has a read out, and that read does not set
        // `isCommandInFlight` -- so a command sent now would be written over an exchange already in the air.
        let wire = Wire()
        let sync = sync(on: wire)

        sync.cubeAsked(for: .ledBrightnessRequired)

        #expect(wire.sent == [], "nothing goes out until the login settles")
    }

    @Test func testRepeatedAskingIsCollapsed() {
        // A cube that is failing to hold its settings asks on every notification and every re-read, and each answer
        // here is a flash write. The archive's own measurement of what one-for-one costs is in `FaceColourSync`.
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        sync.cubeAsked(for: .autoPauseRequired)
        let after = wire.sent.count

        sync.cubeAsked(for: .autoPauseRequired)
        sync.cubeAsked(for: .autoPauseRequired)

        #expect(wire.sent.count == after)
    }

    @Test func testAskingAgainOnceTheCooldownIsOverIsAnswered() {
        let wire = Wire()
        let sync = sync(on: wire)
        sync.linkSettled()
        sync.cubeAsked(for: .autoPauseRequired)
        let after = wire.sent.count

        moment = moment.addingTimeInterval(DeviceSettingsSync.cooldownSeconds + 1)
        sync.cubeAsked(for: .autoPauseRequired)

        #expect(wire.sent.count == after + 1)
    }

    // MARK: - one at a time, and read when it is built

    @Test func testASecondSettingWaitsForTheFirstToComeBack() {
        // `DeviceLogin` queues commands itself, but this queue is what makes the *value* right: each command is built
        // when its turn comes, not when it was asked for.
        let wire = Wire()
        let sync = sync(answering: false, on: wire)

        sync.linkSettled()

        #expect(wire.commands == [0x09], "the blink period waits")
        wire.waiting.removeFirst()(true)
        #expect(wire.commands == [0x09, 0x0A])
    }

    @Test func testTheValueIsReadWhenTheCommandIsBuiltRatherThanWhenItIsQueued() {
        let wire = Wire()
        let sync = sync(answering: false, on: wire)
        sync.linkSettled()
        #expect(wire.sent.first == DeviceCommandRules.ledBrightness(60))

        held.ledBlinkSeconds = 45
        wire.waiting.removeFirst()(true)

        #expect(wire.sent.last == DeviceCommandRules.ledBlink(45), "the edit that arrived mid-run is what went")
    }

    // MARK: - the link going

    @Test func testTheLinkGoingDropsWhatWasQueuedAndStandsTheRunDown() {
        // **Forgetting the second half is a stall rather than a lost write**: a command out when the link goes is
        // never completed, so a sending flag left true would make every later connection queue and send nothing.
        let wire = Wire()
        let link = Link()
        let sync = sync(link: link, answering: false, on: wire)
        sync.linkSettled()
        #expect(wire.sent.count == 1, "precondition: one out, one queued")

        sync.linkEnded()
        link.isCubeConnected = true
        sync.linkSettled()

        #expect(wire.commands == [0x09, 0x09], "the new connection starts its own run")
    }
}

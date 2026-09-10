@testable import FacetCore
import Foundation
import Testing

/// Covers `CubeCommandChannel`: the queue on the command characteristic, and the read-back discipline that decides
/// whether an answer arriving on the command result is this exchange's answer.
///
/// **These are the first unit tests this sequencing has ever had.** It lived in `DeviceLogin`, which owns a
/// `CBPeripheral`, and `DeviceLoginRulesTests` records why that meant none: "a `CBPeripheral` cannot be built
/// outside CoreBluetooth". So the two measured traps below were enforced only by a person turning a cube.
///
/// The transport is two closures and the deadline is `fire()`, so nothing here waits on a run loop. That is
/// deliberate beyond speed: on Linux a `@MainActor` swift-testing test does not run on the main thread, so a
/// `Timer` on `RunLoop.main` never fires and a suite that waited on one would fail with nothing to show for it.
@Suite @MainActor
final class CubeCommandChannelTests {
    /// What the channel asked the transport to do, in order.
    final class Wire {
        var transmitted: [Data] = []
        var reads = 0
        var statuses: [DeviceCommandRules.Status] = []
        var otherExchangeInFlight = false
    }

    private let wire = Wire()
    private let clock = HandDrivenScheduler()

    private func channel() -> CubeCommandChannel {
        CubeCommandChannel(
            scheduler: clock,
            transmit: { [wire] payload in wire.transmitted.append(payload) },
            readResult: { [wire] in wire.reads += 1 },
            status: { [wire] status in wire.statuses.append(status) },
            isOtherExchangeInFlight: { [wire] in wire.otherExchangeInFlight }
        )
    }

    /// A `0x10` answer: locked byte, paused byte, then the auto-pause delay big-endian.
    private func answer(locked: Bool = false, paused: Bool = false, autoPauseMinutes: Int = 5) -> Data {
        Data([
            locked ? 0x01 : 0x02,
            paused ? 0x01 : 0x02,
            UInt8(autoPauseMinutes >> 8),
            UInt8(autoPauseMinutes & 0xFF),
        ])
    }

    // MARK: - a command with nothing to read it back

    @Test("A command the spec cannot read back is settled by the write landing, and nothing is read")
    func aCommandWithNoReadBackEndsAtTheAcknowledgement() {
        let channel = self.channel()
        var reported: Bool?

        // `0x09`, LED brightness. `docs/timeflip.md`'s matrix gives it no read command at all.
        channel.send(DeviceCommandRules.ledBrightness(50)) { reported = $0 }
        #expect(wire.transmitted.count == 1)

        channel.acknowledged(landed: true)
        #expect(reported == true)
        // The point of the test: no second write asking whether it took, and no read.
        #expect(wire.transmitted.count == 1)
        #expect(wire.reads == 0)
        #expect(channel.isCommandInFlight == false)
    }

    @Test("A write the cube refuses is reported as not taken")
    func aRefusedWriteIsReportedFalse() {
        let channel = self.channel()
        var reported: Bool?

        channel.send(DeviceCommandRules.ledBrightness(50)) { reported = $0 }
        channel.acknowledged(landed: false)

        #expect(reported == false)
        #expect(wire.reads == 0)
        #expect(channel.isCommandInFlight == false)
    }

    // MARK: - a command that is asked about

    @Test("A command that can be read back is not believed until the cube says so")
    func aReadableCommandIsConfirmedByTheCube() {
        let channel = self.channel()
        var reported: Bool?

        channel.send(DeviceCommandRules.pause(true)) { reported = $0 }
        #expect(wire.transmitted == [DeviceCommandRules.pause(true)])

        // The write landed. That is not the answer, and the whole rule is that it is not treated as one.
        channel.acknowledged(landed: true)
        #expect(reported == nil)
        #expect(wire.transmitted.last == DeviceCommandRules.status)
        #expect(wire.reads == 0)

        // The question landed, so now the answer may be read.
        channel.acknowledged(landed: true)
        #expect(wire.reads == 1)
        #expect(reported == nil)

        channel.resultArrived(answer(paused: true))
        #expect(reported == true)
        #expect(channel.isCommandInFlight == false)
    }

    @Test("A cube that says it did not take is reported as not taken, though every write landed")
    func aCubeThatRefusesTheStateIsReportedFalse() {
        let channel = self.channel()
        var reported: Bool?

        channel.send(DeviceCommandRules.pause(true)) { reported = $0 }
        channel.acknowledged(landed: true)
        channel.acknowledged(landed: true)
        // Asked to pause, and the cube says it is running.
        channel.resultArrived(answer(paused: false))

        #expect(reported == false)
    }

    @Test("A question the cube will not take ends the exchange rather than reading anyway")
    func aRefusedReadBackQuestionEndsTheExchange() {
        let channel = self.channel()
        var reported: Bool?

        channel.send(DeviceCommandRules.pause(true)) { reported = $0 }
        channel.acknowledged(landed: true)
        channel.acknowledged(landed: false)

        #expect(reported == false)
        #expect(wire.reads == 0)
    }

    // MARK: - the first measured trap: a 0x10 answer identifies nothing

    @Test("A value on the command result before the question is acknowledged is not this exchange's answer")
    func aValueArrivingTooEarlyIsIgnored() {
        let channel = self.channel()
        var reported: Bool?

        channel.send(DeviceCommandRules.pause(true)) { reported = $0 }

        // The characteristic frequently holds the *previous* command's reply, and a `0x10` answer carries no
        // echoed command byte to say otherwise. So this one is somebody else's, and taking it would be a verdict
        // on a command the cube has not been asked about yet.
        #expect(channel.isAwaitingResult == false)
        channel.resultArrived(answer(paused: true))
        #expect(reported == nil)

        // The same bytes, once the sequence has earned the right to read them.
        channel.acknowledged(landed: true)
        channel.acknowledged(landed: true)
        channel.resultArrived(answer(paused: true))
        #expect(reported == true)
    }

    @Test("Bytes that are not a status at all are refused rather than read as unlocked")
    func bytesThatAreNotAStatusAreRefused() {
        let channel = self.channel()
        var answered: DeviceCommandRules.Status??

        channel.askStatus { answered = $0 }
        channel.acknowledged(landed: true)
        // A leftover login verdict. `02` alone is not four bytes and both mode bytes have to be `0x01` or `0x02`.
        channel.resultArrived(Data([0x02]))

        #expect(answered == .some(nil))
        #expect(wire.statuses.isEmpty)
    }

    // MARK: - a plain question about the state

    @Test("A plain question is written, waited for, and only then read")
    func askStatusWaitsForItsOwnAcknowledgement() {
        let channel = self.channel()
        var answered: DeviceCommandRules.Status??

        channel.askStatus { answered = $0 }
        #expect(wire.transmitted == [DeviceCommandRules.status])
        // Already awaiting a result, because for this exchange the write *is* the question.
        #expect(channel.isAwaitingResult == true)
        #expect(wire.reads == 0)

        channel.acknowledged(landed: true)
        #expect(wire.reads == 1)

        channel.resultArrived(answer(locked: true, autoPauseMinutes: 300))
        #expect(answered??.isLocked == true)
        #expect(answered??.autoPauseMinutes == 300)
        // A locked cube reports itself paused whatever its pause byte says, which is the second measured trap and
        // is `DeviceCommandRules`' to enforce. Asserted here so the channel is shown to pass it through unaltered.
        #expect(answered??.isPaused == true)
    }

    @Test("Whatever the cube says about itself is published, whichever question drew it out")
    func theStatusIsPublishedForBothKindsOfExchange() {
        let channel = self.channel()

        channel.askStatus { _ in }
        channel.acknowledged(landed: true)
        channel.resultArrived(answer(autoPauseMinutes: 7))
        #expect(wire.statuses.count == 1)

        channel.send(DeviceCommandRules.pause(true)) { _ in }
        channel.acknowledged(landed: true)
        channel.acknowledged(landed: true)
        channel.resultArrived(answer(paused: true, autoPauseMinutes: 7))
        // Twice: the read-back's answer is as much a statement about the cube as the plain ask's was.
        #expect(wire.statuses.count == 2)
    }

    // MARK: - the queue

    @Test("A second exchange waits its turn rather than being refused")
    func aSecondExchangeWaits() {
        let channel = self.channel()
        var first: Bool?
        var second: Bool?

        channel.send(DeviceCommandRules.ledBrightness(10)) { first = $0 }
        channel.send(DeviceCommandRules.ledBrightness(20)) { second = $0 }

        // Only the first has gone out. The second is queued, not declined: a caller told `false` here would
        // believe the cube had refused it.
        #expect(wire.transmitted == [DeviceCommandRules.ledBrightness(10)])
        #expect(second == nil)

        channel.acknowledged(landed: true)
        #expect(first == true)
        #expect(wire.transmitted.count == 2)

        channel.acknowledged(landed: true)
        #expect(second == true)
    }

    @Test("A caller may send from inside its own completion, which is what the lock sequence does")
    func sendingFromInsideACompletionWorks() {
        let channel = self.channel()
        var pauseTook: Bool?
        var lockTook: Bool?
        /// Whether the lock had actually gone out by the time the pause's completion returned.
        ///
        /// **This is the assertion that pins the ordering**, and a plain "the lock went out eventually" does not:
        /// `finishExchange` ends with `startNextIfIdle`, so a slot still holding the finished exchange would queue
        /// the lock and then start it a moment later anyway. Mutation-checked on 2026-09-09: moving the two `nil`s
        /// after the completions leaves every other test in this suite green, and fails only this line.
        var lockWentOutDuringTheCompletion: Bool?

        channel.send(DeviceCommandRules.pause(true)) { took in
            pauseTook = took
            // Exactly the shape of `CubeLock.lock`: pause first, and send the lock from the pause's completion.
            channel.send(DeviceCommandRules.lock(true)) { lockTook = $0 }
            lockWentOutDuringTheCompletion = self.wire.transmitted.last == DeviceCommandRules.lock(true)
        }
        channel.acknowledged(landed: true)
        channel.acknowledged(landed: true)
        channel.resultArrived(answer(paused: true))
        #expect(pauseTook == true)

        // The lock went out rather than being refused as "already busy", which is what a slot still holding the
        // finished exchange would have done.
        #expect(lockWentOutDuringTheCompletion == true)
        #expect(wire.transmitted.last == DeviceCommandRules.lock(true))
        channel.acknowledged(landed: true)
        channel.acknowledged(landed: true)
        channel.resultArrived(answer(locked: true))
        #expect(lockTook == true)
    }

    @Test("An exchange this channel does not own still holds the queue, and ending it releases it")
    func aForeignExchangeHoldsTheQueue() {
        let channel = self.channel()
        var reported: Bool?

        // A double-tap read or a factory reset: on the same characteristic, owned by the login.
        wire.otherExchangeInFlight = true
        channel.send(DeviceCommandRules.ledBrightness(30)) { reported = $0 }
        #expect(wire.transmitted.isEmpty)
        #expect(channel.isCommandInFlight == true)

        wire.otherExchangeInFlight = false
        channel.startNextIfIdle()
        #expect(wire.transmitted.count == 1)
        channel.acknowledged(landed: true)
        #expect(reported == true)
    }

    @Test("An acknowledgement arriving while only a foreign exchange is out is not answered for")
    func aForeignAcknowledgementIsNotTaken() {
        let channel = self.channel()
        wire.otherExchangeInFlight = true

        // The login deals with its own exchanges' acknowledgements. This one must not be read as a command's.
        channel.acknowledged(landed: true)

        #expect(wire.transmitted.isEmpty)
        #expect(wire.reads == 0)
    }

    // MARK: - the deadline

    @Test("An exchange the cube never answers is given up on, and the queue moves on")
    func theDeadlineEndsTheExchangeAndStartsTheNext() throws {
        let channel = self.channel()
        var first: Bool?
        var second: Bool?

        channel.send(DeviceCommandRules.pause(true)) { first = $0 }
        channel.send(DeviceCommandRules.ledBrightness(40)) { second = $0 }
        #expect(channel.scheduledSeconds == CubeCommandChannel.timeoutSeconds)

        try clock.tick()

        #expect(first == false)
        // The one behind it is not stranded by the one in front timing out.
        #expect(wire.transmitted.last == DeviceCommandRules.ledBrightness(40))
        // And it gets a deadline of its own rather than inheriting the elapsed one, which is why this is still
        // armed here: giving up on one exchange is not giving up on the channel.
        #expect(channel.scheduledSeconds == CubeCommandChannel.timeoutSeconds)

        channel.acknowledged(landed: true)
        #expect(second == true)
        #expect(channel.scheduledSeconds == nil)
    }

    @Test("The deadline is re-armed for the read-back, so the question gets its own full wait")
    func theDeadlineIsRearmedForTheQuestion() {
        let channel = self.channel()

        channel.askStatus { _ in }
        #expect(channel.scheduledSeconds == CubeCommandChannel.timeoutSeconds)
        channel.acknowledged(landed: true)
        // Still armed: the answer has not arrived, and the wait for it is not the wait for the write.
        #expect(channel.scheduledSeconds == CubeCommandChannel.timeoutSeconds)

        channel.resultArrived(answer())
        #expect(channel.scheduledSeconds == nil)
    }

    // MARK: - the link going

    @Test("A channel dropped with work in it answers nobody")
    func aDroppedChannelAnswersNobody() {
        // **This is what the link going actually is**, rather than a method that says so: `BluetoothRadio`
        // drops the `DeviceLogin` on every path that clears `connectedDevice`, and the channel goes with it.
        //
        // Neither caller is told anything, which is the point. A caller given `false` could not tell a cube
        // that refused from a cube that is not there, and those have opposite remedies.
        var reported: Bool?
        var answered: DeviceCommandRules.Status??
        let before: Int
        do {
            let channel = self.channel()
            channel.send(DeviceCommandRules.pause(true)) { reported = $0 }
            channel.askStatus { answered = $0 }
            before = wire.transmitted.count
        }

        #expect(reported == nil)
        #expect(answered == nil)
        #expect(wire.transmitted.count == before, "and nothing queued goes out on the next link")
    }
}

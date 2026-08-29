@testable import FacetApp
import Foundation
import XCTest

/// Covers the commands this app sends a cube, and how each one is read back.
///
/// **The read-back is the point of most of these.** An acknowledged write says the cube heard, never that it obeyed
/// -- a cube refuses commands until a PIN is accepted, and refuses them *after* the write has already succeeded -- so
/// what decides whether a command took is the cube's own answer to a question about its state. See the rule in
/// `CLAUDE.md` and the per-command matrix in `docs/timeflip.md`.
final class DeviceCommandRulesTests: XCTestCase {
    /// A `0x10` answer: lock, pause, then the auto-pause delay in minutes, big-endian.
    private func status(locked: UInt8, paused: UInt8, minutes: UInt16 = 0) -> Data {
        Data([locked, paused, UInt8(minutes >> 8), UInt8(minutes & 0xFF)])
    }

    // MARK: - the bytes

    func testTheBytesAreTheVendorsOwn() {
        // Pinned as bytes rather than as calls, because a wrong second byte is a valid command doing the opposite.
        XCTAssertEqual(DeviceCommandRules.pause(true), Data([0x06, 0x01]))
        XCTAssertEqual(DeviceCommandRules.pause(false), Data([0x06, 0x02]))
        XCTAssertEqual(DeviceCommandRules.lock(true), Data([0x04, 0x01]))
        XCTAssertEqual(DeviceCommandRules.lock(false), Data([0x04, 0x02]))
        XCTAssertEqual(DeviceCommandRules.status, Data([0x10]))
    }

    func testTheLEDBytesAreTheVendorsOwnToo() {
        // `0x09 0xXX` brightness in %, `0x0A 0xXX` the gap between flashes in seconds. Pinned as bytes for the reason
        // above: the two commands differ by one, so a transposition is a valid command setting the wrong thing.
        XCTAssertEqual(DeviceCommandRules.ledBrightness(80), Data([0x09, 80]))
        XCTAssertEqual(DeviceCommandRules.ledBlink(30), Data([0x0A, 30]))
    }

    func testTheLEDRangesAreTheSpecsAndTheCommandKeepsToThem() {
        // 1-100 and 5-60, and neither starts at zero: a cube cannot be told to put its LED out this way, so 0 is a
        // value the firmware refuses rather than an off switch.
        XCTAssertEqual(DeviceCommandRules.brightnessRange, 1...100)
        XCTAssertEqual(DeviceCommandRules.blinkRange, 5...60)

        // Clamped on the way to the wire as well as in the field somebody types into. The field is what stops a bad
        // number being chosen; this is what stops one being sent, which matters because a value can also come out of
        // a database row nobody in this app wrote.
        XCTAssertEqual(DeviceCommandRules.ledBrightness(0), Data([0x09, 1]))
        XCTAssertEqual(DeviceCommandRules.ledBrightness(9_999), Data([0x09, 100]))
        XCTAssertEqual(DeviceCommandRules.ledBlink(0), Data([0x0A, 5]))
        XCTAssertEqual(DeviceCommandRules.ledBlink(1_000), Data([0x0A, 60]))
    }

    func testTheAutoPauseBytesAreTheVendorsOwnToo() {
        // `0x05 0xXX 0xXX`, the delay in minutes as two bytes high-then-low. The order is the archive's
        // (`TimeFlipBLEDevice.setAutoPause`), the spec giving the width and not the order, and it is the way round
        // `0x10` answers -- so a transposition here would set 256 minutes where 1 was asked for.
        XCTAssertEqual(DeviceCommandRules.autoPause(0), Data([0x05, 0x00, 0x00]), "0 disables it")
        XCTAssertEqual(DeviceCommandRules.autoPause(15), Data([0x05, 0x00, 0x0F]))
        XCTAssertEqual(DeviceCommandRules.autoPause(240), Data([0x05, 0x00, 0xF0]))
    }

    func testTheAutoPauseRangeIsKeptOnTheWayToTheWire() {
        // The field a person types into is what stops a bad number being chosen; this is what stops one being sent,
        // which matters because the value can also come out of a database row nobody in this app wrote.
        XCTAssertEqual(DeviceCommandRules.autoPauseRange, 0...240)
        XCTAssertEqual(DeviceCommandRules.autoPause(-5), Data([0x05, 0x00, 0x00]))
        XCTAssertEqual(DeviceCommandRules.autoPause(9_999), Data([0x05, 0x00, 0xF0]))
    }

    func testTheMinutesAreReadBackOutOfTheCommandsOwnBytes() {
        // One place knows the layout, which is what the read-back compares against: what went out, rather than a
        // number handed to it alongside. Reading a command that is not a `0x05` answers nothing at all.
        XCTAssertEqual(DeviceCommandRules.autoPauseMinutes(sentIn: DeviceCommandRules.autoPause(45)), 45)
        XCTAssertEqual(DeviceCommandRules.autoPauseMinutes(sentIn: Data([0x05, 0x01, 0x00])), 256, "high byte first")
        XCTAssertNil(DeviceCommandRules.autoPauseMinutes(sentIn: DeviceCommandRules.pause(true)))
        XCTAssertNil(DeviceCommandRules.autoPauseMinutes(sentIn: Data([0x05, 0x00])), "a byte short of a command")
    }

    // MARK: - what the cube says it is doing

    func testARealAnswerIsRead() {
        let running = DeviceCommandRules.status(from: status(locked: 0x02, paused: 0x02, minutes: 30))

        XCTAssertEqual(running, DeviceCommandRules.Status(isLocked: false, isPaused: false, autoPauseMinutes: 30))
    }

    func testTheAutoPauseDelayIsBigEndian() {
        // The way `0x05` writes it: high byte then low. Read the other way round, 256 minutes would come back as 1.
        let answer = DeviceCommandRules.status(from: status(locked: 0x02, paused: 0x02, minutes: 256))

        XCTAssertEqual(answer?.autoPauseMinutes, 256)
    }

    func testALockedCubeCountsAsPausedWhateverItsPauseByteSays() {
        // The archive's reading, and `docs/timeflip.md`'s "pause (0x01/0x02 unless locked)". The consequence is a
        // sequencing rule rather than a curiosity: a pause read back after a lock proves nothing, because the answer
        // is `true` either way -- which is why the quit confirms the pause before it sends the lock.
        let locked = DeviceCommandRules.status(from: status(locked: 0x01, paused: 0x02))

        XCTAssertEqual(locked?.isLocked, true)
        XCTAssertEqual(locked?.isPaused, true, "a locked cube reports itself paused")
    }

    func testSomebodyElsesAnswerIsRefused() {
        // Nothing in a `0x10` reply identifies it as one -- no echoed command byte, unlike `0x17` -- and finding 2 of
        // `docs/timeflip2-firmware-observations.md` is that this characteristic often holds the previous command's
        // reply. Refusing bytes that are not modes at all is the only inspection available.
        XCTAssertNil(DeviceCommandRules.status(from: Data([0x02])), "the login verdict, alone")
        XCTAssertNil(DeviceCommandRules.status(from: Data([0x17, 0x3A, 0x5A, 0x3B])), "a stale double-tap answer")
        XCTAssertNil(DeviceCommandRules.status(from: Data([0x00, 0x01, 0x00, 0x00])), "0x00 is not a mode")
        XCTAssertNil(DeviceCommandRules.status(from: nil))
        XCTAssertNil(DeviceCommandRules.status(from: Data()))
    }

    func testAnAnswerCutShortIsRefused() {
        XCTAssertNil(DeviceCommandRules.status(from: Data([0x02, 0x02, 0x00])))
    }

    // MARK: - which question confirms which command

    func testAPauseIsConfirmedByTheStatus() throws {
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.pause(true)))

        XCTAssertEqual(readBack.request, DeviceCommandRules.status)
        XCTAssertTrue(readBack.took(status(locked: 0x02, paused: 0x01)))
        XCTAssertFalse(readBack.took(status(locked: 0x02, paused: 0x02)), "still running, so it did not take")
    }

    func testDoubleTapIsConfirmedRegisterByRegister() throws {
        // `0x16` has a read-back, so it is one of the commands `CLAUDE.md` says must be read before it is believed.
        // The answer echoes `0x17` and all four register addresses, so unlike `0x10` it identifies itself.
        let wanted = DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 0)
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DoubleTapRules.command(for: wanted)))

        XCTAssertEqual(readBack.request, Data([DoubleTapRules.read]))
        XCTAssertTrue(readBack.took(Data([0x17, 0x3A, 90, 0x3B, 20, 0x3C, 50, 0x3D, 0])))
    }

    func testADoubleTapAnswerThatDiffersInOneRegisterDidNotTake() throws {
        // The whole point of confirming this one: the cube taking three of the four registers and not the fourth is a
        // gesture still firing while the app believes it is off. Window is the register that matters most, being the
        // one the disable trick moves.
        let wanted = DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 0)
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DoubleTapRules.command(for: wanted)))

        XCTAssertFalse(
            readBack.took(Data([0x17, 0x3A, 90, 0x3B, 20, 0x3C, 50, 0x3D, 50])),
            "the window came back at 50, so the gesture is still on"
        )
    }

    func testAStaleReplyIsNotADoubleTapConfirmation() throws {
        // The command result characteristic frequently holds the previous command's reply (finding 2,
        // `docs/timeflip2-firmware-observations.md`). A `0x10` sitting there must not read as this command's answer.
        let wanted = DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 0)
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DoubleTapRules.command(for: wanted)))

        XCTAssertFalse(readBack.took(status(locked: 0x02, paused: 0x02)))
        XCTAssertFalse(readBack.took(nil))
    }

    func testTheDoubleTapAnswerIsPutIntoWords() throws {
        // So a refused write names the registers the cube is actually on. `took` collapses the answer to yes or no,
        // which is all the caller needs and much less than whoever reads the row afterwards: the numbers beside the
        // verdict are the disagreement itself.
        let wanted = DoubleTapParameters(threshold: 200, limit: 45, latency: 34, window: 0)
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DoubleTapRules.command(for: wanted)))

        XCTAssertEqual(
            readBack.described(Data([0x17, 0x3A, 200, 0x3B, 45, 0x3C, 34, 0x3D, 0])),
            "Threshold: 200, Limit: 45, Latency: 34, Window: 0"
        )
    }

    func testWhatWasNotAnAnswerIsPutIntoNoWordsAtAll() throws {
        // `nil` rather than a guess, and for the same reason the parse is strict: the characteristic frequently holds
        // the previous command's reply, and printing numbers out of somebody else's would be worse than printing
        // none.
        let wanted = DoubleTapParameters(threshold: 200, limit: 45, latency: 34, window: 0)
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DoubleTapRules.command(for: wanted)))

        XCTAssertNil(readBack.described(status(locked: 0x02, paused: 0x02)))
        XCTAssertNil(readBack.described(nil))
    }

    func testACommandWithNoInterpretationSaysNothing() throws {
        // Only `0x16` puts its answer into words today. A pause is confirmed by a status whose four bytes carry no
        // echoed command byte, so there is nothing there worth naming that the verdict does not already say.
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.pause(true)))

        XCTAssertNil(readBack.described(status(locked: 0x02, paused: 0x01)))
    }

    func testAResumeIsConfirmedTheOtherWayRound() throws {
        // The command asked for pause *off*, so an answer saying paused is a failure. Reading "took" as "the cube
        // answered" rather than "the cube is in the state asked for" would call this a success.
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.pause(false)))

        XCTAssertTrue(readBack.took(status(locked: 0x02, paused: 0x02)))
        XCTAssertFalse(readBack.took(status(locked: 0x02, paused: 0x01)))
    }

    func testALockIsConfirmedByTheStatus() throws {
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.lock(true)))

        XCTAssertTrue(readBack.took(status(locked: 0x01, paused: 0x01)))
        XCTAssertFalse(readBack.took(status(locked: 0x02, paused: 0x01)))
    }

    func testAnUnlockIsConfirmedByTheStatus() throws {
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.lock(false)))

        XCTAssertTrue(readBack.took(status(locked: 0x02, paused: 0x02)))
        XCTAssertFalse(readBack.took(status(locked: 0x01, paused: 0x01)), "still locked, so it did not take")
    }

    func testAnAnswerThatIsNotAnAnswerNeverConfirms() throws {
        // A refusal, a leftover, a cube that said nothing: none of them is evidence the command took.
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.pause(true)))

        XCTAssertFalse(readBack.took(nil))
        XCTAssertFalse(readBack.took(Data([0x02])))
    }

    func testAutoPauseIsConfirmedByTheStatus() throws {
        // `0x05` has a read-back, so it is one of the commands `CLAUDE.md` says must be read before it is believed.
        // The answer is `0x10`'s, which carries the delay the cube is set to.
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.autoPause(15)))

        XCTAssertEqual(readBack.request, DeviceCommandRules.status)
        XCTAssertTrue(readBack.took(status(locked: 0x02, paused: 0x02, minutes: 15)))
        XCTAssertFalse(readBack.took(status(locked: 0x02, paused: 0x02, minutes: 14)), "a minute out is not it")
        XCTAssertFalse(readBack.took(status(locked: 0x02, paused: 0x02)), "and off is certainly not it")
    }

    func testAutoPauseIsConfirmedAgainstWhatWasSentRatherThanWhatWasAskedFor() throws {
        // The clamp is why this matters. A field asking for 300 sends 240, so a cube answering 240 has done exactly
        // what it was told -- and comparing against the number somebody typed would report that as a refusal.
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.autoPause(300)))

        XCTAssertTrue(readBack.took(status(locked: 0x02, paused: 0x02, minutes: 240)))
    }

    func testAnAutoPauseAnswerThatIsNotAnAnswerNeverConfirms() throws {
        // A `0x10` reply carries no echoed command byte, so what this can refuse is bytes that are not a status at
        // all: a leftover login verdict, or a stale `0x17`, whose mode fields are not modes.
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.autoPause(0)))

        XCTAssertFalse(readBack.took(Data([0x02])), "a login verdict sitting in the characteristic")
        XCTAssertFalse(readBack.took(Data([0x17, 0x3A, 90, 0x3B])), "somebody else's answer")
        XCTAssertFalse(readBack.took(nil), "and nothing at all")
    }

    func testARefusedAutoPauseNamesWhatTheCubeIsOn() throws {
        // What `described` is for: a refusal that says only "it did not take" leaves the disagreement to be guessed
        // at, where the number the cube reports is the whole of it.
        let readBack = try XCTUnwrap(DeviceCommandRules.readBack(for: DeviceCommandRules.autoPause(15)))

        XCTAssertEqual(readBack.described(status(locked: 0x02, paused: 0x02, minutes: 5)), "auto-pause 5m")
        XCTAssertNil(readBack.described(Data([0x02])), "and bytes that were not an answer are put into no words")
    }

    func testACommandWithNoReadBackSaysSo() {
        // `nil` is an answer, not a gap: LED brightness, blink interval and face colour have no read command in the
        // spec, so for those the write really is the only evidence there is.
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0x09, 50])), "LED brightness")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0x0A, 10])), "blink interval")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0x11, 1, 0, 0, 0, 0, 0, 0])), "face colour")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0xFF])), "a factory reset, which is confirmed by a login")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data()))
    }

    // MARK: - the cube's clock

    func testSettingTheClockIsTheCommandThenEightBigEndianBytes() {
        // The vendor's format: `0x08` then `uint64_t` seconds since 1970, in UTC.
        XCTAssertEqual(
            DeviceCommandRules.setTime(1_787_295_649),
            Data([0x08, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x87, 0xF7, 0xA1])
        )
    }

    func testAskingTheTimeIsOneByte() {
        XCTAssertEqual(DeviceCommandRules.readTime, Data([0x07]))
    }

    func testTheAnswerIsReadFromTheWideForm() {
        // Eight bytes with a zero high half, which is what the spec describes and what the traces show.
        let answer = Data([0x07, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x87, 0xF7, 0xA1])

        XCTAssertEqual(DeviceCommandRules.time(from: answer), 1_787_295_649)
    }

    func testTheAnswerIsReadFromTheNarrowFormToo() {
        // Firmware that answers in 32 bits, which `docs/timeflip.md` records and the archive tolerated. A big-endian
        // read over whatever arrives gives the same answer for both, since the wide form's high half is zero.
        XCTAssertEqual(DeviceCommandRules.time(from: Data([0x07, 0x6A, 0x87, 0xF7, 0xA1])), 1_787_295_649)
    }

    func testTheRealPaddedAnswerFromTheCubeIsRead() {
        // **Off the wire on 2026-08-21**, and the one that caught the bug. The characteristic is 20 bytes wide, so the
        // answer arrives with eleven zeros after it -- and a big-endian read over the whole remainder shifts the real
        // value out of the top and leaves nothing, which reported a correctly set clock as a failure.
        var measured = Data([0x07, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x88, 0x20, 0xA9])
        measured.append(Data(repeating: 0, count: 11))

        XCTAssertEqual(measured.count, 20)
        XCTAssertEqual(DeviceCommandRules.time(from: measured), 1_787_306_153)
    }

    func testAPaddedAnswerConfirmsTheCommandThatAskedForIt() {
        // The whole point of reading it: the same bytes, through the read-back the app actually uses.
        var measured = Data([0x07, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x88, 0x20, 0xA9])
        measured.append(Data(repeating: 0, count: 11))

        let readBack = DeviceCommandRules.readBack(for: DeviceCommandRules.setTime(1_787_306_153))

        XCTAssertEqual(readBack?.took(measured), true)
    }

    func testSomethingElseIsNotATime() {
        // The echoed command byte is checked, and it is worth having: unlike a `0x10` reply this answer identifies
        // itself, so a leftover from the previous command cannot be read as a clock.
        XCTAssertNil(DeviceCommandRules.time(from: Data([0x10, 0x01, 0x01, 0x00, 0x05])))
        XCTAssertNil(DeviceCommandRules.time(from: Data([0x07, 0x00])), "too short to carry one")
        XCTAssertNil(DeviceCommandRules.time(from: nil))
    }

    func testAClockOfZeroIsNoAnswer() {
        // A cube that has never been told the time, which is the state this whole command exists for. Reporting it as
        // 1970 would be a timestamp rather than the absence of one.
        XCTAssertNil(DeviceCommandRules.time(from: Data([0x07, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    func testSettingTheClockIsConfirmedByReadingIt() {
        let command = DeviceCommandRules.setTime(1_787_295_649)
        let readBack = DeviceCommandRules.readBack(for: command)

        XCTAssertEqual(readBack?.request, DeviceCommandRules.readTime)
        XCTAssertEqual(readBack?.took(Data([0x07, 0, 0, 0, 0, 0x6A, 0x87, 0xF7, 0xA1])), true)
    }

    /// The `0x07` answer a cube whose clock reads `seconds` would give.
    private func clockReading(_ seconds: UInt64) -> Data {
        var bytes = [UInt8](DeviceCommandRules.setTime(seconds))
        bytes[0] = 0x07
        return Data(bytes)
    }

    func testAClockASecondOrTwoOutStillCounts() {
        // Not equality, because time passes: the write, its acknowledgement and the read are three round trips, and
        // the cube counts in whole seconds. An exact comparison would fail whenever one straddled a second boundary.
        let asked: UInt64 = 1_787_295_649
        let readBack = DeviceCommandRules.readBack(for: DeviceCommandRules.setTime(asked))

        for drift in [UInt64(1), 2, DeviceCommandRules.timeTolerance] {
            XCTAssertEqual(readBack?.took(clockReading(asked + drift)), true, "\(drift)s late")
            XCTAssertEqual(readBack?.took(clockReading(asked - drift)), true, "\(drift)s early")
        }
    }

    func testAClockJustOutsideTheToleranceDoesNot() {
        let asked: UInt64 = 1_787_295_649
        let readBack = DeviceCommandRules.readBack(for: DeviceCommandRules.setTime(asked))

        XCTAssertEqual(readBack?.took(clockReading(asked + DeviceCommandRules.timeTolerance + 1)), false)
    }

    func testAClockWildlyOutDoesNotCount() {
        // The error this is meant to catch is a clock that was never set at all, which is far outside any round trip.
        let readBack = DeviceCommandRules.readBack(for: DeviceCommandRules.setTime(1_787_295_649))

        XCTAssertEqual(readBack?.took(Data([0x07, 0, 0, 0, 0, 0, 0, 0, 0x01])), false)
        XCTAssertEqual(readBack?.took(nil), false)
    }
}

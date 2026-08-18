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

    func testACommandWithNoReadBackSaysSo() {
        // `nil` is an answer, not a gap: LED brightness, blink interval and face colour have no read command in the
        // spec, so for those the write really is the only evidence there is.
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0x09, 50])), "LED brightness")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0x0A, 10])), "blink interval")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0x11, 1, 0, 0, 0, 0, 0, 0])), "face colour")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data([0xFF])), "a factory reset, which is confirmed by a login")
        XCTAssertNil(DeviceCommandRules.readBack(for: Data()))
    }
}

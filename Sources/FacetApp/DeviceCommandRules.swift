import Foundation

/// The commands this app sends a cube that are not part of logging in to it.
///
/// **The bytes are the vendor's**, from `docs/TimeFlip2 BLE Protocol v4.3.md` Tab. 1, and each is written as a
/// function of on/off rather than as the one constant this app happens to send today. Half a command is a worse thing
/// to have written down than none: somebody reaching for "how do I unpause it" would otherwise find a `pauseOn` and
/// have to go back to the spec to learn that the answer is `0x02` and not `0x00`.
enum DeviceCommandRules {
    /// Pause mode: `0x06 0x01` on, `0x06 0x02` off.
    ///
    /// **Pause stops the clock and leaves the cube awake.** The spec's own footnote: time counting is paused, but the
    /// facets go on being notified, so somebody can still flip the cube and assign faces while it is paused, and the
    /// interval the cube files for the paused stretch carries `Side + 128`. That last part is why a paused cube's
    /// history is still readable rather than simply absent.
    static func pause(_ on: Bool) -> Data {
        Data([pauseCommand, on ? 0x01 : 0x02])
    }

    /// Lock mode: `0x04 0x01` on, `0x04 0x02` off.
    ///
    /// **Lock freezes the cube on the face it is on.** The spec's footnote again: it "freezes TimeFlip to count time
    /// on the last active facet and blocks the device from switching facets when TimeFlip is flipped". So a locked
    /// cube that is not also paused goes on recording against whatever face was up, which is exactly why the two are
    /// sent together and in that order.
    static func lock(_ on: Bool) -> Data {
        Data([lockCommand, on ? 0x01 : 0x02])
    }

    /// Sets the cube's clock (`0x08`): the command byte then the epoch as `uint64` big-endian, in **UTC**.
    ///
    /// **The cube stamps every history frame with this clock**, so a cube whose time has never been set has nothing to
    /// date an interval with. `docs/timeflip.md` puts "set device time" first in the sequence a factory reset calls
    /// for, and the system state characteristic has a code for the cube asking for it outright (`0x0201`,
    /// `timeRequired`). The archive set it on every connect (`TimeFlipBLEDevice.initializeSession`) and this app now
    /// does the same.
    ///
    /// **UTC, and the spec is explicit about it** ("in utc(0) format"), so this takes seconds since the epoch and no
    /// timezone enters into it. Which timezone a segment is *displayed* in is `timezone`'s question, decided when the
    /// row is written, and nothing to do with what the cube counts in.
    static func setTime(_ secondsSinceEpoch: UInt64) -> Data {
        var bytes: [UInt8] = [timeCommand]
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: secondsSinceEpoch >> (8 * (7 - $0))) }
        return Data(bytes)
    }

    /// Asks what the cube's clock says (`0x07`). The answer echoes the command byte, unlike `0x10`.
    static let readTime = Data([readTimeCommand])

    /// The seconds in a `0x07` answer, or `nil` when it is not one.
    ///
    /// **Two four-byte candidates, and the first non-zero one wins.** This is the archive's tolerance
    /// (`TimeFlipBLEDevice.readDeviceTime`) copied as it stands, and the reason is in its own comment: "payload
    /// sometimes comes as 8 bytes with leading zeros then BE timestamp", while `docs/timeflip.md` adds that some
    /// firmware historically answered in 32 bits. The wide form puts the seconds in the *second* four bytes and the
    /// narrow form puts them in the first, so trying each in turn reads both.
    ///
    /// **Reading "everything after the command byte" as one big-endian number does not work, and the shortcut cost a
    /// false failure the day it was written.** The characteristic is 20 bytes wide and the answer is padded with
    /// zeros, so a shift over the whole remainder pushes the real value out of the top and leaves nothing: the cube
    /// echoed `07 00 00 00 00 6A 88 20 A9` followed by eleven zeros, which was exactly the time it had been asked for,
    /// and the app reported that the clock would not set (2026-08-21). Anything reading this field must take a fixed
    /// number of bytes and ignore the padding.
    ///
    /// **The echoed `0x07` is checked**, and it is worth having: this is one of the few answers on the command result
    /// that identifies itself, so unlike a `0x10` reply it cannot be mistaken for the previous command's.
    static func time(from value: Data?) -> UInt64? {
        guard let value, value.count >= 5, value[value.startIndex] == readTimeCommand else { return nil }
        let payload = [UInt8](value.dropFirst())
        for start in [0, 4] where payload.count >= start + 4 {
            var seconds: UInt64 = 0
            for byte in payload[start..<(start + 4)] { seconds = seconds << 8 | UInt64(byte) }
            if seconds > 0 { return seconds }
        }
        return nil
    }

    /// How far out a clock read back after `0x08` may be and still count as set.
    ///
    /// **Not equality, because time passes.** The write, its acknowledgement and the read are three round trips, each
    /// around 100 ms in the traces, and the cube's clock has one-second resolution -- so an exact comparison would
    /// report a perfectly good write as a failure roughly whenever it straddled a second boundary. Five seconds is far
    /// wider than any round trip seen and far narrower than the error this is meant to catch, which is a clock that was
    /// never set at all.
    static let timeTolerance: UInt64 = 5

    /// Status request (`0x10`): the read-back that says whether a pause or a lock actually took.
    ///
    /// Neither command has an answer of its own beyond the write being acknowledged, and an acknowledgement says the
    /// cube heard rather than that it obeyed -- see the read-back rule in `CLAUDE.md`. The answer arrives on the
    /// command result as `0xXX 0xYY 0xZZ 0xZZ`: lock mode, pause mode, and the auto-pause delay in minutes.
    static let status = Data([0x10])

    /// What the cube says it is doing.
    struct Status: Equatable {
        let isLocked: Bool
        let isPaused: Bool
        /// The auto-pause delay in minutes, `0` meaning disabled.
        let autoPauseMinutes: Int
    }

    /// The four bytes of a `0x10` answer, or `nil` when they are not one.
    ///
    /// **A locked cube counts as paused whatever its pause byte says.** The archive reads it exactly this way
    /// (`paused = locked ? true : data[1] == 0x01`) and `docs/timeflip.md` records the same, as "pause (0x01/0x02
    /// unless locked)". The consequence is a sequencing rule rather than a detail: a pause read back *after* a lock
    /// tells you nothing, because the answer would be `true` either way.
    ///
    /// **The auto-pause delay is big-endian**, matching the way `0x05` writes it (high byte then low).
    ///
    /// **Nothing here identifies the answer as an answer**, which is why callers must only read after this command's
    /// own acknowledgement: unlike `0x17`, a `0x10` reply carries no echoed command byte, and the characteristic it
    /// arrives on frequently holds the previous command's reply. What this can do is refuse bytes that are not a
    /// status at all -- both mode bytes have to be `0x01` or `0x02`, which is what a leftover login verdict (`02`
    /// alone) or a stale `0x17` answer fails.
    static func status(from value: Data?) -> Status? {
        guard let value, value.count >= 4, let locked = mode(value[0]), let paused = mode(value[1]) else { return nil }
        return Status(
            isLocked: locked,
            isPaused: locked ? true : paused,
            autoPauseMinutes: Int(value[2]) << 8 | Int(value[3])
        )
    }

    /// `0x01` on, `0x02` off, anything else not a mode at all.
    private static func mode(_ byte: UInt8) -> Bool? {
        switch byte {
        case 0x01: return true
        case 0x02: return false
        default: return nil
        }
    }

    /// How a command is read back, for the commands that can be.
    ///
    /// Given to `DeviceLogin.send`, so the rule lives in one place instead of at each call site: a caller sends a
    /// command and is told whether the cube *is now in the state it asked for*, rather than whether the bytes landed.
    struct ReadBack {
        /// The command that asks the question.
        let request: Data
        /// Whether the answer says the command took.
        let took: (Data?) -> Bool
    }

    /// What confirms `command`, or `nil` for one the vendor spec gives no way to read back.
    ///
    /// **`nil` is an answer, not a gap.** LED brightness (`0x09`), blink interval (`0x0A`) and face colour (`0x11`)
    /// have no read command in the spec at all, so for those the write really is the only evidence there is, and the
    /// app is the system of record. See the matrix in `docs/timeflip.md`.
    static func readBack(for command: Data) -> ReadBack? {
        guard command.count >= 2 else { return nil }
        let wanted = command[1] == 0x01
        switch command[0] {
        case pauseCommand:
            return ReadBack(request: status) { status(from: $0)?.isPaused == wanted }
        case lockCommand:
            return ReadBack(request: status) { status(from: $0)?.isLocked == wanted }
        case DoubleTapRules.write:
            // **Confirmed register by register, against the command's own bytes.** `0x17` answers in the same
            // nine-byte shape `0x16` was written in, so what went out and what came back are compared as parsed
            // values rather than as two descriptions of them.
            //
            // **This one identifies itself**, unlike `0x10`: the answer echoes `0x17` and all four register
            // addresses, which is what `DoubleTapRules.parameters(from:)` checks every byte of. A leftover reply
            // sitting in the characteristic (finding 2, `docs/timeflip2-firmware-observations.md`) fails that shape
            // rather than being mistaken for this command's answer.
            guard let asked = DoubleTapRules.parameters(sentIn: command) else { return nil }
            return ReadBack(request: Data([DoubleTapRules.read])) { DoubleTapRules.parameters(from: $0) == asked }
        case timeCommand:
            // The clock this command asked for, read back out of the command's own bytes rather than passed in
            // alongside them: there is one place that knows the layout and it is `setTime`.
            var asked: UInt64 = 0
            for byte in command.dropFirst() { asked = asked << 8 | UInt64(byte) }
            return ReadBack(request: readTime) { answer in
                guard let told = time(from: answer) else { return false }
                return told > asked
                    ? told - asked <= timeTolerance
                    : asked - told <= timeTolerance
            }
        default:
            return nil
        }
    }

    private static let lockCommand: UInt8 = 0x04
    private static let pauseCommand: UInt8 = 0x06
    private static let readTimeCommand: UInt8 = 0x07
    private static let timeCommand: UInt8 = 0x08
}

import Foundation

/// The cube's history: what to ask for, how to read a frame of the answer, and where to resume from.
///
/// **Values in, values out**, which is the split every device rules type here keeps: `swift test` cannot scan, so the
/// part worth testing must not be the part that needs a cube on the desk. What talks to the radio is `DeviceLogin`,
/// what writes rows is `DeviceEventRecorder`, and what sequences the two is `HistoryIngestor`. This decides.
///
/// **The frame layout is the vendor's and the traps are the archive's**, both recorded in `docs/timeflip.md` §5 before
/// this app existed. Everything below that is not simply a byte offset was paid for by a real device or a real
/// database, and is marked where it sits.
enum DeviceHistoryRules {
    /// One frame on the history characteristic, which is always 20 bytes.
    static let frameLength = 20

    /// How many frames a single stream may deliver before it is abandoned.
    ///
    /// **The archive's cap, kept.** A cube holds far fewer than this, so reaching it means the stream is not ending --
    /// a sentinel that never came, or frames that keep parsing as something. Stopping is better than reading for ever,
    /// and the next refresh starts again from what actually landed.
    static let frameCap = 2048

    // MARK: - asking

    /// Asks for one event. `nil` asks for **the last one**, which is what the cube is on right now.
    ///
    /// `0xFFFFFFFF` is the vendor's own "give me the latest" and is why this takes an optional rather than a magic
    /// number at the call site.
    static func readEvent(_ eventNumber: Int? = nil) -> Data {
        Data([0x01]) + bigEndian(eventNumber.map(UInt32.init(clamping:)) ?? 0xFFFF_FFFF)
    }

    /// Asks for every event from `eventNumber` onwards, as a stream of notifications ending in a sentinel.
    ///
    /// **From it, not past it.** The newest row on file is normally the cube's still-open segment, and asking for it
    /// again is how its finished duration comes back. Advancing past it would lose exactly that.
    static func readHistory(from eventNumber: Int) -> Data {
        Data([0x02]) + bigEndian(UInt32(clamping: max(eventNumber, 0)))
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    // MARK: - reading an answer

    /// What kind of answer a history frame is.
    ///
    /// **Three answers, which is why this is a state and not two booleans.** It was `isEndOfStream` and
    /// `isNoSuchEvent`, and the second had to test the first before it could answer, because a terminator is also
    /// four zero bytes. One classifier decides once, in order, and a caller cannot ask them the wrong way round.
    enum HistoryFrameState: Equatable {
        /// A real event, there to be read into a segment.
        case event
        /// The cube saying it has no such event, which is how "no history at all" arrives.
        case noSuchEvent
        /// The terminator.
        case endOfStream
    }

    /// Which of the three this frame is.
    ///
    /// **Order matters and is the whole point of doing it here.** End of stream is tested first, because its
    /// seventeen zeros also satisfy the four-zero test that says "no such event".
    static func historyFrameState(_ frame: Data) -> HistoryFrameState {
        if isEndOfStream(frame) { return .endOfStream }
        if isNoSuchEvent(frame) { return .noSuchEvent }
        return .event
    }

    /// Whether this frame is the end of the stream.
    ///
    /// **Seventeen zeros, not twenty.** The spec draws the sentinel as an all-zero frame; the archive checks the first
    /// seventeen because bytes 18 and 19 carry a previous-event pointer that some firmware fills in regardless. A
    /// stricter check would read a real terminator as a frame and go on waiting.
    private static func isEndOfStream(_ frame: Data) -> Bool {
        guard frame.count >= 17 else { return true }
        return frame.prefix(17).allSatisfy { $0 == 0 }
    }

    /// Whether this frame is the cube saying it has no such event, which is how "no history at all" arrives.
    ///
    /// **A different answer from a frame this app cannot read, and telling them apart is the whole point.** Both come
    /// back as `nil` from `segment(from:)`, but one is an ordinary state and the other is a fault worth chasing -- and
    /// reporting the ordinary one as a parse failure cost a long session on 2026-08-21 looking for a bug in the
    /// parser while the cube was answering perfectly correctly.
    ///
    /// The cube fills the event number with zero and leaves junk in the duration field, which is measured rather than
    /// documented: what arrives is thirteen zero bytes and then four that track the cube's own clock, ticking a second
    /// at a time between requests. `docs/timeflip2-firmware-evidence.sqlite` holds the same answer given to the
    /// previous app, so it is the firmware's habit rather than anything this app provoked.
    private static func isNoSuchEvent(_ frame: Data) -> Bool {
        guard frame.count >= 4, !isEndOfStream(frame) else { return false }
        return frame.prefix(4).allSatisfy { $0 == 0 }
    }

    /// Reads one frame into a segment, or answers `nil` for anything that is not one.
    ///
    /// **The layout is the vendor spec's own table**, which `docs/TimeFlip2 BLE Protocol v4.3.md` draws under
    /// *History read request for a single event* as bytes 0 to 16 -- **seventeen**, not twenty:
    ///
    /// - `0...3` `N event`, `u32` big-endian. **Zero is not an event.** The cube answers a request for an event it
    ///   does not have with a frame numbered 0, so this is how "there is no history" arrives, and the archive reads it
    ///   the same way ("treat zero eventNumber frames as sentinel-like")
    /// - `4` `Side`. Above 127 the interval was **paused** and the face is `value - 128`; `66` is the cube reporting
    ///   an accelerometer error rather than a face; `0` is not a face at all
    /// - `5...12` `Moment flip`, seconds since the epoch, `u64` big-endian
    /// - `13...16` `Duration side`, **four** bytes -- see `duration(from:)` for the byte order, which is measured
    ///   rather than documented
    /// - `17...19` present only on the streamed form, where the vendor's example shows a previous-event pointer.
    ///   Ignored here as it is there
    ///
    /// **Seventeen bytes, and requiring eighteen was a real bug**: a single-event answer is exactly this length, so
    /// every reply to `0x01` was thrown away with "a frame this app cannot read" while the cube was answering
    /// perfectly well (measured 2026-08-21). `docs/timeflip.md` describes a five-byte duration at `13...17` and is
    /// wrong about both, which is why `CLAUDE.md` puts the vendor spec above it.
    static func segment(from frame: Data) -> DeviceEventSegment? {
        guard frame.count >= 17, !isEndOfStream(frame) else { return nil }
        let bytes = [UInt8](frame)

        let eventNumber = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        // The cube's way of saying it has nothing to give, so it is not a segment and not an error either.
        guard eventNumber > 0 else { return nil }
        guard let face = face(from: bytes[4]) else { return nil }

        var startEpoch: UInt64 = 0
        for byte in bytes[5...12] { startEpoch = startEpoch << 8 | UInt64(byte) }
        // A segment that began at the epoch is a frame that did not carry a time, not one from 1970.
        guard startEpoch > 0 else { return nil }

        return DeviceEventSegment(
            eventNumber: eventNumber,
            face: face,
            startedAt: Date(timeIntervalSince1970: TimeInterval(startEpoch)),
            durationSeconds: TimeInterval(duration(from: Array(bytes[13..<min(bytes.count, 17)]))),
            isPaused: bytes[4] > 127
        )
    }

    /// `Duration side`, from the four bytes the vendor's table gives it.
    ///
    /// **Copied from the archive as it stands** (`TimeFlipHistoryParser.durationTolerant`), because it is a
    /// measurement rather than a preference and re-deriving it costs the same experiment: firmware disagrees with its
    /// own spec about the byte order of this one field, so both readings are taken and the **smaller** non-zero one
    /// wins. That works because a plausible duration is a small number: 90 seconds is `00 00 00 5A` one way round and
    /// `1509949440` the other, so the sane interpretation is always the lesser. Its own comment records the evidence,
    /// "prefer 4-byte big-endian at bytes 13-16 (observed on firmware shipping 2026-01)".
    static func duration(from bytes: [UInt8]) -> UInt64 {
        var big: UInt64 = 0
        for byte in bytes { big = big << 8 | UInt64(byte) }
        var little: UInt64 = 0
        for (shift, byte) in bytes.enumerated() { little |= UInt64(byte) << (8 * shift) }
        return [big, little].filter { $0 > 0 }.min() ?? 0
    }

    /// The face a frame's byte 4 names, and whether that interval was paused.
    ///
    /// **Paused intervals are recorded, not discarded.** The vendor's own note: pausing adds an interval to the
    /// history "for the facet with Side + 128", so the cube keeps the stretch and marks it. `device_event.paused` is
    /// the column for it, and dropping the frame would lose the fact that the time was accounted for at all.
    ///
    /// `66` is the cube saying its accelerometer failed, which is not a face and not a segment.
    private static func face(from byte: UInt8) -> Int? {
        guard byte != accelerometerError else { return nil }
        let face = byte > 127 ? Int(byte) - 128 : Int(byte)
        return DeviceFaceRules.reported.contains(face) ? face : nil
    }

    /// Byte 4's value when the cube is reporting a broken accelerometer rather than a face.
    static let accelerometerError: UInt8 = 66

    // MARK: - where to resume

    /// Whether the segment on file and the one the cube reports are the same stretch of time.
    ///
    /// **The number *and* the start, never the number alone.** A factory reset restarts the counter, so a post-reset
    /// event 10 is not the event 10 already on file -- and treating them as one skips the stream that would bring
    /// events 1 to 9 of the new generation in. Measured against a copy of the previous app's production database,
    /// where comparing numbers alone wrote one row where ten were due and lost nine segments silently.
    static func isSameSegment(_ mark: DeviceEventMark, as segment: DeviceEventSegment) -> Bool {
        mark.eventNumber == segment.eventNumber
            && mark.startEpoch == Int(segment.startedAt.timeIntervalSince1970)
    }

    /// Which event a stream should start at, given the newest row on file and the cube's own last event.
    ///
    /// **The stored position is used only if the cube can still reach it**, in the counter *and* the clock. Failing
    /// either, the stream starts from the beginning: the position names a segment the cube no longer has, so asking
    /// for it returns nothing -- for ever, while the events it does hold are never fetched.
    ///
    /// Two ways it fails, and the second is why the clock is compared at all:
    ///
    /// - **A lower number**, which is what a factory reset does to the counter.
    /// - **An earlier start.** Within one generation a later event never begins before an earlier one, so a "newer"
    ///   event that started before the row on file proves the generation changed. This catches a reset that has
    ///   already counted back up past the stored number, where nothing about the numbers looks wrong.
    ///
    /// `>=` on the epoch rather than `>`, because a zero-length segment can share its second with the one after it --
    /// the previous app's production database holds several.
    ///
    /// **A cube that did not answer leaves the position standing**, so a timed-out read re-requests the same thing
    /// rather than re-streaming everything the cube holds.
    ///
    /// **A cube reporting no history at all is that same case, and it is knowingly left alone.** An empty cube is a
    /// reset one, so the stored position is unreachable and the stream from it comes straight back as a sentinel --
    /// which repeats until the cube has anything at all, and then heals on its own: the cheap check answers, the two
    /// tests below catch the generation change, and the next stream starts from the beginning. Restarting from zero on
    /// an empty answer would buy nothing but one wasted request per refresh in the meantime.
    ///
    /// **What this still does not cover**, and the archive says so too: a cube reset while the app was not running,
    /// which then counts *past* the stored position before the next launch. It reports both a higher number and a
    /// later start, so both tests pass and the two generations merge with the new one's early events never ingested.
    /// Telling that apart needs a second read -- asking the cube for its own event 10 and seeing that it began at a
    /// different second from the row on file.
    static func resumeFrom(_ mark: DeviceEventMark, deviceLast: DeviceEventSegment?) -> Int {
        guard mark != .none else { return 0 }
        guard let deviceLast else { return mark.eventNumber }
        // The cube is sitting on the very segment already recorded. `HistoryIngestor` answers that case before asking
        // this, but the rule stays true on its own rather than only in the context of its caller.
        if isSameSegment(mark, as: deviceLast) { return mark.eventNumber }
        guard deviceLast.eventNumber > mark.eventNumber,
              Int(deviceLast.startedAt.timeIntervalSince1970) >= mark.startEpoch else { return 0 }
        return mark.eventNumber
    }

    /// Splits a fetched stream into the segments that are finished and the one still running.
    ///
    /// **The last frame of a complete dump is the cube's open interval**, which is measured behaviour rather than
    /// anything the spec says: the cube reuses that event number and refreshes its duration every few seconds, so it
    /// is the same segment arriving again with a larger figure. Everything before it has been closed out by the frame
    /// that follows it.
    ///
    /// Sorted by event number rather than trusted in arrival order, and de-duplicated to the last frame seen for each
    /// number: a stream can repeat one, and the later copy is the more recent account of it.
    static func split(_ segments: [DeviceEventSegment]) -> (finished: [DeviceEventSegment], open: DeviceEventSegment?) {
        var newest: [Int: DeviceEventSegment] = [:]
        for segment in segments { newest[segment.eventNumber] = segment }
        let ordered = newest.values.sorted { $0.eventNumber < $1.eventNumber }
        guard let open = ordered.last else { return ([], nil) }
        return (Array(ordered.dropLast()), open)
    }

    /// Whether the frame the stream ended on is really the cube's current one.
    ///
    /// **A stream cut short also ends on a frame**, and that frame is a closed segment with more history behind it
    /// that simply has not arrived. Recording it as the open one would put a stale segment on screen as what is
    /// happening now, and the next refresh would resume from the wrong place. So it counts as current only if it
    /// reaches the event the cube named as its last, read before the stream started.
    ///
    /// A cube that did not answer that read leaves nothing to check against, and the stream is taken at its word.
    static func isCurrent(_ open: DeviceEventSegment, deviceLast: DeviceEventSegment?) -> Bool {
        guard let deviceLast else { return true }
        return open.eventNumber >= deviceLast.eventNumber
    }
}

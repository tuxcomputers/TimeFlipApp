import Foundation

/// One timing segment, as whatever reported it describes it: a stretch of time on one face, which either
/// counted or was paused.
///
/// The device's own history stream is the eventual source (`docs/timeflip.md` §5), and manual mode is a
/// second one -- the app timing by hand is still a thing that produces segments, so it produces these
/// rather than a parallel kind of row.
///
/// `eventNumber` is the reporter's own counter and is **not** an identity on its own: see
/// `DeviceEventRules.decision`.
struct DeviceEventSegment: Equatable {
    /// The reporter's counter for this event. `Int` rather than `UInt32`, which is the width on the wire:
    /// every `UInt32` fits, and the comparisons below stay ordinary signed arithmetic with no trap.
    let eventNumber: Int

    /// Which face was up. 1...12 are the cube's; 13 is manual mode's (`ManualFace.id`), and the table's
    /// `CHECK (device_face BETWEEN 1 AND 13)` is what refuses anything else.
    let face: Int

    /// When the segment began.
    let startedAt: Date

    /// How long it has run so far. Grows while the segment is still open, so the same segment arrives
    /// repeatedly with a larger figure.
    let durationSeconds: TimeInterval

    /// Whether this stretch was paused, i.e. present but not counting.
    let isPaused: Bool

    init(eventNumber: Int, face: Int, startedAt: Date, durationSeconds: TimeInterval, isPaused: Bool) {
        self.eventNumber = eventNumber
        self.face = face
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.isPaused = isPaused
    }

    /// Whole seconds since 1970, which is the resolution the device reports and so the resolution the table
    /// stores (`start_epoch`). Two genuinely different segments can share one of these, which is the whole
    /// reason `eventNumber` is carried alongside it.
    var startEpoch: Int {
        Int(startedAt.timeIntervalSince1970)
    }
}

/// Where the newest row in `device_event` sits, in the only terms that order two segments.
///
/// Read from the table when it is needed rather than carried in memory: the previous app kept this as a
/// pair of scalars seeded at startup and advanced on every write, which is precisely the two-copies-of-one-
/// fact shape the first rule in `CLAUDE.md` exists to forbid. The read is a covered index lookup
/// (`IN1_device_event`) at the rate a person flips a cube, so there is nothing to buy by holding it.
struct DeviceEventMark: Equatable {
    /// No rows at all. `-1` rather than an optional so every comparison below is ordinary: a real epoch is
    /// always greater, so an empty table always takes the insert-as-open path without a special case.
    static let none = DeviceEventMark(startEpoch: -1, eventNumber: -1)

    let startEpoch: Int
    let eventNumber: Int
}

/// What to do with an incoming segment. **The decisions only**, taken against numbers, so they can be
/// asserted without a database: `DeviceEventRecorder` is what reads, writes and reports.
enum DeviceEventRules {

    /// What recording a segment amounts to.
    enum Decision: Equatable {
        /// This exact segment is already on record, so its row is brought up to date in place. `finalised`
        /// is false only while it is still the newest thing on record: the open segment being re-sent with a
        /// larger duration is the normal case here.
        ///
        /// In place rather than `ON CONFLICT DO UPDATE`, which burns an `AUTOINCREMENT` id on every update
        /// and leaves permanent gaps in `device_event_id`.
        case update(rowID: Int, finalised: Bool)

        /// Never seen, and newer than anything on record: whatever row is still open is closed first, then
        /// this is inserted as the open one. A history dump's last frame is always the segment in progress.
        case insertAsOpen

        /// Never seen, but not the newest: it arrived out of order, so it cannot be what is happening now
        /// and goes in already closed. Unusual, and not a failure.
        case insertClosed
    }

    /// Decides between the three, from what is already on record.
    ///
    /// **Identity is the pair `(eventNumber, startEpoch)`**, which is what `existingRowID` is looked up by,
    /// and neither column will do on its own. `eventNumber` is a counter kept by the device, so a reset (a
    /// battery pull, or the vendor's own app) restarts it low, and matching on it alone would either
    /// overwrite an unrelated old row or refuse a legitimate new segment. `startEpoch` is whole seconds, and
    /// two real segments genuinely share one -- a quick flip across a face on the way to another, which is
    /// what the `blip_time` setting is about. Both together collide only if a reset reuses a number in the
    /// same wall-clock second as the row it lands on.
    ///
    /// **Ordering is the pair too, with the epoch dominating.** Measured on the device 2026-08-12: a daily
    /// limit's pause produced events 72 through 76 inside one second, and with the epoch as the only test
    /// the close-out stopped firing after 72 -- leaving 72 claiming forever to be the live segment beside
    /// the row that really was. A row stuck like that is never converted, so time with it is lost. The
    /// epoch still dominates, so a device reset (later epoch, low counter) is decided on the epoch and
    /// never has its counter compared.
    ///
    /// Note the equality in the `update` arm: a re-send of the live row **is** the mark rather than past it,
    /// so `finalised` is decided by matching the mark exactly, not by `isNewer`. Testing the epoch alone
    /// there re-opened an earlier row from the same second every time the device re-sent it.
    static func decision(for segment: DeviceEventSegment, existingRowID: Int?, mark: DeviceEventMark) -> Decision {
        if let existingRowID {
            let isTheMark = segment.startEpoch == mark.startEpoch && segment.eventNumber == mark.eventNumber
            return .update(rowID: existingRowID, finalised: !isTheMark)
        }
        return isNewer(segment, than: mark) ? .insertAsOpen : .insertClosed
    }

    /// Whether a segment is newer than the newest on record. See `decision` for why it is the pair.
    static func isNewer(_ segment: DeviceEventSegment, than mark: DeviceEventMark) -> Bool {
        if segment.startEpoch != mark.startEpoch {
            return segment.startEpoch > mark.startEpoch
        }
        return segment.eventNumber > mark.eventNumber
    }

    /// The `event_type` row this segment belongs to, by name rather than by id: the id is the reference
    /// table's business, and naming it here means a renumbered seed cannot silently retype every event.
    ///
    /// Only these two, because only these two are segments. The other seeded types (`double_tap`,
    /// `battery_level`, and the rest) are things the device reports *about itself* and are not stretches of
    /// time on a face, so nothing here can produce one.
    static func eventTypeName(isPaused: Bool) -> String {
        isPaused ? "pause" : "face_flip"
    }
}

import Foundation

/// One `time_entry` as a Google Calendar event: what it is called, what it says, when it ran, and how to tell
/// afterwards that the event Google kept is the one that was sent.
///
/// **The event's id is worked out rather than stored.** It is derived from the `time_entry` id, so the same entry
/// always addresses the same event, and no column has to be added to `time_entry` to remember what Google called it.
/// Two things follow, and they are the reason for doing it this way:
///
/// - **A repeated insert cannot make a duplicate.** Google refuses a second event with an id it already has (409),
///   which turns "the app crashed between writing the event and ticking the row" from a duplicated event into a
///   no-op. A server-assigned id would give the sweep no way to tell its own earlier work from a fresh entry.
/// - **The read-back knows where to look.** Step 2 of the design is fetching the event again to check it, and with a
///   derived id that is a `GET` at a known address rather than a search.
///
/// The archive had none of this. `GoogleCalendarClient.swift` has `insertEvent`, which posts a
/// summary, a description and two dates and never reads anything back, and nothing ever called it -- the sync itself
/// was never built there. So its event shape is **massaged**: the four fields it sent are the right four, and
/// everything about identity, verification and which zone the times are in is new.
enum GoogleEventRules {
    /// How many entries one pass sends before starting another pass.
    ///
    /// A batch size, not a cap: a full batch means the sweep goes round again, so a database with a year of unsynced
    /// entries still drains. It exists so that a single pass holds a bounded number of rows in memory and so that a
    /// failure part way through costs one batch rather than everything.
    static let batchSize = 50

    /// The event id for an entry.
    ///
    /// Google's ids are base32hex: the digits `0-9` and the letters `a-v`, at least 5 characters. `facet` happens to
    /// be five letters all inside that alphabet, and a `time_entry` id is digits, so the two concatenate into a legal
    /// id with nothing to escape or encode.
    ///
    /// **`time_entry_id` is `AUTOINCREMENT`**, so sqlite never hands the same id to a second row even after deletes
    /// (`009_time_entry.sql`). That is what makes this safe to derive rather than store: two different entries cannot
    /// collide on one event.
    static func eventID(forTimeEntry timeEntryID: Int) -> String {
        "facet\(timeEntryID)"
    }

    /// What the event says in its notes.
    ///
    /// Both ids, because they answer different questions: the `time_entry` id finds the row this event was made from,
    /// and the `device_event` id finds the segment that row was made from -- which is the one that carries the
    /// original event number and start from the cube.
    static func description(timeEntryID: Int, deviceEventID: Int) -> String {
        "Facet time entry \(timeEntryID)\nDevice event \(deviceEventID)"
    }

    /// A time as Google wants it: RFC 3339, **with the offset of the zone the time was recorded in**.
    ///
    /// The zone is the entry's own `start_timezone_id`, not the machine's current one. The archive sent
    /// `TimeZone.current.identifier` for every event it built, which is right until somebody travels or until history
    /// is ingested from a cube that recorded it somewhere else: the entry would then be filed at the right clock time
    /// in the wrong zone, which is the wrong moment.
    ///
    /// The formatter is built per call rather than held. One shared instance would have to be mutated to set its zone,
    /// and a mutable shared formatter is not something to hand a strict-concurrency compiler; this runs at the rate a
    /// person flips a cube, so the allocation is not worth arguing about.
    static func dateTime(epoch: Int, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter.string(from: Date(timeIntervalSince1970: Double(epoch)))
    }

    /// The zone a stored `timezone_name` means, falling back to the machine's own.
    ///
    /// `timezone` is seeded with an `Unknown` row at id 0 (`002_timezone.sql`) and every timestamp column defaults to
    /// it, so a row filed before a real zone was resolved lands here. Guessing the current zone is better than
    /// refusing to sync the entry: the wrong offset is a recoverable annoyance, an entry that never syncs is silent.
    static func timeZone(named name: String?) -> TimeZone {
        guard let name, let zone = TimeZone(identifier: name) else { return .current }
        return zone
    }

    /// What one entry should look like at Google.
    ///
    /// Built from the row and then used twice: once to make the event, and once as the thing the read-back is compared
    /// against. One value rather than two constructions of the same expectation, so a check cannot drift from what was
    /// actually sent.
    struct Expected: Equatable {
        var eventID: String
        var summary: String
        var description: String
        /// **Whole seconds, and held as epochs rather than as `Date`s.** This is not a storage preference, it is the
        /// fix for a bug that stopped the whole feature dead: `dateTime(epoch:in:)` takes an `Int`, so a moment
        /// carrying a fraction was truncated on the way to Google and *not* truncated on the way to the comparison.
        /// Google returned exactly what it had been sent, the read-back then disagreed with the expectation by
        /// 0.6 of a second, and the entry could never be marked synced. Measured on `time_entry` 27, whose
        /// `duration_seconds` is 147.612311840057 (2026-08-15).
        ///
        /// Making the type unable to hold a fraction is what stops that coming back: there is now one value, and
        /// what is sent and what is compared are the same number by construction rather than by both call sites
        /// remembering to round the same way.
        var startEpoch: Int
        var endEpoch: Int
        var timeZoneName: String

        var start: Date { Date(timeIntervalSince1970: Double(startEpoch)) }
        var end: Date { Date(timeIntervalSince1970: Double(endEpoch)) }
    }

    /// The body of `events.insert`.
    ///
    /// `summary` is the category's name, which is Google's word for the title shown on the calendar. `timeZone` beside
    /// each `dateTime` is not redundant with the offset already in it: the offset says which moment, the zone says
    /// which rules to re-render it under, which is what makes the event show at the right local time for a reader in
    /// another zone.
    static func body(for expected: Expected) -> Data? {
        let zone = timeZone(named: expected.timeZoneName)
        let start = dateTime(epoch: expected.startEpoch, in: zone)
        let end = dateTime(epoch: expected.endEpoch, in: zone)
        let object: [String: Any] = [
            "id": expected.eventID,
            "summary": expected.summary,
            "description": expected.description,
            "start": ["dateTime": start, "timeZone": expected.timeZoneName],
            "end": ["dateTime": end, "timeZone": expected.timeZoneName],
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// An event as Google reports it back.
    struct Event: Equatable, Sendable {
        var id: String
        var summary: String?
        var description: String?
        var start: Date?
        var end: Date?
        /// Google keeps deleted events as `cancelled` rather than removing them, and a cancelled event still answers a
        /// `GET`. Without this the read-back of an event the user deleted would look like a successful sync.
        var isCancelled: Bool
    }

    static func event(fromResponse data: Data) -> Event? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String, !id.isEmpty
        else {
            return nil
        }
        return Event(
            id: id,
            summary: object["summary"] as? String,
            description: object["description"] as? String,
            start: moment(fromEndpoint: object["start"]),
            end: moment(fromEndpoint: object["end"]),
            isCancelled: (object["status"] as? String) == "cancelled"
        )
    }

    /// Reads one end of an event's span.
    ///
    /// **Only `dateTime` counts.** An all-day event carries `date` instead, which is a day rather than a moment and
    /// cannot be compared with the second-resolution span an entry has. Facet never creates one, so finding one means
    /// somebody edited the event into a shape this cannot verify, and reporting no moment is the honest answer.
    private static func moment(fromEndpoint value: Any?) -> Date? {
        guard let object = value as? [String: Any], let text = object["dateTime"] as? String else { return nil }
        return internetDate().date(from: text)
    }

    /// Parses to an **instant**, so the comparison is between moments and not between strings. Google is free to
    /// answer in a different offset for the same moment, and a text comparison would then report a mismatch on two
    /// spellings of one time.
    ///
    /// Built per call rather than held as a `static let`: `ISO8601DateFormatter` is a mutable class and not
    /// `Sendable`, so a shared one is a compile error under strict concurrency rather than a judgement call.
    private static func internetDate() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// What differs between the event Google kept and the event that was sent.
    enum Mismatch: Equatable {
        case wrongEvent
        case cancelled
        case summary
        case description
        case start
        case end

        var described: String {
            switch self {
            case .wrongEvent: return "it is a different event"
            case .cancelled: return "the event has been deleted"
            case .summary: return "the title does not match"
            case .description: return "the description does not match"
            case .start: return "the start does not match"
            case .end: return "the end does not match"
            }
        }
    }

    /// Checks the read-back against what was sent, and answers `nil` when they agree.
    ///
    /// **This is what a tick in `synced_to_google_calendar` means.** The flag says the event is at Google and is
    /// right, so it is set from what Google says it has rather than from the insert having returned a success -- an
    /// event created and then altered would otherwise be recorded as synced for good, and nothing would ever look
    /// again.
    ///
    /// Checked in the order a person would: is it the right event at all, is it still there, then each field.
    static func mismatch(between event: Event, and expected: Expected) -> Mismatch? {
        guard event.id == expected.eventID else { return .wrongEvent }
        guard !event.isCancelled else { return .cancelled }
        guard event.summary == expected.summary else { return .summary }
        guard event.description == expected.description else { return .description }
        guard event.start == expected.start else { return .start }
        guard event.end == expected.end else { return .end }
        return nil
    }
}

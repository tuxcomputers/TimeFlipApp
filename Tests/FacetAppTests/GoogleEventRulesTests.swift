@testable import FacetApp
import Foundation
import XCTest

/// What a `time_entry` becomes at Google, and how the app tells afterwards that it got there intact.
///
/// What is deliberately **not** here: the requests. Whether Google accepts the body and whether it answers a repeated
/// id with a 409 can only be found out against the real thing, which is a live run rather than `swift test`.
final class GoogleEventRulesTests: XCTestCase {
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    private func expected(
        entry: Int = 4213,
        event: Int = 1288,
        summary: String = "Meeting",
        startEpoch: Int = 1_755_000_000,
        seconds: Double = 1800
    ) -> GoogleEventRules.Expected {
        GoogleEventRules.Expected(
            eventID: GoogleEventRules.eventID(forTimeEntry: entry),
            summary: summary,
            description: GoogleEventRules.description(timeEntryID: entry, deviceEventID: event),
            startEpoch: startEpoch,
            endEpoch: startEpoch + Int(seconds),
            timeZoneName: sydney.identifier
        )
    }

    // MARK: - the event's identity

    func testTheEventIdIsDerivedFromTheEntryAndIsLegalBase32hex() {
        // Google refuses anything outside `0-9a-v`, and refuses ids under five characters. Getting this wrong is a
        // 400 on every single insert, so the alphabet is worth asserting rather than eyeballing.
        let id = GoogleEventRules.eventID(forTimeEntry: 4213)
        XCTAssertEqual(id, "facet4213")
        XCTAssertGreaterThanOrEqual(id.count, 5)
        let legal = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuv")
        XCTAssertNil(id.rangeOfCharacter(from: legal.inverted), "every character must be base32hex")
    }

    func testTheSameEntryAlwaysAddressesTheSameEvent() {
        // The whole duplicate-prevention argument rests on this: a second pass over an entry that was written but not
        // ticked has to collide with its own earlier event rather than make another.
        XCTAssertEqual(GoogleEventRules.eventID(forTimeEntry: 7), GoogleEventRules.eventID(forTimeEntry: 7))
        XCTAssertNotEqual(GoogleEventRules.eventID(forTimeEntry: 7), GoogleEventRules.eventID(forTimeEntry: 70))
    }

    func testTheDescriptionCarriesBothIds() {
        // The `time_entry` id finds the row, the `device_event` id finds the segment behind it. An event with only one
        // of them can be traced half way.
        let text = GoogleEventRules.description(timeEntryID: 4213, deviceEventID: 1288)
        XCTAssertEqual(text, "Facet time entry 4213\nDevice event 1288")
    }

    // MARK: - the body

    func testTheBodyIsTheCategoryTheIdsAndTwoZonedTimes() throws {
        let body = try XCTUnwrap(GoogleEventRules.body(for: expected()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, "facet4213")
        // The title is the category and nothing else: no prefix, no duration, nothing that would have to be parsed
        // back out by anything reading the calendar.
        XCTAssertEqual(object["summary"] as? String, "Meeting")
        XCTAssertEqual(object["description"] as? String, "Facet time entry 4213\nDevice event 1288")

        let start = try XCTUnwrap(object["start"] as? [String: String])
        let end = try XCTUnwrap(object["end"] as? [String: String])
        XCTAssertEqual(start["timeZone"], "Australia/Sydney")
        XCTAssertEqual(end["timeZone"], "Australia/Sydney")
        // Spelled out rather than compared against `dateTime(epoch:in:)`, which would only prove the body calls the
        // same function this test would: 1755000000 is 12:00 UTC, which is 22:00 in Sydney, and the entry ran 1800s.
        XCTAssertEqual(start["dateTime"], "2025-08-12T22:00:00+10:00")
        XCTAssertEqual(end["dateTime"], "2025-08-12T22:30:00+10:00")
    }

    func testATimeIsWrittenWithTheOffsetOfTheZoneItWasRecordedIn() {
        // The archive sent `TimeZone.current` for every event. The same instant in two zones is the same moment and
        // two different wall clocks, and an entry recorded elsewhere has to keep the one it was recorded with.
        let epoch = 1_755_000_000
        let inSydney = GoogleEventRules.dateTime(epoch: epoch, in: sydney)
        let inLondon = GoogleEventRules.dateTime(epoch: epoch, in: TimeZone(identifier: "Europe/London")!)
        XCTAssertTrue(inSydney.hasSuffix("+10:00"), inSydney)
        XCTAssertTrue(inLondon.hasSuffix("+01:00"), inLondon)
        XCTAssertNotEqual(inSydney, inLondon)
    }

    func testAnUnknownZoneFallsBackToThisMachinesRatherThanRefusing() {
        // `timezone` seeds an `Unknown` row at id 0 and every timestamp column defaults to it, so rows filed before a
        // real zone was resolved land here. Refusing to sync them would lose the time silently.
        XCTAssertEqual(GoogleEventRules.timeZone(named: "Unknown"), .current)
        XCTAssertEqual(GoogleEventRules.timeZone(named: nil), .current)
        XCTAssertEqual(GoogleEventRules.timeZone(named: "Australia/Sydney"), sydney)
    }

    // MARK: - reading the event back

    private func response(
        id: String = "facet4213",
        summary: String? = "Meeting",
        description: String? = "Facet time entry 4213\nDevice event 1288",
        start: String? = "2025-08-12T22:00:00+10:00",
        end: String? = "2025-08-12T22:30:00+10:00",
        status: String = "confirmed"
    ) throws -> Data {
        var object: [String: Any] = ["id": id, "status": status]
        if let summary { object["summary"] = summary }
        if let description { object["description"] = description }
        if let start { object["start"] = ["dateTime": start, "timeZone": "Australia/Sydney"] }
        if let end { object["end"] = ["dateTime": end, "timeZone": "Australia/Sydney"] }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testTheReadBackAgreesWithWhatWasSent() throws {
        let kept = try XCTUnwrap(GoogleEventRules.event(fromResponse: response()))
        XCTAssertNil(GoogleEventRules.mismatch(between: kept, and: expected()))
    }

    func testTwoSpellingsOfOneMomentAreNotAMismatch() throws {
        // Google may answer in a different offset for the same instant. Comparing the text would report a mismatch on
        // an event that is perfectly correct, and the entry would then never sync.
        let utc = try response(start: "2025-08-12T12:00:00Z", end: "2025-08-12T12:30:00Z")
        let kept = try XCTUnwrap(GoogleEventRules.event(fromResponse: utc))
        XCTAssertNil(GoogleEventRules.mismatch(between: kept, and: expected()))
    }

    func testAnEntryWhoseDurationCarriesAFractionStillVerifies() throws {
        // The bug that stopped this feature dead the first time it ran. `duration_seconds` is REAL and some rows hold
        // a fraction (`time_entry` 27 holds 147.612311840057). The body sends whole seconds, so an expectation that
        // kept the fraction disagreed with Google by 0.6 of a second, for ever: the event was created, the read-back
        // "failed", the row was never ticked, and every later sweep retried the same row.
        //
        // `Expected` now holds epochs, so this asserts the type cannot get back into that state: what is sent and
        // what is compared are one number.
        let startEpoch = 1_755_000_000
        let expected = GoogleEventRules.Expected(
            eventID: "facet27",
            summary: "Meeting",
            description: "x",
            startEpoch: startEpoch,
            endEpoch: startEpoch + Int(147.612311840057),
            timeZoneName: sydney.identifier
        )
        let body = try XCTUnwrap(GoogleEventRules.body(for: expected))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try XCTUnwrap((object["end"] as? [String: String])?["dateTime"])

        // Google answers with what it was given. That is the whole point: a round trip has to come back equal.
        let kept = try XCTUnwrap(GoogleEventRules.event(fromResponse: try JSONSerialization.data(withJSONObject: [
            "id": "facet27", "status": "confirmed", "summary": "Meeting", "description": "x",
            "start": ["dateTime": try XCTUnwrap((object["start"] as? [String: String])?["dateTime"])],
            "end": ["dateTime": sent],
        ])))
        XCTAssertNil(GoogleEventRules.mismatch(between: kept, and: expected))
    }

    func testEachFieldGoingWrongIsReportedAsItself() throws {
        // The mismatch is a debug line nobody is watching live, so it has to say which field, not just "no".
        func kept(_ data: Data) throws -> GoogleEventRules.Event {
            try XCTUnwrap(GoogleEventRules.event(fromResponse: data))
        }
        try XCTAssertEqual(GoogleEventRules.mismatch(between: kept(response(id: "facet99")), and: expected()), .wrongEvent)
        try XCTAssertEqual(GoogleEventRules.mismatch(between: kept(response(summary: "Lunch")), and: expected()), .summary)
        try XCTAssertEqual(GoogleEventRules.mismatch(between: kept(response(description: "")), and: expected()), .description)
        try XCTAssertEqual(
            GoogleEventRules.mismatch(between: kept(response(start: "2025-08-12T22:05:00+10:00")), and: expected()),
            .start
        )
        try XCTAssertEqual(
            GoogleEventRules.mismatch(between: kept(response(end: "2025-08-12T23:30:00+10:00")), and: expected()),
            .end
        )
    }

    func testADeletedEventIsNotASyncedEvent() throws {
        // Google keeps a deleted event as `cancelled` rather than removing it, so it still answers a GET with the
        // right id, summary and times. Without the status check the read-back of an event the user threw away would
        // look like proof it is there.
        let kept = try XCTUnwrap(GoogleEventRules.event(fromResponse: response(status: "cancelled")))
        XCTAssertEqual(GoogleEventRules.mismatch(between: kept, and: expected()), .cancelled)
    }

    func testAnAllDayEventCannotBeVerified() throws {
        // An all-day event carries `date` rather than `dateTime`: a day, not a moment. Reading it as "no start" is
        // what makes it a mismatch instead of an accidental pass.
        let allDay = try JSONSerialization.data(withJSONObject: [
            "id": "facet4213", "status": "confirmed", "summary": "Meeting",
            "description": "Facet time entry 4213\nDevice event 1288",
            "start": ["date": "2025-08-12"], "end": ["date": "2025-08-13"],
        ])
        let kept = try XCTUnwrap(GoogleEventRules.event(fromResponse: allDay))
        XCTAssertNil(kept.start)
        XCTAssertEqual(GoogleEventRules.mismatch(between: kept, and: expected()), .start)
    }

    func testAReplyWithNoIdIsNotAnEvent() throws {
        XCTAssertNil(GoogleEventRules.event(fromResponse: Data("not json".utf8)))
        XCTAssertNil(GoogleEventRules.event(fromResponse: try JSONSerialization.data(withJSONObject: ["summary": "x"])))
    }

    // MARK: - addressing

    func testAnEventUrlEscapesTheCalendarIdExactlyOnce() throws {
        // The same trap the calendar's own URL fell into, one level deeper: `abc@group...` escaped twice addresses an
        // id nobody has, and the 404 that comes back would be read as the event being missing.
        let url = try XCTUnwrap(
            GoogleEventClient.eventURL(calendarID: "abc@group.calendar.google.com", eventID: "facet4213")
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://www.googleapis.com/calendar/v3/calendars/abc%40group.calendar.google.com/events/facet4213"
        )
    }

    func testTheEventsUrlIsTheCalendarPlusEvents() throws {
        let url = try XCTUnwrap(GoogleEventClient.eventsURL(calendarID: "abc@group.calendar.google.com"))
        XCTAssertEqual(
            url.absoluteString,
            "https://www.googleapis.com/calendar/v3/calendars/abc%40group.calendar.google.com/events"
        )
    }
}

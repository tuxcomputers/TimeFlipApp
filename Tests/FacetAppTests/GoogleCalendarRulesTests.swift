@testable import FacetApp
import Foundation
import XCTest

/// The calendar's rules: what identifies it, what a typed name becomes, and how Google's answers are read.
final class GoogleCalendarRulesTests: XCTestCase {
    // MARK: - identity

    func testACalendarIsItsIdAndNotItsName() {
        // The user can rename it at Google in two clicks. Anything that decided "do we have a calendar" by its name
        // would make a second one the first time somebody did.
        XCTAssertTrue(GoogleCalendarRules.calendar(id: "abc@group.calendar.google.com", name: nil).exists)
        XCTAssertFalse(GoogleCalendarRules.calendar(id: nil, name: "Facet").exists)
        XCTAssertFalse(GoogleCalendarRules.Calendar.none.exists)
    }

    func testABlankIdIsNoCalendar() {
        // Sign-out writes empty strings rather than removing the keys, since the identity shares the row.
        XCTAssertFalse(GoogleCalendarRules.calendar(id: "   ", name: "Facet").exists)
    }

    // MARK: - the name

    func testAnEmptyNameFallsBackToFacet() {
        // Google would accept a calendar called "", and the user would then have an unnamed row in their calendar
        // list with no obvious way back.
        XCTAssertEqual(GoogleCalendarRules.name(fromTyped: "   "), "Facet")
        XCTAssertEqual(GoogleCalendarRules.name(fromTyped: ""), "Facet")
    }

    func testATypedNameIsTrimmedButOtherwiseLeftAlone() {
        XCTAssertEqual(GoogleCalendarRules.name(fromTyped: "  Work time  "), "Work time")
    }

    // MARK: - reading Google

    func testACreatedCalendarIsReadFromTheReply() throws {
        let body = try JSONSerialization.data(withJSONObject: ["id": "abc@group.calendar.google.com", "summary": "Facet"])
        let calendar = try XCTUnwrap(GoogleCalendarRules.calendar(fromResponse: body))
        XCTAssertEqual(calendar.id, "abc@group.calendar.google.com")
        XCTAssertEqual(calendar.name, "Facet")
    }

    func testAReplyWithNoIdIsNotACalendar() throws {
        // A missing summary is a missing label; a missing id is nothing that can be written to.
        let body = try JSONSerialization.data(withJSONObject: ["summary": "Facet"])
        XCTAssertNil(GoogleCalendarRules.calendar(fromResponse: body))
    }

    func testTheListIsReadAndEntriesWithoutIdsAreDropped() throws {
        let body = try JSONSerialization.data(withJSONObject: ["items": [
            ["id": "one@group.calendar.google.com", "summary": "Facet"],
            ["summary": "no id here"],
            ["id": "two@group.calendar.google.com"],
        ]])
        let found = try XCTUnwrap(GoogleCalendarRules.calendars(fromList: body))
        XCTAssertEqual(found.map(\.id), ["one@group.calendar.google.com", "two@group.calendar.google.com"])
        XCTAssertEqual(found[0].name, "Facet")
        XCTAssertNil(found[1].name)
    }

    func testAnEmptyListIsAnAnswerAndRubbishIsNot() throws {
        // "No calendars" means make one. "Could not read that" must not, or a bad reply creates a duplicate.
        let empty = try JSONSerialization.data(withJSONObject: ["items": []])
        XCTAssertEqual(GoogleCalendarRules.calendars(fromList: empty)?.count, 0)
        XCTAssertNil(GoogleCalendarRules.calendars(fromList: Data("not json".utf8)))
    }

    // MARK: - when a calendar may be replaced

    func testOnlyAGoneCalendarJustifiesMakingAnother() {
        // The duplicate machine: creating whenever the id merely looks missing gives a second "Facet" per attempt,
        // because a failed write of the id leaves the row empty while the calendar exists perfectly well.
        XCTAssertTrue(GoogleCalendarRules.isCalendarGone(status: 404))
        XCTAssertTrue(GoogleCalendarRules.isCalendarGone(status: 410))
        for status in [401, 403, 429, 500, 503] {
            XCTAssertFalse(GoogleCalendarRules.isCalendarGone(status: status), "\(status) is a request that failed")
        }
    }

    // MARK: - addressing one

    func testACalendarIdIsEscapedIntoItsUrl() throws {
        // Ids look like an email address, and an unescaped "@" makes a URL that addresses the wrong thing.
        let url = try XCTUnwrap(GoogleCalendarRules.url(forCalendar: "abc@group.calendar.google.com"))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/"))
        XCTAssertFalse(url.absoluteString.contains("@"))
    }

    func testTheBodyUsesGooglesWordForTheName() throws {
        let body = try XCTUnwrap(GoogleCalendarRules.body(name: "Work time"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["summary": "Work time"])
    }
}

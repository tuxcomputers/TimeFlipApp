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

    func testACalendarIdIsEscapedExactlyOnce() throws {
        // Ids look like an email address. The trap is escaping twice: a "%" from the first pass becomes "%25" in the
        // second, and the URL then addresses a calendar id nobody has, which comes back as a 404 -- which this app
        // reads as "the calendar is gone" and acts on.
        let url = try XCTUnwrap(GoogleCalendarRules.url(forCalendar: "abc@group.calendar.google.com"))
        XCTAssertEqual(
            url.absoluteString,
            "https://www.googleapis.com/calendar/v3/calendars/abc%40group.calendar.google.com"
        )
    }

    func testTheBodyUsesGooglesWordForTheName() throws {
        let body = try XCTUnwrap(GoogleCalendarRules.body(name: "Work time"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["summary": "Work time"])
    }

    // MARK: - what a sign-in does about it

    func testASignInWithNoStoredCalendarMakesNothing() {
        // **The point of the whole rule.** Connecting an account used to make a "Facet" calendar at the end of the
        // sign-in, so somebody who only wanted to see which account was connected got a calendar in it they had not
        // asked for and had to go and delete. Nothing is made now: the row offers a Create button instead.
        for stored in [nil, "", "   "] {
            XCTAssertEqual(
                GoogleCalendarRules.settlement(forStoredID: stored), .leaveToTheUser,
                "a stored id of \(stored.map { "\"\($0)\"" } ?? "nil") is no calendar"
            )
        }
    }

    func testASignInWithAStoredCalendarChecksItRatherThanMakingAnother() {
        // The id survives a sign-out on purpose, so the common case -- the same person signing back in -- keeps the
        // calendar and its history. Checking is a `calendars.get`, which also brings back a name changed at Google.
        XCTAssertEqual(
            GoogleCalendarRules.settlement(forStoredID: "abc@group.calendar.google.com"),
            .check(id: "abc@group.calendar.google.com")
        )
        XCTAssertEqual(
            GoogleCalendarRules.settlement(forStoredID: "  abc@group.calendar.google.com  "),
            .check(id: "abc@group.calendar.google.com"),
            "trimmed, as every other read of this field is"
        )
    }
}

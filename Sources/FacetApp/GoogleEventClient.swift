import Foundation

/// Writes events into the calendar Facet owns, and reads them back.
///
/// **Separate from `GoogleCalendarClient`, which is about the calendar itself.** That one makes and renames a single
/// calendar a handful of times in an account's life; this one runs whenever tracked time is recorded. They talk to the
/// same API and share the escaping rule, and nothing else.
///
/// **Nothing here ever reports a calendar as gone.** A 404 from an event address is ambiguous -- the event may be
/// missing, or the calendar around it may be -- and `CalendarGone` is the one signal that makes the app forget its
/// stored `calendar_id` and offer to make another (`SettingsWindowController.forgetAndOfferGoogleCalendar`). A sweep
/// running in the background must not be able to reach that: it would clear the calendar off the back of one failed
/// request, with nobody watching. So the sweep leaves rows unsynced and complains, and the calendar is settled the next
/// time somebody opens Settings, where the question can actually be asked.
enum GoogleEventClient {
    /// What an insert came to.
    enum Insertion: Equatable {
        /// Google took it, and this is what it made.
        case created(GoogleEventRules.Event)
        /// An event with that id is already in this calendar. **Not a failure**: the id is derived from the
        /// `time_entry` id, so this is Facet meeting its own earlier work -- a pass that wrote the event and did not
        /// get as far as ticking the row. The read-back that follows is what decides whether it is right.
        case alreadyThere
    }

    /// Errors the sweep can report, worded for a debug line rather than an alert: nobody is watching this happen.
    enum Failure: LocalizedError, Equatable {
        case notAddressable
        case refused(String)
        case unreadable
        case missing

        var errorDescription: String? {
            switch self {
            case .notAddressable: return "that calendar or event id cannot be put in a URL"
            case let .refused(reason): return reason
            case .unreadable: return "Google's reply could not be read"
            case .missing: return "the event is not in the calendar"
            }
        }
    }

    static func insert(
        _ expected: GoogleEventRules.Expected,
        calendarID: String,
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> Insertion {
        guard let url = eventsURL(calendarID: calendarID), let body = GoogleEventRules.body(for: expected) else {
            throw Failure.notAddressable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, status) = try await send(request, session: session)
        // 409 is the whole point of a derived id, so it is an answer rather than an error.
        if status == 409 { return .alreadyThere }
        guard (200 ..< 300).contains(status) else { throw refusal(status: status, data: data) }
        guard let event = GoogleEventRules.event(fromResponse: data) else { throw Failure.unreadable }
        return .created(event)
    }

    /// Fetches the event again, which is what makes a tick in `synced_to_google_calendar` mean something.
    ///
    /// A separate request rather than the insert's own reply on purpose: the reply says what Google accepted, and this
    /// says what Google **kept**. They are the same thing right up until they are not, and this feature's whole claim
    /// is that a synced row has a correct event behind it.
    static func get(
        eventID: String,
        calendarID: String,
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> GoogleEventRules.Event {
        guard let url = eventURL(calendarID: calendarID, eventID: eventID) else {
            throw Failure.notAddressable
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, status) = try await send(request, session: session)
        if status == 404 || status == 410 { throw Failure.missing }
        guard (200 ..< 300).contains(status) else { throw refusal(status: status, data: data) }
        guard let event = GoogleEventRules.event(fromResponse: data) else { throw Failure.unreadable }
        return event
    }

    // MARK: - addressing

    /// `.../calendars/{id}/events`, with the calendar id escaped **once**, by the same rule the calendar's own URL
    /// uses. See the note on `GoogleCalendarRules.url(forCalendar:)` for what escaping it twice cost.
    static func eventsURL(calendarID: String) -> URL? {
        guard let escaped = GoogleCalendarRules.pathSegment(calendarID) else { return nil }
        return URL(string: GoogleCalendarRules.endpoint.absoluteString + "/" + escaped + "/events")
    }

    static func eventURL(calendarID: String, eventID: String) -> URL? {
        guard let base = eventsURL(calendarID: calendarID), let escaped = GoogleCalendarRules.pathSegment(eventID) else {
            return nil
        }
        return URL(string: base.absoluteString + "/" + escaped)
    }

    // MARK: - one request

    private static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.refused(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        return (data, http.statusCode)
    }

    /// Google's own reason where it gives one, since "the request was refused (403)" is not enough to act on and the
    /// body says whether it was the scope, the quota or the calendar.
    private static func refusal(status: Int, data: Data) -> Failure {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        if let message = error?["message"] as? String, !message.isEmpty {
            return .refused("\(message) (\(status))")
        }
        return .refused("the request was refused (\(status))")
    }
}

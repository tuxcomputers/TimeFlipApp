import Foundation

struct GoogleCalendarSummary: Identifiable, Equatable, Sendable {
    let id: String
    let summary: String
}

struct GoogleCalendarEvent: Sendable {
    let summary: String
    let description: String
    let startDate: Date
    let endDate: Date
}

@MainActor
protocol GoogleCalendarClient {
    func listCalendars(accessToken: String) async throws -> [GoogleCalendarSummary]
    func insertEvent(accessToken: String, calendarId: String, event: GoogleCalendarEvent) async throws
}

@MainActor
final class GoogleCalendarAPIClient: GoogleCalendarClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listCalendars(accessToken: String) async throws -> [GoogleCalendarSummary] {
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=writer") else {
            throw GoogleAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try GoogleAPIError.validate(response: response, data: data)
        let payload = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        return payload.items.map { GoogleCalendarSummary(id: $0.id, summary: $0.summary) }
    }

    func insertEvent(accessToken: String, calendarId: String, event: GoogleCalendarEvent) async throws {
        let encodedId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedId)/events") else {
            throw GoogleAPIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let timeZone = TimeZone.current.identifier
        let formatter = ActivityRecordFormatter.iso8601
        let payload = CalendarEventPayload(
            summary: event.summary,
            description: event.description,
            start: CalendarEventTime(dateTime: formatter.string(from: event.startDate), timeZone: timeZone),
            end: CalendarEventTime(dateTime: formatter.string(from: event.endDate), timeZone: timeZone)
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        try GoogleAPIError.validate(response: response, data: data)
    }
}

private struct CalendarListResponse: Decodable {
    let items: [CalendarListEntry]
}

private struct CalendarListEntry: Decodable {
    let id: String
    let summary: String
}

private struct CalendarEventPayload: Encodable {
    let summary: String
    let description: String
    let start: CalendarEventTime
    let end: CalendarEventTime
}

private struct CalendarEventTime: Encodable {
    let dateTime: String
    let timeZone: String
}

enum GoogleAPIError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(code: Int, message: String?)

    static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw GoogleAPIError.httpStatus(code: httpResponse.statusCode, message: message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Unexpected response from Google API."
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty {
                return "Google API error (\(code)): \(message)"
            }
            return "Google API error (\(code))."
        }
    }
}

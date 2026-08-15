import Foundation

/// The calendar Facet makes for itself: which fields hold it, what it is called, and how to read Google's answers.
///
/// **The id is the identity and the name is a label.** Everything keys off `calendar_id`; nothing is ever found by
/// name. The calendar lives in the user's own account and they can rename it at Google in two clicks, so a lookup by
/// name would create a duplicate the first time somebody did. That is the same fault as matching a cube by its
/// advertised name, which this codebase has already paid for once.
enum GoogleCalendarRules {
    /// Both fields live in the `google_account` row, beside the identity, because a calendar selection is meaningless
    /// without an account (`database/011_setting.sql`).
    static let idField = "calendar_id"
    static let nameField = "calendar_name"

    /// What a new calendar is called unless somebody says otherwise. The name the privacy policy already tells people
    /// to expect.
    static let defaultName = "Facet"

    static let endpoint = URL(string: "https://www.googleapis.com/calendar/v3/calendars")!
    /// Under `calendar.app.created` this lists only the calendars this app made, which is what makes it safe to adopt
    /// one without asking.
    static let calendarListEndpoint = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!

    /// What the table holds about the calendar.
    struct Calendar: Equatable {
        var id: String?
        var name: String?

        /// **Decided by the id alone.** A name with no id behind it is a label for something that cannot be written
        /// to, and treating it as a calendar would mean the app believing it has somewhere to sync.
        var exists: Bool { id != nil }

        static let none = Calendar(id: nil, name: nil)
    }

    /// Reads the calendar out of what the table gave back, treating blank as absent, as the identity fields are.
    static func calendar(id: String?, name: String?) -> Calendar {
        Calendar(id: trimmedOrNil(id), name: trimmedOrNil(name))
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// What a typed name becomes before it is sent anywhere.
    ///
    /// Trimmed, and an empty one falls back to the default rather than being sent: Google would take a calendar called
    /// "" and the user would then have an unnamed row in their calendar list with no obvious way back.
    static func name(fromTyped typed: String) -> String {
        trimmedOrNil(typed) ?? defaultName
    }

    /// The body of a create or a rename. `summary` is Google's word for what everybody else calls the name.
    static func body(name: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["summary": name])
    }

    /// The URL for changing one calendar, which needs the id percent-encoded: Google's ids contain `@`, and for a
    /// secondary calendar they look like an email address.
    static func url(forCalendar id: String) -> URL? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return endpoint.appendingPathComponent(escaped)
    }

    /// Reads Google's reply to a create or a rename.
    ///
    /// **The id is required and the name is not.** A reply with no id is not a calendar this app can use, where a
    /// missing summary is only a missing label.
    static func calendar(fromResponse data: Data) -> Calendar? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String, !id.isEmpty
        else {
            return nil
        }
        return Calendar(id: id, name: trimmedOrNil(object["summary"] as? String))
    }

    /// Reads a calendar list, keeping only entries with an id.
    static func calendars(fromList data: Data) -> [Calendar]? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = object["items"] as? [[String: Any]]
        else {
            return nil
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return Calendar(id: id, name: trimmedOrNil(item["summary"] as? String))
        }
    }

    /// Whether a failure means the calendar is gone rather than that the request went wrong.
    ///
    /// **This is the only thing allowed to trigger a re-create.** Creating whenever the id merely looks missing is how
    /// a user ends up with a second "Facet" calendar, and a third, one per attempt: a write of the id that failed
    /// leaves the row empty while the calendar exists perfectly well at Google.
    static func isCalendarGone(status: Int) -> Bool {
        status == 404 || status == 410
    }

    /// What the Calendar row says when there is no calendar yet.
    static let missingName = "Not created"

    /// Errors worth telling somebody about, in words that say whose problem it is.
    enum Failure: LocalizedError, Equatable {
        case notSignedIn
        case createFailed(String)
        case renameFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Facet is not connected to a Google account, so it cannot make a calendar."
            case let .createFailed(reason):
                return "Facet could not create the calendar: \(reason)."
            case let .renameFailed(reason):
                return "Facet could not rename the calendar: \(reason)."
            }
        }
    }
}

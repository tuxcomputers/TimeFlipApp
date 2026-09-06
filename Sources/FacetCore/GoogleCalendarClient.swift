import Foundation

/// Makes and renames the one calendar Facet owns.
///
/// **Two requests exist in this whole type, and neither is on a timer.** Creating happens once per account, renaming
/// only when somebody types a new name. Nothing polls, because a poll would be a Calendar API request per launch per
/// user for a label that rarely changes, and "starting the app costs nothing" is a property worth keeping.
enum GoogleCalendarClient {
    /// A short-lived access token, from the refresh token in the Keychain.
    ///
    /// **Never stored.** It is good for an hour, and keeping it would mean a second credential on disk to no purpose:
    /// asking for a fresh one costs a request to Google's *token* endpoint, which is not the Calendar API and does not
    /// touch the project's Calendar quota.
    static func accessToken(
        credentials: GoogleCredentials,
        refreshToken: String,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: GoogleOAuthRules.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await send(request, session: session, describing: "sign-in has expired")
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = object["access_token"] as? String
        else {
            _ = response
            throw GoogleOAuthRules.Failure.exchangeFailed("the reply could not be read")
        }
        return token
    }

    /// A usable access token for whoever is signed in **right now**, resolved from scratch every time.
    ///
    /// The credentials and the refresh token are both looked up at the moment they are needed rather than held: a
    /// sign-out clears the Keychain item, and anything holding a token from before it would go on acting on an account
    /// the app says it is not connected to. This is the first design rule applied to something that does not live in a
    /// table but changes for the same reasons.
    static func currentAccessToken(session: URLSession = .shared) async throws -> String {
        guard let credentials = GoogleCredentials.resolve() else {
            throw GoogleOAuthRules.Failure.noCredentials
        }
        // Asked three ways rather than two, so a Keychain that would not answer is reported as itself instead of
        // as an account nobody signed into.
        switch GoogleTokenStore.lookUp() {
        case let .found(refresh):
            return try await accessToken(credentials: credentials, refreshToken: refresh, session: session)
        case .missing:
            throw GoogleCalendarRules.Failure.notSignedIn
        case let .unavailable(status):
            throw GoogleCalendarRules.Failure.keychainUnavailable(status)
        }
    }

    /// Fetches the stored calendar, to find out whether it is still there and what it is called now.
    ///
    /// **This is where drift is noticed**, without a poll: the same request that proves the calendar exists also
    /// brings back its current name, so a rename made at Google is picked up on the one occasion the app was going to
    /// ask anyway. Throws `CalendarGone` when it does not resolve, which is the only thing allowed to lead to making
    /// another one.
    static func get(
        id: String,
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> GoogleCalendarRules.Calendar {
        guard let url = GoogleCalendarRules.url(forCalendar: id) else {
            throw CalendarGone()
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await send(request, session: session, describing: "Google refused the request")
        guard let calendar = GoogleCalendarRules.calendar(fromResponse: data) else {
            throw CalendarGone()
        }
        return calendar
    }

    /// Creates the calendar and answers with what Google called it.
    ///
    /// **Called once**, at the end of a sign-in, and otherwise only from the recovery button. Everything else keys off
    /// the stored id.
    static func create(
        name: String,
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> GoogleCalendarRules.Calendar {
        var request = URLRequest(url: GoogleCalendarRules.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleCalendarRules.body(name: name)

        let (data, _) = try await send(request, session: session, describing: "Google refused the request")
        guard let calendar = GoogleCalendarRules.calendar(fromResponse: data) else {
            throw GoogleCalendarRules.Failure.createFailed("Google's reply had no calendar in it")
        }
        return calendar
    }

    /// Renames it, and answers with what it is called afterwards.
    ///
    /// **A real rename, at Google.** A name that only changed inside Facet would be a setting that does something
    /// other than what it says, which is the two-answers problem the first design rule exists to prevent.
    static func rename(
        id: String,
        to name: String,
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> GoogleCalendarRules.Calendar {
        guard let url = GoogleCalendarRules.url(forCalendar: id) else {
            throw GoogleCalendarRules.Failure.renameFailed("that calendar id cannot be addressed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleCalendarRules.body(name: name)

        let (data, _) = try await send(request, session: session, describing: "Google refused the request")
        guard let calendar = GoogleCalendarRules.calendar(fromResponse: data) else {
            throw GoogleCalendarRules.Failure.renameFailed("Google's reply had no calendar in it")
        }
        return calendar
    }

    /// Deletes the calendar, at Google, for good.
    ///
    /// **The one thing here that destroys something.** Creating and renaming can both be undone by doing them again;
    /// this takes the calendar and every event Facet ever wrote to it, and Google keeps no copy for the app to go back
    /// to. So the window confirms it first and names what goes, and this does nothing but carry the answer out.
    ///
    /// **A calendar that is already gone counts as deleted.** `CalendarGone` means the id does not resolve, which is
    /// the outcome being asked for however it came about -- reporting that as a failure would leave somebody trying to
    /// delete a thing that is not there.
    static func delete(id: String, accessToken: String, session: URLSession = .shared) async throws {
        guard let url = GoogleCalendarRules.url(forCalendar: id) else {
            throw GoogleCalendarRules.Failure.deleteFailed("that calendar id cannot be addressed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            _ = try await send(request, session: session, describing: "Google refused the request")
        } catch is CalendarGone {
            return
        }
    }

    /// One request, with Google's own reason pulled out of the body when it refuses.
    ///
    /// **A gone calendar is reported as gone**, distinctly, because it is the one failure that may legitimately lead
    /// to creating another one. Everything else is a request that went wrong and must not.
    private static func send(
        _ request: URLRequest,
        session: URLSession,
        describing fallback: String
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GoogleCalendarRules.Failure.createFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarRules.Failure.createFailed(fallback)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if GoogleCalendarRules.isCalendarGone(status: http.statusCode) {
                throw CalendarGone()
            }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            throw GoogleCalendarRules.Failure.createFailed(
                (error?["message"] as? String) ?? "\(fallback) (\(http.statusCode))"
            )
        }
        return (data, http)
    }
}

/// The calendar this app made is no longer there.
///
/// Its own type rather than a case of `Failure`, so that the one place allowed to respond by creating another calendar
/// has to name it deliberately. Anything catching `Failure` generally will not catch this by accident.
struct CalendarGone: Error {}

@testable import TimeFlipApp
import XCTest

// swiftlint:disable trailing_closure
@MainActor
final class GoogleIntegrationCoordinatorTests: XCTestCase {
    private let calendarID = "primary"

    func testRecordsAreRoutedToCalendarRespectingThresholds() async throws {
        let calendar = CapturingCalendarClient()
        let dbURL = AppDataStore.testDatabaseURL()
        AppDataStore.resetForTests(at: dbURL)
        let store = AppDataStore(databaseURL: dbURL)
        let coordinator = GoogleIntegrationCoordinator(
            authManager: dummyAuthManager(),
            calendarClient: calendar,
            tokenProvider: { "token" },
            store: store,
            preferencesProvider: { IntegrationPreferences(calendarId: self.calendarID) }
        )

        // Seed logbook directly with event-numbered records (new pipeline).
        let events: [DeviceEventRecord] = [
            .init(
                id: nil,
                eventNumber: 1,
                facetID: 1,
                startedAt: Date(timeIntervalSince1970: 0),
                duration: 400,
                isPaused: false,
                activityName: "Code"
            ), // <15m
            .init(
                id: nil,
                eventNumber: 2,
                facetID: 2,
                startedAt: Date(timeIntervalSince1970: 1_000),
                duration: 30,
                isPaused: true,
                activityName: "Email"
            ), // <15m
            .init(
                id: nil,
                eventNumber: 3,
                facetID: 3,
                startedAt: Date(timeIntervalSince1970: 2_000),
                duration: 1_200,
                isPaused: false,
                activityName: "Review"
            ), // 20m
            .init(
                id: nil,
                eventNumber: 4,
                facetID: 4,
                startedAt: Date(timeIntervalSince1970: 3_000),
                duration: 900,
                isPaused: false,
                activityName: "Standup"
            ) // exactly 15m
        ]
        events.forEach { store.append($0) }

        await coordinator.flushPendingSessionsAndWait()

        XCTAssertEqual(
            calendar.insertedEvents.map(\.summary),
            ["Review", "Standup"],
            "Calendar should receive only events >= 15 minutes."
        )
    }

    // MARK: - Helpers

    private func dummyAuthManager() -> GoogleAuthManager {
        // Safe placeholder; real auth is bypassed via tokenProvider
        GoogleAuthManager(stateStore: InMemoryAuthStateStore())
    }
}

// MARK: - Test Doubles

@MainActor
private final class CapturingCalendarClient: GoogleCalendarClient {
    struct InsertedEvent {
        let accessToken: String
        let calendarId: String
        let summary: String
        let description: String
        let startDate: Date
        let endDate: Date
    }

    private(set) var insertedEvents: [InsertedEvent] = []

    func listCalendars(accessToken: String) async throws -> [GoogleCalendarSummary] {
        _ = accessToken
        return []
    }

    func fetchUserInfo(accessToken: String) async throws -> GoogleAccountInfo {
        _ = accessToken
        return GoogleAccountInfo(name: nil, email: nil)
    }

    func insertEvent(accessToken: String, calendarId: String, event: GoogleCalendarEvent) async throws {
        insertedEvents.append(
            InsertedEvent(
                accessToken: accessToken,
                calendarId: calendarId,
                summary: event.summary,
                description: event.description,
                startDate: event.startDate,
                endDate: event.endDate
            )
        )
    }
}
// swiftlint:enable trailing_closure

@testable import FacetCore
import Foundation
import Testing

/// Covers `DatabaseEnvironment`: reading which database a launch opened.
///
/// The read matters more than it looks. Its answer decides whether the menu bar warns that a test
/// database is open, so a wrong answer is worse than no answer -- which is why the `nil` cases below are
/// tested as carefully as the two real ones.
///
/// **swift-testing rather than XCTest**, as every `@MainActor` suite has to be: Linux discovers XCTest
/// tests through a generated list and cannot cast an isolated method, so one such class aborts the whole
/// run. Here the isolation is simply honoured. `init` replaces `setUpWithError` and needs no
/// `assumeIsolated` -- it *is* on the main actor -- and cleanup moves to `deinit`, which is not.
@Suite @MainActor
final class DatabaseEnvironmentTests {
    private let database: TemporaryDatabase
    private let settings: SettingStore

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    deinit {
        database.remove()
    }

    private func setType(_ value: String) {
        #expect(
            database.execute("UPDATE setting SET setting_value = '\(value)' WHERE setting_name = 'db_type';")
        )
    }

    @Test func aFreshDatabaseReadsAsProduction() {
        #expect(DatabaseEnvironment.read(from: settings) == .production)
    }

    @Test func aDatabaseMarkedAsATestCopyReadsAsTest() {
        // What switching to a test database does to the row it just seeded.
        setType(#"{"type":"test"}"#)

        #expect(DatabaseEnvironment.read(from: settings) == .test)
    }

    @Test func theTypeIsReadCaseInsensitively() {
        // The row is written by hand and by script, so the casing it arrives in is not guaranteed.
        setType(#"{"type":"TEST"}"#)

        #expect(DatabaseEnvironment.read(from: settings) == .test)
    }

    @Test func aValueNamingNeitherEnvironmentIsNotGuessedAt() {
        for value in [#"{"type":"staging"}"#, #"{"type":""}"#, #"{"kind":"test"}"#, "production"] {
            setType(value)
            #expect(DatabaseEnvironment.read(from: settings) == nil, "should not resolve: \(value)")
        }
    }

    @Test func aMissingSettingRowIsUnknownRatherThanProduction() {
        #expect(database.execute("DELETE FROM setting WHERE setting_name = 'db_type';"))

        #expect(DatabaseEnvironment.read(from: settings) == nil)
    }

    @Test func aMissingDatabaseIsUnknownRatherThanProduction() {
        // A launch that reads production while opening nothing is the worst of the three answers.
        let missing = SettingStore(connection: DatabaseConnection(databaseURL: database.directory.appendingPathComponent("nowhere.sqlite")))

        #expect(DatabaseEnvironment.read(from: missing) == nil)
    }
}

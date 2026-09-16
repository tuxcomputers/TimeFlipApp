@testable import FacetCore
import Foundation
import Testing

/// One row of the App tab, written and read back, with no window.
///
/// **What it pins is the split.** A change either becomes a row or is a request for something only a platform can do,
/// and the surface has to be able to tell those apart without a list of its own -- which is what `notASetting` is.
/// On the Mac that distinction is eleven `if case` branches at the top of one method.
@Suite @MainActor
final class AppSettingWriteTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
    }

    deinit {
        database.remove()
    }

    @Test func testAFlagIsWrittenAndReadBack() {
        let outcome = AppSettingWrite.apply(.showsSeconds(false), to: settings, debugLog: nil)

        #expect(outcome == .stored)
        #expect(settings.flag("display_seconds", field: "enabled") == false)
    }

    @Test func testANumberGoesThroughTheRulesRatherThanStraightToTheTable() {
        // The control offers minutes and the row holds seconds, which is `AppSettingsRules`' conversion and not
        // something a surface should be doing on the way past.
        let outcome = AppSettingWrite.apply(.fetchIntervalMinutes(5), to: settings, debugLog: nil)

        #expect(outcome == .stored)
        #expect(settings.integer("fetch_history_interval_seconds", field: "seconds") == 300)
    }

    @Test func testTheClockFaceHourBecomesATwentyFourHourRow() {
        let outcome = AppSettingWrite.apply(.dailyResetHour12(4), to: settings, debugLog: nil)

        #expect(outcome == .stored)
        #expect(settings.integer("daily_reset_time", field: "hour") != nil)
    }

    @Test func testTheDebugDirectoryIsText() {
        let outcome = AppSettingWrite.apply(.debugDirectory("/tmp/facet"), to: settings, debugLog: nil)

        #expect(outcome == .stored)
        #expect(settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField) == "/tmp/facet")
    }

    @Test func testARequestForSomethingOnlyAPlatformCanDoWritesNothing() {
        let before = settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)

        for request in [
            AppSettingsChange.debugDirectoryRequested,
            .debugRevealRequested,
            .debugCopyRequested,
            .googleSignInRequested,
            .googleCalendarCreateRequested,
        ] {
            #expect(AppSettingWrite.apply(request, to: settings, debugLog: nil) == .notASetting)
        }

        #expect(settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField) == before)
    }

    @Test func testARefusalCarriesTheTitleTheNoticeIsShownUnder() throws {
        // A row the table does not hold at all, which is what a refused write looks like from here: the store
        // answers false and the caller has something to say rather than a silent no-op.
        #expect(database.execute("DELETE FROM setting WHERE setting_name = 'display_seconds';"))

        let outcome = AppSettingWrite.apply(.showsSeconds(false), to: settings, debugLog: nil)

        guard case let .refused(title) = outcome else {
            Issue.record("a missing row has to refuse rather than report success")
            return
        }
        #expect(!title.isEmpty, "the notice needs something to be shown under")
    }
}

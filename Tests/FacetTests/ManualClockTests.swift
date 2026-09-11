@testable import FacetCore
import Foundation
import Testing

/// Stopping and starting the app's own clock, against a real database and no window.
///
/// **Its only cover was AppKit suites that cannot run on Linux.** `togglePause` lived in
/// `SettingsWindowController`, so every test of it built the whole controller: seven such suites exist and all
/// seven are on `platformBoundTests`. The decision is not a window's -- the status item's right half and the
/// dropdown's Pause item both reach it with Settings shut -- and now neither is its test.
///
/// **The refusal is the one worth pinning.** Both controls grey themselves when the daily limit is spent, and
/// that is the courtesy; this is what makes finding another button useless.
@Suite @MainActor
final class ManualClockTests {
    private let database: TemporaryDatabase
    private var connection: DatabaseConnection!
    private var events: DeviceEventRecorder!
    private var readout: TimingReadout!
    private var categories: CategoryStore!
    private var faces: FaceStore!

    private let moment = Date(timeIntervalSince1970: 1_786_600_000)

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        connection = database.connection()
        faces = FaceStore(connection: connection)
        categories = CategoryStore(connection: connection)
        // Wired as `main.swift` wires it, so closing a segment records the stretch: the figure is summed from
        // `time_entry`, and a recorder with nowhere to hand a finished one would show none of it.
        events = DeviceEventRecorder(
            connection: connection,
            timezones: TimezoneStore(connection: connection),
            timeEntries: TimeEntryRecorder(
                connection: connection,
                settings: SettingStore(connection: connection),
                faces: faces,
                debugLog: nil
            ),
            debugLog: nil
        )
        readout = TimingReadout(
            categories: categories,
            faces: faces,
            events: events,
            dayTotal: DayTotal(
                settings: SettingStore(connection: connection),
                entries: TimeEntryStore(connection: connection),
                events: events,
                faces: faces
            )
        )
    }

    deinit {
        database.remove()
    }

    /// Something running, which is what a stop is asked of.
    ///
    /// **A segment on its own is not "running".** `ManualTimerRules` answers `.idle` when the face carries no
    /// category, because an open row against nothing is not a session anybody started. Category 1 is the DDL's
    /// own seed (`database/007_category.sql`), which is what `TimingReadoutTests` uses too.
    private func startSomething() {
        #expect(faces.assign(categoryID: 1, toFace: ManualFace.first))
        events.startSegment(face: ManualFace.first, at: moment)
    }

    @Test func testStoppingSomethingRunningClosesTheSegment() throws {
        startSomething()
        #expect(readout.read().timingState == .running)

        let after = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: false,
            at: moment.addingTimeInterval(60), debugLog: nil
        )

        #expect(after?.timingState == .paused)
        #expect(readout.read().timingState == .paused, "and the table says so, not just the answer")
    }

    @Test func testStartingAgainResumesOnTheSameFaceRatherThanTheNext() throws {
        // **Rotating exists to stop a face's category changing under a finished segment, and resuming does not
        // change it.** Taking the next face here would cycle the pool for nothing on a pause-heavy session.
        startSomething()
        let face = events.currentManualFace()
        _ = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: false,
            at: moment.addingTimeInterval(60), debugLog: nil
        )

        _ = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: false,
            at: moment.addingTimeInterval(120), debugLog: nil
        )

        #expect(readout.read().timingState == .running)
        #expect(events.currentManualFace() == face)
    }

    @Test func testTheAnswerIsReadBackFromTheTableRatherThanAssumed() throws {
        // The rule applied to the app's own writes as well as to what it shows: this says what the table now
        // holds, so a write that did not take says so here rather than being reported as done.
        startSomething()

        let after = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: false,
            at: moment.addingTimeInterval(60), debugLog: nil
        )

        #expect(after == readout.read())
    }

    // MARK: - the refusal

    @Test func testASpentDailyLimitRefusesAResumeAndWritesNothing() throws {
        startSomething()
        _ = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: false,
            at: moment.addingTimeInterval(60), debugLog: nil
        )
        #expect(readout.read().timingState == .paused)

        let after = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: true,
            at: moment.addingTimeInterval(120), debugLog: nil
        )

        #expect(after == nil, "nil is the caller's instruction not to repaint")
        #expect(readout.read().timingState == .paused, "and nothing was started")
    }

    @Test func testASpentLimitDoesNotStopSomethingAlreadyRunning() throws {
        // **Stopping is always allowed**, which `ManualTimerRules.isClickable` decides and this pins against a
        // real table: a limit that made the clock unstoppable would trap a session running past its own budget.
        startSomething()

        let after = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: true,
            at: moment.addingTimeInterval(60), debugLog: nil
        )

        #expect(after?.timingState == .paused)
    }

    @Test func testNothingBeingTimedIsNothingToStopOrStart() throws {
        // No clock and no row, so there is nothing here to do. The same question the dropdown's Pause item and
        // the status item's right side ask, and the same answer.
        let after = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: false, at: moment, debugLog: nil
        )

        #expect(after == nil)
    }

    // MARK: - the rows a scripted check reads

    @Test func testTheRowsKeepTheWordingTheCheckersMatchOn() throws {
        // `05-faces-timing` waits on `Timing: stopped <name>` and `Timing: running <name>`, so the wording is
        // interface. It moved file on 2026-09-11 and must not have moved wording.
        try database.bootstrapDebug()
        let log = DebugLog(databaseURL: database.debugURL, isRecording: true)
        startSomething()

        _ = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: false,
            at: moment.addingTimeInterval(60), debugLog: log
        )
        _ = ManualClock.toggle(
            timing: readout, events: events, isLimitReached: true,
            at: moment.addingTimeInterval(120), debugLog: log
        )

        let rows = database.debugString("SELECT group_concat(message, ' | ') FROM debug_log;") ?? ""
        #expect(rows.contains("Timing: stopped"), "\(rows)")
        #expect(rows.contains("Resume refused"), "\(rows)")
        #expect(rows.contains("has spent its daily limit"), "\(rows)")
    }
}

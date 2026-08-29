@testable import FacetApp
import AppKit
import XCTest

/// Covers the Auto-pause field reaching the `auto_pause_minutes` row: after the arrows stop, once, and not before.
///
/// **On a real database rather than on doubles**, for the reason `CreateStartsTimingTests` is on one: what is being
/// checked is not that a method was called, it is that the table holds the number, and only the table can say so.
///
/// **Driven at the real half second**, which is where this differs from `WriteDebounceTests`. That file drives a 20ms
/// interval because coalescing is a fact about the mechanism and not about the duration; this one is about the wiring
/// behind one field, and the window's debounces are its own. Every wait here ends the moment the row moves, so what it
/// costs is the debounce rather than the deadline.
///
/// **What is not here is the cube.** Auto-pause is a device setting and nothing sends it yet, so a table holding 15
/// minutes says what the app has been asked to keep and nothing about what the cube is doing. Confirming the delay on
/// hardware belongs to the feature that sends `0x05` and reads `0x10` back.
@MainActor
final class AutoPauseSettlesBeforeItIsWrittenTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    /// A real log, because two of the claims below are about rows: that one hold of the arrow writes one of them, and
    /// that a refusal says so rather than passing in silence.
    private var debugLog: DebugLog!
    private var controller: SettingsWindowController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            _ = try database.bootstrap()
            _ = try database.bootstrapDebug()
            settings = SettingStore(connection: database.connection())
            debugLog = DebugLog(databaseURL: database.debugURL)
            controller = SettingsWindowController(
                debugLog: debugLog, categories: nil, faces: nil, settings: settings
            )
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            controller = nil
            debugLog = nil
            settings = nil
            database.remove()
        }
        super.tearDown()
    }

    // MARK: - reaching the tab

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The Device tab's pane, found the way the controller finds it. Every pane is built when `panes` is first
    /// asked for, so this needs no tab to be selected.
    private func devicePane() throws -> DevicePane {
        try XCTUnwrap(controller.panes.tabViewItems.compactMap { $0.view as? DevicePane }.first)
    }

    /// The field carries the identifier and the control around it owns it, as on the App tab.
    private func autoPauseField(in pane: DevicePane) throws -> SteppedNumberField {
        try XCTUnwrap(
            descendants(of: pane).compactMap { $0 as? SteppedNumberField }
                .first {
                    descendants(of: $0).contains { $0.accessibilityIdentifier() == DevicePane.Identifier.autoPause }
                }
        )
    }

    /// Steps the field the way somebody does, one press of an arrow. A *hold* is `StepperHoldRules`, tested on its
    /// own: driving one here would mean holding a real mouse button down for several seconds.
    private func press(_ direction: Int, times: Int = 1) throws {
        let field = try autoPauseField(in: devicePane())
        let arrow = try XCTUnwrap(
            descendants(of: field).compactMap { $0 as? HoldArrow }.first { $0.direction == direction }
        )
        for _ in 0 ..< times { arrow.performClick(nil) }
    }

    /// What the table holds, asked of the table every time.
    private func stored() -> Int? {
        settings.integer("auto_pause_minutes", field: "minutes")
    }

    /// How many log rows match, which is a SQL `LIKE`. A count read as a number, so a query that cannot run answers
    /// zero rather than something that reads as a match (the trap `DeviceReconnectorOfferTests` records).
    private func rows(matching pattern: String) -> Int {
        Int(database.debugString("SELECT COUNT(*) FROM debug_log WHERE message LIKE '\(pattern)';") ?? "0") ?? 0
    }

    /// Waits for the thing to **have happened** rather than for a span somebody guessed would cover it, and spins the
    /// run loop rather than sleeping through it: the debounce is a `Timer` in `.common`, and a sleeping test never
    /// lets it fire. Copied from `WriteDebounceTests`, where a fixed wait had already failed on a loaded runner.
    private func waitUntil(
        _ what: String,
        within timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    // MARK: - what the wiring does

    func testTheSeededRowIsWhatTheFieldOpensOn() throws {
        // The precondition every other test here leans on, and worth stating rather than assuming: `011_setting.sql`
        // seeds the delay off, so a field that opened anywhere else would make the numbers below mean nothing.
        XCTAssertEqual(stored(), 0)
        XCTAssertEqual(try autoPauseField(in: devicePane()).value, 0)
    }

    func testNothingIsWrittenWhileTheValueCouldStillMove() throws {
        try press(1)

        XCTAssertEqual(try autoPauseField(in: devicePane()).value, 1, "the field moved, as somebody just moved it")
        XCTAssertEqual(stored(), 0, "and the table has not, because the arrows could still be going")
    }

    func testTheValueReachesTheTableOnceTheArrowsStop() throws {
        try press(1)

        waitUntil("the row holds what the field was left on") { self.stored() == 1 }
        XCTAssertEqual(
            rows(matching: "Auto-pause: the table now holds 1m, and the cube has not been told"), 1,
            "and the row says the cube was not told, which is true until 0x05 is sent"
        )
    }

    func testARunOfChangesBecomesOneRowWritten() throws {
        // **The whole reason the write is held back.** A held arrow moves this field ten times a second
        // (`StepperHoldRules`), and every tick reaching the table would be a read, a rewrite and a read-back apiece
        // for numbers nobody stopped on.
        try press(1, times: 4)

        waitUntil("the table ends up on the number the arrow was let go on") { self.stored() == 4 }
        XCTAssertEqual(rows(matching: "Auto-pause: the table now holds%"), 1, "one write, not one per press")
        XCTAssertEqual(rows(matching: "Auto-pause: the table now holds 4m%"), 1, "and it carried the last number")
    }

    func testWhatLandedIsRecordedWithoutTakingTheFieldBack() throws {
        // The race this loses on purpose: the write goes out with 1 on it, somebody steps to 2 while it is being
        // made, and putting 1 back into the field would take that edit off the screen and then write it again.
        try press(1)
        waitUntil("the first value landed") { self.stored() == 1 }

        try press(1)

        XCTAssertEqual(try autoPauseField(in: devicePane()).value, 2, "still what was stepped to")
        XCTAssertEqual(try devicePane().values.autoPauseMinutes, 1, "and what landed is what was recorded")
    }

    func testARefusedWritePutsTheFieldBackToWhatTheTableHolds() throws {
        // **A missing row is how a write is refused**, and it is the honest way to provoke one: `SettingStore.write`
        // does not insert, the rows being seeded by the DDL, so a row that is not there is a database behind rather
        // than a setting waiting to be made.
        XCTAssertTrue(database.execute("DELETE FROM setting WHERE setting_name = 'auto_pause_minutes';"))

        try press(1, times: 2)

        waitUntil("the field goes back") { (try? self.autoPauseField(in: self.devicePane()).value) == 0 }
        XCTAssertEqual(rows(matching: "Auto-pause: the table REFUSED 2m"), 1, "and it says so rather than passing")
    }
}

@testable import FacetApp
import AppKit
import XCTest

/// Covers what the Auto-pause field does when the arrows stop: one attempt at the cube, after the value settles, and
/// nothing written down that the cube did not confirm.
///
/// **On a real database rather than on doubles**, for the reason `CreateStartsTimingTests` is on one: the claim is
/// that the `auto_pause_minutes` row did or did not move, and only the table can say.
///
/// **What cannot be here is a cube that says yes.** `swift test` never touches a radio, so every path below ends in a
/// refusal of one kind or another -- which is exactly the half worth pinning hermetically, since it is the half that
/// must leave the table alone. That a cube takes `0x05`, answers `0x10` with the same delay and the row then follows
/// is `Tests/Scripted/65-auto-pause.sh`, against real hardware.
///
/// **The window is drawn as though a cube were connected**, which the Auto-pause field needs to be live at all: it is
/// dead until the table says there is one to send to. Nothing here makes that true of the radio, so the send still
/// finds nothing -- see `setUpWithError`.
///
/// **Driven at the real half second**, unlike `WriteDebounceTests`, which drives 20ms because coalescing is a fact
/// about the mechanism rather than about the duration. Here the wiring is the subject and the window's debounces are
/// its own. Every wait ends the moment the row appears, so what it costs is the debounce rather than the deadline.
@MainActor
final class AutoPauseSettlesBeforeItIsSentTests: XCTestCase, @unchecked Sendable {
    private var database: TemporaryDatabase!
    private var settings: SettingStore!
    /// A real log, because most of what is claimed below is a row: that one hold makes one attempt, and that a
    /// refusal says which kind it was rather than passing in silence.
    private var debugLog: DebugLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MainActor.assumeIsolated {
            database = TemporaryDatabase()
            _ = try database.bootstrap()
            _ = try database.bootstrapDebug()
            settings = SettingStore(connection: database.connection())
            debugLog = DebugLog(databaseURL: database.debugURL)
            // **The table has to say a cube is connected, because the field is dead unless it does**
            // (`DevicePane.show`). The radio still has none, and that pairing of a row saying connected with a radio
            // holding nothing is not artificial: it is the state between a link going down and the drop being
            // recorded, and what the window does in it -- refuse the write rather than record it -- is what these
            // tests are about.
            XCTAssertTrue(settings.write("connection", field: "connected", true))
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            debugLog = nil
            settings = nil
            database.remove()
        }
        super.tearDown()
    }

    // MARK: - the window

    /// A window with a radio that has no cube on it, which is the ordinary way this fails: somebody moves the arrows
    /// with the cube out of range or flat, and `BluetoothRadio.send` refuses at once rather than reaching for
    /// anything. The manager is not built until something scans, so this touches no hardware and provokes no
    /// permission prompt (`DeviceReconnectorOfferTests` builds one the same way and for the same reason).
    ///
    /// **Handed one rather than left to make its own.** The window builds a radio for itself as the Device pane is
    /// wired (`deviceRadio`), so there is no such thing as a window without one here; passing it in is only what
    /// makes that visible at the top of each test.
    private func window() -> SettingsWindowController {
        SettingsWindowController(
            debugLog: debugLog, categories: nil, faces: nil, settings: settings, radio: BluetoothRadio(debugLog: nil)
        )
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The Device tab's pane, found the way the controller finds it. Every pane is built when `panes` is first asked
    /// for, so this needs no tab to be selected.
    private func devicePane(in controller: SettingsWindowController) throws -> DevicePane {
        try XCTUnwrap(controller.panes.tabViewItems.compactMap { $0.view as? DevicePane }.first)
    }

    /// The field carries the identifier and the control around it owns it, as on the App tab.
    private func field(in controller: SettingsWindowController) throws -> SteppedNumberField {
        try XCTUnwrap(
            descendants(of: try devicePane(in: controller)).compactMap { $0 as? SteppedNumberField }
                .first {
                    descendants(of: $0).contains { $0.accessibilityIdentifier() == DevicePane.Identifier.autoPause }
                }
        )
    }

    /// Steps the field the way somebody does, one press of an arrow. A *hold* is `StepperHoldRules`, tested on its
    /// own: driving one here would mean holding a real mouse button down for several seconds.
    private func press(_ direction: Int, times: Int = 1, in controller: SettingsWindowController) throws {
        let arrow = try XCTUnwrap(
            descendants(of: try field(in: controller)).compactMap { $0 as? HoldArrow }
                .first { $0.direction == direction }
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
        let window = window()

        XCTAssertEqual(stored(), 0)
        XCTAssertEqual(try field(in: window).value, 0)
    }

    func testNothingIsSentWhileTheValueCouldStillMove() throws {
        let window = window()

        try press(1, in: window)

        XCTAssertEqual(try field(in: window).value, 1, "the field moved, as somebody just moved it")
        XCTAssertEqual(rows(matching: "Auto-pause:%"), 0, "and nothing has been attempted, because it could still move")

        waitUntil("the attempt follows once the arrows stop") { self.rows(matching: "Auto-pause: sending 1m") == 1 }
    }

    func testARunOfChangesBecomesOneAttempt() throws {
        // **The whole reason the write is held back.** A held arrow moves this field ten times a second
        // (`StepperHoldRules`), and every tick reaching the cube would be a `0x05` and a `0x10` behind it for numbers
        // nobody stopped on -- with `DeviceLogin.send` refusing each one that arrived while the last was still out.
        let window = window()

        try press(1, times: 4, in: window)

        waitUntil("the attempt carries the number the arrow was let go on") {
            self.rows(matching: "Auto-pause: sending 4m") == 1
        }
        XCTAssertEqual(rows(matching: "Auto-pause: sending%"), 1, "one attempt, not one per press")
    }

    func testAValueTheCubeNeverTookIsNotWrittenDown() throws {
        // **The claim this file exists for.** The table is the app's record of what the cube is set to, so a row
        // written on the strength of a command no cube took would be the app's wish recorded as the cube's state,
        // which is the fault the first rule in `CLAUDE.md` is about.
        let window = window()

        try press(1, times: 2, in: window)

        waitUntil("the refusal is logged") { self.rows(matching: "Auto-pause: the cube did not take 2m%") == 1 }
        XCTAssertEqual(stored(), 0, "so the table still holds what it held")
        XCTAssertEqual(rows(matching: "Auto-pause: the table now holds%"), 0, "and nothing claims otherwise")
        waitUntil("and the field goes back to what is stored") { (try? self.field(in: window).value) == 0 }
    }
}

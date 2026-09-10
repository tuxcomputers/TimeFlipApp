@testable import FacetCore
import Foundation
import Testing

/// Settling one setting: the order it happens in, and what each way of failing leads to.
///
/// **The order is the whole point and it had no test.** Six rows on the Device tab each spelled out "send to
/// the cube, then write the table only if the cube took it", and a sequence written six times is one that can
/// be written differently once. What made it unassertable was that every copy lived inside
/// `SettingsWindowController`, behind a real radio and a real `NSAlert`.
@Suite @MainActor
struct DeviceSettingWriteTests {
    private static let command = Data([0x05, 0x00, 0x0F])

    /// Records what happened and in what order, which is what these tests are really about.
    @MainActor
    final class Wire {
        var events: [String] = []
        /// What the cube answers. `nil` leaves the command unanswered, which is a cube still thinking.
        var cubeTakesIt: Bool? = true
        var tableTakesIt = true

        var send: ((Data, @escaping (Bool) -> Void) -> Void) {
            { [self] _, reported in
                events.append("sent")
                if let cubeTakesIt { reported(cubeTakesIt) }
            }
        }

        func record() -> Bool {
            events.append("recorded")
            return tableTakesIt
        }
    }

    private func settle(_ wire: Wire, radio: Bool = true) -> DeviceSettingWrite.Outcome? {
        var outcome: DeviceSettingWrite.Outcome?
        DeviceSettingWrite.send(
            Self.command,
            "Auto-pause",
            value: "15m",
            through: radio ? wire.send : nil,
            recording: { wire.record() },
            debugLog: nil
        ) { outcome = $0 }
        return outcome
    }

    // MARK: - the order

    @Test func testTheCubeIsAskedBeforeTheTableIsWritten() {
        // **The fault this exists to make impossible.** A row written on the strength of a command the cube
        // refused is the app's wish recorded as the cube's state, which is the two-answers disagreement the
        // first design rule is about.
        let wire = Wire()

        _ = settle(wire)

        #expect(wire.events == ["sent", "recorded"])
    }

    @Test func testARefusedCommandWritesNothingAtAll() {
        let wire = Wire()
        wire.cubeTakesIt = false

        let outcome = settle(wire)

        #expect(outcome == .refusedByTheCube)
        #expect(wire.events == ["sent"], "the table is never reached")
    }

    @Test func testNoRadioSendsNothingAndWritesNothing() {
        // A field left showing a number that reached neither the cube nor the table is the surface claiming
        // something about hardware nobody ever asked.
        let wire = Wire()

        let outcome = settle(wire, radio: false)

        #expect(outcome == .nothingToSendTo)
        #expect(wire.events.isEmpty)
    }

    @Test func testACubeThatTookItAndATableThatWouldNotIsItsOwnOutcome() {
        // Rarer than a refusal and worse: the two now disagree, and which they disagree about matters to what
        // is said next.
        let wire = Wire()
        wire.tableTakesIt = false

        let outcome = settle(wire)

        #expect(outcome == .notRecorded)
        #expect(wire.events == ["sent", "recorded"])
    }

    @Test func testACubeStillThinkingSettlesNothingYet() {
        // The completion is called once, when there is an answer. A cube that never answers is the deadline's
        // problem and not this function's.
        let wire = Wire()
        wire.cubeTakesIt = nil

        #expect(settle(wire) == nil)
    }

    // MARK: - what the surface does about it

    @Test func testEverythingButSuccessPutsTheRowBack() {
        for outcome in [
            DeviceSettingWrite.Outcome.nothingToSendTo, .refusedByTheCube, .notRecorded, .nowhereToRecord,
        ] {
            #expect(outcome.putsTheRowBack, "\(outcome)")
        }
        // **And success must not.** By the time a write has been read back the field may hold a newer number
        // with a write of its own queued, and assigning this one would take that edit off the screen.
        #expect(!DeviceSettingWrite.Outcome.settled.putsTheRowBack)
    }

    @Test func testSuccessAndAMissingRadioSayNothing() {
        // Silence on `nothingToSendTo` is deliberate: telling somebody their cube is not connected is what the
        // tab already does, and every other writing row answers the same way.
        #expect(DeviceSettingWrite.notice(for: .settled, setting: "the auto-pause delay") == nil)
        #expect(DeviceSettingWrite.notice(for: .nothingToSendTo, setting: "the auto-pause delay") == nil)
    }

    @Test func testTheTwoWaysOfFailingReadDifferently() throws {
        // A cube that refused and a table that refused have opposite remedies, so they must not share wording:
        // one says nothing changed, the other says the device and the app now disagree.
        let refused = try #require(DeviceSettingWrite.notice(for: .refusedByTheCube, setting: "the delay"))
        let unrecorded = try #require(DeviceSettingWrite.notice(for: .notRecorded, setting: "the delay"))

        #expect(refused.title == "The TimeFlip did not accept that")
        #expect(refused.message.contains("nothing has changed"))
        #expect(unrecorded.title == "That setting was not saved")
        #expect(unrecorded.message.contains("now disagree"))
        #expect(refused.choices.isEmpty, "both are notices, with nothing to decide")
        #expect(unrecorded.choices.isEmpty)
    }

    // MARK: - the rows a scripted check reads

    @Test func testTheRowsKeepTheWordingTheCheckersMatchOn() {
        // **`label: verb value`, and it is not cosmetic.** `Tests/Scripted` reads these back with SQL `LIKE`
        // patterns, and that suite is set aside, so a tidied message would break checks that cannot say so.
        let wire = Wire()
        wire.cubeTakesIt = false
        let database = TemporaryDatabase()
        defer { database.remove() }
        try? database.bootstrap()
        let log = DebugLog(databaseURL: database.debugURL, isRecording: true)

        DeviceSettingWrite.send(
            Self.command, "Auto-pause", value: "15m",
            through: wire.send, recording: { wire.record() }, debugLog: log
        ) { _ in }

        let rows = database.debugString("SELECT group_concat(message, ' | ') FROM debug_log;") ?? ""
        #expect(rows.contains("Auto-pause: sending 15m"), "\(rows)")
        #expect(rows.contains("Auto-pause: the cube did not take 15m"), "\(rows)")
        #expect(!rows.contains("the table now holds"), "nothing may claim the table took it")
    }
}

@testable import FacetCore
import Foundation
import Testing

/// What the app does when the radio says something, with no radio and no window.
///
/// **None of this was testable before.** It lived in `SettingsWindowController.adopt`, so reaching it needed the
/// whole controller plus AppKit, and every suite that did is excluded on Linux. The reactions are not a
/// window's: a paired app follows its cube with Settings shut, which is why the reconnect loop's backoff used
/// to depend on a controller having been constructed at launch.
///
/// **The orderings are what these pin.** Three of them matter and none is visible from the outside: the loop is
/// told about a login before anything is recorded, the row goes down before the loop is told about a drop, and
/// a refused login records nothing at all.
@Suite @MainActor
final class CubeReportsTests {
    private let database: TemporaryDatabase
    private var settings: SettingStore!
    private var reports: CubeReports!
    private var dialogues: RecordingDialogues!
    private var redraws = 0

    private let cube = DeviceHandle("00000000-0000-0000-0000-0000000000AA")
    private let stranger = DeviceHandle("00000000-0000-0000-0000-0000000000BB")

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        settings = SettingStore(connection: database.connection())
        dialogues = RecordingDialogues()
        reports = CubeReports(settings: settings, devicePINs: nil, debugLog: nil)
        reports.dialogues = dialogues
        reports.changed = { [self] in redraws += 1 }
    }

    deinit {
        database.remove()
    }

    private func device(_ id: DeviceHandle, named name: String = "TimeFlip v2.0") -> ScannedDevice {
        ScannedDevice(id: id, peripheralName: name, advertisedName: name, advertisesTimeFlipService: true)
    }

    private func pairTo(_ id: DeviceHandle, named name: String = "TimeFlip v2.0") {
        #expect(settings.write("paired", field: "paired", true))
        #expect(settings.write("device_uuid", field: "uuid", id.value))
        #expect(settings.write("device_name", field: "name", name))
    }

    // MARK: - a login ending

    @Test func testALoginToAnUnknownCubeIsAPairing() {
        reports.loginEnded(.loggedIn, with: device(cube))

        #expect(settings.flag("paired", field: "paired") == true)
        #expect(settings.string("device_uuid", field: "uuid") == cube.value)
    }

    @Test func testALoginToTheCubeAlreadyOnRecordIsAReconnection() {
        // **The table decides which of the two this is**, not the caller: both are a PIN accepted by a cube, and
        // they are different claims about the app. A pairing here would rewrite rows that already said this.
        pairTo(cube)
        let before = settings.string("device_name", field: "name")

        reports.loginEnded(.loggedIn, with: device(cube, named: "Something Else"))

        #expect(settings.string("device_name", field: "name") == before, "a reconnection renames nothing")
    }

    @Test func testAnythingButALoginRecordsNothingAtAll() {
        // A refused PIN, a device that was not a TimeFlip and a cube that stopped answering all leave the table
        // as it was: a `paired` row written anyway sends the next launch after a device it cannot log into.
        for outcome in [DeviceLoginOutcome.wrongPIN, .notATimeFlip, .unreachable, .timedOut] {
            reports.loginEnded(outcome, with: device(cube))
        }

        #expect(settings.flag("paired", field: "paired") != true)
        #expect(redraws == 0, "and nothing is repainted for a login that changed nothing")
    }

    // MARK: - the name the cube reports

    @Test func testANameFromAStrangersCubeIsIgnored() {
        // Every connection reports a name, including the one that proves a factory reset and any made to a
        // device that turns out to be somebody else's. Writing one of those renames the pairing after a cube it
        // is not to.
        pairTo(cube, named: "Bandicoot")

        reports.nameArrived("Somebody Elses Cube", from: stranger)

        #expect(settings.string("device_name", field: "name") == "Bandicoot")
    }

    @Test func testTheNameFromBeforeARenameIsRefusedRatherThanAdopted() {
        // **The measured one.** macOS re-reads the GAP name only on connecting, so the connection after a rename
        // can still hand out the name the cube was renamed away from. Adopting it would undo the rename on the
        // tab and in the row the scan filter is built from, and put it back a connection later.
        pairTo(cube, named: "Bandicoot")
        #expect(settings.write("device_name", field: "previous_name", "TimeFlip v2.0"))

        reports.nameArrived("TimeFlip v2.0", from: cube)

        #expect(settings.string("device_name", field: "name") == "Bandicoot")
    }

    @Test func testANameTheCubeReallyChangedToIsAdopted() {
        pairTo(cube, named: "Bandicoot")

        reports.nameArrived("Renamed Elsewhere", from: cube)

        #expect(settings.string("device_name", field: "name") == "Renamed Elsewhere")
        #expect(redraws > 0)
    }

    // MARK: - what a surface is told

    @Test func testAReportWithNobodyLookingStillRecords() {
        // `changed` unset is an ordinary state, not a failure: the app follows its cube with no window open, and
        // the row is what the next open reads.
        reports.changed = nil

        reports.loginEnded(.loggedIn, with: device(cube))

        #expect(settings.flag("paired", field: "paired") == true)
    }

    @Test func testAPINNothingWouldTakeIsSaidOutLoud() {
        // With no store at all there is nothing to record into, which is the launch this cannot happen on. With
        // one that refuses, somebody has to be told: the cube is already on a PIN this app has lost.
        #expect(dialogues.told.isEmpty)

        reports.pinChanged(to: "123456")

        #expect(dialogues.told.isEmpty, "no store means nothing was attempted, so nothing is claimed")
    }
}

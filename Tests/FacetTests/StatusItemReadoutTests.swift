@testable import FacetCore
import Foundation
import Testing

/// What the menu bar reads: the line, whether to tick, whether anything moved, and which rows a move writes.
///
/// **The two logging rules had no unit coverage at all before this.** They were reachable only through
/// `MenuBarController.redraw`, which is Mac-only, so the only thing checking them was the scripted suite
/// (`expect_colours` in `Tests/Scripted/lib.sh`, and `53-device-reconnect`) -- which is set aside for the
/// duration of the Linux port. That mattered more than it looks: the rows are, by their own comments, the only
/// way the colours are visible at all, the accessibility tree carrying none.
@Suite @MainActor
final class StatusItemReadoutTests {
    private let database: TemporaryDatabase
    private var debugLog: DebugLog!

    init() throws {
        database = TemporaryDatabase()
        try database.bootstrap()
        debugLog = DebugLog(databaseURL: database.debugURL, isRecording: true)
    }

    deinit {
        database.remove()
    }

    @MainActor
    final class World {
        var reading: TimingReadout.Reading = .idle
        var cube = CubeReading(isCubeConnected: false, cubeLockState: .unknown)
        var showingSeconds = true
        var isLimitReached = false
        var lowBattery: LowBatteryAlert = .none
        var isManualMode = true
    }

    private static let meeting = CategoryRecord(
        id: 1,
        name: "Meeting",
        iconName: nil,
        colourID: 0,
        colour: nil,
        usesWhiteLines: false,
        dailyLimitMinutes: 0,
        isCategoryActive: true
    )

    private func readout(_ world: World, logging: Bool = false) -> StatusItemReadout {
        StatusItemReadout(
            appLabel: "Facet",
            timing: { world.reading },
            cube: { world.cube },
            showingSeconds: { world.showingSeconds },
            isLimitReached: { world.isLimitReached },
            lowBattery: { world.lowBattery },
            isManualMode: { world.isManualMode },
            debugLog: logging ? debugLog : nil
        )
    }

    private func rows(_ pattern: String) -> Int {
        Int(database.debugString("SELECT COUNT(*) FROM debug_log WHERE message LIKE '\(pattern)';") ?? "0") ?? 0
    }

    private func rows(tag: DebugLog.Tag) -> Int {
        Int(database.debugString("SELECT COUNT(*) FROM debug_log WHERE tag = '\(tag.rawValue)';") ?? "0") ?? 0
    }

    // MARK: - whether the clock behind it runs

    @Test func testACubeTimingKeepsTheItemTicking() {
        // **The fix this exists for.** A followed cube leaves `timingState` idle for the whole session, and the
        // tick was started on `timingState`, so the item stood still while a cube timed and jumped a whole
        // history interval whenever a fetch redrew it. The figure was growing on every read the entire time.
        let world = World()
        world.reading = TimingReadout.Reading(
            category: Self.meeting,
            timingState: .idle,
            seconds: 30,
            isCounting: true,
            cubeFace: 5,
            cubePauseState: .running
        )

        #expect(readout(world).read().isTicking)
    }

    @Test func testAStandingFigureDoesNotTick() {
        let world = World()
        world.reading = TimingReadout.Reading(
            category: Self.meeting, timingState: .paused, seconds: 30, isCounting: false
        )

        #expect(!readout(world).read().isTicking)
    }

    // MARK: - whether anything needs repainting

    @Test func testTheFirstReadAlwaysHasSomethingToDraw() {
        #expect(readout(World()).read().hasChanged)
    }

    @Test func testAnUnchangedLineIsNotRedrawn() {
        // Asked every second for the life of the launch, so this is what stops the item being laid out again
        // sixty times a minute with `display_seconds` off, where the figure only moves once.
        let readout = readout(World())
        _ = readout.read()

        #expect(!readout.read().hasChanged)
    }

    @Test func testALineThatMovesIsRedrawn() {
        let world = World()
        let readout = readout(world)
        _ = readout.read()

        world.reading = TimingReadout.Reading(
            category: Self.meeting, timingState: .running, seconds: 30, isCounting: true
        )

        #expect(readout.read().hasChanged)
    }

    // MARK: - the rows a change is worth

    @Test func testAColourChangeIsRecordedOnce() {
        let world = World()
        let readout = readout(world, logging: true)
        _ = readout.read()
        let before = rows("Menu bar:%")

        world.reading = TimingReadout.Reading(
            category: Self.meeting, timingState: .running, seconds: 30, isCounting: true
        )
        _ = readout.read()

        #expect(rows("Menu bar:%") == before + 1)
    }

    @Test func testATickingFigureWritesNoRowPerSecond() {
        // **What the whole colour-only rule is for.** `DebugLog` warns that a tag logging on a timer needs a
        // write queue first, and this is read from one: a row per drawn title would be a row per second for the
        // life of the launch. A colour moves when the app changes what it is doing, which is the rate the rest
        // of the log is written at.
        let world = World()
        world.reading = TimingReadout.Reading(
            category: Self.meeting, timingState: .running, seconds: 30, isCounting: true
        )
        let readout = readout(world, logging: true)
        _ = readout.read()
        let before = rows("Menu bar:%")

        for second in 31...40 {
            world.reading = TimingReadout.Reading(
                category: Self.meeting, timingState: .running, seconds: TimeInterval(second), isCounting: true
            )
            #expect(readout.read().hasChanged, "the figure moved, so it is repainted")
        }

        #expect(rows("Menu bar:%") == before, "ten repaints, no rows: the colour never moved")
    }

    @Test func testReachingForTheCubeIsRecordedUnderReachingAndNotStatus() {
        // **Never under `status`.** `expect_colours` reads the newest `status` row as what the line is drawn in
        // right now, so putting this there makes that read answer the wrong question, which it did, failing
        // `55-device-face` on run 167 against a menu bar that was correct.
        let world = World()
        world.isManualMode = false
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unknown)
        let readout = readout(world, logging: true)

        _ = readout.read()

        #expect(rows("The status item is reaching for the cube") == 1)
        #expect(rows(tag: .reaching) == 1)
    }

    @Test func testItSaysWhenItStopsReaching() {
        let world = World()
        world.isManualMode = false
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unknown)
        let readout = readout(world, logging: true)
        _ = readout.read()
        #expect(rows("The status item is reaching for the cube") == 1, "precondition")

        // A complete reading is what settles the latch: the cube has answered, so it is no longer being reached
        // for.
        world.reading = TimingReadout.Reading(
            category: Self.meeting,
            timingState: .idle,
            seconds: 30,
            isCounting: true,
            cubeFace: 5,
            cubePauseState: .running
        )
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unlocked, cubePauseState: .running)
        _ = readout.read()

        #expect(rows("The status item has read the cube and stops reaching") == 1)
    }
}

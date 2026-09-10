@testable import FacetCore
import Foundation
import Testing

/// What the status item's dropdown holds, and what each line says.
///
/// **All of this used to be Mac-only**, asserted through `NSMenu` in `MenuBarControllerTests`, which
/// `Package.swift` excludes from the Linux build. None of it was ever about AppKit: the order of the lines, what
/// Pause is called, whether Lock can be chosen and what choosing it does are the same answers on either
/// platform, and now they are checked on both. What stays in the Mac suite is the rendering, which is the part
/// that really is `NSMenu`.
@Suite @MainActor
struct StatusItemMenuTests {
    /// Mutable state the menu reads through its closures, so a test can move the world between two `items()`
    /// calls the way the app does.
    @MainActor
    final class World {
        var reading: TimingReadout.Reading = .idle
        var cube = CubeReading(isCubeConnected: false, cubeLockState: .unknown)
        var isLimitReached = false
        var settingsOpened = 0
        var appPauses = 0
        var cubePauses = 0
        var cubeLocks = 0
        var quits = 0

        var timingState: TimingState {
            get { reading.timingState }
            set {
                reading = TimingReadout.Reading(
                    category: reading.category, timingState: newValue, seconds: reading.seconds
                )
            }
        }
    }

    private func menu(_ world: World) -> StatusItemMenu {
        StatusItemMenu(
            timing: { world.reading },
            cube: { world.cube },
            isLimitReached: { world.isLimitReached },
            openSettings: { world.settingsOpened += 1 },
            togglePause: { world.appPauses += 1 },
            toggleCubePause: { world.cubePauses += 1 },
            toggleCubeLock: { world.cubeLocks += 1 },
            quit: { world.quits += 1 },
            debugLog: nil
        )
    }

    private func line(_ identifier: String, of world: World) -> StatusItemMenu.Item? {
        menu(world).items().first { $0.identifier == identifier }
    }

    // MARK: - what is in it

    @Test func testTheItemsAndTheirOrder() {
        let items = menu(World()).items()

        #expect(
            items.map { $0.isSeparator ? "---" : $0.identifier }
                == ["open-settings", "toggle-pause", "toggle-cube-lock", "---", "quit-app"],
            "Pause sits under Settings, Lock under Pause, and Quit stays behind a separator"
        )
    }

    @Test func testEveryLineIsNamedForAScript() {
        for item in menu(World()).items() where !item.isSeparator {
            #expect(!item.identifier.isEmpty, "\(item.title) needs an identifier")
        }
    }

    // MARK: - what Lock says, and when it can be chosen

    @Test func testTheLockLineIsDeadWithNoCubeConnected() {
        // It ends in a command, and a command needs a live link. A paired cube in another room can be neither
        // locked nor resumed, so a line offering it would be a control that does nothing and says nothing about
        // why.
        let world = World()
        world.cube = CubeReading(isCubeConnected: false, cubeLockState: .unknown)

        let lock = line(StatusItemMenu.Identifier.toggleCubeLock, of: world)

        #expect(lock?.title == "Lock")
        #expect(lock?.choose == nil, "nothing to choose is how a dead line is said")
    }

    @Test func testAConnectedUnlockedCubeIsOfferedALock() throws {
        let world = World()
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unlocked)

        let lock = try #require(line(StatusItemMenu.Identifier.toggleCubeLock, of: world))

        #expect(lock.title == "Lock")
        #expect(lock.choose != nil)
    }

    @Test func testALockedCubeIsOfferedAnUnlock() throws {
        let world = World()
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .locked)

        let lock = try #require(line(StatusItemMenu.Identifier.toggleCubeLock, of: world))

        #expect(lock.title == "Unlock")
        #expect(lock.choose != nil)
    }

    @Test func testACubeNobodyHasAskedYetReadsLock() throws {
        // The safer of the two to be wrong about: offering to lock an already-locked cube sends a command that
        // changes nothing, while offering to resume a running one would unlock what was never locked.
        let world = World()
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unknown)

        #expect(try #require(line(StatusItemMenu.Identifier.toggleCubeLock, of: world)).title == "Lock")
    }

    @Test func testNoTwoLinesEverReadTheSame() {
        // Seen on screen: with the app's clock stopped and the cube locked, the dropdown offered "Resume" twice,
        // one starting the app's clock and one starting the cube. Two lines reading the same thing while doing
        // entirely different things is a menu nobody can use.
        let world = World()
        world.timingState = .paused
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .locked)

        let titles = menu(world).items().filter { !$0.isSeparator }.map(\.title)

        #expect(Set(titles).count == titles.count, "two lines read the same: \(titles)")
    }

    // MARK: - what Pause says

    @Test func testWithNothingBeingTimedItReadsPauseAndCannotBeChosen() {
        let world = World()
        world.timingState = .idle

        let pause = line(StatusItemMenu.Identifier.togglePause, of: world)

        // "Pause" rather than "Resume": the line is dead either way, and a dead line claiming there is something
        // to resume is worse than one claiming there is something to pause.
        #expect(pause?.title == "Pause")
        #expect(pause?.choose == nil)
    }

    @Test func testWhileRunningItOffersToPause() {
        let world = World()
        world.timingState = .running

        let pause = line(StatusItemMenu.Identifier.togglePause, of: world)

        // A menu line says what choosing it does, which is the opposite of the glyph beside it: play showing
        // means recording, and this reads "Pause" at the same moment.
        #expect(pause?.title == "Pause")
        #expect(pause?.choose != nil)
    }

    @Test func testWhileStoppedItOffersToResume() {
        let world = World()
        world.timingState = .paused

        let pause = line(StatusItemMenu.Identifier.togglePause, of: world)

        #expect(pause?.title == "Resume")
        #expect(pause?.choose != nil)
    }

    @Test func testASpentLimitTakesPauseAway() {
        // What makes the limit hard rather than advisory: with the budget gone there is nothing to resume.
        let world = World()
        world.timingState = .paused
        world.isLimitReached = true

        #expect(line(StatusItemMenu.Identifier.togglePause, of: world)?.choose == nil)
    }

    // MARK: - the menu never remembers

    @Test func testEveryLineIsDecidedAgainEachTimeTheMenuOpens() throws {
        // Asked as the menu opens rather than pushed when something changes: a menu that never remembers cannot
        // be stale, and nothing else has to know the menu exists.
        let world = World()
        let menu = menu(world)
        world.timingState = .running
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unlocked)
        #expect(menu.items()[1].title == "Pause")
        #expect(menu.items()[2].title == "Lock")

        world.timingState = .paused
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .locked)

        #expect(menu.items()[1].title == "Resume")
        #expect(menu.items()[2].title == "Unlock")
    }

    // MARK: - what choosing one does

    @Test func testChoosingSettingsOpensThem() throws {
        let world = World()

        let choose = try #require(line(StatusItemMenu.Identifier.settings, of: world)?.choose)
        choose()

        #expect(world.settingsOpened == 1)
    }

    @Test func testChoosingQuitAsksTheAppToStop() throws {
        // The one line whose action the platform supplies, `NSApp.terminate` here and `gtk_main_quit` there.
        let world = World()

        let choose = try #require(line(StatusItemMenu.Identifier.quit, of: world)?.choose)
        choose()

        #expect(world.quits == 1)
    }

    @Test func testChoosingLockGoesToTheOneLockPath() throws {
        let world = World()
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unlocked)

        let choose = try #require(line(StatusItemMenu.Identifier.toggleCubeLock, of: world)?.choose)
        choose()

        #expect(world.cubeLocks == 1)
    }

    @Test func testPauseStopsTheAppsOwnClockWhenThatIsWhatIsRunning() throws {
        let world = World()
        world.timingState = .running

        let choose = try #require(line(StatusItemMenu.Identifier.togglePause, of: world)?.choose)
        choose()

        #expect(world.appPauses == 1)
        #expect(world.cubePauses == 0)
    }

    @Test func testPauseStopsTheCubeWhenTheCubeIsWhatIsRunning() throws {
        // With no manual session running, Pause is the cube's, exactly as a single click on the right half is.
        // It used to ask only about the app's own clock and so sat greyed above a status item that would
        // happily pause the cube.
        let world = World()
        world.timingState = .idle
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unlocked, cubePauseState: .running)

        let choose = try #require(line(StatusItemMenu.Identifier.togglePause, of: world)?.choose)
        choose()

        #expect(world.cubePauses == 1)
        #expect(world.appPauses == 0)
    }

    @Test func testPauseIsDecidedAgainWhenItIsChosen() throws {
        // **The stale-copy fault this codebase keeps being bitten by.** The menu may have been sitting open
        // while the cube went away, so what the line was named for is not necessarily what it should now do.
        let world = World()
        world.timingState = .idle
        world.cube = CubeReading(isCubeConnected: true, cubeLockState: .unlocked, cubePauseState: .running)
        let chosen = try #require(line(StatusItemMenu.Identifier.togglePause, of: world)?.choose)

        world.cube = CubeReading(isCubeConnected: false, cubeLockState: .unknown)
        chosen()

        #expect(world.cubePauses == 0, "the cube it was named for has gone, so nothing is sent to it")
        #expect(world.appPauses == 0, "and there is no app session either")
    }
}

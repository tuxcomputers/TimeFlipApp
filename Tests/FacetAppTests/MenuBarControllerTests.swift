@testable import FacetApp
import AppKit
import XCTest

/// Covers the dropdown -- what is in it, and how the Pause item reads and behaves for each timing state -- and the
/// order of the status item's own line.
///
/// Both are checked without calling `start()`, which would put a real status item in the menu bar of whoever is
/// running the tests. What the line *says* is `StatusItemTitle`'s to decide and is tested there; this covers the
/// composition, which is where the order lives.
///
/// Worth testing at all because the previous app's equivalent was three expressions inside a method that
/// built `NSMenuItem`s, out of reach of any test -- and that is how the dropdown came to disagree with the
/// status item about pausing, with nothing failing.
@MainActor
final class MenuBarControllerTests: XCTestCase {
    private var reading: TimingReadout.Reading = .idle
    private var state: TimingState {
        get { reading.state }
        set { reading = TimingReadout.Reading(category: reading.category, state: newValue, seconds: reading.seconds) }
    }
    private var toggles = 0
    private var cube = MenuBarController.CubeReading(isConnected: false, isLocked: nil)
    private var cubeToggles = 0

    /// Held for the length of the test, because an item's `target` is **weak**: a controller nobody keeps is
    /// deallocated the moment it is built, and then choosing an item reaches nobody, silently.
    ///
    /// The menu's *state* no longer depends on this -- `refresh` is called directly rather than through a weak
    /// delegate -- but the action still does, which is the same reason `main.swift` keeps the controller in a
    /// binding.
    private var kept: MenuBarController?

    override func tearDown() {
        kept = nil
        super.tearDown()
    }

    private func controller(badge: DatabaseBadge? = nil, showingSeconds: Bool = true) -> MenuBarController {
        let controller = MenuBarController(
            databaseBadge: badge,
            debugLog: nil,
            openSettings: {},
            timing: { self.reading },
            showingSeconds: { showingSeconds },
            togglePause: { self.toggles += 1 },
            cube: { self.cube },
            toggleCubeLock: { self.cubeToggles += 1 }
        )
        kept = controller
        return controller
    }

    // MARK: - how wide the item has to be

    func testALongerTitleNeedsAWiderItem() {
        // **The background macOS 26 draws behind a status item is sized from `NSStatusItem.length`**, and left to
        // `variableLength` that length did not follow a title that grew: timing "1" and then switching to
        // "SCRIPTED 1 REACTIVATE" drew the longer text spilling out of a capsule still the width of the shorter one
        // (seen 2026-08-16). The item is measured on every change now, so this is the measurement.
        let controller = controller()
        let short = NSAttributedString(string: "1")
        let long = NSAttributedString(string: "SCRIPTED 1 REACTIVATE")

        XCTAssertGreaterThan(controller.width(of: long), controller.width(of: short))
    }

    func testTheWidthLeavesRoomEitherSideOfTheInk() {
        // A measured string is the ink. Without the padding the last character sits on the edge of that background.
        let controller = controller()
        let text = NSAttributedString(string: "Facet")

        XCTAssertGreaterThan(controller.width(of: text), ceil(text.size().width))
    }

    private func menu() -> NSMenu {
        let controller = controller()
        let menu = controller.makeMenu()
        // What the controller does as it presents the menu, which is when the Pause item is named and enabled.
        controller.refresh(menu)
        return menu
    }

    private func pauseItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == MenuBarController.Identifier.togglePause }
    }

    // MARK: - what is in it

    func testTheItemsAndTheirOrder() {
        let items = menu().items

        XCTAssertEqual(
            items.map { $0.isSeparatorItem ? "---" : ($0.identifier?.rawValue ?? "?") },
            ["open-settings", "toggle-pause", "toggle-cube-lock", "---", "quit-app"],
            "Pause sits under Settings, Lock under Pause, and Quit stays behind a separator"
        )
    }

    func testEveryItemIsNamedForAScript() {
        for item in menu().items where !item.isSeparatorItem {
            XCTAssertNotNil(item.identifier?.rawValue, "\(item.title) needs an identifier")
            XCTAssertEqual(item.accessibilityIdentifier(), item.identifier?.rawValue)
        }
    }

    // MARK: - what Lock says, and when it can be chosen

    func testTheLockItemIsDeadWithNoCubeConnected() {
        // It ends in a command, and a command needs a live link. A paired cube in another room can be neither locked
        // nor resumed, so an item offering it would be a control that does nothing and says nothing about why.
        cube = MenuBarController.CubeReading(isConnected: false, isLocked: nil)

        let item = try? XCTUnwrap(lockItem())

        XCTAssertEqual(item?.isEnabled, false)
        XCTAssertEqual(item?.title, "Lock")
    }

    func testAConnectedUnlockedCubeIsOfferedALock() throws {
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: false)

        let item = try XCTUnwrap(lockItem())

        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.title, "Lock")
    }

    func testALockedCubeIsOfferedAnUnlock() throws {
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: true)

        let item = try XCTUnwrap(lockItem())

        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.title, "Unlock")
    }

    func testNoTwoItemsEverReadTheSame() throws {
        // Seen on screen: with the app's clock stopped and the cube locked, the dropdown offered "Resume" twice --
        // one starting the app's clock and one starting the cube. Two items reading the same thing while doing
        // entirely different things is a menu nobody can use.
        state = .paused
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: true)

        let titles = menu().items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(Set(titles).count, titles.count, "two items read the same: \(titles)")
    }

    func testACubeNobodyHasAskedYetReadsLock() throws {
        // The safer of the two to be wrong about: offering to lock an already-locked cube sends a command that
        // changes nothing, while offering to resume a running one would unlock what was never locked.
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: nil)

        XCTAssertEqual(try XCTUnwrap(lockItem()).title, "Lock")
    }

    func testTheLockItemIsRenamedEveryTimeTheMenuOpens() throws {
        // The same rule as Pause beside it: the menu never remembers, so nothing has to tell it when the cube
        // changes.
        let controller = controller()
        let menu = controller.makeMenu()
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: false)
        controller.refresh(menu)
        XCTAssertEqual(try XCTUnwrap(item(named: MenuBarController.Identifier.toggleCubeLock, in: menu)).title, "Lock")

        cube = MenuBarController.CubeReading(isConnected: true, isLocked: true)
        controller.refresh(menu)

        XCTAssertEqual(
            try XCTUnwrap(item(named: MenuBarController.Identifier.toggleCubeLock, in: menu)).title,
            "Unlock"
        )
    }

    func testChoosingItGoesToTheOneLockPath() throws {
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: false)
        let item = try XCTUnwrap(lockItem())

        _ = item.target?.perform(item.action, with: item)

        XCTAssertEqual(cubeToggles, 1)
    }

    /// The Lock item out of a freshly refreshed menu.
    private func lockItem() -> NSMenuItem? {
        item(named: MenuBarController.Identifier.toggleCubeLock, in: menu())
    }

    private func item(named identifier: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == identifier }
    }

    // MARK: - what Pause says

    func testWithNothingBeingTimedItReadsPauseAndCannotBeChosen() {
        state = .idle

        let pause = pauseItem(in: menu())

        // "Pause" rather than "Resume": the item is dead either way, and a dead item claiming there is
        // something to resume is worse than one claiming there is something to pause.
        XCTAssertEqual(pause?.title, "Pause")
        XCTAssertEqual(pause?.isEnabled, false)
    }

    func testWhileRunningItOffersToPause() {
        state = .running

        let pause = pauseItem(in: menu())

        // A menu item says what clicking does, which is the opposite of the glyph beside it: play showing
        // means recording, and this reads "Pause" at the same moment.
        XCTAssertEqual(pause?.title, "Pause")
        XCTAssertEqual(pause?.isEnabled, true)
    }

    func testWhileStoppedItOffersToResume() {
        state = .paused

        let pause = pauseItem(in: menu())

        XCTAssertEqual(pause?.title, "Resume")
        XCTAssertEqual(pause?.isEnabled, true)
    }

    func testItIsRenamedEveryTimeTheMenuOpens() {
        let controller = controller()
        let menu = controller.makeMenu()

        state = .running
        controller.refresh(menu)
        XCTAssertEqual(pauseItem(in: menu)?.title, "Pause")

        state = .paused
        controller.refresh(menu)

        // Asked as the menu opens rather than pushed when the clock changes: a menu that never remembers
        // cannot be stale, and nothing else has to know the menu exists.
        XCTAssertEqual(pauseItem(in: menu)?.title, "Resume")
    }

    func testTheMenuDoesNotLetAppKitDecideWhatIsEnabled() {
        // Left on, AppKit enables an item whose action can be found -- which is always -- and overwrites
        // what the delegate just set.
        XCTAssertFalse(menu().autoenablesItems)
    }

    // MARK: - what choosing it does

    // MARK: - the line the item draws

    /// What an image in a line of text comes back as when the string is read as plain text.
    private let attachment = "\u{FFFC}"

    private func title(
        _ controller: MenuBarController,
        lowBattery: LowBatteryAlert = .none
    ) -> NSAttributedString {
        controller.makeTitle(
            StatusItemTitle.make(
                appLabel: "Facet",
                badgeDescription: nil,
                reading: reading,
                showingSeconds: true,
                lowBattery: lowBattery,
                // From the same reading the dropdown's Lock item is drawn from, so a test setting one gets the other.
                isCubeLocked: cube.isLocked == true
            )
        )
    }

    private func line(_ controller: MenuBarController) -> String {
        title(controller).string
    }

    /// The colour a stretch of the drawn line carries.
    private func colour(of substring: String, in title: NSAttributedString) -> NSColor? {
        let range = (title.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return title.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    func testTheOrderIsBadgeIconCategoryGlyphThenTime() {
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: "ic_calls", colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .running,
            seconds: 30
        )

        // The badge is first because it qualifies everything to its right, and the icon is inside the line rather
        // than the button's own image, which would draw it to the badge's left.
        XCTAssertEqual(
            line(controller(badge: .forEnvironment(.test))),
            "TEST \(attachment) Meeting \(attachment) 0:00:30"
        )
    }

    func testALockedCubeAddsABadgeBeforeTheGlyph() {
        // Beside the play/pause glyph rather than in place of it, which is the archive's rule: whether the cube is
        // still timing or stopped stays worth seeing while it is locked.
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: "ic_calls", colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .running,
            seconds: 30
        )
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: true)

        XCTAssertEqual(
            line(controller(badge: .forEnvironment(.test))),
            "TEST \(attachment) Meeting \(attachment) \(attachment) 0:00:30",
            "the lock badge sits between the name and the play glyph"
        )
    }

    func testALockedCubeShowsTheBadgeWithNothingBeingTimed() {
        // The state that most needs saying: a locked cube is why nothing is running.
        reading = .idle
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: true)

        XCTAssertEqual(line(controller()), "Facet \(attachment)")
    }

    func testTheBadgeGoesWhenTheCubeDoes() {
        // A link that drops takes the status with it (`BluetoothRadio` clears it), and the badge has to go with that
        // -- a lock drawn for a cube nobody can reach is a claim about hardware the app cannot see.
        reading = .idle
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: true)
        XCTAssertEqual(line(controller()), "Facet \(attachment)", "precondition")

        cube = MenuBarController.CubeReading(isConnected: false, isLocked: nil)

        XCTAssertEqual(line(controller()), "Facet")
    }

    func testAnUnlockedCubeAddsNothingToTheLine() {
        reading = .idle
        cube = MenuBarController.CubeReading(isConnected: true, isLocked: false)

        XCTAssertEqual(line(controller()), "Facet")
    }

    func testWithNothingBeingTimedItIsTheAppsNameAlone() {
        reading = .idle

        XCTAssertEqual(line(controller(badge: .forEnvironment(.test))), "TEST Facet")
    }

    func testWithoutTheDevFlagThereIsNoBadgeInTheLine() {
        reading = .idle

        // A shipped copy only ever has the real database, so a permanent "PROD" tag would take up menu bar space
        // answering something nobody asked.
        XCTAssertEqual(line(controller()), "Facet")
    }

    func testTheBadgeKeepsItsOwnColourWhileTheSessionIsGreen() {
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: "ic_calls", colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .running,
            seconds: 30
        )

        let title = title(controller(badge: .forEnvironment(.test)))

        // Two separate things being said: which database this launch writes to, and what the app is doing. A green
        // "TEST" would lose the warning the red is there to carry.
        XCTAssertEqual(colour(of: "TEST", in: title), .systemRed)
        XCTAssertEqual(colour(of: "Meeting", in: title), .systemGreen)
        XCTAssertEqual(colour(of: "0:00:30", in: title), .systemGreen)
    }

    func testWithNothingBeingTimedTheAppsNameIsNotGreen() {
        reading = .idle

        XCTAssertEqual(colour(of: "Facet", in: title(controller())), .labelColor)
    }

    func testAFlatCubeFlashesTheNameAndLeavesTheClockAlone() {
        // Where the warning actually reaches the screen. `StatusItemTitleTests` pins which colours are chosen; this
        // pins that the drawing applies them to the right stretch of the line -- the name and its icon alternate,
        // and the figure beside them stays the colour it was, being a clock somebody is reading.
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: "ic_calls", colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .running,
            seconds: 30
        )
        let flashing = title(controller(), lowBattery: LowBatteryAlert(isLow: true, isBlinkOn: true))
        let between = title(controller(), lowBattery: LowBatteryAlert(isLow: true, isBlinkOn: false))

        XCTAssertEqual(colour(of: "Meeting", in: flashing), .systemRed)
        XCTAssertEqual(colour(of: "0:00:30", in: flashing), .systemGreen)
        XCTAssertEqual(colour(of: "Meeting", in: between), .labelColor)
        XCTAssertEqual(colour(of: "0:00:30", in: between), .systemGreen)
    }

    func testTheAppsNameFlashesWhenThereIsNoSessionToFlash() {
        reading = .idle

        XCTAssertEqual(
            colour(of: "Facet", in: title(controller(), lowBattery: LowBatteryAlert(isLow: true, isBlinkOn: true))),
            .systemRed
        )
    }

    func testACategoryWithNoIconDrawsOneAttachmentRatherThanTwo() {
        reading = TimingReadout.Reading(
            category: CategoryRecord(
                id: 2, name: "Meeting", iconName: nil, colourID: 0, colour: nil, usesWhiteLines: false, dailyLimitMinutes: 0, isActive: true
            ),
            state: .paused,
            seconds: 30
        )

        XCTAssertEqual(line(controller()), "Meeting \(attachment) 0:00:30", "the glyph, and no artwork before the name")
    }

    // MARK: - what choosing it does

    func testChoosingItGoesToTheOneTogglePath() throws {
        state = .running
        let menu = menu()
        let pause = try XCTUnwrap(pauseItem(in: menu))

        // `NSApplication.shared` rather than `NSApp`: the latter is an implicitly unwrapped global that is
        // nil in a test bundle until the application object has been made, and reading it crashes the run.
        NSApplication.shared.sendAction(try XCTUnwrap(pause.action), to: pause.target, from: pause)

        XCTAssertEqual(toggles, 1, "the same closure the Timing column's control ends in")
    }
}

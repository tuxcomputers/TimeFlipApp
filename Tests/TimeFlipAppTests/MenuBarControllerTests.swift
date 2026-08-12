@testable import TimeFlipApp
import AppKit
import XCTest

/// Covers the dropdown: what is in it, and how the Pause item reads and behaves for each timing state.
///
/// The menu is built without calling `start()`, which would put a real status item in the menu bar of
/// whoever is running the tests.
///
/// Worth testing at all because the previous app's equivalent was three expressions inside a method that
/// built `NSMenuItem`s, out of reach of any test -- and that is how the dropdown came to disagree with the
/// status item about pausing, with nothing failing.
@MainActor
final class MenuBarControllerTests: XCTestCase {
    private var state: TimingState = .idle
    private var toggles = 0

    /// Held for the length of the test. A menu's delegate and an item's target are both **weak**, so a
    /// controller nobody keeps is deallocated the moment it is built -- and then the menu updates nothing and
    /// choosing an item reaches nobody, silently. (Which is why `main.swift` keeps it in a binding too.)
    private var kept: MenuBarController?

    override func tearDown() {
        kept = nil
        super.tearDown()
    }

    private func controller() -> MenuBarController {
        let controller = MenuBarController(
            databaseBadge: nil,
            debugLog: nil,
            openSettings: {},
            timingState: { self.state },
            togglePause: { self.toggles += 1 }
        )
        kept = controller
        return controller
    }

    private func menu() -> NSMenu {
        let menu = controller().makeMenu()
        // What AppKit does as the menu opens, which is when the Pause item is named and enabled.
        menu.delegate?.menuNeedsUpdate?(menu)
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
            ["open-settings", "toggle-pause", "---", "quit-app"],
            "Pause sits under Settings, and Quit stays behind a separator"
        )
    }

    func testEveryItemIsNamedForAScript() {
        for item in menu().items where !item.isSeparatorItem {
            XCTAssertNotNil(item.identifier?.rawValue, "\(item.title) needs an identifier")
            XCTAssertEqual(item.accessibilityIdentifier(), item.identifier?.rawValue)
        }
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
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertEqual(pauseItem(in: menu)?.title, "Pause")

        state = .paused
        menu.delegate?.menuNeedsUpdate?(menu)

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

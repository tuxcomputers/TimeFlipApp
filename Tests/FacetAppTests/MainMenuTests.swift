@testable import FacetApp
import AppKit
import XCTest

/// Covers `MainMenu`: the menu bar that makes ⌘X, ⌘C, ⌘V and ⌘A work in a text field.
///
/// Worth pinning down rather than eyeballing, because **the failure it fixes is silent at both ends**. A field with
/// no route to `paste(_:)` does not complain, it simply does nothing to a keystroke; and the trap that would break
/// this again -- putting the Edit menu first -- does not fail either, it quietly renames the menu to the app's own
/// name and hides Cut and Paste inside it. Neither shows up anywhere but on screen, which is how the whole menu came
/// to be missing from a rebuild whose hermetic suite was entirely green.
@MainActor
final class MainMenuTests: XCTestCase, @unchecked Sendable {
    private func submenu(_ identifier: String, in menu: NSMenu) throws -> NSMenu {
        let holder = menu.items.first { $0.identifier?.rawValue == identifier }
        return try XCTUnwrap(XCTUnwrap(holder).submenu, "\(identifier) should carry a submenu")
    }

    private func item(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == identifier })
    }

    // MARK: - the shape of the bar

    func testTheAppMenuComesFirstSoTheEditMenuIsNotDrawnAsIt() throws {
        let menu = MainMenu.make()

        // The whole reason the app menu exists. AppKit draws the *first* submenu as the application menu whatever it
        // is called, so an Edit menu in this position would appear under the app's name with Cut and Paste in it.
        XCTAssertEqual(menu.items.first?.identifier?.rawValue, MainMenu.Identifier.app)
        XCTAssertEqual(menu.items.count, 2, "an app menu and an Edit menu, and nothing else yet")
        XCTAssertEqual(menu.items.last?.identifier?.rawValue, MainMenu.Identifier.edit)
    }

    func testTheEditMenuCarriesTheFourEditingItemsInTheirPlatformOrder() throws {
        let edit = try submenu(MainMenu.Identifier.edit, in: MainMenu.make())

        XCTAssertEqual(
            edit.items.map { $0.identifier?.rawValue },
            [
                MainMenu.Identifier.cut,
                MainMenu.Identifier.copy,
                MainMenu.Identifier.paste,
                MainMenu.Identifier.selectAll,
            ]
        )
    }

    // MARK: - the shortcuts, which are the point

    func testEachEditingItemCarriesItsPlatformShortcut() throws {
        let edit = try submenu(MainMenu.Identifier.edit, in: MainMenu.make())
        let expected = [
            MainMenu.Identifier.cut: "x",
            MainMenu.Identifier.copy: "c",
            MainMenu.Identifier.paste: "v",
            MainMenu.Identifier.selectAll: "a",
        ]

        for (identifier, key) in expected {
            let item = try self.item(identifier, in: edit)
            XCTAssertEqual(item.keyEquivalent, key, "\(item.title) is the shortcut this menu exists to carry")
            // Command alone. `NSMenuItem` defaults to it, and the assertion is here because a stray modifier would
            // leave the item looking right in the menu and doing nothing to the keystroke somebody actually types.
            XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        }
    }

    func testEachEditingItemSendsThePlatformSelectorToWhateverIsBeingEdited() throws {
        let edit = try submenu(MainMenu.Identifier.edit, in: MainMenu.make())
        let expected: [String: Selector] = [
            MainMenu.Identifier.cut: #selector(NSText.cut(_:)),
            MainMenu.Identifier.copy: #selector(NSText.copy(_:)),
            MainMenu.Identifier.paste: #selector(NSText.paste(_:)),
            MainMenu.Identifier.selectAll: #selector(NSText.selectAll(_:)),
        ]

        for (identifier, selector) in expected {
            let item = try self.item(identifier, in: edit)
            XCTAssertEqual(item.action, selector)
            // **`nil`, and that is the mechanism rather than an omission.** The action goes down the responder chain
            // to whichever field is being edited; naming a target would tie the menu to one field, and there is no
            // one field -- the device name, the category and calendar names and every stepped number field all use it.
            XCTAssertNil(item.target)
        }
    }

    func testTheEditingItemsAreEnabledByTheResponderChainRatherThanByThisApp() throws {
        let edit = try submenu(MainMenu.Identifier.edit, in: MainMenu.make())

        // The opposite decision from `MenuBarController.makeMenu`, which turns this off because its items are enabled
        // from the app's own state. What should grey out Paste is an empty pasteboard and what should grey out Cut is
        // nothing being selected -- both answered by the responder chain, neither known to this app.
        XCTAssertTrue(edit.autoenablesItems)
    }

    // MARK: - Quit

    func testQuitIsInTheAppMenuAndCarriesNoShortcut() throws {
        let appMenu = try submenu(MainMenu.Identifier.app, in: MainMenu.make())
        let quit = try item(MainMenu.Identifier.quit, in: appMenu)

        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertNil(quit.target, "so it reaches NSApp, and so QuitSequence, exactly as the dropdown's Quit does")
        // The app's standing rule, carried over from the archive with its reason: this menu is only reachable while
        // Settings is open, and a stray ⌘Q aimed at a field has quit the app out from under somebody before.
        XCTAssertEqual(quit.keyEquivalent, "", "no ⌘Q, matching the dropdown's Quit")
    }

    func testTheAppMenuIsNotEmpty() throws {
        // An app menu that opens onto nothing reads as a menu that failed to build, which is the reason it holds Quit
        // rather than being the placeholder it would otherwise be.
        let appMenu = try submenu(MainMenu.Identifier.app, in: MainMenu.make())

        XCTAssertFalse(appMenu.items.isEmpty)
    }

    // MARK: - installing it

    func testInstallingItPutsItOnTheApplication() {
        let app = NSApplication.shared
        // Put back afterwards: this is the one test that touches process-wide state, and a menu bar left behind would
        // be inherited by every test that runs after it.
        let previous = app.mainMenu
        defer { app.mainMenu = previous }

        MainMenu.install(into: app)

        XCTAssertEqual(app.mainMenu?.items.first?.identifier?.rawValue, MainMenu.Identifier.app)
        XCTAssertEqual(app.mainMenu?.items.last?.identifier?.rawValue, MainMenu.Identifier.edit)
    }
}

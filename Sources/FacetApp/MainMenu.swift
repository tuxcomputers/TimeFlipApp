import AppKit

/// The application menu bar: an app menu and an Edit menu, installed once at launch.
///
/// **It exists so that ⌘X, ⌘C, ⌘V and ⌘A work in a text field**, which until now they did not, anywhere in the app.
/// The reason is not obvious from the field's side: `NSTextField` and the field editor behind it implement `cut(_:)`,
/// `copy(_:)`, `paste(_:)` and `selectAll(_:)` perfectly well, but nothing turns a *keystroke* into one of those
/// calls. `NSApplication.sendEvent` offers a key-down to `mainMenu.performKeyEquivalent` first, and it is the menu
/// item that carries the shortcut; with no main menu there is no item, so the keystroke reaches the field as an
/// ordinary character and is dropped. Every editable field in the app is affected -- the device name and the category
/// and calendar names in `EditableNameCell`, `CategoryCreateControl`'s name field, and every `SteppedNumberField` --
/// and the failure is silent, which is why it survived a full rebuild.
///
/// **Copied from the archive's `ApplicationDelegate.setupMainMenu`**, which is the same four items with the same
/// selectors and no shortcut on Quit. Rewriting it would land in the same place: these are the platform's own
/// selectors and their key equivalents are not ours to choose. What is not copied is where it lived, the archive
/// building it inline in a delegate that could not be reached from a test.
///
/// **The menu is only ever visible while the Settings window is open**, since `SettingsWindowController` is what
/// switches the app to `.regular` and back (`main.swift` leaves it `.accessory`). That is also the only time a window
/// of this app's can be key, so it is exactly the span in which any of this can matter. Installing it once at launch
/// rather than with the window keeps the menu bar from being something a window owns.
@MainActor
enum MainMenu {
    /// Names for the parts a test or a scripted check addresses. The four editing items are named too, even though
    /// nothing presses them by name today: they are the reason this type exists, and an item nobody can find is an
    /// item nobody can prove is there.
    enum Identifier {
        static let app = "main-menu-app"
        static let quit = "main-menu-quit"
        static let edit = "main-menu-edit"
        static let cut = "main-menu-cut"
        static let copy = "main-menu-copy"
        static let paste = "main-menu-paste"
        static let selectAll = "main-menu-select-all"
    }

    /// Puts the menu bar in place. Called once, from `main.swift`, before the app runs.
    static func install(into app: NSApplication = .shared) {
        app.mainMenu = make()
    }

    /// The menu bar. Internal rather than private so its shape can be asserted without an app running, which is the
    /// same arrangement `MenuBarController.makeMenu` uses and for the same reason.
    static func make() -> NSMenu {
        let menu = NSMenu()

        // **The first submenu is always drawn as the application menu**, whatever it is titled, and AppKit puts the
        // bundle's name on it rather than the title given here. So an Edit menu on its own would not appear as "Edit":
        // it would appear as "Facet", with Cut and Paste inside it. This item is here to take that place.
        //
        // It is not empty, because an app menu that opens onto nothing reads as a menu that failed to build. Quit is
        // what goes in it: it is the one thing an app menu is expected to carry, and this app already has exactly one
        // way out for it to be a second door onto.
        menu.addItem(submenu(titled: "Facet", identifier: Identifier.app, items: [
            // **No ⌘Q**, which is the archive's choice and this app's standing rule -- the dropdown's Quit carries no
            // shortcut either (`MenuBarController.makeMenu`). The archive had measured the cost: this menu is only
            // reachable while Settings is open, and a stray ⌘Q aimed at a field had quit the app out from under
            // somebody. A menu item that has to be chosen deliberately cannot be hit by accident.
            //
            // `nil` target, so it travels the responder chain to `NSApp` and through `QuitSequence` -- the same route
            // the dropdown's Quit takes, so the cube is still paused, locked and let go of on the way out.
            item("Quit Facet", Identifier.quit, #selector(NSApplication.terminate(_:))),
        ]))

        // Every one of these has a `nil` target on purpose: the action goes down the responder chain and lands on
        // whichever field is being edited. Naming a target would tie the menu to one field, and there is no one field.
        menu.addItem(submenu(titled: "Edit", identifier: Identifier.edit, items: [
            item("Cut", Identifier.cut, #selector(NSText.cut(_:)), "x"),
            item("Copy", Identifier.copy, #selector(NSText.copy(_:)), "c"),
            item("Paste", Identifier.paste, #selector(NSText.paste(_:)), "v"),
            item("Select All", Identifier.selectAll, #selector(NSText.selectAll(_:)), "a"),
        ]))

        // **`autoenablesItems` is left on here, where `MenuBarController` turns it off**, and the difference is which
        // question decides an item. The dropdown's items are enabled from the app's own state, so AppKit deciding
        // from "can the action be found" would overwrite what `refresh` set. These four are the opposite case: what
        // should grey out Paste is an empty pasteboard, and what should grey out Cut is nothing being selected, both
        // of which the responder chain already answers correctly and neither of which this app knows.
        return menu
    }

    /// A menu with a title, wrapped in the item that carries it. Both halves are titled, because the bar reads the
    /// item's title and a menu's own title is what a screen reader announces.
    private static func submenu(titled title: String, identifier: String, items: [NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        for item in items { submenu.addItem(item) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.identifier = NSUserInterfaceItemIdentifier(identifier)
        holder.submenu = submenu
        return holder
    }

    private static func item(
        _ title: String, _ identifier: String, _ action: Selector, _ keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }
}

import AppKit

/// The status item and its dropdown. Owns the AppKit; decides nothing (see `StatusItemClickRouter`).
///
/// At this point in the rebuild the menu holds one item, Quit, and the item's title is the app's
/// name. Both grow as there is something to say and something to do.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    /// Accessibility identifiers, which are how a script addresses these rather than by position.
    ///
    /// Every element gets one, from the first element onwards. The archived suite shows what the
    /// alternative costs: steps that said `checkbox 1` and `static text 5` and so depended on sort
    /// order, and a step that read `group 3` where it wanted `group 1` and failed for a reason that
    /// took a run on the device to find. `AXIdentifier` is the attribute the runner already prefers
    /// (`first button whose value of attribute "AXIdentifier" is "scan-for-devices"`), so these
    /// follow the same kebab-case naming.
    enum Identifier {
        static let statusItem = "status-item"
        static let quit = "quit-app"
    }

    /// Creates the item and puts it in the menu bar.
    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "TimeFlip"
        // Carried from the archived controller's own setup: a status item draws unbordered, and
        // truncating rather than wrapping matters once the title is a live duration whose width
        // changes on every tick. `variableLength` is why the width moves at all -- which the test
        // harness knows about, re-reading the item's rect on every click rather than caching it
        // (`scripts/testrunner/locators.py`), after a synthetic click missed an item that had grown.
        item.button?.isBordered = false
        item.button?.cell?.truncatesLastVisibleLine = true
        item.button?.setAccessibilityIdentifier(Identifier.statusItem)
        // A label as well as an identifier: the identifier is for scripts, the label is what
        // VoiceOver reads, and a button whose only name is its title reads as its title -- which will
        // become a duration, and "0:07" is not a description of anything.
        item.button?.setAccessibilityLabel("TimeFlip")
        // Our own handler rather than `item.menu`, which would make AppKit present the menu for a
        // click anywhere on the item and take the left/right distinction away entirely. `showMenu`
        // below is how the menu still gets presented in AppKit's own way when we do want it.
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        statusItem = item
        statusMenu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // No key equivalent: ⌘Q belongs to the app-wide menu an accessory app does not have, and
        // putting it here would claim the shortcut only while the dropdown was already open.
        let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "")
        quit.target = self
        // Both, deliberately. `identifier` is AppKit's own and is what a menu item exposes as
        // AXIdentifier; `setAccessibilityIdentifier` is the accessibility one. Which of the two
        // actually surfaces is a question for the accessibility tree rather than the documentation --
        // the archived code carries a note that `.accessibilityDescription` never appeared at all --
        // so both are set and the tree is what settles it.
        quit.identifier = NSUserInterfaceItemIdentifier(Identifier.quit)
        quit.setAccessibilityIdentifier(Identifier.quit)
        menu.addItem(quit)
        return menu
    }

    @objc
    private func handleClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        // No event to read a side from -- a synthetic `performClick`, say. The menu is the safe
        // answer, being the one thing reachable in every state, and the only way out of the app.
        guard let event = NSApp.currentEvent else {
            showMenu()
            return
        }
        let location = button.convert(event.locationInWindow, from: nil)
        // `<=` so the exact midpoint counts as the left half, i.e. as the menu: of the two, it is the
        // one that cannot leave someone stuck.
        let isLeftSide = location.x <= button.bounds.width / 2

        let action = StatusItemClickRouter.action(isLeftSide: isLeftSide)
        // Not decoration. The test harness confirms a *synthetic* click actually landed by finding this
        // line, which is how a click that never reached the app was caught: six posted, five logged
        // (`build_device_history` in `scripts/testrunner/actions.py`). Same wording as the archived
        // controller's, so the harness's existing matcher still finds it.
        //
        // TODO: the harness reads `debug_log` **rows**, not console text, so this only becomes usable
        // to it again when `DeveloperMode.logSink` and the table's writer are back.
        DeveloperMode.debugPrint(
            .click,
            "Status item clicked: side=\(isLeftSide ? "left" : "right") clickCount=\(event.clickCount) -> \(action)"
        )

        switch action {
        case .showMenu:
            showMenu()
        case .ignore:
            break
        }
    }

    /// Presents the dropdown by lending the item its menu for exactly one click.
    ///
    /// The assign/click/detach dance is what keeps the halves apart. Left assigned, `statusItem.menu`
    /// makes AppKit open the menu for any click on the item, and `handleClick` above never runs
    /// again -- so it is detached immediately, and the next click comes back to us.
    private func showMenu() {
        guard let button = statusItem?.button, let menu = statusMenu else { return }
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc
    private func menuQuit() {
        DeveloperMode.debugPrint(.menu, "Menu clicked: Quit")
        NSApp.terminate(nil)
    }
}

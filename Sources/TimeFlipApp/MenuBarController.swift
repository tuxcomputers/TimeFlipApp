import AppKit

/// The status item and its dropdown. Owns the AppKit; decides nothing (see `StatusItemClickRouter`).
///
/// At this point in the rebuild the menu holds Settings, Pause and Quit, and the title is the database
/// badge followed by the app's name. Both grow as there is something to say and something to do.
/// Carries one value across a queue hop that the compiler cannot check for us.
private struct UncheckedSend<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
final class MenuBarController: NSObject {
    /// Holds the status item so it can be taken out of the menu bar when this controller goes away.
    ///
    /// Its own object because a `@MainActor` class's `deinit` cannot touch the class's own non-Sendable
    /// properties -- and the removal has to happen there. `NSStatusBar` retains what it is given, so without
    /// this a controller nobody kept would leave its item in the menu bar: still drawn, and dead, because the
    /// button's target is weak. A visible failure beats an invisible one, so the item leaves with its owner.
    private final class StatusItemHolder {
        var item: NSStatusItem?

        deinit {
            guard let item else { return }
            // Removed on the main actor, where AppKit wants it, with the item carried across as an unchecked
            // send: an `NSStatusItem` is not `Sendable`, and this is the one moment it has to cross -- nothing
            // else holds it by now, since this object dying is what brought us here.
            let carried = UncheckedSend(item)
            DispatchQueue.main.async {
                NSStatusBar.system.removeStatusItem(carried.value)
            }
        }
    }

    private let holder = StatusItemHolder()
    private var statusItem: NSStatusItem? {
        get { holder.item }
        set { holder.item = newValue }
    }

    private var statusMenu: NSMenu?

    /// The database tag drawn ahead of everything else, or `nil` for no tag at all. Fixed for the
    /// life of the launch, so it is stored rather than looked up per redraw.
    private let databaseBadge: DatabaseBadge?

    /// The app's own name, as the title's last element and the base of its accessibility label.
    private static let appLabel = "TimeFlip"

    /// Accessibility identifiers, which are how a script addresses these rather than by position.
    ///
    /// Every element gets one, from the first element onwards. Addressing by position is the
    /// alternative, and it means `checkbox 1` and `static text 5` -- which depend on the order the
    /// tree happens to come back in, and fail by finding the wrong element rather than by finding
    /// nothing. `AXIdentifier` is the attribute a UI script can match on directly, so these follow
    /// its kebab-case convention.
    enum Identifier {
        static let statusItem = "status-item"
        static let settings = "open-settings"
        static let togglePause = "toggle-pause"
        static let quit = "quit-app"
    }

    /// What to do when Settings is chosen. A closure rather than a window this class owns: it draws
    /// the menu, it does not decide what the app's windows are.
    private let openSettings: () -> Void

    /// What is being timed right now, asked as the menu opens rather than pushed here when it changes. The
    /// menu cannot be stale if it never remembers anything, which is the same reasoning the database rule
    /// rests on -- and it saves every state change having to know the menu exists.
    private let timingState: () -> TimingState

    /// Stops the clock, or starts it again. **The same closure the on-screen control ends in**, not a second
    /// implementation of pausing.
    private let togglePause: () -> Void

    /// `nil` in a build without the dev flag, which is the whole of how logging is switched off here.
    private let debugLog: DebugLog?

    init(
        databaseBadge: DatabaseBadge?,
        debugLog: DebugLog?,
        openSettings: @escaping () -> Void,
        timingState: @escaping () -> TimingState = { .idle },
        togglePause: @escaping () -> Void = {}
    ) {
        self.databaseBadge = databaseBadge
        self.debugLog = debugLog
        self.openSettings = openSettings
        self.timingState = timingState
        self.togglePause = togglePause
        super.init()
    }

    /// Creates the item and puts it in the menu bar.
    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.attributedTitle = makeTitle()
        // A status item draws unbordered, and truncating rather than wrapping matters once the title
        // is a live duration whose width changes on every tick. `variableLength` is what lets the
        // width move at all, which anything driving this by synthetic click has to account for: the
        // item's rect has to be re-read per click rather than cached.
        item.button?.isBordered = false
        item.button?.cell?.truncatesLastVisibleLine = true
        item.button?.setAccessibilityIdentifier(Identifier.statusItem)
        // A label as well as an identifier: the identifier is for scripts, the label is what
        // VoiceOver reads, and a button whose only name is its title reads as its title -- which will
        // become a duration, and "0:07" is not a description of anything. The badge goes in here too,
        // since its colour says nothing to a screen reader.
        item.button?.setAccessibilityLabel(accessibilityLabel())
        // Our own handler rather than `item.menu`, which would make AppKit present the menu for a
        // click anywhere on the item and take the left/right distinction away entirely. `showMenu`
        // below is how the menu still gets presented in AppKit's own way when we do want it.
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        statusItem = item
        statusMenu = makeMenu()
    }

    /// The status item's title: the database badge, then the app's name.
    ///
    /// Attributed rather than a plain string because the badge carries its own colour and weight --
    /// it is a tag, not part of the sentence. Sized off `.small` rather than the menu bar's own font
    /// because of where the title is going: an icon, a category name, a pause glyph and a running
    /// duration all end up on this one line, and it has to fit beside everything else up there.
    private func makeTitle() -> NSAttributedString {
        let size = NSFont.systemFontSize(for: .small)
        let title = NSMutableAttributedString()
        if let databaseBadge {
            title.append(NSAttributedString(
                string: "\(databaseBadge.text) ",
                attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: databaseBadge.color]
            ))
        }
        title.append(NSAttributedString(
            string: Self.appLabel,
            attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
        ))
        return title
    }

    private func accessibilityLabel() -> String {
        guard let databaseBadge else { return Self.appLabel }
        return "\(Self.appLabel), \(databaseBadge.spokenDescription)"
    }

    /// The dropdown. Internal so its shape can be asserted without putting a real status item in the menu
    /// bar, which is what `start()` does.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Trailing ellipsis, the platform's way of saying a choice opens something rather than doing
        // something. No ⌘, for the same reason Quit carries no ⌘Q, below.
        menu.addItem(item(title: "Settings…", identifier: Identifier.settings, action: #selector(menuSettings)))
        // Under Settings, because it acts on what Settings is showing. Its title and whether it can be
        // chosen at all are set when the menu opens, not here.
        menu.addItem(item(title: "Pause", identifier: Identifier.togglePause, action: #selector(menuTogglePause)))
        // Quit sits under a separator, away from anything ordinary: it is the only way out of the app,
        // so it should not be adjacent to a choice somebody makes routinely.
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit", identifier: Identifier.quit, action: #selector(menuQuit)))
        // Off, because AppKit would otherwise decide each item's enabled state from whether its action can be
        // found -- which is always -- and overwrite what `refresh` sets.
        menu.autoenablesItems = false
        return menu
    }

    /// Names the Pause item and decides whether it can be chosen, from the state at that moment. Nothing has
    /// to tell the menu when the clock changes, because the menu never remembers.
    ///
    /// Called from `showMenu`, which is the only place a menu of ours is ever presented, rather than through
    /// `NSMenuDelegate`. A delegate is a **weak** reference, so wiring it makes the menu depend on somebody
    /// else keeping this object alive -- and when that fails the menu simply stops updating, with nothing to
    /// see. We are already the code that opens it, so there is no reason to be told.
    func refresh(_ menu: NSMenu) {
        guard let pause = menu.items.first(where: { $0.identifier?.rawValue == Identifier.togglePause }) else {
            return
        }
        let state = timingState()
        pause.title = ManualTimerRules.pauseMenuTitle(for: state)
        pause.isEnabled = ManualTimerRules.isClickable(state)
    }

    /// One menu item, targeted at this controller and named for a script.
    ///
    /// No key equivalent on any of these: a shortcut belongs to the app-wide menu an accessory app
    /// does not have, and one declared here would only work while the dropdown was already open --
    /// which is not a shortcut.
    ///
    /// Both identifiers are set, deliberately. `identifier` is AppKit's own and is what a menu item
    /// exposes as AXIdentifier; `setAccessibilityIdentifier` is the accessibility one. Which of the
    /// two actually surfaces is a question for the accessibility tree rather than the documentation,
    /// so both are set and the tree is what settles it.
    private func item(title: String, identifier: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        item.setAccessibilityIdentifier(identifier)
        return item
    }

    @objc
    private func handleClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        // No event to read a side from -- a synthetic `performClick`, say. The menu is the safe
        // answer, being the one thing reachable in every state, and the only way out of the app.
        guard let event = NSApp.currentEvent else {
            debugLog?.record(.click, "Status item clicked: no event, side unknown -> showMenu")
            showMenu()
            return
        }
        let location = button.convert(event.locationInWindow, from: nil)
        // `<=` so the exact midpoint counts as the left half, i.e. as the menu: of the two, it is the
        // one that cannot leave someone stuck.
        let isLeftSide = location.x <= button.bounds.width / 2
        let action = StatusItemClickRouter.action(isLeftSide: isLeftSide)

        // Recorded whatever the outcome, including `ignore`. A click that deliberately did nothing and
        // a click that never arrived look identical afterwards unless one of them left a row -- and
        // telling those two apart is the difference between a routing bug and a missed hit.
        debugLog?.record(
            .click,
            "Status item clicked: side=\(isLeftSide ? "left" : "right") clicks=\(event.clickCount) -> \(action)"
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
        refresh(menu)
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc
    private func menuSettings() {
        debugLog?.record(.menu, "Menu item clicked: Settings")
        openSettings()
    }

    @objc
    private func menuTogglePause() {
        // What it was called when it was chosen, which is what the person clicking it meant.
        debugLog?.record(.menu, "Menu item clicked: \(ManualTimerRules.pauseMenuTitle(for: timingState()))")
        togglePause()
    }

    @objc
    private func menuQuit() {
        // Before terminating, not after: there is no after.
        debugLog?.record(.menu, "Menu item clicked: Quit")
        NSApp.terminate(nil)
    }
}

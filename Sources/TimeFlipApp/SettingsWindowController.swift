import AppKit

/// The Settings window: one tab per `SettingsTab`, each pane empty.
///
/// Owns the window and nothing else. Which tabs exist is `SettingsTab`'s business, and what goes in
/// them is each pane's, once there is anything to put there.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Accessibility identifiers for the parts a script needs to address. The tabs themselves are
    /// addressed by their titles, which `SettingsTab` already owns.
    enum Identifier {
        static let window = "settings-window"
        static let tabs = "settings-tabs"
    }

    private enum Layout {
        // Provisional, and deliberately generous rather than fitted to five empty panes: the window
        // is sized for the content it is about to hold so the numbers do not have to be re-tuned as
        // each pane arrives. The tab that ends up needing the most room is what should set these,
        // measured, once it exists.
        static let defaultWidth: CGFloat = 640
        static let defaultHeight: CGFloat = 680
        static let minimumWidth: CGFloat = 560
        static let minimumHeight: CGFloat = 400
    }

    /// Built on first open, not at launch: a window nobody opens should not exist. Reused after that
    /// -- closing orders it out rather than destroying it, so it reopens on the tab it was left on and
    /// where it was left on screen.
    private lazy var window: NSWindow = makeWindow()

    func show() {
        // An accessory app has no application menu, and the standard editing shortcuts (⌘X/⌘C/⌘V,
        // ⌘W) live in it -- so a text field in this window would have no way to be pasted into.
        // `.regular` borrows a real one for as long as the window is open, at the cost of a Dock icon
        // appearing while it is. The alternative is to build a hidden main menu and stay `.accessory`
        // throughout; worth revisiting when the first editable field lands here, which is the point
        // at which the difference is testable rather than theoretical.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app, so the Dock icon goes away with the window that needed it.
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.defaultWidth, height: Layout.defaultHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TimeFlip Settings"
        window.identifier = NSUserInterfaceItemIdentifier(Identifier.window)
        window.contentMinSize = NSSize(width: Layout.minimumWidth, height: Layout.minimumHeight)
        // Survives its own close, which is what makes the window reusable: without this, closing it
        // deallocates it and `window` above would be rebuilt on the next open, losing the selected
        // tab and the position on screen.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeTabView()
        window.center()
        return window
    }

    /// The tab bar and the five panes behind it.
    ///
    /// The tab buttons themselves are addressed **by their titles**, not by an identifier. Measured in
    /// the accessibility tree: they arrive as `AXRadioButton`s carrying `AXTitle`, and
    /// `NSTabViewItem.identifier` does not reach `AXIdentifier` at all -- AppKit builds those buttons
    /// itself and the item's identifier stays on the AppKit side of the fence. Each tab's *pane* does
    /// carry an identifier, which is what a script confirms the switch actually landed with.
    private func makeTabView() -> NSTabView {
        let tabView = NSTabView()
        tabView.setAccessibilityIdentifier(Identifier.tabs)
        for tab in SettingsTab.allCases {
            // Set even though it does not surface: it is how `tabViewItem(withIdentifier:)` finds a
            // tab from code, which is a different question from how a script finds one.
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = makePane(for: tab)
            tabView.addTabViewItem(item)
        }
        return tabView
    }

    /// An empty pane, named so a script can confirm which tab it is looking at.
    ///
    /// All three calls are load-bearing, and the first is the one that is easy to miss: an ordinary
    /// `NSView` is not an accessibility element, so without `setAccessibilityElement(true)` the role
    /// and identifier below are simply never asked for and the pane is absent from the tree (measured:
    /// it came back as an untitled `AXGroup` with no identifier). `.group` is what an empty container
    /// should be anyway -- it is about to hold this tab's controls.
    private func makePane(for tab: SettingsTab) -> NSView {
        let pane = NSView()
        pane.setAccessibilityElement(true)
        pane.setAccessibilityRole(.group)
        pane.setAccessibilityIdentifier(tab.paneIdentifier)
        pane.setAccessibilityLabel(tab.title)
        return pane
    }
}

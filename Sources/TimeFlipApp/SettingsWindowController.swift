import AppKit

/// The Settings window: one tab per `SettingsTab`, each pane empty.
///
/// Owns the window and nothing else. Which tabs exist is `SettingsTab`'s business, and what goes in
/// them is each pane's, once there is anything to put there.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTabViewDelegate {
    /// Accessibility identifiers for the parts a script needs to address. The tabs themselves are
    /// addressed by their titles, which `SettingsTab` already owns.
    enum Identifier {
        static let window = "settings-window"
        static let tabs = "settings-tabs"
        static let panes = "settings-panes"
        static let close = "close-settings"
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
        /// Around the Close button, and between it and the panes above.
        static let buttonPadding: CGFloat = 12
        static let buttonSpacing: CGFloat = 6
        /// The air around the tab bar: above it to the title bar, and below it to the top of the box.
        /// One constant used on both sides, because equal gaps are the point -- the bar should read as
        /// sitting in a band of its own rather than resting on the content.
        static let tabBarMargin: CGFloat = 5
        /// The box's inset from the window's left and right edges.
        static let panesSideInset: CGFloat = 4
    }

    /// Built on first open, not at launch: a window nobody opens should not exist. Reused after that
    /// -- closing orders it out rather than destroying it, so it reopens on the tab it was left on and
    /// where it was left on screen.
    private lazy var window: NSWindow = makeWindow()

    /// `nil` in a build without the dev flag.
    private let debugLog: DebugLog?

    /// Where the Faces tab's list comes from. `nil` leaves it empty, which is what a test that only cares
    /// about layout wants.
    private let categories: CategoryReader?

    init(debugLog: DebugLog?, categories: CategoryReader?) {
        self.debugLog = debugLog
        self.categories = categories
        super.init()
    }

    /// Reads what the visible pane shows, now.
    ///
    /// Called when the window opens and again on every switch between tabs, which is the database rule
    /// applied literally (see `CLAUDE.md`): the values a window shows are read when it is about to show
    /// them, so closing and reopening it, or leaving a tab and coming back, reads the table again rather
    /// than redrawing what was true the first time.
    private func reloadSelectedPane() {
        guard let categories, let pane = panes.selectedTabViewItem?.view as? FacesPane else { return }
        pane.show(categories.activeCategories())
    }

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
        reloadSelectedPane()
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
        window.contentView = makeContentView()
        window.center()
        return window
    }

    /// The tab bar, the box of panes under it, and the Close button on its own row at the bottom.
    ///
    /// **Why the tab bar is a segmented control of our own** rather than the one `NSTabView` draws: with
    /// its tabs on top, `NSTabView` centres the bar on the top edge of its box, so the box begins
    /// half-way up the buttons and the shading starts mid-tab. `tabViewBorderType` cannot fix that while
    /// the tabs are on top -- it only applies when the tab position is `.none`, measured by setting it and
    /// watching nothing move. So the tab position *is* `.none` here: the tab view keeps only the panes and
    /// the switching between them, and the bar above is ours to place.
    ///
    /// With the box gone as well, a pane sits on the window's white, which is what the previous app looked
    /// like. The bar has the same gap under it as over it, so it reads as a band of its own.
    private func makeContentView() -> NSView {
        let content = NSView()
        let close = makeCloseButton()
        content.addSubview(tabBar)
        content.addSubview(panes)
        content.addSubview(close)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor, constant: Layout.tabBarMargin),
            tabBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            panes.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: Layout.tabBarMargin),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Layout.panesSideInset),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.panesSideInset),
            panes.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -Layout.buttonSpacing),

            // Bottom right, where a window's dismissal belongs on this platform.
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Layout.buttonPadding),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Layout.buttonPadding),
        ])
        return content
    }

    private func makeCloseButton() -> NSButton {
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.translatesAutoresizingMaskIntoConstraints = false
        close.identifier = NSUserInterfaceItemIdentifier(Identifier.close)
        close.setAccessibilityIdentifier(Identifier.close)
        // Escape closes the window, which is what a Close button is expected to answer to, and matters
        // more than usual here: an accessory app has no application menu, so ⌘W does not exist.
        //
        // It will need giving up once this window has text fields in it. A key equivalent is dispatched
        // before the focused field sees the key, so Escape would close the window out from under
        // somebody cancelling an edit, and the field cannot win that on its own.
        close.keyEquivalent = "\u{1b}"
        return close
    }

    /// The tab bar: one segment per tab, addressed **by its label, which arrives as `AXDescription`**.
    ///
    /// A label is the only name a tab button can have, whichever control draws it: a segmented control
    /// has no per-segment identifier, and `NSTabView`'s own bar has none either (`NSTabViewItem.identifier`
    /// does not reach `AXIdentifier`, and the item has no `setAccessibilityIdentifier` at all). The
    /// control itself is named, and each tab's *pane* carries the identifier that confirms a switch landed.
    ///
    /// So a script matches on `description`: `radio button "Report"` finds nothing, while `first radio
    /// button whose description is "Report"` finds it (measured, both ways round). That is the same
    /// contract the previous app exposed and the one `Tests/Methods.md` Method 10 is already written
    /// against -- `NSTabView`'s own bar, with its `AXTitle`s, was the odd one out. The path is one level
    /// shorter here: the segments are `radio group 1 of window`, where they used to be inside
    /// `group 1 of toolbar 1`, so that method needs its path updated when the checklists come back.
    lazy var tabBar: NSSegmentedControl = {
        let bar = NSSegmentedControl(
            labels: SettingsTab.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabBarChanged)
        )
        bar.selectedSegment = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setAccessibilityIdentifier(Identifier.tabs)
        // No focus ring. It draws around the selected segment once the bar has keyboard focus, and on
        // the first and last segments it is visible on the inward side only -- the outward side is
        // clipped by the bar's own edge -- so it reads as a gap opening beside the pill rather than a
        // ring around it. Measured both ways: with the window active the halo is there, and it
        // disappears entirely when another app takes focus.
        //
        // What this gives up is the indication that the tab bar is the focused control, which is nothing
        // while it is the only control up there. Worth re-examining when this window has fields to tab
        // between, at which point the ring is what says where the keyboard is pointing.
        bar.focusRingType = .none
        return bar
    }()

    /// The five panes, and the box drawn around them. No tab bar of its own -- see `makeContentView`.
    lazy var panes: NSTabView = {
        let panes = NSTabView()
        panes.translatesAutoresizingMaskIntoConstraints = false
        panes.setAccessibilityIdentifier(Identifier.panes)
        panes.tabPosition = .none
        // No box and no border, so a pane sits on the window's own white. Measured against the previous
        // app (`image/preferences-device.png`, `image/preferences-faces.png`): its content area was pure
        // white, and the only grey in the window was the section panels *inside* a pane. A bezel here
        // tinted the whole pane instead, which is the tinge that made the tab bar look like it was
        // resting on a shelf.
        panes.tabViewBorderType = .none
        for tab in SettingsTab.allCases {
            // Does not surface to accessibility, but it is how `tabViewItem(withIdentifier:)` finds a
            // tab from code, which is a different question from how a script finds one.
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = makePane(for: tab)
            panes.addTabViewItem(item)
        }
        // Set after the items are added, so the first tab landing selected as a side effect of being
        // added is not logged as somebody choosing it.
        panes.delegate = self
        return panes
    }()

    @objc
    private func tabBarChanged() {
        guard tabBar.selectedSegment >= 0 else { return }
        // The switch itself is logged by the tab view's delegate, which fires for this and for a tab
        // chosen in code alike.
        panes.selectTabViewItem(at: tabBar.selectedSegment)
    }

    /// Records the tab that is now showing.
    ///
    /// "Selected", not "clicked": this fires for a tab chosen in code as well as one clicked, and the
    /// app will eventually choose one itself (a window that opens straight to the tab you need). A
    /// message that said "clicked" would then be a lie in exactly the case worth investigating.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let label = tabViewItem?.label else { return }
        debugLog?.record(.tab, "Settings tab selected: \(label)")
        reloadSelectedPane()
    }

    @objc
    private func closeWindow() {
        debugLog?.record(.click, "Button clicked: Close (Settings window)")
        window.performClose(nil)
    }

    /// An empty pane, named so a script can confirm which tab it is looking at.
    ///
    /// All three calls are load-bearing, and the first is the one that is easy to miss: an ordinary
    /// `NSView` is not an accessibility element, so without `setAccessibilityElement(true)` the role
    /// and identifier below are simply never asked for and the pane is absent from the tree (measured:
    /// it came back as an untitled `AXGroup` with no identifier). `.group` is what an empty container
    /// should be anyway -- it is about to hold this tab's controls.
    private func makePane(for tab: SettingsTab) -> NSView {
        let pane: NSView = tab == .faces ? FacesPane() : NSView()
        // The tab view hands each pane the content rect and resizes it from there, so the pane keeps
        // its autoresizing frame rather than being pinned by constraints from out here.
        pane.autoresizingMask = [.width, .height]
        pane.setAccessibilityElement(true)
        pane.setAccessibilityRole(.group)
        pane.setAccessibilityIdentifier(tab.paneIdentifier)
        pane.setAccessibilityLabel(tab.title)
        return pane
    }
}

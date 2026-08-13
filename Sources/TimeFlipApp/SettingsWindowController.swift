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

    /// Where the Faces tab's list comes from, and what a new category is written through. `nil` leaves the
    /// list empty, which is what a test that only cares about layout wants.
    private let categories: CategoryStore?

    /// Held so the create flow can reach the pane it belongs to without going through the selected tab.
    private var facesPane: FacesPane?

    /// Held so Escape can be lent to a name field while one is open.
    private var closeButton: NSButton?

    /// Which category each face holds, including the manual face. `nil` in a test that only cares about
    /// layout.
    private let faces: FaceStore?

    /// The one thing that knows whether time is being recorded, and for what.
    private let session: TimingSession?

    /// Where a segment goes. `nil` in a test that only cares about layout, and in that case a click times
    /// without recording anything -- which is the difference between the window's own behaviour and what it
    /// leaves behind, and worth being able to test apart.
    private let deviceEvents: DeviceEventRecorder?

    /// How much time the category being timed has today. `nil` draws zero, which is what a layout test wants.
    private let dayTotal: DayTotal?

    /// Redraws the elapsed time while the window is open. Only while it is open: a clock nobody can see does
    /// not need repainting, and the session's elapsed time is worked out from when it started rather than
    /// counted up, so nothing is lost by not ticking.
    private var tick: Timer?

    init(
        debugLog: DebugLog?,
        categories: CategoryStore?,
        faces: FaceStore?,
        session: TimingSession?,
        deviceEvents: DeviceEventRecorder? = nil,
        dayTotal: DayTotal? = nil
    ) {
        self.debugLog = debugLog
        self.categories = categories
        self.faces = faces
        self.session = session
        self.deviceEvents = deviceEvents
        self.dayTotal = dayTotal
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
        redrawTiming()
    }

    /// Draws the session: which category, whether it is running, and how much time that category has.
    ///
    /// The category comes from the `face` table every time rather than being remembered from the click that
    /// started it -- so a category renamed or recoloured elsewhere shows correctly here, and there is only ever
    /// one answer to what is being timed. **Which** face is read is itself a question, since manual mode
    /// rotates: the one the current segment is on, which is the one the last segment it recorded used.
    ///
    /// **The figure is the category's total for the day, not this session's stopwatch.** That is what the
    /// previous app drew, and it is the difference between a number that means something and one that resets
    /// whenever the app is relaunched: pick a category up again after lunch and its morning is still there. It
    /// comes from `DayTotal`, which reads it rather than counting it.
    private func redrawTiming() {
        guard let pane = panes.selectedTabViewItem?.view as? FacesPane else { return }
        guard let session, let faces, let categories else {
            pane.timingView.show(category: nil, state: .idle, elapsed: 0)
            return
        }
        let assigned = faces.categoryID(forFace: currentManualFace()).flatMap { categories.category(id: $0) }
        pane.timingView.show(
            category: assigned,
            state: ManualTimerRules.state(categoryID: assigned == nil ? nil : session.categoryID, isRunning: session.isRunning),
            elapsed: assigned.map { dayTotal?.seconds(categoryID: $0.id) ?? 0 } ?? 0
        )
    }

    /// The manual face in use right now: the one the last manual segment was recorded on, or the first of them
    /// when nothing has been timed yet.
    ///
    /// Asked rather than held, so nothing has to stay in step with the rotation -- and a relaunch mid-session
    /// finds the same answer the launch before it had.
    private func currentManualFace() -> Int {
        deviceEvents?.latestFace(in: ManualFace.all) ?? ManualFace.first
    }

    /// A category was clicked: the segment that was running ends, the **next** manual face takes the new
    /// category, and a new segment starts on it.
    ///
    /// One moment is read for the whole gesture, so the segment that ends and the one that begins meet exactly
    /// rather than overlapping or leaving a gap nobody timed.
    ///
    /// **The new category goes on a different face from the one the finished segment named**, which is what
    /// makes the outgoing segment's category safe no matter when anything reads it. Closing before writing the
    /// face is still the right order and still done, but it is no longer the only thing standing between a
    /// finished stretch and being filed under the category that replaced it -- see `ManualFace`.
    ///
    /// What each step means for the rows is `DeviceEventRecorder`'s, not this method's: it is handed a moment
    /// and decides the rest.
    private func startTiming(_ category: CategoryRecord) {
        guard let session, let faces else { return }
        // Already timing this one, so the click has nothing to ask for: the clock is where it should be, and
        // restarting it would put the figure back to zero and lose the seconds it held. Ahead of the face
        // write as well as the clock, since the face already holds this category too.
        //
        // Recorded even though nothing happened. A click that deliberately did nothing and a click that never
        // landed look identical afterwards unless one of them leaves a row, and telling those apart is the
        // difference between this working and the list having stopped responding.
        if session.isTiming(category.id) {
            debugLog?.record(.mode, "Timing: already timing \"\(category.name)\", so the click changes nothing")
            return
        }
        let moment = Date()
        // Read before anything is written, so the face the finished segment is on is not the face about to be
        // reassigned.
        let face = ManualFace.next(after: deviceEvents?.latestFace(in: ManualFace.all))
        deviceEvents?.closeOpenSegment(at: moment)
        // A refused write here leaves the outgoing segment closed with no new one open, and the clock still
        // claiming to run. That is worth naming rather than guarding: the close is right on its own terms (the
        // stretch did end when the click arrived), and the only way to reach this is the database refusing an
        // update -- the app's own faces are never locked, being reassigned is the whole point of them.
        guard faces.assign(categoryID: category.id, toFace: face) else {
            debugLog?.record(.mode, "Timing: face \(face) refused category \"\(category.name)\"")
            return
        }
        deviceEvents?.startSegment(face: face, at: moment)
        session.start(categoryID: category.id)
        debugLog?.record(.mode, "Timing: started \"\(category.name)\" (category_id \(category.id)) on face \(face)")
        redrawTiming()
        startTicking()
    }

    /// Stop the clock, or start it again.
    ///
    /// **One path for both ways in**: the control in the Timing column and the dropdown's Pause item both end
    /// here, so they cannot come to disagree about what pausing means. The previous app had them as two
    /// implementations and they did exactly that.
    ///
    /// It lives here because this is the only thing that draws a session. When the menu bar shows one too,
    /// this becomes a small coordinator both views observe rather than one view the other calls.
    ///
    /// **Pausing ends the segment; resuming begins another.** A segment's duration is the wall time from its
    /// start, so a pause left sitting inside one would be counted as time spent -- and it was, until this: the
    /// clock read 14 seconds against a row claiming 20. Ending it at the pause is also what hands the stretch
    /// to the time entry module, which is the moment it can be asked whether it counts.
    func togglePause() {
        // Nothing picked means no clock and no row, so there is nothing here to stop or start. `TimingSession`
        // refuses the toggle for the same reason; this keeps the writes from happening around a toggle that
        // will not.
        guard let session, session.categoryID != nil else { return }
        let moment = Date()
        // Read before the toggle, since it is what decides which of the two this is, and one moment for both
        // halves so the segment that ends and the one that begins meet exactly.
        if session.isRunning {
            deviceEvents?.closeOpenSegment(at: moment)
        } else {
            // The same face the paused stretch was on, not the next one, and nothing is written to it. Rotating
            // exists to stop a face's category changing under a finished segment, and resuming does not change
            // it: this is the same category continuing. Reusing the face is therefore safe, and it keeps a
            // pause-heavy session from cycling the pool for no reason.
            deviceEvents?.startSegment(face: currentManualFace(), at: moment)
        }
        session.togglePause()
        debugLog?.record(
            .mode,
            "Timing: \(session.isRunning ? "running" : "stopped") after \(Int(session.elapsed))s"
        )
        redrawTiming()
        if session.isRunning {
            startTicking()
        } else {
            // Nothing left to repaint once it is stopped: the elapsed figure cannot change again until it
            // is started, and the redraw above has already shown its final value.
            stopTicking()
        }
    }

    private func startTicking() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, session.isRunning else { return }
                self.redrawTiming()
            }
        }
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
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
        if session?.isRunning == true {
            startTicking()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app, so the Dock icon goes away with the window that needed it.
        NSApp.setActivationPolicy(.accessory)
        // The clock keeps running; only the repainting stops. Elapsed time is worked out from when the
        // session started, so a closed window costs nothing and misses nothing.
        stopTicking()
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
        closeButton = close
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
    /// contract the previous app exposed and the one `Archive/Tests/Methods.md` Method 10 is already written
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

    private func makeFacesPane() -> FacesPane {
        let faces = FacesPane()
        faces.categoryList.onSelect = { [weak self] category in
            self?.startTiming(category)
        }
        faces.timingView.onTogglePause = { [weak self] in
            self?.togglePause()
        }
        faces.createControl.onSave = { [weak self] typed in
            self?.saveNewCategory(typed)
        }
        faces.createControl.onEditingChanged = { [weak self] isEditing in
            // Escape belongs to whichever of the two needs it more. While a name is being typed that is
            // the field, since a key equivalent is dispatched before the focused field ever sees the key
            // -- so without this, Escape would close the window instead of abandoning the name, and the
            // field could not win that on its own.
            self?.closeButton?.keyEquivalent = isEditing ? "" : "\u{1b}"
        }
        facesPane = faces
        return faces
    }

    /// Acts on a typed category name.
    ///
    /// The decision is `CategoryCreateRules`', taken against the whole `category` table rather than the
    /// list on screen -- which shows only active categories, so a retired namesake is invisible to it and
    /// the one thing standing between a typo and two identical categories would be missing.
    private func saveNewCategory(_ typed: String) {
        guard let categories, let control = facesPane?.createControl else { return }
        switch CategoryCreateRules.decision(rawName: typed, matching: categories.matching(name:)) {
        case .ignore:
            control.collapse()

        case let .insert(name):
            let created = categories.insert(name: name)
            debugLog?.record(
                .click,
                "Button clicked: Save new category \"\(name)\" -> \(created.map { "category_id \($0)" } ?? "refused")"
            )
            control.collapse()
            // Re-read rather than adding the new row to the list by hand: the database is what the list
            // shows, and a row put there by the writer would be a second answer to what it holds.
            reloadSelectedPane()

        case let .reactivate(existing):
            let succeeded = categories.reactivate(id: existing.id)
            debugLog?.record(
                .click,
                "Button clicked: Save new category \"\(existing.name)\" -> reactivated category_id "
                    + "\(existing.id)\(succeeded ? "" : " REFUSED")"
            )
            control.collapse()
            reloadSelectedPane()

        case let .alreadyActive(existing):
            debugLog?.record(
                .click,
                "Button clicked: Save new category \"\(existing.name)\" -> already active as category_id \(existing.id)"
            )
            control.collapse()
            showAlreadyActive(existing)
        }
    }

    /// The dead end: an active category already holds the name, so there is nothing to decide and only
    /// something to say. Wording carried over from the previous app.
    private func showAlreadyActive(_ existing: CategoryRecord) {
        let alert = NSAlert()
        alert.messageText = "That category already exists"
        alert.informativeText = "\"\(existing.name)\" is already in the Active list. Scroll up -- it is right there."
        alert.addButton(withTitle: "Ok")
        alert.beginSheetModal(for: window)
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
        let pane: NSView = tab == .faces ? makeFacesPane() : NSView()
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

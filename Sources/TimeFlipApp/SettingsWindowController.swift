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

    /// Built on first open, not at launch: a window nobody opens should not exist. Reused after that --
    /// closing orders it out rather than destroying it, so it reopens where it was left on screen.
    ///
    /// The *tab* it was left on is deliberately not kept: every open selects `tabOnOpen`. See there.
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

    /// Where a segment goes. `nil` in a test that only cares about layout, and in that case a click times
    /// without recording anything -- which is the difference between the window's own behaviour and what it
    /// leaves behind, and worth being able to test apart.
    private let deviceEvents: DeviceEventRecorder?

    /// What is being timed, for drawing. `nil` draws an idle column, which is what a layout test wants.
    private let timing: TimingReadout?

    /// Called when this window changes what is being timed, so the status item can repaint at the same moment.
    ///
    /// A settable property rather than a constructor argument because the two need each other: the item's menu is
    /// what opens this window. Set from `main.swift` once both exist, which is also where the closure keeps this
    /// class from knowing the menu bar's type.
    var onTimingChanged: (@MainActor () -> Void)?

    /// Redraws the figure while the window is open. Only while it is open: a clock nobody can see does not need
    /// repainting, and the figure is worked out from what is recorded rather than counted up, so nothing is lost
    /// by not ticking.
    private var tick: Timer?

    init(
        debugLog: DebugLog?,
        categories: CategoryStore?,
        faces: FaceStore?,
        deviceEvents: DeviceEventRecorder? = nil,
        timing: TimingReadout? = nil
    ) {
        self.debugLog = debugLog
        self.categories = categories
        self.faces = faces
        self.deviceEvents = deviceEvents
        self.timing = timing
        super.init()
    }

    /// Reads what the visible pane shows, now.
    ///
    /// Called when the window opens and again on every switch between tabs, which is the database rule
    /// applied literally (see `CLAUDE.md`): the values a window shows are read when it is about to show
    /// them, so closing and reopening it, or leaving a tab and coming back, reads the table again rather
    /// than redrawing what was true the first time.
    private func reloadSelectedPane() {
        guard let categories else { return }
        // Only the pane on show is read. The others are read when they are switched to, which is the same rule
        // applied one level down: a tab nobody is looking at has no values worth having.
        switch panes.selectedTabViewItem?.view {
        case let pane as FacesPane:
            pane.show(categories.activeCategories())
            redrawTiming()

        case let pane as CategoriesPane:
            wire(pane)
            pane.show(categories.activeCategories())

        default:
            break
        }
    }

    /// Points the Categories tab's edits at the tables they write to.
    ///
    /// Set on every reload rather than once, because it costs nothing and because a pane wired in only one place is a
    /// pane that draws dead controls the day something else builds it.
    ///
    /// **A write is not followed by a re-read here, and the retire is the exception.** Settings reads the database
    /// when it opens and what it shows is then the answer until it closes, so a limit typed into a field is already on
    /// screen and re-reading would only rebuild the row -- taking the field out from under whoever is still typing in
    /// it. Retiring is different in kind: it changes *which* rows belong in the list, so the list is read again and
    /// the row leaves because the table no longer calls it active.
    private func wire(_ pane: CategoriesPane) {
        pane.activeTable.facesHolding = { [weak self] category in
            self?.faces?.facesHolding(categoryID: category.id) ?? []
        }
        pane.activeTable.onSetDailyLimit = { [weak self] category, minutes in
            self?.setDailyLimit(minutes, on: category)
        }
        pane.activeTable.onRetire = { [weak self] category in
            self?.retire(category)
        }
    }

    /// Stores a category's daily limit.
    ///
    /// A refused write is the one case that reads the row back. The field is showing what was typed, and if the table
    /// did not take it then the screen and the database now disagree -- which is the whole thing the first rule in
    /// `CLAUDE.md` exists to prevent. Losing the field's focus is the smaller cost of the two.
    private func setDailyLimit(_ minutes: Int, on category: CategoryRecord) {
        guard let categories else { return }
        let allowed = CategoryEditRules.dailyLimitMinutes(minutes)
        let stored = categories.setDailyLimit(id: category.id, minutes: allowed)
        debugLog?.record(
            .field,
            "Category \"\(category.name)\" daily limit -> \(allowed)min\(stored ? "" : " REFUSED")"
        )
        guard !stored else { return }
        reloadSelectedPane()
    }

    /// Retires a category and takes it off the faces holding it.
    ///
    /// **Both, or neither.** A retired category left on a face would still be what that face is timing while being
    /// absent from every list a category can be picked from, which is a state nothing else in the app is prepared to
    /// explain. The archive did the same, and the faces are cleared after the retire rather than before so a refused
    /// retire leaves the faces alone.
    ///
    /// Nothing here has to check for a locked face: `CategoryEditRules` decided that before the box was drawn, and a
    /// locked face's box is disabled, so this is not reachable for one.
    private func retire(_ category: CategoryRecord) {
        guard let categories else { return }
        guard categories.setActive(id: category.id, false) else {
            debugLog?.record(.click, "Category \"\(category.name)\" retire REFUSED")
            return
        }
        let cleared = (faces?.facesHolding(categoryID: category.id) ?? []).filter { faces?.clear(face: $0.face) == true }
        debugLog?.record(
            .click,
            "Category \"\(category.name)\" retired, cleared from face(s) \(cleared.map(\.face))"
        )
        // The list is read again because retiring changes which rows belong in it, not merely what one of them says.
        reloadSelectedPane()
        // The Faces tab and the status item draw from the same tables, and a face this cleared may be the one being
        // timed.
        onTimingChanged?()
    }

    /// Draws the session: which category, whether it is running, and how much time that category has.
    ///
    /// Every part of that is read at this moment, and read by `TimingReadout` rather than here -- because the
    /// status item asks the same question and the two must not answer it separately. See there for what each
    /// piece is read from and why the figure is the category's total for the day rather than this session's
    /// stopwatch.
    private func redrawTiming() {
        draw(timing?.read() ?? .idle)
    }

    /// Draws a reading already taken, which is what the tick wants: it has to look at the state anyway to decide
    /// whether to keep going, and reading twice for one repaint would be two answers where one will do.
    private func draw(_ reading: TimingReadout.Reading) {
        guard let pane = panes.selectedTabViewItem?.view as? FacesPane else { return }
        pane.timingView.show(category: reading.category, state: reading.state, elapsed: reading.seconds)
    }

    /// The manual face in use right now, which is `DeviceEventRecorder`'s answer to give: it owns the table the
    /// rotation is read out of.
    private func currentManualFace() -> Int {
        deviceEvents?.currentManualFace() ?? ManualFace.first
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
        guard let faces else { return }
        // Already timing this one, so the click has nothing to ask for: the clock is where it should be, and
        // restarting it would rotate the face and close a segment for a gesture that asked for no change. Ahead of
        // the face write as well as the segment, since the face already holds this category too.
        //
        // Recorded even though nothing happened. A click that deliberately did nothing and a click that never
        // landed look identical afterwards unless one of them leaves a row, and telling those apart is the
        // difference between this working and the list having stopped responding.
        if timing?.read().isTiming(category.id) == true {
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
        debugLog?.record(.mode, "Timing: started \"\(category.name)\" (category_id \(category.id)) on face \(face)")
        redrawTiming()
        onTimingChanged?()
        startTicking()
    }

    /// Stop the clock, or start it again.
    ///
    /// **One path for both ways in**: the control in the Timing column and the dropdown's Pause item both end
    /// here, so they cannot come to disagree about what pausing means. The previous app had them as two
    /// implementations and they did exactly that.
    ///
    /// It lives here because this was the only thing that drew a session. The status item draws one now too, and
    /// both reach this same method, so this is that coordinator: the decision is here, what it changed is read back
    /// out of the table by whoever draws.
    ///
    /// **Pausing ends the segment; resuming begins another.** A segment's duration is the wall time from its
    /// start, so a pause left sitting inside one would be counted as time spent -- and it was, until this: the
    /// clock read 14 seconds against a row claiming 20. Ending it at the pause is also what hands the stretch
    /// to the time entry module, which is the moment it can be asked whether it counts.
    ///
    /// **Which of the two this is comes from the table**, not from a flag: an open segment is what running means.
    /// So a launch that inherits a paused session can resume it, which an in-memory flag could not -- a new launch
    /// started that flag empty, and the toggle refused, leaving a category on show that could not be started.
    func togglePause() {
        // Read before anything is written, since it is what decides which of the two this is.
        let before = timing?.read() ?? .idle
        // Nothing being timed means no clock and no row, so there is nothing here to stop or start. The same
        // question the dropdown's Pause item and the status item's right side ask, and the same answer.
        guard ManualTimerRules.isClickable(before.state) else { return }
        // One moment for both halves, so the segment that ends and the one that begins meet exactly.
        let moment = Date()
        if before.state == .running {
            deviceEvents?.closeOpenSegment(at: moment)
        } else {
            // The same face the paused stretch was on, not the next one, and nothing is written to it. Rotating
            // exists to stop a face's category changing under a finished segment, and resuming does not change
            // it: this is the same category continuing. Reusing the face is therefore safe, and it keeps a
            // pause-heavy session from cycling the pool for no reason.
            deviceEvents?.startSegment(face: currentManualFace(), at: moment)
        }
        // Read back rather than assumed, which is the rule applied to the app's own writes as well as to what it
        // shows: this says what the table now holds, so a write that did not take says so here.
        let after = timing?.read() ?? .idle
        debugLog?.record(
            .mode,
            "Timing: \(after.state == .running ? "running" : "stopped") "
                + "\"\(after.category?.name ?? "nothing")\", \(Int(after.seconds))s today"
        )
        draw(after)
        onTimingChanged?()
        if after.state == .running {
            startTicking()
        } else {
            // Nothing left to repaint once it is stopped: the figure cannot change again until it is started, and
            // the redraw above has already shown its final value.
            stopTicking()
        }
    }

    private func startTicking() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let reading = self.timing?.read() ?? .idle
                // Stopped behind our back -- there is no such path today, every pause going through `togglePause`
                // above, and a clock that kept repainting a frozen figure would be the sort of thing nobody
                // notices. So the tick asks rather than trusting it was stopped.
                guard reading.state == .running else {
                    self.stopTicking()
                    return
                }
                self.draw(reading)
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
        // Before the window is on screen, so it never appears on one tab and switches to another.
        select(Self.tabOnOpen)
        // Logged here rather than left to the tab view's delegate, which does not fire for a tab that is already
        // selected -- and since Faces became the *first* tab, that is now every ordinary open. The row is the only
        // evidence of which tab an open landed on, so it says so itself rather than depending on a change happening.
        debugLog?.record(.tab, "Settings opened on \(Self.tabOnOpen.title)")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reloadSelectedPane()
        if timing?.read().state == .running {
            startTicking()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app, so the Dock icon goes away with the window that needed it.
        NSApp.setActivationPolicy(.accessory)
        // The clock keeps running; only the repainting stops. The figure comes from what is recorded rather than
        // from anything counting up in here, so a closed window costs nothing and misses nothing.
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

    /// The tab every open lands on.
    ///
    /// **Faces, always**, whatever the window was last left on. It is where the time is: the category list,
    /// the clock, and starting or stopping it are all there and nowhere else, so it is what somebody opening
    /// this window came for. The previous app forced it only in manual mode and otherwise reopened wherever
    /// the user left off -- reasoning that moving somebody's window under them is worse than useless -- but
    /// that left a glance at Report costing a click to get back to the tab that does the work.
    ///
    /// A single value rather than a rule taking arguments, because there is nothing yet to weigh against it.
    /// The archive's version answered a second case (jump to Device while a low battery is blinking); when
    /// something here has a claim that strong, this becomes a decision again.
    static let tabOnOpen: SettingsTab = .faces

    /// Shows a tab, moving the bar and the pane together.
    ///
    /// Through the bar's selection rather than the tab view's, so the two cannot disagree: `tabBarChanged`
    /// is what drives the panes, and it is the only thing that does.
    ///
    /// Internal so what `show()` does to the tabs can be asserted without putting a window on somebody's
    /// screen, which is the only other thing `show()` does that a test would have to tolerate.
    func select(_ tab: SettingsTab) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab) else { return }
        tabBar.selectedSegment = index
        tabBarChanged()
    }

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
    /// app does choose one itself (see `show`). A message that said "clicked" would then be a lie in
    /// exactly the case worth investigating.
    ///
    /// **It fires on a change, not on a selection.** Choosing the tab already showing is not a change, so this says
    /// nothing at all on an ordinary open now that Faces is both the first tab and the tab every open lands on --
    /// which is why `show` logs the open itself rather than leaving the evidence to this.
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
        let pane: NSView
        switch tab {
        case .faces: pane = makeFacesPane()
        case .categories: pane = CategoriesPane()
        // Empty, and each becomes its own view when there is something to put in it.
        case .report, .app, .device: pane = NSView()
        }
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

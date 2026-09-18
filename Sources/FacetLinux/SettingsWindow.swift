import CGtk
import FacetCore
import Foundation

/// The Settings window: a tab bar, the pane under it, and a Close button.
///
/// **The Linux half of `SettingsWindowController`, and there was no port to fill for it.** That file is 3,206 lines
/// of AppKit, and `docs/architecture-ports-plan.md` item 6 is explicit that what is left of it is view construction
/// and tab wiring -- which is what an adapter is *for*. So this is built rather than slotted into, and the
/// standing instruction from `docs/handover-linux.md` item 22 applies as it is built: a decision worth sharing comes
/// out into the core rather than being written a second time here. `CategoryEdits` is the first of those.
///
/// **Built on each open and destroyed on each close**, which is the one real difference from the Mac and is the
/// first rule in `CLAUDE.md` made structural rather than remembered. There the window and its five panes are made
/// once and reused, so the controller has to put every fold back to its default on each open
/// (`restoreDefaultSectionStates`) and re-read every setting into the panes; here a closed window is a destroyed
/// one, so the next open reads the tables again because there is nothing left to read from. Nothing is given up for
/// it: every open lands on the same tab anyway, and the window manager remembers where a window was on screen.
///
/// **One width, and the height free** -- `SettingsMetrics.windowWidth`, pinned by making the minimum and the maximum
/// the same number. `CLAUDE.md`'s *A tab's content spans the width of the window* is what that is for, and the
/// intermittent version of the fault is what it buys: a panel that spans at one size and stops short at another.
///
/// **Which tabs it has is which tabs exist.** The Mac's notebook carries all five and always opens on Faces
/// (`SettingsWindowController.tabOnOpen`); four of the five are not built here yet, and a tab holding an empty pane
/// is a control that looks live and does nothing -- which is exactly what `StatusItemMenu` refuses to draw. So the
/// notebook is built from what `pane(for:)` can make, and when the Faces tab lands here, opening on it is a decision
/// that comes into the core with it rather than being written down twice.
@MainActor
final class SettingsWindow {
    private let categories: CategoryStore
    private let faces: FaceStore
    private let icons: IconStore
    private let colours: ColourStore
    private let entries: TimeEntryStore
    private let settings: SettingStore
    private let timing: TimingReadout
    private let report: ReportReadout
    private let dialogues: DialoguePresenter
    private let google: GoogleConnection
    private let deviceRows: DeviceSettingRows
    private let deviceReadings: DeviceReadings

    /// What the Device tab needs from the radio, which the core has no protocol for and this window has no business
    /// reaching itself. **Closures rather than a radio**, so a window built for a layout check has no device in it
    /// at all -- the same shape `TimingReadout` uses for the same question.
    struct DeviceReadings {
        var battery: () -> Int?
        var isReachingForCube: () -> Bool
        var pair: () -> Void
        var forget: () -> Void
        /// Wipes the cube, and answers what became of it. **The outcome comes back rather than being acted on**,
        /// because what to say about it is `FactoryResetOutcome.message(for:)` and what to do about it is the
        /// window's: only a confirmed wipe gives the cube up.
        var reset: (@escaping @MainActor (FactoryResetOutcome) -> Void) -> Void
    }
    private let categoryEdits: CategoryEdits
    private let faceEdits: FaceEdits
    private let isLimitReached: () -> Bool

    /// The clock the Faces tab's figure moves on. **Injected, which is what makes it the same one every other tick
    /// in the app uses** -- the menu bar's repaint, the history timer, the reconnect loop. The Mac reaches for
    /// `Timer.scheduledTimer` here and is the reason `RunLoop` is on `PlatformBlindCoreTests.bannedSpellings`.
    private let scheduler: Scheduler
    private let debugLog: DebugLog?

    /// What is on screen, or `nil` while the window is shut. **The window and its panes together**, because they
    /// live and die together: there is no state here that outlives an open.
    private var shown: Shown?

    private struct Shown {
        let window: UnsafeMutablePointer<GtkWidget>
        let notebook: UnsafeMutablePointer<GtkWidget>
        /// The tabs in the order the notebook holds them, so a page number can be named.
        let tabs: [SettingsTab]
        let categories: CategoriesPane
        let faces: FacesPane
        let report: ReportPane
        let app: AppSettingsPane
        let device: DevicePane
    }

    /// The once-a-second repaint of the Faces tab's figure, running only while that tab is showing and something is
    /// counting. **Held so it can be stopped**, which is the whole of what it is for: a wake a second repainting a
    /// pane nobody is looking at is the kind of thing nothing ever notices.
    private var tick: ScheduledWake?

    /// Asks before wiping a cube, and acts on the answer.
    ///
    /// **The question is `CubeResetQuestion`'s and the wording of every ending is
    /// `FactoryResetOutcome.message(for:)`'s**, both in the core, so the two platforms make the same promise about
    /// the most destructive control the app has. What is here is the order: ask, send, and give the cube up only
    /// for a wipe that was proven.
    private func confirmReset() {
        dialogues.ask(CubeResetQuestion.dialogue, offering: CubeResetQuestion.answers) { [weak self] answer in
            guard let self else { return }
            guard answer == true else {
                debugLog?.record(.pair, "Button clicked: Cancel, the cube was not reset")
                return
            }
            let name = settings.string("device_name", field: "name") ?? "the cube"
            deviceReadings.reset { [weak self] outcome in
                guard let self else { return }
                debugLog?.record(.pair, "The reset ended: \(outcome)")
                // **Only a confirmed wipe gives the cube up**, which is `FactoryResetOutcome`'s whole point: sent
                // and erased are different claims, and throwing away a cube's name on the strength of a command
                // that may never have landed is the mistake that distinction exists to stop.
                if outcome == .confirmed {
                    DevicePairingRecorder(settings: settings, debugLog: debugLog).recordFactoryReset()
                    onTimingChanged?()
                }
                deviceChanged()
                dialogues.tell(Dialogue(title: "Reset", message: outcome.message(for: name)))
            }
        }
    }

    /// The cube connected, dropped, or said what it is. **Not a setting the window holds**, which is the licence's
    /// own boundary: what the app changes behind the window goes on being read on its own terms.
    func deviceChanged() {
        shown?.device.reload()
    }

    /// An account was connected, so a sweep becomes possible. **Assigned rather than taken at init**, for the
    /// reason `onTimingChanged` is: what it reaches is built after this window.
    var onGoogleConnected: (@MainActor () -> Void)?

    /// Everything drawn from the app's own clock, after a setting that one of them is drawn from changed.
    ///
    /// **Assigned rather than taken at init**, which is the Mac's arrangement (`settingsWindow.onTimingChanged`) and
    /// is forced by the order a composition root can build things in: the menu bar this wakes is built *after* the
    /// window, because its dropdown opens the window. A closure passed in here would be reaching a value that does
    /// not exist yet.
    var onTimingChanged: (@MainActor () -> Void)?

    private var signals = GtkSignals()

    init(
        categories: CategoryStore,
        faces: FaceStore,
        icons: IconStore,
        colours: ColourStore,
        entries: TimeEntryStore,
        settings: SettingStore,
        timing: TimingReadout,
        report: ReportReadout,
        dialogues: DialoguePresenter,
        google: GoogleConnection,
        deviceRows: DeviceSettingRows,
        deviceReadings: DeviceReadings,
        categoryEdits: CategoryEdits,
        faceEdits: FaceEdits,
        isLimitReached: @escaping () -> Bool,
        scheduler: Scheduler,
        debugLog: DebugLog?
    ) {
        self.categories = categories
        self.faces = faces
        self.icons = icons
        self.colours = colours
        self.entries = entries
        self.settings = settings
        self.timing = timing
        self.report = report
        self.dialogues = dialogues
        self.google = google
        self.deviceRows = deviceRows
        self.deviceReadings = deviceReadings
        self.categoryEdits = categoryEdits
        self.faceEdits = faceEdits
        self.isLimitReached = isLimitReached
        self.scheduler = scheduler
        self.debugLog = debugLog
    }

    /// Puts the window on screen, or brings the one that is already there forward.
    func show() {
        if let shown {
            // **Presented rather than rebuilt.** Two Settings windows would be two answers to every setting in
            // them, which is the first rule's own case.
            facet_window_present(shown.window)
            return
        }
        build()
    }

    /// Takes the window down. The next open builds it again, which is what makes an external change made while it
    /// was shut simply what that open finds.
    func close() {
        guard let shown else { return }
        gtk_widget_destroy(shown.window)
        // `destroy` is handled below and is what clears `shown`, so a close from here and a close from the window
        // manager end the same way rather than in two places that have to agree.
    }

    private func build() {
        SettingsWidgets.installStyles(debugLog: debugLog)
        signals = GtkSignals()

        let window = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        SettingsWidgets.identify(window, "settings-window")
        facet_window_set_title(window, "Facet Settings")
        facet_window_set_default_size(
            window,
            Int32(SettingsMetrics.windowWidth),
            Int32(SettingsMetrics.windowDefaultHeight)
        )
        facet_window_pin_width(
            window,
            Int32(SettingsMetrics.windowWidth),
            Int32(SettingsMetrics.windowMinimumHeight)
        )

        let notebook = gtk_notebook_new()!
        SettingsWidgets.identify(notebook, "settings-tabs")

        let categoriesPane = CategoriesPane(
            categories: categories,
            faces: faces,
            icons: icons,
            colours: colours,
            entries: entries,
            edits: categoryEdits,
            debugLog: debugLog
        )
        let facesPane = FacesPane(
            categories: categories,
            timing: timing,
            settings: settings,
            edits: faceEdits,
            categoryEdits: categoryEdits,
            isLimitReached: isLimitReached
        )

        let reportPane = ReportPane(readout: report, debugLog: debugLog)
        let appPane = AppSettingsPane(
            settings: settings,
            dialogues: dialogues,
            google: google,
            googleConnected: { [weak self] in self?.onGoogleConnected?() },
            debugLog: debugLog,
            timingChanged: { [weak self] in self?.onTimingChanged?() }
        )
        let devicePane = DevicePane(
            settings: settings,
            rows: deviceRows,
            battery: deviceReadings.battery,
            isReachingForCube: deviceReadings.isReachingForCube,
            pair: deviceReadings.pair,
            forget: { [weak self] in
                self?.deviceReadings.forget()
                // Redrawn from the table afterwards, and the bar told: forgetting a cube changes what this tab is
                // allowed to offer *and* what the status item says the app is doing.
                self?.deviceChanged()
                self?.onTimingChanged?()
            },
            reset: { [weak self] in self?.confirmReset() },
            debugLog: debugLog
        )

        var tabs: [SettingsTab] = []
        for tab in SettingsTab.allCases {
            guard let pane = pane(
                for: tab,
                categories: categoriesPane,
                faces: facesPane,
                report: reportPane,
                app: appPane,
                device: devicePane
            ) else { continue }
            let label = SettingsWidgets.plainLabel(tab.title)
            SettingsWidgets.identify(label, "settings-tab-\(tab.rawValue)")
            facet_notebook_append_page(notebook, pane, label)
            tabs.append(tab)
        }

        let content = SettingsWidgets.column(spacing: 0)
        // The notebook takes the room: the panes are what the window is for, and the Close button below is one row
        // high whatever the window's height is.
        facet_box_pack_start(content, notebook, 1, 1, 0)
        facet_box_pack_start(content, closeRow(window), 0, 1, 0)
        facet_container_add(window, content)

        shown = Shown(
            window: window,
            notebook: notebook,
            tabs: tabs,
            categories: categoriesPane,
            faces: facesPane,
            report: reportPane,
            app: appPane,
            device: devicePane
        )

        // **Read whenever an edit changes what a list holds.** Set on the open and given up on the close:
        // there is nothing to redraw while the window is shut, and the menu bar's own tick is what keeps the tray
        // current either way.
        categoryEdits.changed = { [weak self] in self?.reloadShownPane() }
        faceEdits.changed = { [weak self] in self?.reloadShownPane() }

        facet_on_switch_page(notebook, { _, _, page, data in
            guard let data else { return }
            MainActor.assumeIsolated {
                Unmanaged<SettingsWindow>.fromOpaque(data).takeUnretainedValue().pageChanged(to: Int(page))
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        signals.connectEvent(window, "key-press-event") { [weak self] event in
            guard let self, EditableNameCell.isEscape(event) else { return false }
            // **Escape belongs to whichever control needs it more**, and what decides that is where the keyboard is
            // pointing. A field open for editing abandons the edit; anything else closes the window. The Mac reaches
            // the same answer by lending its Close button's key equivalent away while a field is open, because on
            // both toolkits the window sees a key before the focused widget does.
            guard facet_is_entry_focused(window) == 0 else { return false }
            debugLog?.record(.click, "Settings closed by Escape")
            close()
            return true
        }
        signals.connect(window, "destroy") { [weak self] in self?.forget() }

        gtk_widget_show_all(window)
        reportPanesThatDoNotFit(tabs: tabs, panes: [
            .faces: facesPane.widget,
            .categories: categoriesPane.widget,
            .report: reportPane.widget,
            .app: appPane.widget,
            .device: devicePane.widget,
        ])
        // **The tables are read after the widgets are shown, and that is measured rather than tidy** (2026-09-16):
        // `gtk_notebook_get_current_page` answers **-1** until its pages have been shown, so a read before this line
        // found no tab to read and both lists came up empty. Nothing is on screen yet either way -- GTK maps the
        // window when the main loop next turns -- so this is still before anybody could see an empty pane.
        //
        // **The App tab is read here rather than when it is switched to**, which is the rule's first condition: an
        // open window reads every tab's settings in one go, and what it holds from that moment is the answer.
        appPane.reload()
        devicePane.reload()
        reloadShownPane()
        // Logged here rather than left to the page handler, which does not fire for the page a notebook is already
        // on -- and that is every ordinary open. The row is the only evidence of which tab an open landed on, so it
        // says so itself rather than depending on a change happening.
        debugLog?.record(.tab, "Settings opened on \(tabs.first?.title ?? "nothing")")
    }

    /// Says which pane is wider than the window is allowed to be, if any is.
    ///
    /// **The window is one width and a pane cannot be made narrower than its contents**, so a pane that demands more
    /// simply widens the window -- and `CLAUDE.md`'s *A tab's content spans the width of the window* is then quietly
    /// false, with nothing on screen to say which tab did it. Measured 2026-09-16: the window came up 730 wide and
    /// the only way to tell which of five panes had done it was to take them out one at a time.
    ///
    /// A row rather than a refusal: the window is still usable, and the fix is a measurement somebody has to make.
    private func reportPanesThatDoNotFit(tabs: [SettingsTab], panes: [SettingsTab: UnsafeMutablePointer<GtkWidget>]) {
        for tab in tabs {
            guard let pane = panes[tab] else { continue }
            var minimum: Int32 = 0
            var natural: Int32 = 0
            gtk_widget_get_preferred_width(pane, &minimum, &natural)
            guard CGFloat(minimum) > SettingsMetrics.windowWidth else { continue }
            debugLog?.record(
                .tab,
                "The \(tab.title) tab needs \(minimum)pt and the window is \(Int(SettingsMetrics.windowWidth))pt, "
                    + "so the window is wider than it should be"
            )
        }
    }

    /// The pane for a tab, or `nil` for one this platform has not built.
    ///
    /// **A switch rather than a table, so the compiler names the tabs still missing**: adding a case to
    /// `SettingsTab` fails to compile here until somebody has decided what this platform does about it.
    private func pane(
        for tab: SettingsTab,
        categories: CategoriesPane,
        faces: FacesPane,
        report: ReportPane,
        app: AppSettingsPane,
        device: DevicePane
    ) -> UnsafeMutablePointer<GtkWidget>? {
        switch tab {
        case .faces:
            return faces.widget
        case .categories:
            return categories.widget
        case .report:
            return report.widget
        case .app:
            return app.widget
        case .device:
            return device.widget
        }
    }

    /// Bottom right, where a window's dismissal belongs.
    private func closeRow(_ window: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        let row = SettingsWidgets.row()
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(row, Int32(Self.closePadding))
        }
        let close = gtk_button_new_with_label("Close")!
        SettingsWidgets.identify(close, "close-settings")
        signals.connect(close, "clicked") { [weak self] in
            self?.debugLog?.record(.click, "Button clicked: Close (Settings window)")
            gtk_widget_destroy(window)
        }
        facet_box_pack_end(row, close, 0, 0, 0)
        return row
    }

    /// Around the Close button. The Mac's number, and the only one in this file that is not `SettingsMetrics`': it is
    /// the window's chrome rather than anything a tab is drawn from.
    private static let closePadding: CGFloat = 12

    /// Reads the tables again for the pane on show.
    ///
    /// **The pane on show and not all of them**, which is what the Mac's `reloadSelectedPane` does too: a tab nobody
    /// is looking at is read when it is switched to, and reading all of them would be work in service of nothing.
    private func reloadShownPane() {
        guard let shown, let tab = shownTab() else { return }
        reload(tab, in: shown)
    }

    /// The tab on show.
    ///
    /// **Asked of the notebook, which is right everywhere except during a switch**: `switch-page` is emitted
    /// *before* the page changes, so a handler asking here would be told the tab being left. Measured 2026-09-16 --
    /// switching to Report re-read Faces and the totals never arrived. That is why `pageChanged` passes the tab it
    /// was handed instead of calling this.
    private func shownTab() -> SettingsTab? {
        guard let shown else { return nil }
        let page = Int(facet_notebook_get_current_page(shown.notebook))
        return shown.tabs.indices.contains(page) ? shown.tabs[page] : nil
    }

    private func reload(_ tab: SettingsTab, in shown: Shown) {
        switch tab {
        case .faces:
            shown.faces.reload()
        case .categories:
            shown.categories.reload()
        case .report:
            // **Re-read on every switch to it, and after an edit.** A total is only true as of the moment it was
            // summed, and pausing the clock from the tray is exactly the sort of thing that changes one while this
            // tab is the one on show.
            shown.report.reload()
        case .app, .device:
            // **Read once per open rather than per switch**, which is the one place this window holds what it shows:
            // `CLAUDE.md` licenses an open Settings window to be the source of truth for the settings on it, under
            // conditions the panes keep. Re-reading on every switch would take a value out from under somebody who
            // had just typed it.
            //
            // **What the app itself changes behind the window is not covered by that**, which the rule is explicit
            // about: a cube connecting or going changes what the Device tab is allowed to offer, and `deviceChanged`
            // is what carries that.
            break
        }
        // **The figure is decided from the reading, not from the gesture that caused it.** A cube turned, a
        // double-tap, a limit spent and a pause from the tray all arrive as a redraw and any of them can be the
        // moment the number starts or stops moving -- so this is the one place the tick is decided.
        keepTicking(on: tab)
    }

    /// Starts or stops the once-a-second repaint from one answer, so no caller has to remember both halves.
    ///
    /// **Only while the Faces tab is the one on show.** The figure is worked out when it is drawn rather than
    /// counted up in here, so a tab nobody is looking at misses nothing by not ticking -- and the Mac stops its own
    /// for the window being off screen, which is the same judgement about the same wake.
    private func keepTicking(on tab: SettingsTab) {
        let shouldTick = tab == .faces && timing.read().isCounting
        guard shouldTick else {
            tick?.cancel()
            tick = nil
            return
        }
        guard tick == nil else { return }
        // **A second, because it is a clock**, which is the same exception the menu bar's repaint writes down: there
        // is no event to hang a running total on, the seconds simply pass. The read itself still goes to the
        // database every time; what the wake decides is only how often to ask. `mayGroup` is deliberately not given
        // -- a figure showing seconds that settles alongside some other wake visibly skips one.
        tick = scheduler.wake(in: 1, repeating: true) { [weak self] in
            guard let self, let shown else { return }
            let reading = timing.read()
            // Stopped behind our back -- a cube double-tapped, a limit reached, a pause from the tray -- and a clock
            // that kept repainting a frozen figure would be the sort of thing nobody notices. So the tick asks
            // rather than trusting it was stopped.
            guard reading.isCounting else {
                tick?.cancel()
                tick = nil
                return
            }
            shown.faces.draw(reading)
        }
    }

    /// Records the tab that is now showing, and reads it.
    ///
    /// "Selected", not "clicked": this fires for a tab chosen in code as well as one clicked.
    private func pageChanged(to page: Int) {
        guard let shown, shown.tabs.indices.contains(page) else { return }
        let tab = shown.tabs[page]
        debugLog?.record(.tab, "Settings tab selected: \(tab.title)")
        // **The tab it was handed, not the one the notebook reports**: see `shownTab`.
        reload(tab, in: shown)
    }

    /// The window has gone, however it went: the Close button, the window manager, or the app quitting.
    private func forget() {
        shown = nil
        signals.removeAll()
        // Nothing to repaint once the window has gone, and a wake that outlived it would be a second a wake for a
        // pane that no longer exists.
        tick?.cancel()
        tick = nil
        // Given up with the window, so an edit made from somewhere else while Settings is shut does not reach a
        // pane that no longer exists.
        categoryEdits.changed = nil
        faceEdits.changed = nil
    }
}

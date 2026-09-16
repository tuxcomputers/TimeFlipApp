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
    private let edits: CategoryEdits
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
    }

    private var signals = GtkSignals()

    /// Whether the window is up, which is what the menu bar's Settings line would ask if it ever needed to.
    var isOpen: Bool { shown != nil }

    init(
        categories: CategoryStore,
        faces: FaceStore,
        icons: IconStore,
        colours: ColourStore,
        entries: TimeEntryStore,
        edits: CategoryEdits,
        debugLog: DebugLog?
    ) {
        self.categories = categories
        self.faces = faces
        self.icons = icons
        self.colours = colours
        self.entries = entries
        self.edits = edits
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
            edits: edits,
            debugLog: debugLog
        )

        var tabs: [SettingsTab] = []
        for tab in SettingsTab.allCases {
            guard let pane = pane(for: tab, categories: categoriesPane) else { continue }
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

        shown = Shown(window: window, notebook: notebook, tabs: tabs, categories: categoriesPane)

        // **The lists are read now, with the window built and before it is on screen**, so it never appears empty
        // and fills in.
        categoriesPane.reload()
        // **And read again whenever an edit changes what they hold.** Set on the open and given up on the close:
        // there is nothing to redraw while the window is shut, and the menu bar's own tick is what keeps the tray
        // current either way.
        edits.changed = { [weak self] in self?.reloadShownPane() }

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
        // Logged here rather than left to the page handler, which does not fire for the page a notebook is already
        // on -- and that is every ordinary open. The row is the only evidence of which tab an open landed on, so it
        // says so itself rather than depending on a change happening.
        debugLog?.record(.tab, "Settings opened on \(tabs.first?.title ?? "nothing")")
    }

    /// The pane for a tab, or `nil` for one this platform has not built.
    ///
    /// **A switch rather than a table, so the compiler names the tabs still missing**: adding a case to
    /// `SettingsTab` fails to compile here until somebody has decided what this platform does about it.
    private func pane(for tab: SettingsTab, categories: CategoriesPane) -> UnsafeMutablePointer<GtkWidget>? {
        switch tab {
        case .categories:
            return categories.widget
        case .faces, .report, .app, .device:
            // Item 11 of `docs/linux-port.md`, in size order: the Faces tab, then Report, then App and Device.
            return nil
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
        guard let shown else { return }
        let page = Int(facet_notebook_get_current_page(shown.notebook))
        guard shown.tabs.indices.contains(page) else { return }
        switch shown.tabs[page] {
        case .categories:
            shown.categories.reload()
        case .faces, .report, .app, .device:
            break
        }
    }

    /// Records the tab that is now showing, and reads it.
    ///
    /// "Selected", not "clicked": this fires for a tab chosen in code as well as one clicked.
    private func pageChanged(to page: Int) {
        guard let shown, shown.tabs.indices.contains(page) else { return }
        debugLog?.record(.tab, "Settings tab selected: \(shown.tabs[page].title)")
        reloadShownPane()
    }

    /// The window has gone, however it went: the Close button, the window manager, or the app quitting.
    private func forget() {
        shown = nil
        signals.removeAll()
        // Given up with the window, so an edit made from somewhere else while Settings is shut does not reach a
        // pane that no longer exists.
        edits.changed = nil
    }
}

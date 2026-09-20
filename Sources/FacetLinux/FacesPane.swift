import CGtk
import FacetCore
import Foundation

/// The Faces tab: what is being timed on the left, the categories to pick from on the right.
///
/// **The archive's layout, and the Mac's**: a wide left column for the thing being timed and a narrow right column
/// for the list, two thirds to one third. Clicking a category is what starts a session -- or hands a face a
/// category, or does nothing -- and the control in the left column is what stops it.
///
/// **The tab every open lands on, on the Mac.** It is where the time is: the category list, the clock, and starting
/// or stopping it are all here and nowhere else. This platform opens on it too now that it exists, which is
/// `SettingsWindowController.tabOnOpen`'s decision rather than a second one taken here.
///
/// **It reads and it draws; what a gesture means is `FaceEdits`'.** The two clicks and the pick all go straight to
/// that core module, which is the same one the Mac is asked to adopt -- so a cube resting on a locked face refuses a
/// click identically on both platforms, and says so identically.
///
/// **The figure moves, so this tab has a tick.** It is the only one that does: `SettingsWindow` starts a wake a
/// second while this tab is showing and something is counting, and stops it the moment the reading says otherwise.
@MainActor
final class FacesPane {
    private enum Layout {
        /// The gutter between the two columns.
        static let columnSpacing = 24
        /// Between a heading and what sits under it.
        static let sectionSpacing = Int(SettingsMetrics.headingSpacing)
        /// The narrow column, in points. **A width rather than the Mac's ratio**, and for the reason `TimingView`
        /// gives up its fractions: that ratio holds as a window is resized, and this window is one width.
        static let categoriesColumnWidth = 200
    }

    let widget: UnsafeMutablePointer<GtkWidget>

    let timingView = TimingView()
    let categoryList = CategoryListView()
    let createControl = CategoryCreateControl()

    private let categories: CategoryStore
    private let timing: TimingReadout
    private let settings: SettingStore
    private let edits: FaceEdits
    private let categoryEdits: CategoryEdits
    private let isLimitReached: () -> Bool

    init(
        categories: CategoryStore,
        timing: TimingReadout,
        settings: SettingStore,
        edits: FaceEdits,
        categoryEdits: CategoryEdits,
        isLimitReached: @escaping () -> Bool
    ) {
        self.categories = categories
        self.timing = timing
        self.settings = settings
        self.edits = edits
        self.categoryEdits = categoryEdits
        self.isLimitReached = isLimitReached

        widget = SettingsWidgets.row(spacing: Layout.columnSpacing)
        SettingsWidgets.identify(widget, SettingsTab.faces.paneIdentifier)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(widget, Int32(SettingsMetrics.tabPadding))
        }

        // **Plain headings above their content, not on a panel**, which is `CLAUDE.md`'s distinction: these name what
        // is under them rather than operating it, and this tab is the only one left with any.
        let timingColumn = column(
            heading: "Timing",
            identifier: "faces-timing-column",
            headingIdentifier: "faces-timing-heading"
        )
        facet_box_pack_start(timingColumn, timingView.widget, 0, 1, 0)

        let categoriesColumn = column(
            heading: "Categories",
            identifier: "faces-categories-column",
            headingIdentifier: "faces-categories-heading"
        )
        gtk_widget_set_size_request(categoriesColumn, Int32(Layout.categoriesColumnWidth), -1)
        facet_box_pack_start(categoriesColumn, categoryList.widget, 0, 1, 0)
        // Under the list rather than at the foot of the column, so it stays with what it adds to: the panel is as
        // tall as its rows, and a short list would otherwise strand the button at the bottom of the pane.
        facet_box_pack_start(categoriesColumn, createControl.widget, 0, 1, 0)

        facet_box_pack_start(widget, timingColumn, 1, 1, 0)
        facet_box_pack_start(widget, categoriesColumn, 0, 0, 0)

        wire()
    }

    /// Reads the categories and the session, and draws both columns.
    ///
    /// **One reading for the whole tab**, which is what keeps this and the menu bar saying the same thing. They did
    /// not, briefly, on the Mac: the pane asked the radio for the face while the status item asked `TimingReadout`
    /// what was being timed, so a launch with a cube connected drew the cube's category on the tab and the app's name
    /// in the bar.
    func reload() {
        categoryList.show(categories.activeCategories())
        draw(timing.read())
    }

    /// Draws a reading already taken, which is what the tick wants: it has to look at the state anyway to decide
    /// whether to keep going, and reading twice for one repaint would be two answers where one will do.
    func draw(_ reading: TimingReadout.Reading) {
        // **The lock, the list and the click all come off one answer**, asked here and again at the click rather than
        // written out twice. This app had only the click half until a locked face was watched refusing one on
        // hardware with nothing on screen to say so.
        categoryList.allowPicking(edits.click(for: reading).doesAnything)
        guard let face = reading.cubeFace else {
            timingView.show(
                category: reading.category,
                timingState: reading.timingState,
                elapsed: reading.seconds,
                isLimitReached: isLimitReached()
            )
            return
        }
        timingView.show(
            face: face,
            category: reading.category,
            isFaceLocked: edits.isFaceLocked(face),
            // The same figure the menu bar draws, out of the same reading, so the two cannot differ by a read.
            elapsed: reading.seconds,
            // Read at the moment it is drawn, like every other setting: the App tab can change it while this window
            // is open, and the next redraw is what carries it.
            showingSeconds: settings.flag("display_seconds", field: "enabled") ?? true,
            cubePauseState: reading.cubePauseState
        )
    }

    private func wire() {
        categoryList.onSelect = { [weak self] category in self?.edits.start(category) }
        timingView.onTogglePause = { [weak self] in self?.edits.togglePause() }
        timingView.onToggleLock = { [weak self] in self?.edits.toggleLock() }
        // **The same control the Categories tab has, and the same writer** -- with one difference the core carries:
        // a category made here starts timing, because somebody typing a name into this tab is naming what they are
        // about to do.
        createControl.onSave = { [weak self] typed in self?.categoryEdits.create(typed, startsTiming: true) }
    }

    /// **The heading's identifier is given rather than derived.** It used to be `"\(identifier)-heading"`, which
    /// produced `faces-timing-column-heading` where the Mac names the same label `faces-timing-heading` -- two names
    /// for one thing, which is the hazard `CLAUDE.md` opens with, and a check written once then drives one platform.
    private func column(
        heading: String,
        identifier: String,
        headingIdentifier: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = SettingsWidgets.column(spacing: Layout.sectionSpacing)
        SettingsWidgets.identify(column, identifier)
        let label = SettingsWidgets.plainLabel(heading)
        facet_label_set_markup(label, "<b>\(heading)</b>")
        SettingsWidgets.identify(label, headingIdentifier, saying: heading)
        facet_box_pack_start(column, label, 0, 0, 0)
        return column
    }
}

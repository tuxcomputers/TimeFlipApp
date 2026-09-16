import CGtk
import FacetCore
import Foundation

/// The Categories tab's Active list: a caption row naming the columns, then one row per category, on the panel its
/// section draws around both this and the heading.
///
/// **The columns are the archive's five**: Active, icon, name, colour, daily limit. All but the name are live -- the
/// box retires a category, the icon and the swatch each open a picker, and the limit writes `category.daily_limit`.
///
/// **A different list from a pick list**, which is the Mac's own distinction and holds here: this is a record of what
/// each category *is*, in columns that line up down the tab so one property can be read across every category at a
/// glance. The Faces tab's list, when it lands, is the other kind.
///
/// **Rebuilt rather than diffed**, for the reason every list in this window is: the rows are read from the database
/// every time, so they arrive whole, and reconciling them against what is on screen would be work in service of
/// nothing.
///
/// **The tint is the section's, not this list's.** Content inside a panel must not draw a panel of its own, which
/// `CLAUDE.md` names as a fault that has already happened once: two translucent fills stack and the rows come out
/// darker than the heading above them.
@MainActor
final class CategoryTable {
    /// The archive's column widths, by way of the Mac's `CategoryTable.Layout`, and its reason for fixing them at
    /// all: a label sized to its own content would put the next column at a different x on every row.
    enum Layout {
        static let nameColumnWidth: CGFloat = 160
        static let colourColumnWidth: CGFloat = 46
        /// A checkbox is narrower than the word "Active" above it, so the column is fixed to the caption's width.
        static let activeColumnWidth: CGFloat = 44
        static let iconSize = 20
        /// One number field wide, and wide enough for the caption over it.
        static let limitColumnWidth: CGFloat = 200
    }

    let widget: UnsafeMutablePointer<GtkWidget>

    /// The rows, and the handlers on them, thrown away together. **Not a copy of anything true** -- it is what GTK
    /// was handed, kept only so it can be taken back, which is the same thing `MenuBar.shown` is.
    private let signals = GtkSignals()

    /// Which faces hold a category, and whether they are locked, which is what decides whether a row can be edited at
    /// all. Asked per row as the row is built, so it is read when it is needed rather than passed in alongside the
    /// categories and going stale between the two.
    var facesHolding: ((CategoryRecord) -> [(face: Int, isFaceLocked: Bool)])?

    var onSetDailyLimit: ((CategoryRecord, Int) -> Void)?
    var onRetire: ((CategoryRecord) -> Void)?
    var onRename: ((CategoryRecord, String) -> Void)?
    /// Called with the category and the cell the picker should hang from: a popover has to be anchored to something,
    /// and the row is the only thing that knows which widget that is.
    var onPickIcon: ((CategoryRecord, UnsafeMutablePointer<GtkWidget>) -> Void)?
    var onPickColour: ((CategoryRecord, UnsafeMutablePointer<GtkWidget>) -> Void)?

    /// The name cells on show, held because nothing else holds them.
    ///
    /// **A lifetime, not a list to read.** An `EditableNameCell` owns the `GtkSignals` carrying its handlers, and
    /// GTK retains the widgets rather than the Swift object around them -- so a cell nobody keeps is deallocated
    /// with its handlers while its entry is still on screen, which is a press reaching a pointer to nothing.
    /// Cleared as the rows are destroyed, and never before.
    private var nameCells: [EditableNameCell] = []

    init() {
        widget = SettingsWidgets.column()
        SettingsWidgets.identify(widget, "category-table")
    }

    /// Replaces the list with `categories`.
    func show(_ categories: [CategoryRecord]) {
        for child in SettingsWidgets.children(of: widget) {
            gtk_widget_destroy(child)
        }
        signals.removeAll()
        nameCells.removeAll()

        // The caption row goes with the categories rather than above them permanently: columns with nothing under
        // them are a table pretending to be empty for a reason, when the truth is there is nothing to show.
        guard !categories.isEmpty else {
            // The previous app's wording, which says what is missing rather than that something went wrong.
            facet_box_pack_start(widget, SettingsWidgets.secondary("No active categories."), 0, 0, 0)
            gtk_widget_show_all(widget)
            return
        }
        facet_box_pack_start(widget, headerRow(), 0, 1, 0)
        for category in categories {
            facet_box_pack_start(widget, row(category), 0, 1, 0)
        }
        gtk_widget_show_all(widget)
    }

    /// The column captions, at the same widths as the row under them so each sits over its own column.
    private func headerRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = SettingsWidgets.row()
        SettingsWidgets.identify(row, "category-table-header")
        facet_box_pack_start(row, SettingsWidgets.cell(SettingsWidgets.caption("Active"), width: Layout.activeColumnWidth), 0, 0, 0)
        // Holds the icon column open with nothing in it: there is nothing useful to call that column.
        facet_box_pack_start(row, SettingsWidgets.cell(SettingsWidgets.spacer(), width: CGFloat(Layout.iconSize)), 0, 0, 0)
        facet_box_pack_start(row, SettingsWidgets.cell(SettingsWidgets.caption("Name"), width: Layout.nameColumnWidth), 0, 0, 0)
        facet_box_pack_start(row, SettingsWidgets.cell(SettingsWidgets.caption("Colour"), width: Layout.colourColumnWidth), 0, 0, 0)
        // The caption says what 0 means, because a limit of nothing and no limit at all are opposites and the field
        // cannot tell them apart on its own. The archive's wording.
        facet_box_pack_start(row, SettingsWidgets.cell(SettingsWidgets.caption("Daily limit (0 = disabled)"), width: Layout.limitColumnWidth), 0, 0, 0)
        return row
    }

    /// One category as a row of columns.
    ///
    /// **A locked face refuses all five columns, and each of them says why on hover**
    /// (`CategoryEditRules.editRefusal`). Refused, not removed: the row is still a record of what the category is,
    /// and a column that vanished on some rows would be a table that changes shape down the tab.
    ///
    /// **Only the two that are purely controls draw as off**, the Active box and the daily limit. The icon, the
    /// colour and the name draw a value that happens to be clickable, and greying those would lose the value -- a
    /// dimmed swatch is a different colour, and a grey name reads as a retired category. Those three stay as they
    /// are and decline the click.
    private func row(_ category: CategoryRecord) -> UnsafeMutablePointer<GtkWidget> {
        let refusal = CategoryEditRules.editRefusal(facesHolding: facesHolding?(category) ?? [])
        let help = CategoryEditRules.editRefusalHelp(refusal, categoryName: category.name)
        let row = SettingsWidgets.row()
        SettingsWidgets.identify(row, "category-detail-row-\(category.id)")
        gtk_widget_set_size_request(row, -1, Int32(SettingsMetrics.rowHeight))

        facet_box_pack_start(row, activeBox(category, refusal: refusal, help: help), 0, 0, 0)
        facet_box_pack_start(row, iconCell(category, refusal: refusal, help: help), 0, 0, 0)
        facet_box_pack_start(row, nameCell(category, refusal: refusal, help: help), 0, 0, 0)
        facet_box_pack_start(row, colourCell(category, refusal: refusal, help: help), 0, 0, 0)
        facet_box_pack_start(row, limitCell(category, refusal: refusal, help: help), 0, 0, 0)
        return row
    }

    /// Ticked, this being the active list. Unticking retires the category.
    ///
    /// **Disabled rather than refused when a locked face holds it**, which is the archive's decision and its
    /// reasoning: retiring takes a category off every face it is on, and a locked face is one the user has said keeps
    /// what it has, so the two instructions contradict each other and the app does not get to choose.
    private func activeBox(
        _ category: CategoryRecord,
        refusal: CategoryEditRules.EditRefusal?,
        help: String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let box = gtk_check_button_new()!
        SettingsWidgets.identify(box, "category-active-\(category.id)")
        facet_toggle_set_active(box, 1)
        gtk_widget_set_sensitive(box, refusal == nil ? 1 : 0)
        gtk_widget_set_tooltip_text(box, help)
        signals.connect(box, "toggled") { [weak self] in
            // Only the one direction: this is the active list, so a box that has been unticked is a retirement and a
            // box being ticked back is the list having been read again.
            guard facet_toggle_get_active(box) == 0 else { return }
            self?.onRetire?(category)
        }
        return SettingsWidgets.cell(box, width: Layout.activeColumnWidth)
    }

    /// The category's artwork, or a "no sign" glyph for one that has none -- the archive's answer, and better than a
    /// gap, which reads as a column that failed to draw rather than as a category nobody has dressed yet.
    private func iconCell(
        _ category: CategoryRecord,
        refusal: CategoryEditRules.EditRefusal?,
        help: String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let content: UnsafeMutablePointer<GtkWidget>
        if let iconName = category.iconName,
           let image = ActivityIcon.image(
               named: iconName,
               size: Layout.iconSize,
               colour: SettingsWidgets.foreground(of: widget)
           ) {
            content = image
        } else {
            content = SettingsWidgets.secondary("\u{2298}")
        }
        let button = SettingsWidgets.flatButton(content)
        SettingsWidgets.identify(button, "category-icon-\(category.id)")
        gtk_widget_set_tooltip_text(
            button,
            help ?? (category.iconName.map { "\(category.name) icon, \(IconStore.displayName(for: $0))" }
                ?? "\(category.name) icon, none")
        )
        // Enabled, and refusing to open: a disabled button greys its artwork, which would make a locked row look
        // retired, and it would take the tooltip explaining the refusal with it.
        signals.connect(button, "clicked") { [weak self] in
            guard refusal == nil else { return }
            self?.onPickIcon?(category, button)
        }
        return SettingsWidgets.cell(button, width: CGFloat(Layout.iconSize))
    }

    /// The name, which becomes a field when it is clicked. What a committed edit means is `CategoryEdits`' -- a
    /// rename is confirmed before it is written -- so this only reports what was typed.
    private func nameCell(
        _ category: CategoryRecord,
        refusal: CategoryEditRules.EditRefusal?,
        help: String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let cell = EditableNameCell(
            name: category.name,
            identifier: "category-name-\(category.id)",
            isEnabled: refusal == nil,
            refusalHelp: help
        )
        cell.onCommit = { [weak self] typed in self?.onRename?(category, typed) }
        nameCells.append(cell)
        return SettingsWidgets.cell(cell.widget, width: Layout.nameColumnWidth)
    }

    /// The swatch sits at the leading edge of a wider column, so the column's width comes from its caption rather
    /// than from the square: what has to line up is where the *next* column starts.
    private func colourCell(
        _ category: CategoryRecord,
        refusal: CategoryEditRules.EditRefusal?,
        help: String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let swatch = ColourSwatch.drawingArea(colour: category.colour, signals: signals)
        let button = SettingsWidgets.flatButton(swatch)
        SettingsWidgets.identify(button, "category-colour-\(category.id)")
        // Named for what it is rather than for the shade, which the row cannot know: the colour's own name lives in
        // the `colour` table and the record carries only the colour itself.
        gtk_widget_set_tooltip_text(
            button,
            help ?? (category.colour == nil ? "\(category.name) colour, none" : "\(category.name) colour")
        )
        signals.connect(button, "clicked") { [weak self] in
            guard refusal == nil else { return }
            self?.onPickColour?(category, button)
        }
        return SettingsWidgets.cell(button, width: Layout.colourColumnWidth)
    }

    /// The category's budget for a day, in minutes, with 0 meaning no limit.
    ///
    /// **A `GtkSpinButton`, which is what `SteppedNumberField` is on the Mac** -- a field with a stepper, bounded by
    /// `CategoryEditRules`. The suffix is a label beside it rather than inside it, GTK having nowhere to put one.
    ///
    /// **`value-changed` fires on a typed digit as well as a pressed arrow**, so the write happens as the number
    /// settles rather than on every keystroke: GTK emits it when the value is committed -- on focus leaving, on
    /// Return, and on each arrow.
    private func limitCell(
        _ category: CategoryRecord,
        refusal: CategoryEditRules.EditRefusal?,
        help: String?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let field = gtk_spin_button_new_with_range(
            Double(CategoryEditRules.disabledDailyLimit),
            Double(CategoryEditRules.maximumDailyLimitMinutes),
            1
        )!
        SettingsWidgets.identify(field, "category-limit-\(category.id)")
        facet_spin_set_value(field, Double(category.dailyLimitMinutes))
        gtk_widget_set_sensitive(field, refusal == nil ? 1 : 0)
        gtk_widget_set_tooltip_text(field, help)
        signals.connect(field, "value-changed") { [weak self] in
            let minutes = Int(facet_spin_get_value_as_int(field))
            // The value the field already holds is not a change worth writing: GTK emits this as the row is built
            // and as a value is put back, and a write per redraw would be a `debug_log` row per redraw.
            guard minutes != category.dailyLimitMinutes else { return }
            self?.onSetDailyLimit?(category, minutes)
        }

        let cell = SettingsWidgets.row(spacing: 4)
        facet_box_pack_start(cell, field, 0, 0, 0)
        facet_box_pack_start(cell, SettingsWidgets.secondary("min"), 0, 0, 0)
        return SettingsWidgets.cell(cell, width: Layout.limitColumnWidth)
    }
}

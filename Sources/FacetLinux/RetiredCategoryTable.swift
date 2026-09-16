import CGtk
import FacetCore
import Foundation

/// The Categories tab's Inactive list: the categories that have been retired, with the name and when each last
/// recorded time.
///
/// **Its own type rather than the Active table with columns hidden**, which is how the archive drew it and how the
/// Mac draws it: two lists that answer different questions. The Active one is a record of what a category *is* --
/// its icon, its colour, its budget, all of them editable. This one is a record of what it *was*, and the only
/// question it answers is which of them to bring back.
///
/// So the icon, the colour and the daily limit are absent rather than drawn dead. A retired category is kept only so
/// historical `time_entry` rows still resolve, so those three describe a past, and showing them invites an edit that
/// means nothing.
///
/// **The Active box leads the row**, which is the archive's placement and its reasoning: in the Active list that box
/// is a column in a row full of settings, and here there are no settings, so putting it first makes it the point of
/// the row rather than something to read past.
@MainActor
final class RetiredCategoryTable {
    let widget: UnsafeMutablePointer<GtkWidget>

    private let signals = GtkSignals()

    /// When a category last recorded time. Asked per row as the list is built, so it is read at the moment it is
    /// needed rather than arriving alongside the categories and going stale between the two.
    var lastUsed: ((CategoryRecord) -> Date?)?

    var onReinstate: ((CategoryRecord) -> Void)?

    /// The same signature the Active list's rename carries, and it reaches the same handler: what a committed edit
    /// *means* is `CategoryEdits`' to decide, and it reads the record to tell an index violation from a name the
    /// table will take.
    var onRename: ((CategoryRecord, String) -> Void)?

    /// Held for the reason the Active list's are: a cell nobody keeps takes its handlers with it while its entry
    /// is still on screen. See `CategoryTable.nameCells`.
    private var nameCells: [EditableNameCell] = []

    init() {
        widget = SettingsWidgets.column()
        SettingsWidgets.identify(widget, "retired-category-table")
    }

    func show(_ categories: [CategoryRecord]) {
        for child in SettingsWidgets.children(of: widget) {
            gtk_widget_destroy(child)
        }
        signals.removeAll()
        nameCells.removeAll()

        guard !categories.isEmpty else {
            facet_box_pack_start(widget, SettingsWidgets.secondary("No inactive categories."), 0, 0, 0)
            gtk_widget_show_all(widget)
            return
        }
        facet_box_pack_start(widget, headerRow(), 0, 1, 0)
        for category in categories {
            facet_box_pack_start(widget, row(category), 0, 1, 0)
        }
        gtk_widget_show_all(widget)
    }

    /// Three captions, and the last-used one sized to its own text: it is the final column, so nothing after it has
    /// to line up.
    private func headerRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = SettingsWidgets.row()
        SettingsWidgets.identify(row, "retired-category-table-header")
        facet_box_pack_start(
            row,
            SettingsWidgets.cell(SettingsWidgets.caption("Active"), width: CategoryTable.Layout.activeColumnWidth),
            0, 0, 0
        )
        facet_box_pack_start(
            row,
            SettingsWidgets.cell(SettingsWidgets.caption("Name"), width: CategoryTable.Layout.nameColumnWidth),
            0, 0, 0
        )
        facet_box_pack_start(row, SettingsWidgets.caption(CategoryLastUsedText.columnTitle), 0, 0, 0)
        return row
    }

    /// One retired category: the box that brings it back, its name, and when it last recorded time.
    ///
    /// **Nothing here is refused by a locked face**, which is the Mac's decision and the reason it is right:
    /// reinstating puts nothing on any face, so a locked face is no bar to it as it is to retiring. A database
    /// written before any of that can have a locked face holding a retired category, and it still has to come back.
    private func row(_ category: CategoryRecord) -> UnsafeMutablePointer<GtkWidget> {
        let row = SettingsWidgets.row()
        SettingsWidgets.identify(row, "retired-category-row-\(category.id)")
        gtk_widget_set_size_request(row, -1, Int32(SettingsMetrics.rowHeight))

        let box = gtk_check_button_new()!
        SettingsWidgets.identify(box, "retired-category-active-\(category.id)")
        facet_toggle_set_active(box, 0)
        signals.connect(box, "toggled") { [weak self] in
            // One direction, this being the retired list: a box that has been ticked is a reinstatement, and one
            // going back to unticked is the list having been read again.
            guard facet_toggle_get_active(box) != 0 else { return }
            self?.onReinstate?(category)
        }
        facet_box_pack_start(row, SettingsWidgets.cell(box, width: CategoryTable.Layout.activeColumnWidth), 0, 0, 0)

        let name = EditableNameCell(name: category.name, identifier: "retired-category-name-\(category.id)")
        name.onCommit = { [weak self] typed in self?.onRename?(category, typed) }
        nameCells.append(name)
        facet_box_pack_start(
            row,
            SettingsWidgets.cell(name.widget, width: CategoryTable.Layout.nameColumnWidth),
            0, 0, 0
        )

        // **`CategoryLastUsedText` decides what this says**, including that a category with no recorded time reads
        // *Never* rather than blank: an empty cell reads as "this has not loaded", where the interesting fact is
        // that there is genuinely nothing behind the row -- which for two namesakes is the whole answer about which
        // one to bring back.
        let text = CategoryLastUsedText.label(
            isCategoryActive: category.isCategoryActive,
            lastUsed: lastUsed?(category)
        )
        if let text {
            facet_box_pack_start(row, SettingsWidgets.secondary(text), 0, 0, 0)
        }
        return row
    }
}

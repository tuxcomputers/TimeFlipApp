import CGtk
import FacetCore
import Foundation

/// The palette a category's colour is picked from, shown in a popover under its swatch.
///
/// **A list rather than a grid**, which is the archive's own split from the icon picker and its reasoning: a colour
/// has a name worth reading, where an icon is recognised by its artwork. So each row is a swatch, the colour's name,
/// and a tick on the one the category already has.
///
/// **There is no None row.** Clearing a colour is done by clicking the one already chosen, which is
/// `CategoryEditRules.colourSelection` -- the same rule, and the same reason, as the icon grid's.
@MainActor
final class ColourList {
    private enum Layout {
        /// The archive's numbers (`SettingsLayoutConstants.ColorPicker`), by way of the Mac's `ColourList.Layout`.
        static let rowSpacing = 8
        static let rowVerticalPadding = 4
        static let rowHorizontalPadding = 8
        static let listPadding = 6
    }

    private let popover: UnsafeMutablePointer<GtkWidget>
    private let signals = GtkSignals()

    /// Called with the `colour_id` to store, which is `CategoryEditRules.colourSelection`'s answer rather than the
    /// row that was clicked -- so re-picking the current colour arrives here as `0`.
    var onPick: ((Int) -> Void)?

    /// - Parameter selected: the `colour_id` the category currently has, `CategoryEditRules.noColour` for one with no
    ///   colour of its own.
    init(colours: [ColourRecord], selected selectedColourID: Int, over anchor: UnsafeMutablePointer<GtkWidget>) {
        popover = gtk_popover_new(anchor)!
        SettingsWidgets.identify(popover, "colour-list")

        // **No gap between rows**, which is the archive's: they are a list to run down rather than separate controls,
        // and the padding inside each row is what holds them apart.
        let list = SettingsWidgets.column(spacing: 0)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(list, Int32(Layout.listPadding))
        }

        for colour in colours {
            let row = self.row(colour, isSelected: colour.id == selectedColourID)
            signals.connect(row, "clicked") { [weak self] in
                guard let self else { return }
                facet_popover_popdown(popover)
                onPick?(CategoryEditRules.colourSelection(clicked: colour.id, selected: selectedColourID))
            }
            // Filled rather than sized to its own word, or every row is only as wide as its name and the list has a
            // ragged edge to click at.
            facet_box_pack_start(list, row, 0, 1, 0)
        }
        facet_container_add(popover, list)
        gtk_widget_show_all(list)
    }

    private func row(_ colour: ColourRecord, isSelected: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row(spacing: Layout.rowSpacing)
        gtk_widget_set_margin_top(line, Int32(Layout.rowVerticalPadding))
        gtk_widget_set_margin_bottom(line, Int32(Layout.rowVerticalPadding))
        gtk_widget_set_margin_start(line, Int32(Layout.rowHorizontalPadding))
        gtk_widget_set_margin_end(line, Int32(Layout.rowHorizontalPadding))
        facet_box_pack_start(line, ColourSwatch.drawingArea(colour: colour.colour, signals: signals), 0, 0, 0)
        facet_box_pack_start(line, SettingsWidgets.label(colour.name), 0, 0, 0)
        if isSelected {
            // The tick is what marks the current colour, and it goes at the far end of the row: a name followed by
            // nothing would leave a list whose rows each end in a different place.
            facet_box_pack_end(line, SettingsWidgets.secondary("\u{2713}"), 0, 0, 0)
        }

        let button = gtk_button_new()!
        facet_button_flatten(button)
        // **Named by the colour rather than by its row number**, which is what the Mac's `ColourList` does:
        // `colour-option-Red`. A check says which colour it is choosing, and a number would make it say which
        // position the colour happened to be in -- two names for one thing, and the check reads worse besides.
        SettingsWidgets.identify(button, "colour-option-\(colour.name)", saying: colour.name)
        gtk_widget_set_tooltip_text(button, isSelected ? "\(colour.name), selected" : colour.name)
        facet_container_add(button, line)
        return button
    }

    /// Puts the palette on screen under the swatch it was opened from.
    func show() {
        facet_popover_popup(popover)
    }
}

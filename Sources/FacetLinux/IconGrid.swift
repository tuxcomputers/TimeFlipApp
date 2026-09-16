import CGtk
import FacetCore
import Foundation

/// The grid of icons a category's artwork is picked from, shown in a popover under its icon.
///
/// **Six wide, which is the archive's measurement and a finding rather than a preference**: 42 icons are seeded
/// (`database/004_icon.sql`), so six columns lay them out as an even 6 by 7 with no partial last row and nothing to
/// scroll.
///
/// **There is no None cell.** Clearing an icon is done by clicking the one already chosen, which is
/// `CategoryEditRules.iconSelection` -- the same rule the previous app used, and the reason a grid of artwork does
/// not need a cell containing nothing.
///
/// **A `GtkPopover` because an `NSPopover` is what the Mac uses**, and for its reason: the grid belongs to the row
/// it was opened from, where a window would have to say which category it was for. It closes on a pick, one choice
/// being the whole of what it is for.
@MainActor
final class IconGrid {
    private enum Layout {
        /// The archive's numbers, every one of them.
        static let columns = 6
        static let cellSize = 40
        static let spacing = 10
        static let padding = 4
        static let iconSize = 24
    }

    /// The popover, kept for as long as it is up: GTK destroys a popover with the widget it hangs off, but the
    /// handlers inside it are Swift and are held here.
    private let popover: UnsafeMutablePointer<GtkWidget>
    private let signals = GtkSignals()

    /// Called with the `icon_id` to store, which is `CategoryEditRules.iconSelection`'s answer rather than the cell
    /// that was clicked -- so re-picking the current icon arrives here as `0`.
    var onPick: ((Int) -> Void)?

    /// - Parameter selected: the icon the category currently has, by filename, since that is what a `CategoryRecord`
    ///   carries.
    init(icons: [IconRecord], selected selectedIconName: String?, over anchor: UnsafeMutablePointer<GtkWidget>) {
        popover = gtk_popover_new(anchor)!
        SettingsWidgets.identify(popover, "icon-grid")
        // **Boxes of six rather than a `GtkGrid`**, which is what the Mac does with stack views and is the same
        // shape: every cell is a fixed square, so nothing needs a grid's column sizing.
        let grid = SettingsWidgets.column(spacing: Layout.spacing)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(grid, Int32(Layout.padding))
        }

        let selectedID = icons.first { $0.fileName == selectedIconName }?.id ?? CategoryEditRules.noIcon
        for start in stride(from: 0, to: icons.count, by: Layout.columns) {
            let line = SettingsWidgets.row(spacing: Layout.spacing)
            for icon in icons[start ..< min(start + Layout.columns, icons.count)] {
                let cell = self.cell(icon, isSelected: icon.fileName == selectedIconName)
                signals.connect(cell, "clicked") { [weak self] in
                    guard let self else { return }
                    facet_popover_popdown(popover)
                    onPick?(CategoryEditRules.iconSelection(clicked: icon.id, selected: selectedID))
                }
                facet_box_pack_start(line, cell, 0, 0, 0)
            }
            facet_box_pack_start(grid, line, 0, 0, 0)
        }
        facet_container_add(popover, grid)
        gtk_widget_show_all(grid)
    }

    /// One icon as a cell of the grid. The artwork is drawn in the colour the popover draws text in, which is
    /// `ActivityIcon`'s decision and is read from the cell rather than fixed.
    private func cell(_ icon: IconRecord, isSelected: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        SettingsWidgets.identify(button, "icon-cell-\(icon.fileName)")
        gtk_widget_set_size_request(button, Int32(Layout.cellSize), Int32(Layout.cellSize))
        gtk_widget_set_tooltip_text(button, isSelected ? "\(icon.name), selected" : icon.name)
        // The current icon keeps its frame and the rest lose theirs, which is this platform's spelling of the
        // archive's heavier outline on the selected cell.
        if !isSelected { facet_button_flatten(button) }
        if let image = ActivityIcon.image(
            named: icon.fileName,
            size: Layout.iconSize,
            colour: SettingsWidgets.foreground(of: button)
        ) {
            facet_container_add(button, image)
        } else {
            // **Named rather than blank**, because a cell with nothing in it is a cell nobody can tell from a gap:
            // the artwork is missing, and the icon is still pickable.
            facet_container_add(button, SettingsWidgets.label(icon.name))
        }
        return button
    }

    /// Puts the grid on screen under the cell it was opened from.
    func show() {
        facet_popover_popup(popover)
    }
}

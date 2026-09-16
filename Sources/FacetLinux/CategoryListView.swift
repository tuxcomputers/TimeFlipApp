import CGtk
import FacetCore
import Foundation

/// The Faces tab's pick list: one row per category, a colour swatch holding the icon, the name beside it, on a
/// rounded panel.
///
/// **A different list from the Categories tab's**, deliberately, and the split is the archive's: that one is a
/// record of what a category *is*, in columns that line up down the tab; this one is a control -- the whole row is
/// the button, and clicking it is how a category is picked. What that *means* is `FaceEdits`'.
///
/// **A refusal is drawn, not only logged.** `allowPicking` is what makes a click the app is going to refuse look
/// refused: a locked face or a cube the app has not found yet otherwise produces a log row and nothing on screen at
/// all, which reads as a list that has stopped responding. `FacesTabRules` decides, and the pane asks it the same
/// question here and at the click.
@MainActor
final class CategoryListView {
    enum Layout {
        /// The previous app's numbers, each arrived at against real artwork: a 36pt row, a 28pt swatch sized to
        /// clear the 20pt icon while still fitting the row, and 12pt between the swatch and the name.
        static let rowHeight = 36
        static let iconSize = 20
        static let swatchSize = 28
        static let swatchCornerRadius: CGFloat = 6
        static let rowSpacing = 12
        static let horizontalPadding = 8
    }

    let widget: UnsafeMutablePointer<GtkWidget>

    private let rows: UnsafeMutablePointer<GtkWidget>
    private let signals = GtkSignals()

    /// Called with the category whose row was clicked.
    var onSelect: ((CategoryRecord) -> Void)?

    /// The row buttons on show, so a refusal can be drawn over them without rebuilding the list.
    private var rowButtons: [UnsafeMutablePointer<GtkWidget>] = []

    init() {
        rows = SettingsWidgets.column(spacing: 0)
        widget = SettingsWidgets.styled(rows, SettingsWidgets.panelClass)
        SettingsWidgets.identify(widget, "category-list")
    }

    /// Replaces the list with `categories`. Rebuilt rather than diffed, like every list here.
    func show(_ categories: [CategoryRecord]) {
        for child in SettingsWidgets.children(of: rows) {
            gtk_widget_destroy(child)
        }
        signals.removeAll()
        rowButtons.removeAll()

        guard !categories.isEmpty else {
            facet_box_pack_start(rows, SettingsWidgets.secondary("No categories yet."), 0, 0, 0)
            gtk_widget_show_all(rows)
            return
        }
        for category in categories {
            let button = row(category)
            rowButtons.append(button)
            facet_box_pack_start(rows, button, 0, 1, 0)
        }
        gtk_widget_show_all(rows)
    }

    /// Whether a click on a row would do anything, drawn as the rows being live or dead.
    ///
    /// **Applied after every `show`**, since that rebuilds the rows: a state held only in the widgets would be
    /// thrown away by the next redraw, which happens on every flip of the cube.
    func allowPicking(_ allowed: Bool) {
        for button in rowButtons {
            gtk_widget_set_sensitive(button, allowed ? 1 : 0)
        }
    }

    private func row(_ category: CategoryRecord) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row(spacing: Layout.rowSpacing)
        gtk_widget_set_margin_start(line, Int32(Layout.horizontalPadding))
        gtk_widget_set_margin_end(line, Int32(Layout.horizontalPadding))
        facet_box_pack_start(line, swatch(category), 0, 0, 0)
        facet_box_pack_start(line, SettingsWidgets.label(category.name), 0, 1, 0)

        let button = gtk_button_new()!
        facet_button_flatten(button)
        SettingsWidgets.identify(button, "category-row-\(category.id)", saying: category.name)
        gtk_widget_set_size_request(button, -1, Int32(Layout.rowHeight))
        facet_container_add(button, line)
        signals.connect(button, "clicked") { [weak self] in self?.onSelect?(category) }
        return button
    }

    /// The colour with the icon on it, or a hollow outline for a category with neither.
    ///
    /// **The outline replaces the colour rather than sitting on it**, which is how the previous app drew it: with no
    /// glyph to see through, a filled swatch would just be a coloured square meaning nothing.
    ///
    /// **The icon takes the colour of the swatch it is on**, white where the colour is dark enough to swallow black
    /// lines. That is `usesWhiteLines`, which comes off the colour's own row rather than being worked out here.
    private func swatch(_ category: CategoryRecord) -> UnsafeMutablePointer<GtkWidget> {
        let area = gtk_drawing_area_new()!
        gtk_widget_set_size_request(area, Int32(Layout.swatchSize), Int32(Layout.swatchSize))
        gtk_widget_set_valign(area, GTK_ALIGN_CENTER)

        guard let iconName = category.iconName else {
            let ink = SettingsWidgets.foreground(of: area)
            signals.connectDraw(area) { context in
                guard let context else { return }
                facet_draw_swatch(
                    context, Double(Layout.swatchSize), Double(Layout.swatchCornerRadius),
                    Double(ink.red), Double(ink.green), Double(ink.blue), 0
                )
            }
            return area
        }

        let holder = gtk_overlay_new()!
        gtk_widget_set_size_request(holder, Int32(Layout.swatchSize), Int32(Layout.swatchSize))
        gtk_widget_set_valign(holder, GTK_ALIGN_CENTER)
        if let colour = category.colour {
            signals.connectDraw(area) { context in
                guard let context else { return }
                facet_draw_swatch(
                    context, Double(Layout.swatchSize), Double(Layout.swatchCornerRadius),
                    colour.red, colour.green, colour.blue, 1
                )
            }
        }
        facet_container_add(holder, area)
        if let icon = ActivityIcon.image(
            named: iconName,
            size: Layout.iconSize,
            colour: category.usesWhiteLines ? .white : .black
        ) {
            gtk_widget_set_halign(icon, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
            facet_overlay_add(holder, icon)
        }
        return holder
    }
}

extension GdkRGBA {
    /// The two colours a category's artwork is ever drawn in, which `CategoryRecord.usesWhiteLines` chooses between.
    /// Fixed rather than read from the theme: what they have to contrast with is the category's own colour under
    /// them, not the window behind it.
    static let white = GdkRGBA(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = GdkRGBA(red: 0, green: 0, blue: 0, alpha: 1)
}

import CGtk
import FacetCore
import Foundation

/// A category's colour as a small rounded square, and the absence of one as a hollow outline.
///
/// **Hollow rather than a grey fill, which is the archive's distinction and worth keeping**: grey is a colour in the
/// palette (`database/005_colour.sql`), so filling with it would say the category is grey when the truth is that
/// nobody has chosen.
///
/// **Drawn rather than styled**, which is the one place this window departs from CSS. Everything else a section or a
/// row is drawn with is a style class, because a class named once is what makes the tabs one look; a swatch's colour
/// comes out of the `colour` table per row, and a stylesheet would mean a generated class name per palette entry.
@MainActor
enum ColourSwatch {
    /// The archive's numbers, by way of the Mac's `CategoryTable.Layout`.
    private static let size: CGFloat = 14
    private static let cornerRadius: CGFloat = 3

    /// One swatch as a drawing area. `nil` for a category with no colour, which draws the outline alone.
    ///
    /// **The handlers are the caller's to hold**, which is why `signals` is passed in rather than made here: a
    /// drawing handler released while its widget is still on screen is a redraw that reaches a pointer to nothing,
    /// so the collection has to live as long as the list the swatch is in.
    static func drawingArea(
        colour: Colour?,
        signals: GtkSignals
    ) -> UnsafeMutablePointer<GtkWidget> {
        let area = gtk_drawing_area_new()!
        gtk_widget_set_size_request(area, Int32(size), Int32(size))
        gtk_widget_set_valign(area, GTK_ALIGN_CENTER)
        signals.connectDraw(area) { context in
            guard let context else { return }
            if let colour {
                facet_draw_swatch(
                    context, Double(size), Double(cornerRadius),
                    colour.red, colour.green, colour.blue, 1
                )
            } else {
                // The outline is drawn in the colour text is drawn in, so "nobody has chosen" reads the same way in
                // a light theme and a dark one.
                let ink = SettingsWidgets.foreground(of: area)
                facet_draw_swatch(
                    context, Double(size), Double(cornerRadius),
                    Double(ink.red), Double(ink.green), Double(ink.blue), 0
                )
            }
        }
        return area
    }
}

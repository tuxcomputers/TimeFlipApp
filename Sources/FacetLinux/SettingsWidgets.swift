import CGtk
import FacetCore
import Foundation

/// The pieces every Settings tab is built out of: a label, a caption, a fixed-width cell, a row, and the app's
/// stylesheet.
///
/// **It decides nothing except how a number from `SettingsMetrics` reaches GTK.** Every measurement here is read
/// from that module, which is the core's and is where the look of a tab is settled -- `rowHeight` is the point of
/// reference, and changing it has to move every tab on both platforms. A number written down in this file would be
/// the third copy of a decision that already cost two tabs being measured by eye (see `CLAUDE.md`, *A tab's content
/// spans the width of the window*).
///
/// **The tint and the corners are CSS**, because that is GTK's answer to both, where the Mac draws an `NSBox`. One
/// stylesheet for the app rather than a provider per widget: a class named once and applied is what makes the three
/// tabs one look, and it is the same argument `SettingsMetrics` makes about the numbers.
@MainActor
enum SettingsWidgets {
    /// The class a section's panel carries. Named for what it is rather than for the colour it happens to be.
    static let panelClass = "facet-panel"

    /// The class a caption over a column carries: the smaller, dimmer text naming what is under it.
    static let captionClass = "facet-caption"

    /// The class a borderless button carries: no padding of its own, so what is in it starts where its column
    /// does. **Measured rather than assumed** (2026-09-16): GTK's default button padding put every category name
    /// 25px to the right of the *Name* caption above it, which is the column alignment `CategoryTable.Layout`
    /// exists to hold.
    static let flatClass = "facet-flat"

    /// The class a reading that is not a control carries -- a date, a total -- which is the same dimming without the
    /// smaller size.
    static let secondaryClass = "facet-secondary"

    /// The app's stylesheet, installed once.
    ///
    /// **`alpha(@theme_fg_color, ...)` rather than a grey**, which is the GTK spelling of what `quaternarySystemFill`
    /// does on the Mac: it resolves against whatever theme is on, so a panel is a shade darker than the window in a
    /// light theme and a shade lighter in a dark one. A fixed colour here would be a panel that disappears under half
    /// the desktops this app can run on.
    private static var stylesheet: String {
        """
        .\(panelClass) {
            background-color: alpha(@theme_fg_color, 0.06);
            border-radius: \(Int(SettingsMetrics.cornerRadius))px;
            padding: \(Int(SettingsMetrics.panelPadding))px;
        }
        .\(flatClass) {
            padding: 0;
            min-height: 0;
            min-width: 0;
            border: none;
        }
        .\(captionClass) {
            font-size: smaller;
            color: alpha(@theme_fg_color, 0.65);
        }
        .\(secondaryClass) {
            color: alpha(@theme_fg_color, 0.65);
        }
        """
    }

    /// Loads the stylesheet for the whole screen. Called once, from the window's first open.
    ///
    /// **Reports rather than assumes**, which is the shim's own doing: a stylesheet that failed to parse leaves every
    /// panel untinted, and that is a fault to hear about now rather than to notice as "the window looks wrong" later.
    static func installStyles(debugLog: DebugLog?) {
        guard let failure = facet_style_add(stylesheet) else { return }
        debugLog?.record(.tab, "The Settings stylesheet was refused: \(String(cString: failure))")
        g_free(failure)
    }

    static func styled(_ widget: UnsafeMutablePointer<GtkWidget>, _ name: String) -> UnsafeMutablePointer<GtkWidget> {
        gtk_style_context_add_class(gtk_widget_get_style_context(widget), name)
        return widget
    }

    // MARK: - naming a control

    /// Names a control, for CSS and for whatever is driving the app.
    ///
    /// **Two names, set together, because they are two different things and both are needed.**
    /// `gtk_widget_set_name` is the one a stylesheet matches; the *accessible* name is the one a check finds a
    /// control by, and `docs/linux-port.md` records it measured: AT-SPI's `name` is ATK's, a locator is one tree
    /// walk comparing it, and nothing else about a widget crosses. Setting one and not the other is how a control
    /// comes to be unreachable while looking named in the source.
    ///
    /// The same pairing the Mac makes, where `identifier` and `setAccessibilityIdentifier` are both set on every
    /// control for the same reason.
    /// - Parameter value: what the control *says*, for a control whose own text is a value the app wrote. It
    ///   becomes the accessible description, because the name is the identifier and a `GtkButton` has only those
    ///   two: a category name cell with neither set answers nothing at all. Leave it off wherever the label is
    ///   fixed wording, which reads back as text without help.
    static func identify(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ name: String,
        saying value: String? = nil
    ) {
        gtk_widget_set_name(widget, name)
        facet_set_accessible_name(widget, name)
        if let value {
            facet_set_accessible_description(widget, value)
        }
    }

    // MARK: - text

    /// A label, left-aligned in whatever room it is given: a caption over a column has to start where the column
    /// does, and GTK centres a label that is not told otherwise.
    ///
    /// **Ellipsised**, rather than allowed to widen the row: the window is one width, so a long name has to give way
    /// somewhere, and a truncated name in a column that stays put reads better than a table that shifts.
    static func label(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = plainLabel(text)
        facet_label_ellipsize_end(label)
        return label
    }

    /// A label that keeps its whole text whatever room it is in.
    ///
    /// **What it is for is a tab**, and it is measured rather than defensive (2026-09-16): a notebook sizes its tab
    /// to its label, so a label that has already agreed to shorten itself has nothing to hold the tab open, and
    /// *Categories* came out as a tab reading `...`.
    static func plainLabel(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = gtk_label_new(text)!
        facet_label_set_xalign(label, 0)
        return label
    }

    /// A column's caption: what the archive drew over each column of the Categories tab, smaller and dimmer than the
    /// rows under it.
    static func caption(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        styled(label(text), captionClass)
    }

    /// A reading rather than a control, drawn dimmer. The Inactive list's dates are these.
    static func secondary(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        styled(label(text), secondaryClass)
    }

    // MARK: - boxes

    /// A row of columns, at the spacing every tab holds its columns apart by.
    static func row(spacing: Int = Int(SettingsMetrics.columnSpacing)) -> UnsafeMutablePointer<GtkWidget> {
        gtk_box_new(GTK_ORIENTATION_HORIZONTAL, Int32(spacing))!
    }

    /// A stack of rows, at the spacing every tab holds its rows apart by. **Whitespace and never a line**: the
    /// Categories tab has never drawn a separator and reads as a list regardless, which is the decision
    /// `SettingsMetrics.rowSpacing` carries.
    static func column(spacing: Int = Int(SettingsMetrics.rowSpacing)) -> UnsafeMutablePointer<GtkWidget> {
        gtk_box_new(GTK_ORIENTATION_VERTICAL, Int32(spacing))!
    }

    /// Holds a control's column open at a fixed width, so the column after it starts at the same x on every row.
    ///
    /// The archive's reason for fixing them at all, carried over from `CategoryTable.Layout`: a label sized to its
    /// own content would put the next column at a different x on every row.
    static func cell(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        width: CGFloat
    ) -> UnsafeMutablePointer<GtkWidget> {
        let cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_set_size_request(cell, Int32(width), -1)
        // Not expanded: the width request is the column, and a child that grew into spare room would take the
        // column with it.
        facet_box_pack_start(cell, widget, 0, 1, 0)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        return cell
    }

    /// Room at the far end of a row, so what follows is pushed to the edge. A box with nothing in it, which is what
    /// the Mac's `spacer` is for the same purpose.
    static func spacer() -> UnsafeMutablePointer<GtkWidget> {
        gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
    }

    // MARK: - buttons

    /// A button that draws only what is put in it: no frame and no relief, which is what makes an icon or a swatch
    /// clickable without reading as a control in a column of readings.
    static func flatButton(_ child: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        facet_button_flatten(button)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        facet_container_add(button, child)
        return styled(button, flatClass)
    }

    // MARK: - taking a list apart again

    /// What a container currently holds.
    ///
    /// **Every list in this window rebuilds rather than diffing**, so this is how the old rows are found to be
    /// destroyed. `g_list_free` rather than `g_list_free_full`: the list is ours to free and the widgets in it are
    /// not -- destroying them is the caller's decision, and one of them may be being kept.
    static func children(of container: UnsafeMutablePointer<GtkWidget>) -> [UnsafeMutablePointer<GtkWidget>] {
        guard let list = facet_container_children(container) else { return [] }
        defer { g_list_free(list) }
        var found: [UnsafeMutablePointer<GtkWidget>] = []
        var node: UnsafeMutablePointer<GList>? = list
        while let current = node {
            if let data = current.pointee.data {
                found.append(data.assumingMemoryBound(to: GtkWidget.self))
            }
            node = current.pointee.next
        }
        return found
    }

    // MARK: - colours

    /// The colour this widget's theme draws text in, which is what the artwork in a row is drawn in too.
    ///
    /// Read from the widget rather than decided here, for the reason the Mac uses `.labelColor` instead of black:
    /// the panel is a colour that resolves as it draws, so an ink colour fixed in the source is one that disappears
    /// into it under half the themes this app can run on.
    static func foreground(of widget: UnsafeMutablePointer<GtkWidget>) -> GdkRGBA {
        let context = gtk_widget_get_style_context(widget)
        var colour = GdkRGBA()
        gtk_style_context_get_color(context, gtk_style_context_get_state(context), &colour)
        return colour
    }
}

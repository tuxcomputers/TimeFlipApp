import CGtk
import FacetCore
import Foundation

/// A section of a Settings tab that folds away on its own tinted panel: a triangle and a heading, with whatever the
/// section holds under them.
///
/// **The same shape as `PanelSection` on the Mac, which is the point.** The heading sits *on* the panel as the first
/// row of it and folding shuts the panel around the heading, which is `CLAUDE.md`'s rule for a collapsible group
/// that has a panel of its own -- a heading floating above a panel it folds reads as a caption rather than as the
/// control it is. Two things follow, both of which have already gone wrong once on the other platform: what is
/// inside the panel must not draw a panel of its own, and hiding the contents is not folding them.
///
/// **A `GtkExpander`, which answers both of those for free.** Its triangle and heading are one widget, its
/// allocation shrinks to the title row when it is collapsed, and the panel style class is on the expander itself --
/// so the tint closes around the heading rather than leaving an empty box. The Mac has to swap two sets of
/// constraints to get the second of those, Auto Layout not caring that a view is hidden.
///
/// **The whole heading line is the target**, which `CLAUDE.md` requires and GTK gives on one condition: the label
/// has to be a widget filling the title row rather than a string GTK sizes to its text. `facet_expander_set_label_widget`
/// is that, and it is why there is a shim for a two-line call.
///
/// **Nothing here restores a default fold**, which the Mac's `PanelSection` has to: its panes are made once and
/// reused, so a section left open stays open into the next Settings window. This window is built on each open and
/// destroyed on each close, so a fresh section starts at its default because it is fresh.
///
/// **What it does not have is the Mac's `Metrics`.** That exists there because the App tab used to inset its rows
/// differently; every tab takes the same inset now, so there is one set of numbers and they are read from
/// `SettingsMetrics`.
@MainActor
final class PanelSection {
    /// What the heading says, for a caller that logs a fold and would otherwise be holding the same string twice.
    let title: String

    /// The expander, which is the panel as well: the style class is on it, so folding takes the tint with it.
    let widget: UnsafeMutablePointer<GtkWidget>

    /// Whether what sits under the heading is on show. **Read from GTK rather than remembered**, which is the first
    /// rule pointed at a widget: the expander is what the fold *is*, and a copy here could disagree with it.
    var isExpanded: Bool { facet_expander_get_expanded(widget) != 0 }

    /// Called when somebody presses the heading, with the fold it has moved to.
    ///
    /// **One callback rather than the Mac's two.** There it has `onToggle` for a press and `onExpandedChanged` for
    /// every path, because the window puts every section back to its default on each open and something drawn from
    /// the fold has to follow that too. Nothing puts a fold back here -- a closed window is a destroyed one -- so
    /// the two questions have one answer, and a second callback would be a distinction with nothing behind it.
    var onToggle: ((Bool) -> Void)?

    private final class Handler {
        let run: (Bool) -> Void
        init(_ run: @escaping (Bool) -> Void) { self.run = run }
    }

    /// Kept alive for as long as the section: the handler crosses into C as an `Unmanaged` pointer, which carries no
    /// ownership of its own.
    private var handler: Handler?

    init(
        title: String,
        identifier: String,
        isExpanded: Bool,
        content: UnsafeMutablePointer<GtkWidget>
    ) {
        self.title = title
        widget = gtk_expander_new(nil)!
        // **The name a check addresses it by**, which on this platform is the widget name rather than an
        // `AXIdentifier`: `Tests/Methods.md` Method 15 reads `name` off an AT-SPI node and GTK answers it with this.
        SettingsWidgets.identify(widget, identifier)
        _ = SettingsWidgets.styled(widget, SettingsWidgets.panelClass)

        // The heading, as a widget so the whole line is the target. Bold, which is what a section heading is on both
        // platforms, and set through markup because GTK has no weight property on a label.
        let heading = gtk_label_new(nil)!
        facet_label_set_markup(heading, "<b>\(Self.escaped(title))</b>")
        facet_label_set_xalign(heading, 0)
        facet_expander_set_label_widget(widget, heading)

        // Inside the panel, under the heading: `headingSpacing` between the heading line and what folds away, and
        // the panel's own padding around the rest, which the stylesheet applies.
        gtk_widget_set_margin_top(content, Int32(SettingsMetrics.headingSpacing))
        facet_container_add(widget, content)
        facet_expander_set_expanded(widget, isExpanded ? 1 : 0)

        // **The expander's own `activate`, which is emitted when the fold moves.** Read back from the widget rather
        // than toggled here: GTK has already changed it by the time this arrives, and a handler that flipped a copy
        // would be the copy that can disagree.
        let handler = Handler { [weak self] expanded in
            self?.onToggle?(expanded)
        }
        self.handler = handler
        facet_on(widget, "activate", { widget, data in
            guard let data, let widget else { return }
            MainActor.assumeIsolated {
                let handler = Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue()
                handler.run(facet_expander_get_expanded(widget) != 0)
            }
        }, Unmanaged.passUnretained(handler).toOpaque())
    }

    /// Pango markup is XML, so a title carrying an ampersand would be a heading GTK refuses to parse and draws as
    /// nothing at all. None of the app's five titles has one; escaping them anyway is what stops the sixth being a
    /// blank heading nobody can explain.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

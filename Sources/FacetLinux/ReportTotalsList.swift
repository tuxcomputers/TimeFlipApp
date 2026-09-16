import CGtk
import FacetCore
import Foundation

/// What the picked range came to: two column headings that sort, then one folding group per category.
///
/// **Only the categories that recorded something appear.** A row of zeroes is not an answer somebody asked for, and
/// the question was "what did I spend the time on", not "what categories exist".
///
/// **Each group is closed, and opening one is what reads its entries.** The totals are the answer to the range; the
/// entries are the working, and nobody wants twelve categories' working on screen at once -- so a closed group costs
/// no query at all. That is `ReportReadout.entries(for:start:end:)`, asked at the moment the fold opens and against
/// the range on screen at that moment, so the rows add up to the figure above them.
///
/// **The whole heading line is the target**, which is `CLAUDE.md`'s rule for a collapsible group -- and this is its
/// second case: a group with no panel of its own, where the heading is a row of the list it belongs to. What
/// survives from the panel case is that the line folds and that folding takes the space back rather than hiding what
/// was in it.
@MainActor
final class ReportTotalsList {
    private enum Layout {
        static let rowHeight = CategoryListView.Layout.rowHeight
        static let entryHeight = 24
        static let toggleWidth = 16
        /// The stretches line up under the name rather than under the triangle, so a group reads as one thing
        /// indented rather than as two lists.
        static let entryIndent = toggleWidth + CategoryListView.Layout.horizontalPadding
            + CategoryListView.Layout.swatchSize + CategoryListView.Layout.rowSpacing
        static let dateWidth = 52
        static let clockWidth = 68
        static let headerHeight = 24
    }

    let widget: UnsafeMutablePointer<GtkWidget>

    /// The order in force, which the headings show and every draw obeys.
    private(set) var order = ReportSortRules.Order.initial

    /// The stretches behind one category, asked for as a group opens.
    var entries: ((CategoryTotal) -> [TimeEntryRecord])?

    /// Called when a heading is clicked, so the window can record what was asked for.
    var onSort: ((ReportSortRules.Order) -> Void)?

    /// Called as a group opens or closes, for the same reason.
    var onToggle: ((CategoryTotal, Bool) -> Void)?

    private let header: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private var signals = GtkSignals()

    /// What `show` was last given, so a heading click can re-order without going back to the database.
    ///
    /// **Not a cached table.** It is the answer to a question somebody asked, held for as long as that question is
    /// on screen -- and re-sorting it is rearranging what was already read rather than asking again.
    private var shown: [CategoryTotal] = []
    private var showingSeconds = true

    /// Which groups are open, by category, so a redraw does not shut what somebody opened.
    ///
    /// **Re-read when it reopens**, which is the point: the figures above the entries have just been summed again,
    /// so the rows under them are asked for again too.
    private var opened: Set<Int> = []

    init() {
        widget = SettingsWidgets.column(spacing: Int(SettingsMetrics.rowSpacing))
        header = SettingsWidgets.row(spacing: 0)
        list = SettingsWidgets.column(spacing: 0)
        SettingsWidgets.identify(list, "report-totals")
        _ = SettingsWidgets.styled(list, SettingsWidgets.panelClass)
        facet_box_pack_start(widget, header, 0, 1, 0)
        facet_box_pack_start(widget, list, 0, 1, 0)
        drawHeader()
    }

    /// Draws what the range came to.
    func show(_ totals: [CategoryTotal], showingSeconds: Bool) {
        shown = totals
        self.showingSeconds = showingSeconds
        // Groups for categories that are no longer in the answer are forgotten rather than left open for a range
        // they are not in.
        opened.formIntersection(Set(totals.map(\.categoryID)))
        redraw()
    }

    private func redraw() {
        for child in SettingsWidgets.children(of: list) {
            gtk_widget_destroy(child)
        }
        signals = GtkSignals()
        drawHeader()

        guard !shown.isEmpty else {
            let empty = SettingsWidgets.secondary("Nothing was recorded in this range.")
            SettingsWidgets.identify(empty, "report-totals-empty", saying: "Nothing was recorded in this range.")
            facet_box_pack_start(list, empty, 0, 0, 0)
            gtk_widget_show_all(widget)
            return
        }
        for total in ReportSortRules.sorted(shown, by: order) {
            facet_box_pack_start(list, group(total), 0, 1, 0)
        }
        gtk_widget_show_all(widget)
    }

    /// The two column headings, above the list so they stay put.
    ///
    /// **The whole heading is the target**, not the arrow in it, which is the same reasoning as every other
    /// collapsible heading in this app: a small target for an obvious gesture reads as a control that is broken.
    /// What the arrow says, and what a click does to the order, are `ReportSortRules`'.
    private func drawHeader() {
        for child in SettingsWidgets.children(of: header) {
            gtk_widget_destroy(child)
        }
        facet_box_pack_start(header, sortButton("Category", column: .category, identifier: "report-sort-category"), 1, 1, 0)
        facet_box_pack_start(header, sortButton("Time", column: .time, identifier: "report-sort-time"), 0, 0, 0)
    }

    private func sortButton(
        _ title: String,
        column: ReportSortRules.Column,
        identifier: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let heading = ReportSortRules.heading(title, sortColumnState: column, order: order)
        let button = gtk_button_new_with_label(heading)!
        facet_button_flatten(button)
        gtk_widget_set_size_request(button, -1, Int32(Layout.headerHeight))
        SettingsWidgets.identify(button, identifier, saying: heading)
        signals.connect(button, "clicked") { [weak self] in
            guard let self else { return }
            order = ReportSortRules.next(after: order, clicking: column)
            onSort?(order)
            // Re-ordered rather than re-read: the answer on screen is the answer to the same question, asked
            // differently.
            redraw()
        }
        return button
    }

    /// One category: a heading line carrying its swatch, its name and its total, with its stretches folded away.
    private func group(_ total: CategoryTotal) -> UnsafeMutablePointer<GtkWidget> {
        let isOpen = opened.contains(total.categoryID)
        let box = SettingsWidgets.column(spacing: 0)
        SettingsWidgets.identify(box, "report-total-\(total.categoryID)")

        let line = SettingsWidgets.row(spacing: CategoryListView.Layout.rowSpacing)
        gtk_widget_set_margin_start(line, Int32(CategoryListView.Layout.horizontalPadding))
        gtk_widget_set_margin_end(line, Int32(CategoryListView.Layout.horizontalPadding))
        let triangle = SettingsWidgets.plainLabel(isOpen ? "\u{25BE}" : "\u{25B8}")
        gtk_widget_set_size_request(triangle, Int32(Layout.toggleWidth), -1)
        facet_box_pack_start(line, triangle, 0, 0, 0)
        facet_box_pack_start(line, swatch(total), 0, 0, 0)
        facet_box_pack_start(line, SettingsWidgets.label(total.name), 0, 1, 0)
        let figure = SettingsWidgets.label(ReportEntryText.duration(total.seconds, showingSeconds: showingSeconds))
        SettingsWidgets.identify(
            figure,
            "report-total-\(total.categoryID)-duration",
            saying: ReportEntryText.duration(total.seconds, showingSeconds: showingSeconds)
        )
        facet_box_pack_end(line, figure, 0, 0, 0)

        let heading = gtk_button_new()!
        facet_button_flatten(heading)
        gtk_widget_set_size_request(heading, -1, Int32(Layout.rowHeight))
        SettingsWidgets.identify(heading, "report-total-\(total.categoryID)-heading", saying: total.name)
        facet_container_add(heading, line)
        signals.connect(heading, "clicked") { [weak self] in
            guard let self else { return }
            if opened.contains(total.categoryID) {
                opened.remove(total.categoryID)
            } else {
                opened.insert(total.categoryID)
            }
            onToggle?(total, opened.contains(total.categoryID))
            redraw()
        }
        facet_box_pack_start(box, heading, 0, 1, 0)

        guard isOpen else { return box }
        // **Read as it opens**, against the range on screen at that moment.
        for entry in entries?(total) ?? [] {
            facet_box_pack_start(box, row(entry), 0, 1, 0)
        }
        return box
    }

    /// One stretch: the day, the clock times it ran between, and how long that was.
    private func row(_ entry: TimeEntryRecord) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row(spacing: 6)
        gtk_widget_set_margin_start(line, Int32(Layout.entryIndent))
        gtk_widget_set_margin_end(line, Int32(CategoryListView.Layout.horizontalPadding))
        gtk_widget_set_size_request(line, -1, Int32(Layout.entryHeight))
        SettingsWidgets.identify(line, "report-entry-\(entry.timeEntryID)", saying: ReportEntryText.spoken(entry, showingSeconds: showingSeconds))

        facet_box_pack_start(line, figure(ReportEntryText.date(entry.start), width: Layout.dateWidth), 0, 0, 0)
        facet_box_pack_start(
            line,
            figure(ReportEntryText.clock(entry.start, showingSeconds: showingSeconds), width: Layout.clockWidth),
            0, 0, 0
        )
        facet_box_pack_start(line, SettingsWidgets.secondary("\u{2013}"), 0, 0, 0)
        facet_box_pack_start(
            line,
            figure(ReportEntryText.clock(entry.end, showingSeconds: showingSeconds), width: Layout.clockWidth),
            0, 0, 0
        )
        facet_box_pack_end(
            line,
            SettingsWidgets.secondary(ReportEntryText.duration(entry.seconds, showingSeconds: showingSeconds)),
            0, 0, 0
        )
        return line
    }

    private func figure(_ text: String, width: Int) -> UnsafeMutablePointer<GtkWidget> {
        let label = SettingsWidgets.secondary(text)
        gtk_widget_set_size_request(label, Int32(width), -1)
        return label
    }

    /// The same swatch the Faces tab's pick list draws, at the same size and from the same two fields: a category
    /// looks like itself wherever it appears.
    private func swatch(_ total: CategoryTotal) -> UnsafeMutablePointer<GtkWidget> {
        let area = gtk_drawing_area_new()!
        let size = CategoryListView.Layout.swatchSize
        gtk_widget_set_size_request(area, Int32(size), Int32(size))
        gtk_widget_set_valign(area, GTK_ALIGN_CENTER)
        let outline = SettingsWidgets.foreground(of: area)
        signals.connectDraw(area) { context in
            guard let context else { return }
            if let colour = total.colour {
                facet_draw_swatch(
                    context, Double(size), Double(CategoryListView.Layout.swatchCornerRadius),
                    colour.red, colour.green, colour.blue, 1
                )
            } else {
                facet_draw_swatch(
                    context, Double(size), Double(CategoryListView.Layout.swatchCornerRadius),
                    Double(outline.red), Double(outline.green), Double(outline.blue), 0
                )
            }
        }
        guard let iconName = total.iconName,
              let icon = ActivityIcon.image(
                  named: iconName,
                  size: CategoryListView.Layout.iconSize,
                  colour: total.usesWhiteLines ? .white : .black
              )
        else {
            return area
        }
        let holder = gtk_overlay_new()!
        gtk_widget_set_valign(holder, GTK_ALIGN_CENTER)
        facet_container_add(holder, area)
        gtk_widget_set_halign(icon, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
        facet_overlay_add(holder, icon)
        return holder
    }
}

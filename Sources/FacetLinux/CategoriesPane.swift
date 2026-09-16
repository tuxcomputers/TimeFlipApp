import CGtk
import FacetCore
import Foundation

/// The Categories tab: the categories themselves, as opposed to which of them is being timed.
///
/// **Laid out as the Mac lays it out**, which is how the previous app laid this window out: two sections, Active then
/// Inactive, each folding away behind its own heading -- Active open, because it is the one somebody works in, and
/// Inactive closed, because it is an archive to go looking in occasionally. The create control sits between them,
/// which is where the archive put it: in the gap rather than inside either list, so it belongs to the tab and not to
/// one section of it.
///
/// **It reads the tables and it draws. What a gesture *means* is `CategoryEdits`'**, which is core and is the same
/// module the Mac's Categories tab will call: the icon, the colour, the name, the limit, retiring, reinstating and
/// creating are one sequence each, written once, and every one of them is covered by `CategoryEditsTests` with no
/// window at all.
///
/// **The lists are read here rather than handed in**, and read again whenever an edit changes what belongs in them.
/// That is `CLAUDE.md`'s first rule and its own exception: the open Settings window may hold a *setting* it is
/// showing, and a list is not a setting -- which rows belong in it is a different question from what a value is.
/// This tab holds no settings at all, so there is nothing here to hold.
@MainActor
final class CategoriesPane {
    let widget: UnsafeMutablePointer<GtkWidget>

    private let categories: CategoryStore
    private let faces: FaceStore
    private let icons: IconStore
    private let colours: ColourStore
    private let entries: TimeEntryStore
    private let edits: CategoryEdits
    private let debugLog: DebugLog?

    private let activeTable = CategoryTable()
    private let retiredTable = RetiredCategoryTable()
    private let createControl = CategoryCreateControl()
    private let activeSection: PanelSection
    private let inactiveSection: PanelSection

    /// The picker that is up, kept alive while it is: a popover is a GTK object the anchor does not own, so letting
    /// this go closes a grid somebody is looking at.
    private var iconPicker: IconGrid?
    private var colourPicker: ColourList?

    init(
        categories: CategoryStore,
        faces: FaceStore,
        icons: IconStore,
        colours: ColourStore,
        entries: TimeEntryStore,
        edits: CategoryEdits,
        debugLog: DebugLog?
    ) {
        self.categories = categories
        self.faces = faces
        self.icons = icons
        self.colours = colours
        self.entries = entries
        self.edits = edits
        self.debugLog = debugLog

        activeSection = PanelSection(
            title: "Active",
            identifier: "categories-active-section",
            isExpanded: true,
            content: activeTable.widget
        )
        inactiveSection = PanelSection(
            title: "Inactive",
            identifier: "categories-inactive-section",
            isExpanded: false,
            content: retiredTable.widget
        )

        widget = SettingsWidgets.column(spacing: Int(SettingsMetrics.sectionSpacing))
        SettingsWidgets.identify(widget, SettingsTab.categories.paneIdentifier)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(widget, Int32(SettingsMetrics.tabPadding))
        }
        // **Each section spans the tab**, which is `CLAUDE.md`'s *A tab's content spans the width of the window*:
        // filled rather than sized to its own widest row, so the two panels line up with each other and with the
        // tabs that come after them.
        facet_box_pack_start(widget, activeSection.widget, 0, 1, 0)
        facet_box_pack_start(widget, createControl.widget, 0, 1, 0)
        facet_box_pack_start(widget, inactiveSection.widget, 0, 1, 0)

        wire()
    }

    /// Reads both lists and draws them.
    ///
    /// **Handed each list rather than one list to filter**, because which rows count as active is a question about
    /// the table (`CategoryStore.activeCategories`, `inactiveCategories`) and a pane that split them would be a
    /// second answer to it.
    func reload() {
        activeTable.show(categories.activeCategories())
        retiredTable.show(categories.inactiveCategories())
    }

    private func wire() {
        activeTable.facesHolding = { [weak self] category in
            self?.faces.facesHolding(categoryID: category.id) ?? []
        }
        activeTable.onRetire = { [weak self] category in self?.edits.retire(category) }
        activeTable.onRename = { [weak self] category, typed in self?.edits.rename(category, to: typed) }
        activeTable.onSetDailyLimit = { [weak self] category, minutes in
            self?.edits.setDailyLimit(minutes, on: category)
        }
        activeTable.onPickIcon = { [weak self] category, anchor in self?.pickIcon(for: category, from: anchor) }
        activeTable.onPickColour = { [weak self] category, anchor in self?.pickColour(for: category, from: anchor) }

        // Read per row as the Inactive list is drawn, which is why it is a closure rather than a field on the record:
        // an active row draws no date at all, so joining it onto every category read would cost a subquery on the
        // reads that happen once a second.
        retiredTable.lastUsed = { [weak self] category in self?.entries.lastUsed(categoryID: category.id) }
        retiredTable.onReinstate = { [weak self] category in self?.edits.reinstate(category) }
        // **The same handler the Active list's rename reaches.** Everything that differs between the two is a
        // question about the record, so a second handler here would be a second answer to a question one already
        // answers.
        retiredTable.onRename = { [weak self] category, typed in self?.edits.rename(category, to: typed) }

        createControl.onSave = { [weak self] typed in self?.edits.create(typed) }

        activeSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "Categories section Active \(isExpanded ? "opened" : "folded")")
        }
        inactiveSection.onToggle = { [weak self] isExpanded in
            self?.debugLog?.record(.tab, "Categories section Inactive \(isExpanded ? "opened" : "folded")")
        }
    }

    /// Opens the icon grid under a category's icon.
    ///
    /// **The icons are read as the picker opens**, not held: the `icon` table is one of `CLAUDE.md`'s three reference
    /// tables and so *may* be kept, and it is read per ask anyway -- the only thing that asks is a picker somebody
    /// opened, and a read that costs nothing needs no exception written next to it. `IconStore` says the same.
    private func pickIcon(for category: CategoryRecord, from anchor: UnsafeMutablePointer<GtkWidget>) {
        let grid = IconGrid(icons: icons.all(), selected: category.iconName, over: anchor)
        grid.onPick = { [weak self] iconID in self?.edits.setIcon(iconID, on: category) }
        iconPicker = grid
        grid.show()
    }

    /// Opens the palette under a category's swatch, on the same terms as the icon grid.
    private func pickColour(for category: CategoryRecord, from anchor: UnsafeMutablePointer<GtkWidget>) {
        let list = ColourList(colours: colours.all(), selected: category.colourID, over: anchor)
        list.onPick = { [weak self] colourID in self?.edits.setColour(colourID, on: category) }
        colourPicker = list
        list.show()
    }
}

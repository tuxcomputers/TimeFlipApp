import AppKit

/// The Categories tab: the categories themselves, as opposed to which of them is being timed.
///
/// **Laid out as the previous app laid this window out**: a titled section with a rounded panel under it, the
/// pattern the Device tab used for every group it had (see `image/preferences-device.png`, measured rather than
/// recalled). Two sections now, Active then Inactive, each folding away behind its own triangle -- Active open,
/// because it is the one somebody works in, and Inactive closed, because it is an archive to go looking in
/// occasionally.
///
/// The create control sits between them, which is where the archive put it: in the gap rather than inside either
/// list, so it belongs to the tab and not to one section of it.
///
/// Draws what it is given. Reading the categories is the window's job, per the database rule -- so a tab left and
/// come back to is a fresh read rather than a redraw of what was true the first time.
@MainActor
final class CategoriesPane: NSView {
    enum Identifier {
        static let activeSection = "categories-active-section"
        static let activeHeading = "categories-active-section-heading"
        static let inactiveSection = "categories-inactive-section"
        static let inactiveHeading = "categories-inactive-section-heading"
    }

    private enum Layout {
        /// Room between the pane's edge and its content, on all four sides. The Faces tab's number, so the two tabs
        /// sit at the same rhythm.
        static let padding: CGFloat = 20
        /// Between one section and the next, and around the create control between them.
        static let sectionSpacing: CGFloat = 16
    }

    /// Exposed so what they hold can be asserted without a window on screen, and so the window can wire what their
    /// edits do: the pane draws, it does not write.
    let activeTable = CategoryTable()
    let retiredTable = RetiredCategoryTable()

    /// The same control the Faces tab offers, wired to the same rules and the same writer by the window. Two ways
    /// in, one implementation.
    let createControl = CategoryCreateControl()

    private(set) var activeSection: CategorySection!
    private(set) var inactiveSection: CategorySection!

    init() {
        super.init(frame: .zero)
        addSections()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Built in code, never from a nib, so there is no archive to decode.
        fatalError("init(coder:) is not used")
    }

    /// Shows the two lists.
    ///
    /// Handed each list rather than one list to filter, because which rows count as active is a question about the
    /// table (`CategoryStore.activeCategories`, `inactiveCategories`) and a pane that split them would be a second
    /// answer to it.
    func show(active: [CategoryRecord], inactive: [CategoryRecord] = []) {
        activeTable.show(active)
        retiredTable.show(inactive)
    }

    private func addSections() {
        activeSection = CategorySection(
            title: "Active",
            identifier: Identifier.activeSection,
            isExpanded: true,
            content: activeTable
        )
        inactiveSection = CategorySection(
            title: "Inactive",
            identifier: Identifier.inactiveSection,
            isExpanded: false,
            content: retiredTable
        )

        let stack = NSStackView(views: [activeSection, createControl, inactiveSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Layout.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            // Only as tall as its content: the sections grow downward from the top of the tab rather than being
            // stretched to fill a height they have nothing to put in.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.padding),
        ])
        // Each section spans the tab, so the two panels line up rather than sizing to their own widest row.
        for section in [activeSection, inactiveSection] {
            section?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        createControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

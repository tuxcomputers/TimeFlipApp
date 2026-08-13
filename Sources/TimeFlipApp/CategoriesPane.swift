import AppKit

/// The Categories tab: the categories themselves, as opposed to which of them is being timed.
///
/// **Laid out as the previous app laid this window out**: a bold section heading with a rounded panel under it, the
/// pattern the Device tab used for every group it had (see `image/preferences-device.png`, measured rather than
/// recalled). Active is the section somebody works in, so it comes first and is the only one built.
///
/// The previous app made both sections collapsible, with Active open and Inactive folded away. That is worth having
/// when there are two and one of them is an archive to go looking in occasionally; with one section there is nothing
/// to fold away *from*, so the triangles arrive with the Inactive list rather than ahead of it.
///
/// Draws what it is given. Reading the categories is the window's job, per the database rule -- so a tab left and
/// come back to is a fresh read rather than a redraw of what was true the first time.
@MainActor
final class CategoriesPane: NSView {
    enum Identifier {
        static let activeSection = "categories-active-section"
        static let activeHeading = "categories-active-heading"
    }

    private enum Layout {
        /// Room between the pane's edge and its content, on all four sides. The Faces tab's number, so the two tabs
        /// sit at the same rhythm.
        static let padding: CGFloat = 20
        /// Between a heading and what sits under it. Also the Faces tab's.
        static let sectionSpacing: CGFloat = 12
    }

    /// Exposed so what it holds can be asserted without a window on screen, and so the window can wire what its
    /// edits do: the pane draws, it does not write.
    let activeTable = CategoryTable()

    init() {
        super.init(frame: .zero)
        addActiveSection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Built in code, never from a nib, so there is no archive to decode.
        fatalError("init(coder:) is not used")
    }

    /// Shows `categories` as the Active list.
    ///
    /// Handed the active ones rather than filtering here: which rows count as active is a question about the table
    /// (`CategoryStore.activeCategories`), and a pane that filtered would be a second answer to it.
    func show(_ categories: [CategoryRecord]) {
        activeTable.show(categories)
    }

    private func addActiveSection() {
        let heading = NSTextField(labelWithString: "Active")
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier(Identifier.activeHeading)

        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        // Named and made an element, or it is absent from the tree entirely: an ordinary `NSView` is not an
        // accessibility element, so its role and identifier are simply never asked for (measured on the Settings
        // panes, see `SettingsWindowController.makePane`).
        section.setAccessibilityElement(true)
        section.setAccessibilityRole(.group)
        section.setAccessibilityIdentifier(Identifier.activeSection)
        section.setAccessibilityLabel("Active categories")

        addSubview(section)
        section.addSubview(heading)
        section.addSubview(activeTable)

        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            section.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            section.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            // Only as tall as its content: the list grows downward from the top of the tab, rather than being
            // stretched to fill a height it has nothing to put in.
            section.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.padding),

            heading.topAnchor.constraint(equalTo: section.topAnchor),
            heading.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: section.trailingAnchor),

            activeTable.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Layout.sectionSpacing),
            activeTable.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            activeTable.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            activeTable.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
    }
}

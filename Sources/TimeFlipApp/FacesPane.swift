import AppKit

/// The Faces tab's layout in manual mode: a wide left column for the thing being timed, and a narrow
/// right column for the categories to pick from.
///
/// **Layout only.** Both columns are empty apart from their headings, and nothing here reads the
/// database, responds to a click, or knows what a category is yet.
///
/// This is the manual-mode arrangement, which is the only one built so far. Following a cube puts a
/// picture of the device and its lock in the left column instead, under a "Top face" heading, and that
/// branch belongs here when there is a cube to follow.
@MainActor
final class FacesPane: NSView {
    enum Identifier {
        static let timingColumn = "faces-timing-column"
        static let timingHeading = "faces-timing-heading"
        static let categoriesColumn = "faces-categories-column"
        static let categoriesHeading = "faces-categories-heading"
    }

    private enum Layout {
        /// Room between the pane's edge and its content, on all four sides.
        static let padding: CGFloat = 20
        /// The gutter between the two columns.
        static let columnSpacing: CGFloat = 24
        /// Between a heading and what sits under it.
        static let sectionSpacing: CGFloat = 12
        /// The left column is twice the width of the right: a two-thirds/one-third split, expressed as
        /// a ratio between the two columns rather than as a fraction of the pane, so it needs nothing
        /// measured and holds by itself as the window is resized.
        static let leftToRightWidthRatio: CGFloat = 2
    }

    /// Exposed so the split can be asserted without a window on screen. Layout is the one thing here
    /// worth testing, and a broken constraint is otherwise only visible by eye.
    let timingColumn = NSView()
    let categoriesColumn = NSView()

    init() {
        super.init(frame: .zero)
        addColumns()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Built in code, never from a nib, so there is no archive to decode.
        fatalError("init(coder:) is not used")
    }

    private func addColumns() {
        let timingHeading = heading("Timing", identifier: Identifier.timingHeading)
        let categoriesHeading = heading("Categories", identifier: Identifier.categoriesHeading)

        configure(timingColumn, identifier: Identifier.timingColumn, label: "Timing")
        configure(categoriesColumn, identifier: Identifier.categoriesColumn, label: "Categories")

        for (column, columnHeading) in [(timingColumn, timingHeading), (categoriesColumn, categoriesHeading)] {
            addSubview(column)
            column.addSubview(columnHeading)
            NSLayoutConstraint.activate([
                columnHeading.topAnchor.constraint(equalTo: column.topAnchor),
                columnHeading.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                columnHeading.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
                // The gap a heading leaves for the content that will sit under it. It is also what
                // gives an otherwise empty column a height, so the columns are visible in the layout
                // before either of them holds anything.
                column.bottomAnchor.constraint(
                    greaterThanOrEqualTo: columnHeading.bottomAnchor,
                    constant: Layout.sectionSpacing
                ),
            ])
        }

        NSLayoutConstraint.activate([
            timingColumn.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            timingColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
            timingColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.padding),

            categoriesColumn.topAnchor.constraint(equalTo: timingColumn.topAnchor),
            categoriesColumn.leadingAnchor.constraint(
                equalTo: timingColumn.trailingAnchor,
                constant: Layout.columnSpacing
            ),
            categoriesColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            categoriesColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.padding),

            timingColumn.widthAnchor.constraint(
                equalTo: categoriesColumn.widthAnchor,
                multiplier: Layout.leftToRightWidthRatio
            ),
        ])
    }

    private func configure(_ column: NSView, identifier: String, label: String) {
        column.translatesAutoresizingMaskIntoConstraints = false
        // An ordinary NSView is not an accessibility element, so without this the role and identifier
        // are never asked for and the column is absent from the tree entirely.
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityIdentifier(identifier)
        column.setAccessibilityLabel(label)
    }

    private func heading(_ text: String, identifier: String) -> NSTextField {
        let heading = NSTextField(labelWithString: text)
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier(identifier)
        return heading
    }
}

import AppKit

/// Creating a category: a Create button that becomes a name field and a Save button, and goes back to
/// being a button when it is done.
///
/// Collapsed until clicked, on purpose: the column stays a list of categories rather than a permanently
/// open form.
///
/// It decides nothing. What a typed name means is `CategoryCreateRules`, and who writes it is the window
/// -- this reports the name and is told when to fold up.
@MainActor
final class CategoryCreateControl: NSView, NSTextFieldDelegate {
    enum Identifier {
        static let create = "create-category"
        static let nameField = "category-name-field"
        static let save = "save-category"
    }

    private enum Layout {
        static let fieldToSaveSpacing: CGFloat = 8
        /// Wide enough to type a category name into rather than a word at a time.
        static let minimumFieldWidth: CGFloat = 140
    }

    let createButton = NSButton()
    let nameField = NSTextField()
    let saveButton = NSButton()

    /// The typed name, raw. Normalising it is the rules' job, not the field's.
    var onSave: ((String) -> Void)?

    /// Reports the field opening and closing, because something outside has to know: the window's Close
    /// button holds Escape, and a key equivalent is dispatched before the focused field sees the key -- so
    /// while a name is being typed, Escape has to belong to the field or it closes the window out from
    /// under the edit.
    var onEditingChanged: ((Bool) -> Void)?

    private(set) var isEditing = false
    private var collapsedConstraints: [NSLayoutConstraint] = []
    private var editingConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addControls()
        apply(editing: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Opens the name field, ready to type into.
    func startEditing() {
        guard !isEditing else { return }
        nameField.stringValue = ""
        apply(editing: true)
        // The field is only in the responder chain once it is on screen, so this has to come after the
        // constraints change rather than with it.
        window?.makeFirstResponder(nameField)
    }

    /// Back to a single Create button, whatever was typed.
    func collapse() {
        guard isEditing else { return }
        // Given up before the field goes away: a field that is still first responder while hidden leaves
        // the window with no obvious focus and Escape belonging to nothing.
        if window?.firstResponder == nameField.currentEditor() {
            window?.makeFirstResponder(nil)
        }
        nameField.stringValue = ""
        apply(editing: false)
    }

    // MARK: - the field's keys

    /// Holds the field to `CategoryCreateRules.maximumLength` as it is typed into, the way the rename cell holds its
    /// own (`EditableNameCell.controlTextDidChange`).
    ///
    /// **The caret goes to the end**, which is where it already is in the case this fires in: a keystroke that would
    /// take the name past the limit. A paste into the middle of a full name moves it, which is the price of not
    /// tracking a selection through a truncation, and it is visible rather than surprising.
    ///
    /// `normalise` cuts it too, and that is the one that guarantees it. This is so that what is on screen is what
    /// will be saved, rather than a name that quietly loses its tail on the way to the table.
    func controlTextDidChange(_ notification: Notification) {
        guard nameField.stringValue.count > CategoryCreateRules.maximumLength else { return }
        nameField.stringValue = String(nameField.stringValue.prefix(CategoryCreateRules.maximumLength))
        nameField.currentEditor()?.selectedRange = NSRange(location: (nameField.stringValue as NSString).length, length: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            // Return saves, so a name can be typed and committed without reaching for the mouse.
            save()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape abandons the name. It reaches here rather than closing the window because the Close
            // button gave up its key equivalent while this field was open.
            collapse()
            return true
        default:
            return false
        }
    }

    // MARK: - building it

    private func addControls() {
        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.target = self
        createButton.action = #selector(startCreating)
        createButton.identifier = NSUserInterfaceItemIdentifier(Identifier.create)
        createButton.setAccessibilityIdentifier(Identifier.create)

        nameField.placeholderString = "Category name"
        nameField.delegate = self
        nameField.identifier = NSUserInterfaceItemIdentifier(Identifier.nameField)
        nameField.setAccessibilityIdentifier(Identifier.nameField)
        nameField.setAccessibilityLabel("Category name")

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.identifier = NSUserInterfaceItemIdentifier(Identifier.save)
        saveButton.setAccessibilityIdentifier(Identifier.save)

        for control in [createButton, nameField, saveButton] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }

        collapsedConstraints = [
            createButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            createButton.topAnchor.constraint(equalTo: topAnchor),
            createButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            createButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ]
        editingConstraints = [
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.topAnchor.constraint(equalTo: topAnchor),
            nameField.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameField.widthAnchor.constraint(greaterThanOrEqualTo: widthAnchor, multiplier: 0.5),
            nameField.trailingAnchor.constraint(
                equalTo: saveButton.leadingAnchor,
                constant: -Layout.fieldToSaveSpacing
            ),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
        ]
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumFieldWidth).isActive = true
    }

    /// Swaps the two states. Hidden **and** unconstrained: leaving the other state's constraints active
    /// would have the field still setting this view's height while invisible.
    private func apply(editing: Bool) {
        isEditing = editing
        NSLayoutConstraint.deactivate(editing ? collapsedConstraints : editingConstraints)
        createButton.isHidden = editing
        nameField.isHidden = !editing
        saveButton.isHidden = !editing
        NSLayoutConstraint.activate(editing ? editingConstraints : collapsedConstraints)
        onEditingChanged?(editing)
    }

    @objc
    private func startCreating() {
        startEditing()
    }

    @objc
    private func saveClicked() {
        save()
    }

    private func save() {
        onSave?(nameField.stringValue)
    }
}

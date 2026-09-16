import CGtk
import FacetCore
import Foundation

/// Creating a category: a Create button that becomes a name field and a Save button, and goes back to being a button
/// when it is done.
///
/// Collapsed until clicked, on purpose: the column stays a list of categories rather than a permanently open form.
///
/// **It decides nothing.** What a typed name means is `CategoryCreateRules`, and what is done about it is
/// `CategoryEdits` -- this reports the name and folds itself up.
///
/// **Return saves and Escape abandons**, which is `CategoryCreateControl`'s contract on the Mac. Escape reaches the
/// field here for the reason it does there, arrived at differently: the Mac lends its Close button's key equivalent
/// to whichever field is open, and this window asks what has focus instead (see `SettingsWindow`).
@MainActor
final class CategoryCreateControl {
    private enum Identifier {
        static let create = "create-category"
        static let nameField = "category-name-field"
        static let save = "save-category"
    }

    private enum Layout {
        /// Wide enough to type a category name into rather than a word at a time.
        static let minimumFieldWidth = 140
        static let fieldToSaveSpacing = 8
    }

    let widget: UnsafeMutablePointer<GtkWidget>

    private let createButton: UnsafeMutablePointer<GtkWidget>
    private let nameField: UnsafeMutablePointer<GtkWidget>
    private let saveButton: UnsafeMutablePointer<GtkWidget>
    private let signals = GtkSignals()

    /// The typed name, raw. Normalising it is the rules' job, not the field's.
    var onSave: ((String) -> Void)?

    /// Whether the field is open, read from the widget rather than remembered.
    var isEditing: Bool { gtk_widget_get_visible(nameField) != 0 }

    init() {
        widget = SettingsWidgets.row(spacing: Layout.fieldToSaveSpacing)

        createButton = gtk_button_new_with_label("Create")!
        SettingsWidgets.identify(createButton, Identifier.create)
        gtk_widget_set_halign(createButton, GTK_ALIGN_START)

        nameField = gtk_entry_new()!
        SettingsWidgets.identify(nameField, Identifier.nameField)
        facet_entry_set_placeholder(nameField, "Category name")
        facet_entry_set_max_length(nameField, Int32(CategoryCreateRules.maximumLength))
        gtk_widget_set_size_request(nameField, Int32(Layout.minimumFieldWidth), -1)

        saveButton = gtk_button_new_with_label("Save")!
        SettingsWidgets.identify(saveButton, Identifier.save)

        facet_box_pack_start(widget, createButton, 0, 0, 0)
        // The field takes the room the Save button does not, so a name is typed into something the width of the tab
        // rather than of the word it starts as.
        facet_box_pack_start(widget, nameField, 1, 1, 0)
        facet_box_pack_start(widget, saveButton, 0, 0, 0)

        // `no_show_all`, or the window's own `show_all` would open the form on every open. The same thing
        // `EditableNameCell` needs, and for the same reason.
        for widget in [nameField, saveButton] {
            gtk_widget_set_no_show_all(widget, 1)
            gtk_widget_hide(widget)
        }

        signals.connect(createButton, "clicked") { [weak self] in self?.startEditing() }
        signals.connect(saveButton, "clicked") { [weak self] in self?.save() }
        signals.connect(nameField, "activate") { [weak self] in self?.save() }
        signals.connectEvent(nameField, "key-press-event") { [weak self] event in
            guard let self, EditableNameCell.isEscape(event) else { return false }
            collapse()
            return true
        }
    }

    /// Opens the name field, ready to type into.
    func startEditing() {
        guard !isEditing else { return }
        facet_entry_set_text(nameField, "")
        gtk_widget_hide(createButton)
        gtk_widget_show(nameField)
        gtk_widget_show(saveButton)
        gtk_widget_grab_focus(nameField)
    }

    /// Back to a single Create button, whatever was typed.
    func collapse() {
        guard isEditing else { return }
        facet_entry_set_text(nameField, "")
        gtk_widget_hide(nameField)
        gtk_widget_hide(saveButton)
        gtk_widget_show(createButton)
    }

    /// **Folded before the name is reported**, which is what makes `CategoryEdits.create` take no control: every
    /// outcome there collapsed it, the one that does nothing at all included, so what looked like four decisions was
    /// one and it was this control's.
    private func save() {
        let typed = String(cString: facet_entry_get_text(nameField))
        collapse()
        onSave?(typed)
    }
}

import CGtk
import FacetCore
import Foundation

/// A name that becomes a field when it is clicked, and goes back to being a name when the edit ends.
///
/// **The same three ways out as `EditableNameCell` on the Mac**, which is the file this answers to:
///
/// - **Return commits it**, which is what raises the confirmation. The name on screen does not change here; it
///   changes when the table has been written and read back.
/// - **A click anywhere else abandons it**, which under GTK arrives as the field losing focus.
/// - **Escape abandons it too**, so a name opened by mistake costs one key rather than a trip through a dialogue.
///
/// Abandoning rather than committing on the way out is deliberate and is the Mac's reasoning unchanged: a rename is
/// confirmed, so committing on a stray click would raise a dialogue about a change nobody asked for, in front of
/// whatever they were actually clicking.
///
/// **Two widgets swapped rather than one entry with its frame turned off.** A frameless entry is still a field --
/// it takes focus, it shows a caret, and a list of them reads as a form somebody is meant to fill in, where this
/// column is a record of what each category is called.
///
/// **Swapped by hiding, which GTK allows and Auto Layout does not.** A hidden widget takes no room in a GTK box, so
/// there is nothing here answering to `PanelSection`'s swapped constraints. The one thing it costs is
/// `no_show_all` on the field: `gtk_widget_show_all` walks the whole window and would otherwise open every name in
/// every row the moment the window appeared.
///
/// **A length is the one limit this holds**, `CategoryCreateRules.maximumLength`, and GTK enforces it in the entry
/// so that what is on screen is what will be written. Which *characters* are acceptable is deliberately not asked
/// here: a character that vanished as it was typed reads as a broken keyboard, so it is left visible and refused by
/// whoever the name is submitted to, with a reason.
@MainActor
final class EditableNameCell {
    /// The cell, for putting in a row.
    let widget: UnsafeMutablePointer<GtkWidget>

    private let box: UnsafeMutablePointer<GtkWidget>
    private let button: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>
    private let name: String
    private let signals = GtkSignals()

    /// Whether the field is open. **Read from the widget rather than remembered**, which is the first rule pointed
    /// at a control: what is on screen is the answer, and a flag beside it could disagree with it.
    var isEditing: Bool { gtk_widget_get_visible(entry) != 0 }

    /// Called when Return commits an edit, with what was typed. Whether that becomes the name is `CategoryEdits`' to
    /// decide: it confirms, writes, and the row is read back.
    var onCommit: ((String) -> Void)?

    /// **What `GDK_KEY_Escape` is, spelled out.** It is a `#define` of `0xff1b`, and Swift's importer does not follow
    /// a macro -- the same wall `SystemBus.Kind` met with `DBUS_TYPE_STRING`.
    private static let escapeKey: UInt32 = 0xff1b

    /// - Parameters:
    ///   - isEnabled: whether the name can be edited at all. Off, the name is drawn exactly as before and clicking
    ///     it does nothing: it is still a name to read. **Not greyed**, which is the Mac's decision and its reason --
    ///     a grey name reads as a retired category, where what is true is that a locked face is holding this one.
    ///   - refusalHelp: what the cell says on hover when it will not open, which is the only thing explaining why
    ///     nothing happens.
    init(
        name: String,
        identifier: String,
        isEnabled: Bool = true,
        refusalHelp: String? = nil
    ) {
        self.name = name
        box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        widget = box

        // The name as a flat button, so the whole cell is the way in rather than the words alone. Borderless, so a
        // column of these reads as a list of names and not as a row of controls.
        let label = SettingsWidgets.label(name)
        button = SettingsWidgets.flatButton(label)
        SettingsWidgets.identify(button, identifier, saying: name)
        gtk_widget_set_tooltip_text(button, isEnabled ? "Click to rename" : refusalHelp)

        entry = gtk_entry_new()!
        SettingsWidgets.identify(entry, "\(identifier)-field")
        facet_entry_set_max_length(entry, Int32(CategoryCreateRules.maximumLength))

        facet_box_pack_start(box, button, 1, 1, 0)
        facet_box_pack_start(box, entry, 1, 1, 0)
        gtk_widget_set_no_show_all(entry, 1)
        gtk_widget_hide(entry)

        guard isEnabled else { return }
        signals.connect(button, "clicked") { [weak self] in self?.beginEditing() }
        // Return, which is a `GtkEntry`'s `activate`.
        signals.connect(entry, "activate") { [weak self] in self?.commit() }
        signals.connectEvent(entry, "key-press-event") { [weak self] event in
            guard let self, Self.isEscape(event) else { return false }
            endEditing()
            // Claimed, so the window's own Escape does not also close the window behind the abandoned edit.
            return true
        }
        signals.connectEvent(entry, "focus-out-event") { [weak self] _ in
            // A click elsewhere. Abandoned rather than committed, and the click lands on whatever it was aimed at.
            self?.endEditing()
            return false
        }
    }

    /// Turns the name into a field, focused, with the current name in it and selected, so typing replaces it.
    func beginEditing() {
        facet_entry_set_text(entry, name)
        gtk_widget_hide(button)
        gtk_widget_show(entry)
        gtk_widget_grab_focus(entry)
        facet_entry_select_all(entry)
    }

    /// Puts the name back. The name itself never changed: what a commit does is ask, and the row is rebuilt from the
    /// table afterwards.
    func endEditing() {
        guard isEditing else { return }
        gtk_widget_hide(entry)
        gtk_widget_show(button)
    }

    private func commit() {
        let typed = String(cString: facet_entry_get_text(entry))
        endEditing()
        onCommit?(typed)
    }

    /// Whether a key event is Escape.
    ///
    /// **Shared with `CategoryCreateControl`**, which abandons its own field on the same key: two copies of one
    /// keyval is the hazard `CLAUDE.md` opens with, wearing a magic number.
    static func isEscape(_ event: UnsafeMutablePointer<GdkEvent>?) -> Bool {
        guard let event else { return false }
        var keyval: guint = 0
        guard gdk_event_get_keyval(event, &keyval) != 0 else { return false }
        return keyval == escapeKey
    }
}

import CGtk
import FacetCore
import Foundation

/// The Linux slot in the dialogue square: a `GtkMessageDialog`.
///
/// **`AlertPresenter` is the reference and this is the same job.** A `Dialogue` is a value the core decided --
/// a heading, the wording, the buttons in order, which one is the way out, and whether it is a warning -- and
/// this turns it into a window and answers with the position of the choice taken. Nothing here decides anything;
/// all nineteen of the app's dialogues go through the port, so a platform that phrased one differently would be
/// the two-copies fault wearing a toolkit.
///
/// **Modal, and answered before `ask` returns.** `gtk_dialog_run` spins a nested main loop, which is what
/// `NSAlert.runModal` does on the other platform and for the same reason the Mac's app-modal path exists:
/// somebody who starts the app and walks away has to find the question where they left it rather than a launch
/// that quietly carried on. The app's own wakes are on the same main context, so the menu bar's clock goes on
/// ticking inside it -- which is a property of `GLibScheduler` being a GLib source rather than a thread.
///
/// **No parent window, and that is this platform's ordinary case rather than a gap.** The Mac presents eighteen
/// of its nineteen as sheets on the Settings window; there is no window here at all yet, so every one of them
/// takes the shape the nineteenth already has on both platforms.
///
/// **`wayOut` is simply honoured**, where AppKit has to be worked around. GTK does not relocate a button by its
/// title, so `gtk_dialog_set_default_response` puts Return on the answer the core named and there is nothing to
/// undo. The port carrying the position rather than a title is what makes that a one-line adapter here and a
/// measured trap there.
@MainActor
final class GtkDialoguePresenter: DialoguePresenter {
    private let debugLog: DebugLog?

    /// What a dialogue closed by the window manager comes back as. **Outside the choices deliberately**: the
    /// generic `ask(_:offering:)` turns a position none of them occupies into `nil`, which is a dialogue
    /// dismissed rather than answered, and that is exactly what closing the window is.
    private static let dismissed = Int(GTK_RESPONSE_DELETE_EVENT.rawValue)

    init(debugLog: DebugLog?) {
        self.debugLog = debugLog
    }

    func tell(_ notice: Dialogue) {
        _ = present(notice, buttons: notice.choices.isEmpty ? ["OK"] : notice.choices)
    }

    func ask(_ question: Dialogue, answered: @escaping @MainActor (Int) -> Void) {
        answered(present(question, buttons: question.choices))
    }

    /// Shows one dialogue and answers with the position of the button pressed.
    ///
    /// **The response id *is* the position**, which is the whole of why no platform numbering reaches the core:
    /// the buttons are added in the order `Dialogue.choices` gives them and each is registered under its own
    /// index. GTK's own ids are all negative, so nothing it invents can collide with one.
    private func present(_ dialogue: Dialogue, buttons: [String]) -> Int {
        debugLog?.record(.menu, "Dialogue: \(dialogue.title)")
        let dialog = facet_message_dialog_new(dialogue.isWarning ? 1 : 0, dialogue.title, dialogue.message)
        for (index, title) in buttons.enumerated() {
            facet_dialog_add_button(dialog, title, Int32(index))
        }
        if let wayOut = dialogue.wayOut, buttons.indices.contains(wayOut) {
            facet_dialog_set_default(dialog, Int32(wayOut))
        }

        let response = Int(facet_dialog_run(dialog))
        // **Destroyed here rather than left to be collected.** A `GtkDialog` is a top-level window and hiding it
        // is not closing it: one left behind keeps the app on screen after the question is over.
        gtk_widget_destroy(dialog)

        let chosen = buttons.indices.contains(response) ? buttons[response] : "nothing"
        debugLog?.record(.menu, "Dialogue answered: \(chosen)")
        return response == Self.dismissed ? Self.dismissed : response
    }
}

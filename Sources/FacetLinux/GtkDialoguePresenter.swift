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

    /// **Shown where it was asked for, unlike `ask` below.** A notice answers nothing, so nothing is waiting on
    /// it and there is no reason to move it -- and moving it turned out to matter: deferred, it appeared an idle
    /// later than the thing that raised it, which on a sequence of scripted steps is *after* the next step has
    /// already pressed something, and a modal window that arrives late swallows the press. Measured 2026-09-20:
    /// the App tab's calendar was created, the notice about it arrived behind the next press, and renaming the
    /// calendar never started.
    func tell(_ notice: Dialogue) {
        _ = present(notice, buttons: notice.choices.isEmpty ? ["OK"] : notice.choices)
    }

    func ask(_ question: Dialogue, answered: @escaping @MainActor (Int) -> Void) {
        onceTheHandlerHasReturned { [weak self] in
            guard let self else { return }
            answered(present(question, buttons: question.choices))
        }
    }

    /// Runs the block from an idle, rather than from wherever the dialogue was asked for.
    ///
    /// **Because a modal loop must not be started from inside a signal handler, and this app started every one
    /// of them that way.** `gtk_dialog_run` spins a nested main loop; the thing that raised the dialogue is
    /// usually a GTK handler -- committing an inline rename is `activate` on the entry -- so the nested loop ran
    /// with that emission still on the stack. Inside it the answer rebuilds the list, which destroys the very
    /// entry whose handler is waiting to return, and the unwind then touches freed memory.
    ///
    /// **Measured 2026-09-20**: renaming a category onto a name already in use crashed in `gtk_dialog_run`,
    /// somewhere under `EditableNameCell.commit`, with `G_IS_OBJECT` in the registers. It read from outside as
    /// the app vanishing off the accessibility bus, and the check reported that the rename had not taken --
    /// which is how a crash looks to something that can only see the database afterwards.
    ///
    /// It is the same hazard `DevicePane` records about rebuilding its own sections, one level further out:
    /// there the widget was destroyed and re-packed, here it is destroyed while GTK is still inside it.
    ///
    /// An idle runs after the current emission has finished and before the next event, so nothing is delayed
    /// that anybody could see.
    private func onceTheHandlerHasReturned(_ run: @escaping @MainActor () -> Void) {
        let box = Deferred(run)
        deferred.append(box)
        facet_timeout_add(
            0,
            { data in
                guard let data else { return facet_source_remove_value() }
                MainActor.assumeIsolated {
                    Unmanaged<Deferred>.fromOpaque(data).takeUnretainedValue().run()
                }
                return facet_source_remove_value()
            },
            Unmanaged.passUnretained(box).toOpaque()
        )
    }

    /// A boxed block, for the same reason `GtkSignals` boxes a handler: a Swift closure cannot cross into C.
    private final class Deferred {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    /// **Held for the life of the presenter rather than released when it runs.** A dialogue is answered by a
    /// person, so the gap between scheduling and running is unbounded, and there is one presenter for the life
    /// of the app: nineteen dialogues over a session is not a leak worth a weak table.
    private var deferred: [Deferred] = []

    /// Shows one dialogue and answers with the position of the button pressed.
    ///
    /// **The response id *is* the position**, which is the whole of why no platform numbering reaches the core:
    /// the buttons are added in the order `Dialogue.choices` gives them and each is registered under its own
    /// index. GTK's own ids are all negative, so nothing it invents can collide with one.
    private func present(_ dialogue: Dialogue, buttons: [String]) -> Int {
        debugLog?.record(.menu, "Dialogue: \(dialogue.title)")
        let dialog = facet_message_dialog_new(dialogue.isWarning ? 1 : 0, dialogue.title, dialogue.message)

        // **The way out goes on the left, whatever order `choices` lists it in.**
        //
        // AppKit does this for itself -- `AlertPresenter`'s own comment records that it *relocates a button
        // titled Cancel to the left* -- and GTK does not: it packs them in the order they are added. So a
        // dialogue whose choices read `["Reset Device", "Cancel"]` came out on this platform with the
        // destructive button sitting exactly where the way out belongs, and the way out where somebody
        // expects the action (measured 2026-09-20, `CubeResetQuestion`). The Google one happened to be
        // declared the other way round and so looked right, which is why nobody had seen it.
        //
        // It is also what the GNOME HIG asks for, so the two platforms agree here rather than merely matching.
        //
        // **The index registered is still the position in `choices`**, which is the contract the core relies
        // on: `present` answers with the response id and the caller reads it as a position, so moving a button
        // on screen must not move its number.
        var order = Array(buttons.indices)
        if let wayOut = dialogue.wayOut, buttons.indices.contains(wayOut) {
            order.removeAll { $0 == wayOut }
            order.insert(wayOut, at: 0)
        }
        for index in order {
            facet_dialog_add_button(dialog, buttons[index], Int32(index))
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

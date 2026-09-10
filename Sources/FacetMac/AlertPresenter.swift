import AppKit
import FacetCore

/// The macOS slot in the dialogue square: `NSAlert`, presented as a sheet on the Settings window.
///
/// **A sheet rather than a free-standing alert**, which is what every one of these was before the port and is
/// the platform's own answer for a question about the window in front of you. The window is held weakly and a
/// dialogue with nowhere to go is dropped rather than shown detached: an alert floating with no parent, from an
/// accessory app with no Dock icon, is one somebody may never find.
///
/// **Everything about `keyEquivalent` is here and nowhere else**, which is the whole reason this file earns its
/// place. `Dialogue.wayOut` says which answer changes nothing; what a Mac has to do about that is a measured
/// trap, written up on the property itself, and it was previously repeated at four call sites with two of them
/// spelling it differently.
@MainActor
final class AlertPresenter: DialoguePresenter {
    private weak var window: NSWindow?
    private let debugLog: DebugLog?

    init(window: NSWindow?, debugLog: DebugLog?) {
        self.window = window
        self.debugLog = debugLog
    }

    func tell(_ notice: Dialogue) {
        present(notice, dismissal: "OK") { _ in }
    }

    func ask(_ question: Dialogue, answered: @escaping @MainActor (Int) -> Void) {
        present(question, dismissal: nil, answered: answered)
    }

    /// - Parameter dismissal: the single button a notice gets. `nil` for a question, which brings its own.
    private func present(
        _ dialogue: Dialogue,
        dismissal: String?,
        answered: @escaping @MainActor (Int) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = dialogue.title
        alert.informativeText = dialogue.message
        if dialogue.isWarning { alert.alertStyle = .warning }

        let titles = dialogue.choices.isEmpty ? [dismissal ?? "OK"] : dialogue.choices
        for title in titles {
            alert.addButton(withTitle: title)
        }
        // **Return is put on the way out rather than aimed at it by ordering.** AppKit relocates a button
        // titled "Cancel" to the left, which takes it out of the rightmost place Return fires, so a dialogue
        // that merely listed the way out first would have Return agreeing to the thing it must not.
        if let wayOut = dialogue.wayOut {
            for index in alert.buttons.indices {
                alert.buttons[index].keyEquivalent = index == wayOut ? "\r" : ""
            }
        }

        guard let window else {
            // **Said rather than swallowed.** A question nobody was asked is not the same as one answered, and
            // the caller is about to be told nothing at all, so the row is the only trace there would be.
            debugLog?.record(.field, "No window to put a dialogue on, so it was not shown: \(dialogue.title)")
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                answered(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            }
        }
    }
}

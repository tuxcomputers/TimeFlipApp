import AppKit
import FacetCore

/// The macOS slot in the dialogue square: `NSAlert`, presented as a sheet on the Settings window.
///
/// **A sheet where there is a window, and an app-modal alert where there is not.** The eighteen dialogues the
/// Settings window raises are sheets, which is the platform's own answer for a question about the window in
/// front of you. The nineteenth is the cube-not-found offer, which has to be answerable when no window is open
/// at all: that is the ordinary case at startup for a menu bar app, and it is the archive's decision unchanged.
///
/// **The app-modal path activates first, and that is not a flourish.** An accessory app is not frontmost, so
/// without it the alert can come up behind whatever somebody is actually looking at.
///
/// **The window is held weakly**, so a presenter built for a window that has gone falls back to app-modal
/// rather than dropping the question. A dialogue nobody is shown is worse than one in the wrong place.
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
            // **Modal, and answered before this returns.** The app has nothing else on screen to interact
            // with, and somebody who starts the app and walks away has to find the question exactly where they
            // left it rather than a launch that quietly carried on.
            NSApp.activate(ignoringOtherApps: true)
            answered(alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                answered(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            }
        }
    }
}

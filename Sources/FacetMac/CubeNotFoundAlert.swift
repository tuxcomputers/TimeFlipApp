import AppKit
import FacetCore

/// The dialog that says the cube could not be found, and asks whether to look again.
///
/// **An `NSAlert` put up by the app rather than by a window**, which is the archive's decision and its reasoning
/// unchanged: every other alert in this app hangs off the Settings window (`confirmReset`, `showNameTaken`), and this
/// one has to be answerable when no window is open at all -- which is the ordinary case at startup for a menu-bar app.
/// The activate call is part of that: an accessory app is not frontmost, so without it the alert can come up behind
/// whatever somebody is actually looking at.
///
/// Its own type rather than a closure written out in `main.swift`, so the reconnector can be driven through both
/// answers in a test without a dialog to dismiss -- see `DeviceReconnector.onCubeNotFound`, which takes any presenter.
@MainActor
enum CubeNotFoundAlert {
    /// Puts the question up and reports the answer.
    ///
    /// **What it says and what it offers is `CubeNotFoundQuestion`**, in `FacetCore`, so a GTK app asks the
    /// identical question. What is left here is that it is shown with no window behind it, which
    /// `AlertPresenter` handles by going app-modal.
    ///
    /// **A dismissal that is none of the three answers is a quit.** A modal `NSAlert` with no Cancel returns
    /// one of its buttons, so this cannot arise; answering it rather than trapping it keeps a dialog nobody can
    /// dismiss out of the one path that exists for a cube nobody can reach.
    static func ask(_ answer: @escaping (CubeNotFoundAnswer) -> Void) {
        AlertPresenter(window: nil, debugLog: nil).ask(
            CubeNotFoundQuestion.dialogue, offering: CubeNotFoundQuestion.answers
        ) { chosen in
            answer(chosen ?? .quit)
        }
    }
}

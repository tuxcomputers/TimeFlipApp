import AppKit

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
    /// The heading, and the whole of it: one question, however the cube came to be out of reach.
    static let messageText = "Unable to find your device"

    /// What it says underneath, and it is **the archive's wording rather than a rephrasing of it**.
    ///
    /// **"No TimeFlip answered", not "your TimeFlip did not answer".** The difference is not tone, it is what the app
    /// is in a position to claim. A cube that answers and refuses this app's PIN is very often not the user's cube at
    /// all: it is a colleague's on the next desk, found because it is a TimeFlip in range, on the morning the user
    /// left theirs at home. Saying "it would not accept this app's PIN" about that one asserts both that it was
    /// theirs and that theirs refused them, and is wrong twice over -- and it sends somebody hunting a PIN problem
    /// they do not have. Naming neither device says only what actually happened.
    ///
    /// **What the second paragraph says is what each button does, because all three commit to something different.**
    /// It names the two facts somebody needs before choosing: that timing by hand keeps the cube paired, so choosing
    /// it costs nothing to undo, and that this launch will not go back to looking on its own, so getting the cube
    /// back is a restart. The version before this one had to describe a two-step route to timing by hand -- forget the
    /// device, then restart -- because the button could not switch the running launch. It can, so it does.
    static let informativeText = """
        No TimeFlip answered: either none is in range, or none of the ones found would accept this app's PIN.

        Rescan looks again. Time by Hand carries on without it: your device stays paired and the app keeps its own \
        clock, so quit and start the app when you want the cube back.
        """

    /// Puts the question up and reports the answer.
    ///
    /// **One dialog, whatever the reason.** This deliberately takes no reason at all, and that is the guarantee
    /// rather than a convenience: `DeviceReconnector` derives one (`CubeNotFoundOffer.reason`) and it goes to the
    /// `debug_log` and nowhere else, because it is a diagnosis and not something to put to somebody. The situation a
    /// person is in is the same in every case -- their cube is not usable and they have to decide whether to wait for
    /// it -- and the distinctions the app can draw between "nothing answered" and "something answered and refused"
    /// are about the radio, not about them.
    ///
    /// **Modal, deliberately.** The app has stopped reaching for the cube and will not start again until this is
    /// answered, so there is nothing happening behind it to interact with -- and somebody who starts the app and walks
    /// away has to find the question exactly where they left it, rather than a launch that quietly carried on.
    static func ask(_ answer: @escaping (CubeNotFoundAnswer) -> Void) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        // **Added in this order because `NSAlert` draws the first one rightmost and makes it the default**, so
        // Return is Rescan: the answer that changes nothing and can be given again. Quit goes last, which puts it at
        // the far left where a dismissing button belongs.
        //
        // **"Time by Hand" rather than "Switch to Manual Mode"**, which is what the archive called it. Nothing on
        // screen anywhere in this app says "manual mode" to a user -- the Faces tab simply times -- so a button
        // naming a mode would be introducing a concept to explain itself, and what somebody wants here is the
        // activity, not the state they will be in while doing it.
        alert.addButton(withTitle: "Rescan")
        alert.addButton(withTitle: "Time by Hand")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: answer(.rescan)
        case .alertSecondButtonReturn: answer(.timeByHand)
        // **Quit is the default for anything else, and there is nothing else.** A modal `NSAlert` with no Cancel
        // returns one of the three, and answering the third case rather than trapping it keeps a dialog nobody can
        // dismiss out of the one path that exists for a cube nobody can reach.
        default: answer(.quit)
        }
    }
}

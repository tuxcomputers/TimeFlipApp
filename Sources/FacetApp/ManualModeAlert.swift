import AppKit

/// The offer itself: the dialog that says the cube could not be found, and asks what to do about it.
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
enum ManualModeAlert {
    /// The heading, and the whole of it: one question, however the cube came to be out of reach.
    static let messageText = "Unable to find your device, retry or switch to manual mode"

    /// What it says underneath, and it is **the archive's wording rather than a rephrasing of it**.
    ///
    /// **"No TimeFlip answered", not "your TimeFlip did not answer".** The difference is not tone, it is what the app
    /// is in a position to claim. A cube that answers and refuses this app's PIN is very often not the user's cube at
    /// all: it is a colleague's on the next desk, found because it is a TimeFlip in range, on the morning the user
    /// left theirs at home. Saying "it would not accept this app's PIN" about that one asserts both that it was
    /// theirs and that theirs refused them, and is wrong twice over -- and it sends somebody hunting a PIN problem
    /// they do not have. Naming neither device says only what actually happened.
    ///
    /// **"Quit and start the app" is the whole of the way back, and saying more would be a promise this app does not
    /// keep.** Only a paired launch ever sees this dialog, and the Device tab shows no Scan button while a cube is
    /// paired (`DevicePairingRules.showsScanControls`) -- so there is nothing on that tab to pair, and offering it
    /// would send somebody looking for a control that is not there.
    static let informativeText = """
        No TimeFlip answered: either none is in range, or none of the ones found would accept this app's PIN.

        Manual mode lets you track time from the app instead. It will not look for your device again on its own \
        -- quit and start the app when you want it back.
        """

    /// Puts the question up and reports the answer.
    ///
    /// **One dialog, whatever the reason.** This deliberately takes no reason at all, and that is the guarantee
    /// rather than a convenience: `DeviceReconnector` derives one (`ManualModeOffer.reason`) and it goes to the
    /// `debug_log` and nowhere else, because it is a diagnosis and not something to put to somebody. The situation a
    /// person is in is the same in every case -- their cube is not usable and they have to decide whether to wait for
    /// it -- and the distinctions the app can draw between "nothing answered" and "something answered and refused"
    /// are about the radio, not about them.
    ///
    /// **Modal, deliberately.** The app has stopped reaching for the cube and will not start again until this is
    /// answered, so there is nothing happening behind it to interact with -- and somebody who starts the app and walks
    /// away has to find the question exactly where they left it, rather than a launch that quietly carried on.
    static func ask(_ answer: @escaping (ManualModeAnswer) -> Void) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Switch to Manual Mode")
        NSApp.activate(ignoringOtherApps: true)
        answer(alert.runModal() == .alertFirstButtonReturn ? .retry : .switchToManualMode)
    }
}

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
    /// **What it now says about timing by hand, and why the instruction got longer rather than shorter.** This
    /// dialog used to offer manual mode as a button, and taking it switched the running launch. It cannot any more
    /// (`LaunchMode`): a launch that started with a cube on record stays one. So the text has to name the actual way
    /// there, which is two steps rather than one -- **forget the device, then restart** -- because a restart on its
    /// own comes straight back to this dialog, the app still being paired and still unable to find anything. Saying
    /// only "start the app again" would send somebody round that loop with no way of knowing why.
    ///
    /// Only a paired launch ever sees this dialog, so Forget is on the Device tab to be used; what is not there is a
    /// Scan button, the tab showing none while a cube is paired (`DevicePairingRules.showsScanControls`).
    static let informativeText = """
        No TimeFlip answered: either none is in range, or none of the ones found would accept this app's PIN.

        This launch will not look for it again on its own -- quit and start the app to try once more. To track time \
        from the app instead, forget the device on the Device tab and then start the app again.
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
        alert.addButton(withTitle: "Retry")
        // **"Stop Looking" rather than "Switch to Manual Mode"**, which is what this button used to do and no longer
        // can. It names what pressing it actually does, all of it: the launch stops reaching for the cube and stays
        // the launch it was.
        alert.addButton(withTitle: "Stop Looking")
        NSApp.activate(ignoringOtherApps: true)
        answer(alert.runModal() == .alertFirstButtonReturn ? .retry : .stopLooking)
    }
}

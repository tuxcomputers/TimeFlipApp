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
    /// Puts the question up and reports the answer.
    ///
    /// **Modal, deliberately.** The app has stopped reaching for the cube and will not start again until this is
    /// answered, so there is nothing happening behind it to interact with -- and somebody who starts the app and walks
    /// away has to find the question exactly where they left it, rather than a launch that quietly carried on.
    static func ask(_ answer: @escaping (ManualModeAnswer) -> Void) {
        let alert = NSAlert()
        // The archive's words, kept: they say what happened, what each button does, and -- the part that is easy to
        // leave out -- that manual mode does not end by itself.
        alert.messageText = "Unable to find your device, retry or switch to manual mode"
        // **"Quit and start the app" is the whole of the way back, and saying more would be a promise this app does
        // not keep.** Only a paired launch ever sees this dialog, and the Device tab shows no Scan button while a cube
        // is paired (`DevicePairingRules.showsScanControls`) -- so there is nothing on that tab to pair, and offering
        // it would send somebody looking for a control that is not there.
        alert.informativeText = """
            Your TimeFlip did not answer: either it is not in range, or it would not accept this app's PIN.

            Manual mode lets you track time from the app instead. It will not look for your device again on its own \
            -- quit and start the app when you want it back.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Switch to Manual Mode")
        NSApp.activate(ignoringOtherApps: true)
        answer(alert.runModal() == .alertFirstButtonReturn ? .retry : .switchToManualMode)
    }
}

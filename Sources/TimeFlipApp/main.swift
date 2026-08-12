import AppKit
import Foundation

// Startup, in order. The database comes up first and the menu bar second, because the second has
// nothing to draw from if the first did not happen -- and from here on **Quit is the only way out**.
//
// The one exception is a database that cannot be brought up, which is a refusal to start rather than
// an exit: there is no useful app on the other side of it, so it says why on stderr and stops. Every
// other failure from here has to be something the running app copes with.

do {
    try DatabaseBootstrap.ensureDatabase()
} catch {
    // The app is refusing to start, so the reason has to reach whoever launched it.
    let message = (error as? DatabaseBootstrap.Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("timeflip: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

let app = NSApplication.shared
// `.accessory`: a menu bar app, so no Dock icon and no app menu. It is also why the dropdown's Quit
// carries no ⌘Q -- there is no application menu for the shortcut to live in.
app.setActivationPolicy(.accessory)

let menuBar = MenuBarController()
menuBar.start()

app.run()

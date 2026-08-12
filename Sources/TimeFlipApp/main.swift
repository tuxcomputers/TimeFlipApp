import AppKit
import Foundation

// Startup, in order. The database comes up first and the menu bar second, because the second has
// nothing to draw from if the first did not happen -- and from here on **Quit is the only way out**.
//
// The one exception is a database that cannot be brought up, which is a refusal to start rather than
// an exit: there is no useful app on the other side of it, so it says why on stderr and stops. Every
// other failure from here has to be something the running app copes with.

let databaseURL: URL
do {
    databaseURL = try DatabaseBootstrap.ensureDatabase().databaseURL
} catch {
    // The app is refusing to start, so the reason has to reach whoever launched it.
    let message = (error as? DatabaseBootstrap.Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("timeflip: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

// The dev flag's first job. Which database this launch opened is a developer's question -- in a
// shipped copy there is only ever the real one, so a permanent "PROD" tag would take space in the
// menu bar to answer a question nobody has. A `nil` badge is no badge at all, which is why the gate
// lives here rather than inside the badge or the menu bar: one place decides, and the rest of the
// app never asks whether this is a dev build.
let databaseBadge = DeveloperMode.isEnabled
    ? DatabaseBadge.forEnvironment(DatabaseEnvironment.read(from: databaseURL))
    : nil

let app = NSApplication.shared
// `.accessory`: a menu bar app, so no Dock icon and no app menu. It is also why the dropdown's Quit
// carries no ⌘Q -- there is no application menu for the shortcut to live in.
app.setActivationPolicy(.accessory)

// The window is built on its first open, so this costs nothing until Settings is chosen.
let settingsWindow = SettingsWindowController()
let menuBar = MenuBarController(databaseBadge: databaseBadge, openSettings: { settingsWindow.show() })
menuBar.start()

app.run()

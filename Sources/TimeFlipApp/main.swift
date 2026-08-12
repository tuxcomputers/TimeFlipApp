import AppKit
import Foundation

// Startup, in order: prove this is the only instance, bring the database up, then the menu bar. Each
// step is ahead of the one that would be wrong to do twice -- a duplicate launch stands down before it
// has opened a database or claimed a status item -- and from here on **Quit is the only way out**.
//
// The exceptions are the two ways a launch can end early below, both of them refusals to start rather
// than exits. Every other failure from here has to be something the running app copes with.

// Kept for the life of the process, which is the whole of what it does: the lock lives on an open file
// descriptor, so letting this go would hand the app's identity to the next launch mid-run.
let instanceLock: InstanceLock?
switch InstanceLock.claim() {
case let .success(lock):
    instanceLock = lock
case .failure(.heldByAnotherInstance):
    // stderr rather than the debug log, which lives in the database a duplicate must not open. Exit 0
    // because standing down is this code working, not failing -- a non-zero status would tell a script
    // that launched the app that the launch was broken.
    FileHandle.standardError.write(Data("timeflip: already running, so this copy is exiting.\n".utf8))
    exit(EXIT_SUCCESS)
case let .failure(.cannotTell(reason)):
    // No answer either way, so carry on rather than refuse: a lock file that cannot be opened is not
    // evidence of a second instance, and standing down here would turn a read-only home directory into
    // an app that never starts at all.
    FileHandle.standardError.write(Data("timeflip: could not check for a second instance: \(reason)\n".utf8))
    instanceLock = nil
}

let databaseURL: URL
do {
    databaseURL = try DatabaseBootstrap.ensureDatabase().databaseURL
} catch {
    // The app is refusing to start, so the reason has to reach whoever launched it.
    let message = (error as? DatabaseBootstrap.Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("timeflip: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

// Everything the dev flag gates is decided here, and nowhere else: what it produces is either a thing
// or `nil`, and the rest of the app takes what it is given without ever asking whether this is a dev
// build.
//
// The badge names which database this launch opened, which is a developer's question -- a shipped copy
// only ever has the real one, so a permanent "PROD" tag would occupy the menu bar to answer something
// nobody asked.
let databaseBadge = DeveloperMode.isEnabled
    ? DatabaseBadge.forEnvironment(DatabaseEnvironment.read(from: databaseURL))
    : nil
let debugLog = DeveloperMode.isEnabled ? DebugLog(databaseURL: databaseURL) : nil

let app = NSApplication.shared
// `.accessory`: a menu bar app, so no Dock icon and no app menu. It is also why the dropdown's Quit
// carries no ⌘Q -- there is no application menu for the shortcut to live in.
app.setActivationPolicy(.accessory)

// The window is built on its first open, so this costs nothing until Settings is chosen.
let settingsWindow = SettingsWindowController(debugLog: debugLog)
let menuBar = MenuBarController(
    databaseBadge: databaseBadge,
    debugLog: debugLog,
    openSettings: { settingsWindow.show() }
)
menuBar.start()

app.run()

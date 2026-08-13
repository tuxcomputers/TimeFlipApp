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

// One read connection, held open for the life of the app, with a reader per table on top of it. Asked
// again every time an answer is wanted, and caching nothing: see the first design rule in `CLAUDE.md`.
let database = DatabaseConnection(databaseURL: databaseURL)
let settings = SettingReader(connection: database)
let categories = CategoryStore(connection: database)
let faces = FaceStore(connection: database)
let timezones = TimezoneStore(connection: database)

// The one owner of what is being timed. In memory, like the mode it belongs to: which category the manual
// face holds is in the database, and how long it has been running is this launch's business.
let timingSession = TimingSession()

// Everything the dev flag gates is decided here, and nowhere else: what it produces is either a thing
// or `nil`, and the rest of the app takes what it is given without ever asking whether this is a dev
// build.
//
// The badge names which database this launch opened, which is a developer's question -- a shipped copy
// only ever has the real one, so a permanent "PROD" tag would occupy the menu bar to answer something
// nobody asked.
let databaseBadge = DeveloperMode.isEnabled
    ? DatabaseBadge.forEnvironment(DatabaseEnvironment.read(from: settings))
    : nil
let debugLog = DeveloperMode.isEnabled ? DebugLog(databaseURL: databaseURL) : nil

// With no device paired there is nothing to follow, so the app times by hand. Startup is the first
// place that needs the answer, which is why the read happens here and not sooner.
let manualMode = ManualMode(debugLog: debugLog)
manualMode.startIfNoDeviceIsPaired(settings)

let app = NSApplication.shared
// `.accessory`: a menu bar app, so no Dock icon and no app menu. It is also why the dropdown's Quit
// carries no ⌘Q -- there is no application menu for the shortcut to live in.
app.setActivationPolicy(.accessory)

// The `device_event` table's one writer. Built after the debug log so a segment can say what it did, and
// before the window, which is where the clicks that produce segments arrive.
let deviceEvents = DeviceEventRecorder(connection: database, timezones: timezones, debugLog: debugLog)

// The window is built on its first open, so this costs nothing until Settings is chosen.
let settingsWindow = SettingsWindowController(
    debugLog: debugLog,
    categories: categories,
    faces: faces,
    session: timingSession,
    deviceEvents: deviceEvents
)
// Asks for history on an interval it re-reads from the database every time it fires. With no cube paired
// there is nothing to ask, so the timeout **is** the source: the app reports its own open segment, and the
// recorder recognises it as the same event and grows its duration. When a device arrives, the fetch request
// goes in here beside this and the recorder is handed frames instead.
//
// Only while the clock is running. Pausing writes nothing yet, so the open row is still the running segment
// and growing it through a pause would record time nobody spent. That guard goes when pause closes its own
// segment, because then a paused session simply has no open row to find.
let historyTimer = HistoryTimer(settings: settings, debugLog: debugLog) {
    guard timingSession.isRunning else { return }
    deviceEvents.refreshOpenSegment(at: Date())
}
historyTimer.start()

let menuBar = MenuBarController(
    databaseBadge: databaseBadge,
    debugLog: debugLog,
    openSettings: { settingsWindow.show() },
    // Asked as the menu opens rather than pushed when it changes, so the menu cannot be stale.
    timingState: {
        ManualTimerRules.state(categoryID: timingSession.categoryID, isRunning: timingSession.isRunning)
    },
    // The same entry point the Timing column's control uses. Two ways in, one implementation.
    togglePause: { settingsWindow.togglePause() }
)
menuBar.start()

app.run()

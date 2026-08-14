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
let settings = SettingStore(connection: database)
let categories = CategoryStore(connection: database)
let faces = FaceStore(connection: database)
let timezones = TimezoneStore(connection: database)

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

// The two tables that record time, in the order the answer flows: a segment is recorded first, and closing one
// raises the question the second module answers. `device_event` is what a source says happened; `time_entry` is
// what the app counts, and they are deliberately not the same question.
let timeEntries = TimeEntryRecorder(
    connection: database,
    settings: settings,
    faces: faces,
    debugLog: debugLog
)
let deviceEvents = DeviceEventRecorder(
    connection: database,
    timezones: timezones,
    timeEntries: timeEntries,
    debugLog: debugLog
)


// A launch inherits whatever the last one left behind. A segment still open on one of the app's own faces is a
// launch that ended without its quit sequence -- a crash, a force quit -- and closing it here, before the window
// or the history timer can touch it, is what stops either of them measuring it from its start to now.
//
// Before anything else reads the table, and deliberately not a step the user can arrive in the middle of.
deviceEvents.closeSegmentsStrandedOnAppFaces()

// What the Timing column draws: the category's total for the day, read every time rather than counted.
let entries = TimeEntryStore(connection: database)
let dayTotal = DayTotal(
    settings: settings,
    entries: entries,
    events: deviceEvents,
    faces: faces
)

// What is being timed, for both things that draw it. The Faces tab and the status item read one answer rather
// than each resolving the face, the category and the total for itself -- and it is all read, including whether the
// clock is running, so a launch inherits the session the last one left instead of starting blank.
let timingReadout = TimingReadout(
    categories: categories,
    faces: faces,
    events: deviceEvents,
    dayTotal: dayTotal
)

// What happens on the way out, and it has to be set before `run()`. Kept in a binding because
// `NSApplication.delegate` is a **weak** reference: a quit sequence nobody retains is deallocated
// immediately and the app then ends without running any of it, silently.
let quitSequence = QuitSequence(deviceEvents: deviceEvents, debugLog: debugLog)
app.delegate = quitSequence

// The window is built on its first open, so this costs nothing until Settings is chosen.
let settingsWindow = SettingsWindowController(
    debugLog: debugLog,
    categories: categories,
    faces: faces,
    deviceEvents: deviceEvents,
    timing: timingReadout,
    entries: entries,
    icons: IconStore(connection: database),
    colours: ColourStore(connection: database),
    settings: settings
)
// Asks for history on an interval it re-reads from the database every time it fires. With no cube paired
// there is nothing to ask, so the timeout **is** the source: the app reports its own open segment, and the
// recorder recognises it as the same event and grows its duration. When a device arrives, the fetch request
// goes in here beside this and the recorder is handed frames instead.
//
// No check on whether anything is running: an open row **is** that answer, and pausing closes its segment, so a
// paused session has nothing here to find. This used to ask an in-memory session first, which was a second copy of
// a question the table already answers, and that session is now gone for the same reason (see `TimingReadout`).
let historyTimer = HistoryTimer(settings: settings, debugLog: debugLog) {
    deviceEvents.refreshOpenSegment(at: Date())
}
historyTimer.start()

let menuBar = MenuBarController(
    databaseBadge: databaseBadge,
    debugLog: debugLog,
    openSettings: { settingsWindow.show() },
    // Asked as the item is drawn and as the menu opens, rather than pushed when it changes, so neither can be
    // stale. The same readout the Faces tab draws from.
    timing: { timingReadout.read() },
    // `display_seconds`, read per draw like everything else, and defaulting to showing them: a menu bar clock
    // without seconds looks stopped.
    showingSeconds: { settings.flag("display_seconds", field: "enabled") ?? true },
    // The same entry point the Timing column's control uses. Two ways in, one implementation.
    togglePause: { settingsWindow.togglePause() }
)
menuBar.start()

// A category picked or paused in the window has to reach the item in the same moment, rather than on its next
// tick. Assigned here because each side needs the other: the item's menu is what opens the window.
settingsWindow.onTimingChanged = { menuBar.redraw() }

app.run()

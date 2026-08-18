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
    FileHandle.standardError.write(Data("facet: already running, so this copy is exiting.\n".utf8))
    exit(EXIT_SUCCESS)
case let .failure(.cannotTell(reason)):
    // No answer either way, so carry on rather than refuse: a lock file that cannot be opened is not
    // evidence of a second instance, and standing down here would turn a read-only home directory into
    // an app that never starts at all.
    FileHandle.standardError.write(Data("facet: could not check for a second instance: \(reason)\n".utf8))
    instanceLock = nil
}

let databaseURL: URL
do {
    databaseURL = try DatabaseBootstrap.ensureDatabase().databaseURL
} catch {
    // The app is refusing to start, so the reason has to reach whoever launched it.
    let message = (error as? DatabaseBootstrap.Failure)?.description ?? error.localizedDescription
    FileHandle.standardError.write(Data("facet: \(message)\n".utf8))
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

// Recorded time on its way to Google. Wired as a closure rather than handed to the recorder, so writing a
// `time_entry` row does not depend on there being a Google account at all: with nothing connected this sweeps,
// finds it has nowhere to put anything, says so once and stops.
let calendarSync = CalendarSync(connection: database, settings: settings, debugLog: debugLog)
timeEntries.onEntryRecorded = { calendarSync.sweep(because: "an entry was recorded") }


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

// The radio, which is the app's and not the Settings window's.
//
// **It was the window's until reconnecting existed, and that is what moved it.** A paired app has to reach its cube
// whether or not anybody opens Settings -- which is most launches -- so a radio built on the first scan is one that never
// gets built. The window still drives it for scanning and pairing; it no longer owns it.
//
// **Building it does not touch the radio.** `CBCentralManager` is made on the first scan or reach, inside
// `BluetoothRadio.start`, so a launch with nothing paired still never provokes the system's Bluetooth prompt.
let radio = BluetoothRadio(debugLog: debugLog)

// The low-battery warning, which two things draw and one thing decides.
//
// **Built here, beside the radio, because it is the app's and not the window's** -- the flash it drives is in the menu
// bar, which is up whether or not Settings has ever been opened. It asks the radio for the charge and the table for
// what counts as low, holding neither: the only thing it remembers is whether the warning is currently on, which is
// what hysteresis *is* and exists nowhere else.
let lowBattery = LowBatteryWatch(
    level: { radio.batteryPercent },
    settings: settings,
    debugLog: debugLog
)

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
    settings: settings,
    manualMode: manualMode,
    radio: radio,
    lowBattery: lowBattery
)
// **Set here rather than passed in**, because the window controller is made after the quit sequence: a connection
// outlives the Settings window, so the app is what gives it back. See `SettingsWindowController.letGoOfTheDevice`.
quitSequence.letGoOfTheDevice = { settingsWindow.letGoOfTheDevice() }
// Stopping the cube, which two things now ask for: the dropdown's Lock item, and the quit. One object so the order,
// the setting and the read-backs are decided once -- see `CubeLock`, and the note there about why the order is not
// arbitrary.
let cubeLock = CubeLock(
    settings: settings,
    isConnected: { radio.connectedDevice != nil },
    send: { command, reported in radio.send(command, reported) },
    debugLog: debugLog
)
// The other half of the way out: the cube is paused and then locked before the link is given back, so a device left on
// the desk is not still counting time against whatever face was up when the app went away.
quitSequence.cubeLock = cubeLock

// What keeps a paired app's cube reachable: it looks for it now, and goes on looking whenever the link goes.
//
// **The stored PIN is a closure rather than a value**, for the reason every read in this app is at the point of use:
// `config.json` is a file a developer also edits by hand, and an attempt an hour from now must present what it says then.
let reconnector = DeviceReconnector(
    radio: radio,
    settings: settings,
    debugLog: debugLog,
    storedPIN: { DeveloperConfigFile.standard?.pin() ?? DeveloperMode.devicePIN },
    rotatingTo: DeveloperMode.devicePIN,
    // Asked rather than told, so there is one answer to "is this launch timing by hand" and the loop reads it at the
    // moment it is about to act on it -- which matters because pairing a cube turns the mode off underneath it.
    isTimingByHand: { manualMode.isOn }
)
// What happens when a paired app cannot find its cube at startup: it stops and asks, rather than retrying behind a
// menu bar that says nothing.
//
// **Turning the mode on lives here and not in the loop**, which is the one thing this closure decides. The reconnector
// stops either way; what the answer changes is whether this launch is an app that times by hand, and that is
// `ManualMode`'s to record. Choosing manual mode leaves the pairing exactly as it was -- the cube is still this app's
// cube, and pairing one from the Device tab is what ends the mode (`ManualMode.stop`).
reconnector.onCubeNotFound = { _, answer in
    ManualModeAlert.ask { picked in
        if picked == .switchToManualMode {
            manualMode.start(because: "the cube could not be found and manual mode was chosen")
        }
        answer(picked)
    }
}
settingsWindow.reconnect = reconnector
// Asks for history on an interval it re-reads from the database every time it fires. With no cube paired
// there is nothing to ask, so the timeout **is** the source: the app reports its own open segment, and the
// recorder recognises it as the same event and grows its duration. When a device arrives, the fetch request
// goes in here beside this and the recorder is handed frames instead.
//
// No check on whether anything is running: an open row **is** that answer, and pausing closes its segment, so a
// paused session has nothing here to find. This used to ask an in-memory session first, which was a second copy of
// a question the table already answers, and that session is now gone for the same reason (see `TimingReadout`).
//
// **It stops while nothing is being timed and there is no cube to ask**, and both halves of that are questions put to
// the table rather than answers a pause path pushed in: pausing closes the open segment, so an open row *is* the
// answer to the first.
//
// The second half is why it is not simply "is a segment open". With a cube connected, the timeout is a fetch, and the
// cube is the one that knows what has happened -- somebody flipping it while the app believed nothing was running is
// precisely the event that would go unnoticed with the timer off. So a connected cube keeps it asking whatever the
// app's own rows say, and only an app timing nothing *with no cube to ask* lets it stop.
let historyTimer = HistoryTimer(
    settings: settings,
    debugLog: debugLog,
    hasSomethingToFollow: {
        deviceEvents.openSegment() != nil || settings.flag("connection", field: "connected") == true
    }
) {
    deviceEvents.refreshOpenSegment(at: Date())
}
historyTimer.start()

// Stops the clock when the category being timed has spent its `daily_limit`, and is then what every path that
// could start it again asks before doing so.
//
// **Manual mode is what makes this testable with no cube on the desk.** The app is the clock, so "pause the device"
// is the app's own pause path -- and when a device arrives the same `.pause` becomes `0x06 0x01` going out to it,
// with nothing in `DailyLimitEnforcement` or here changing.
let dailyLimit = DailyLimitWatch(
    timing: { timingReadout.read() },
    windowStart: { dayTotal.windowStart(at: $0) },
    debugLog: debugLog,
    stopTiming: { settingsWindow.togglePause() }
)
// Asked rather than pushed, so the refusal and the greying cannot be working from different copies of one answer.
settingsWindow.isLimitReached = { dailyLimit.isReached }

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
    togglePause: { settingsWindow.togglePause() },
    // Greys the dropdown's Resume and turns the item's right half into a no-op. `togglePause` refuses as well,
    // which is the enforcement; these two are what stop it looking like a control that is simply broken.
    isLimitReached: { dailyLimit.isReached },
    // Asked as the item is drawn, like everything else it shows. What makes it draw twice a second while a warning
    // is up is the watch itself, below.
    lowBattery: { lowBattery.alert },
    // Both halves asked at the moment the menu opens. `cubeStatus` is only ever as fresh as the last question the app
    // put to the cube -- it volunteers nothing about being locked -- which is why the item reads "Lock" when nobody
    // has asked yet rather than guessing the other way.
    cube: {
        MenuBarController.CubeReading(
            isConnected: radio.connectedDevice != nil,
            isLocked: radio.cubeStatus?.isLocked
        )
    },
    // Whichever way it is offering. What the app is holding decides, and the commands are `CubeLock`'s.
    toggleCubeLock: {
        if radio.cubeStatus?.isLocked == true {
            cubeLock.resume { _ in }
        } else {
            cubeLock.lock { _ in }
        }
    }
)
menuBar.start()

// Both surfaces repaint from one decision, which is the whole reason the warning is an object rather than a flag in
// each of them: the menu bar's category name and the Device tab's Battery row flash in step because they are told to
// flash by the same timer.
lowBattery.onChanged = {
    menuBar.redraw()
    settingsWindow.redrawLowBattery()
}
// A launch can inherit a running clock, so the watch starts here rather than waiting for somebody to press
// something: the segment it is measuring may already be over the limit.
dailyLimit.start()

// A category picked or paused in the window has to reach the item in the same moment, rather than on its next
// tick. Assigned here because each side needs the other: the item's menu is what opens the window.
// Also where the history timer comes back: it stops itself once nothing is being timed, and this is the one funnel
// every path that starts timing already goes through, so there is no separate thing for a new path to remember.
settingsWindow.onTimingChanged = {
    menuBar.redraw()
    historyTimer.resumeIfStopped()
    // The same funnel, for the same reason: this stands itself down while nothing is being timed, and every path
    // that starts the clock already comes through here, so a new one gets the limit enforced for nothing.
    dailyLimit.resumeIfStopped()
}

// Connecting Google is the other moment a sweep becomes possible. Without this, somebody who signs in after a week
// of recording would see nothing appear until their next flip -- the entries are all still waiting, and there is
// suddenly somewhere to put them.
settingsWindow.onGoogleCalendarSettled = { calendarSync.sweep(because: "a calendar was connected") }

// Last, and after everything a login reports to is wired: reaching the cube writes rows, fills the Device tab and turns
// manual mode off, so a launch that started looking any earlier could get an answer before there was anywhere to put it.
//
// **Whether there is a cube to look for is this call's own question**, read from the table rather than decided here.
reconnector.follow()

app.run()

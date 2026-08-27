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
// **The trace goes in its own file**, brought up here rather than at the top: it is only wanted when developer mode
// is on, and a launch without it should not create a database nobody is going to write to. A failure to open it is
// not a reason to refuse the launch either -- the app works perfectly well without a trace, and `DebugLog` already
// keeps printing to the terminal when the recording half cannot start.
let debugLog: DebugLog? = {
    guard DeveloperMode.isEnabled else { return nil }
    let url = (try? DatabaseBootstrap.ensureDebugDatabase().databaseURL) ?? DatabaseBootstrap.debugDatabaseURL()
    return DebugLog(databaseURL: url)
}()

// With no device paired there is nothing to follow, so the app times by hand. Startup is the first place that needs
// the answer, which is why the read happens here and not sooner -- and the only place, this being the one moment the
// mode is decided at all. Nothing after this line may change it; see `LaunchMode`.
let launchMode = LaunchMode.decided(from: settings, debugLog: debugLog)

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

// The radio, which is the app's and not the Settings window's.
//
// **It was the window's until reconnecting existed, and that is what moved it.** A paired app has to reach its cube
// whether or not anybody opens Settings -- which is most launches -- so a radio built on the first scan is one that never
// gets built. The window still drives it for scanning and pairing; it no longer owns it.
//
// **Building it does not touch the radio.** `CBCentralManager` is made on the first scan or reach, inside
// `BluetoothRadio.start`, so a launch with nothing paired still never provokes the system's Bluetooth prompt.
let radio = BluetoothRadio(debugLog: debugLog)

// What is being timed, for both things that draw it. The Faces tab and the status item read one answer rather
// than each resolving the face, the category and the total for itself -- and it is all read, including whether the
// clock is running, so a launch inherits the session the last one left instead of starting blank.
let timingReadout = TimingReadout(
    categories: categories,
    faces: faces,
    events: deviceEvents,
    dayTotal: dayTotal
)
// Which face the cube is on, asked per reading. **This is what keeps the menu bar and the Faces tab saying the same
// thing**: both draw from one reading, and this is the question that decides which of the two pictures that reading
// describes. Set here rather than passed in because the readout is built alongside the tables and the radio is not one.
//
timingReadout.deviceFace = { radio.currentFace }
// **Timing by hand means the cube is not asked about at all**, which is the other half of the reconnect loop standing
// down: that stops the app looking for a cube, and this stops one being drawn if it turns up anyway. Why is
// `TimingReadout.isTimingByHand`; that it is asked rather than copied is the same reason everything else here is.
timingReadout.isTimingByHand = { launchMode.isManual }
// **Read from the table at the moment a reading is taken**, like every other answer here. It is what tells a cube
// that has gone quiet from no cube at all: without it a dropped link fell through to the app's own faces and drew a
// manual session nobody had started.
timingReadout.isCubePaired = { settings.flag("paired", field: "paired") == true }
// What the cube said when the app asked it how it was, which is what draws the glyph until the first history frame
// arrives and `device_event` takes over. Asked per reading, and `nil` the moment the link goes.
timingReadout.cubeSaysPaused = { radio.cubeStatus?.isPaused }

// What happens on the way out, and it has to be set before `run()`. Kept in a binding because
// `NSApplication.delegate` is a **weak** reference: a quit sequence nobody retains is deallocated
// immediately and the app then ends without running any of it, silently.
let quitSequence = QuitSequence(deviceEvents: deviceEvents, debugLog: debugLog)
app.delegate = quitSequence

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
    launchMode: launchMode,
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
    // The cube's own account of what it is doing, out of `device_event` by way of the readout -- the same answer the
    // menu bar and the Faces tab draw their play/pause glyph from, so the click flips what is on show rather than
    // something only the app can see. Read at the moment it is needed, never held.
    isPaused: { timingReadout.read().deviceIsPaused },
    // A different source, because nothing else answers it: no history frame carries a lock bit and `device_event` has
    // no column for one, so `0x10` is all there is. See `CubeLock.isLocked`.
    isLocked: { radio.cubeStatus?.isLocked },
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
    // Asked rather than told, so there is one answer to "is this launch timing by hand" rather than a copy beside it.
    // It cannot move under the loop any more (`LaunchMode`), which makes asking safe as well as right.
    isTimingByHand: { launchMode.isManual }
)
// What happens when a paired app cannot find its cube at startup: it stops and asks, rather than retrying behind a
// menu bar that says nothing.
//
// **The answer decides whether to keep looking, and nothing else.** It used to decide the launch's mode as well,
// switching a device launch to timing by hand -- which is the switching `LaunchMode` exists to have removed. A launch
// that started with a cube on record stays a launch with a cube on record even when the cube cannot be found; what
// the Device tab says about that is `DeviceInfoRules.connection`'s to answer, and the way to the other mode is to
// forget the device and start the app again.
//
// So this closure now only presents the question: the reconnector stops on either answer, and the gate in `attempt`
// is what keeps it stopped.
reconnector.onCubeNotFound = { _, answer in
    CubeNotFoundAlert.ask(answer)
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
// The cube's own record of what it has been doing, on its way into `device_event`.
//
// **Built before the timer**, because the timer's tick is what asks it. The reads are handed in as closures for the
// reason every dependency in this app is: what the radio is doing is the radio's answer, at the moment it is wanted.
let historyIngestor = HistoryIngestor(
    events: deviceEvents,
    readLastEvent: { radio.readLastEvent($0) },
    fetchHistory: { from, answered in radio.fetchHistory(from: from, answered) },
    debugLog: debugLog
)
// Recorded time changed, so everything drawn from it is stale: the readings on both surfaces, the day's totals, and
// whether a category has spent its limit.
historyIngestor.onChanged = {
    menuBar.redraw()
    settingsWindow.redrawTiming()
}

let historyTimer = HistoryTimer(
    settings: settings,
    debugLog: debugLog,
    hasSomethingToFollow: {
        deviceEvents.openSegment() != nil || settings.flag("connection", field: "connected") == true
    }
) {
    // **Two sources, one tick.** With a cube connected the cube is what knows what has happened, so the tick fetches
    // its history; with none, the app is its own source and the tick is what grows the open segment it is measuring.
    // Both, not either: a manual segment left open when a cube arrives still needs its duration kept honest.
    //
    // **Which of the two a row belongs to is the recorder's to decide, not this line's.** `refreshOpenSegment` writes
    // only to the app's own faces, so a cube's row is never grown from this machine's clock: its `duration_seconds` is
    // whatever the fetch below brings back, and nothing else. What the menu bar and the Faces tab draw in between is a
    // separate question and a separate number -- see `TimingReadout.Reading.isCounting`.
    deviceEvents.refreshOpenSegment(at: Date())
    if radio.connectedDevice != nil {
        historyIngestor.refresh(because: "the timer asked")
    }
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
            isLocked: radio.cubeStatus?.isLocked,
            isPaused: radio.cubeStatus?.isPaused
        )
    },
    // Whichever way it is offering. What the app is holding decides, and the commands are `CubeLock`'s.
    //
    // **Two gestures end here**: the dropdown's Lock item and a double click on the item's right half.
    //
    // **The history fetch afterwards is the same one the pause gesture makes, and for the same reason.** Both halves
    // of this sequence move the cube's pause -- locking pauses it first, unlocking resumes it -- and the cube says
    // nothing when its pause changes. Without asking, the glyph on both surfaces would go on drawing the old state
    // until the timer next fired, which a shipped build floors at a minute.
    toggleCubeLock: {
        if radio.cubeStatus?.isLocked == true {
            cubeLock.resume { _ in
                historyIngestor.refresh(because: "the cube was unlocked from the menu bar")
            }
        } else {
            cubeLock.lock { _ in
                historyIngestor.refresh(because: "the cube was locked from the menu bar")
            }
        }
    },
    // A single click on the right half, with a cube on the other end: stop it counting, or start it again.
    //
    // **The history fetch afterwards is not tidying up, it is how the app finds out.** The cube says nothing when its
    // pause changes -- no notification follows `0x06`, which the archive measured and worked around the same way --
    // so without this the open segment would go on reporting the old state until the next tick, and the glyph the
    // click was aimed at would sit there unchanged for as long as that took.
    toggleCubePause: {
        cubeLock.togglePause { _ in
            historyIngestor.refresh(because: "the cube was paused from the menu bar")
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
// The lock badge, repainted the moment the answer moves rather than on the item's next tick.
//
// **Without this the badge is invisible for exactly the state it is for.** The tick only runs while something is being
// timed, so a locked cube with the clock stopped -- which is the ordinary case, since locking pauses -- would leave the
// item drawn as it was until something else happened to redraw it. This fires on the ask made when a link comes up, on
// the read-back of every lock or unlock the app sends, and on the link going away, which is what takes the badge off
// again: `BluetoothRadio` clears the status with the connection and reports that as a change like any other.
radio.onCubeStatus = { _, _ in
    menuBar.redraw()
}
// A flip repaints both surfaces, from here rather than from either of them.
//
// **One callback with two listeners, so it is assigned once.** The Settings window used to take this for itself, and
// the menu bar needing it too would have been a second assignment quietly replacing the first -- the tab would simply
// have stopped following flips, with nothing to see. Both are told, and both then read the same `TimingReadout`.
//
// The menu bar needs it for the same reason the lock badge does: the item's tick only runs while the app itself is
// timing something, and following a cube is precisely when it is not.
radio.onFace = { _, _ in
    menuBar.redraw()
    settingsWindow.redrawTiming()
    // **A flip closed a segment and opened another**, which is exactly what history is a record of, so this is the
    // moment to go and get it rather than waiting out the rest of the tick. It also refreshes whether the cube is
    // paused, because every frame carries that in its face byte -- see `timingReadout.isDevicePaused`.
    historyIngestor.refresh(because: "the cube was turned")
}
// **The link coming up is its own reason to ask, and it used to be nobody's.** The fetch on connect happened only
// because the face read that follows a login produced a flip nobody had made, so the log said "the cube was turned"
// about a cube sitting still, and a cube whose faces characteristic went missing would have brought back no history at
// all. This asks because the link is up, which is what is actually true.
//
// **`onCubeReady`, not `onLoginEnded`.** A login ends when the PIN is accepted, which is several round trips before
// the characteristics are discovered -- ask then and the cube has no history characteristic yet, which is precisely
// the fault this pass fixed.
//
// The face read still fires its own refresh a moment later and `HistoryIngestor` drops it while this one is running,
// with a row saying so. That is the guard doing its job rather than a duplicate to be designed away: both are real
// reasons to ask, and the one that arrives second is simply not needed yet.
radio.onCubeReady = { _ in
    historyIngestor.refresh(because: "the link came up")
}
// **The other end of the same thought.** A fetch waits on answers the radio delivers, so a link ending mid-conversation
// leaves it in flight with nothing ever going to finish it -- and one fetch at a time then means no fetch ever again.
// The mirror of the refresh above: what a link coming up starts, a link going has to let go of.
radio.onLinkEnded = { _ in
    historyIngestor.linkEnded()
}
// What the cube says about its own condition, which until now the app subscribed to and threw away.
//
// **A factory reset is the one this can act on, and acting means asking again.** There is no cursor to clear first:
// the resume position is read out of `device_event` on every refresh and checked against what the cube can reach, so a
// counter back at the bottom is followed down without anything having to be told a reset happened. That is the
// archive's own reasoning, kept whole -- and its own caveat with it: a cube straight after a reset holds no history at
// all, so this finds nothing until the first flip.
//
// **The rest is written down and not acted on**, deliberately. The cube can ask for its time, its face colours, its
// LED brightness, its blink interval, its task parameters or its auto-pause delay, and this app has no way to push most
// of those yet -- so a row saying it asked is the honest answer, and it is a great deal better than the silence there
// was before. `BluetoothRadio.received(systemState:from:)` writes it, including the hardware half, which is where a
// **flash memory fault** turns up: history lives in flash, so a cube reporting one records nothing, and from the
// outside that looks exactly like a cube that was reset.
radio.onSystemState = { _, state in
    guard state.sync == .factoryReset else { return }
    historyIngestor.refresh(because: "the cube says it was put back to the factory")
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

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

// **The trace goes in its own file**, and both of the `debug` row's fields are read here, at launch.
//
// **`enabled` is where it starts, not where it stays.** The logger is built either way and records only while the
// row says so, so ticking the box on the App tab starts the trace at that moment and unticking it stops it, with no
// relaunch (`DebugLog.setRecording`). What makes that free to leave off is the message being an autoclosure: with
// recording off a call site costs one boolean check and builds no string at all.
//
// **Nothing is created here.** `DebugLog` brings its database up on the first message it actually records, so a
// launch that never records leaves no `debug.sqlite` behind, and a folder that cannot be opened falls back with a
// line saying so rather than silently taking the trace with it.
//
// **The folder is the one part that is not live.** The file is open from the first message to quit, so a folder
// chosen on the App tab applies at the next launch, which the section says out loud.
let debugLog: DebugLog? = {
    let stored = settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)
        ?? DebugTraceRules.defaultDirectory
    return DebugLog(
        databaseURL: DatabaseBootstrap.debugDatabaseURL(in: DebugTraceRules.directoryURL(from: stored)),
        isRecording: settings.flag(DebugTraceRules.setting, field: DebugTraceRules.enabledField)
            ?? DebugTraceRules.defaultEnabled
    )
}()

// With no device paired there is nothing to follow, so the app times by hand.
//
// **One derivation, defined here and asked rather than held.** Timing by hand is not a fact of its own: it is what
// being unpaired means, and `paired` is the table's to answer. So this reads the row every time somebody asks, which
// is `CLAUDE.md`'s first rule and, here, the whole of what lets the app follow a cube the moment one is paired
// instead of at the next launch. It replaced a `LaunchMode` decided once at startup, whose value could not move while
// the row under it did -- which is two answers to one question, and cost a restart after every pair, forget and reset
// to keep them in step.
//
// **Every reader takes this closure rather than a copy**, so nothing has to be told when the answer changes. What
// does have to be told is anything that draws intermittently: the menu bar repaints on a tick that only runs while
// something is being timed, so it is redrawn where the pairing changes, and where this launch gives up on its cube
// (`reconnector.onGaveUpOnCube`).
//
// **The second input, and why it is a closure with a default rather than a value.** A paired launch that could not
// find its cube and was told to time by hand is the app's own clock too, and that fact lives on the reconnect loop
// -- which is built a long way below this, because it needs the radio. So this starts as the truth at launch, when
// nothing can have given up yet, and is pointed at the loop once there is one. `TimingReadout.isCubePaired` is the
// same idiom for the same reason.
var hasGivenUpOnCube: () -> Bool = { false }
let isManualMode = {
    ManualTimerRules.isManualMode(
        isCubePaired: settings.flag("paired", field: "paired") == true,
        hasGivenUpOnCube: hasGivenUpOnCube()
    )
}

// **What this launch started as, for the log and nothing else.** Nothing branches on it: the row is here so a run
// reconstructed from `debug_log` says which of the two the app came up as, which is the first thing worth knowing
// about a session and is otherwise only inferable from what happened next.
debugLog?.record(
    .mode,
    isManualMode()
        ? "Launch mode: manual, no device is paired"
        : "Launch mode: device, a device is paired"
)

let app = NSApplication.shared
// `.accessory`: a menu bar app, so no Dock icon, and no menu bar of its own for as long as it stays
// that way. `SettingsWindowController` switches to `.regular` while its window is open and back
// afterwards, so the bar below is on screen for exactly that span.
app.setActivationPolicy(.accessory)
// The menu bar that span needs: an app menu, and an Edit menu whose four items are what make ⌘X, ⌘C,
// ⌘V and ⌘A work in a text field at all. Nothing else routes a keystroke to the field editor -- see
// `MainMenu`, which is also where the dropdown's Quit having no ⌘Q is followed through.
MainMenu.install(into: app)

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
timingReadout.cubeFace = { radio.cubeFace }
// **Timing by hand means the cube is not asked about at all**, which is the other half of the reconnect loop standing
// down: that stops the app looking for a cube, and this stops one being drawn if it turns up anyway. Why is
// `TimingReadout.isManualMode`; that it is asked rather than copied is the same reason everything else here is.
timingReadout.isManualMode = isManualMode
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
    isManualMode: isManualMode,
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
    isCubeConnected: { radio.connectedDevice != nil },
    send: { command, reported in radio.send(command, reported) },
    // The cube's own account of what it is doing, out of `device_event` by way of the readout -- the same answer the
    // menu bar and the Faces tab draw their play/pause glyph from, so the click flips what is on show rather than
    // something only the app can see. Read at the moment it is needed, never held.
    cubePauseState: { timingReadout.read().cubePauseState },
    // A different source, because nothing else answers it: no history frame carries a lock bit and `device_event` has
    // no column for one, so `0x10` is all there is. See `CubeLock.isLocked`.
    cubeLockState: { CubeLockState(reported: radio.cubeStatus?.isLocked) },
    debugLog: debugLog
)
// The other half of the way out: the cube is paused and then locked before the link is given back, so a device left on
// the desk is not still counting time against whatever face was up when the app went away.
quitSequence.cubeLock = cubeLock

// What the cube lights each face in. Built here rather than inside the window, because the window is not who mostly
// tells it anything: a link coming up sends all twelve, and the Settings window is one of four things that change one.
let faceColours = FaceColourSync(
    send: { command, reported in radio.send(command, reported) },
    isCubeConnected: { radio.connectedDevice != nil },
    // **Two reads and a fallback, taken at the moment the command is built** rather than a table of colours kept
    // anywhere. `categoryID(forFace:)` answers `nil` for a face holding the seeded *Unassigned* row, and
    // `CategoryRecord.colour` is `nil` for the *None* colour; both mean the same thing to a cube, and
    // `FaceColourRules.channels` is the one place that turns either into black.
    faceColour: { face in
        let category = faces.categoryID(forFace: face).flatMap { categories.category(id: $0) }
        return FaceColour(face: face, categoryName: category?.name, colour: category?.colour)
    },
    debugLog: debugLog
)

// What the cube is *set* to, as against what it is lit in: the auto-pause delay, the two LED values and the four
// double-tap registers, all of which the Device tab writes when somebody moves them and nothing ever wrote again.
//
// **Built here for `FaceColourSync`'s reason**, and it is stronger here: the window is not who mostly tells the cube
// these things. A link coming up does, and so does the cube itself, and neither of those has a window open.
//
// **Every value is read from the table at the moment its command is built**, which is why this takes a closure and
// not a snapshot: a setting edited while a queue is waiting its turn goes out as what it is now.
let deviceSettings = DeviceSettingsSync(
    send: { command, reported in radio.send(command, reported) },
    isCubeConnected: { radio.connectedDevice != nil },
    stored: {
        let seeded = DevicePane.Values.seeded
        return DeviceSettingsSync.Stored(
            autoPauseMinutes: settings.integer("auto_pause_minutes", field: "minutes") ?? seeded.autoPauseMinutes,
            ledBrightnessPercent: settings.integer("led_settings", field: "brightness") ?? seeded.ledBrightnessPercent,
            ledBlinkSeconds: settings.integer("led_settings", field: "blink_interval") ?? seeded.ledBlinkSeconds,
            // Clamped on the way out of the table, as the tab's own fields are: a register is one byte, and a row
            // holding something else is a fault to survive rather than a reason to send nothing.
            doubleTap: DoubleTapParameters(
                threshold: UInt8(clamping: settings.integer("double_tap_settings", field: "clickThreshold") ?? seeded.doubleTapThreshold),
                limit: UInt8(clamping: settings.integer("double_tap_settings", field: "limit") ?? seeded.doubleTapLimit),
                latency: UInt8(clamping: settings.integer("double_tap_settings", field: "latency") ?? seeded.doubleTapLatency),
                window: UInt8(clamping: settings.integer("double_tap_settings", field: "window") ?? seeded.doubleTapWindow)
            ),
            isDoubleTapEnabled: settings.flag("double_tap_settings", field: "enabled") ?? seeded.isDoubleTapEnabled
        )
    },
    debugLog: debugLog
)
settingsWindow.faceColours = faceColours

// What keeps a paired app's cube reachable: it looks for it now, and goes on looking whenever the link goes.
//
// **Both are closures rather than values**, for the reason every read in this app is at the point of use: the PINs
// this app holds live in the Keychain and in a file a developer also edits by hand, so an attempt an hour from now
// must present what they say then -- and the PIN to put on a cube is fresh random digits every time it is asked for
// in any build but a developer's.
let reconnector = DeviceReconnector(
    radio: radio,
    settings: settings,
    debugLog: debugLog,
    storedPINs: { DevicePINSource(debugLog: debugLog).stored() },
    rotatingTo: { DevicePINRules.target() }
)
// **The mode derivation gets its second input**, now that the thing holding it exists. Assigned rather than passed
// in, so `isManualMode` above is the only place the two inputs are put together and every reader goes through it.
hasGivenUpOnCube = { reconnector.hasGivenUpOnCube }

// **Whether the two PIN stores are saying different things, asked once, here.**
//
// They disagree only after a Keychain write that failed: the PIN went into `config.json` instead, so the file holds
// what the cube took and the Keychain holds what it was on before. Neither this app nor anything else can tell which
// is right without asking the cube, so the answer waits for a login -- and the first login of the launch is the one
// that gets it, because that is when the question was asked.
//
// **Armed at launch and disarmed by the first accepted PIN**, which is what makes this a startup check rather than
// something running on every connect: once a launch has settled the two stores there is nothing left to ask until
// something writes again, and that write is itself a rotation that puts both in step.
var isReconcilingPINStores = DevicePINSource(debugLog: debugLog).settleAtLaunch() == .awaitingTheCube
radio.onPINAccepted = { _, pin in
    guard isReconcilingPINStores else { return }
    // **Disarmed by an answer that settled it, not by any login at all.** A cube can accept a PIN from neither store
    // -- the vendor default on a factory-reset confirmation is exactly that, and it happens on an ordinary run --
    // and letting that spend the launch's one question would leave the two stores disagreeing until the next launch
    // for no reason.
    guard DevicePINSource(debugLog: debugLog).reconcile(accepted: pin) != .nothingHappened else { return }
    isReconcilingPINStores = false
}

// What happens when a paired app cannot find its cube at startup: it stops and asks, rather than retrying behind a
// menu bar that says nothing.
//
// **Three answers, and each one is a different thing to want.** Rescan waits for the cube, Time by Hand gets on
// without it, and Quit leaves. The middle one changes what the app is doing for the rest of the launch, which is what
// this offer is for and what it had briefly stopped doing: the version before this settled the reconnect loop and
// left the Faces tab refusing every click, so somebody who had just said they wanted to work without the cube could
// not start a clock.
//
// **What made that safe to give back is that nothing holds a mode.** The old switching set one and every surface had
// to be told; this sets one per-launch flag on the loop and `ManualTimerRules.isManualMode` reads it, so the answer
// arrives everywhere by being asked for rather than by being sent.
//
// This closure only presents the question. What each answer does is the reconnector's.
reconnector.onCubeNotFound = { _, answer in
    CubeNotFoundAlert.ask(answer)
}
// **Quit goes out the same door as the menu bar's Quit**, so the quit sequence runs exactly as it does from there
// rather than this being a second way to end the process.
reconnector.onQuitRequested = { NSApp.terminate(nil) }
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
    // **Which clock is running decides where the stop goes**, and the open segment's face is what says so -- the same
    // test `DeviceEventRecorder.closeOpenSegment` makes before it will write a row. A cube's pause is a command; the
    // app's is a row, and sending one where the other was wanted does nothing at all.
    //
    // **It did exactly that until now.** This was `settingsWindow.togglePause()` outright, which is the app's own
    // clock, so with a cube on the other end the limit reached `closeOpenSegment`, was refused on the face, and logged
    // that the row was left open for the cube to report the length of. Nothing went out, nothing was corrupted, and
    // the limit simply did not apply to a device. `12-daily-limit` never caught it: it sits below 50 and runs in
    // manual mode, where the wiring it had was the right one.
    //
    // **The fetch afterwards is how the app finds out**, not tidying up. Measured 2026-08-27 (finding 9 in
    // `docs/timeflip2-firmware-observations.md`): a pause files a new history event on the cube and the cube
    // announces nothing, so without asking, the open segment would go on reporting the old state.
    stopTiming: {
        guard let open = deviceEvents.openSegment(), !ManualFace.isAppFace(open.face) else {
            settingsWindow.togglePause()
            return
        }
        cubeLock.setPause(true) { _ in
            historyIngestor.refresh(because: "a category spent its daily limit")
        }
    }
)
// Asked rather than pushed, so the refusal and the greying cannot be working from different copies of one answer.
settingsWindow.isLimitReached = { dailyLimit.isLimitReached }
// **The fourth path that could send a resume, and the one that was not refusing.** Unlocking resumes the cube, so a
// double click on the status item's right half was a way round a spent limit: lock, unlock, and the budget is
// spendable again until the watch notices. `CubeLock.resume` now unlocks and leaves it stopped.
cubeLock.isLimitReached = { dailyLimit.isLimitReached }

// Stops the cube when it is resting on a face with no category, and starts it again when that face is given one.
//
// **Time the app cannot attribute is time it will not let the cube record.** The decision is `ForcedPause` and this
// only puts it on the wire; both are driven from the two funnels below rather than from a tick, there being nothing
// else that can change the answer.
//
// **After the daily limit deliberately**, because the two decide the same cube's pause state and a hard limit has to
// win: `limitIsHolding` is what stands this down while the limit has one of its own.
let forcedPause = ForcedPauseWatch(
    // The cube's own open row and nothing else. `ManualFace.isAppFace` filters 13 and 14 out here rather than in the
    // decision, so what the decision is handed is only ever a face a cube reported.
    cubeFace: { deviceEvents.openSegment().map(\.face).flatMap { ManualFace.isAppFace($0) ? nil : $0 } },
    hasCategory: { faces.categoryID(forFace: $0) != nil },
    // **The same three sources `CubeLock` reads**, deliberately: the thing deciding to send a pause and the thing
    // sending it must not be working from different answers about whether the cube is stopped, locked or reachable.
    cubePauseState: { timingReadout.read().cubePauseState },
    cubeLockState: { CubeLockState(reported: radio.cubeStatus?.isLocked) },
    isCubeConnected: { radio.connectedDevice != nil },
    limitIsHolding: { dailyLimit.isLimitHoldingPause },
    setPause: { wanted, then in cubeLock.setPause(wanted, then: then) },
    refreshHistory: { reason, done in historyIngestor.refresh(because: reason) { _ in done() } },
    debugLog: debugLog
)

// Recorded time changed, so everything drawn from it is stale: the readings on both surfaces, the day's totals, and
// whether a category has spent its limit.
historyIngestor.onChanged = {
    menuBar.redraw()
    settingsWindow.redrawTiming()
    // **The limit's tick stands itself down the moment nothing is being timed, and a pause is exactly that**, so
    // without this the watch dies at the first limit it enforces and never looks again. `resumeIfStopped` was reached
    // only from `onTimingChanged`, which every path that starts the *app's* clock goes through and no cube ever does.
    //
    // That is what makes a flip back onto a spent category work: the flip resumes the cube in firmware, this fetch
    // brings the frame in, the tick comes back because something is running again, and the evaluation that follows
    // finds a category still spent for the day. Without it the cube is stopped once and then left alone for ever.
    //
    // Cheap where it does nothing: `resumeIfStopped` returns at once if the tick is already up, and `start` refuses
    // unless something really is running.
    dailyLimit.resumeIfStopped()
    // **An event came in, so the face the cube is resting on may be one with nothing on it.** This is the moment that
    // is true of, and a flip reaches it promptly: the faces characteristic notifies and the app fetches on it, so this
    // does not wait out `fetch_history_interval_seconds`.
    forcedPause.check()
}

let menuBar = MenuBarController(
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
    isLimitReached: { dailyLimit.isLimitReached },
    // Asked as the item is drawn, like everything else it shows. What makes it draw twice a second while a warning
    // is up is the watch itself, below.
    lowBattery: { lowBattery.alert },
    // Both halves asked at the moment the menu opens. `cubeStatus` is only ever as fresh as the last question the app
    // put to the cube -- it volunteers nothing about being locked -- which is why the item reads "Lock" when nobody
    // has asked yet rather than guessing the other way.
    cube: {
        MenuBarController.CubeReading(
            isCubeConnected: radio.connectedDevice != nil,
            cubeLockState: CubeLockState(reported: radio.cubeStatus?.isLocked),
            cubePauseState: CubePauseState(reported: radio.cubeStatus?.isPaused)
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
        if CubeLockState(reported: radio.cubeStatus?.isLocked) == .locked {
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
// Giving up on the cube repaints both surfaces, because the answer to "who is the clock" has just moved and neither
// of them is on a tick that would notice.
//
// **This is a redraw and not a notification**, which is the distinction the whole derivation rests on: nothing here
// tells anything what the app now is, it tells two views to go and ask. The menu bar has to be told because its tick
// only runs while something is being timed, and nothing is; the Faces tab has to be told because its own repaint
// hangs off a flip, and there is no cube to flip. Every other reader asks the next time it draws.
reconnector.onGaveUpOnCube = {
    menuBar.redraw()
    settingsWindow.redrawTiming()
}
// The lock badge, repainted the moment the answer moves rather than on the item's next tick.
//
// **Without this the badge is invisible for exactly the state it is for.** The tick only runs while something is being
// timed, so a locked cube with the clock stopped -- which is the ordinary case, since locking pauses -- would leave the
// item drawn as it was until something else happened to redraw it. This fires on the ask made when a link comes up, on
// the read-back of every lock or unlock the app sends, and on the link going away, which is what takes the badge off
// again: `BluetoothRadio` clears the status with the connection and reports that as a change like any other.
radio.onCubeStatus = { _, status in
    menuBar.redraw()
    // **The cube's own answer about its auto-pause delay, which is the only one there is.** A disagreement with the
    // table is a cube that has lost the setting -- a reset, a flat battery, the vendor's app -- and this is the first
    // moment it can be noticed. `nil` is the status being cleared with the link, which says nothing about a cube.
    guard let status else { return }
    deviceSettings.cubeReported(status: status)
}
// A flip repaints both surfaces, from here rather than from either of them.
//
// **One callback with two listeners, so it is assigned once.** The Settings window used to take this for itself, and
// the menu bar needing it too would have been a second assignment quietly replacing the first -- the tab would simply
// have stopped following flips, with nothing to see. Both are told, and both then read the same `TimingReadout`.
//
// The menu bar needs it for the same reason the lock badge does: the item's tick only runs while the app itself is
// timing something, and following a cube is precisely when it is not.
// The four registers the cube reports on every connection, against the four the table holds.
radio.onDoubleTapParameters = { _, parameters in
    deviceSettings.cubeReported(doubleTap: parameters)
}
radio.onFace = { _, _ in
    menuBar.redraw()
    settingsWindow.redrawTiming()
    // **A flip closed a segment and opened another**, which is exactly what history is a record of, so this is the
    // moment to go and get it rather than waiting out the rest of the tick. It also refreshes whether the cube is
    // paused, because every frame carries that in its face byte -- see `timingReadout.cubePauseState`.
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
// **Every face, every time the link comes up, and nothing remembered between times.** `0x11` has no read-back, so the
// only record of what a cube is showing would be a note the app wrote to itself -- which is the second copy of a fact
// `CLAUDE.md`'s first rule is about, and it goes stale the moment anything else colours the cube. Twelve writes is what
// the archive itself did on the first connect of every run; see `FaceColourSync`.
//
// **`onCubeSettled`, not `onCubeReady`.** The two fire a few round trips apart, and a command sent on the earlier one
// writes over a question the login still has out. The history fetch above is on the earlier one deliberately, being a
// question rather than a command and wanting to be first in the queue.
radio.onCubeSettled = { _ in
    faceColours.linkSettled()
    // **After the colours, and it makes no difference which order they are called in.** Both queue their own work and
    // `DeviceLogin` serialises the commands themselves (`enqueue`), so the two runs interleave on the wire rather
    // than one writing over the other.
    deviceSettings.linkSettled()
}
// **The other end of the same thought.** A fetch waits on answers the radio delivers, so a link ending mid-conversation
// leaves it in flight with nothing ever going to finish it -- and one fetch at a time then means no fetch ever again.
// The mirror of the refresh above: what a link coming up starts, a link going has to let go of.
radio.onLinkEnded = { _ in
    historyIngestor.linkEnded()
    // The same thought again: what is queued for a cube that has gone is dropped rather than sent one refusal at a
    // time.
    faceColours.linkEnded()
    deviceSettings.linkEnded()
}
// What the cube says about its own condition, which until now the app subscribed to and threw away.
//
// **A factory reset is the one this can act on, and acting means asking again.** There is no cursor to clear first:
// the resume position is read out of `device_event` on every refresh and checked against what the cube can reach, so a
// counter back at the bottom is followed down without anything having to be told a reset happened. That is the
// archive's own reasoning, kept whole -- and its own caveat with it: a cube straight after a reset holds no history at
// all, so this finds nothing until the first flip.
//
// **Every request the cube can make is now answered by something, bar one.** It can ask for its time, its face
// colours, its LED brightness, its blink interval, its auto-pause delay or its task parameters; the first is the
// login's, the second is `FaceColourSync`'s, the next three are `DeviceSettingsSync`'s, and the last is the one
// nothing here can answer -- this app has never set a task parameter, so it has nothing to send and says so.
// `BluetoothRadio.received(systemState:from:)` writes every one of them down regardless, including the hardware
// half, which is where a **flash memory fault** turns up: history lives in flash, so a cube reporting one records
// nothing, and from the outside that looks exactly like a cube that was reset.
radio.onSystemState = { _, state in
    // **The one that needs a run of twelve writes.** A cube that has lost its face colours says so here,
    // and it says so repeatedly -- which is why the answer is collapsed rather than given once per notification. See
    // `FaceColourSync.cooldownSeconds`, where the archive records what answering one for one did to a failing device.
    if state.cubeSyncState == .faceColoursRequired {
        faceColours.cubeAskedForThem()
    }
    // **And everything else it can ask for that this app is the record of**: its time, its auto-pause delay, its LED
    // brightness and its blink period. Answering these is what the archive did (`reconcileSystemState`) and what this
    // app used to write down and ignore. Task parameters are the one request nothing here can answer, and
    // `DeviceSettingsSync` says so rather than passing over it.
    deviceSettings.cubeAsked(for: state.cubeSyncState)
    guard state.cubeSyncState == .factoryReset else { return }
    historyIngestor.refresh(because: "the cube says it was put back to the factory")
    // A wiped cube has the factory colours, whatever it was last told. Nothing needs to ask for this: a reset drops
    // the link, and the reconnect behind it sends all twelve.
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
    // **The other half, and the only route to it.** Giving a face a category changes a table with the cube sitting
    // still, so no history event follows and nothing else would ever notice. `SettingsWindowController` comes through
    // here after every assignment for exactly this sort of reason.
    forcedPause.check()
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

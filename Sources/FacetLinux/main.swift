import FacetCore
import Foundation

// **The Linux entry point, and it is deliberately only the part that has an answer.** Startup, in the
// same order as the macOS `main.swift` and for the same reasons: prove this is the only instance, bring
// the database up, then start the trace. Every step is ahead of the one that would be wrong to do twice.
//
// **What is missing here is missing on purpose, not forgotten.** There is a menu bar item, a radio and no
// Settings window: the rest of the UI is the remainder of item 11 of `docs/linux-port.md`, and the decisions it
// would need are still to come out into the core (`docs/handover-linux.md` item 22).
//
// **The boot is not Linux-specific and the bar is.** Everything down to the debug log is `FacetCore` and
// a near-transcription of the macOS `main.swift`, which is AppKit-free for its first hundred lines -- the two
// platforms start the same way because there is only one way to start. What differs begins at `MenuBar`, which
// is GTK where the other is AppKit, and at the radio, which is BlueZ where the other is CoreBluetooth.
//
// **The device half is composed here as of 2026-09-11**, which is what a composition root is for: this is the
// only file on this platform allowed to know both halves. `DeviceLogin`, `DeviceReconnector`,
// `CubeCommandChannel`, `HistoryIngestor`, `HistoryTimer`, `CubeLock`, `FaceColourSync`, `DeviceSettingsSync`,
// `LowBatteryWatch` and `DailyLimitWatch` all run here unchanged, because none of them knows what platform it
// is on.

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
    // The app is refusing to start, so the reason has to reach whoever launched it. On this platform that
    // is more than a formality: the DDL is found through `Bundle.module`, which resolves beside the
    // executable, so a binary installed without `Facet_FacetCore.resources` next to it fails here.
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
let entries = TimeEntryStore(connection: database)

// **This is where the platform gets chosen, and the only place it is.** The core states what it needs as a
// protocol and cannot find out which adapter it got: `CLAUDE.md`, *The core is platform-blind*. The macOS root
// hands over a `KeychainSecretStore` at exactly this point; this one hands over the login keyring.
let secrets: SecretStore = SecretToolStore()
let devicePINs = DevicePINStore(secrets: secrets)

// **The trace goes in its own file**, and both of the `debug` row's fields are read here, at launch, so
// that a scripted check has something to poll for. `DebugLog` creates nothing until the first message it
// actually records, so a launch with logging off leaves no `debug.sqlite` behind.
let debugLog: DebugLog? = {
    let stored = settings.string(DebugTraceRules.setting, field: DebugTraceRules.directoryField)
        ?? DebugTraceRules.defaultDirectory
    return DebugLog(
        databaseURL: DatabaseBootstrap.debugDatabaseURL(in: DebugTraceRules.directoryURL(from: stored)),
        isRecording: settings.flag(DebugTraceRules.setting, field: DebugTraceRules.enabledField)
            ?? DebugTraceRules.defaultEnabled
    )
}()

debugLog?.record(.launch, "Facet started on Linux")
debugLog?.record(.launch, "Database at \(databaseURL.path)")

// The two tables that record time, in the order the answer flows: a segment is recorded first, and closing one
// raises the question the second module answers. `device_event` is what a source says happened; `time_entry` is
// what the app counts, and they are deliberately not the same question.
let timeEntries = TimeEntryRecorder(connection: database, settings: settings, faces: faces, debugLog: debugLog)
let deviceEvents = DeviceEventRecorder(connection: database, timezones: timezones,
                                       timeEntries: timeEntries, debugLog: debugLog)

// A launch inherits whatever the last one left behind. A segment still open on one of the app's own faces is a
// launch that ended without its quit sequence, and closing it here, before anything else reads the table, is what
// stops the history timer measuring it from its start to now.
deviceEvents.closeSegmentsStrandedOnAppFaces()

let dayTotal = DayTotal(settings: settings, entries: entries, events: deviceEvents, faces: faces)

// **The clock, handed over rather than reached for.** One instance, because there is one main context, which
// is the same reason the Mac makes one `RunLoopScheduler`. Nothing above this line knows which of the two it
// has: `HistoryTimer`, `LowBatteryWatch`, `DailyLimitWatch`, `DeviceReconnector`, `WriteDebounce` and
// `QuitSequence` all take a `Scheduler`, and the menu bar's own repaint tick takes this one.
let scheduler = GLibScheduler()

// The radio, which is the app's and not any window's -- there being no window here at all. A paired app has to
// reach its cube whether or not anybody is looking, which is what makes this the composition root's rather than a
// surface's on either platform.
//
// **The bus is opened here and nowhere else.** `SystemBus` is one connection to the system daemon, shared by the
// scan, the GATT tables and the signal pump, exactly as `BluetoothRadio` is one `CBCentralManager`.
let radio: BlueZCubeRadio? = {
    do {
        let bus = try SystemBus()
        return BlueZCubeRadio(
            link: BlueZBusLink(bus: bus, scheduler: scheduler, debugLog: debugLog),
            scheduler: scheduler,
            debugLog: debugLog
        )
    } catch {
        // **A launch without a bus still starts**, which is the same judgement the instance lock makes about a
        // home directory it cannot write: the app has a database, a menu bar and its own clock, and refusing to
        // come up would take those away to punish a missing daemon. What it cannot do is reach a cube, and it says
        // so once here rather than at every attempt.
        debugLog?.record(.launch, "There is no system bus, so this launch cannot reach a cube: \(error)")
        return nil
    }
}()

// Written down where the app knows it is talking to the right cube: the pairing, the name, what the cube says it
// is, and whether it can be heard from right now. Five rows and three lifetimes; see `DevicePairingRecorder`.
let pairing = DevicePairingRecorder(settings: settings, debugLog: debugLog)

// With no device paired there is nothing to follow, so the app times by hand.
//
// **One derivation, defined here and asked rather than held**, exactly as on the Mac: timing by hand is not a fact
// of its own, it is what being unpaired means, and `paired` is the table's to answer. The second input lives on the
// reconnect loop, which is built below because it needs the radio, so this starts as the truth at launch -- nothing
// can have given up yet -- and is pointed at the loop once there is one.
var hasGivenUpOnCube: () -> Bool = { false }
let isManualMode = {
    ManualTimerRules.isManualMode(
        isCubePaired: settings.flag("paired", field: "paired") == true,
        hasGivenUpOnCube: hasGivenUpOnCube()
    )
}

// **What this launch started as, for the log and nothing else.** Nothing branches on it: the row is here so a run
// reconstructed from `debug_log` says which of the two the app came up as.
debugLog?.record(
    .mode,
    isManualMode()
        ? "Launch mode: manual, no device is paired"
        : "Launch mode: device, a device is paired"
)

// **The same readout the menu bar and the Faces tab share on the other platform**, built from the same
// four collaborators and asked rather than pushed. Its cube-facing questions go to the radio at the moment a
// reading is taken, which is what keeps this platform's menu bar and the cube saying the same thing.
let timingReadout = TimingReadout(categories: categories, faces: faces, events: deviceEvents, dayTotal: dayTotal)
timingReadout.cubeFace = { radio?.cubeFace }
timingReadout.isManualMode = isManualMode
timingReadout.isCubePaired = { settings.flag("paired", field: "paired") == true }
timingReadout.cubeSaysPaused = { radio?.cubeStatus?.isPaused }

// What happens on the way out. **Held for the life of the process**, because the menu bar's Quit item is what runs
// it and there is nothing else keeping it alive.
let quitSequence = QuitSequence(deviceEvents: deviceEvents, debugLog: debugLog, scheduler: scheduler)
quitSequence.letGoOfTheDevice = {
    guard let radio, radio.connectedDevice != nil else { return false }
    radio.disconnect(because: "the app is quitting")
    pairing.recordQuit()
    return true
}

// The low-battery warning. **Built here because it is the app's and not a window's**: the flash it drives is in the
// menu bar, which is up whether or not anything else is.
let lowBattery = LowBatteryWatch(
    level: { radio?.batteryPercent },
    settings: settings,
    debugLog: debugLog,
    scheduler: scheduler
)

// Stopping the cube, which the quit asks for. One object so the order, the setting and the read-backs are decided
// once -- see `CubeLock`, and the note there about why the order is not arbitrary.
let cubeLock = CubeLock(
    settings: settings,
    isCubeConnected: { radio?.connectedDevice != nil },
    send: { command, reported in
        guard let radio else {
            reported(false)
            return
        }
        radio.send(command, reported)
    },
    cubePauseState: { timingReadout.read().cubePauseState },
    // A different source, because nothing else answers it: no history frame carries a lock bit and `device_event`
    // has no column for one, so `0x10` is all there is. See `CubeLock.isLocked`.
    cubeLockState: { CubeLockState(reported: radio?.cubeStatus?.isLocked) },
    debugLog: debugLog
)
quitSequence.cubeLock = cubeLock

// What the cube lights each face in. A link coming up sends all twelve; `0x11` has no read-back, so nothing here
// remembers what a cube is showing.
let faceColours = FaceColourSync(
    send: { command, reported in
        guard let radio else {
            reported(false)
            return
        }
        radio.send(command, reported)
    },
    isCubeConnected: { radio?.connectedDevice != nil },
    faceColour: { face in
        let category = faces.categoryID(forFace: face).flatMap { categories.category(id: $0) }
        return FaceColour(face: face, categoryName: category?.name, colour: category?.colour)
    },
    debugLog: debugLog
)

// What the cube is *set* to, as against what it is lit in. **Every value is read from the table at the moment its
// command is built**, which is why this takes a closure and not a snapshot.
let deviceSettings = DeviceSettingsSync(
    send: { command, reported in
        guard let radio else {
            reported(false)
            return
        }
        radio.send(command, reported)
    },
    isCubeConnected: { radio?.connectedDevice != nil },
    stored: {
        let seeded = DeviceSettingsSync.Stored.seeded
        return DeviceSettingsSync.Stored(
            autoPauseMinutes: settings.integer("auto_pause_minutes", field: "minutes") ?? seeded.autoPauseMinutes,
            ledBrightnessPercent: settings.integer("led_settings", field: "brightness") ?? seeded.ledBrightnessPercent,
            ledBlinkSeconds: settings.integer("led_settings", field: "blink_interval") ?? seeded.ledBlinkSeconds,
            // Clamped on the way out of the table: a register is one byte, and a row holding something else is a
            // fault to survive rather than a reason to send nothing.
            doubleTap: DoubleTapParameters(
                threshold: UInt8(clamping: settings.integer("double_tap_settings", field: "clickThreshold")
                    ?? Int(seeded.doubleTap.threshold)),
                limit: UInt8(clamping: settings.integer("double_tap_settings", field: "limit")
                    ?? Int(seeded.doubleTap.limit)),
                latency: UInt8(clamping: settings.integer("double_tap_settings", field: "latency")
                    ?? Int(seeded.doubleTap.latency)),
                window: UInt8(clamping: settings.integer("double_tap_settings", field: "window")
                    ?? Int(seeded.doubleTap.window))
            ),
            isDoubleTapEnabled: settings.flag("double_tap_settings", field: "enabled") ?? seeded.isDoubleTapEnabled
        )
    },
    debugLog: debugLog
)

// What keeps a paired app's cube reachable: it looks for it now, and goes on looking whenever the link goes.
//
// **`onCubeNotFound` is deliberately not set**, and `DeviceReconnector.ask` has a path for that: with no presenter
// it schedules the next attempt instead of standing down. That is the honest behaviour until this platform has a
// dialogue slot (item 21 of `docs/handover-linux.md`) -- a cube out of range comes back, and quietly timing by hand
// without having asked would be the app deciding something the user was never offered.
let reconnector: DeviceReconnector? = radio.map { radio in
    DeviceReconnector(
        radio: radio,
        settings: settings,
        debugLog: debugLog,
        scheduler: scheduler,
        storedPINs: { DevicePINSource(keychain: devicePINs, debugLog: debugLog).stored() },
        rotatingTo: { DevicePINRules.target() }
    )
}
hasGivenUpOnCube = { reconnector?.hasGivenUpOnCube ?? false }

// The cube's own record of what it has been doing, on its way into `device_event`, and the timer whose tick asks
// for it. **Built before the timer**, because the timer's tick is what asks it.
let historyIngestor = HistoryIngestor(
    events: deviceEvents,
    readLastEvent: { answered in
        guard let radio else {
            answered(nil)
            return
        }
        radio.readLastEvent(answered)
    },
    fetchHistory: { from, answered in
        guard let radio else {
            answered([])
            return
        }
        radio.fetchHistory(from: from, answered)
    },
    debugLog: debugLog
)
let historyTimer = HistoryTimer(
    settings: settings,
    debugLog: debugLog,
    scheduler: scheduler,
    hasSomethingToFollow: {
        deviceEvents.openSegment() != nil || settings.flag("connection", field: "connected") == true
    }
) {
    // **Two sources, one tick.** With a cube connected the cube is what knows what has happened, so the tick
    // fetches its history; with none, the app is its own source and the tick is what grows the open segment it is
    // measuring. Which of the two a row belongs to is the recorder's to decide, not this line's.
    deviceEvents.refreshOpenSegment(at: Date())
    if radio?.connectedDevice != nil {
        historyIngestor.refresh(because: "the timer asked")
    }
}

// Stops the clock when the category being timed has spent its `daily_limit`.
//
// **Which clock is running decides where the stop goes**, and the open segment's face is what says so: a cube's
// pause is a command; the app's is a row, and sending one where the other was wanted does nothing at all.
let dailyLimit = DailyLimitWatch(
    timing: { timingReadout.read() },
    windowStart: { dayTotal.windowStart(at: $0) },
    debugLog: debugLog,
    scheduler: scheduler,
    stopTiming: {
        guard let open = deviceEvents.openSegment(), !ManualFace.isAppFace(open.face) else {
            // **The app's own clock, and this platform has no control that starts one yet.** The Faces tab is what
            // starts a manual session on the Mac; here a segment on an app face can only have been inherited from a
            // launch on the other machine, and closing it is the whole of what stopping means.
            deviceEvents.closeOpenSegment(at: Date())
            return
        }
        cubeLock.setPause(true) { _ in
            historyIngestor.refresh(because: "a category spent its daily limit")
        }
    }
)
cubeLock.isLimitReached = { dailyLimit.isLimitReached }

// Stops the cube when it is resting on a face with no category, and starts it again when that face is given one.
// **Time the app cannot attribute is time it will not let the cube record.**
let forcedPause = ForcedPauseWatch(
    cubeFace: { deviceEvents.openSegment().map(\.face).flatMap { ManualFace.isAppFace($0) ? nil : $0 } },
    hasCategory: { faces.categoryID(forFace: $0) != nil },
    cubePauseState: { timingReadout.read().cubePauseState },
    cubeLockState: { CubeLockState(reported: radio?.cubeStatus?.isLocked) },
    isCubeConnected: { radio?.connectedDevice != nil },
    limitIsHolding: { dailyLimit.isLimitHoldingPause },
    setPause: { wanted, then in cubeLock.setPause(wanted, then: then) },
    refreshHistory: { reason, done in historyIngestor.refresh(because: reason) { _ in done() } },
    debugLog: debugLog
)

// **The bar, built before the radio's callbacks are wired**, because several of them redraw it. From here on quit
// is the only way out, exactly as the macOS launch says.
let menuBar = MenuBar(
    debugLog: debugLog,
    scheduler: scheduler,
    // **What is being timed, asked of the database every second.** `hoursMinutesSeconds` is the same
    // formatter the other platform's status item uses, so the two read alike. The guide is the widest the
    // figure gets, which is what stops the panel shuffling as the digits change.
    label: {
        let reading = timingReadout.read()
        guard let category = reading.category else { return ("Facet", "00:00:00") }
        let elapsed = DurationFormat.hoursMinutesSeconds(reading.seconds, rounding: .truncate, showingSeconds: true)
        return ("\(category.name) \(elapsed)", "Category name 0:00:00")
    },
    // **Rebuilt from the tables as the menu opens.** Every category active *now*, with the total it has
    // *now* -- so a category retired from the Mac while this menu sat closed is simply not in the list the
    // next time it opens, which is the behaviour the read-at-the-point-of-use rule buys.
    items: {
        var items: [MenuBar.Item] = []

        let reading = timingReadout.read()
        if let category = reading.category {
            items.append(MenuBar.Item("Timing \(category.name)"))
        } else {
            items.append(MenuBar.Item("Not timing"))
        }
        items.append(.separator)

        // **The cube, read now rather than remembered.** Whether one is paired is the table's answer and whether
        // one is connected is the radio's, and this is the one control this platform has for either.
        let isPaired = settings.flag("paired", field: "paired") == true
        if radio == nil {
            items.append(MenuBar.Item("No Bluetooth"))
        } else if radio?.connectedDevice != nil {
            let name = settings.string("device_name", field: "name") ?? "the cube"
            items.append(MenuBar.Item("Connected to \(name)"))
        } else if isPaired {
            items.append(MenuBar.Item("Looking for the cube"))
        } else {
            // **The only way into a pairing on this platform**, the Device tab being the Mac's and there being no
            // window here. The PINs are `DeviceLoginRules`' pairing list, which puts the vendor default first: a
            // cube being paired for the first time is probably factory-fresh.
            items.append(MenuBar.Item("Pair a cube") {
                debugLog?.record(.pair, "Pairing was chosen from the menu bar")
                radio?.pair(
                    presenting: DeviceLoginRules.candidates(
                        stored: DevicePINSource(keychain: devicePINs, debugLog: debugLog).stored()
                    ),
                    rotatingTo: DevicePINRules.target()
                )
            })
        }
        items.append(.separator)

        // **Today, per category, read now.** Listed rather than offered: starting a category by hand is
        // manual mode, which is a control this platform has not built yet, so these say what the day looks
        // like without pretending to change it.
        //
        // The window is `DayTotal`'s, not midnight: the day the app counts by is a setting, and asking the
        // thing that owns that question is what stops this list disagreeing with the Report tab.
        let now = Date()
        let totals = entries.totals(from: dayTotal.windowStart(at: now), to: now)
        let byCategory = Dictionary(totals.map { ($0.categoryID, $0.seconds) }, uniquingKeysWith: +)
        let today = categories.activeCategories()
        if today.isEmpty {
            items.append(MenuBar.Item("No categories yet"))
        } else {
            for category in today {
                let seconds = byCategory[category.id] ?? 0
                let figure = DurationFormat.hoursMinutesSeconds(seconds, rounding: .truncate, showingSeconds: true)
                items.append(MenuBar.Item("\(category.name)   \(figure)"))
            }
        }

        items.append(.separator)
        items.append(MenuBar.Item("Quit Facet") {
            debugLog?.record(.quit, "Quit was chosen from the menu bar")
            // **The same two halves AppKit gets, in the same order and for the same measured reason.** The pause
            // and the lock are BLE writes and need a round trip, so the process has to still be here for them:
            // `pauseAndLockTheCube` answers whether anything went, and the rest of the sequence runs once it has
            // either landed or timed out. With nothing to send there is nothing to wait for.
            let started = quitSequence.pauseAndLockTheCube {
                quitSequence.run(at: Date())
                MenuBar.quit()
            }
            guard !started else { return }
            quitSequence.run(at: Date())
            MenuBar.quit()
        })
        return items
    }
)

// Recorded time changed, so everything drawn from it is stale.
historyIngestor.onChanged = {
    menuBar.redraw()
    // **The limit's tick stands itself down the moment nothing is being timed, and a pause is exactly that**, so
    // without this the watch dies at the first limit it enforces and never looks again.
    dailyLimit.resumeIfStopped()
    // **An event came in, so the face the cube is resting on may be one with nothing on it.**
    forcedPause.check()
}

// MARK: - what the radio says happened

if let radio {
    // **The cube is on the new PIN by the time this runs**, and it has proved it by logging in with it, so a
    // failure here is the app losing a PIN the cube already has. The write happens on its own line rather than
    // inside a logging call: `debugLog?.record(...)` is optional chaining, so with no logger its argument is never
    // evaluated and the PIN would go unrecorded in exactly the build that has no log to notice.
    radio.onPINChanged = { pin in
        let recorded = DevicePINSource(keychain: devicePINs, debugLog: debugLog).record(pin)
        guard !recorded.isRecorded else { return }
        debugLog?.record(.pin, "Neither store would keep the new PIN, so the cube now has one this app has not got")
    }

    // **Whether the two PIN stores are saying different things, asked once, here.** They disagree only after a
    // Keychain write that failed, and only the cube can say which is right -- so the answer waits for a login, and
    // the first login of the launch is the one that gets it.
    var isReconcilingPINStores =
        DevicePINSource(keychain: devicePINs, debugLog: debugLog).settleAtLaunch() == .awaitingTheCube
    radio.onPINAccepted = { _, pin in
        guard isReconcilingPINStores else { return }
        // Disarmed by an answer that settled it, not by any login at all: a cube can accept a PIN from neither
        // store, which is what a factory-reset confirmation is.
        guard DevicePINSource(keychain: devicePINs, debugLog: debugLog).reconcile(accepted: pin) != .nothingHappened
        else { return }
        isReconcilingPINStores = false
    }

    radio.onLoginEnded = { id, outcome in
        // **Told either way, and before the recording.** A failure is what starts the next attempt, so the loop
        // has to hear about the ones that did not work.
        reconnector?.noteOutcome(outcome)
        // **Only a login that got all the way through writes anything.** A refused PIN, a device that turned out
        // not to be a TimeFlip and a cube that stopped answering all leave the table exactly as it was.
        guard outcome == .loggedIn else { return }
        let device = radio.device(id)
        let alreadyPaired = settings.flag("paired", field: "paired") == true
            && settings.string("device_uuid", field: "uuid") == id.uuidString
        if alreadyPaired {
            pairing.recordReconnection(with: device)
        } else {
            pairing.recordPairing(with: device)
        }
        // **What the app is doing has just changed, and only this says so.** Timing by hand is what being unpaired
        // means, so writing `paired` is what makes this app follow a cube; the timer and the limit watch had both
        // stood down under a launch with nothing to follow, and this is the funnel that puts them back on their
        // feet.
        menuBar.redraw()
        historyTimer.resumeIfStopped()
        dailyLimit.resumeIfStopped()
        forcedPause.check()
    }

    // **The one confirmation a rename ever gets**, arriving a second or two into a connection. It is also what
    // notices a cube renamed in the vendor's app.
    radio.onDeviceName = { id, name in
        // **Only for the cube this app is paired to**, read from the table at this moment: every connection
        // reports a name, including ones made to a device that turns out to be somebody else's.
        guard settings.string("device_uuid", field: "uuid") == id.uuidString else {
            debugLog?.record(.pair, "Ignoring the name \(name): it is not the cube this app is paired to")
            return
        }
        switch DevicePairingRules.adoption(
            of: name,
            current: settings.string("device_name", field: "name"),
            previouslyKnown: settings.string("device_name", field: "previous_name")
        ) {
        case .unchanged, .stale:
            return
        case .adopt:
            pairing.recordName(name, because: "the cube said so on connecting")
            menuBar.redraw()
        }
    }

    // What the cube says it is, arriving after the pairing rather than with it: the four Device Information reads
    // run once the login is over and take a moment.
    radio.onDeviceInfo = { _, info in
        pairing.recordInfo(info)
    }

    // **Nothing is written down**, which makes this the one radio callback that files nothing: the charge has no
    // row and is not going to get one.
    radio.onBatteryLevel = { _, _ in
        lowBattery.reconsider(because: "a charge arrived")
    }

    radio.onCubeStatus = { _, status in
        menuBar.redraw()
        // **The cube's own answer about its auto-pause delay, which is the only one there is.** A disagreement
        // with the table is a cube that has lost the setting.
        guard let status else { return }
        deviceSettings.cubeReported(status: status)
    }

    radio.onDoubleTapParameters = { _, parameters in
        deviceSettings.cubeReported(doubleTap: parameters)
    }

    radio.onFace = { _, _ in
        menuBar.redraw()
        // **A flip closed a segment and opened another**, which is exactly what history is a record of, so this is
        // the moment to go and get it rather than waiting out the rest of the tick.
        historyIngestor.refresh(because: "the cube was turned")
    }

    // **`onCubeReady`, not `onLoginEnded`.** A login ends when the PIN is accepted, which is several round trips
    // before the characteristics are discovered -- ask then and the cube has no history characteristic yet.
    radio.onCubeReady = { _ in
        historyIngestor.refresh(because: "the link came up")
    }

    // **`onCubeSettled`, not `onCubeReady`.** The two fire a few round trips apart, and a command sent on the
    // earlier one writes over a question the login still has out.
    radio.onCubeSettled = { _ in
        faceColours.linkSettled()
        deviceSettings.linkSettled()
    }

    // **What a link coming up starts, a link going has to let go of.** Each of these three documents a stall that
    // shipped on the other platform when its own reset was missing, and `LinkEndedFanOutTests` is what checks the
    // list is complete.
    let linkEnders: [() -> Void] = [
        historyIngestor.linkEnded,
        faceColours.linkEnded,
        deviceSettings.linkEnded,
    ]
    radio.onLinkEnded = { _ in
        for letGo in linkEnders { letGo() }
    }

    radio.onConnectionDropped = { _ in
        pairing.recordConnectionLost(because: "the cube stopped answering")
        menuBar.redraw()
        // **After the row is down, not before.** The loop's first act is to ask whether the app is already
        // connected, and a reconnect that succeeded before the drop was written down would leave `connected` false
        // under a live link.
        reconnector?.noteDropped()
    }

    // What the cube says about its own condition, which it volunteers on connecting and whenever something changes.
    radio.onSystemState = { _, state in
        if state.cubeSyncState == .faceColoursRequired {
            faceColours.cubeAskedForThem()
        }
        deviceSettings.cubeAsked(for: state.cubeSyncState)
        guard state.cubeSyncState == .factoryReset else { return }
        historyIngestor.refresh(because: "the cube says it was put back to the factory")
    }
}

// A launch can inherit a running clock, so both start here rather than waiting for somebody to press something:
// the segment they are watching may already be over its limit.
dailyLimit.start()
historyTimer.start()

// Last, and after everything a login reports to is wired: reaching the cube writes rows and turns manual mode off,
// so a launch that started looking any earlier could get an answer before there was anywhere to put it.
//
// **Whether there is a cube to look for is this call's own question**, read from the table rather than decided here.
reconnector?.follow()

menuBar.run()

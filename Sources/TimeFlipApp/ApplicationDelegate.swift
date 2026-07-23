import AppKit
import Combine
import OSLog

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let dataStore = AppDataStore()
    private lazy var appState = AppState(
        autoPauseMinutes: dataStore.loadAutoPauseMinutes(),
        ledBrightnessPercent: dataStore.loadLEDBrightnessPercent(),
        blinkIntervalSeconds: dataStore.loadLEDBlinkIntervalSeconds(),
        doubleTapParameters: dataStore.loadDoubleTapParameters(),
        isDoubleTapEnabled: dataStore.loadDoubleTapEnabled(),
        colourOptions: ActivityLibrary.colorOptions(from: dataStore.loadColours()),
        dailyResetHour: dataStore.loadDailyResetTime().hour,
        dailyResetMinute: dataStore.loadDailyResetTime().minute
    )
    private let enableGoogleIntegrations = true
    private lazy var authManager = GoogleAuthManager(
        stateStore: (DeveloperMode.isEnabled && appState.isDeveloperConfigLoaded)
            ? DeveloperModeGoogleAuthStateStore()
            : KeychainAuthStateStore(),
        configurationProvider: { [weak appState] in
            guard let appState else {
                throw GoogleAuthError.missingClientID
            }
            // Load client secret from keychain on first access
            appState.loadClientSecretOnce()
            let clientID = appState.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientID.isEmpty else {
                throw GoogleAuthError.missingClientID
            }
            let clientSecret = appState.googleClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientSecret.isEmpty else {
                throw GoogleAuthError.missingClientSecret
            }
            return GoogleAuthConfiguration(
                clientID: clientID,
                clientSecret: clientSecret
            )
        }
    )
    private lazy var integrationCoordinator = GoogleIntegrationCoordinator(
        authManager: enableGoogleIntegrations ? authManager : nil,
        store: dataStore,
        integrationEnabled: enableGoogleIntegrations
    )
    private lazy var settingsWindowController = SettingsWindowController(
        appState: appState,
        authManager: authManager,
        integrationCoordinator: integrationCoordinator
    )
    private lazy var dailyTotals = DailyFacetTotals(dataStore: dataStore)
    private lazy var menuBarController = MenuBarController(
        appState: appState,
        settingsWindowController: settingsWindowController,
        onPauseToggle: { [weak self] pause in
            guard let self else { return }
            Task { @MainActor in
                await self.device?.setPause(pause)
                // Device doesn't send notification after setPause command,
                // so explicitly fetch history to confirm state change
                await self.historyIngestor?.refreshHistory(trigger: "manual_pause")
            }
        },
        onLockRequest: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.handleLockRequest()
            }
        },
        displaySecondsEnabled: dataStore.loadDisplaySecondsEnabled(),
        lowBatteryThresholdPercent: dataStore.loadLowBatteryLevelPercent()
    )
    private let enableMockEvents = false
    private lazy var device: TimeFlipSessionManaging? = enableMockEvents ? MockTimeFlipDevice() : TimeFlipBLEDevice()
    private var eventTask: Task<Void, Never>?
    // Bumped every time startDeviceEvents spawns a new eventTask, so a stale task's completion
    // handler can tell it's no longer the current one and avoid nil-ing out its replacement.
    private var eventTaskGeneration = 0
    private var mockHTTPServer: MockEventHTTPServer?
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "lifecycle")
    private var cancellables: Set<AnyCancellable> = []
    private var lastSentFacetColors: [UInt8: ColorComponents] = [:]
    // Debounces the device write for each live-editable setting below: DB persistence and the
    // "value changed" debug print happen immediately on every change, but the actual device write
    // (and, where the protocol supports it, its read-back verification) only fires once the value
    // has been stable for autoPauseWriteDelay -- rescheduled on every intervening change so a fast
    // sequence (a held stepper arrow, a dragged slider) reaches the device once, not per tick.
    private let autoPauseWriteDebouncer = DeviceWriteDebouncer()
    private let ledBrightnessWriteDebouncer = DeviceWriteDebouncer()
    private let blinkIntervalWriteDebouncer = DeviceWriteDebouncer()
    private let doubleTapWriteDebouncer = DeviceWriteDebouncer()
    private var facetColorInitialized = false
    private var awaitingInitialStatus = false
    // Guards handleDeviceEvent against acting on live BLE notifications until the initial history
    // backfill (recordDeviceEvent's ascending-order requirement -- see HistoryIngestor.refreshHistory)
    // has finished, so a live notification can't race a fresh device_event table.
    private var isHistoryBackfillComplete = false
    private var historyIngestor: HistoryIngestor?
    private let useHistoryPipeline = true
    private var dayResetTimer: Timer?
    // Backoff counter for reconnect attempts after losing connection to an already-paired
    // device; reset to 0 as soon as a reconnect succeeds. Capped in scheduleReconnect().
    private var reconnectAttempt = 0
    // Set from the moment a factory reset's 0xFF command is sent until the device is confirmed
    // reset (it reconnects on the factory default password) or the deadline passes. While set, the
    // reconnect path treats a successful default-password login as the reset confirmation -- NOT a
    // pairing -- then drops the connection into the pristine never-paired state; and the disconnect
    // caused by the device rebooting is shown as "Resetting..." rather than a reconnect failure.
    private var pendingFactoryResetConfirm = false
    private var factoryResetConfirmDeadline: Date?
    // How long to keep trying to catch the device coming back on the default password after a reset
    // before giving up and surfacing a failure (the device reboots in well under this).
    private let factoryResetConfirmTimeout: TimeInterval = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        // Read before anything else runs, so every debug print for the rest of this launch
        // respects the setting from the moment the app starts.
        DeveloperMode.isDebugSettingEnabled = dataStore.loadDebugEnabled()
        // Persist every debug message into debug_log too (see AppDataStore.recordDebugLog), so a
        // failed test run can be analyzed from the database afterward instead of relying on a
        // terminal transcript that was never captured.
        DeveloperMode.logSink = { [dataStore] tag, message in
            dataStore.recordDebugLog(tag: tag.rawValue, message: message)
        }
        // Surfaced so an interactive testing session can confirm from debug_log alone (no need to
        // separately inspect the appdata.sqlite symlink target) which physical database this
        // launch actually opened -- see Tests/CLAUDE.md's database-switching workflow. Also pushed
        // onto appState so the menu bar can display it (dev mode only) as a guard against logging
        // real timings into a test database.
        let dbType = dataStore.loadDbType()
        appState.dbType = dbType
        DeveloperMode.debugPrint(.dbType, "Database type: \(dbType)")
        logger.notice("Launching TimeFlip mockup")
        setupMainMenu()
        appState.onPairingChange = { [weak self] paired in
            guard let self else { return }
            if let controller = self.device as? TimeFlipMockControlling {
                if paired {
                    controller.pair()
                } else {
                    controller.forget()
                }
            }
            if paired {
                self.startDeviceEvents()
            } else {
                self.stopDeviceEvents()
            }
        }
        if let bleDevice = device as? TimeFlipBLEDevice {
            bleDevice.onDeviceDiscovered = { [weak appState] discovered in
                appState?.addDiscoveredDevice(discovered)
            }
            bleDevice.onDiscoveryScanStopped = { [weak appState] in
                appState?.deviceScanStopped()
            }
        }
        appState.onStartDeviceScan = { [weak self] filterToTimeFlip in
            guard let bleDevice = self?.device as? TimeFlipBLEDevice else { return }
            Task { await bleDevice.startDiscoveryScan(filterToTimeFlip: filterToTimeFlip) }
        }
        appState.onStopDeviceScan = { [weak self] in
            (self?.device as? TimeFlipBLEDevice)?.stopDiscoveryScan()
        }
        appState.onDeviceSelectedForPairing = { [weak self] id in
            guard let self, let bleDevice = self.device as? TimeFlipBLEDevice else { return }
            Task { @MainActor in
                self.appState.pairingStatus = .pairing
                self.appState.wantsPairing = true
                // A newly selected device is almost always still on the factory default —
                // reusing whatever password a previous (different) device rotated to would
                // just be wrong here. Try the default first; fall back to the password field
                // (e.g. a known custom PIN typed in for recovery) only if that's rejected.
                var attemptedPassword = TimeFlipConstants.defaultPassword
                var outcome = await bleDevice.connectToDiscoveredDevice(id: id, password: attemptedPassword)
                if outcome == .wrongPassword, self.appState.devicePassword != TimeFlipConstants.defaultPassword {
                    attemptedPassword = self.appState.devicePassword
                    outcome = await bleDevice.connectToDiscoveredDevice(id: id, password: attemptedPassword)
                }
                switch outcome {
                case .connected:
                    // The probe already confirmed this exact password works — make sure the
                    // follow-up login() call in startDeviceEvents uses the same one, not
                    // whatever was left over from a previous device.
                    self.appState.devicePassword = attemptedPassword
                    self.startDeviceEvents(skipConnect: true)
                case .notTimeFlip:
                    self.appState.markDeviceInvalid(id)
                    self.appState.pairingStatus = .notPaired
                    self.appState.wantsPairing = false
                case .wrongPassword:
                    self.appState.pairingFailed(message: "Wrong PIN")
                    self.appState.wantsPairing = false
                case .failed:
                    self.appState.pairingFailed(message: "Connect failed")
                case .cancelled:
                    break // state already reset by AppState.cancelPairingAttempt()
                }
            }
        }
        appState.onCancelPairingAttempt = { [weak self] in
            (self?.device as? TimeFlipBLEDevice)?.cancelConnectionAttempt()
        }
        appState.onResetDevicePasswordRequest = { [weak self] in
            guard let bleDevice = self?.device as? TimeFlipBLEDevice else { return true }
            let confirmed = await bleDevice.resetDevicePasswordToDefault()
            if confirmed, !(self?.appState.isDeveloperConfigLoaded ?? false) {
                try? TimeFlipDevicePasswordStore.shared.savePassword(nil)
            }
            return confirmed
        }
        appState.onFactoryResetRequest = { [weak self] in
            guard let self, let bleDevice = self.device as? TimeFlipBLEDevice else { return false }
            // Arm the confirmation window BEFORE sending 0xFF so the disconnect the reset triggers
            // is recognised as "device rebooting" (kept as .resetting) rather than a reconnect
            // failure. The stored password is cleared only once the reset is actually confirmed
            // (see the pendingFactoryResetConfirm branch in startDeviceEvents).
            self.pendingFactoryResetConfirm = true
            self.factoryResetConfirmDeadline = Date().addingTimeInterval(self.factoryResetConfirmTimeout)
            self.reconnectAttempt = 0
            let sent = await bleDevice.factoryReset()
            guard sent else {
                self.pendingFactoryResetConfirm = false
                self.factoryResetConfirmDeadline = nil
                return false
            }
            // Tear the current (soon-dead) session down intentionally and start the confirm-reconnect
            // loop now, rather than waiting for the device's own ~30s stream timeout. The reconnect
            // path re-logs-in with the default password to confirm the wipe took (see the
            // pendingFactoryResetConfirm branch in startDeviceEvents). isPaired is still true here, so
            // scheduleReconnect proceeds.
            self.stopDeviceEvents()
            self.scheduleReconnect()
            return true
        }
        appState.onCurrentFacetMappingChange = { [weak self] in
            self?.menuBarController.refreshFromState()
        }
        appState.onFacetColourPicked = { [weak self] facetID, colourID in
            self?.dataStore.updateCategoryColour(faceID: Int(facetID), colourID: colourID)
        }
        appState.onDailyResetTimeChange = { [weak self] hour, minute in
            guard let self else { return }
            DeveloperMode.debugPrint(.dailyReset, String(format: "Daily reset time changed to %02d:%02d", hour, minute))
            self.dataStore.saveDailyResetTime(hour: hour, minute: minute)
            // Re-read the boundary into the live accumulator, re-seed totals from the new window,
            // and re-arm the timer so the change takes effect immediately (matters for testing the
            // reset firing at a near-future minute).
            self.dailyTotals.updateResetTime(hour: hour, minute: minute)
            self.seedDailyTotals()
            self.scheduleDayReset()
            self.menuBarController.refreshFromState()
        }
        // The settings view updates appState before invoking these callbacks. Each handler prints
        // the new value and persists it to the DB immediately (every intermediate change while a
        // stepper/slider is moving), then debounces the actual device write through its
        // DeviceWriteDebouncer above -- see that type's doc comment.
        appState.onAutoPauseChange = { [weak self] minutes in
            guard let self else { return }
            DeveloperMode.debugPrint(.autoPause, "Auto-pause value changed to \(minutes)m")
            self.dataStore.saveAutoPauseMinutes(minutes)
            DeveloperMode.debugPrint(.autoPause, "Auto-pause saved to DB: \(minutes)m")
            self.autoPauseWriteDebouncer.schedule { [weak self] in
                await self?.device?.setAutoPause(minutes: minutes)
            }
        }
        appState.onLEDBrightnessChange = { [weak self] percent in
            guard let self else { return }
            DeveloperMode.debugPrint(.led, "Brightness value changed to \(percent)%")
            self.dataStore.saveLEDBrightnessPercent(percent)
            DeveloperMode.debugPrint(.led, "Brightness saved to DB: \(percent)%")
            self.ledBrightnessWriteDebouncer.schedule { [weak self] in
                await self?.device?.setLEDBrightness(percent: percent)
            }
        }
        appState.onBlinkIntervalChange = { [weak self] seconds in
            guard let self else { return }
            DeveloperMode.debugPrint(.led, "Blink interval value changed to \(seconds)s")
            self.dataStore.saveLEDBlinkIntervalSeconds(seconds)
            DeveloperMode.debugPrint(.led, "Blink interval saved to DB: \(seconds)s")
            self.blinkIntervalWriteDebouncer.schedule { [weak self] in
                await self?.device?.setBlinkInterval(seconds: seconds)
            }
        }
        appState.onDoubleTapParametersChange = { [weak self] params in
            guard let self else { return }
            let summary = "ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)"
            DeveloperMode.debugPrint(.doubleTap, "Params changed: \(summary)")
            self.doubleTapWriteDebouncer.schedule { [weak self] in
                await self?.device?.setDoubleTapParameters(params)
            }
        }
        appState.onDoubleTapSettingsPersist = { [weak self] params, enabled in
            guard let self else { return }
            self.dataStore.saveDoubleTapParameters(params)
            self.dataStore.saveDoubleTapEnabled(enabled)
            DeveloperMode.debugPrint(.doubleTap, "Params saved to DB: enabled=\(enabled)")
        }
        appState.$facetMappings
            .sink { [weak self] mappings in
                Task { @MainActor in
                    guard let self else { return }
                    if !self.facetColorInitialized {
                        self.lastSentFacetColors = Dictionary(uniqueKeysWithValues: mappings.map {
                            ($0.facetID, ColorComponents(color: $0.color))
                        })
                        self.facetColorInitialized = true
                        return
                    }
                    await self.sendFacetColors(mappings)
                }
            }
            .store(in: &cancellables)
        seedDailyTotals()
        scheduleDayReset()
        // If already authenticated at launch and the account identity isn't cached yet, fetch it
        // once and store it in the `google_account` setting so later reads come from the DB rather
        // than hitting the userinfo endpoint again.
        if authManager.isAuthenticated {
            Task { @MainActor in
                _ = try? await integrationCoordinator.loadAccountInfo()
            }
        }
        menuBarController.start()
        if appState.isPaired {
            startDeviceEvents()
        } else if appState.wantsPairing {
            startDeviceEvents()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        logger.info("Application did finish launching")
    }

    /// If `pause_on_lock` is enabled, pause and lock the device before actually quitting -- same
    /// rationale as pausing via the app engaging lock mode (see `pause_on_lock`'s seed
    /// description): the device shouldn't keep running/trackable once nothing's left controlling
    /// it. If the setting is disabled (or there's no paired device to command), quit immediately
    /// with no device interaction. Delays termination (`.terminateLater`) rather than blocking
    /// this call, since `setPause`/`setLock` are async BLE round trips.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let device, appState.isPaired, dataStore.loadPauseOnLockEnabled() else {
            DeveloperMode.debugPrint(.timeFlip, "Quit requested; pause_on_lock disabled or no paired device, exiting immediately")
            return .terminateNow
        }
        DeveloperMode.debugPrint(.timeFlip, "Quit requested; pause_on_lock enabled, pausing and locking device before exit")
        Task { @MainActor in
            if !appState.isPaused {
                await device.setPause(true)
            }
            await device.setLock(true)
            DeveloperMode.debugPrint(.timeFlip, "Pause+lock on quit complete, terminating now")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        // Record the intentional quit and clear connection_lost, so the disconnect that
        // stopDeviceEvents() is about to cause isn't later read as a dropped connection.
        dataStore.recordQuitRequest()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopDeviceEvents()
        logger.info("Application will terminate")
    }

    /// The BLE stack (any in-flight scan/connect, its 30s-per-phase watchdogs) can be left in an
    /// unknown state after the Mac has been asleep — CoreBluetooth on macOS is known to sometimes
    /// stop actually delivering scan results after a long suspend even though nothing has
    /// technically errored, silently wedging the existing backoff retry loop rather than making it
    /// visibly fail. Rather than trust that loop to recover on its own, force a clean teardown and
    /// restart the moment the system wakes, so the reconnect attempt lands as soon as possible
    /// (the user is presumably right next to the device again) instead of waiting on whatever
    /// backoff delay happened to be queued before the Mac went to sleep.
    @objc
    private func handleSystemWake() {
        Task { @MainActor in
            guard self.appState.pairingStatus != .paired else {
                self.logger.notice("System woke from sleep; device already connected")
                return
            }
            guard self.appState.isPaired || self.appState.wantsPairing else { return }
            self.logger.notice("System woke from sleep; forcing a fresh device reconnect attempt")
            self.stopDeviceEvents()
            self.reconnectAttempt = 0
            self.appState.pairingStatus = .reconnecting
            // Deliberate pause between showing the yellow "reconnecting" text and actually
            // attempting the connection. Without it, a fast reconnect makes it impossible to tell
            // whether this wake-triggered retry path ran at all versus the device just already
            // being in range by coincidence.
            DeveloperMode.debugPrint(.timeFlip, "System wake: reconnecting status shown, waiting 2s before connect attempt")
            try? await Task.sleep(nanoseconds: 2 * TimeConstants.nanosecondsPerSecond)
            guard self.appState.isPaired || self.appState.wantsPairing else { return }
            DeveloperMode.debugPrint(.timeFlip, "System wake: 2s delay elapsed, attempting reconnect now")
            self.startDeviceEvents()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = application
        _ = urls
        logger.notice("Received URL callback, but Google auth uses loopback redirect.")
    }

    private func startDeviceEvents(skipConnect: Bool = false) {
        guard let device, eventTask == nil else { return }
        historyIngestor = HistoryIngestor(
            device: device,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals,
            onLatestEntry: { [weak self] entry in
                guard let self else { return }
                self.applyActiveInterval(from: entry)
            }
        )
        historyIngestor?.startPeriodicFetchTimer()
        if let bleDevice = device as? TimeFlipBLEDevice {
            bleDevice.onDisconnect = { [weak self] in
                self?.handleDeviceDisconnect()
            }
        }
        eventTaskGeneration += 1
        let generation = eventTaskGeneration
        eventTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.eventTaskGeneration == generation {
                    self.eventTask = nil
                }
            }
            if !skipConnect {
                let connected = await device.connect()
                guard connected else {
                    logger.error("TimeFlip connect failed; will retry")
                    await MainActor.run {
                        self.handleReconnectFailure(message: "Connect failed")
                    }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            var passwordUsed = appState.devicePassword
            var loggedIn = await device.login(password: passwordUsed)
            if !loggedIn, (device as? TimeFlipBLEDevice)?.wasWrongPassword == true,
               passwordUsed != TimeFlipConstants.defaultPassword {
                // The stored password goes stale after a reset (the device reverts to the factory
                // default) -- both during a reset we initiated (pendingFactoryResetConfirm) and for
                // an out-of-band reset -- so retry with the default before giving up, same reasoning
                // already used for a freshly-selected device in onDeviceSelectedForPairing. During
                // our own reset this default-password login is what confirms the wipe (below).
                passwordUsed = TimeFlipConstants.defaultPassword
                loggedIn = await device.login(password: passwordUsed)
            }
            guard loggedIn else {
                logger.error("TimeFlip login failed; events not started")
                let wasCancelled = (device as? TimeFlipBLEDevice)?.wasCancelled ?? false
                if pendingFactoryResetConfirm {
                    // Device is still rebooting after the reset -- tear down intentionally and keep
                    // waiting for it to come back on the default password, rather than reporting a
                    // pairing failure.
                    await MainActor.run {
                        self.stopDeviceEvents()
                        self.retryOrTimeOutFactoryResetConfirm()
                    }
                    return
                }
                await device.disconnect()
                if !wasCancelled {
                    await MainActor.run {
                        self.appState.pairingFailed(message: "Wrong PIN")
                    }
                }
                return
            }
            // A factory reset we initiated is confirmed only by the device coming back on the
            // FACTORY DEFAULT password -- that's the proof the 0xFF wipe took effect. When it does,
            // this login is deliberately NOT treated as a pairing: forget the device into the
            // pristine never-paired state (forgetDevice() tears down the connection via
            // onPairingChange(false) -> stopDeviceEvents, which also detaches onDisconnect so no
            // spurious failure/reconnect follows).
            if pendingFactoryResetConfirm {
                if passwordUsed == TimeFlipConstants.defaultPassword {
                    pendingFactoryResetConfirm = false
                    factoryResetConfirmDeadline = nil
                    DeveloperMode.debugPrint(.timeFlip, "Factory reset confirmed: device is back on the default password; returning to never-paired state")
                    if !appState.isDeveloperConfigLoaded {
                        try? TimeFlipDevicePasswordStore.shared.savePassword(nil)
                    }
                    await MainActor.run {
                        self.appState.forgetDevice()
                    }
                } else {
                    // Logged in, but with the OLD password -- the wipe hasn't taken yet. Tear down
                    // and keep waiting for the reboot; only fail once the deadline passes.
                    DeveloperMode.debugPrint(.timeFlip, "Factory reset not yet confirmed: device still accepts the old password; retrying")
                    await MainActor.run {
                        self.stopDeviceEvents()
                        self.retryOrTimeOutFactoryResetConfirm()
                    }
                }
                return
            }
            guard !Task.isCancelled else { return }
            // A genuine device connection (a new pairing, or an app-start/reconnect login --
            // the factory-reset-confirmation login returned above and is deliberately excluded).
            // Stamp connection.last_connection so an observer/test can confirm the device connected.
            let connectedAt = dataStore.recordConnection()
            DeveloperMode.debugPrint(.timeFlip, "connection.last_connection recorded: \(connectedAt)")
            await MainActor.run {
                // Login confirms the device is reachable and authenticated again — clear the
                // "reconnecting" state right away; the history backfill below will correct the
                // displayed facet/duration/pause state to whatever the device actually reports.
                if self.appState.pairingStatus == .reconnecting {
                    self.appState.pairingStatus = .paired
                }
                self.reconnectAttempt = 0
                // Persist the password that actually worked if it differs from the stored one
                // (the default-password fallback above), so the next reconnect doesn't have to
                // rediscover this via another rejection first.
                if passwordUsed != self.appState.devicePassword {
                    self.appState.devicePassword = passwordUsed
                    if !self.appState.isDeveloperConfigLoaded {
                        do {
                            try TimeFlipDevicePasswordStore.shared.savePassword(passwordUsed)
                        } catch {
                            self.logger.error("Failed to save recovered device password to Keychain: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
            // Only rotate the password during the pairing flow itself (skipConnect is only ever
            // true there) — routine reconnects afterward must keep reusing that same password.
            if skipConnect, let bleDevice = device as? TimeFlipBLEDevice,
               let rotatedPassword = await bleDevice.rotateDevicePassword() {
                await MainActor.run {
                    self.appState.devicePassword = rotatedPassword
                }
                if !self.appState.isDeveloperConfigLoaded {
                    do {
                        try TimeFlipDevicePasswordStore.shared.savePassword(rotatedPassword)
                    } catch {
                        logger.error("Failed to save rotated device password to Keychain: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await device.enableNotifications()
            let desiredAutoPause = appState.autoPauseMinutes
            await device.initializeSession(hostTime: Date(), desiredAutoPauseMinutes: desiredAutoPause)
            // LED brightness/blink have no device read-back (vendor spec defines none for 0x09/
            // 0x0A -- see docs/timeflip.md), so unlike auto-pause and double-tap below, these two
            // can't be checked against the device first; they're always (re-)applied.
            DeveloperMode.debugPrint(.deviceSync, "LED brightness: no device read-back available; applying \(appState.ledBrightnessPercent)%")
            await device.setLEDBrightness(percent: appState.ledBrightnessPercent)
            DeveloperMode.debugPrint(.deviceSync, "LED blink interval: no device read-back available; applying \(appState.blinkIntervalSeconds)s")
            await device.setBlinkInterval(seconds: appState.blinkIntervalSeconds)
            await syncDoubleTapParameters(expected: appState.effectiveDoubleTapParameters, device: device)
            guard !Task.isCancelled else { return }
            logger.notice("Backfill starting")
            awaitingInitialStatus = true
            isHistoryBackfillComplete = false
            await self.historyIngestor?.refreshHistory(trigger: "startup")
            isHistoryBackfillComplete = true
            logger.notice("Backfill finished; resuming normal event processing")
            guard !Task.isCancelled else { return }
            for await event in device.events {
                self.handleDeviceEvent(event)
            }
        }
        device.start()
        if let controller = device as? TimeFlipMockControlling {
            let server = MockEventHTTPServer(controller: controller)
            server.start()
            mockHTTPServer = server
        }
        logger.notice("Device event stream active")
    }

    private func stopDeviceEvents() {
        // This is always an *intentional* teardown (forget/reset/reconnect cycle), so detach the
        // disconnect handler first: cancelPeripheralConnection below still fires the CoreBluetooth
        // didDisconnect callback, and without this that would re-enter handleDeviceDisconnect and
        // surface a spurious "Disconnected before pairing completed" failure (or a stray reconnect)
        // after a deliberate forget. startDeviceEvents re-installs the handler when it reconnects.
        (device as? TimeFlipBLEDevice)?.onDisconnect = nil
        device?.stop()
        Task { [weak self] in
            await self?.device?.disconnect()
        }
        eventTask?.cancel()
        eventTask = nil
        historyIngestor?.stopPeriodicFetchTimer()
        mockHTTPServer?.stop()
        mockHTTPServer = nil
        logger.notice("Device event stream stopped")
    }

    private func handleDeviceDisconnect() {
        logger.warning("Device disconnected; attempting auto-reconnect")
        let lostAt = dataStore.recordConnectionLost()
        DeveloperMode.debugPrint(.timeFlip, "connection.connection_lost recorded: \(lostAt)")
        lastSentFacetColors.removeAll()
        facetColorInitialized = false
        awaitingInitialStatus = false
        isHistoryBackfillComplete = false
        stopDeviceEvents()
        handleReconnectFailure(message: "Disconnected before pairing completed")
    }

    /// Called whenever a connection to an already-paired device is lost or a reconnect attempt
    /// fails outright. This is almost always a transient BLE issue (out of range, laptop asleep)
    /// rather than a deliberate unpair, so — unlike a genuine pairing failure — it must not wipe
    /// `isPaired`/the on-screen activity. Instead it keeps retrying indefinitely with backoff
    /// while marking the state `.reconnecting`, which MenuBarController renders by leaving the
    /// last known icon/activity/timer on screen. History resync after a successful reconnect
    /// corrects anything that drifted while offline.
    private func handleReconnectFailure(message: String) {
        // Mid factory-reset: the disconnect is the device rebooting after the 0xFF command. Keep the
        // "Resetting..." status (not a scary "Reconnecting/Failed") and keep retrying to catch the
        // device coming back on the default password.
        if pendingFactoryResetConfirm {
            retryOrTimeOutFactoryResetConfirm()
            return
        }
        // Retry on wantsPairing too: a drop between connect() and the first facet event happens
        // before isPaired is ever set, so gating on isPaired alone would leave the UI stuck with
        // no retry and no failure surfaced.
        guard appState.isPaired || appState.wantsPairing else {
            appState.pairingFailed(message: message)
            return
        }
        appState.pairingStatus = .reconnecting
        scheduleReconnect()
    }

    /// While a factory reset is pending confirmation, keep retrying the reconnect (to catch the
    /// device coming back on the default password) until `factoryResetConfirmDeadline`; once that
    /// passes, give up and surface a failure. Keeps the UI in `.resetting` throughout.
    private func retryOrTimeOutFactoryResetConfirm() {
        guard pendingFactoryResetConfirm else { return }
        if let deadline = factoryResetConfirmDeadline, Date() < deadline {
            appState.pairingStatus = .resetting
            scheduleReconnect()
        } else {
            pendingFactoryResetConfirm = false
            factoryResetConfirmDeadline = nil
            DeveloperMode.debugPrint(.timeFlip, "Factory reset NOT confirmed within timeout; the device never came back on the default password")
            appState.pairingStatus = .failed("Reset sent, but couldn't confirm — check the device")
        }
    }

    /// Retries startDeviceEvents() with capped exponential backoff (2s, 4s, ... up to 30s) for as
    /// long as the device is still considered paired, instead of giving up after one attempt.
    private func scheduleReconnect() {
        let delaySeconds = min(2 * (reconnectAttempt + 1), 30)
        reconnectAttempt += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * TimeConstants.nanosecondsPerSecond)
            guard let self else { return }
            guard self.appState.isPaired || self.appState.wantsPairing else { return }
            self.startDeviceEvents()
        }
    }

    /// Checked once per connect (see startDeviceEvents' startup sync): reads the device's current
    /// double-tap registers (cmd 0x17) and only writes (cmd 0x16) if they differ from `expected`,
    /// instead of blindly re-writing on every reconnect. `expected` is `AppState`'s
    /// `effectiveDoubleTapParameters`, which already accounts for the "disabled" (window=0) trick.
    private func syncDoubleTapParameters(expected: DoubleTapParameters, device: TimeFlipSessionManaging) async {
        let expectedSummary = "ths=\(expected.clickThreshold) lim=\(expected.limit) lat=\(expected.latency) win=\(expected.window)"
        guard let current = await device.readDoubleTapParameters() else {
            DeveloperMode.debugPrint(.deviceSync, "Double-tap: could not read current value; applying \(expectedSummary)")
            await device.setDoubleTapParameters(expected)
            return
        }
        guard current == expected else {
            let currentSummary = "ths=\(current.clickThreshold) lim=\(current.limit) lat=\(current.latency) win=\(current.window)"
            DeveloperMode.debugPrint(.deviceSync, "Double-tap MISMATCH: device=\(currentSummary) expected=\(expectedSummary); applying")
            await device.setDoubleTapParameters(expected)
            return
        }
        DeveloperMode.debugPrint(.deviceSync, "Double-tap OK: device matches expected \(expectedSummary)")
    }

    private func sendFacetColors(_ mappings: [FacetMapping], force: Bool = false) async {
        guard let device else { return }
        if force {
            lastSentFacetColors.removeAll()
        }
        for mapping in mappings {
            let components = ColorComponents(color: mapping.color)
            if force || lastSentFacetColors[mapping.facetID] != components {
                lastSentFacetColors[mapping.facetID] = components
                await device.setFacetColor(facetID: mapping.facetID, components: components)
            }
        }
    }

    private func handleDeviceEvent(_ event: TimeFlipEvent) {
        guard isHistoryBackfillComplete else {
            logger.debug("device_event ignored (history backfill not complete yet): \(event.description, privacy: .public)")
            return
        }
        logger.info("TimeFlip event: \(event.description, privacy: .public)")
        if let notification = event.deviceNotification {
            dataStore.recordDeviceNotification(eventType: notification.eventType, payload: notification.payload)
        }
        appState.update(from: event)
        if awaitingInitialStatus, case .facetChanged = event {
            awaitingInitialStatus = false
            appState.confirmPaired(name: "TimeFlip", uuid: nil)
        }
        if case .systemState(let state) = event {
            switch state.syncStatus {
            case .factoryReset:
                historyIngestor?.resetCursors(reason: "factory_reset_event")
                Task { [weak self] in
                    await self?.historyIngestor?.refreshHistory(trigger: "factory_reset")
                }
            case .blinkIntervalSyncRequired:
                Task { [weak self] in
                    guard let self else { return }
                    await self.device?.setBlinkInterval(seconds: self.appState.blinkIntervalSeconds)
                }
            case .ledBrightnessSyncRequired:
                Task { [weak self] in
                    guard let self else { return }
                    await self.device?.setLEDBrightness(percent: self.appState.ledBrightnessPercent)
                }
            default:
                break
            }
        }
        if useHistoryPipeline, event.isFacetOrPauseChange {
            logger.debug("schedule_history_fetch reason=live_event")
            Task { [weak self] in
                await self?.historyIngestor?.refreshHistory(trigger: "live_event")
            }
        }
        logger.debug("live_event \(event.description, privacy: .public)")
    }

    /// Triggered by a double-click on the right-hand side of the status item. If `pause_on_lock`
    /// is enabled and the device isn't already paused, pause it first so the device can't keep
    /// running while locked; otherwise (setting disabled, or already paused) just send the lock.
    private func handleLockRequest() async {
        guard let device else { return }
        // Read the device's actual current lock state fresh rather than trusting the cached
        // appState.isLocked -- then flip it. A second double-click is meant to unlock.
        let currentlyLocked = await device.refreshLockState()
        let shouldLock = !currentlyLocked
        // Reflect the intended state in the menu bar icon right away, rather than waiting for the
        // optional pause + history refresh + lock command + verification below to all finish --
        // that chain is a handful of BLE round trips and can take a few seconds. The lockChanged
        // event from setLock()'s own verification step corrects this afterward if the device
        // didn't actually confirm the change.
        appState.isLocked = shouldLock
        DeveloperMode.debugPrint(.timeFlip, "Lock icon updated optimistically to \(shouldLock ? "ON" : "OFF"), pending device verification")
        if shouldLock, dataStore.loadPauseOnLockEnabled(), !appState.isPaused {
            await device.setPause(true)
            await historyIngestor?.refreshHistory(trigger: "manual_pause")
        }
        await device.setLock(shouldLock)
    }

    private func applyActiveInterval(from entry: TimeFlipHistoryEntry) {
        guard TimeFlipConstants.isValidFacetID(entry.facetID) else { return }
        let isPaused = entry.isPaused
        let elapsed: TimeInterval
        if entry.duration > 0 {
            elapsed = entry.duration
        } else {
            elapsed = max(0, Date().timeIntervalSince(entry.startedAt))
        }
        appState.currentFacetID = entry.facetID
        appState.isPaused = isPaused
        menuBarController.applyElapsed(facetID: entry.facetID, elapsedSeconds: elapsed, isPaused: isPaused)
    }

    private func seedDailyTotals(now: Date = Date()) {
        dailyTotals.resetWindow(now: now)
        appState.setDailyWindowStart(dailyTotals.windowStart)
        appState.replaceDailyTotals(dailyTotals.totals)
    }

    private func scheduleDayReset(now: Date = Date()) {
        dayResetTimer?.invalidate()
        let nextReset = dailyTotals.nextResetDate
        let timer = Timer(
            fireAt: nextReset,
            interval: 0,
            target: self,
            selector: #selector(handleDayReset),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        timer.tolerance = TimeConstants.defaultTimerTolerance
        dayResetTimer = timer
        logger.debug("daily_totals next_reset_at=\(nextReset.timeIntervalSince1970, privacy: .public)")
    }

    @objc
    private func handleDayReset() {
        logger.notice("daily_totals reset at scheduled boundary")
        seedDailyTotals()
        scheduleDayReset()
        menuBarController.refreshFromState()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        // No keyEquivalent: this app-menu Quit only becomes reachable while Preferences is open
        // (see SettingsWindowController's .regular/.accessory activation-policy toggle), and a
        // stray ⌘Q there has quit the app unexpectedly -- no keyboard shortcuts anywhere for this
        // app, matching the status-item dropdown menu.
        appMenu.addItem(withTitle: "Quit TimeFlip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

}

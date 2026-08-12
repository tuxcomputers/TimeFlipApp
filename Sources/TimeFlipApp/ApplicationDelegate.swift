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
        iconOptions: ActivityLibrary.iconOptions(from: dataStore.loadIcons()),
        faceCategories: dataStore.loadFaceCategories(),
        faceLocks: dataStore.loadFaceLocks(),
        googleCalendarID: dataStore.loadGoogleConfiguration().calendarID,
        googleCalendarName: dataStore.loadGoogleConfiguration().calendarName,
        googleClientID: dataStore.loadGoogleConfiguration().clientID,
        // Pairing survives a quit: the app comes back up still paired to whatever it was paired to,
        // and only Forget Device changes that.
        isPaired: dataStore.loadPaired(),
        deviceName: dataStore.loadDeviceName(),
        pairedDeviceUUID: dataStore.loadDeviceUUID(),
        displaySecondsEnabled: dataStore.loadDisplaySecondsEnabled(),
        pauseOnLockEnabled: dataStore.loadPauseOnLockEnabled(),
        lowBatteryThresholdPercent: dataStore.loadLowBatteryLevelPercent(),
        fetchHistoryIntervalSeconds: Int(dataStore.loadFetchHistoryIntervalSeconds()),
        blipTimeSeconds: dataStore.loadBlipTimeSeconds(),
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
        integrationCoordinator: integrationCoordinator,
        loadCategories: { [dataStore] in dataStore.loadCategories() },
        createCategory: { [dataStore] name in dataStore.createCategory(name: name) },
        findCategory: { [dataStore] name in dataStore.findCategory(named: name) },
        findCategories: { [dataStore] name in dataStore.findCategories(named: name) },
        updateCategoryColour: { [weak self, dataStore] categoryID, colourID in
            dataStore.updateCategoryColour(categoryID: categoryID, colourID: colourID)
            self?.refreshFaceCategories()
        },
        updateCategoryDailyLimit: { [weak self, dataStore] categoryID, minutes in
            dataStore.updateCategoryDailyLimit(categoryID: categoryID, minutes: minutes)
            self?.refreshFaceCategories()
        },
        updateCategoryActive: { [weak self, dataStore] categoryID, isActive in
            let succeeded = dataStore.updateCategoryActive(categoryID: categoryID, isActive: isActive)
            self?.refreshFaceCategories()
            return succeeded
        },
        updateCategoryName: { [weak self, dataStore] categoryID, name in
            dataStore.updateCategoryName(categoryID: categoryID, name: name)
            self?.refreshFaceCategories()
        },
        updateCategoryIcon: { [weak self, dataStore] categoryID, iconID in
            dataStore.updateCategoryIcon(categoryID: categoryID, iconID: iconID)
            self?.refreshFaceCategories()
        },
        assignCategoryToFace: { [weak self, dataStore] faceID, categoryID in
            dataStore.updateFaceCategory(faceID: faceID, categoryID: categoryID)
            self?.refreshFaceCategories()
        },
        setFaceLocked: { [weak self, dataStore] faceID, locked in
            dataStore.updateFaceLocked(faceID: faceID, locked: locked)
            self?.refreshFaceCategories()
        },
        loadCategoryTotals: { [dataStore] from, to in
            dataStore.loadCategoryTotals(from: from, to: to)
        }
    )
    private lazy var dailyTotals = DailyCategoryTotals(dataStore: dataStore)
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
    /// The radio, held for the whole launch whatever `device` currently points at.
    ///
    /// A second reference rather than a cast, and the difference is what makes scanning work in
    /// manual mode. `device` is what the app is *timing from*, and a manual session replaces it with
    /// a virtual device -- so `device as? TimeFlipBLEDevice`, which is how discovery and pairing used
    /// to reach the radio, finds a mock, fails the cast, and returns having done nothing at all. The
    /// button reported a scan that never started. Worse, the real object was dropped on the way in:
    /// nothing else held it, so entering manual mode deallocated the radio along with the
    /// `CBCentralManager` inside it and there was nothing left to scan with.
    ///
    /// Everything about the *session* still goes through `device`, and must: in manual mode those
    /// paths are meant to reach the virtual device, not the cube that is not there.
    ///
    /// `nil` only in the mock-events build, which has no radio to hold.
    private lazy var bleDevice: TimeFlipBLEDevice? = enableMockEvents ? nil : TimeFlipBLEDevice()
    private lazy var device: TimeFlipSessionManaging? = bleDevice ?? MockTimeFlipDevice()
    /// The same object as `device` while a manual session is running, held at its own type so the
    /// timing controls can drive it. `nil` outside manual mode, which is what makes those controls
    /// no-ops rather than something that has to be guarded at every call site.
    private var manualDevice: MockTimeFlipDevice?
    private var eventTask: Task<Void, Never>?
    // Bumped every time startDeviceEvents spawns a new eventTask, so a stale task's completion
    // handler can tell it's no longer the current one and avoid nil-ing out its replacement.
    private var eventTaskGeneration = 0
    private var mockHTTPServer: MockEventHTTPServer?
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "lifecycle")
    private var cancellables: Set<AnyCancellable> = []
    private var lastSentFaceColors: [UInt8: ColorComponents] = [:]
    // Debounces the device write for each setting below whose value is edited live: DB persistence
    // and the "value changed" debug print happen immediately on every change, but the actual device
    // write (and, where the protocol supports it, its read-back verification) only fires once the
    // value has been stable for DeviceWriteDebouncer.defaultDelay -- rescheduled on every
    // intervening change, so a fast sequence (a held stepper arrow, a run of clicks) reaches the
    // device once rather than once per tick. One debouncer each: sharing one would mean editing
    // brightness cancelled a blink-interval write that hadn't fired yet.
    private let autoPauseWriteDebouncer = DeviceWriteDebouncer()
    private let ledBrightnessWriteDebouncer = DeviceWriteDebouncer()
    private let blinkIntervalWriteDebouncer = DeviceWriteDebouncer()
    private let doubleTapWriteDebouncer = DeviceWriteDebouncer()
    private let faceColourWriteDebouncer = DeviceWriteDebouncer()
    private var faceColorInitialized = false
    /// Whether this run has actually written the face colours to a device yet, which is what turns
    /// `lastSentFaceColors` from an assumption seeded off the DB into a real record. Until it has,
    /// a connect writes all 12 rather than trusting that record -- see `startDeviceEvents`.
    private var hasSentFaceColoursThisRun = false
    // Collapses the device's repeated "I've lost my face colours" requests into one resync -- see
    // requestFaceColourResync for why answering them one for one is actively harmful.
    private let faceColourResyncDebouncer = DeviceWriteDebouncer()
    private var isFaceColourResyncPending = false
    private var isFaceColourResyncRunning = false
    private var lastFaceColourResyncAt: Date?
    private var suppressedFaceColourRequests = 0
    /// How long after finishing a resync to ignore further requests. The device can keep asking for
    /// a while after being answered, and re-answering costs another 12 flash writes for nothing.
    private let faceColourResyncCooldown: TimeInterval = 30
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
    // This picks the *delay* and nothing else -- which is why handleSystemWake resets it (a loop
    // that had climbed to the 30s cap would otherwise keep someone who just woke their Mac beside
    // their cube waiting half a minute). Whether to offer manual mode is a separate question, in
    // `manualModeOffer`, so neither can quietly change the other's meaning.
    private var reconnectAttempt = 0
    // Whether this launch has ever connected, which is the whole of what decides between retrying
    // quietly and putting the offer up. See ManualModeOffer for the rule.
    private var manualModeOffer = ManualModeOffer()
    // What the current connect attempt found, which is how the manual-mode offer says why it gave
    // up (see `ManualModeOfferReason`). Held here rather than returned, because the offer is often
    // raised from the disconnect the attempt causes -- a path with no access to what the attempt is
    // about to return, and the one that gets there first. Both reset at the top of every attempt.
    private var attemptEligibleCount = 0
    private var attemptRefusedCount = 0
    // Puts the "device isn't in range" choice in front of the user and reports what they picked.
    // A seam rather than a direct NSAlert call so a test can answer it without a window server;
    // the default is set in applicationDidFinishLaunching.
    var presentManualModeOffer: ((@escaping (ManualModeAnswer) -> Void) -> Void)?
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
    // How long to leave between two password attempts against the same peripheral. A rejected probe
    // cancels its connection on the way out, and CoreBluetooth will not reconnect to a peripheral it
    // is still tearing down -- without this the second attempt returns `.failed` in the same second,
    // which reads as "could not be reached" when the password was never sent at all.
    private let probeSettleSeconds: UInt64 = 1

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
        // A manual segment left open by a run that did not reach `applicationWillTerminate` -- a
        // crash, a force quit, a power cut. Manual mode is per-launch, so an open manual row can
        // never be resumed and is finished by definition; left alone it stays `finalised = 0` and
        // never converts, and unlike a cube's row there is no later frame coming to close it, which
        // for a user with no device at all means never. Keeps whatever duration it was last written
        // with rather than inventing one from the clock: when it actually stopped is unknowable.
        // Before the sweep, so the row it finalises is converted by that same pass.
        dataStore.closeOpenManualSegment(endingAt: nil)
        // Before anything can add to the backlog: converts whatever the last run left behind, and
        // reports any device_event marked processed with no time_entry to show for it. Runs after
        // the log sink is wired above so a repair actually reaches debug_log.
        dataStore.sweepTimeEntries(trigger: .launch)
        removeLegacyPreferencesBlob()
        // The `icon` table is the only say in which icons exist, so a row naming artwork that isn't
        // bundled has to be complained about rather than quietly filtered out. Same reason this runs
        // after the log sink: the complaint belongs in debug_log where it can be read after the fact.
        ActivityLibrary.reportUnresolvableIcons(appState.iconOptions)
        logger.notice("Launching TimeFlip mockup")
        setupMainMenu()
        if presentManualModeOffer == nil {
            presentManualModeOffer = { [weak self] answer in
                self?.runManualModeAlert(answer)
            }
        }
        // Until this launch has reached the device once, a scan that finds nothing has to give up
        // quickly: these are the attempts the manual-mode offer is counting, and at the full
        // watchdog three of them leave someone watching an app that looks like it is doing nothing
        // for minutes. Restored to the full watchdog by the first successful connect.
        bleDevice?.connectScanTimeoutSeconds = TimeFlipConstants.startupConnectScanTimeoutSeconds
        appState.onManualTimingStart = { [weak self] categoryID in
            self?.startManualTiming(categoryID: categoryID)
        }
        appState.onManualTimingPauseToggle = { [weak self] in
            guard let self else { return }
            self.setManualTimingPaused(!self.appState.isPaused)
        }
        appState.onPairingChange = { [weak self] paired in
            guard let self else { return }
            // Fires only when pairing itself changes -- true once a first pairing succeeds, false
            // on forget/factory-reset/pairing-failure. Routine connects and drops don't reach here
            // (see AppState.confirmConnected), so the `paired` setting stays put across them.
            self.dataStore.recordPaired(paired)
            // A running manual session is not the pairing's to start or stop, and both lines below
            // would do it harm. `stopDeviceEvents()` would cancel the virtual device's event task and
            // its history timer, freezing the clock the user is timing with -- and it would do that
            // on the two things a manual session now does routinely: forgetting the old cube (which
            // is how the scan list appears) and a pairing attempt that failed, which reports itself
            // through `pairingFailed` and so arrives here as `paired = false`. The mock controls are
            // the same mistake in miniature: the stand-in would be told to forget a pairing it is not
            // party to. Asked as "is a session running" rather than `isManualMode`, because during a
            // pairing attempt the status has already left `.manual` for `.pairing`.
            guard self.manualDevice == nil else { return }
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
        if let bleDevice {
            bleDevice.onDeviceDiscovered = { [weak appState] discovered in
                appState?.addDiscoveredDevice(discovered)
            }
            bleDevice.onDiscoveryScanStopped = { [weak appState] in
                appState?.deviceScanStopped()
            }
        }
        appState.onStartDeviceScan = { [weak self] filterToTimeFlip in
            guard let bleDevice = self?.bleDevice else { return }
            Task { await bleDevice.startDiscoveryScan(filterToTimeFlip: filterToTimeFlip) }
        }
        appState.onStopDeviceScan = { [weak self] in
            self?.bleDevice?.stopDiscoveryScan()
        }
        appState.onDeviceSelectedForPairing = { [weak self] id in
            guard let self, let bleDevice = self.bleDevice else { return }
            Task { @MainActor in
                self.appState.connectionStatus = .pairing
                // The default first, then the stored password, and nothing else -- see
                // `PairingPasswordRules`, which holds the policy and the reasoning. Each is tried
                // only if the one before was rejected as wrong; any other outcome stops the
                // sequence, and both being rejected is a pairing failure.
                let candidates = PairingPasswordRules.candidates(storedPassword: self.appState.devicePassword)
                var tried: Set<String> = []
                var attemptedPassword = TimeFlipConstants.defaultPassword
                var outcome = DeviceConnectOutcome.wrongPassword
                for candidate in candidates where !tried.contains(candidate) {
                    // Let the rejected probe's teardown finish before reconnecting to the same
                    // peripheral. A refused login drops the link on its way out
                    // (`connectToDiscoveredDevice` cancels the connection in a `defer`), so an
                    // immediate second attempt races that teardown and comes back `.failed`
                    // before it can send anything -- which the `guard` below reads as "not a
                    // verdict about the password" and stops on, abandoning every candidate after
                    // the first. The list then only ever presents the default, which is exactly
                    // what pairing did on 2026-08-10: `000000` refused, no second `Probe logging
                    // in using password` line at all, and a cube on a rotated PIN unpairable.
                    //
                    // Same cause, and the same one-second settle, as the auto-connect probe in
                    // `connectToFirstEligible` -- which got this fix on 2026-08-09 while this
                    // path, the one a person actually clicks, did not.
                    if !tried.isEmpty {
                        try? await Task.sleep(nanoseconds: probeSettleSeconds * TimeConstants.nanosecondsPerSecond)
                    }
                    tried.insert(candidate)
                    attemptedPassword = candidate
                    outcome = await bleDevice.connectToDiscoveredDevice(id: id, password: candidate)
                    guard outcome == .wrongPassword else { break }
                }
                switch outcome {
                case .connected:
                    // The probe already confirmed this exact password works — make sure the
                    // follow-up login() call in startDeviceEvents uses the same one, not
                    // whatever was left over from a previous device.
                    self.appState.devicePassword = attemptedPassword
                    // A real device has answered, so the stand-in's work is over. Before
                    // `startDeviceEvents`, which would otherwise run the whole connected session
                    // against the virtual device still sitting in `device`.
                    self.endManualSession()
                    self.startDeviceEvents(skipConnect: true)
                case .notTimeFlip:
                    self.appState.markDeviceInvalid(id)
                    self.appState.connectionStatus = .disconnected
                case .wrongPassword:
                    self.appState.pairingFailed(message: "Wrong PIN")
                case .failed:
                    self.appState.pairingFailed(message: "Connect failed")
                case .cancelled:
                    break // state already reset by AppState.cancelPairingAttempt()
                }
                // An attempt that started from a manual session and did not pair leaves that session
                // exactly as it was, so the status has to go back to saying so. Every branch above
                // lands somewhere that describes an app timing from nothing -- `.failed`, or the
                // `.disconnected` that `markDeviceInvalid`'s branch and `cancelPairingAttempt` set --
                // while the virtual device is still running and still writing segments. The menu bar
                // would clear, the Faces tab's timer would go with it, and the clock would carry on
                // underneath. Deliberately after the switch and not inside four branches: what
                // matters is that the attempt is over and nothing came of it, not which way.
                //
                // Only the failures. `.connected` ended the session above, which is what makes
                // `manualDevice` nil here and this a no-op on the one path that did pair.
                if self.manualDevice != nil, self.appState.connectionStatus != .connected {
                    DeveloperMode.debugPrint(.manualMode, "Pairing attempt ended without pairing; manual session continues")
                    self.appState.enterManualMode()
                }
            }
        }
        appState.onCancelPairingAttempt = { [weak self] in
            self?.bleDevice?.cancelConnectionAttempt()
        }
        appState.onFactoryResetRequest = { [weak self] in
            // Against the protocol, not `as? TimeFlipBLEDevice`: the cast made this path
            // unreachable for the mock, so the one flow whose failure mode is "the cube is
            // unreachable afterwards" was the one flow with no test coverage.
            guard let self, let device = self.device else { return false }
            // Arm the confirmation window BEFORE sending 0xFF so the disconnect the reset triggers
            // is recognised as "device rebooting" (kept as .resetting) rather than a reconnect
            // failure. The stored password is cleared only once the reset is actually confirmed
            // (see the pendingFactoryResetConfirm branch in startDeviceEvents).
            self.pendingFactoryResetConfirm = true
            self.factoryResetConfirmDeadline = Date().addingTimeInterval(self.factoryResetConfirmTimeout)
            self.reconnectAttempt = 0
            let sent = await device.factoryReset()
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
        appState.onDeviceRenameRequest = { [weak self] name in
            // Against the protocol rather than `as? TimeFlipBLEDevice`, so the mock can drive this
            // path too -- the same reason onFactoryResetRequest is written that way.
            guard let device = self?.device as? TimeFlipSessionManaging else { return false }
            guard await device.setDeviceName(name) else { return false }
            // The scan filter has to learn the new name in the same breath as the device does.
            // Leave it until the next launch and a drop in between would be unrecoverable: the
            // reconnect scan would still be looking for the name the cube no longer answers to.
            // The name being displaced is kept rather than dropped: the GAP name macOS reports is
            // one connection stale, so the very next scan is still seeing it.
            if let ble = device as? TimeFlipBLEDevice {
                ble.previouslyKnownDeviceName = ble.rememberedDeviceName
                ble.rememberedDeviceName = name
            }
            return true
        }
        appState.onDisplaySecondsChange = { [weak self] enabled in
            guard let self else { return }
            DeveloperMode.debugPrint(.field, "Field changed: Display seconds: \(enabled ? "on" : "off")")
            self.dataStore.saveDisplaySecondsEnabled(enabled)
            self.menuBarController.setDisplaySeconds(enabled)
        }
        appState.onPauseOnLockChange = { [weak self] enabled in
            guard let self else { return }
            DeveloperMode.debugPrint(.field, "Field changed: Pause on lock: \(enabled ? "on" : "off")")
            self.dataStore.savePauseOnLockEnabled(enabled)
            // Nothing to apply: handleLockRequest and the quit path each re-read the setting when
            // they run, so the next lock picks this up without anything being held in sync here.
        }
        appState.onFetchHistoryIntervalChange = { [weak self] seconds in
            guard let self else { return }
            DeveloperMode.debugPrint(.field, "Field changed: History fetch interval: \(seconds)s")
            self.dataStore.saveFetchHistoryIntervalSeconds(seconds)
            // Re-reads the setting and replaces the existing timer, so the new interval applies now
            // rather than at the next launch.
            self.historyIngestor?.startPeriodicFetchTimer()
        }
        appState.onBlipTimeChange = { [weak self] seconds in
            guard let self else { return }
            DeveloperMode.debugPrint(.field, "Field changed: Blip time: \(seconds)s")
            self.dataStore.saveBlipTimeSeconds(seconds)
            // Nothing to re-arm: the value is read when a segment is converted, so the next
            // conversion picks it up on its own.
        }
        appState.onLowBatteryThresholdChange = { [weak self] percent in
            guard let self else { return }
            DeveloperMode.debugPrint(.battery, "Field changed: Low battery threshold: \(percent)%")
            self.dataStore.saveLowBatteryLevelPercent(percent)
            self.menuBarController.setLowBatteryThreshold(percent)
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
            DeveloperMode.debugPrint(.ledBright, "Brightness value changed to \(percent)%")
            self.dataStore.saveLEDBrightnessPercent(percent)
            DeveloperMode.debugPrint(.ledBright, "Brightness saved to DB: \(percent)%")
            self.ledBrightnessWriteDebouncer.schedule { [weak self] in
                await self?.device?.setLEDBrightness(percent: percent)
            }
        }
        appState.onBlinkIntervalChange = { [weak self] seconds in
            guard let self else { return }
            DeveloperMode.debugPrint(.ledBlink, "Blink interval value changed to \(seconds)s")
            self.dataStore.saveLEDBlinkIntervalSeconds(seconds)
            DeveloperMode.debugPrint(.ledBlink, "Blink interval saved to DB: \(seconds)s")
            self.blinkIntervalWriteDebouncer.schedule { [weak self] in
                await self?.device?.setBlinkInterval(seconds: seconds)
            }
        }
        appState.onDoubleTapParametersChange = { [weak self] params, immediately in
            guard let self else { return }
            let summary = "ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)"
            DeveloperMode.debugPrint(.doubleTap, "Params changed: \(summary)")
            guard !immediately else {
                // A boolean flip (the Disable checkbox) has nothing to settle, so it goes now. Any
                // pending register write is dropped first: it carries parameters worked out before
                // the flag flipped, so letting it land afterwards would undo the toggle.
                self.doubleTapWriteDebouncer.cancel()
                DeveloperMode.debugPrint(.doubleTap, "Params sent without debounce: \(summary)")
                Task { @MainActor [weak self] in
                    await self?.device?.setDoubleTapParameters(params)
                }
                return
            }
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
        // The LED colours follow the faces' categories: assigning a face a different category, or
        // recolouring a category on the Categories tab, is what changes what the device lights up.
        // Debounced like the other device writes, since clicking along the Faces tab's category list
        // to find the right one emits a change per click -- only where it settles needs to be sent.
        appState.$faceCategories
            .sink { [weak self] categories in
                Task { @MainActor in
                    guard let self else { return }
                    let colours = self.appState.faceLEDColours(in: categories)
                    if !self.faceColorInitialized {
                        // First emission is the state as loaded, not an edit -- record what the
                        // device is assumed to already show without writing all 12 faces at launch.
                        self.lastSentFaceColors = colours
                        self.faceColorInitialized = true
                        return
                    }
                    self.faceColourWriteDebouncer.schedule { [weak self] in
                        guard let self else { return }
                        // Re-read the categories rather than sending the snapshot this emission
                        // carried: the whole point of waiting is to send where the edits settled.
                        await self.sendFaceColors(in: self.appState.faceCategories, reason: "category edit")
                    }
                }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest(appState.$googleCalendarID, appState.$googleCalendarName)
            .sink { [weak self] id, name in
                self?.dataStore.recordGoogleCalendar(id: id, name: name)
            }
            .store(in: &cancellables)
        appState.$googleClientID
            .sink { [weak self] clientID in
                let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.dataStore.recordGoogleClientID(trimmed.isEmpty ? nil : trimmed)
            }
            .store(in: &cancellables)
        // Two rows, not one, because the two have different lifetimes: Forget Device clears the
        // uuid and leaves the name (see AppState.forgetDevice). Persisted from `deviceName` rather
        // than the Device tab's `pairedDeviceName`, so the "Not paired" placeholder never reaches
        // the database as if it were a device called that.
        appState.$deviceName
            .sink { [weak self] name in
                self?.dataStore.recordDeviceName(name)
            }
            .store(in: &cancellables)
        appState.$pairedDeviceUUID
            .sink { [weak self] uuid in
                self?.dataStore.recordDeviceUUID(uuid)
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
        // Being paired is what makes a connection attempt worth making at all -- an app that has
        // never been paired, or has been told to forget, has no device to reach for.
        if appState.isPaired {
            startDeviceEvents()
        } else {
            // So it times manually instead, from the moment it opens and without being asked. The
            // offer exists to settle a question ("your cube isn't answering -- keep trying, or time
            // it yourself?"), and with nothing paired there is no question: no device was expected, no
            // scan has failed, and there is nothing to retry. Asking anyway would be asking somebody
            // who has never owned a cube to decide about one.
            //
            // What it replaces is an app that sat inert -- no timer, no way to record anything, and a
            // menu bar showing its own name -- until the user found the Device tab and paired
            // something. That is the state a brand-new user starts in, and the state anybody who
            // forgets their device restarts into. Both can now use the app straight away, and pair
            // when there is something to pair: scanning works from inside a manual session (see
            // `bleDevice`), so buying a cube later costs a scan and a click, not a reinstall's worth
            // of confusion.
            DeveloperMode.debugPrint(.manualMode, "Nothing paired at launch; starting in manual mode")
            appState.enterManualMode()
            startManualSession()
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
    /// rationale as locking via the app pausing first (see `handleLockRequest` and
    /// `pause_on_lock`'s seed description): the device shouldn't keep recording time against a
    /// category once nothing's left controlling it. Quitting locks the device, so the setting that
    /// governs "pause whenever the app locks" governs this too.
    /// If the setting is disabled (or the device isn't reachable to be commanded), quit
    /// immediately with no device interaction -- being paired isn't enough here, since pause/lock
    /// are BLE round trips that go nowhere without a live connection. Delays termination
    /// (`.terminateLater`) rather than blocking this call, since they're async.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let device, appState.isConnected, dataStore.loadPauseOnLockEnabled() else {
            DeveloperMode.debugPrint(.timeFlip, "Quit requested; pause_on_lock disabled or device not connected, exiting immediately")
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
        // Quitting is how a manual session ends, and nothing else will close its segment: a cube's
        // is closed by the frame after it, and there is no frame after this one. Done here, straight
        // against the database, rather than by pausing the virtual device and refreshing history:
        // that path is async and coalesces against a fetch already running, either of which would
        // lose the race with termination.
        // Asked of the virtual device itself rather than of the status, which can have left `.manual`
        // for `.pairing` with the session still running underneath it (see `endManualSession`) -- and
        // a quit during that attempt would otherwise leave the segment open.
        if manualDevice != nil {
            dataStore.closeOpenManualSegment(endingAt: Date())
        }
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
            guard !self.appState.isConnected else {
                self.logger.notice("System woke from sleep; device already connected")
                return
            }
            guard self.appState.shouldAttemptConnection else { return }
            self.logger.notice("System woke from sleep; forcing a fresh device reconnect attempt")
            self.stopDeviceEvents()
            self.reconnectAttempt = 0
            self.appState.connectionStatus = .reconnecting
            // Deliberate pause between showing the yellow "reconnecting" text and actually
            // attempting the connection. Without it, a fast reconnect makes it impossible to tell
            // whether this wake-triggered retry path ran at all versus the device just already
            // being in range by coincidence.
            DeveloperMode.debugPrint(.timeFlip, "System wake: reconnecting status shown, waiting 2s before connect attempt")
            try? await Task.sleep(nanoseconds: 2 * TimeConstants.nanosecondsPerSecond)
            guard self.appState.shouldAttemptConnection else { return }
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
            // The one authoritative "the cube really is called this now" signal, so it outranks the
            // stored name that `confirmConnected` otherwise keeps -- unlike a connect-time read,
            // this fires *because* the name changed rather than reporting a cached one.
            bleDevice.onDeviceNameChanged = { [weak self] name in
                // Compared against the live stored name, not `rememberedDeviceName`. That is a
                // snapshot taken before the connect for the scan filter, and a connect can move the
                // stored name out from under it: when it did, this guard rejected the one
                // authoritative name report on the grounds that it matched a value the connect had
                // already replaced, and the wrong name stayed on screen (measured 2026-08-10).
                guard let self, let name, !name.isEmpty, name != self.appState.deviceName else { return }
                self.appState.adoptReportedDeviceName(name)
                bleDevice.previouslyKnownDeviceName = bleDevice.rememberedDeviceName
                bleDevice.rememberedDeviceName = name
            }
            // Before the connect below, because the connect IS the scan: a cube renamed off
            // "timeflip" matches on one of these names or on nothing at all. Both go in, since the
            // scan after a rename is still seeing the name before it.
            bleDevice.rememberedDeviceName = appState.deviceName
            bleDevice.previouslyKnownDeviceName = dataStore.loadPreviousDeviceName()
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
                let outcome = await self.connectToPairedDevice(device)
                // A deliberate teardown -- a forget, a reset, a quit -- is not a verdict on whether
                // the device is in range, so it must not reach the failure handling below. It
                // mattered less while the offer waited for a third failure; now that the first one
                // asks, letting this through would put the dialog up because the user pressed
                // Forget Device.
                guard outcome != .cancelled else { return }
                guard outcome == .connected else {
                    logger.error("TimeFlip connect failed; will retry")
                    await MainActor.run {
                        // A newer attempt has replaced this one, so this result is about a
                        // connection nobody is waiting for any more, and acting on it does harm.
                        //
                        // Retry is where that happens, and the position of this check is the whole
                        // fix. The offer is raised from inside this very task and puts up a modal,
                        // so the main actor is busy answering the dialog while this block sits in
                        // the queue. Retry clears the awaiting flag and starts a fresh attempt;
                        // then the modal returns, this block finally runs, raises the dialog a
                        // second time, and `offerManualMode` -> `stopDeviceEvents` cancels the
                        // attempt Retry just started, before its first line executes. Measured
                        // 2026-08-10: Retry logged "scanning again", the new task was created 2ms
                        // later, the dialog was back 3ms after that, and no scan ran for 99s.
                        //
                        // Checking before the `await` instead proves nothing, because the
                        // generation is still current at that point -- tried on the device, and it
                        // changed nothing at all. `eventTaskGeneration` already existed for this
                        // and was consulted only by the `defer` above.
                        guard self.eventTaskGeneration == generation else { return }
                        // Every eligible device was there and refused this app's PIN. Retrying
                        // scans up the same cube for the same refusal, so this is the same final
                        // answer either way -- ask now. Only on a launch that has never connected:
                        // after that, the offer is over for the session and a refusal is handled as
                        // any other drop.
                        if outcome == .allRefused, !self.manualModeOffer.hasConnectedThisLaunch {
                            self.offerManualMode()
                            return
                        }
                        self.handleReconnectFailure(message: "Connect failed")
                    }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            var passwordUsed = appState.devicePassword
            var loggedIn = await device.login(password: passwordUsed)
            // The factory default is a PAIRING password, not a connection fallback. Connecting is
            // gated on already being paired, which means the app is supposed to know this device's
            // password -- if the stored one is rejected, the honest answer is that the pairing is
            // no longer valid and the user has to Forget and re-pair. Silently retrying 000000
            // hides that: it re-logs-in to a device whose password the app has actually lost track
            // of, so an out-of-band reset looks like nothing happened.
            //
            // The one exception is a factory reset this app itself just issued, where coming back
            // on the default is the defined proof the 0xFF wipe took effect. That window is opened
            // by us, bounded by factoryResetConfirmDeadline, and ends by dropping the device into
            // the never-paired state below -- so it is confirming a reset, not connecting.
            if !loggedIn, pendingFactoryResetConfirm,
               (device as? TimeFlipBLEDevice)?.wasWrongPassword == true,
               passwordUsed != TimeFlipConstants.defaultPassword {
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
                        // An already-paired device rejecting the stored password is a connection
                        // failure, not an unpairing: the app still knows which device this is, and
                        // dropping the pairing on its behalf would throw away the remembered device
                        // over what might be a one-off. Surface it and stop retrying -- Forget
                        // Device is the user's move to make. A device that was never paired (the
                        // pairing attempt itself) goes through pairingFailed instead.
                        if self.appState.isPaired {
                            self.appState.connectionFailed(message: "Wrong PIN")
                        } else {
                            self.appState.pairingFailed(message: "Wrong PIN")
                        }
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
                        // 0xFF wipes the name along with everything else, so the remembered one is
                        // discarded here rather than kept the way Forget Device keeps it.
                        self.appState.forgetDevice(deviceWasWiped: true)
                        // The wipe is what this branch just proved, so `config.json` has to follow
                        // the cube back to the factory default -- otherwise the next launch presents
                        // a password a wiped cube no longer holds.
                        self.appState.recordDevicePasswordInConfig(TimeFlipConstants.defaultPassword)
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
            // This is purely a connection event: it stamps connection.last_connection and marks the
            // link up, and deliberately does NOT touch `paired`. Whether the app is paired was
            // settled before this attempt was made, and reaching the device doesn't change it.
            let connectedAt = dataStore.recordConnection()
            DeveloperMode.debugPrint(.timeFlip, "connection.last_connection recorded: \(connectedAt)")
            await MainActor.run {
                // Login confirms the device is reachable and authenticated again — clear the
                // "reconnecting" state right away; the history backfill below will correct the
                // displayed face/duration/pause state to whatever the device actually reports.
                if self.appState.connectionStatus == .reconnecting {
                    self.appState.connectionStatus = .connected
                }
                self.reconnectAttempt = 0
                // Settles the manual-mode question for the rest of this session: from here a drop
                // reconnects on the backoff indefinitely, with no offer. Having the cube and then
                // losing it is a different situation from never having had it.
                let wasFirstConnect = !self.manualModeOffer.hasConnectedThisLaunch
                self.manualModeOffer.recordConnected()
                if wasFirstConnect, let ble = self.device as? TimeFlipBLEDevice {
                    // The short startup scan budget was there to reach a verdict while someone was
                    // watching. Nobody is now, and a reconnect is chasing a device this launch has
                    // already reached, so give the scan the full watchdog back.
                    ble.connectScanTimeoutSeconds = ble.defaultConnectScanTimeoutSeconds
                }
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
            // Rotate only in the pairing flow itself (`skipConnect` is only ever true there), and
            // only for a cube that answered to the vendor default -- `PairingPasswordRules` holds
            // why. Routine reconnects afterward keep reusing the same password.
            if skipConnect, PairingPasswordRules.rotatesPassword(passwordUsed: passwordUsed),
               let bleDevice = device as? TimeFlipBLEDevice,
               let rotatedPassword = await bleDevice.rotateDevicePassword() {
                await MainActor.run {
                    self.appState.devicePassword = rotatedPassword
                    // Dev mode writes the PIN into config.json rather than the Keychain, because
                    // that file is what a paired connect reads. This is the one save that sets the
                    // field rather than passing it through from disk -- see
                    // `AppState.recordDevicePasswordInConfig` for why that is safe only here.
                    self.appState.recordDevicePasswordInConfig(rotatedPassword)
                }
                if !DeveloperMode.isEnabled {
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
            DeveloperMode.debugPrint(.syncLed, "LED brightness: no device read-back available; applying \(appState.ledBrightnessPercent)%")
            await device.setLEDBrightness(percent: appState.ledBrightnessPercent)
            DeveloperMode.debugPrint(.syncLed, "LED blink interval: no device read-back available; applying \(appState.blinkIntervalSeconds)s")
            await device.setBlinkInterval(seconds: appState.blinkIntervalSeconds)
            // Face colours have no read-back either, so lastSentFaceColors is the app's only
            // record of what the device is showing -- and at the start of a run that record is an
            // assumption seeded from the DB, not evidence of anything having been sent. So the first
            // connect of a run writes all 12 outright, as does a fresh pairing (skipConnect is only
            // true there), which is a device this app has never coloured. Later reconnects in the
            // same run have really sent those writes, so they trust the record and write only what
            // drifted -- in practice a face reassigned while the device was away.
            let isFirstFaceColourSync = skipConnect || !hasSentFaceColoursThisRun
            await sendFaceColors(
                in: appState.faceCategories,
                reason: skipConnect ? "pairing" : (hasSentFaceColoursThisRun ? "reconnect" : "launch"),
                force: isFirstFaceColourSync
            )
            hasSentFaceColoursThisRun = true
            faceColorInitialized = true
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
        // The device being torn down, captured now rather than read again when the task runs. Manual
        // mode puts a different one in `device` moments after this returns, and re-reading the
        // property there would disconnect the replacement instead of the one being let go.
        let outgoing = device
        Task {
            await outgoing?.disconnect()
        }
        eventTask?.cancel()
        eventTask = nil
        historyIngestor?.stopPeriodicFetchTimer()
        mockHTTPServer?.stop()
        mockHTTPServer = nil
        logger.notice("Device event stream stopped")
    }

    /// The device went away on its own -- out of range, powered off, BLE dropped. Only the
    /// connection is affected: the pairing is untouched, so the app keeps knowing which device it
    /// is meant to be talking to and keeps trying to get back to it.
    private func handleDeviceDisconnect() {
        logger.warning("Device disconnected; attempting auto-reconnect")
        let lostAt = dataStore.recordConnectionLost()
        DeveloperMode.debugPrint(.timeFlip, "connection.connection_lost recorded: \(lostAt)")
        // A new connection gets a fresh hearing: the cooldown is there to stop one connection's
        // repeated asking from being re-answered, not to gag a device that comes back having really
        // lost its colours.
        lastFaceColourResyncAt = nil
        suppressedFaceColourRequests = 0
        // lastSentFaceColors deliberately survives a drop: the device keeps its face colours in
        // flash, so what it was last sent is still what it is showing, and keeping the record means
        // a face reassigned while it is away registers as drift to write on reconnect. A device that
        // really did lose them reports faceColorSyncRequired.
        awaitingInitialStatus = false
        isHistoryBackfillComplete = false
        stopDeviceEvents()
        handleReconnectFailure(message: "Disconnected before pairing completed")
    }

    /// Called whenever a connection to an already-paired device is lost or a reconnect attempt
    /// fails outright. This is almost always a transient BLE issue (out of range, laptop asleep)
    /// rather than a deliberate unpair, so it must not touch `isPaired` or the on-screen activity.
    /// Instead it keeps retrying indefinitely with backoff while marking the connection
    /// `.reconnecting`, which MenuBarController renders by leaving the last known
    /// icon/activity/timer on screen. History resync after a successful reconnect corrects anything
    /// that drifted while offline.
    private func handleReconnectFailure(message: String) {
        // Mid factory-reset: the disconnect is the device rebooting after the 0xFF command. Keep the
        // "Resetting..." status (not a scary "Reconnecting/Failed") and keep retrying to catch the
        // device coming back on the default password.
        if pendingFactoryResetConfirm {
            retryOrTimeOutFactoryResetConfirm()
            return
        }
        // Nothing to reconnect to: this drop happened during a pairing attempt that never got as
        // far as pairing (a drop between connect() and the first face event), so report it as the
        // pairing failure it is rather than retrying forever against a device the app isn't
        // actually paired to.
        //
        // Deliberately `shouldMaintainConnection` and not `shouldAttemptConnection`: this asks
        // whether there is a pairing to reconnect to, not whether an attempt may run right now.
        // Reading the manual-mode gates here would report a pairing failure for a device that is
        // perfectly well paired and merely out of range.
        guard appState.shouldMaintainConnection else {
            appState.pairingFailed(message: message)
            return
        }
        // An attempt that was already in flight when the offer went up, landing afterwards. The
        // dialog is the only thing that decides what happens next, so this failure changes nothing.
        guard !appState.isAwaitingManualModeDecision, !appState.isManualMode else { return }
        guard manualModeOffer.recordFailedAttempt() == .keepTrying else {
            offerManualMode()
            return
        }
        appState.connectionStatus = .reconnecting
        scheduleReconnect()
    }

    /// Find this app's own device among everything advertising, and log in to it.
    ///
    /// Scan, build the list of eligible devices, then try each in turn until one accepts the
    /// password or the list runs out. The list is eligible-by-name, which in an office is several
    /// people's cubes; only one of them will take this app's PIN, and that is what identifies it.
    /// The previous driver connected to whichever answered first and stopped there, so a colleague's
    /// cube advertising a moment sooner was enough to lock this user out of their own device with a
    /// "wrong password" that named nothing.
    ///
    /// `.wrongPassword` is therefore not a failure, it is the answer to "is this one mine?" and the
    /// loop moves on. Only running out of candidates is a failure, and that is what the manual-mode
    /// offer counts.
    ///
    /// The mock has no radio and nothing to scan, so it keeps `connect()`.
    private func connectToPairedDevice(_ device: TimeFlipSessionManaging) async -> ConnectAttemptOutcome {
        attemptEligibleCount = 0
        attemptRefusedCount = 0
        guard let ble = device as? TimeFlipBLEDevice else {
            return await device.connect() ? .connected : .noneEligible
        }

        let pairedUUID = appState.pairedDeviceUUID.flatMap(UUID.init(uuidString:))
        // Confirming a reset waits the whole scan window out. The cube is still advertising, and
        // still on its old password, for several seconds after 0xFF, so the device present at the
        // start of the window is the one being replaced rather than the one being waited for.
        let candidates = await ble.scanForEligibleDevices(
            preferring: pairedUUID,
            mayEndEarly: !pendingFactoryResetConfirm
        )
        attemptEligibleCount = candidates.count
        guard !candidates.isEmpty else {
            DeveloperMode.debugPrint(.scan, "no eligible device found in this scan")
            return .noneEligible
        }
        // Mid factory-reset the cube has gone back to the default password, and that login is the
        // proof the wipe took -- so it goes **first**, ahead of the stored one.
        //
        // It used to be appended, and that made the reset impossible to confirm. The stored password
        // is guaranteed wrong once the wipe has landed, a rejected probe drops the link on its way
        // out (`connectToDiscoveredDevice` cancels the peripheral connection in a `defer`), and the
        // next attempt on that same peripheral then races the teardown and fails before it can send
        // anything. Measured on the device 2026-08-09: `refused this app's PIN` and `could not be
        // reached` in the same second, with no `Probe logging in using password` line for the second
        // attempt at all -- the default was never actually presented, every scan round repeated it,
        // and `02b` timed out waiting for a confirmation that could not arrive.
        var passwords = [appState.devicePassword]
        if pendingFactoryResetConfirm, appState.devicePassword != TimeFlipConstants.defaultPassword {
            passwords.insert(TimeFlipConstants.defaultPassword, at: 0)
        }

        for candidate in candidates {
            // Counted per candidate, not per attempt: mid-factory-reset there are two passwords to
            // try, and a cube that refuses both is still one device that refused, not two.
            var refusedThisCandidate = false
            for (attempt, password) in passwords.enumerated() {
                // Let the previous probe's teardown finish before reconnecting to the same
                // peripheral. Ordering above means the reset case no longer depends on this, but a
                // second attempt that fails instantly is not an answer about the password -- it is
                // the radio still holding the last one.
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: probeSettleSeconds * TimeConstants.nanosecondsPerSecond)
                }
                switch await ble.connectToDiscoveredDevice(id: candidate.id, password: password) {
                case .connected:
                    DeveloperMode.debugPrint(.scan, "logged in to \(candidate.name)")
                    return .connected
                case .wrongPassword:
                    refusedThisCandidate = true
                    DeveloperMode.debugPrint(.scan, "\(candidate.name) refused this app's PIN; trying the next device")
                case .notTimeFlip:
                    DeveloperMode.debugPrint(.scan, "\(candidate.name) is not a TimeFlip after all; trying the next device")
                case .cancelled:
                    return .cancelled
                case .failed:
                    DeveloperMode.debugPrint(.scan, "\(candidate.name) could not be reached; trying the next device")
                }
            }
            if refusedThisCandidate {
                attemptRefusedCount += 1
            }
        }
        DeveloperMode.debugPrint(.scan, "none of the \(candidates.count) eligible device(s) accepted this app's PIN")
        return .allRefused
    }

    /// Why an attempt to reach the paired device ended, in the terms the manual-mode offer needs.
    /// The difference that matters is whether anything eligible was *there*: nothing in range is
    /// worth retrying, and a cube that refused the PIN is not, because the next scan finds the same
    /// cube and it refuses again.
    private enum ConnectAttemptOutcome {
        case connected
        /// The scan found nothing this app could be paired to. Counts toward the retry threshold.
        case noneEligible
        /// Devices were found and every one refused this app's PIN. Straight to the dialog.
        case allRefused
        /// Torn down deliberately (a forget, a reset, a quit). Not a verdict on anything.
        case cancelled
    }

    /// The default presentation of the offer: a modal `NSAlert`.
    ///
    /// `NSAlert` rather than a SwiftUI `.alert`, which is what the rest of the app uses, because
    /// every one of those hangs off a view inside the Settings window and this has to be answerable
    /// when no window is open at all -- the usual case at startup for an `LSUIElement` app. The
    /// activate call is part of that: a menu-bar app is not frontmost, so without it the alert can
    /// come up behind whatever the user is actually looking at.
    private func runManualModeAlert(_ answer: @escaping (ManualModeAnswer) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Unable to find your device, retry or switch to manual mode"
        alert.informativeText = """
            No TimeFlip answered: either none is in range, or none of the ones found would accept \
            this app's PIN.

            Manual mode lets you track time from the app instead. It won't try your device again on \
            its own -- quit and start the app when you want it back.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Switch to Manual Mode")
        NSApp.activate(ignoringOtherApps: true)
        answer(alert.runModal() == .alertFirstButtonReturn ? .retry : .switchToManualMode)
    }

    /// Stop trying and ask: retry, or switch to manual mode for the rest of this launch.
    ///
    /// Reached only from a launch that has never connected, on the first failed attempt. No attempt
    /// runs while this is on screen -- `AppState.shouldAttemptConnection` is false from here until
    /// an answer arrives, which closes off the backoff retry and the wake-from-sleep path alike.
    ///
    /// **Two callers race to get here and both arrive.** A refused PIN ends the probe, and the
    /// disconnect that causes reaches `handleReconnectFailure` before `startDeviceEvents` can act
    /// on the `.allRefused` it is about to be handed -- measured at 3ms apart on hardware
    /// 2026-08-09. The loser used to arrive anyway, blocked behind `runModal()`, and fire the
    /// instant the user chose manual mode: the dialog went straight back up and `stopDeviceEvents()`
    /// tore down the session that had just started, so the mode could only be entered by answering
    /// the same question twice. The guard below is what makes a second call harmless, and it lives
    /// here rather than at the call sites because only one of them ever had it.
    ///
    /// The reason is derived rather than passed in for the same reason: the caller that knows the
    /// true answer is the one that loses the race. See `ManualModeOfferReason`.
    private func offerManualMode() {
        guard appState.mayOfferManualMode else { return }
        let reason = ManualModeOfferReason.describe(
            eligibleFound: attemptEligibleCount,
            refusedPIN: attemptRefusedCount
        )
        DeveloperMode.debugPrint(.manualMode, "Offering manual mode: \(reason)")
        appState.awaitManualModeDecision()
        appState.connectionStatus = .disconnected
        stopDeviceEvents()
        presentManualModeOffer? { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .retry:
                DeveloperMode.debugPrint(.manualMode, "Retry chosen; scanning again")
                // The delay counter goes back to the start, so the next attempt begins two seconds
                // out rather than at whatever the last one had climbed to.
                self.reconnectAttempt = 0
                self.appState.manualModeDeclined()
                self.appState.connectionStatus = .reconnecting
                self.startDeviceEvents()
            case .switchToManualMode:
                DeveloperMode.debugPrint(.manualMode, "Manual mode chosen; no further connection attempts this launch")
                self.appState.enterManualMode()
                self.startManualSession()
            }
        }
    }

    /// Stands a virtual device up where the cube was, and runs the ordinary event loop against it.
    ///
    /// The substitution is the whole trick: a manually timed segment is not a second kind of record
    /// living beside the real ones, it is a `device_event` written by the same `HistoryIngestor`
    /// from the same history frames, so the menu bar, the daily totals, `time_entry` and the Report
    /// all keep working with nothing added to any of them.
    ///
    /// Deliberately **not** `startDeviceEvents`, which is the connect-and-log-in path and does a
    /// pile of things that would be lies here: it stamps `connection.last_connection` for a device
    /// that was never reached, syncs LED brightness and face colours to hardware that does not
    /// exist, and stands up `MockEventHTTPServer`, a developer control surface that has no business
    /// listening on a port during an ordinary user's session. What is actually needed is the
    /// ingestor, the event stream, and nothing else.
    ///
    /// The virtual device starts **empty and stopped**: no seeded sample history (those two invented
    /// segments would be ingested into a real database as work the user never did), no initial face,
    /// and no auto-pause, which on a real cube is a convenience and here would silently stop a timer
    /// the user is relying on.
    private func startManualSession() {
        let mock = MockTimeFlipDevice(
            configuration: MockTimeFlipDevice.Configuration(
                initialFaceID: TimeFlipConstants.unassignedFaceID,
                isPaused: true,
                isInitiallyPaired: true,
                autoPauseMinutes: 0,
                emitInitialStatus: false,
                seedsSampleHistory: false,
                reportsOpenSegment: true
            )
        )
        device = mock
        manualDevice = mock
        historyIngestor = HistoryIngestor(
            device: mock,
            dataStore: dataStore,
            appState: appState,
            dailyTotals: dailyTotals,
            onLatestEntry: { [weak self] entry in
                self?.applyActiveInterval(from: entry)
            }
        )
        historyIngestor?.startPeriodicFetchTimer()
        // The events are what make a click feel immediate: `handleDeviceEvent` refreshes history on
        // any face or pause change, so a segment reaches the database on the click rather than at
        // the next tick of the periodic timer.
        //
        // `awaitingInitialStatus` stays false on purpose. It is what turns the first face event of a
        // connection into `confirmConnected(name:uuid:)`, and this device's name is nothing -- it
        // would overwrite the real cube's remembered name with a blank, losing the app's handle on
        // the device the user is going to want back on the next launch.
        awaitingInitialStatus = false
        isHistoryBackfillComplete = true
        eventTaskGeneration += 1
        let generation = eventTaskGeneration
        eventTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.eventTaskGeneration == generation {
                    self.eventTask = nil
                }
            }
            _ = await mock.connect()
            _ = await mock.login(password: TimeFlipConstants.defaultPassword)
            await mock.enableNotifications()
            for await event in mock.events {
                self.handleDeviceEvent(event)
            }
        }
        mock.start()
        DeveloperMode.debugPrint(.manualMode, "Manual session started on face \(TimeFlipConstants.manualFaceID)")
    }

    /// Stands the virtual device down, because a real one has just been paired.
    ///
    /// The one way a manual session ends without the app quitting, and it is a deliberate act of the
    /// user's: they scanned, they picked a cube, and it answered. Nothing automatic reaches here --
    /// see `AppState.enterManualMode` for why that matters.
    ///
    /// **The segment is closed first, and closing it is the whole reason this is not just
    /// `stopDeviceEvents()`.** Every other segment in `device_event` is closed by the frame that
    /// follows it, and a manual session's last one has no frame coming: the virtual device is about to
    /// stop existing, so left alone the row the user was timing stays `finalised = 0` and never
    /// becomes a `time_entry`. `applicationWillTerminate` does the same thing for the same reason on
    /// the quit path; this is that path's twin, for a session that ends while the app keeps running.
    ///
    /// It also settles the double-counting question this codebase has been careful about (see
    /// `docs/TODO-features-under-development.md`, Manual mode): the manual row is closed and the
    /// virtual device torn down *before* anything connects, so a manual segment and a cube's can
    /// still never describe the same span. `manualDevice` going nil is what the timing controls and
    /// `applicationWillTerminate` read to know the session is over.
    private func endManualSession() {
        guard manualDevice != nil else { return }
        let closed = dataStore.closeOpenManualSegment(endingAt: Date())
        DeveloperMode.debugPrint(.manualMode, "Manual session ending, a device has been paired; open segment closed: \(closed)")
        stopDeviceEvents()
        manualDevice = nil
        // Back to the radio, which was never anywhere else -- see `bleDevice`. The probe that just
        // succeeded ran on it, and it is what `startDeviceEvents` is about to log in with. Left alone
        // if there is no radio at all: only the mock-events build is in that position, and it has no
        // way to reach this in the first place, so putting `nil` in `device` would be inventing a
        // state rather than restoring one.
        if let bleDevice {
            device = bleDevice
        }
    }

    /// Picks the category being timed, and starts the clock on it.
    ///
    /// **The order is the point.** A `time_entry` records the category its face was mapped to when
    /// the segment happened, and manual mode's face is remapped every time the user picks something
    /// new -- so writing the new category first would convert the segment that just ended against
    /// the category it was not. The flip closes that segment, the refresh converts it while the old
    /// mapping still stands, and only then does the face take the new category, which the next
    /// segment (open, unconverted) will be resolved through when it in turn ends.
    ///
    /// Unpausing comes after the flip rather than before it so the stub segment that leaves behind
    /// is a *paused* one, and paused segments are never converted into `time_entry` rows. Before it,
    /// the same stub would be a running segment and would land in the user's totals as a zero-second
    /// entry against whatever they had been doing.
    private func startManualTiming(categoryID: Int) {
        guard let manualDevice else { return }
        DeveloperMode.debugPrint(.manualMode, "Manual timing: category \(categoryID) on face \(TimeFlipConstants.manualFaceID)")
        manualDevice.flip(to: TimeFlipConstants.manualFaceID)
        manualDevice.setPaused(false)
        Task { [weak self] in
            guard let self else { return }
            await self.historyIngestor?.refreshHistory(trigger: "manual_start")
            self.dataStore.updateFaceCategory(faceID: TimeFlipConstants.manualFaceID, categoryID: categoryID)
            self.refreshFaceCategories()
        }
    }

    /// Stops the manual clock, or starts it again. The segment that ends is written and converted by
    /// the refresh, exactly as a flip's is.
    private func setManualTimingPaused(_ paused: Bool) {
        guard let manualDevice else { return }
        DeveloperMode.debugPrint(.manualMode, "Manual timing: \(paused ? "stopped" : "running")")
        manualDevice.setPaused(paused)
        Task { [weak self] in
            await self?.historyIngestor?.refreshHistory(trigger: "manual_pause")
        }
    }

    /// While a factory reset is pending confirmation, keep retrying the reconnect (to catch the
    /// device coming back on the default password) until `factoryResetConfirmDeadline`; once that
    /// passes, give up and surface a failure. Keeps the UI in `.resetting` throughout.
    private func retryOrTimeOutFactoryResetConfirm() {
        guard pendingFactoryResetConfirm else { return }
        if let deadline = factoryResetConfirmDeadline, Date() < deadline {
            appState.connectionStatus = .resetting
            scheduleReconnect()
        } else {
            pendingFactoryResetConfirm = false
            factoryResetConfirmDeadline = nil
            DeveloperMode.debugPrint(.timeFlip, "Factory reset NOT confirmed within timeout; the device never came back on the default password")
            appState.connectionStatus = .failed("Reset sent, but couldn't confirm — check the device")
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
            // Re-read on the far side of the sleep, not before it: the manual-mode offer can go up
            // while this delay is running, and an attempt queued a moment earlier must not land
            // behind the dialog.
            guard self.appState.shouldAttemptConnection else { return }
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
            DeveloperMode.debugPrint(.syncDtap, "Double-tap: could not read current value; applying \(expectedSummary)")
            await device.setDoubleTapParameters(expected)
            return
        }
        guard current == expected else {
            let currentSummary = "ths=\(current.clickThreshold) lim=\(current.limit) lat=\(current.latency) win=\(current.window)"
            DeveloperMode.debugPrint(.syncDtap, "Double-tap MISMATCH: device=\(currentSummary) expected=\(expectedSummary); applying")
            await device.setDoubleTapParameters(expected)
            return
        }
        DeveloperMode.debugPrint(.syncDtap, "Double-tap OK: device matches expected \(expectedSummary)")
    }

    /// Writes each face's LED colour (BLE `0x11`), skipping any that already show the right one.
    /// The colours are resolved from `categories` -- see `AppState.faceLEDColours`, including why a
    /// category with no colour resolves to black rather than being left alone. The categories come in
    /// rather than being read off `appState` so a Combine sink logs and sends the snapshot it was
    /// handed.
    ///
    /// `force` writes all 12 regardless of what was last sent, for when the device says it no longer
    /// has them. There is no read-back for `0x11` (the vendor spec defines none -- see
    /// `docs/timeflip.md`), so what was last sent is the only record of what the device is showing.
    private func sendFaceColors(
        in categories: [UInt8: CategoryRecord],
        reason: String,
        force: Bool = false
    ) async {
        let colours = appState.faceLEDColours(in: categories)
        guard let device else {
            // Not connected: leave lastSentFaceColors alone so this shows up as drift to write at
            // the next connect, rather than being recorded as though the device had received it.
            DeveloperMode.debugPrint(.syncColour, "Face colours (\(reason)): no device connected; deferred to next connect")
            return
        }
        var written: [UInt8] = []
        for faceID in TimeFlipConstants.faceIDs {
            guard let components = colours[faceID] else { continue }
            if force || lastSentFaceColors[faceID] != components {
                lastSentFaceColors[faceID] = components
                await device.setFaceColor(faceID: faceID, components: components)
                logFaceColour(faceID: faceID, components: components, in: categories, reason: reason)
                written.append(faceID)
            }
        }
        guard !written.isEmpty else {
            // Deliberately not "already up to date": with no read-back for 0x11 the app can only
            // speak for what it last sent, never for what the device is actually showing.
            DeveloperMode.debugPrint(.syncColour, "Face colours (\(reason)): unchanged since this run last sent them, nothing written")
            return
        }
        DeveloperMode.debugPrint(.syncColour, "Face colours (\(reason)): wrote \(written.count) of \(TimeFlipConstants.faceIDs.count) faces; no device read-back available")
    }

    /// The device reporting that it has lost its face colours (system state `0x02 0x02`). It can say
    /// so many times over: once per notification, once more per post-reconcile re-read, and again on
    /// every reconnect while it is unhappy. Each answer is 12 flash-writing colour commands that also
    /// light the LED, so the requests are collapsed into one resync rather than answered one for one.
    ///
    /// This is not hypothetical tidiness. With flat batteries the device was rebooting, asking on
    /// every connect, and 8 requests in one second turned into 96 colour writes -- which lit the LED
    /// continuously and helped brown out a device that was already failing to hold its own settings.
    /// The first request schedules the resync; everything arriving while one is pending, running, or
    /// inside the cooldown is counted and dropped.
    private func requestFaceColourResync() {
        let inCooldown = lastFaceColourResyncAt.map {
            Date().timeIntervalSince($0) < faceColourResyncCooldown
        } ?? false
        guard !isFaceColourResyncPending, !isFaceColourResyncRunning, !inCooldown else {
            suppressedFaceColourRequests += 1
            return
        }
        isFaceColourResyncPending = true
        DeveloperMode.debugPrint(.syncColour, "Device requested face colour resync (system state 0x02 0x02)")
        faceColourResyncDebouncer.schedule { [weak self] in
            await self?.resyncFaceColours()
        }
    }

    /// Answers a collapsed batch of resync requests with a single forced write of all 12 faces.
    @MainActor
    private func resyncFaceColours() async {
        isFaceColourResyncPending = false
        isFaceColourResyncRunning = true
        let collapsed = suppressedFaceColourRequests
        suppressedFaceColourRequests = 0
        if collapsed > 0 {
            DeveloperMode.debugPrint(.syncColour, "Collapsed \(collapsed) repeat resync request(s) into this one")
        }
        await sendFaceColors(in: appState.faceCategories, reason: "device request", force: true)
        lastFaceColourResyncAt = Date()
        isFaceColourResyncRunning = false
    }

    /// One line per face actually written, naming the face, the category on it, the colour and the
    /// hex sent -- so a face lighting up wrong (or not at all) can be checked against exactly what
    /// went out for it. `rgb16` is what `0x11` carries: hex is 8 bits per channel, the command takes
    /// 16, and both are logged so a scaling problem is visible rather than inferred.
    private func logFaceColour(
        faceID: UInt8,
        components: ColorComponents,
        in categories: [UInt8: CategoryRecord],
        reason: String
    ) {
        let category = categories[faceID]
        let categoryName = category?.name ?? "no category"
        let colourName = category.flatMap { appState.colourOption(forColourID: $0.colourID) }?.name
            // A face with no category, or one whose colour didn't resolve, is sent black. Naming it
            // "off" rather than leaving it blank keeps the reason for an unlit face on the line.
            ?? (components == .off ? "off" : "unknown colour")
        let (r, g, b) = components.deviceRGB16
        let rgb16 = String(format: "%04x,%04x,%04x", Int(r), Int(g), Int(b))
        DeveloperMode.debugPrint(
            .syncColour,
            "Face \(faceID) (\(reason)): \(categoryName) / \(colourName) \(components.hexString) sent as rgb16 \(rgb16)"
        )
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
        if awaitingInitialStatus, case .faceChanged = event {
            awaitingInitialStatus = false
            // The cube's own name, not a literal. It used to be spelled "TimeFlip" here, which
            // meant the Info panel reported that whatever the device was actually called: the
            // scan showed "TimeFlip v2.0" and this replaced it on the first face event.
            //
            // Logged because this read is the one that can overwrite `device_name`, and it is
            // `CBPeripheral.name`, which macOS caches: on 2026-08-01 it reported the name as of the
            // *previous* connection, one rename behind. Both values are printed so a run can be
            // read for whether the device agrees with what the app last wrote, rather than that
            // disagreement only surfacing later as a device nothing can find.
            let reportedName = device?.deviceName
            DeveloperMode.debugPrint(
                .deviceName,
                "device name read on connect: device=\(reportedName ?? "nil") stored=\(appState.deviceName ?? "nil")"
            )
            // The peripheral's own identifier, not nil. Passing nil here is what made
            // `pairedDeviceUUID` fall through to its `UUID()` fallback on every first pairing, so
            // the stored value identified nothing and the eligibility scan's preference could never
            // match it. A real value also self-heals an install carrying one of those random ones,
            // since a non-nil uuid replaces whatever is stored.
            appState.confirmConnected(name: reportedName, uuid: device?.deviceIdentifier)
        }
        if case .systemState(let state) = event {
            switch state.syncStatus {
            case .factoryReset:
                // Just refresh. There is no cursor to clear first: the resume position is read out
                // of `device_event` and capped at the number the cube itself reports, so a counter
                // back at the bottom is followed down without being told a reset happened. A cube
                // straight after one holds no history at all, so this finds nothing until the first
                // flip -- which is why the same path recovers a reset this session never saw.
                Task { [weak self] in
                    await self?.historyIngestor?.refreshHistory(trigger: "factory_reset")
                }
            case .faceColorSyncRequired:
                requestFaceColourResync()
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
        if useHistoryPipeline, event.isFaceOrPauseChange {
            logger.debug("schedule_history_fetch reason=live_event")
            Task { [weak self] in
                await self?.historyIngestor?.refreshHistory(trigger: "live_event")
            }
        }
        logger.debug("live_event \(event.description, privacy: .public)")
    }

    /// Re-reads `face` joined to `category` after a Categories tab edit, so a renamed, recoloured
    /// or re-iconed category reaches the menu bar straight away instead of at the next launch.
    /// Both tables are tiny and this only runs on an explicit user edit.
    /// Deletes the app's one and only `UserDefaults` key, left behind by the removed preferences
    /// blob (`timeflip.preferences`).
    ///
    /// Without this the goal in `docs/TODO-Legacy-removal.md` is only half met: nothing reads the
    /// key any more, but the state is still on disk, and `UserDefaults` never forgets a key on its
    /// own. What goes with it is any face names and icons typed before faces were assigned
    /// categories; those cannot be migrated, since a name is not a category and guessing which
    /// category a name meant would invent data. The per-face daily limits went the same way when
    /// that field moved. In practice there was nothing to lose: the blob on the development machine
    /// held 12 faces, every one of them with an empty name and icon.
    ///
    /// Safe to delete this method once every install has launched a build containing it. Costs one
    /// `UserDefaults` read per launch until then, and nothing after.
    private func removeLegacyPreferencesBlob() {
        let key = "timeflip.preferences"
        guard UserDefaults.standard.object(forKey: key) != nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
        DeveloperMode.debugPrint(.legacy, "Removed the legacy UserDefaults preferences blob (\(key))")
    }

    private func refreshFaceCategories() {
        appState.faceCategories = dataStore.loadFaceCategories()
        appState.faceLocks = dataStore.loadFaceLocks()
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
        // The stored bound: in manual mode these entries come from the virtual device on face 13.
        // The frames a real cube sends are already held to 12 by `TimeFlipHistoryParser.parse`
        // before they ever reach here, so widening this cannot let a corrupt frame through.
        guard TimeFlipConstants.isValidStoredFaceID(entry.faceID) else { return }
        let isPaused = entry.isPaused
        let elapsed: TimeInterval
        if entry.duration > 0 {
            elapsed = entry.duration
        } else {
            elapsed = max(0, Date().timeIntervalSince(entry.startedAt))
        }
        appState.currentFaceID = entry.faceID
        appState.isPaused = isPaused
        // The event number rides along so a daily limit can tell a genuinely new event from the same
        // one re-reported with a longer duration; see MenuBarController.limitWriteSentAtEventNumber.
        menuBarController.applyElapsed(
            faceID: entry.faceID,
            elapsedSeconds: elapsed,
            isPaused: isPaused,
            eventNumber: entry.eventNumber
        )
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

import AppKit
import Combine
import OSLog

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let dataStore = AppDataStore()
    private let enableGoogleIntegrations = true
    private lazy var authManager = GoogleAuthManager(
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
        preferencesProvider: { [weak appState] in
            IntegrationPreferences(
                calendarId: appState?.googleCalendarID,
                sheetURL: appState?.googleSheetURL
            )
        },
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
        settingsWindowController: settingsWindowController
    ) { [weak self] pause in
        guard let self else { return }
        Task { @MainActor in
            await self.device?.setPause(pause)
            // Device doesn't send notification after setPause command,
            // so explicitly fetch history to confirm state change
            await self.historyIngestor?.refreshHistory(trigger: "manual_pause")
        }
    }
    private let enableMockEvents = false
    private lazy var device: TimeFlipSessionManaging? = enableMockEvents ? MockTimeFlipDevice() : TimeFlipBLEDevice()
    private var eventTask: Task<Void, Never>?
    private var mockHTTPServer: MockEventHTTPServer?
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "lifecycle")
    private var cancellables: Set<AnyCancellable> = []
    private var lastSentFacetColors: [UInt8: ColorComponents] = [:]
    private var facetColorInitialized = false
    private var awaitingInitialStatus = false
    private var historyIngestor: HistoryIngestor?
    private let useHistoryPipeline = true
    private var dayResetTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
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
                let outcome = await bleDevice.connectToDiscoveredDevice(id: id)
                switch outcome {
                case .connected:
                    self.startDeviceEvents(skipConnect: true)
                case .notTimeFlip:
                    self.appState.markDeviceInvalid(id)
                    self.appState.pairingStatus = .notPaired
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
        appState.onCurrentFacetMappingChange = { [weak self] in
            self?.menuBarController.refreshFromState()
        }
        // The settings view updates appState before invoking these callbacks,
        // so the handlers only forward the new value to the device.
        appState.onAutoPauseChange = { [weak self] minutes in
            guard let self else { return }
            Task { @MainActor in
                await self.device?.setAutoPause(minutes: minutes)
            }
        }
        appState.onLEDBrightnessChange = { [weak self] percent in
            guard let self else { return }
            Task { @MainActor in
                await self.device?.setLEDBrightness(percent: percent)
            }
        }
        appState.onBlinkIntervalChange = { [weak self] seconds in
            guard let self else { return }
            Task { @MainActor in
                await self.device?.setBlinkInterval(seconds: seconds)
            }
        }
        appState.onDoubleTapParametersChange = { [weak self] params in
            guard let self else { return }
            Task { @MainActor in
                await self.device?.setDoubleTapParameters(params)
            }
        }
        appState.onDoubleTapParametersRequest = { [weak self] in
            guard let self else { return nil }
            return await self.device?.readDoubleTapParameters()
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
        menuBarController.start()
        if appState.isPaired {
            startDeviceEvents()
        } else if appState.wantsPairing {
            startDeviceEvents()
        }
        logger.info("Application did finish launching")
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        stopDeviceEvents()
        logger.info("Application will terminate")
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
            onNewEvents: { [weak self] in
                guard let self, self.enableGoogleIntegrations else { return }
                self.integrationCoordinator.flushPendingSessions()
            },
            onLatestEntry: { [weak self] entry in
                guard let self else { return }
                self.applyActiveInterval(from: entry)
            }
        )
        if let bleDevice = device as? TimeFlipBLEDevice {
            bleDevice.onDisconnect = { [weak self] in
                self?.handleDeviceDisconnect()
            }
        }
        eventTask = Task { [weak self] in
            guard let self else { return }
            defer { self.eventTask = nil }
            if !skipConnect {
                let connected = await device.connect()
                guard connected else {
                    logger.error("TimeFlip connect failed; aborting startup")
                    await MainActor.run {
                        self.appState.pairingFailed(message: "Connect failed")
                    }
                    return
                }
            }
            guard await device.login(password: appState.devicePassword) else {
                logger.error("TimeFlip login failed; events not started")
                await device.disconnect()
                let wasCancelled = (device as? TimeFlipBLEDevice)?.wasCancelled ?? false
                if !wasCancelled {
                    await MainActor.run {
                        self.appState.pairingFailed(message: "Wrong PIN")
                    }
                }
                return
            }
            await device.enableNotifications()
            let desiredAutoPause = appState.autoPauseMinutes ?? 0
            await device.initializeSession(hostTime: Date(), desiredAutoPauseMinutes: desiredAutoPause)
            await device.setLEDBrightness(percent: appState.ledBrightnessPercent)
            await device.setBlinkInterval(seconds: appState.blinkIntervalSeconds)
            if let params = appState.doubleTapParameters {
                await device.setDoubleTapParameters(params)
            }
            logger.notice("Backfill starting")
            awaitingInitialStatus = true
            await self.historyIngestor?.refreshHistory(trigger: "startup")
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
        device?.stop()
        Task { [weak self] in
            await self?.device?.disconnect()
        }
        eventTask?.cancel()
        eventTask = nil
        mockHTTPServer?.stop()
        mockHTTPServer = nil
        logger.notice("Device event stream stopped")
    }

    private func handleDeviceDisconnect() {
        logger.warning("Device disconnected; attempting auto-reconnect")
        lastSentFacetColors.removeAll()
        facetColorInitialized = false
        awaitingInitialStatus = false
        stopDeviceEvents()
        // Small delay to avoid tight retry loops.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2 * TimeConstants.nanosecondsPerSecond)
            guard let self else { return }
            if self.appState.isPaired {
                self.startDeviceEvents()
            }
        }
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
        logger.info("TimeFlip event: \(event.description, privacy: .public)")
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
        appMenu.addItem(withTitle: "Quit TimeFlip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

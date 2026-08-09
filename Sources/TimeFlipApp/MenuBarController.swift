import AppKit
import Combine
import OSLog

@MainActor
final class MenuBarController: NSObject {
    private enum Constants {
        static let defaultIconPointSize: CGFloat = 16
        static let minStatusBarIconSize: CGFloat = 14
        static let statusBarIconVerticalInset: CGFloat = 2
        static let minIndicatorAttachmentSize: CGFloat = 14
        static let indicatorScale: CGFloat = 1.6
        static let minIndicatorSymbolSize: CGFloat = 10
        // Fast enough to actually grab attention, per the low-battery warning's purpose.
        static let lowBatteryBlinkInterval: TimeInterval = 0.5
        // Hysteresis margin above lowBatteryThresholdPercent before the low-battery state clears
        // (Schmitt trigger, same idea as a map only zooming back in once well clear of the
        // zoom-out line) -- without this, a reading that wobbles right around the threshold would
        // flip the blink on/off on every read instead of latching until it's actually recovered.
        static let lowBatteryRecoveryMarginPercent = 5
    }

    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "menu-bar")
    private let appState: AppState
    private let settingsWindowController: SettingsWindowController
    private let onPauseToggle: ((Bool) -> Void)?
    private let onLockRequest: (() -> Void)?
    // Not a `let`: the App tab can change it while the app runs, which has to re-arm the refresh
    // timer as well as change the format, since the tick interval follows it.
    private var displaySecondsEnabled: Bool
    // Not a `let`: the App tab can change it while the app runs.
    private var lowBatteryThresholdPercent: Int
    private var pendingSingleClickWorkItem: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    private var currentActivity: Activity?
    private var isPaused = false
    private var activityStartDate: Date?
    private var currentSegmentElapsed: TimeInterval = 0
    private var refreshTimer: Timer?
    private var lowBatteryBlinkTimer: Timer?
    private var lowBatteryBlinkPhaseOn = false
    private var isLowBatteryLatched = false
    private var lastSnapshot: StatusSnapshot?
    private var cachedIcon: NSImage?
    private var cachedIconName: String?
    private var cachedIconSize: CGFloat = 0
    private var lastRenderedTitle: String = ""
    private var isPairedSnapshot: Bool
    private var connectionStatusSnapshot: ConnectionStatus
    /// Whether the app is driving time itself rather than from the cube. Mirrored here for the
    /// same reason as the two above: the click handler runs on an AppKit callback and reads its
    /// state from snapshots rather than reaching into `AppState`.
    private var isManualModeSnapshot = false
    // Whether the device has actually been reached since launch. Distinct from being paired (which
    // is remembered from a previous run) and from currentActivity being set (which
    // syncActivityFromState populates from stored state before any device is contacted). Without
    // it, a paired app that can't reach its device would show a plausible-looking "Idle 0:00" that
    // never came from the device at all. Cleared again by tearDownToUnpaired().
    private var hasReachedDeviceThisSession = false

    init(
        appState: AppState,
        settingsWindowController: SettingsWindowController,
        onPauseToggle: ((Bool) -> Void)? = nil,
        onLockRequest: (() -> Void)? = nil,
        displaySecondsEnabled: Bool = true,
        lowBatteryThresholdPercent: Int = 5
    ) {
        self.appState = appState
        self.settingsWindowController = settingsWindowController
        self.onPauseToggle = onPauseToggle
        self.onLockRequest = onLockRequest
        self.displaySecondsEnabled = displaySecondsEnabled
        self.lowBatteryThresholdPercent = lowBatteryThresholdPercent
        self.isPairedSnapshot = appState.isPaired
        self.connectionStatusSnapshot = appState.connectionStatus
        super.init()
    }

    /// Drive the timer from device-reported elapsed seconds (cmd 0x14).
    func applyElapsed(faceID: UInt8, elapsedSeconds: TimeInterval, isPaused: Bool) {
        guard let activity = appState.categoryActivity(for: faceID) else { return }
        currentActivity = activity
        appState.currentFaceID = faceID
        appState.isPaused = isPaused
        self.isPaused = isPaused
        if isPaused {
            // While paused the device reports the pause segment's span; nothing reads
            // currentSegmentElapsed in this state (currentDuration() returns base only).
            currentSegmentElapsed = elapsedSeconds
            activityStartDate = nil
        } else {
            currentSegmentElapsed = elapsedSeconds
            activityStartDate = Date().addingTimeInterval(-elapsedSeconds)
        }
        logger.debug("apply_elapsed face=\(faceID, privacy: .public) paused=\(isPaused) elapsed=\(elapsedSeconds)")
        updateStatusView(force: true)
        rebuildMenu()
        startRefreshTimer()
    }

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.cell?.truncatesLastVisibleLine = true
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp])
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemClockChange),
            name: .NSSystemClockDidChange,
            object: nil
        )
        syncActivityFromState(resetDuration: false)
        // @Published publishes in willSet, so the new value has to be passed through rather than
        // read back off appState -- hence the override parameter.
        appState.$faceCategories
            .sink { [weak self] categories in
                self?.syncActivityFromState(faceCategoriesOverride: categories)
            }
            .store(in: &cancellables)
        // Unpairing is the only pairing change the menu bar has to act on by itself: it clears the
        // activity and drops to the unpaired look. Becoming paired shows nothing new on its own --
        // there is no activity to display until the device is actually reached, which arrives as a
        // `.connected` status below.
        appState.$isPaired
            .sink { [weak self] isPaired in
                guard let self else { return }
                self.isPairedSnapshot = isPaired
                self.logger.debug("pairing changed isPaired=\(isPaired)")
                if isPaired {
                    self.rebuildMenu()
                } else {
                    self.tearDownToUnpaired()
                }
            }
            .store(in: &cancellables)
        appState.$connectionStatus
            .sink { [weak self] status in
                self?.handleConnectionStatusChange(status)
            }
            .store(in: &cancellables)
        appState.$isManualMode
            .sink { [weak self] isManualMode in
                self?.isManualModeSnapshot = isManualMode
            }
            .store(in: &cancellables)
        appState.$dailyCategoryDurations
            .sink { [weak self] durations in
                self?.updateStatusView(dailyCategoryDurationsOverride: durations)
            }
            .store(in: &cancellables)
        appState.$dailyWindowStart
            .sink { [weak self] windowStart in
                self?.updateStatusView(force: true, dailyWindowStartOverride: windowStart)
            }
            .store(in: &cancellables)
        appState.$batteryLevel
            .sink { [weak self] level in
                guard let self else { return }
                let isLow = self.updatedLowBatteryLatch(currentLevel: level)
                DeveloperMode.debugPrint(
                    .battery,
                    "level=\(level.map(String.init) ?? "nil") threshold=\(self.lowBatteryThresholdPercent) recoveryAt=\(self.lowBatteryThresholdPercent + Constants.lowBatteryRecoveryMarginPercent) isLowBattery=\(isLow)"
                )
                self.updateStatusView(force: true)
            }
            .store(in: &cancellables)
        appState.$isLocked
            .sink { [weak self] _ in
                // Rebuilds the menu (not just the status view) so the Pause/Resume item's
                // enabled state stays in sync with the lock — see rebuildMenu().
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
        rebuildMenu()
        startRefreshTimer()

        logger.notice("Menu bar item created with mock activities")
    }
    @MainActor
    deinit {
        NotificationCenter.default.removeObserver(self)
        refreshTimer?.invalidate()
        lowBatteryBlinkTimer?.invalidate()
    }

    private func rebuildMenu() {
        let newMenu = NSMenu()
        // NSMenu auto-enables items with a target/action by default, which would silently
        // override pauseItem.isEnabled below — opt out so the Pause item actually disables.
        newMenu.autoenablesItems = false
        // Pause/Lock send commands to the device, so they need a live connection, not merely a
        // remembered pairing.
        let isConnected = isPairedSnapshot && connectionStatusSnapshot == .connected
        let isLocked = appState.isLocked

        // Menu items point at thin logging wrappers (menuSettings/menuPauseResume/...) rather
        // than the shared handlers directly, so a dropdown selection is logged as a menu click
        // (tag `menu`) distinctly from the status-item click gesture, which already logs `click`.
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(menuSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        newMenu.addItem(settingsItem)

        newMenu.addItem(.separator())

        let pauseTitle = isConnected ? (isPaused ? "Resume" : "Pause") : "Pause"
        let pauseItem = NSMenuItem(
            title: pauseTitle,
            action: #selector(menuPauseResume),
            keyEquivalent: ""
        )
        pauseItem.target = self
        // While locked, the only valid action is double-clicking the status item to unlock —
        // pause/resume must not be reachable via the menu either.
        pauseItem.isEnabled = isConnected && !isLocked
        newMenu.addItem(pauseItem)

        let lockItem = NSMenuItem(
            title: isLocked ? "Unlock" : "Lock",
            action: #selector(menuLockUnlock),
            keyEquivalent: ""
        )
        lockItem.target = self
        lockItem.isEnabled = isConnected
        newMenu.addItem(lockItem)

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(menuQuit),
            keyEquivalent: ""
        )
        quitItem.target = self
        newMenu.addItem(quitItem)

        statusMenu = newMenu
        updateStatusView()
    }

    private func updateStatusView(
        force: Bool = false,
        dailyCategoryDurationsOverride: [Int: TimeInterval]? = nil,
        dailyWindowStartOverride: Date? = nil
    ) {
        if connectionStatusSnapshot == .pairing {
            applyConnectingStatus()
            return
        }
        // Nothing to show: either no device is paired, or one is but the app hasn't reached it yet
        // this session. Both get the plain placeholder rather than an "Idle 0:00" that looks like a
        // reading from a device. Once the device HAS been reached, a later drop keeps rendering the
        // last known activity (that's the point of `.reconnecting`), so this only suppresses the
        // never-reached case -- and a manual session is never that, having a reading by construction.
        guard MenuBarLiveDisplay.showsActivity(
            isPaired: isPairedSnapshot,
            hasReachedDeviceThisSession: hasReachedDeviceThisSession,
            isManualMode: isManualModeSnapshot
        ) else {
            applyNoLiveDeviceStatus()
            return
        }
        guard let button = statusItem?.button else { return }
        let activityLabel = currentActivity?.name ?? "Idle"
        let duration = formattedDuration(
            dailyCategoryDurationsOverride: dailyCategoryDurationsOverride,
            dailyWindowStartOverride: dailyWindowStartOverride
        )
        let iconName = currentActivity?.iconName
        // The limit rides along on the activity, which is resolved from the face's category --
        // so it can't disagree with the name and icon drawn beside it.
        let limitMinutes = currentActivity?.limitMinutes ?? 0
        let overLimit = limitMinutes > 0 && currentDuration(
            dailyCategoryDurationsOverride: dailyCategoryDurationsOverride,
            dailyWindowStartOverride: dailyWindowStartOverride
        ) >= Double(limitMinutes) * 60
        let isConnected = MenuBarLiveDisplay.rendersAsLive(
            isPaired: isPairedSnapshot,
            isConnected: connectionStatusSnapshot == .connected,
            isManualMode: isManualModeSnapshot
        )
        let isLowBattery = updatedLowBatteryLatch(currentLevel: appState.batteryLevel)
        // Must run before the early-return below so the blink timer starts/stops as soon as the
        // low-battery state changes, even on a call that isn't itself forced. Gated on isConnected
        // too -- disconnected always renders flat yellow (see makeStatusTitle), so there's nothing
        // for the blink to animate while the connection is down.
        updateLowBatteryBlinkTimer(isLowBattery: isLowBattery && isConnected)

        let isLocked = appState.isLocked
        let snapshot = StatusSnapshot(
            activityLabel: activityLabel,
            duration: duration,
            isPaused: isPaused,
            iconName: iconName,
            overLimit: overLimit,
            isConnected: isConnected,
            isLowBattery: isLowBattery,
            isLocked: isLocked
        )

        if !force, snapshot == lastSnapshot {
            return
        }

        logger.debug("status_update face=\(self.appState.currentFaceID, privacy: .public) paused=\(self.isPaused) start=\(self.activityStartDate?.timeIntervalSince1970 ?? -1) accum=\(self.currentSegmentElapsed) dur=\(self.currentDuration())")

        let iconSize = statusBarIconSize()
        let icon = resolvedIcon(named: iconName, pointSize: iconSize)
        // The "TEST"/"PROD" tag is pinned at the far left of the menu bar, which means the activity
        // icon can no longer be the button's own image (that would draw to the left of the title,
        // ahead of the tag). It rides as a leading attachment inside the title instead, so the order
        // reads DB, icon, category, pause/play, time.
        let dbBadge = databaseBadge()
        let titleKey = "\(dbBadge.text)|\(iconName ?? "")|\(activityLabel)|\(duration)|\(isPaused)|\(overLimit)|\(isConnected)|\(isLowBattery)|\(lowBatteryBlinkPhaseOn)|\(isLocked)"
        button.imagePosition = .noImage
        if button.image != nil {
            button.image = nil
        }
        let tooltip = connectionStatusSnapshot == .reconnecting ? "Reconnecting to TimeFlip…" : nil
        if button.toolTip != tooltip {
            button.toolTip = tooltip
        }
        if lastRenderedTitle != titleKey {
            button.attributedTitle = makeStatusTitle(
                databaseBadge: dbBadge,
                leadingIcon: icon,
                activityLabel: activityLabel,
                duration: duration,
                isPaused: isPaused,
                overLimit: overLimit,
                isConnected: isConnected,
                isLowBattery: isLowBattery,
                blinkPhaseOn: lowBatteryBlinkPhaseOn,
                isLocked: isLocked
            )
            lastRenderedTitle = titleKey
        }
        lastSnapshot = snapshot
    }

    /// Starts/stops the fast (0.5s) blink timer that alternates the category text between red and
    /// white while the battery is at or below `lowBatteryThresholdPercent` — deliberately faster
    /// than `refreshTimer`'s duration tick so it actually draws the eye. Idempotent: safe to call
    /// on every `updateStatusView` regardless of whether the low-battery state actually changed.
    private func updateLowBatteryBlinkTimer(isLowBattery: Bool) {
        guard isLowBattery else {
            lowBatteryBlinkTimer?.invalidate()
            lowBatteryBlinkTimer = nil
            lowBatteryBlinkPhaseOn = false
            appState.setLowBatteryBlinkState(isLowBattery: false, blinkPhaseOn: false)
            return
        }
        guard lowBatteryBlinkTimer == nil else { return }
        appState.setLowBatteryBlinkState(isLowBattery: true, blinkPhaseOn: lowBatteryBlinkPhaseOn)
        let timer = Timer(timeInterval: Constants.lowBatteryBlinkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lowBatteryBlinkPhaseOn.toggle()
                self.appState.setLowBatteryBlinkState(isLowBattery: true, blinkPhaseOn: self.lowBatteryBlinkPhaseOn)
                self.updateStatusView(force: true)
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        lowBatteryBlinkTimer = timer
    }

    /// Hysteresis (Schmitt trigger) around `lowBatteryThresholdPercent`: latches into the
    /// low-battery state once the reading drops to/below the threshold, and only clears it once
    /// the reading climbs back above `threshold + lowBatteryRecoveryMarginPercent`. Without this, a
    /// reading that wobbles right around the threshold (real battery percentages are noisy) would
    /// flip the blink on and off on every single read instead of staying latched until the battery
    /// has genuinely recovered.
    private func updatedLowBatteryLatch(currentLevel: UInt8?) -> Bool {
        isLowBatteryLatched = LowBatteryLatch.updated(
            latched: isLowBatteryLatched,
            currentLevel: currentLevel,
            threshold: lowBatteryThresholdPercent,
            recoveryMargin: Constants.lowBatteryRecoveryMarginPercent
        )
        return isLowBatteryLatched
    }

    /// The plain no-activity look: just the app name, no icon, no duration. Shown whenever there
    /// is no live device behind the numbers. The tooltip distinguishes the two ways that happens,
    /// since the fix differs -- pair a device, versus bring the paired one back in range.
    private func applyNoLiveDeviceStatus() {
        let title = AppIdentifiers.statusItemTitle
        guard let button = statusItem?.button else { return }
        // The database tag rides on the placeholder too. This is the state the app sits in before it
        // reaches a device, which is exactly when someone is most likely to be wondering which
        // database this launch opened, and it would be perverse for the answer to appear only once
        // timing had already started.
        let badge = databaseBadge()
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let text = NSMutableAttributedString(
            string: "\(badge.text) ",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small)), .foregroundColor: badge.color]
        )
        text.append(NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        button.image = nil
        button.imagePosition = .noImage
        button.title = title
        button.attributedTitle = text
        button.toolTip = "\(title) (\(isPairedSnapshot ? "Disconnected" : "Not paired"))"
        lastRenderedTitle = "\(badge.text)|\(title)"
        lastSnapshot = nil
    }

    private func applyConnectingStatus() {
        let title = "Connecting…"
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        button.title = title
        button.attributedTitle = NSAttributedString(string: title)
        button.toolTip = "Attempting to connect to TimeFlip"
        lastRenderedTitle = title
        lastSnapshot = nil
    }

    private func formattedDuration(
        dailyCategoryDurationsOverride: [Int: TimeInterval]? = nil,
        dailyWindowStartOverride: Date? = nil
    ) -> String {
        DurationFormat.hoursMinutesSeconds(
            currentDuration(
                dailyCategoryDurationsOverride: dailyCategoryDurationsOverride,
                dailyWindowStartOverride: dailyWindowStartOverride
            ),
            // A live, ticking value: truncate rather than round, so the displayed seconds are
            // never ahead of what has actually elapsed.
            rounding: .truncate,
            showingSeconds: displaySecondsEnabled
        )
    }

    /// The figure the menu bar draws, and the one the daily limit is tested against: the current
    /// **category's** tracked time today, plus the segment still running.
    ///
    /// Keyed off `currentActivity.categoryID`, not `appState.currentFaceID`. Two faces assigned the
    /// same category share its `daily_limit`, so their time has to add up to spend it -- keyed by
    /// face, 40 minutes on one and 40 on another never reached a 60-minute limit. Reading the key off
    /// the activity rather than resolving the face again also keeps this number in step with the name
    /// and limit drawn beside it, which came from that same record.
    ///
    /// No activity means no category to total, so the base is 0 -- the right answer for the "Idle"
    /// placeholder that renders in exactly that state.
    private func currentDuration(
        dailyCategoryDurationsOverride: [Int: TimeInterval]? = nil,
        dailyWindowStartOverride: Date? = nil
    ) -> TimeInterval {
        let durations = dailyCategoryDurationsOverride ?? appState.dailyCategoryDurations
        let base = currentActivity.flatMap { durations[$0.categoryID] } ?? 0
        // Paused time doesn't count toward active duration
        guard !isPaused else { return base }
        let windowStart = dailyWindowStartOverride ?? appState.dailyWindowStart
        let live = clampedCurrentSegmentElapsed(windowStart: windowStart)
        return base + max(0, live)
    }

    /// Elapsed seconds for the in-flight segment, clipped to today's window start.
    /// Only called while running (currentDuration() returns early when paused).
    private func clampedCurrentSegmentElapsed(windowStart: Date, now: Date = Date()) -> TimeInterval {
        guard let start = activityStartDate else { return 0 }
        let clampedStart = max(start, windowStart)
        return max(0, now.timeIntervalSince(clampedStart))
    }

    private func loadIcon(named name: String, pointSize: CGFloat? = nil) -> NSImage? {
        guard let icon = ActivityIconLoader.image(
            named: name,
            pointSize: pointSize ?? Constants.defaultIconPointSize
        ) else {
            logger.error("Missing icon \(name, privacy: .public)")
            return nil
        }
        return icon
    }

    private func setCurrentActivity(_ activity: Activity, resetDuration: Bool) {
        if resetDuration {
            if !isPaused {
                currentSegmentElapsed = 0
                activityStartDate = Date()
                isPaused = false
            } else {
                // Paused: keep elapsed snapshot and leave start nil.
                activityStartDate = nil
            }
        }
        currentActivity = activity
        logger.notice("Selected activity \(activity.name, privacy: .public)")
        updateStatusView()
        startRefreshTimer()
    }

    @objc
    private func handleSystemClockChange() {
        logger.info("System clock changed; refreshing duration display")
        updateStatusView()
    }

    // Dropdown menu-item wrappers: log the click (tag `menu`), then run the shared handler. The
    // handlers stay reachable from the status-item gesture without logging a menu click there.
    @objc
    private func menuSettings() {
        DeveloperMode.debugPrint(.menu, "Menu clicked: Settings...")
        openPreferences()
    }

    @objc
    private func menuPauseResume(_ sender: NSMenuItem) {
        DeveloperMode.debugPrint(.menu, "Menu clicked: \(sender.title)")
        togglePause()
    }

    @objc
    private func menuLockUnlock(_ sender: NSMenuItem) {
        DeveloperMode.debugPrint(.menu, "Menu clicked: \(sender.title)")
        toggleLock()
    }

    @objc
    private func menuQuit() {
        DeveloperMode.debugPrint(.menu, "Menu clicked: Quit")
        quitApp()
    }

    @objc
    private func togglePause() {
        // While locked, the only valid action is double-clicking to unlock — pause/resume must
        // not be reachable from the menu or a single click on the status item.
        guard appState.isConnected, !appState.isLocked else { return }
        onPauseToggle?(!isPaused)
    }

    @objc
    private func toggleLock() {
        // Same read-then-flip request as the double-click gesture — see handleLockRequest() in
        // ApplicationDelegate, which reads the device's actual current lock state before deciding
        // whether to lock or unlock.
        guard appState.isConnected else { return }
        onLockRequest?()
    }

    /// Splits the status item into two click zones, but only once the device is actually
    /// paired: the left side (icon + activity name) opens the dropdown menu as before -- unless
    /// the low-battery warning is active, in which case it jumps straight to Settings (Device
    /// tab, where the blinking Battery line lives) instead, skipping the menu entirely. The right
    /// side (duration/indicator) toggles pause/resume on a single click, or requests a device lock
    /// on a double-click, without opening anything. If the device has never connected (or can't
    /// connect), there's no pause/resume state to toggle, so any click just pops the menu. While
    /// locked, the single-click pause/resume toggle is a no-op (see togglePause) — the double-click
    /// unlock action is the only thing that does anything. Manual mode gives both halves the menu,
    /// including over a stale low-battery blink; see `MenuBarClickRouter`, which owns all of these.
    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        // No event to read a side from (a synthetic `performClick`, say): the menu is the safe
        // answer, since it is the one thing reachable in every state.
        guard let event = NSApp.currentEvent else {
            showMenu()
            return
        }
        let location = button.convert(event.locationInWindow, from: nil)
        let isLeftSide = location.x <= button.bounds.width / 2
        // The raw connected test, not `MenuBarLiveDisplay.rendersAsLive`: manual mode draws as live
        // because its reading is current, but pause and lock still have no device to reach, so for
        // clicks it takes the no-device answer.
        let action = MenuBarClickRouter.action(
            isConnected: isPairedSnapshot && connectionStatusSnapshot == .connected,
            isLowBatteryBlinking: lowBatteryBlinkTimer != nil,
            isLeftSide: isLeftSide,
            clickCount: event.clickCount
        )
        DeveloperMode.debugPrint(
            .click,
            "Status item clicked: side=\(isLeftSide ? "left" : "right") clickCount=\(event.clickCount)"
                + "\(isManualModeSnapshot ? " manualMode" : "") -> \(action)"
        )
        switch action {
        case .showMenu:
            showMenu()
        case .openSettings:
            openPreferences()
        case .lockDevice:
            // Upgrade to the double-click (lock) action instead of also firing the single-click
            // pause toggle that was scheduled on the first click of this pair.
            pendingSingleClickWorkItem?.cancel()
            pendingSingleClickWorkItem = nil
            onLockRequest?()
        case .togglePause:
            // Delayed by the system's double-click interval so a fast second click can still cancel
            // this and upgrade to the lock action above, instead of doing both.
            let workItem = DispatchWorkItem { [weak self] in
                self?.togglePause()
            }
            pendingSingleClickWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button, let menu = statusMenu else { return }
        statusItem?.menu = menu
        button.performClick(nil)
        // Detach immediately after so the next click goes back through our own handler
        // instead of AppKit's automatic (whole-button) menu presentation.
        statusItem?.menu = nil
    }

    /// Opens Settings, on the tab `SettingsTabRules` picks. Reached from the dropdown's
    /// "Settings..." item and from the status-item click, and the tab rule applies to both: the
    /// window lands where the app knows the user is heading regardless of which route got them
    /// there. A `nil` from the rule leaves whatever tab was last selected, which is the usual case.
    @objc
    private func openPreferences() {
        if let tab = SettingsTabRules.tabOnOpen(
            isManualMode: isManualModeSnapshot,
            isLowBatteryBlinking: lowBatteryBlinkTimer != nil
        ) {
            appState.pendingSettingsTab = tab
        }
        settingsWindowController.show()
    }

    @objc
    private func quitApp() {
        NSApplication.shared.terminate(self)
    }

    private func statusBarIconSize() -> CGFloat {
        // Use the system status bar thickness as a stable baseline to avoid runaway growth.
        let barHeight = NSStatusBar.system.thickness
        return max(Constants.minStatusBarIconSize, barHeight - Constants.statusBarIconVerticalInset)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()

        guard !isPaused, currentActivity != nil else {
            refreshTimer = nil
            return
        }

        let now = Date()
        let tickInterval = displaySecondsEnabled ? 1.0 : TimeConstants.secondsPerMinute
        let secondsToNextTick = tickInterval
            - now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: tickInterval)
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusView()
            }
        }
        timer.fireDate = now.addingTimeInterval(secondsToNextTick)
        timer.tolerance = displaySecondsEnabled ? 0 : TimeConstants.defaultTimerTolerance
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resolvedIcon(named name: String?, pointSize: CGFloat) -> NSImage? {
        guard let name else {
            cachedIcon = nil
            cachedIconName = nil
            cachedIconSize = 0
            return nil
        }

        if name == cachedIconName, pointSize == cachedIconSize, let icon = cachedIcon {
            return icon
        }

        let icon = loadIcon(named: name, pointSize: pointSize)
        cachedIcon = icon
        cachedIconName = name
        cachedIconSize = pointSize
        return icon
    }

    /// Applies a new low-battery threshold straight away, re-running the latch against the level
    /// already on hand so the warning starts or stops now rather than waiting for the next battery
    /// reading, which can be minutes away.
    func setLowBatteryThreshold(_ percent: Int) {
        guard percent != lowBatteryThresholdPercent else { return }
        lowBatteryThresholdPercent = percent
        // The latch is sticky by design, so a threshold move has to be able to clear it as well as
        // set it -- otherwise lowering the threshold would leave a stale warning blinking.
        isLowBatteryLatched = false
        refreshFromState()
    }

    /// Applies a change to the seconds preference straight away: the format changes on the next
    /// draw, and the refresh timer is re-armed because its interval and tolerance both follow this.
    func setDisplaySeconds(_ enabled: Bool) {
        guard enabled != displaySecondsEnabled else { return }
        displaySecondsEnabled = enabled
        updateStatusView()
        startRefreshTimer()
    }

    func refreshFromState() {
        syncActivityFromState(force: true)
    }

    private func syncActivityFromState(
        resetDuration: Bool = false,
        force: Bool = false,
        faceCategoriesOverride: [UInt8: CategoryRecord]? = nil
    ) {
        let faceID = appState.currentFaceID
        // The stored bound: what is being asked is which category the face on show carries, and in
        // manual mode that face is 13.
        guard TimeFlipConstants.isValidStoredFaceID(faceID) else { return }
        let categories = faceCategoriesOverride ?? appState.faceCategories
        guard let activity = appState.categoryActivity(for: faceID, in: categories) else {
            return
        }
        if !force, currentActivity == activity, !resetDuration {
            return
        }
        setCurrentActivity(activity, resetDuration: resetDuration && !isPaused)
    }

    /// The device is reachable: start showing what it's doing.
    private func showLiveActivity() {
        hasReachedDeviceThisSession = true
        // If we already have a hydrated activity/start, keep it.
        if currentActivity != nil, activityStartDate != nil {
            rebuildMenu()
            updateStatusView(force: true)
            return
        }
        syncActivityFromState(resetDuration: false)
        rebuildMenu()
    }

    /// Clears the displayed activity and drops the status item to its no-device look. Used both
    /// when the pairing goes away and when the connection does in a way that isn't worth showing
    /// stale data through (a failure, a reset) -- in either case there's nothing live behind the
    /// numbers, so the timer stops rather than keeping a duration ticking up against no device.
    private func tearDownToUnpaired() {
        hasReachedDeviceThisSession = false
        currentActivity = nil
        currentSegmentElapsed = 0
        activityStartDate = nil
        isPaused = true
        appState.isPaused = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        applyNoLiveDeviceStatus()
        rebuildMenu()
        updateStatusView(force: true)
    }

    private func handleConnectionStatusChange(_ status: ConnectionStatus) {
        connectionStatusSnapshot = status
        switch status {
        case .pairing:
            applyConnectingStatus()
        case .connected:
            showLiveActivity()
        case .reconnecting:
            // Transient disconnect on an already-paired device: leave currentActivity,
            // activityStartDate, and the refresh timer untouched so the last known activity/icon
            // stays on screen and keeps ticking through the outage — do NOT tear down. Rebuild just
            // to disable the Pause item (isConnected below requires
            // connectionStatusSnapshot == .connected) and refresh the tooltip.
            rebuildMenu()
            updateStatusView(force: true)
        case .disconnected, .failed, .resetting:
            // .resetting: a factory reset is underway and the device is going away.
            guard MenuBarLiveDisplay.tearsDownOnDisconnect(isManualMode: isManualModeSnapshot) else {
                // Manual mode reports `.disconnected` for the whole launch, truthfully -- there is
                // no cube. Tearing down on it would clear the session that status is describing.
                rebuildMenu()
                updateStatusView(force: true)
                return
            }
            tearDownToUnpaired()
        }
    }

    /// Leading tag naming which database this launch opened -- red "TEST" (attention) against the
    /// ordinary label colour for "PROD" -- so a test database can't be mistaken for the real one and
    /// real timings recorded into it.
    ///
    /// Shown on every run, not only in developer mode. Which database is open decides where every
    /// segment of the day lands, and the moment it is worth knowing is the moment you have forgotten
    /// which one you started under.
    ///
    /// `.labelColor` rather than the white this used while it was developer-only: white is only
    /// legible against a dark menu bar, and now that it shows in every run it has to read in light
    /// appearance too.
    private func databaseBadge() -> (text: String, color: NSColor) {
        let isTest = appState.dbType.lowercased() == "test"
        return isTest ? ("TEST", .systemRed) : ("PROD", .labelColor)
    }

    /// A copy of a template icon filled with `color`, for use as a text attachment inside the status
    /// title -- attachments draw the image's literal pixels (a template's black), so unlike a button
    /// image they don't pick up the button's white content tint on their own.
    private func tintedIcon(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func makeStatusTitle(
        databaseBadge: (text: String, color: NSColor),
        leadingIcon: NSImage? = nil,
        activityLabel: String,
        duration: String,
        isPaused: Bool,
        overLimit: Bool,
        isConnected: Bool,
        isLowBattery: Bool,
        blinkPhaseOn: Bool,
        isLocked: Bool
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let style = MenuBarStatusStyle.make(
            isConnected: isConnected,
            isPaused: isPaused,
            overLimit: overLimit,
            isLowBattery: isLowBattery,
            blinkPhaseOn: blinkPhaseOn,
            isLocked: isLocked
        )
        let steadyColor = style.steadyColor
        let categoryColor = style.categoryColor
        let categoryAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: categoryColor]
        let steadyAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: steadyColor]
        let text = NSMutableAttributedString()

        let indicatorSize = max(Constants.minIndicatorAttachmentSize, font.capHeight * Constants.indicatorScale)

        // The DB tag, then (since it displaces the button's own image) the activity icon, both ahead
        // of the category label -- see updateStatusView. The icon rides at the same height as the
        // pause/play glyph so it can't outgrow the menu bar and clip, and takes `.labelColor` for
        // the same reason the tag does: an attachment draws its own pixels rather than picking up
        // the button's tint, so a hardcoded white would vanish in light appearance.
        let badgeFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))
        let badgeAttributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: databaseBadge.color]
        text.append(NSAttributedString(string: "\(databaseBadge.text) ", attributes: badgeAttributes))
        if let leadingIcon {
            let attachment = NSTextAttachment()
            attachment.image = tintedIcon(leadingIcon, color: .labelColor)
            attachment.bounds = NSRect(x: 0, y: font.descender, width: indicatorSize, height: indicatorSize)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: steadyAttributes))
        }

        text.append(NSAttributedString(string: "\(activityLabel) ", attributes: categoryAttributes))

        // Lock badge sits to the left of the pause/play indicator, not in place of it, so whether
        // the device is still timing or paused stays visible even while locked.
        if style.showsLockBadge, let lockIndicator = lockIndicatorImage(pointSize: indicatorSize) {
            let attachment = NSTextAttachment()
            attachment.image = lockIndicator
            attachment.bounds = NSRect(x: 0, y: font.descender, width: indicatorSize, height: indicatorSize)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: steadyAttributes))
        }

        if let indicator = statusIndicatorImage(isPaused: style.showsPauseIcon, pointSize: indicatorSize, overLimit: style.indicatorOverLimit) {
            let attachment = NSTextAttachment()
            attachment.image = indicator
            attachment.bounds = NSRect(x: 0, y: font.descender, width: indicatorSize, height: indicatorSize)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: steadyAttributes))
        }

        text.append(NSAttributedString(string: duration, attributes: steadyAttributes))
        return text
    }

    private func statusIndicatorImage(isPaused: Bool, pointSize: CGFloat, overLimit: Bool = false) -> NSImage? {
        let symbolName = isPaused ? "pause.fill" : "play.fill"
        let size = max(Constants.minIndicatorSymbolSize, pointSize)
        let baseConfig = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        let configuration: NSImage.SymbolConfiguration
        if overLimit {
            configuration = baseConfig.applying(.init(paletteColors: [.systemRed]))
        } else {
            configuration = baseConfig
        }
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// The red lock badge shown to the left of the pause/play indicator while the device is locked.
    private func lockIndicatorImage(pointSize: CGFloat) -> NSImage? {
        let size = max(Constants.minIndicatorSymbolSize, pointSize)
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(.init(paletteColors: [.systemRed]))
        guard let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(configuration) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        return image
    }

}

private struct StatusSnapshot: Equatable {
    let activityLabel: String
    let duration: String
    let isPaused: Bool
    let iconName: String?
    let overLimit: Bool
    let isConnected: Bool
    let isLowBattery: Bool
    let isLocked: Bool
}

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
    /// The hard `daily_limit`: what has been spent, what that means for the cube's pause state, and
    /// whether Resume is currently refused. See `DailyLimitEnforcement`, which holds every rule; this
    /// class only supplies it with the figures and sends what it asks for.
    private var dailyLimit = DailyLimitEnforcement()
    /// Fires at the second the category on show will spend its budget, so the pause goes out then
    /// rather than on the next display tick -- which is a minute wide when the seconds preference is
    /// off. Re-armed on every evaluation and invalidated whenever there is nothing to wait for.
    private var dailyLimitTimer: Timer?
    private var lowBatteryBlinkTimer: Timer?
    private var lowBatteryBlinkPhaseOn = false
    private var isLowBatteryLatched = false
    /// The spent/not-spent state the dropdown was last built against, so the Pause/Resume item is
    /// rebuilt when it changes and not on every tick. See `enforceDailyLimit`.
    private var lastDailyLimitReached = false
    /// Guards `enforceDailyLimit` against being re-entered from inside its own rebuild, which ends in
    /// `updateStatusView` and so leads straight back to it. Without it the crossing tick evaluates
    /// twice and sends the pause twice, the cube not yet having reported the first one.
    private var isEnforcingDailyLimit = false
    /// The cube's event number as it stood when a limit last sent a pause or a resume, or `nil` when
    /// nothing is outstanding. A write is only repeated once the device has reported a **different**
    /// event number, which is the whole cycle: read the counter, send, wait for the counter to move,
    /// then judge the event that moved it -- a pause means the write landed and nothing more is sent,
    /// anything else means it did not and the next evaluation sends again.
    ///
    /// It is what makes the repeat in `enforceDailyLimit` fire once per *answer* rather than once per
    /// evaluation: evaluation is the per-second tick plus every rebuild it triggers, while the answer
    /// is a BLE round trip and an ingest behind it, so the limit got several writes in before the
    /// first could possibly have been reported.
    ///
    /// Keyed on the event number rather than merely "a frame arrived", because a frame is not proof of
    /// a new event: the cheap-check path re-delivers the *same* live entry with a grown duration on
    /// every refresh (`HistoryIngestor`), and treating that as the answer would let a second write out
    /// while the first was still in flight.
    ///
    /// Compared for *inequality*, not for having grown. A factory reset restarts the counter from a
    /// low number, and waiting for it to exceed the pre-reset value would strand the latch set for the
    /// rest of the session, silently retiring the limit.
    ///
    /// That was believed to cost nothing, on the grounds that `0x06 0x01` is idempotent. **It is not,
    /// measured on real hardware 2026-08-12:** the cube mints a `device_event` per write, so one
    /// limit pause left four events (72's flip, then 73, 74, 75, 76 for four identical writes), all
    /// inside one second -- which then stranded the arrival row unfinalised, `finalised` being decided
    /// on whole seconds. See `docs/timeflip2-firmware-observations.md`.
    ///
    /// The self-healing this replaces is kept: an event that is not the pause means the write did not
    /// land, and the next evaluation sends it again, so a dropped write is still re-sent -- just once
    /// per event that proves it was needed.
    private var limitWriteSentAtEventNumber: UInt32?
    /// Whether that write is still outstanding. Held separately from the number rather than inferred
    /// from it being non-nil, because the number a write is sent at can legitimately *be* nil -- no
    /// frame has arrived yet -- and reading that as "nothing outstanding" would let every evaluation
    /// write, which is the storm this exists to stop. Cleared in `applyElapsed` the moment a frame
    /// reports a different event number.
    private var isLimitWriteOutstanding = false
    /// The event number on the most recent frame, `nil` before the first one (and in manual mode,
    /// where the virtual device has no cube counter and no limit is enforced anyway).
    private var lastReportedEventNumber: UInt32?
    private var lastSnapshot: StatusSnapshot?
    private var cachedIcon: NSImage?
    private var cachedIconName: String?
    private var cachedIconSize: CGFloat = 0
    private var lastRenderedTitle: String = ""
    private var isPairedSnapshot: Bool
    private var connectionStatusSnapshot: ConnectionStatus
    /// Whether the app is driving time itself rather than reading a cube. Read off the status
    /// snapshot rather than mirrored separately: manual mode *is* a connection status, so a second
    /// subscription would only give the two a way to arrive out of order.
    private var isManualMode: Bool { connectionStatusSnapshot == .manual }
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
    func applyElapsed(faceID: UInt8, elapsedSeconds: TimeInterval, isPaused: Bool, eventNumber: UInt32? = nil) {
        guard let activity = appState.categoryActivity(for: faceID) else { return }
        // Released before the evaluation below (`updateStatusView` -> `enforceDailyLimit`) reads it, so
        // a limit judges this frame rather than the one before it. A different number is the cube
        // saying "something happened since you wrote"; `isPaused`, carried on the same frame, is what
        // the evaluation then reads to decide whether that something was the pause landing. See
        // `limitWriteSentAtEventNumber`.
        if isLimitWriteOutstanding, eventNumber != limitWriteSentAtEventNumber {
            isLimitWriteOutstanding = false
        }
        lastReportedEventNumber = eventNumber
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
        dailyLimitTimer?.invalidate()
        lowBatteryBlinkTimer?.invalidate()
    }

    private func rebuildMenu() {
        let newMenu = NSMenu()
        // NSMenu auto-enables items with a target/action by default, which would silently
        // override pauseItem.isEnabled below — opt out so the Pause item actually disables.
        newMenu.autoenablesItems = false
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

        // Both items' titles and enabled states are `MenuBarDropdownRules`', which is also where the
        // reason Pause survives manual mode and Lock does not is written down.
        let pauseItem = NSMenuItem(
            title: MenuBarDropdownRules.pauseTitle(
                connectionStatus: connectionStatusSnapshot,
                isPaired: isPairedSnapshot,
                isPaused: isPaused
            ),
            action: #selector(menuPauseResume),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItem.isEnabled = MenuBarDropdownRules.allowsPause(
            connectionStatus: connectionStatusSnapshot,
            isPaired: isPairedSnapshot,
            isLocked: isLocked,
            isPaused: isPaused,
            isDailyLimitReached: dailyLimit.isReachedForCurrentCategory
        )
        newMenu.addItem(pauseItem)

        let lockItem = NSMenuItem(
            title: isLocked ? "Unlock" : "Lock",
            action: #selector(menuLockUnlock),
            keyEquivalent: ""
        )
        lockItem.target = self
        lockItem.isEnabled = MenuBarDropdownRules.allowsLock(
            connectionStatus: connectionStatusSnapshot,
            isPaired: isPairedSnapshot
        )
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
            connectionStatus: connectionStatusSnapshot
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
        // Evaluated here rather than beside the drawing, and before it, for the same reason the
        // low-battery latch is: this is the app's per-tick heartbeat, so it is the one place that
        // sees every change to the figures a limit is judged on. The red text and the pause then
        // come from a single evaluation in a single pass, and cannot report different states.
        let overLimit = enforceDailyLimit(
            limitMinutes: limitMinutes,
            dailyCategoryDurationsOverride: dailyCategoryDurationsOverride,
            dailyWindowStartOverride: dailyWindowStartOverride
        )
        let isConnected = MenuBarLiveDisplay.rendersAsLive(
            isPaired: isPairedSnapshot,
            connectionStatus: connectionStatusSnapshot
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
        // After the early return above, so this only fires when something actually changed rather
        // than once a second regardless.
        appState.setCurrentDurationText(duration)

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

    /// Measures the category on show against its `daily_limit`, sends whatever the cube needs, and
    /// returns whether the budget is spent (which is what the status item draws red).
    ///
    /// Every rule lives in `DailyLimitEnforcement`, including why a spent category stays spent for
    /// the day; this only supplies the figures, gates the sending on there being something to send
    /// to, and re-arms the timer that catches the next crossing.
    ///
    /// The pause and the resume both go out through `onPauseToggle`, the same callback the dropdown
    /// and the status item's right half use, so a limit's pause is the same pause in every respect:
    /// one `0x06` write, then the history refresh that closes the segment it stopped. Nothing here
    /// short-circuits to the device.
    ///
    /// The repeat while the cube is still reported running is kept, because the limit is hard: it keeps
    /// asking until a history frame says the cube stopped, so a dropped write cannot leave a spent
    /// category running until something else happens to come along. What changed is the **cadence** --
    /// once per frame rather than once per evaluation, see `limitWriteAwaitingFrame`. Repeating per
    /// evaluation was believed to be free (`0x06 0x01` idempotent, and the refresh behind it folding
    /// into whichever fetch is already running, see `HistoryIngestor.refreshHistory`); the cube's
    /// event counter says otherwise, one event per write. Two guards, two different jobs:
    /// `isEnforcingDailyLimit` stops a single pass asking twice, `limitWriteAwaitingFrame` stops
    /// successive passes asking before the first answer is in.
    @discardableResult
    private func enforceDailyLimit(
        limitMinutes: Int,
        dailyCategoryDurationsOverride: [Int: TimeInterval]? = nil,
        dailyWindowStartOverride: Date? = nil
    ) -> Bool {
        guard !isEnforcingDailyLimit else { return dailyLimit.isReachedForCurrentCategory }
        isEnforcingDailyLimit = true
        defer { isEnforcingDailyLimit = false }
        let totalSeconds = currentDuration(
            dailyCategoryDurationsOverride: dailyCategoryDurationsOverride,
            dailyWindowStartOverride: dailyWindowStartOverride
        )
        // Evaluated even when nothing can be sent (mid-reconnect, or a manual session), rather than
        // skipped: the return value draws the menu bar either way, and dropping an evaluation would
        // leave the latch behind the figures rather than in step with them. It is only the write
        // below that needs a live cube -- and evaluating again on the next pass re-decides, so an
        // action dropped here is re-issued as soon as there is a device to take it.
        let action = dailyLimit.evaluate(
            categoryID: currentActivity?.categoryID,
            limitMinutes: limitMinutes,
            totalSeconds: totalSeconds,
            isPaused: isPaused,
            windowStart: dailyWindowStartOverride ?? appState.dailyWindowStart
        )
        let isReached = dailyLimit.isReachedForCurrentCategory
        updateDailyLimitTimer(limitMinutes: limitMinutes, totalSeconds: totalSeconds, isReached: isReached)
        // Manual mode has no cube to pause, and its timer is the app's own; see
        // MenuBarDropdownRules.allowsPause for why a limit is not enforced against it at all.
        if !isManualMode, isPairedSnapshot, connectionStatusSnapshot == .connected {
            let name = currentActivity?.name ?? "Idle"
            switch action {
            case .none:
                break
            case .pause, .resume:
                let wantsPause = action == .pause
                // Decided above and logged either way, so the console still shows the limit holding
                // its position on every tick; only the write is held back until the cube reports a new
                // event. Logged as "waiting" rather than silently skipped, because a run that looks
                // like it asked once needs to be readable as such.
                let verb = wantsPause
                    ? "Limit reached, pausing device"
                    : "Budget on this face, resuming device"
                let held = isLimitWriteOutstanding
                    ? " (already sent at ev=\(limitWriteSentAtEventNumber.map(String.init) ?? "nil"), waiting for the next event)"
                    : ""
                DeveloperMode.debugPrint(
                    .dailyLimit,
                    "\(verb): category=\"\(name)\" limit=\(limitMinutes)m tracked=\(Int(totalSeconds))s\(held)"
                )
                if !isLimitWriteOutstanding {
                    isLimitWriteOutstanding = true
                    limitWriteSentAtEventNumber = lastReportedEventNumber
                    onPauseToggle?(wantsPause)
                }
            }
        }
        // The Pause/Resume item's enabled state follows this, and the dropdown is built once and
        // reused (see showMenu), so a change has to rebuild it rather than wait for the next thing
        // that happens to. Mostly the rebuild that follows a pause landing gets there first
        // (applyElapsed rebuilds on every reported change of pause state); this is what covers the
        // rest, a limit edited on the Categories tab while the cube already sits paused.
        if isReached != lastDailyLimitReached {
            lastDailyLimitReached = isReached
            rebuildMenu()
        }
        return isReached
    }

    /// Arms a one-shot timer for the exact second the category on show will spend its budget, so the
    /// pause is not left waiting on the display tick -- which is a whole minute wide when the seconds
    /// preference is off, and would make how far a hard limit overruns depend on a display setting.
    ///
    /// Nothing to wait for, so nothing armed, in each of the states where the figure cannot climb to
    /// a limit: no limit set, one already reached, or a paused cube, where the tracked total stands
    /// still by definition (`currentDuration` returns the recorded figure alone while paused).
    private func updateDailyLimitTimer(limitMinutes: Int, totalSeconds: TimeInterval, isReached: Bool) {
        dailyLimitTimer?.invalidate()
        dailyLimitTimer = nil
        guard !isReached, !isPaused, currentActivity != nil else { return }
        guard let seconds = DailyLimitEnforcement.secondsUntilReached(
            totalSeconds: totalSeconds,
            limitMinutes: limitMinutes
        ) else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // Straight back through the heartbeat rather than to the enforcement alone, so the
                // duration on screen turns red in the same pass that stops the cube.
                self?.updateStatusView()
            }
        }
        timer.tolerance = 0
        dailyLimitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        // No duration is on show, so nothing should be mirroring one to the Faces tab either.
        appState.setCurrentDurationText("")
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
        appState.setCurrentDurationText("")
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
        // Manual mode's timer is stopped and started through its own path, the one the Faces tab's
        // play/pause control uses, rather than through `onPauseToggle` -- that ends in a device
        // command, and the guard below would refuse it anyway, manual mode never being connected.
        // Same gesture, same effect, so the two controls cannot disagree about what pausing means.
        if isManualMode {
            appState.onManualTimingPauseToggle?()
            return
        }
        // While locked, the only valid action is double-clicking to unlock — pause/resume must
        // not be reachable from the menu or a single click on the status item.
        guard appState.isConnected, !appState.isLocked else { return }
        // The hard limit, and the whole of what makes it hard: the app declines to put the unpause
        // on the wire while the category on show has spent its `daily_limit`. Both gestures land
        // here -- the dropdown item and the status item's right half -- so refusing here refuses
        // both, and the dropdown disables its item as well so the refusal is visible rather than a
        // click that silently does nothing. Pausing is never refused, only resuming.
        if isPaused, dailyLimit.isReachedForCurrentCategory {
            DeveloperMode.debugPrint(
                .dailyLimit,
                "Resume refused, limit spent: category=\"\(currentActivity?.name ?? "Idle")\" limit=\(currentActivity?.limitMinutes ?? 0)m"
            )
            return
        }
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
    /// unlock action is the only thing that does anything. In manual mode the right half still
    /// pauses, immediately rather than after the double-click wait, and the left half keeps the menu
    /// even over a stale low-battery blink; see `MenuBarClickRouter`, which owns all of these.
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
        // The status itself rather than `MenuBarLiveDisplay.rendersAsLive`: the two want different
        // answers here. Manual mode draws as live, but lock has nothing to reach, so it cannot
        // simply borrow the connected case.
        let action = MenuBarClickRouter.action(
            connectionStatus: connectionStatusSnapshot,
            isPaired: isPairedSnapshot,
            isLowBatteryBlinking: lowBatteryBlinkTimer != nil,
            isLeftSide: isLeftSide,
            clickCount: event.clickCount
        )
        DeveloperMode.debugPrint(
            .click,
            "Status item clicked: side=\(isLeftSide ? "left" : "right") clickCount=\(event.clickCount)"
                + "\(isManualMode ? " manualMode" : "") -> \(action)"
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
        case .togglePauseImmediately:
            togglePause()
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
            isManualMode: isManualMode,
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
        case .manual:
            // A session the app itself is timing, so there is something to show and nothing to
            // reach. Rebuild so the menu's device actions go dead, redraw so the session appears --
            // the same pair `.reconnecting` does, and for the same reason: the display outlives the
            // connection. Deliberately not grouped with `.disconnected` below, which is what this
            // case used to be reported as and what made a teardown exception necessary.
            rebuildMenu()
            updateStatusView(force: true)
        case .disconnected, .failed, .resetting:
            // .resetting: a factory reset is underway and the device is going away.
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
        // pause/play glyph so it can't outgrow the menu bar and clip.
        //
        // It takes `categoryColor`, the colour of the name it sits directly against, so it carries
        // the same state the rest of the item does: yellow while the reading is stale, green when
        // live, red over limit, and the red/white low-battery blink. Two colours it must **not**
        // take, both tried: a hardcoded `.white`, which vanishes in a light menu bar, and
        // `.labelColor`, which is worse in a way that is easy to miss -- it follows the appearance
        // setting while the menu bar tints from the wallpaper, so a Light-appearance Mac with a dark
        // wallpaper draws a black icon on a dark strip. Matching the text beside it sidesteps the
        // question: whatever is legible for the category name is legible for its icon.
        let badgeFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))
        let badgeAttributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: databaseBadge.color]
        text.append(NSAttributedString(string: "\(databaseBadge.text) ", attributes: badgeAttributes))
        if let leadingIcon {
            let attachment = NSTextAttachment()
            attachment.image = tintedIcon(leadingIcon, color: categoryColor)
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

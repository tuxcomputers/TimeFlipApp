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
    private let displaySecondsEnabled: Bool
    private let lowBatteryThresholdPercent: Int
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
    private var pairingStatusSnapshot: PairingStatus

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
        self.pairingStatusSnapshot = appState.pairingStatus
        super.init()
    }

    /// Drive the timer from device-reported elapsed seconds (cmd 0x14).
    func applyElapsed(facetID: UInt8, elapsedSeconds: TimeInterval, isPaused: Bool) {
        guard let activity = appState.activity(for: facetID) else { return }
        currentActivity = activity
        appState.currentFacetID = facetID
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
        logger.debug("apply_elapsed facet=\(facetID, privacy: .public) paused=\(isPaused) elapsed=\(elapsedSeconds)")
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
        appState.$facetMappings
            .sink { [weak self] mappings in
                self?.syncActivityFromState(facetMappingsOverride: mappings)
            }
            .store(in: &cancellables)
        appState.$isPaired
            .sink { [weak self] isPaired in
                self?.handlePairingChange(isPaired)
            }
            .store(in: &cancellables)
        appState.$pairingStatus
            .sink { [weak self] status in
                self?.handlePairingStatusChange(status)
            }
            .store(in: &cancellables)
        appState.$dailyFacetDurations
            .sink { [weak self] durations in
                self?.updateStatusView(dailyFacetDurationsOverride: durations)
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
        let isPaired = isPairedSnapshot && pairingStatusSnapshot == .paired
        let isLocked = appState.isLocked

        let settingsItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        settingsItem.target = self
        newMenu.addItem(settingsItem)

        newMenu.addItem(.separator())

        let pauseTitle = isPaired ? (isPaused ? "Resume" : "Pause") : "Pause"
        let pauseItem = NSMenuItem(
            title: pauseTitle,
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        // While locked, the only valid action is double-clicking the status item to unlock —
        // pause/resume must not be reachable via the menu or its ⌘P shortcut either.
        pauseItem.isEnabled = isPaired && !isLocked
        newMenu.addItem(pauseItem)

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        newMenu.addItem(quitItem)

        statusMenu = newMenu
        updateStatusView()
    }

    private func updateStatusView(
        force: Bool = false,
        dailyFacetDurationsOverride: [UInt8: TimeInterval]? = nil,
        dailyWindowStartOverride: Date? = nil
    ) {
        if pairingStatusSnapshot == .pairing {
            applyConnectingStatus()
            return
        }
        if !isPairedSnapshot {
            applyUnpairedStatus()
            return
        }
        guard let button = statusItem?.button else { return }
        let activityLabel = currentActivity?.name ?? "Idle"
        let duration = formattedDuration(
            dailyFacetDurationsOverride: dailyFacetDurationsOverride,
            dailyWindowStartOverride: dailyWindowStartOverride
        )
        let iconName = currentActivity?.iconName
        let limitMinutes = appState.limitMinutes(for: appState.currentFacetID)
        let overLimit = limitMinutes > 0 && currentDuration(
            dailyFacetDurationsOverride: dailyFacetDurationsOverride,
            dailyWindowStartOverride: dailyWindowStartOverride
        ) >= Double(limitMinutes) * 60
        let isConnected = isPairedSnapshot && pairingStatusSnapshot == .paired
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

        logger.debug("status_update facet=\(self.appState.currentFacetID, privacy: .public) paused=\(self.isPaused) start=\(self.activityStartDate?.timeIntervalSince1970 ?? -1) accum=\(self.currentSegmentElapsed) dur=\(self.currentDuration())")

        let iconSize = statusBarIconSize()
        let icon = resolvedIcon(named: iconName, pointSize: iconSize)
        let titleKey = "\(activityLabel)|\(duration)|\(isPaused)|\(overLimit)|\(isConnected)|\(isLowBattery)|\(lowBatteryBlinkPhaseOn)|\(isLocked)"
        button.imagePosition = .imageLeft
        if button.image !== icon {
            button.image = icon
        }
        let tooltip = pairingStatusSnapshot == .reconnecting ? "Reconnecting to TimeFlip…" : nil
        if button.toolTip != tooltip {
            button.toolTip = tooltip
        }
        if lastRenderedTitle != titleKey {
            button.attributedTitle = makeStatusTitle(
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
            return
        }
        guard lowBatteryBlinkTimer == nil else { return }
        let timer = Timer(timeInterval: Constants.lowBatteryBlinkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lowBatteryBlinkPhaseOn.toggle()
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
        guard let currentLevel else { return isLowBatteryLatched }
        if isLowBatteryLatched {
            let recoveryLevel = lowBatteryThresholdPercent + Constants.lowBatteryRecoveryMarginPercent
            if currentLevel > recoveryLevel {
                isLowBatteryLatched = false
            }
        } else if currentLevel <= lowBatteryThresholdPercent {
            isLowBatteryLatched = true
        }
        return isLowBatteryLatched
    }

    private func applyUnpairedStatus() {
        let title = AppIdentifiers.statusItemTitle
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.imagePosition = .noImage
        button.title = title
        button.attributedTitle = NSAttributedString(string: title)
        button.toolTip = "\(title) (Not paired)"
        lastRenderedTitle = title
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
        dailyFacetDurationsOverride: [UInt8: TimeInterval]? = nil,
        dailyWindowStartOverride: Date? = nil
    ) -> String {
        let totalSeconds = Int(currentDuration(
            dailyFacetDurationsOverride: dailyFacetDurationsOverride,
            dailyWindowStartOverride: dailyWindowStartOverride
        ))
        let hours = totalSeconds / Int(TimeConstants.secondsPerHour)
        let minutes = (totalSeconds % Int(TimeConstants.secondsPerHour)) / Int(TimeConstants.secondsPerMinute)
        // Hours are unpadded below 10 (e.g. "1:23") but keep two digits once double-digit (e.g. "12:23").
        if displaySecondsEnabled {
            let seconds = totalSeconds % Int(TimeConstants.secondsPerMinute)
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", hours, minutes)
    }

    private func currentDuration(
        dailyFacetDurationsOverride: [UInt8: TimeInterval]? = nil,
        dailyWindowStartOverride: Date? = nil
    ) -> TimeInterval {
        let durations = dailyFacetDurationsOverride ?? appState.dailyFacetDurations
        let base = durations[appState.currentFacetID] ?? 0
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

    @objc
    private func togglePause() {
        // While locked, the only valid action is double-clicking to unlock — pause/resume must
        // not be reachable from the menu, its ⌘P shortcut, or a single click on the status item.
        guard appState.isPaired, !appState.isLocked else { return }
        onPauseToggle?(!isPaused)
    }

    /// Splits the status item into two click zones, but only once the device is actually
    /// paired: the left side (icon + activity name) opens the dropdown menu as before; the right
    /// side (duration/indicator) toggles pause/resume on a single click, or requests a device lock
    /// on a double-click, without opening anything. If the device has never connected (or can't
    /// connect), there's no pause/resume state to toggle, so any click just pops the menu. While
    /// locked, the single-click pause/resume toggle is a no-op (see togglePause) — the double-click
    /// unlock action is the only thing that does anything.
    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let isPaired = isPairedSnapshot && pairingStatusSnapshot == .paired
        guard isPaired, let event = NSApp.currentEvent else {
            showMenu()
            return
        }
        let location = button.convert(event.locationInWindow, from: nil)
        guard location.x > button.bounds.width / 2 else {
            showMenu()
            return
        }
        if event.clickCount >= 2 {
            // Upgrade to the double-click (lock) action instead of also firing the single-click
            // pause toggle that was scheduled below on the first click of this pair.
            pendingSingleClickWorkItem?.cancel()
            pendingSingleClickWorkItem = nil
            onLockRequest?()
            return
        }
        // Single click: delay by the system's double-click interval so a fast second click can
        // still cancel this and upgrade to the lock action above, instead of doing both.
        let workItem = DispatchWorkItem { [weak self] in
            self?.togglePause()
        }
        pendingSingleClickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    private func showMenu() {
        guard let button = statusItem?.button, let menu = statusMenu else { return }
        statusItem?.menu = menu
        button.performClick(nil)
        // Detach immediately after so the next click goes back through our own handler
        // instead of AppKit's automatic (whole-button) menu presentation.
        statusItem?.menu = nil
    }

    @objc
    private func openPreferences() {
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

    func refreshFromState() {
        syncActivityFromState(force: true)
    }

    private func syncActivityFromState(
        resetDuration: Bool = false,
        force: Bool = false,
        facetMappingsOverride: [FacetMapping]? = nil
    ) {
        let facetID = appState.currentFacetID
        guard TimeFlipConstants.isValidFacetID(facetID) else { return }
        let mappings = facetMappingsOverride ?? appState.facetMappings
        guard let activity = AppState.activity(for: facetID, in: mappings) else { return }
        if !force, currentActivity == activity, !resetDuration {
            return
        }
        setCurrentActivity(activity, resetDuration: resetDuration && !isPaused)
    }

    private func handlePairingChange(_ isPaired: Bool) {
        isPairedSnapshot = isPaired
        logger.debug("handlePairingChange isPaired=\(isPaired)")
        if isPaired {
            // If we already have a hydrated activity/start, keep it.
            if currentActivity != nil, activityStartDate != nil {
                rebuildMenu()
                updateStatusView(force: true)
                return
            }
            syncActivityFromState(resetDuration: false)
            rebuildMenu()
        } else {
            currentActivity = nil
            currentSegmentElapsed = 0
            activityStartDate = nil
            isPaused = true
            appState.isPaused = true
            refreshTimer?.invalidate()
            refreshTimer = nil
            applyUnpairedStatus()
            rebuildMenu()
            updateStatusView(force: true)
        }
    }

    private func handlePairingStatusChange(_ status: PairingStatus) {
        pairingStatusSnapshot = status
        switch status {
        case .pairing:
            applyConnectingStatus()
        case .paired:
            handlePairingChange(true)
        case .reconnecting:
            // Transient disconnect on an already-paired device: leave currentActivity,
            // activityStartDate, and the refresh timer untouched so the last known activity/icon
            // stays on screen and keeps ticking through the outage — do NOT treat this like
            // handlePairingChange(false). Rebuild just to disable the Pause item (isPaired below
            // requires pairingStatusSnapshot == .paired) and refresh the tooltip.
            rebuildMenu()
            updateStatusView(force: true)
        case .notPaired, .failed:
            handlePairingChange(false)
        }
    }

    private func makeStatusTitle(
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
        // Disconnected means the app has no live read on the device any more, so both fields show
        // a flat "unknown" yellow -- not a stale over-limit/low-battery color left over from
        // before the drop, and not blinking (there's nothing to draw attention to that we can
        // still confirm). Only once actually connected do over-limit/low-battery apply, and low
        // battery always wins there regardless of paused/recording/locked/any combination.
        let steadyColor: NSColor
        let categoryColor: NSColor
        if !isConnected {
            steadyColor = .systemYellow
            categoryColor = .systemYellow
        } else {
            steadyColor = overLimit ? .systemRed : .systemGreen
            categoryColor = isLowBattery ? (blinkPhaseOn ? .systemRed : .white) : steadyColor
        }
        let categoryAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: categoryColor]
        let steadyAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: steadyColor]
        let text = NSMutableAttributedString(string: "\(activityLabel) ", attributes: categoryAttributes)

        let indicatorSize = max(Constants.minIndicatorAttachmentSize, font.capHeight * Constants.indicatorScale)

        // Lock badge sits to the left of the pause/play indicator, not in place of it, so whether
        // the device is still timing or paused stays visible even while locked.
        if isLocked, let lockIndicator = lockIndicatorImage(pointSize: indicatorSize) {
            let attachment = NSTextAttachment()
            attachment.image = lockIndicator
            attachment.bounds = NSRect(x: 0, y: font.descender, width: indicatorSize, height: indicatorSize)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: steadyAttributes))
        }

        if let indicator = statusIndicatorImage(isPaused: isPaused, pointSize: indicatorSize, overLimit: overLimit) {
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

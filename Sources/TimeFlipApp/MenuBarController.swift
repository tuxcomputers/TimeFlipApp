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
    }

    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "menu-bar")
    private let appState: AppState
    private let settingsWindowController: SettingsWindowController
    private let onPauseToggle: ((Bool) -> Void)?
    private var statusItem: NSStatusItem?
    private var menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    private var currentActivity: Activity?
    private var isPaused = false
    private var activityStartDate: Date?
    private var currentSegmentElapsed: TimeInterval = 0
    private var refreshTimer: Timer?
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
        onPauseToggle: ((Bool) -> Void)? = nil
    ) {
        self.appState = appState
        self.settingsWindowController = settingsWindowController
        self.onPauseToggle = onPauseToggle
        self.isPairedSnapshot = appState.isPaired
        self.pairingStatusSnapshot = appState.pairingStatus
        super.init()
    }

    /// Seed the timer UI from a persisted session snapshot so it resumes on launch.
    func seedTimer(facetID: UInt8, isPaused: Bool, startDate: Date?, accumulatedDuration: TimeInterval) {
        guard let activity = appState.activity(for: facetID) else { return }
        logger.debug("seed_timer facet=\(facetID, privacy: .public) paused=\(isPaused) start=\(startDate?.timeIntervalSince1970 ?? -1) accum=\(accumulatedDuration)")
        currentActivity = activity
        self.isPaused = isPaused
        activityStartDate = startDate
        self.currentSegmentElapsed = accumulatedDuration
        appState.currentFacetID = facetID
        appState.isPaused = isPaused
        updateStatusView(force: true)
    }

    /// Drive the timer from device-reported elapsed seconds (cmd 0x14).
    func applyElapsed(facetID: UInt8, elapsedSeconds: TimeInterval, isPaused: Bool) {
        guard let activity = appState.activity(for: facetID) else { return }
        currentActivity = activity
        appState.currentFacetID = facetID
        appState.isPaused = isPaused
        self.isPaused = isPaused
        if isPaused {
            // When paused, avoid adding device-reported elapsed (includes pause span).
            currentSegmentElapsed = 0
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
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemClockChange),
            name: .NSSystemClockDidChange,
            object: nil
        )
        syncActivityFromState(resetDuration: false)
        appState.$facetMappings
            .sink { [weak self] _ in
                self?.syncActivityFromState()
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
            .sink { [weak self] _ in
                self?.updateStatusView()
            }
            .store(in: &cancellables)
        appState.$dailyWindowStart
            .sink { [weak self] _ in
                self?.updateStatusView(force: true)
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
    }

    private func rebuildMenu() {
        let newMenu = NSMenu()
        let isPaired = isPairedSnapshot && pairingStatusSnapshot == .paired

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
        pauseItem.isEnabled = isPaired
        newMenu.addItem(pauseItem)

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        newMenu.addItem(quitItem)

        menu = newMenu
        statusItem?.menu = newMenu
        updateStatusView()
    }

    private func updateStatusView(force: Bool = false) {
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
        let duration = formattedDuration()
        let iconName = currentActivity?.iconName
        let limitMinutes = appState.limitMinutes(for: appState.currentFacetID)
        let overLimit = limitMinutes > 0 && currentDuration() >= Double(limitMinutes) * 60
        let snapshot = StatusSnapshot(
            activityLabel: activityLabel,
            duration: duration,
            isPaused: isPaused,
            iconName: iconName,
            overLimit: overLimit
        )

        if !force, snapshot == lastSnapshot {
            return
        }

        logger.debug("status_update facet=\(self.appState.currentFacetID, privacy: .public) paused=\(self.isPaused) start=\(self.activityStartDate?.timeIntervalSince1970 ?? -1) accum=\(self.currentSegmentElapsed) dur=\(self.currentDuration())")

        let iconSize = statusBarIconSize()
        let icon = resolvedIcon(named: iconName, pointSize: iconSize)
        let titleKey = "\(activityLabel)|\(duration)|\(isPaused)|\(overLimit)"
        button.imagePosition = .imageLeft
        if button.image !== icon {
            button.image = icon
        }
        if lastRenderedTitle != titleKey {
            button.attributedTitle = makeStatusTitle(
                activityLabel: activityLabel,
                duration: duration,
                isPaused: isPaused,
                overLimit: overLimit
            )
            lastRenderedTitle = titleKey
        }
        let statusLabel = isPaused ? "Paused" : "Running"
        button.toolTip = "TimeFlip mock: \(activityLabel) \(duration) (\(statusLabel))"
        lastSnapshot = snapshot
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

    private func formattedDuration() -> String {
        let totalSeconds = Int(currentDuration())
        let hours = totalSeconds / Int(TimeConstants.secondsPerHour)
        let minutes = (totalSeconds % Int(TimeConstants.secondsPerHour)) / Int(TimeConstants.secondsPerMinute)
        return String(format: "%02d:%02d", hours, minutes)
    }

    private func currentDuration() -> TimeInterval {
        let base = appState.dailyFacetDurations[appState.currentFacetID] ?? 0
        let windowStart = appState.dailyWindowStart
        let live = clampedCurrentSegmentElapsed(windowStart: windowStart)
        return base + max(0, live)
    }

    private func segmentElapsedNow() -> TimeInterval {
        if let start = activityStartDate {
            return max(0, Date().timeIntervalSince(start))
        }
        return currentSegmentElapsed
    }

    /// Elapsed seconds for the in-flight segment, clipped to today's window start.
    private func clampedCurrentSegmentElapsed(windowStart: Date, now: Date = Date()) -> TimeInterval {
        // If we have a concrete start date (running), use it.
        if let start = activityStartDate {
            let clampedStart = max(start, windowStart)
            return max(0, now.timeIntervalSince(clampedStart))
        }
        // Paused: infer start from reported elapsed.
        guard currentSegmentElapsed > 0 else { return 0 }
        let inferredStart = now.addingTimeInterval(-currentSegmentElapsed)
        let clampedStart = max(inferredStart, windowStart)
        return min(currentSegmentElapsed, max(0, now.timeIntervalSince(clampedStart)))
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
        guard appState.isPaired else { return }
        onPauseToggle?(!isPaused)
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
        let secondsToNextMinute = TimeConstants.secondsPerMinute
            - now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: TimeConstants.secondsPerMinute)
        let timer = Timer(timeInterval: TimeConstants.secondsPerMinute, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusView()
            }
        }
        timer.fireDate = now.addingTimeInterval(secondsToNextMinute)
        timer.tolerance = TimeConstants.defaultTimerTolerance
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

    private func syncActivityFromState(resetDuration: Bool = false, force: Bool = false) {
        let facetID = appState.currentFacetID
        guard TimeFlipConstants.isValidFacetID(facetID) else { return }
        guard let activity = appState.activity(for: facetID) else { return }
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
        case .notPaired, .failed:
            handlePairingChange(false)
        }
    }

    private func makeStatusTitle(
        activityLabel: String,
        duration: String,
        isPaused: Bool,
        overLimit: Bool
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let baseColor = overLimit ? NSColor.systemRed : NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: baseColor
        ]
        let text = NSMutableAttributedString(string: "\(activityLabel) ", attributes: attributes)

        let indicatorSize = max(Constants.minIndicatorAttachmentSize, font.capHeight * Constants.indicatorScale)
        if let indicator = statusIndicatorImage(isPaused: isPaused, pointSize: indicatorSize, overLimit: overLimit) {
            let attachment = NSTextAttachment()
            attachment.image = indicator
            attachment.bounds = NSRect(x: 0, y: font.descender, width: indicatorSize, height: indicatorSize)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: attributes))
        }

        text.append(NSAttributedString(string: duration, attributes: attributes))
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

}

private struct StatusSnapshot: Equatable {
    let activityLabel: String
    let duration: String
    let isPaused: Bool
    let iconName: String?
    let overLimit: Bool
}

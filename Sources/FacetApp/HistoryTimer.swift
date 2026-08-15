import Foundation

/// Asks for history on a repeating interval, and reads that interval from the database every time it fires.
///
/// **The interval is a question, not a value this holds.** It is read at `start()`, and read again at every
/// timeout, so a change to `fetch_history_interval_seconds` takes effect on the next tick with nothing having
/// to be told. The previous app built a repeating timer whose interval was fixed when it was armed, and the
/// settings field had to remember to re-arm it (`ApplicationDelegate.onFetchHistoryIntervalChange`); a second
/// path that has to know the timer exists is a path that can forget.
///
/// What "asking for history" means depends on where the time is coming from, and that is deliberately not
/// decided here. With a cube paired it is a fetch request over BLE; **in manual mode the timer is the whole
/// source** -- nothing is going to tell the app what it is doing, so the timeout is the moment the app reports
/// its own open segment. Either way the answer goes to `DeviceEventRecorder`, which decides what it means for
/// the rows.
@MainActor
final class HistoryTimer {
    /// The setting and the field inside it. Named here rather than at the call site so the string appears
    /// once.
    static let settingName = "fetch_history_interval_seconds"
    static let settingField = "seconds"

    /// Where the interval sits when the row is missing or holds something that is not a number, matching the
    /// seed in `database/011_setting.sql`. A named constant rather than a literal for the reason the previous
    /// app gave for its own: a bare number here is a copy of the seed with nothing linking the two together.
    ///
    /// Ten seconds is below `productionMinimumSeconds` on purpose. It is a developer's value -- fast polling
    /// makes history arrive quickly while working on it -- and a shipped build floors it, because a minute is
    /// as often as a safety net behind live events needs to run.
    static let defaultSeconds = 10

    /// The floor a build without the dev flag applies, and the ceiling every build does. An hour is the far
    /// end of useful for a safety net; the floor stops a hand-edited row turning the app into a poller.
    static let productionMinimumSeconds = 60
    static let maximumSeconds = 3_600

    /// The shortest interval a dev build will accept, which exists only so a `0` in the row cannot spin the
    /// timer as fast as the run loop will go.
    static let developerMinimumSeconds = 1

    private let settings: SettingStore
    private let debugLog: DebugLog?

    /// What to do when the interval elapses. The timer decides *when*, and nothing about *what*.
    private let onTimeout: @MainActor () -> Void

    /// Held in its own object so it can be invalidated when this goes away: a `@MainActor` class's `deinit`
    /// cannot touch the class's own non-Sendable properties. Same shape as `DebugLog.Connection` and
    /// `MenuBarController.StatusItemHolder`, for the same reason.
    private final class TimerHolder {
        var timer: Timer?

        deinit {
            timer?.invalidate()
        }
    }

    private let holder = TimerHolder()

    /// What the timer currently in flight was armed with, and `nil` while stopped. Reported so the re-arming
    /// can be asserted without waiting for a real interval to elapse.
    private(set) var scheduledSeconds: TimeInterval?

    init(settings: SettingStore, debugLog: DebugLog?, onTimeout: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.debugLog = debugLog
        self.onTimeout = onTimeout
    }

    /// Reads the interval and arms the first timeout.
    func start() {
        let seconds = currentInterval()
        debugLog?.record(.history, "History timer started, asking every \(Int(seconds))s")
        arm(after: seconds)
    }

    /// Stops asking. Nothing is remembered, so `start()` begins again from whatever the setting says then.
    func stop() {
        guard holder.timer != nil else { return }
        holder.timer?.invalidate()
        holder.timer = nil
        scheduledSeconds = nil
        debugLog?.record(.history, "History timer stopped")
    }

    /// The timeout itself: ask, then read the setting again and arm the next one.
    ///
    /// Internal so a test can take the place of the run loop. Asking comes first so the interval is measured
    /// from the end of the work rather than the start of it, which is what stops a slow fetch and a short
    /// interval overlapping.
    func fire() {
        onTimeout()

        let seconds = currentInterval()
        // Reported only when it moves. A line per tick would bury the rows somebody actually reads, and a
        // timeout that did exactly what the last one did is not news.
        if let previous = scheduledSeconds, previous != seconds {
            debugLog?.record(.history, "History interval changed, \(Int(previous))s -> \(Int(seconds))s")
        }
        arm(after: seconds)
    }

    /// One timeout, not a repeating one: the interval has to be re-read before the next, and a repeating timer
    /// would keep the interval it was created with.
    private func arm(after seconds: TimeInterval) {
        holder.timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fire()
            }
        }
        // A tenth of the interval, which lets the system group this with other wake-ups rather than waking the
        // machine for it alone. Nothing here needs to land on the second.
        timer.tolerance = seconds * 0.1
        // `.common` rather than `Timer.scheduledTimer`, which adds to `.default`: a status item's menu runs the
        // run loop in a tracking mode, so a default-mode timer stops firing for as long as the menu is open.
        // Copied from the previous app, where it was already the answer to this.
        RunLoop.main.add(timer, forMode: .common)
        holder.timer = timer
        scheduledSeconds = seconds
    }

    private func currentInterval() -> TimeInterval {
        Self.interval(
            fromSeconds: settings.integer(Self.settingName, field: Self.settingField),
            isDeveloperBuild: DeveloperMode.isEnabled
        )
    }

    /// How long to wait, from what the row says. Pure, so every bound can be asserted without a run loop.
    ///
    /// A missing or non-numeric value falls back rather than switching the timer off: with a cube paired, not
    /// asking for history means not recording time, which is a worse answer to a malformed row than using the
    /// value the schema seeds.
    static func interval(fromSeconds seconds: Int?, isDeveloperBuild: Bool) -> TimeInterval {
        let requested = seconds ?? defaultSeconds
        let floor = isDeveloperBuild ? developerMinimumSeconds : productionMinimumSeconds
        return TimeInterval(min(maximumSeconds, max(floor, requested)))
    }
}

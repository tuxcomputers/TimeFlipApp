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
package final class HistoryTimer {
    /// The setting and the field inside it. Named here rather than at the call site so the string appears
    /// once.
    static let settingName = "fetch_history_interval_seconds"
    static let settingField = "seconds"

    /// Where the interval sits when the row is missing or holds something that is not a number, matching the
    /// seed in `database/011_setting.sql`. A named constant rather than a literal for the reason the previous
    /// app gave for its own: a bare number here is a copy of the seed with nothing linking the two together.
    static let defaultSeconds = 10

    /// The bounds the row is held between. An hour is the far end of useful for a safety net behind the live face
    /// and pause events; a second is there only so a `0` in the row cannot spin the timer as fast as the run loop
    /// will go.
    ///
    /// **One floor, where there were two.** A minute was applied to any build without the developer flag and a
    /// second to a build with it, so the seeded 10 meant one thing on a developer's machine and another on
    /// everybody else's -- two cadences from one row, decided at compile time. What the app polls at is the row's
    /// answer, and how often that should be is a question about the seeded value rather than about which build this
    /// is: the App tab offers 1 to 60 minutes, so nothing but a hand-edit can reach below a minute anyway.
    static let minimumSeconds = 1
    static let maximumSeconds = 3_600

    private let settings: SettingStore
    private let debugLog: DebugLog?

    /// What to do when the interval elapses. The timer decides *when*, and nothing about *what*.
    private let onTimeout: @MainActor () -> Void

    /// Whether there is anything to follow at all, **asked of the database every time it matters**.
    ///
    /// This is what stops the timer while the app is paused, and it is deliberately a question rather than a flag the
    /// pause paths set. Pausing closes the open segment (`SettingsWindowController.togglePause`), so "is anything
    /// being timed" is already something the table answers; a `isPaused` field kept in step with it would be a second
    /// copy of one fact, which is the first rule in `CLAUDE.md`, and a pause path added later could forget to set it.
    /// The previous app had exactly that bug in this exact class: its interval lived in a timer armed once, and the
    /// settings field had to remember to re-arm it.
    ///
    /// **A connected cube keeps it running whatever the app's own rows say.** "Nothing is open in our table" and "the
    /// cube has nothing to tell us" are not the same question: while a cube is connected the timeout is a fetch, and
    /// somebody flipping it during a pause is exactly the event that would go unnoticed with the timer off. So the
    /// question `main.swift` passes in is the pair -- a segment open, *or* a cube to ask -- and only an app timing
    /// nothing with nothing to ask lets this stop.
    ///
    /// Injected rather than asked here because it is about what the timeout *is*, which is the one thing this class
    /// deliberately knows nothing about.
    private let hasSomethingToFollow: @MainActor () -> Bool

    private let scheduler: Scheduler

    /// The wake that is waiting, and `nil` while stopped.
    ///
    /// **The `TimerHolder` that used to sit here is gone with the port**, and what it bought is worth naming
    /// rather than quietly dropping. It existed so a `deinit` could invalidate the timer, a `@MainActor` class
    /// being unable to touch its own non-Sendable properties from one. What that actually saved is **a single
    /// wake-up**: the wake armed here never repeats and captures `self` weakly, so a `HistoryTimer` dropped with
    /// one outstanding gets one callback that finds nothing and is then finished. It was not preventing a leak.
    /// The two holders it was modelled on, `DebugLog.Connection` and `MenuBarController.StatusItemHolder`, hold a
    /// database handle and a status item, and both still need theirs.
    private var wake: ScheduledWake?

    /// What the timer currently in flight was armed with, and `nil` while stopped. Reported so the re-arming
    /// can be asserted without waiting for a real interval to elapse.
    private(set) var scheduledSeconds: TimeInterval?

    package init(
        settings: SettingStore,
        debugLog: DebugLog?,
        scheduler: Scheduler,
        hasSomethingToFollow: @escaping @MainActor () -> Bool = { true },
        onTimeout: @escaping @MainActor () -> Void
    ) {
        self.scheduler = scheduler
        self.settings = settings
        self.debugLog = debugLog
        self.hasSomethingToFollow = hasSomethingToFollow
        self.onTimeout = onTimeout
    }

    /// Reads the interval and arms the first timeout, **if there is anything to ask about**.
    package func start() {
        guard hasSomethingToFollow() else {
            debugLog?.record(.history, "History timer not started, nothing is being timed")
            return
        }
        let seconds = currentInterval()
        debugLog?.record(.history, "History timer started, asking every \(Int(seconds))s")
        arm(after: seconds)
    }

    /// Starts it again if it is not running, and does nothing if it is.
    ///
    /// For the moment something begins being timed. Called through `onTimingChanged`, which is the one funnel every
    /// path that changes what is being timed already goes through -- a second, parallel notification would be one more
    /// thing for a new path to forget.
    package func resumeIfStopped() {
        guard wake == nil else { return }
        start()
    }

    /// Stops asking. Nothing is remembered, so `start()` begins again from whatever the setting says then.
    func stop(because reason: String = "") {
        guard wake != nil else { return }
        wake?.cancel()
        wake = nil
        scheduledSeconds = nil
        debugLog?.record(.history, "History timer stopped\(reason.isEmpty ? "" : ", \(reason)")")
    }

    /// The timeout itself: ask, then read the setting again and arm the next one.
    ///
    /// **Private now that the clock is a port**: this was internal purely so a test could take the place of the
    /// run loop, and a test drives `Scheduler` instead. Asking comes first so the interval is measured from the
    /// end of the work rather than the start of it, which is what stops a slow fetch and a short interval
    /// overlapping.
    private func fire() {
        // Asked here rather than trusted from when the timer was armed: a pause during the interval is exactly the
        // case this exists for, and the answer at arming time would be the stale one.
        guard hasSomethingToFollow() else {
            stop(because: "nothing is being timed")
            return
        }
        // **Every tick, whether or not it changed anything.** A working timer is otherwise completely silent:
        // `DeviceEventRecorder.refreshOpenSegment` passes `logging: false`, so a tick that grows an open
        // segment's duration writes no row, and a tick with no open segment does not even reach the recorder.
        // That left "is the timer still running?" answerable only by watching `device_event.duration_seconds`
        // move, which is what this line exists to replace (asked for on 2026-08-15, after a 79-second gap in
        // `debug_log` turned out to be eight healthy ticks).
        //
        // The interval is on the line because the next tick is armed from a fresh read of the setting, so two
        // consecutive lines are what show a change taking effect.
        //
        // This is the one tag that logs on a timer, which is the case `DebugLog` warns needs a write queue
        // before it gets one. It stands because the floor is a second in a developer build and a minute in
        // any other, and one small insert at that rate is not worth a queue.
        debugLog?.record(.history, "History timer fired, asking on a \(Int(scheduledSeconds ?? 0))s interval")
        onTimeout()

        let seconds = currentInterval()
        if let previous = scheduledSeconds, previous != seconds {
            debugLog?.record(.history, "History interval changed, \(Int(previous))s -> \(Int(seconds))s")
        }
        arm(after: seconds)
    }

    /// One timeout, not a repeating one: the interval has to be re-read before the next, and a repeating timer
    /// would keep the interval it was created with.
    private func arm(after seconds: TimeInterval) {
        wake?.cancel()
        // `mayGroup`, because nothing on this arm needs to land on the second: a fetch that happens alongside
        // some other wake-up is a fetch that did not wake the machine on its own. What that means is the
        // platform's business, and on a Mac it is the timer tolerance this line used to set itself.
        wake = scheduler.wake(in: seconds, repeating: false, mayGroup: true) { [weak self] in
            self?.fire()
        }
        scheduledSeconds = seconds
    }

    private func currentInterval() -> TimeInterval {
        Self.interval(fromSeconds: settings.integer(Self.settingName, field: Self.settingField))
    }

    /// How long to wait, from what the row says. Pure, so every bound can be asserted without a run loop.
    ///
    /// A missing or non-numeric value falls back rather than switching the timer off: with a cube paired, not
    /// asking for history means not recording time, which is a worse answer to a malformed row than using the
    /// value the schema seeds.
    static func interval(fromSeconds seconds: Int?) -> TimeInterval {
        TimeInterval(min(maximumSeconds, max(minimumSeconds, seconds ?? defaultSeconds)))
    }
}

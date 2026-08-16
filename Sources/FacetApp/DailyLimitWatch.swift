import Foundation

/// Watches the clock against the category's `daily_limit`, and stops it when the budget is spent.
///
/// **`DailyLimitEnforcement` decides and this acts**, which is the split that lets the decision be tested without a
/// radio and lets this exist before there is one. What "stop it" means is handed in rather than known here: today
/// there is no cube, so manual mode's own pause path is what closes the open segment, and when a device arrives the
/// same `.pause` becomes `0x06 0x01` going out to it with nothing here changing.
///
/// **Everything is read at the moment it is needed**, per the first rule in `CLAUDE.md`. Each tick asks the readout
/// what is being timed, what it has recorded today, and what its limit is; nothing is held between ticks except the
/// enforcement's latch, which is not a copy of any row (see its own note).
///
/// **It only runs while something is being timed.** A stopped clock cannot cross a limit, so the tick stops itself
/// and the same funnel that restarts the history timer restarts this. That funnel is `onTimingChanged`, which every
/// path that starts timing already goes through -- so a new way to start the clock gets this for nothing rather than
/// having to remember it exists.
@MainActor
final class DailyLimitWatch {
    /// Once a second, which is what the menu bar already redraws at: a limit that took effect up to a minute late
    /// would be a hard limit in name only, and one measured against a figure the user cannot see ticking would be
    /// worse than that.
    static let intervalSeconds: TimeInterval = 1

    private let timing: () -> TimingReadout.Reading
    private let windowStart: (Date) -> Date
    private let debugLog: DebugLog?

    /// What stopping the clock means. In manual mode it is the app's own pause path; with a cube it will be the
    /// pause command going out to it.
    private let stopTiming: () -> Void

    /// The decision, and the only thing here that remembers anything.
    private var enforcement = DailyLimitEnforcement()

    /// Held in a class so the timer's closure can clear it without capturing `self` strongly, the same shape
    /// `HistoryTimer` uses.
    private var timer: Timer?

    /// Whether the category on show has spent its budget, **worked out now rather than as of the last tick**.
    ///
    /// **What every path that could start the clock again asks**, through `ManualTimerRules.isClickable`: the
    /// dropdown's Resume greys itself with it, the status item's right half becomes a no-op, the Faces tab's glyph
    /// greys, and `togglePause` refuses. Read rather than pushed, so none of them can be holding a stale copy.
    ///
    /// **It reads the readout on every ask, and that is the point.** The tick stands down the moment the clock stops,
    /// which is precisely what reaching a limit does to it -- so anything answered from the tick's last verdict would
    /// be answered from a tick that is never coming back, and a limit raised afterwards would go unnoticed for the
    /// rest of the launch. That was the bug run 15 found. A readout per ask is the same cost the menu bar already pays
    /// for `display_seconds`, on the same once-a-second draw.
    var isReached: Bool {
        let reading = timing()
        return enforcement.isReached(
            categoryID: reading.category?.id,
            limitMinutes: reading.category?.dailyLimitMinutes ?? 0,
            totalSeconds: reading.seconds,
            windowStart: windowStart(Date())
        )
    }

    init(
        timing: @escaping () -> TimingReadout.Reading,
        windowStart: @escaping (Date) -> Date,
        debugLog: DebugLog?,
        stopTiming: @escaping () -> Void
    ) {
        self.timing = timing
        self.windowStart = windowStart
        self.debugLog = debugLog
        self.stopTiming = stopTiming
    }

    /// Starts watching, if there is a running clock to watch.
    func start() {
        guard timer == nil else { return }
        guard timing().state == .running else { return }
        let timer = Timer(timeInterval: Self.intervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check()
            }
        }
        // `.common`, as the menu bar's own tick is: the default mode stops dead while a menu is tracking, and a
        // limit that could not land while somebody had the dropdown open would be a limit with a hole in it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Starts it again if it is not running, and does nothing if it is. What `onTimingChanged` calls.
    func resumeIfStopped() {
        guard timer == nil else { return }
        start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One evaluation. Internal so a test can take the place of the run loop.
    ///
    /// **The limit is read from the category the readout just returned**, not from a copy taken when the clock
    /// started: a limit edited on the Categories tab mid-session is answered on the next tick, which is what
    /// `DailyLimitEnforcement`'s latch stores the limit for.
    func check(at now: Date = Date()) {
        let reading = timing()
        let action = enforcement.evaluate(
            categoryID: reading.category?.id,
            limitMinutes: reading.category?.dailyLimitMinutes ?? 0,
            totalSeconds: reading.seconds,
            isPaused: reading.state != .running,
            windowStart: windowStart(now)
        )

        switch action {
        case .pause:
            debugLog?.record(
                .limit,
                "Daily limit reached: \"\(reading.category?.name ?? "nothing")\" has spent "
                    + "\(reading.category?.dailyLimitMinutes ?? 0)m, stopping the clock"
            )
            stopTiming()

        case .resume:
            // **Deliberately not acted on while the app is the clock.** With a cube, `.resume` sends `0x06 0x02`
            // and the cube carries on counting the face it is already resting on -- the user has done nothing and
            // nothing about their day changes. In manual mode there is no face resting anywhere: starting the
            // clock again would be the app recording time against a category nobody has come back to, and the
            // most likely moment for it is a limit raised on the Categories tab while somebody is elsewhere.
            //
            // So a stopped manual session stays stopped, and the user starts it. What raising the limit does buy
            // them is the refusal lifting, which is the half that matters: the Resume they click is live again.
            debugLog?.record(.limit, "Daily limit no longer reached, the clock can be started again")

        case .none:
            break
        }

        // Nothing running means nothing that can *cross* a limit, so the tick stands down rather than reading the
        // tables once a second to watch a clock that is not moving. `resumeIfStopped` is what brings it back.
        //
        // **It used to say "an answer that cannot change", and that was the bug.** The answer can change while the
        // clock is stopped, because the limit itself can be raised on the Categories tab -- and the state this stands
        // down into is exactly the one a spent limit produces. Nothing here notices that any more, and nothing needs
        // to: `isReached` is worked out when it is asked, and `setDailyLimit` calls `onTimingChanged` so the edit
        // itself is what redraws. What is genuinely lost is `.resume`, which cannot fire while the tick is down. In
        // manual mode that costs a log line, since `.resume` is deliberately not acted on (above). **With a cube it
        // would cost the pause being lifted**, so a device arriving here needs this stand-down revisited -- keeping
        // the tick alive while a limit is latched is the shape that fixes it.
        if reading.state != .running {
            stop()
        }
    }
}

/// What the menu bar should say now, whether it needs repainting, and whether the clock behind it should be
/// running.
///
/// **The third of the menu bar's three core pieces.** `StatusItemTitle` decides what the line is made of and
/// `StatusItemMenu` decides the dropdown; this is what sits around the first of them, and it used to be spread
/// through `MenuBarController.redraw`: the latch on the first complete cube reading, the decision to tick, the
/// comparison against what was last drawn, and the two rules about which `debug_log` rows a change writes. None
/// of that is AppKit, and a GTK indicator asking its label what to say wants exactly the same answers.
///
/// **Everything is read per call, which is `CLAUDE.md`'s first rule and here it is load-bearing four times over.**
/// The daily limit lands part way through a session, so a copy would go on drawing green through the one state
/// the colour exists to warn about. The low battery flash changes twice a second, so a copy would be frozen on
/// one of its two phases. The lock badge has to come off the moment the link goes, and the link going is not
/// something this type is told about. And `isManualMode` moves the instant somebody answers the cube-not-found
/// offer, so a copy would leave the line saying `Connecting…` at a cube that is plainly connected.
///
/// **The one thing it does remember is what it last reported**, which is not a copy of anything true: it is the
/// answer to "has this changed", and there is nowhere else that question could be asked from.
@MainActor
package final class StatusItemReadout {
    package struct Update {
        /// What the bar should say.
        package let title: StatusItemTitle
        /// Whether the once-a-second repaint should be running. **Decided on whether the figure moves, not on
        /// whether this app is the one measuring**: a followed cube leaves `timingState` idle for the whole
        /// session, so ticking on that meant the item stood still while a cube timed and jumped a whole history
        /// interval whenever a fetch redrew it. See `TimingReadout.Reading.isCounting`.
        package let isTicking: Bool
        /// Whether the title differs from the one last reported. False means there is nothing to repaint, which
        /// matters because this is asked every second for the life of the launch.
        package let hasChanged: Bool
    }

    /// What the line says with nothing being timed. The app's name, passed in rather than written here so the
    /// two platforms cannot come to call it different things.
    private let appLabel: String
    private let timing: () -> TimingReadout.Reading
    private let cube: () -> CubeReading
    private let showingSeconds: () -> Bool
    private let isLimitReached: () -> Bool
    private let lowBattery: () -> LowBatteryAlert
    private let isManualMode: () -> Bool
    private let debugLog: DebugLog?

    private var firstReading = CubeFirstReading()

    /// The last title reported as changed. `nil` until the first read, so the first is always a change.
    private var lastReported: StatusItemTitle?

    package init(
        appLabel: String,
        timing: @escaping () -> TimingReadout.Reading,
        cube: @escaping () -> CubeReading,
        showingSeconds: @escaping () -> Bool,
        isLimitReached: @escaping () -> Bool,
        lowBattery: @escaping () -> LowBatteryAlert,
        isManualMode: @escaping () -> Bool,
        debugLog: DebugLog?
    ) {
        self.appLabel = appLabel
        self.timing = timing
        self.cube = cube
        self.showingSeconds = showingSeconds
        self.isLimitReached = isLimitReached
        self.lowBattery = lowBattery
        self.isManualMode = isManualMode
        self.debugLog = debugLog
    }

    /// Reads everything and answers what to draw.
    ///
    /// **Writing the rows is part of reading**, rather than left to the caller, because which row a change
    /// deserves is a decision and the caller is a drawing surface. It also means the two platforms cannot
    /// record a colour change differently, and those rows are the only evidence a scripted check has.
    package func read() -> Update {
        let reading = timing()
        // **Offered every read and it latches on the first complete one.** The lock comes from `cube()` and the
        // face and pause from the reading, which is where each is already read, so this asks nothing extra of
        // the radio and cannot come to a different answer from the line it is deciding.
        let cubeNow = cube()
        firstReading.record(
            isCubeConnected: cubeNow.isCubeConnected,
            cubeFace: reading.cubeFace,
            cubePauseState: reading.cubePauseState,
            cubeLockState: cubeNow.cubeLockState
        )
        let title = StatusItemTitle.make(
            appLabel: appLabel,
            reading: reading,
            showingSeconds: showingSeconds(),
            isLimitReached: isLimitReached(),
            lowBattery: lowBattery(),
            cubeLockState: cubeNow.cubeLockState,
            isConnecting: firstReading.isConnecting(isManualMode: isManualMode())
        )
        let hasChanged = title != lastReported
        if hasChanged {
            record(title)
            lastReported = title
        }
        return Update(title: title, isTicking: reading.isCounting, hasChanged: hasChanged)
    }

    /// The two rows a changed line can be worth, and neither is written for an unchanged one.
    private func record(_ title: StatusItemTitle) {
        // **A row when the colour changes, and only then.** `DebugLog.record` notes that a tag logging on a
        // timer would need a write queue first, and this is read from one: the figure moves every second, so a
        // row per title would be a row per second for the life of the launch. A colour moves when the app
        // changes what it is doing, which is the rate the rest of the log is written at.
        //
        // **It is the only way the colours are visible at all.** The accessibility tree carries none, so
        // without the row a scripted check has nothing to read and the whole scheme could only be confirmed by
        // somebody looking at the menu bar and saying it seemed right.
        if title.colourDescription != lastReported?.colourDescription {
            debugLog?.record(.status, "Menu bar: \(title.colourDescription)")
        }
        // **A row of its own, because the colours cannot say this one.** A line reaching for the cube is drawn
        // entirely in the label colour, which is exactly what the idle line is drawn in, so the row above
        // reports the two identically. What tells them apart is the words, and this is a state worth being able
        // to confirm from the table: it is on screen only until a cube answers, which is no time at all to be
        // watching a menu bar.
        //
        // **Under `reaching` and never under `status`.** `expect_colours` reads the newest `status` row as what
        // the line is drawn in right now, so putting this there makes that read answer the wrong question,
        // which it did, failing `55-device-face` on run 167 against a menu bar that was correct.
        let wasConnecting = lastReported?.text == StatusItemTitle.connecting
        let isNowConnecting = title.text == StatusItemTitle.connecting
        if isNowConnecting != wasConnecting {
            debugLog?.record(
                .reaching,
                isNowConnecting
                    ? "The status item is reaching for the cube"
                    : "The status item has read the cube and stops reaching"
            )
        }
    }
}

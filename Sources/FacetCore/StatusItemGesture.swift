import Foundation

/// What a click on the status item does, from the side it landed on and how many clicks it was.
///
/// **The fourth and last of the menu bar's core pieces**, beside `StatusItemTitle`, `StatusItemMenu` and
/// `StatusItemReadout`. `StatusItemClickRouter` already decided *which* `StatusItemClick` a press means; this
/// is everything that was wrapped around that call and stayed on the platform side by accident: the row every
/// click writes, the dispatch to what each action ends in, and the pause that waits to see whether it was
/// really half of a double click.
///
/// **A gesture rather than a click**, which is the name it earns from that last part: a press on the right
/// half is not settled until the double-click interval has passed without a second one.
///
/// **What is genuinely the platform's is two facts and no decisions**: which side of the item was pressed, and
/// how many clicks arrived. Both are read from the event and handed in.
@MainActor
package final class StatusItemGesture {
    private let timing: () -> TimingReadout.Reading
    private let cube: () -> CubeReading
    private let isLimitReached: () -> Bool
    private let togglePause: () -> Void
    private let toggleCubePause: () -> Void
    private let toggleCubeLock: () -> Void
    private let showMenu: () -> Void
    private let scheduler: Scheduler
    /// **Read per click rather than held**, and it is the user's own setting: somebody who has slowed their
    /// double click down gets the same gesture rather than a pause firing under it. `NSEvent.doubleClickInterval`
    /// on a Mac; GTK settles the same question with `gtk-double-click-time`.
    private let doubleClickInterval: () -> TimeInterval
    private let debugLog: DebugLog?

    /// A cube pause arranged and not yet sent, waiting to find out whether a second click makes it a lock.
    private var pendingCubePause: ScheduledWake?

    package init(
        timing: @escaping () -> TimingReadout.Reading,
        cube: @escaping () -> CubeReading,
        isLimitReached: @escaping () -> Bool,
        togglePause: @escaping () -> Void,
        toggleCubePause: @escaping () -> Void,
        toggleCubeLock: @escaping () -> Void,
        showMenu: @escaping () -> Void,
        scheduler: Scheduler,
        doubleClickInterval: @escaping () -> TimeInterval,
        debugLog: DebugLog?
    ) {
        self.timing = timing
        self.cube = cube
        self.isLimitReached = isLimitReached
        self.togglePause = togglePause
        self.toggleCubePause = toggleCubePause
        self.toggleCubeLock = toggleCubeLock
        self.showMenu = showMenu
        self.scheduler = scheduler
        self.doubleClickInterval = doubleClickInterval
        self.debugLog = debugLog
    }

    /// One click, on the side it landed and with the count the platform reported.
    package func clicked(isLeftSide: Bool, clickCount: Int) {
        let reading = timing()
        // Read once and handed to both, so the routing and the row below cannot describe different cubes.
        let cubeNow = cube()
        let action = StatusItemClickRouter.action(
            isLeftSide: isLeftSide,
            timingState: reading.timingState,
            isCubeConnected: cubeNow.isCubeConnected,
            cubePauseState: cubeNow.cubePauseState,
            isLimitReached: isLimitReached(),
            clickCount: clickCount
        )
        // **Recorded whatever the outcome, including `ignore`.** A click that deliberately did nothing and a
        // click that never arrived look identical afterwards unless one of them left a row, and telling those
        // two apart is the difference between a routing bug and a missed hit. The state rides along because it
        // is what the right half's answer turns on.
        debugLog?.record(
            .click,
            "Status item clicked: side=\(isLeftSide ? "left" : "right") clicks=\(clickCount) "
                + "state=\(reading.timingState) -> \(action)"
        )
        perform(action)
    }

    /// A click that arrived with no side to read, which a synthetic press is.
    ///
    /// **The menu is the safe answer**, being the one thing reachable in every state and the only way out of
    /// the app. Guessing a side would sometimes send a command nobody asked for.
    package func clickedWithNoSide() {
        debugLog?.record(.click, "Status item clicked: no event, side unknown -> showMenu")
        showMenu()
    }

    private func perform(_ action: StatusItemClick) {
        switch action {
        case .showMenu:
            showMenu()
        case .togglePause:
            // **At once, unlike the cube's.** This is the app's own clock, which has no lock, so there is no
            // second gesture this might turn out to have been half of.
            togglePause()
        case .toggleCubePause:
            deferCubePause()
        case .toggleCubeLock:
            // **Upgrade, not addition.** The first click of this pair already arranged a pause; cancelling it
            // is what stops a double click pausing the cube *and* locking it.
            cancelPendingCubePause(because: "a second click made it a lock")
            toggleCubeLock()
        case .ignore:
            break
        }
    }

    /// Holds a cube pause back long enough for a second click to cancel it.
    ///
    /// The archive did exactly this and for exactly this reason, and it is the one piece of its click handling
    /// that had to come back the moment the right half grew a second meaning.
    private func deferCubePause() {
        cancelPendingCubePause(because: "a newer click replaced it")
        // **Not `mayGroup`.** This is a gesture somebody is in the middle of making: a wait the platform was
        // free to stretch would let a double click land as two separate things.
        pendingCubePause = scheduler.wake(in: doubleClickInterval()) { [weak self] in
            guard let self else { return }
            self.pendingCubePause = nil
            self.toggleCubePause()
        }
    }

    /// Drops a waiting cube pause, saying why. Silent when there was nothing waiting, which is the ordinary case.
    private func cancelPendingCubePause(because reason: String) {
        guard let pending = pendingCubePause else { return }
        pending.cancel()
        pendingCubePause = nil
        debugLog?.record(.click, "The waiting cube pause was dropped: \(reason)")
    }
}

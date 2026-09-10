/// The status item's dropdown, decided in full: which lines, what each says, whether it can be chosen, and what
/// choosing it does.
///
/// **The counterpart of `StatusItemTitle`.** That decides the line in the bar; this decides the menu that opens
/// off it. Neither knows what draws it, and between them they are the whole of what the menu bar means.
///
/// **Nothing here is remembered, and that is the point rather than a style.** `items()` is called as the menu is
/// opened and reads everything it needs then, so the menu cannot come to disagree with the Faces tab about what
/// is being timed, and a menu left open while the cube goes away is answered from what is true when the line is
/// actually chosen. Both are `CLAUDE.md`'s first rule.
///
/// **The Pause line's target is decided twice, deliberately.** Once to name the line and once when it is chosen.
/// It is the same call with the same inputs, so it is the same answer unless the world moved between the two,
/// which is exactly the case where acting on the older answer would be wrong.
///
/// **`choose` is `nil` for a line that cannot be chosen**, rather than a separate `isEnabled`. That is the shape
/// `FacetLinux.MenuBar.Item` already uses, where a `nil` action comes out insensitive, and it makes the two
/// impossible to disagree: there is no way to render an item that looks live and does nothing.
@MainActor
package struct StatusItemMenu {
    /// One line of the dropdown.
    package struct Item {
        package let title: String
        /// What a scripted check addresses it by. AppKit exposes it as `AXIdentifier`; on Linux the same string
        /// comes back through `com.canonical.dbusmenu`'s `GetLayout`.
        package let identifier: String
        /// What choosing it does, or `nil` for a line that is only telling you something.
        package let choose: (@MainActor () -> Void)?
        package let isSeparator: Bool

        package init(
            _ title: String,
            identifier: String,
            choose: (@MainActor () -> Void)? = nil
        ) {
            self.title = title
            self.identifier = identifier
            self.choose = choose
            self.isSeparator = false
        }

        private init(separator: Bool) {
            title = ""
            identifier = ""
            choose = nil
            isSeparator = separator
        }

        package static let separator = Item(separator: true)
    }

    /// What each part of the menu bar is called, for whatever addresses it from outside the app.
    ///
    /// **Shared rather than per platform**, so a scripted check written against one reads the same on the other.
    /// `statusItem` is the item itself rather than a line of the menu, and is here because it is the same
    /// question: what does the thing outside call this.
    package enum Identifier {
        package static let statusItem = "status-item"
        package static let settings = "open-settings"
        package static let togglePause = "toggle-pause"
        package static let toggleCubeLock = "toggle-cube-lock"
        package static let quit = "quit-app"
    }

    // **Plain closures rather than `@MainActor` ones**, though this type is `@MainActor` and every one of them
    // is called from the main actor. A `@MainActor` closure is implicitly `@Sendable`, and the callers hold
    // theirs as plain `() -> Void`; asking for the stricter type here would have made every call site in two
    // composition roots restate an isolation the type already carries.
    private let timing: () -> TimingReadout.Reading
    private let cube: () -> CubeReading
    private let isLimitReached: () -> Bool
    private let openSettings: () -> Void
    private let togglePause: () -> Void
    private let toggleCubePause: () -> Void
    private let toggleCubeLock: () -> Void
    /// **Injected rather than reached for**, which is the whole of why this file is core: `NSApp.terminate` on a
    /// Mac and `gtk_main_quit` under GTK are the same intention performed two ways.
    private let quit: () -> Void
    private let debugLog: DebugLog?

    package init(
        timing: @escaping () -> TimingReadout.Reading,
        cube: @escaping () -> CubeReading,
        isLimitReached: @escaping () -> Bool,
        openSettings: @escaping () -> Void,
        togglePause: @escaping () -> Void,
        toggleCubePause: @escaping () -> Void,
        toggleCubeLock: @escaping () -> Void,
        quit: @escaping () -> Void,
        debugLog: DebugLog?
    ) {
        self.timing = timing
        self.cube = cube
        self.isLimitReached = isLimitReached
        self.openSettings = openSettings
        self.togglePause = togglePause
        self.toggleCubePause = toggleCubePause
        self.toggleCubeLock = toggleCubeLock
        self.quit = quit
        self.debugLog = debugLog
    }

    /// The whole menu as it should be right now.
    ///
    /// The order is the decision this method makes on its own, and it is not arbitrary. Settings first, being an
    /// ordinary choice. Pause under it, because it acts on what Settings is showing. Lock under Pause, being the
    /// same kind of choice one step further: Pause stops the clock, Lock stops the cube. Quit last and behind a
    /// separator, away from anything ordinary, because it is the only way out of the app and should not sit
    /// adjacent to something somebody chooses routinely.
    package func items() -> [Item] {
        let reading = timing()
        let cubeNow = cube()
        return [
            settingsItem(),
            pauseItem(reading: reading, cubeNow: cubeNow),
            lockItem(cubeNow: cubeNow),
            .separator,
            quitItem(),
        ]
    }

    /// **A trailing ellipsis, the platform's way of saying a choice opens something rather than doing something.**
    /// No keyboard shortcut on this or any line here: a shortcut belongs to the app-wide menu an accessory app
    /// does not have, and one declared on a dropdown would work only while the dropdown was already open, which
    /// is not a shortcut.
    private func settingsItem() -> Item {
        Item("Settings…", identifier: Identifier.settings) {
            debugLog?.record(.menu, "Menu item clicked: Settings")
            openSettings()
        }
    }

    /// Pause, named for what it will actually stop and greyed when it would stop nothing.
    ///
    /// **The cube is asked as well as the app's own clock**, because this line acts on either: with no manual
    /// session running, Pause is the cube's, exactly as a single click on the right half is. It used to ask only
    /// about the app's own clock and so sat greyed above a status item that would happily pause the cube.
    ///
    /// Greyed while the category on show has spent its limit, which is what makes the limit hard rather than
    /// advisory, and greyed on a locked cube, which cannot be paused at all until it is unlocked.
    private func pauseItem(reading: TimingReadout.Reading, cubeNow: CubeReading) -> Item {
        let target = PauseMenuRules.target(
            timingState: reading.timingState,
            isCubeConnected: cubeNow.isCubeConnected,
            cubeLockState: cubeNow.cubeLockState,
            cubePauseState: cubeNow.cubePauseState,
            isLimitReached: isLimitReached()
        )
        let title = PauseMenuRules.title(
            for: target, timingState: reading.timingState, cubePauseState: cubeNow.cubePauseState
        )
        guard PauseMenuRules.isEnabled(target) else {
            return Item(title, identifier: Identifier.togglePause)
        }
        return Item(title, identifier: Identifier.togglePause) { choosePause() }
    }

    /// What Pause does, decided again at the moment it is chosen rather than remembered from when it was named.
    ///
    /// The menu may have been sitting open while the cube went away, and acting on what was true when it was
    /// drawn is the stale-copy fault this codebase keeps being bitten by.
    private func choosePause() {
        let reading = timing()
        let cubeNow = cube()
        let target = PauseMenuRules.target(
            timingState: reading.timingState,
            isCubeConnected: cubeNow.isCubeConnected,
            cubeLockState: cubeNow.cubeLockState,
            cubePauseState: cubeNow.cubePauseState,
            isLimitReached: isLimitReached()
        )
        // What it was called when it was chosen, which is what the person clicking it meant.
        debugLog?.record(
            .menu,
            "Menu item clicked: "
                + PauseMenuRules.title(
                    for: target, timingState: reading.timingState, cubePauseState: cubeNow.cubePauseState
                )
        )
        switch target {
        case .appClock:
            togglePause()
        case .cube:
            // **At once, not deferred.** A click on the right half of the item is held back because it might turn
            // out to be the first half of a double click that means lock; a menu line is chosen once and there is
            // no second gesture it could be part of.
            toggleCubePause()
        case .nothing:
            break
        }
    }

    /// Lock, which needs a cube to be worth offering at all.
    ///
    /// The title and whether it can be chosen are both asked at the moment the menu opens. What the cube is doing
    /// is the radio's answer and is only ever as fresh as the last question, but the alternative, a title pushed
    /// in when something changed, would be a copy of it that could be wrong with nothing to say so.
    private func lockItem(cubeNow: CubeReading) -> Item {
        let title = CubeLockRules.title(cubeLockState: cubeNow.cubeLockState)
        guard CubeLockRules.isEnabled(isCubeConnected: cubeNow.isCubeConnected) else {
            return Item(title, identifier: Identifier.toggleCubeLock)
        }
        return Item(title, identifier: Identifier.toggleCubeLock) {
            // Named from a fresh reading for the same reason Pause is, and it ends in the same closure the
            // status item's double click does: one way of locking, whichever gesture asked.
            debugLog?.record(
                .menu, "Menu item clicked: " + CubeLockRules.title(cubeLockState: cube().cubeLockState)
            )
            toggleCubeLock()
        }
    }

    private func quitItem() -> Item {
        Item("Quit", identifier: Identifier.quit) {
            // Before quitting, not after: there is no after.
            debugLog?.record(.menu, "Menu item clicked: Quit")
            quit()
        }
    }
}

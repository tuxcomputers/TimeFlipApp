import AppKit

/// The status item and its dropdown. Owns the AppKit; decides nothing (see `StatusItemClickRouter` for the
/// clicks, `StatusItemTitle` for what the item says, and `TimingReadout` for what is being timed).
///
/// At this point in the rebuild the menu holds Settings, Pause and Quit. The title is the database badge, then
/// the session -- icon, category, play/pause, the category's time today -- and the app's name in place of all
/// of it while nothing is being timed. Both grow as there is something to say and something to do.
/// Carries one value across a queue hop that the compiler cannot check for us.
private struct UncheckedSend<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
final class MenuBarController: NSObject {
    /// Holds the status item so it can be taken out of the menu bar when this controller goes away.
    ///
    /// Its own object because a `@MainActor` class's `deinit` cannot touch the class's own non-Sendable
    /// properties -- and the removal has to happen there. `NSStatusBar` retains what it is given, so without
    /// this a controller nobody kept would leave its item in the menu bar: still drawn, and dead, because the
    /// button's target is weak. A visible failure beats an invisible one, so the item leaves with its owner.
    private final class StatusItemHolder {
        var item: NSStatusItem?

        deinit {
            guard let item else { return }
            // Removed on the main actor, where AppKit wants it, with the item carried across as an unchecked
            // send: an `NSStatusItem` is not `Sendable`, and this is the one moment it has to cross -- nothing
            // else holds it by now, since this object dying is what brought us here.
            let carried = UncheckedSend(item)
            DispatchQueue.main.async {
                NSStatusBar.system.removeStatusItem(carried.value)
            }
        }
    }

    private let holder = StatusItemHolder()
    private var statusItem: NSStatusItem? {
        get { holder.item }
        set { holder.item = newValue }
    }

    private var statusMenu: NSMenu?

    /// The database tag drawn ahead of everything else, or `nil` for no tag at all. Fixed for the
    /// life of the launch, so it is stored rather than looked up per redraw.
    private let databaseBadge: DatabaseBadge?

    /// The app's own name, which is the whole title while nothing is being timed, and the tail of the spoken
    /// label the rest of the time.
    private static let appLabel = "Facet"

    private enum Layout {
        /// The attachments (the category's icon, the play/pause glyph) as a multiple of the type's cap height,
        /// with a floor. Both numbers are the previous app's, which drew this line for a year: a glyph the size
        /// of the letters beside it reads as punctuation rather than as a symbol, and the floor keeps it legible
        /// at the small type the menu bar uses.
        static let attachmentScale: CGFloat = 1.6
        static let minimumAttachmentSize: CGFloat = 14
        /// The breathing room either side of the title, inside the item.
        ///
        /// A measured string is the ink, and a status item is not drawn hard against its neighbours, so without this
        /// the last character sits on the edge of the background macOS draws behind the item. Matches what
        /// `variableLength` was giving before the width was set by hand.
        static let itemPadding: CGFloat = 12
    }

    /// Accessibility identifiers, which are how a script addresses these rather than by position.
    ///
    /// Every element gets one, from the first element onwards. Addressing by position is the
    /// alternative, and it means `checkbox 1` and `static text 5` -- which depend on the order the
    /// tree happens to come back in, and fail by finding the wrong element rather than by finding
    /// nothing. `AXIdentifier` is the attribute a UI script can match on directly, so these follow
    /// its kebab-case convention.
    enum Identifier {
        static let statusItem = "status-item"
        static let settings = "open-settings"
        static let togglePause = "toggle-pause"
        static let toggleCubeLock = "toggle-cube-lock"
        static let quit = "quit-app"
    }

    /// The cube as it stands, asked when the menu is about to be drawn. Two answers rather than one because they
    /// fail differently: there may be no cube at all, and there may be a cube nobody has asked yet.
    struct CubeReading: Equatable {
        let isConnected: Bool
        /// `nil` when the cube has not been asked, or would not answer. See `CubeLockRules.title`.
        let isLocked: Bool?
    }

    private let cube: () -> CubeReading

    /// Locks the cube, or starts it again -- whichever the item is offering. What that means in commands is
    /// `CubeLock`'s, not this class's.
    ///
    /// **The double click ends here too**, rather than in a second implementation that reads the cube's lock state
    /// for itself. One way of locking, whichever gesture asked for it.
    private let toggleCubeLock: () -> Void

    /// Stops the cube counting, or starts it again, without locking it. The single click on the right half.
    ///
    /// **Not `togglePause`**, and the two must not be folded together: that one is the app's own clock, this one is
    /// `0x06` going out to hardware. They are never both live -- the router picks one -- but naming them the same
    /// thing is how the previous app came to have a dropdown item and a status-item half that meant different things.
    private let toggleCubePause: () -> Void

    /// The pause a single click asked for, waiting to see whether a second click turns it into a lock.
    ///
    /// **The whole reason the cube's pause is deferred and the app's own is not.** AppKit sends the action for the
    /// first click of a pair with `clickCount == 1`, so without this a double click would pause the cube *and* lock
    /// it. Held for `NSEvent.doubleClickInterval`, which is the user's own setting rather than a number chosen here.
    private var pendingCubePause: DispatchWorkItem?

    /// What to do when Settings is chosen. A closure rather than a window this class owns: it draws
    /// the menu, it does not decide what the app's windows are.
    private let openSettings: () -> Void

    /// What is being timed right now, asked when the item is about to be drawn rather than pushed here when it
    /// changes. The item cannot be stale if it never remembers anything, which is the same reasoning the database
    /// rule rests on -- and it saves every state change having to know the menu bar exists.
    ///
    /// The dropdown asks the same closure as it opens, so the Pause item and the glyph above it cannot disagree.
    private let timing: () -> TimingReadout.Reading

    /// Whether the figure carries seconds, from `display_seconds` -- read per draw, like everything else.
    ///
    /// Asked here and not by the Faces tab because that is what the setting is about: its own description names
    /// the menu bar duration, this being the one place a duration is on show all day with no window open.
    private let showingSeconds: () -> Bool

    /// Stops the clock, or starts it again. **The same closure the on-screen control ends in**, not a second
    /// implementation of pausing.
    private let togglePause: () -> Void

    /// Whether the category on show has spent its `daily_limit`. **Asked as the menu is built and as a click is
    /// routed**, never held: the limit lands part way through a session, so a copy taken when the item was drawn
    /// would grey the wrong thing.
    private let isLimitReached: () -> Bool

    /// Whether the cube is flat, and which half of the flash is up. **Asked per draw like everything else here**, and
    /// what makes the draws happen is `LowBatteryWatch.onChanged`, which fires on every phase: this class owns no
    /// blink of its own, so the item and the Device tab's Battery row cannot come to flash out of step.
    private let lowBattery: () -> LowBatteryAlert

    /// `nil` in a build without the dev flag, which is the whole of how logging is switched off here.
    private let debugLog: DebugLog?

    /// What was last painted, so an unchanged title is not re-applied. **What was drawn, not what is true**: it is
    /// compared against a fresh reading every time and never read as an answer, which is what keeps it clear of the
    /// database rule. Without it the fixed one-second tick would re-lay-out the item every second even with
    /// `display_seconds` off, where the figure only changes once a minute.
    private var lastDrawn: StatusItemTitle?

    /// Repaints while the clock is running, and only then: with it stopped, nothing on the item can change until
    /// something the app itself did, and each of those redraws by hand.
    private var tick: Timer?

    init(
        databaseBadge: DatabaseBadge?,
        debugLog: DebugLog?,
        openSettings: @escaping () -> Void,
        timing: @escaping () -> TimingReadout.Reading = { .idle },
        showingSeconds: @escaping () -> Bool = { true },
        togglePause: @escaping () -> Void = {},
        isLimitReached: @escaping () -> Bool = { false },
        lowBattery: @escaping () -> LowBatteryAlert = { .none },
        cube: @escaping () -> CubeReading = { CubeReading(isConnected: false, isLocked: nil) },
        toggleCubeLock: @escaping () -> Void = {},
        toggleCubePause: @escaping () -> Void = {}
    ) {
        self.cube = cube
        self.toggleCubeLock = toggleCubeLock
        self.toggleCubePause = toggleCubePause
        self.databaseBadge = databaseBadge
        self.debugLog = debugLog
        self.openSettings = openSettings
        self.timing = timing
        self.showingSeconds = showingSeconds
        self.togglePause = togglePause
        self.isLimitReached = isLimitReached
        self.lowBattery = lowBattery
        super.init()
    }

    /// Creates the item and puts it in the menu bar.
    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A status item draws unbordered, and truncating rather than wrapping matters now that the title
        // is a live duration whose width changes on every tick. `variableLength` is what lets the
        // width move at all, which anything driving this by synthetic click has to account for: the
        // item's rect has to be re-read per click rather than cached.
        item.button?.isBordered = false
        item.button?.cell?.truncatesLastVisibleLine = true
        item.button?.setAccessibilityIdentifier(Identifier.statusItem)
        // Our own handler rather than `item.menu`, which would make AppKit present the menu for a
        // click anywhere on the item and take the left/right distinction away entirely. `showMenu`
        // below is how the menu still gets presented in AppKit's own way when we do want it.
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        statusItem = item
        statusMenu = makeMenu()
        redraw()
    }

    /// Reads the session and paints it, starting or stopping the tick to match.
    ///
    /// Called on every tick, and by hand the moment the app changes what is being timed -- a category picked, a
    /// pause. Waiting for the next tick instead would leave a click's own feedback up to a second behind it.
    func redraw() {
        let reading = timing()
        // **Decided from the reading, before there is anything to paint into.** The tick is about whether the figure
        // moves, which is a question about the session and not about the item -- and taking it first is what lets it
        // be asserted without putting a real status item in the menu bar of whoever is running the tests, the same
        // reason `makeTitle` and `width(of:)` are reachable.
        //
        // **On whether the figure moves, not on whether this app is the one measuring.** A followed cube leaves
        // `state` idle for the whole session, so ticking on that meant the item stood still while a cube timed and
        // jumped a whole history interval whenever a fetch redrew it. See `TimingReadout.Reading.isCounting`.
        if reading.isCounting {
            startTicking()
        } else {
            stopTicking()
        }
        guard let button = statusItem?.button else { return }
        let title = StatusItemTitle.make(
            appLabel: Self.appLabel,
            badgeDescription: databaseBadge?.spokenDescription,
            reading: reading,
            showingSeconds: showingSeconds(),
            // Asked per draw, like everything else here: the limit lands part way through a session, so a copy taken
            // when the item was built would go on drawing green through the one state the colour exists to warn about.
            isLimitReached: isLimitReached(),
            // Likewise per draw, and the reason is sharper still: this changes twice a second while it is up, so a
            // copy taken anywhere other than here would be a flash frozen on one of its two phases.
            lowBattery: lowBattery(),
            // The same answer the dropdown's Lock item reads. Asked per draw, though it can only change when the app
            // itself sends a command or reaches a cube: the badge has to come off the moment the link goes, and the
            // link going is not something this class is told about.
            isCubeLocked: cube().isLocked == true
        )
        if title != lastDrawn {
            let drawn = makeTitle(title)
            button.attributedTitle = drawn
            // **The item is measured and its width set on every change**, rather than left to `variableLength`.
            //
            // macOS 26 draws a rounded background behind each status item and sizes it from `NSStatusItem.length`.
            // Left to itself that length did not follow a title that grew: timing "1" and then switching to
            // "SCRIPTED 1 REACTIVATE" drew the longer text spilling out of a capsule still the width of the shorter
            // one. The text was right and its backdrop was a title behind (seen 2026-08-16).
            //
            // There is no way to turn that background off, so the only fix available is to make it the right size,
            // which means telling the item how wide it now is instead of hoping it notices.
            statusItem?.length = width(of: drawn)
            // A label as well as an identifier: the identifier is for scripts, the label is what VoiceOver reads,
            // and a button whose only name is its title reads as its title -- which is now a duration, and "0:07"
            // is not a description of anything.
            button.setAccessibilityLabel(title.spoken)
            lastDrawn = title
        }
    }

    /// Whether the once-a-second repaint is running. Internal so it can be asserted without waiting a second for a
    /// real one, which is the same reason `makeTitle` and `width(of:)` are.
    var isTicking: Bool { tick != nil }

    /// The status item's line: the database badge, the category's icon, its name, the play/pause glyph, and the
    /// time that category has today. The app's name alone while nothing is being timed.
    ///
    /// Attributed rather than a plain string because the badge carries its own colour and weight -- it is a tag,
    /// not part of the sentence -- and because the two images ride inside the text (see `StatusItemTitle` for why
    /// they cannot be the button's own image). Sized off `.small` rather than the menu bar's own font because of
    /// how much ends up on this one line, all of which has to fit beside everybody else's status items.
    ///
    /// Internal so the order can be asserted without putting a real item in the menu bar.
    func makeTitle(_ parts: StatusItemTitle) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        // One colour for the line and one for the category's name and icon, both `StatusItemTitle`'s to choose. The
        // two differ only while the cube is flat, which is when the name flashes and the figure beside it does not.
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: parts.colour]
        let named: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: parts.nameColour]
        let title = NSMutableAttributedString()
        if let databaseBadge {
            title.append(NSAttributedString(
                string: "\(databaseBadge.text) ",
                attributes: [.font: NSFont.boldSystemFont(ofSize: font.pointSize), .foregroundColor: databaseBadge.color]
            ))
        }
        let size = max(Layout.minimumAttachmentSize, font.capHeight * Layout.attachmentScale)
        // Both images take the colour of the text beside them, which is the previous app's rule: whatever is legible
        // for the category's name is legible for its icon, and the icon then carries the same state the rest of the
        // line does rather than saying something of its own.
        //
        // **Not the category's own colour**, which is what the Timing column draws its glyph in. That works there
        // because it sits on the window's white; here the strip behind it is the wallpaper's, and the palette in
        // `database/005_colour.sql` proves the problem rather than merely risking it: Navy `#000080` disappears
        // against a dark menu bar and Peach `#ffdab9` against a light one. The `white_lines` column exists because
        // half of these colours cannot be read against an arbitrary background.
        if let iconName = parts.iconName, let icon = ActivityIcon.image(named: iconName, pointSize: size) {
            title.append(attachment(of: icon, colour: parts.nameColour, size: size, font: font))
            title.append(NSAttributedString(string: " ", attributes: plain))
        }
        title.append(NSAttributedString(string: parts.text, attributes: named))
        // Before the play/pause glyph, and in red rather than the line's colour -- see `StatusItemTitle.lockGlyphName`
        // for why it sits beside that glyph instead of replacing it, and why this is the one image here that does not
        // take the colour of the text next to it.
        if let lockGlyphName = parts.lockGlyphName, let lock = symbol(named: lockGlyphName, size: size) {
            title.append(NSAttributedString(string: " ", attributes: plain))
            title.append(attachment(of: lock, colour: .systemRed, size: size, font: font))
        }
        if let glyphName = parts.glyphName, let glyph = symbol(named: glyphName, size: size) {
            title.append(NSAttributedString(string: " ", attributes: plain))
            title.append(attachment(of: glyph, colour: parts.colour, size: size, font: font))
        }
        if let duration = parts.duration {
            title.append(NSAttributedString(string: " \(duration)", attributes: plain))
        }
        return title
    }

    /// How wide the item has to be for this title.
    ///
    /// Rounded up rather than to the nearest point: half a point short truncates the last character, and half a point
    /// over is invisible. Internal so it can be asserted without putting a real item in the menu bar, which is the
    /// same reason `makeTitle` is.
    func width(of title: NSAttributedString) -> CGFloat {
        ceil(title.size().width) + Layout.itemPadding
    }

    /// One image sitting in the line of text, tinted and dropped to the type's baseline.
    ///
    /// **The tint is applied inside a drawing handler rather than baked into a bitmap here**, which is the fix for
    /// something the previous app measured and left a warning about: a dynamic colour -- `.labelColor`,
    /// `.systemGreen`, any of them -- resolves against whatever appearance is current *when it is set*, so painting
    /// it into an image at composition time freezes one of its two answers. The menu bar tints from the wallpaper
    /// rather than from the appearance setting, so a Light-appearance Mac with a dark wallpaper then drew a black
    /// icon on a dark strip. A handler re-runs each time the image is drawn, in the appearance it is being drawn
    /// into, so the colour follows the strip the way the text beside it does.
    private func attachment(of image: NSImage, colour: NSColor, size: CGFloat, font: NSFont) -> NSAttributedString {
        let drawn = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            image.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = drawn
        // Dropped by the descender, so a glyph taller than the letters hangs level with them rather than lifting
        // the whole line.
        attachment.bounds = NSRect(x: 0, y: font.descender, width: size, height: size)
        return NSAttributedString(attachment: attachment)
    }

    private func symbol(named name: String, size: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = true
        return image
    }

    private func startTicking() {
        guard tick == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.redraw()
            }
        }
        // `.common` rather than the default mode, which stops dead while a menu is tracking -- and the menu that
        // does it is this item's own, so the clock would freeze in exactly the second somebody is looking at it.
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// Internal for the same reason `isTicking` is: a test that starts the clock has to be able to put it down
    /// again, rather than leaving a timer on the run loop for the rest of the suite.
    func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    /// The dropdown. Internal so its shape can be asserted without putting a real status item in the menu
    /// bar, which is what `start()` does.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Trailing ellipsis, the platform's way of saying a choice opens something rather than doing
        // something. No ⌘, for the same reason Quit carries no ⌘Q, below.
        menu.addItem(item(title: "Settings…", identifier: Identifier.settings, action: #selector(menuSettings)))
        // Under Settings, because it acts on what Settings is showing. Its title and whether it can be
        // chosen at all are set when the menu opens, not here.
        menu.addItem(item(title: "Pause", identifier: Identifier.togglePause, action: #selector(menuTogglePause)))
        // Under Pause, because it is the same kind of choice one step further: Pause stops the clock, this stops the
        // cube. Its title and whether it can be chosen are set when the menu opens, like the item above it.
        menu.addItem(item(title: "Lock", identifier: Identifier.toggleCubeLock, action: #selector(menuToggleCubeLock)))
        // Quit sits under a separator, away from anything ordinary: it is the only way out of the app,
        // so it should not be adjacent to a choice somebody makes routinely.
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit", identifier: Identifier.quit, action: #selector(menuQuit)))
        // Off, because AppKit would otherwise decide each item's enabled state from whether its action can be
        // found -- which is always -- and overwrite what `refresh` sets.
        menu.autoenablesItems = false
        return menu
    }

    /// Names the Pause item and decides whether it can be chosen, from the state at that moment. Nothing has
    /// to tell the menu when the clock changes, because the menu never remembers.
    ///
    /// Called from `showMenu`, which is the only place a menu of ours is ever presented, rather than through
    /// `NSMenuDelegate`. A delegate is a **weak** reference, so wiring it makes the menu depend on somebody
    /// else keeping this object alive -- and when that fails the menu simply stops updating, with nothing to
    /// see. We are already the code that opens it, so there is no reason to be told.
    func refresh(_ menu: NSMenu) {
        if let pause = menu.items.first(where: { $0.identifier?.rawValue == Identifier.togglePause }) {
            let state = timing().state
            pause.title = ManualTimerRules.pauseMenuTitle(for: state)
            // **Greyed while the category on show has spent its limit**, which is what makes the limit hard rather
            // than advisory: the item still reads "Resume", because that is what it would do, and it will not do it.
            pause.isEnabled = ManualTimerRules.isClickable(state, isLimitReached: isLimitReached())
        }
        if let lock = menu.items.first(where: { $0.identifier?.rawValue == Identifier.toggleCubeLock }) {
            // Both asked at the moment the menu opens, like everything else here. What the cube is doing is the
            // radio's answer and it is only ever as fresh as the last question -- but the alternative, a title pushed
            // in when something changed, would be a copy of it that could be wrong with nothing to say so.
            let cube = self.cube()
            lock.title = CubeLockRules.title(isLocked: cube.isLocked)
            lock.isEnabled = CubeLockRules.isEnabled(isConnected: cube.isConnected)
        }
    }

    /// One menu item, targeted at this controller and named for a script.
    ///
    /// No key equivalent on any of these: a shortcut belongs to the app-wide menu an accessory app
    /// does not have, and one declared here would only work while the dropdown was already open --
    /// which is not a shortcut.
    ///
    /// Both identifiers are set, deliberately. `identifier` is AppKit's own and is what a menu item
    /// exposes as AXIdentifier; `setAccessibilityIdentifier` is the accessibility one. Which of the
    /// two actually surfaces is a question for the accessibility tree rather than the documentation,
    /// so both are set and the tree is what settles it.
    private func item(title: String, identifier: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        item.setAccessibilityIdentifier(identifier)
        return item
    }

    @objc
    private func handleClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        // No event to read a side from -- a synthetic `performClick`, say. The menu is the safe
        // answer, being the one thing reachable in every state, and the only way out of the app.
        guard let event = NSApp.currentEvent else {
            debugLog?.record(.click, "Status item clicked: no event, side unknown -> showMenu")
            showMenu()
            return
        }
        let location = button.convert(event.locationInWindow, from: nil)
        // `<=` so the exact midpoint counts as the left half, i.e. as the menu: of the two, it is the
        // one that cannot leave someone stuck.
        let isLeftSide = location.x <= button.bounds.width / 2
        let state = timing().state
        let action = StatusItemClickRouter.action(
            isLeftSide: isLeftSide,
            timing: state,
            isCubeConnected: cube().isConnected,
            isLimitReached: isLimitReached(),
            clickCount: event.clickCount
        )

        // Recorded whatever the outcome, including `ignore`. A click that deliberately did nothing and
        // a click that never arrived look identical afterwards unless one of them left a row -- and
        // telling those two apart is the difference between a routing bug and a missed hit. The state
        // rides along because it is what the right half's answer turns on.
        debugLog?.record(
            .click,
            "Status item clicked: side=\(isLeftSide ? "left" : "right") clicks=\(event.clickCount) "
                + "state=\(state) -> \(action)"
        )

        switch action {
        case .showMenu:
            showMenu()
        case .togglePause:
            // The same closure the dropdown's Pause item and the Timing column's control end in, so the three
            // ways to pause cannot come to mean different things. What it draws afterwards comes back here as a
            // `redraw()` (see `main.swift`), rather than this knowing what it changed.
            //
            // **At once, unlike the cube's.** This is manual mode, which has no lock, so there is no second
            // gesture the click might turn out to have been half of.
            togglePause()
        case .toggleCubePause:
            deferCubePause()
        case .toggleCubeLock:
            // **Upgrade, not addition.** The first click of this pair already scheduled a pause; cancelling it is
            // what stops a double click from pausing the cube *and* locking it.
            cancelPendingCubePause(because: "a second click made it a lock")
            // The same closure the dropdown's Lock item ends in. One way of locking, whichever gesture asked.
            toggleCubeLock()
        case .ignore:
            break
        }
    }

    /// Holds a cube pause back long enough for a second click to cancel it.
    ///
    /// **`NSEvent.doubleClickInterval` rather than a number chosen here**: it is the user's own setting, so somebody
    /// who has slowed their double click down gets the same gesture rather than a pause that fires under it.
    ///
    /// The archive did exactly this and for exactly this reason, and it is the one piece of its click handling that
    /// had to come back the moment the right half grew a second meaning.
    private func deferCubePause() {
        cancelPendingCubePause(because: "a newer click replaced it")
        let pending = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingCubePause = nil
                self.toggleCubePause()
            }
        }
        pendingCubePause = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: pending)
    }

    /// Drops a scheduled cube pause, saying why. Silent when there was nothing waiting, which is the ordinary case.
    private func cancelPendingCubePause(because reason: String) {
        guard let pending = pendingCubePause else { return }
        pending.cancel()
        pendingCubePause = nil
        debugLog?.record(.click, "The waiting cube pause was dropped: \(reason)")
    }

    /// Presents the dropdown by lending the item its menu for exactly one click.
    ///
    /// The assign/click/detach dance is what keeps the halves apart. Left assigned, `statusItem.menu`
    /// makes AppKit open the menu for any click on the item, and `handleClick` above never runs
    /// again -- so it is detached immediately, and the next click comes back to us.
    private func showMenu() {
        guard let button = statusItem?.button, let menu = statusMenu else { return }
        refresh(menu)
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc
    private func menuSettings() {
        debugLog?.record(.menu, "Menu item clicked: Settings")
        openSettings()
    }

    @objc
    private func menuTogglePause() {
        // What it was called when it was chosen, which is what the person clicking it meant.
        debugLog?.record(.menu, "Menu item clicked: \(ManualTimerRules.pauseMenuTitle(for: timing().state))")
        togglePause()
    }

    @objc
    private func menuToggleCubeLock() {
        // What it was called when it was chosen, which is what the person clicking it meant.
        let cube = self.cube()
        debugLog?.record(.menu, "Menu item clicked: \(CubeLockRules.title(isLocked: cube.isLocked))")
        toggleCubeLock()
    }

    @objc
    private func menuQuit() {
        // Before terminating, not after: there is no after.
        debugLog?.record(.menu, "Menu item clicked: Quit")
        NSApp.terminate(nil)
    }
}

import AppKit
import FacetCore

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

/// Carries a menu line's action on the `NSMenuItem` itself. `representedObject` is `Any?`, which a Swift
/// closure cannot be put in directly, so it travels boxed.
@MainActor
private final class MenuAction {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
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
    /// What each part of this is called from outside the app. `StatusItemMenu.Identifier` under its own name,
    /// so the call sites and the scripted checks go on reading the same, and so a Linux check addressing the
    /// dropdown over D-Bus uses the identical strings.
    typealias Identifier = StatusItemMenu.Identifier

    /// The cube as it stands. `FacetCore.CubeReading` under its own name, so the many call sites that spell it
    /// `MenuBarController.CubeReading` go on reading the same.
    typealias CubeReading = FacetCore.CubeReading

    private let cube: () -> CubeReading

    /// Whether this app is its own clock, asked per draw like everything else here. **Defaulted to `true`**, which is
    /// the answer that draws no `Connecting…`: an item built without being told has no cube to be reaching for, and a
    /// test that never mentions a cube should not have to say so to get the line it expects.
    private let isManualMode: () -> Bool

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

    /// What the dropdown should hold, which this controller asks and does not decide. Built in `init` from the
    /// same closures the title is drawn from, so the menu and the line in the bar cannot answer differently.
    private var dropdown: StatusItemMenu!

    /// What the line in the bar should say, which this controller also asks and does not decide.
    private var readout: StatusItemReadout!

    /// What a click means, which this controller reads two facts for and does not decide.
    private var click: StatusItemGesture!

    /// Repaints while the clock is running, and only then: with it stopped, nothing on the item can change until
    /// something the app itself did, and each of those redraws by hand.
    ///
    /// **Whether it should be running is `StatusItemReadout`'s answer**, not this class's. What is here is the
    /// wake itself, arranged through the injected `Scheduler` rather than a `Timer` built by hand, which is the
    /// last of the six `.common` decisions this app used to repeat at every timer site.
    private var tick: ScheduledWake?
    private let scheduler: Scheduler

    init(
        debugLog: DebugLog?,
        openSettings: @escaping () -> Void,
        timing: @escaping () -> TimingReadout.Reading = { .idle },
        showingSeconds: @escaping () -> Bool = { true },
        togglePause: @escaping () -> Void = {},
        isLimitReached: @escaping () -> Bool = { false },
        lowBattery: @escaping () -> LowBatteryAlert = { .none },
        cube: @escaping () -> CubeReading = { CubeReading(isCubeConnected: false, cubeLockState: .unknown, cubePauseState: .unknown) },
        toggleCubeLock: @escaping () -> Void = {},
        toggleCubePause: @escaping () -> Void = {},
        isManualMode: @escaping () -> Bool = { true },
        // **Defaulted for the same reason `radio` is**, and never reached for: a top-level `let` in `main.swift`
        // is a module global, so naming one here would compile and would then be touched by a test that never
        // runs `main` at all.
        scheduler: Scheduler = RunLoopScheduler()
    ) {
        self.scheduler = scheduler
        self.isManualMode = isManualMode
        self.cube = cube
        self.toggleCubeLock = toggleCubeLock
        self.toggleCubePause = toggleCubePause
        self.debugLog = debugLog
        self.openSettings = openSettings
        self.timing = timing
        self.showingSeconds = showingSeconds
        self.togglePause = togglePause
        self.isLimitReached = isLimitReached
        self.lowBattery = lowBattery
        super.init()
        // After `super.init()`, because the closures it is given capture `self`.
        dropdown = StatusItemMenu(
            timing: timing,
            cube: cube,
            isLimitReached: isLimitReached,
            openSettings: openSettings,
            togglePause: togglePause,
            toggleCubePause: toggleCubePause,
            toggleCubeLock: toggleCubeLock,
            // The one line of this menu that is AppKit, and the reason `StatusItemMenu` takes it rather than
            // calling it: `gtk_main_quit` is the same intention on the other platform.
            quit: { NSApp.terminate(nil) },
            debugLog: debugLog
        )
        readout = StatusItemReadout(
            appLabel: Self.appLabel,
            timing: timing,
            cube: cube,
            showingSeconds: showingSeconds,
            isLimitReached: isLimitReached,
            lowBattery: lowBattery,
            isManualMode: isManualMode,
            debugLog: debugLog
        )
        click = StatusItemGesture(
            timing: timing,
            cube: cube,
            isLimitReached: isLimitReached,
            togglePause: togglePause,
            toggleCubePause: toggleCubePause,
            toggleCubeLock: toggleCubeLock,
            showMenu: { [weak self] in self?.showMenu() },
            scheduler: scheduler,
            // The user's own setting, read at the moment a click needs it rather than held.
            doubleClickInterval: { NSEvent.doubleClickInterval },
            debugLog: debugLog
        )
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
        // **The whole of what to say is `StatusItemReadout`'s**, in `FacetCore`: the latch on the first cube
        // reading, the title, whether the clock should be ticking, whether anything moved and which rows that
        // is worth. What is left here is turning an answer into pixels.
        let update = readout.read()
        // **Taken before there is anything to paint into**, deliberately. The tick is about whether the figure
        // moves, which is a question about the session and not about the item, so it is answered even in a test
        // with no real status item in the menu bar.
        if update.isTicking {
            startTicking()
        } else {
            stopTicking()
        }
        guard update.hasChanged, let button = statusItem?.button else { return }
        let drawn = makeTitle(update.title)
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
        button.setAccessibilityLabel(update.title.spoken)
    }

    /// Whether the once-a-second repaint is running. Internal so it can be asserted without waiting a second for a
    /// real one, which is the same reason `makeTitle` and `width(of:)` are.
    var isRepaintTicking: Bool { tick != nil }

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
        // Three colours, all of them `StatusItemTitle`'s to choose: one for the line's own text, one for the
        // category's name and icon, and one for the play/pause glyph. They come apart in the states worth telling
        // apart -- the name flashes while the cube is flat and the figure beside it does not, the figure turns red
        // on a spent limit and the name does not, and the glyph stays the menu bar's own text colour throughout,
        // being a report on the clock rather than on either.
        // **`.appKitColour` on both, and the compiler will not tell you if it is missing.** The dictionary's value
        // type is `Any`, so a `StatusColour` put here compiles perfectly and AppKit then ignores it, drawing the
        // text in the default colour with nothing said. Caught that way on 2026-09-10, during the move that made
        // these an enum rather than an `NSColor`.
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: parts.colour.appKitColour]
        let named: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: parts.nameColour.appKitColour]
        let title = NSMutableAttributedString()
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
            title.append(attachment(of: icon, colour: parts.nameColour.appKitColour, size: size, font: font))
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
        // In its own colour rather than the line's, which is the archive's arrangement reached from the other side:
        // its indicator was an untinted template image, so the menu bar drew it in the strip's own text colour while
        // the words beside it were green. See `StatusItemTitle.glyphColour`.
        if let glyphName = parts.glyphName, let glyph = symbol(named: glyphName, size: size) {
            title.append(NSAttributedString(string: " ", attributes: plain))
            title.append(attachment(of: glyph, colour: parts.glyphColour.appKitColour, size: size, font: font))
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
        // **Not `mayGroup`.** This is a clock somebody is reading: a second that the platform was free to
        // stretch would show as a figure that stutters. `RunLoopScheduler` is what knows that a menu bar item's
        // own dropdown puts the run loop in a tracking mode, so the wake has to be in `.common` or the clock
        // freezes in exactly the second somebody is looking at it.
        tick = scheduler.wake(in: 1, repeating: true) { [weak self] in
            self?.redraw()
        }
    }

    /// Internal for the same reason `isRepaintTicking` is: a test that starts the clock has to be able to put it down
    /// again, rather than leaving a timer on the run loop for the rest of the suite.
    func stopTicking() {
        tick?.cancel()
        tick = nil
    }

    /// The dropdown, built from what `StatusItemMenu` says it should be. Internal so its shape can be asserted
    /// without putting a real status item in the menu bar, which is what `start()` does.
    ///
    /// **This method decides nothing.** Which lines there are, what they say, whether they can be chosen and
    /// what choosing them does are all `StatusItemMenu`'s, in `FacetCore`, so the Linux indicator draws the same
    /// menu from the same answers. What is left here is `NSMenu`.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Off, because AppKit would otherwise decide each item's enabled state from whether its action can be
        // found -- which is always -- and overwrite what `refresh` sets.
        menu.autoenablesItems = false
        refresh(menu)
        return menu
    }

    /// Rebuilds the menu's lines from the state at this moment. Nothing has to tell the menu when the clock
    /// changes, because the menu never remembers.
    ///
    /// Called from `showMenu`, which is the only place a menu of ours is ever presented, rather than through
    /// `NSMenuDelegate`. A delegate is a **weak** reference, so wiring it makes the menu depend on somebody else
    /// keeping this object alive -- and when that fails the menu simply stops updating, with nothing to see. We
    /// are already the code that opens it, so there is no reason to be told.
    ///
    /// **Rebuilt rather than edited in place.** The old version reached into the existing `NSMenu` by identifier
    /// and set two titles, which only worked because the set of lines never varies. Asking for the whole menu
    /// and laying it out again cannot fall out of step with a menu that grows a line.
    func refresh(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in dropdown.items() {
            menu.addItem(render(item))
        }
    }

    /// One line of AppKit from one line of the core's answer.
    ///
    /// `choose` being `nil` is the whole of "cannot be chosen": the action is dropped and the item is disabled
    /// together, so there is no way to draw a line that looks live and does nothing.
    ///
    /// Both identifiers are set, deliberately. `identifier` is AppKit's own and is what a menu item exposes as
    /// AXIdentifier; `setAccessibilityIdentifier` is the accessibility one. Which of the two actually surfaces is
    /// a question for the accessibility tree rather than the documentation, so both are set and the tree is what
    /// settles it.
    private func render(_ item: StatusItemMenu.Item) -> NSMenuItem {
        guard !item.isSeparator else { return .separator() }
        let rendered = NSMenuItem(title: item.title, action: #selector(chooseMenuItem(_:)), keyEquivalent: "")
        rendered.target = self
        rendered.identifier = NSUserInterfaceItemIdentifier(item.identifier)
        rendered.setAccessibilityIdentifier(item.identifier)
        rendered.isEnabled = item.choose != nil
        rendered.representedObject = item.choose.map(MenuAction.init)
        return rendered
    }

    /// Runs whatever the core attached to the line that was chosen.
    ///
    /// **One selector for every line**, rather than one per line. What each does is already decided in
    /// `StatusItemMenu` and travels on the item itself, so a new line needs no new method here and cannot be
    /// added with its handler forgotten.
    @objc
    private func chooseMenuItem(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let action = item.representedObject as? MenuAction else {
            return
        }
        action.run()
    }

    /// Reads the two facts the event carries and hands them to `StatusItemGesture`, which decides the rest.
    ///
    /// **The side and the count are the whole of what AppKit knows here.** Which action they mean, what row to
    /// write, and whether a cube pause waits to see if a second click is coming are all in `FacetCore`, so an
    /// indicator on another desktop routes a click identically from its own two facts.
    @objc
    private func handleClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        // No event to read a side from, which a synthetic `performClick` is.
        guard let event = NSApp.currentEvent else {
            click.clickedWithNoSide()
            return
        }
        let location = button.convert(event.locationInWindow, from: nil)
        // `<=` so the exact midpoint counts as the left half, i.e. as the menu: of the two, it is the one that
        // cannot leave somebody stuck.
        let isLeftSide = location.x <= button.bounds.width / 2
        click.clicked(isLeftSide: isLeftSide, clickCount: event.clickCount)
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

}

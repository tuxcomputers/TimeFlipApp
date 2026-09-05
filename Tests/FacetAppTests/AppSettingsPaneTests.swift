@testable import FacetApp
import AppKit
import XCTest

/// Covers the App tab's settings section: that every row the archive had is there, that each shows what the table
/// says, and the two conversions between what is stored and what is drawn.
///
/// **Nothing here writes**, and that is the thing worth pinning: a change reports outward and the row is left showing
/// the stored value, so the window can read it back. Until each setting has a writer, every change is a refused write
/// and the database rule says a refused write re-reads.
@MainActor
final class AppSettingsPaneTests: XCTestCase {
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(of pane: AppSettingsPane) -> [String] {
        descendants(of: pane).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func control<T: NSView>(_ identifier: String, in pane: AppSettingsPane) -> T? {
        descendants(of: pane).first { $0.accessibilityIdentifier() == identifier } as? T
    }

    private func field(_ identifier: String, in pane: AppSettingsPane) -> SteppedNumberField? {
        // The field inside the control carries the identifier, so the control itself is its owner.
        descendants(of: pane).compactMap { $0 as? SteppedNumberField }
            .first { descendants(of: $0).contains { $0.accessibilityIdentifier() == identifier } }
    }

    private var stored: AppSettingsPane.Values {
        AppSettingsPane.Values(
            showsSeconds: false,
            dailyResetHour24: 4,
            fetchIntervalSeconds: 600,
            blipSeconds: 2
        )
    }

    // MARK: - the rows

    func testEveryRowTheArchiveHadIsThere() {
        let pane = AppSettingsPane()

        // Four of the archive's six, in its order and its wording (`ReportSettingsView.swift`).
        for title in [
            "App settings",
            "Show seconds",
            "Daily reset at",
            "Fetch history every",
            "Ignore flips under",
        ] {
            XCTAssertTrue(labels(of: pane).contains(title), "missing: \(title)")
        }
    }

    func testTheTwoRowsAboutTheCubeAreNotHereAnyMore() {
        // Both are on the Device tab now, the first two rows of its Settings section: one decides what happens to
        // the cube when the app locks it and the other what counts as the cube running flat. Asserted rather than
        // left implied, a row left behind on both tabs being two controls answering one question.
        let pane = AppSettingsPane()

        XCTAssertFalse(labels(of: pane).contains("Pause the device when locking it"))
        XCTAssertFalse(descendants(of: pane).contains { $0.accessibilityIdentifier() == "app-pause-on-lock" })
        XCTAssertFalse(labels(of: pane).contains("Battery warning at"))
        XCTAssertFalse(descendants(of: pane).contains { $0.accessibilityIdentifier() == "app-battery-warning" })
    }

    func testTheRowsAreInTheArchivesOrder() {
        let pane = AppSettingsPane()

        let titles = labels(of: pane).filter { $0.hasPrefix("Show") || $0.hasPrefix("Daily")
            || $0.hasPrefix("Fetch") || $0.hasPrefix("Ignore") }
        XCTAssertEqual(
            titles,
            [
                "Show seconds",
                "Daily reset at",
                "Fetch history every",
                "Ignore flips under",
            ],
            "the switch first, then the three numbers"
        )
    }

    func testEveryControlIsNamedForItsSetting() {
        let pane = AppSettingsPane()

        for identifier in [
            AppSettingsPane.Identifier.showSeconds,
            AppSettingsPane.Identifier.dailyReset,
            AppSettingsPane.Identifier.fetchInterval,
            AppSettingsPane.Identifier.blipTime,
        ] {
            XCTAssertTrue(
                descendants(of: pane).contains { $0.accessibilityIdentifier() == identifier },
                "missing: \(identifier)"
            )
        }
    }

    // MARK: - what they show

    func testTheSwitchShowsWhatTheTableSays() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        let seconds: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.showSeconds, in: pane))
        XCTAssertEqual(seconds.state, .off)

        pane.show(AppSettingsPane.Values.seeded)
        XCTAssertEqual(seconds.state, .on, "and a second read replaces the first, rather than being ignored")
    }

    func testTheHourIsDrawnOnATwelveHourFace() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.dailyReset, in: pane)).value, 4)
        // AM is a fixed word rather than a second thing to set: a reset in the middle of the afternoon would cut a
        // working day's accounting in half, so PM was only ever a way to pick a wrong value.
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.dailyReset, in: pane)).suffix, "AM")
    }

    func testTheIntervalIsDrawnInMinutesThoughItIsStoredInSeconds() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        let field = try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane))
        XCTAssertEqual(field.value, 10, "600 seconds")
        XCTAssertEqual(field.suffix, "mins")
    }

    func testOneMinuteReadsAsSingular() throws {
        let pane = AppSettingsPane()
        var values = stored
        values.fetchIntervalSeconds = 60

        pane.show(values)

        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).suffix, "min")
    }

    func testTheBlipRowShowsItsOwnUnit() throws {
        let pane = AppSettingsPane()

        pane.show(stored)

        let blip = try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane))
        XCTAssertEqual(blip.value, 2)
        XCTAssertEqual(blip.suffix, "secs")
    }

    func testASingleSecondReadsAsSingular() throws {
        let pane = AppSettingsPane()
        var values = stored
        values.blipSeconds = 1

        pane.show(values)

        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).suffix, "sec")
    }

    func testAPaneNobodyHasReadIntoShowsTheSeededValues() throws {
        // Which is what a database missing every one of these rows would give, and the only guess made anywhere.
        let pane = AppSettingsPane()

        XCTAssertEqual(pane.values, .seeded)
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).value, 5)
    }

    // MARK: - a change, and what the pane holds

    func testAChangedSwitchIsReportedAndNotAdoptedUntilItIsStored() throws {
        let pane = AppSettingsPane()
        // **In a window, and laid out, before anything is clicked**, which is `OffscreenWindow`'s whole reason for
        // existing. A loose pane has no window and its boxes have a zero frame until something lays them out, and
        // `performClick` needs both: without them it does nothing at all, silently, so the pane reads as one that
        // ignored the click rather than as a test that never delivered it.
        //
        // **macOS 26 rings it through anyway, and macOS 15 does not.** This test was written on 26 and passed there
        // for months, on its own and in the whole run, while CI (macos-15) failed it the first time it ever saw it.
        // An OS that is lenient about a rule hides every place the rule was broken, so "it passes here" says nothing.
        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        var reported: [AppSettingsPane.Change] = []
        pane.onChange = { reported.append($0) }
        pane.show(stored)
        pane.layoutSubtreeIfNeeded()

        let box: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.showSeconds, in: pane))
        box.performClick(nil)

        XCTAssertEqual(reported, [.showsSeconds(true)])
        // Not adopted here: the window writes it, checks the table took it, and only then hands it back. What this
        // pane holds is still what the table said, so a refused write has something to put the row back to.
        XCTAssertEqual(pane.values, stored)
    }

    func testAChangedNumberIsReportedInTheUnitTheRowShows() throws {
        let pane = AppSettingsPane()
        var reported: [AppSettingsPane.Change] = []
        pane.onChange = { reported.append($0) }
        pane.show(stored)

        try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).onChange?(9)

        // Minutes, which is what the row shows. Converting to the seconds the table stores is a rule, and doing it
        // here would be a second place it happens.
        XCTAssertEqual(reported, [.fetchIntervalMinutes(9)])
        XCTAssertEqual(pane.values.fetchIntervalSeconds, 600, "unchanged until the table has it")
    }

    func testAUnitThatIsAWordKeepsUpWithTheNumber() throws {
        let pane = AppSettingsPane()
        pane.show(stored)

        try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).onChange?(1)
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)).suffix, "min")

        try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).onChange?(1)
        XCTAssertEqual(try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)).suffix, "sec")
    }

    func testAdoptingAChangeMakesItWhatThePaneHolds() {
        let pane = AppSettingsPane()
        pane.show(stored)

        pane.adopt(.dailyResetHour12(2))
        pane.adopt(.fetchIntervalMinutes(9))
        pane.adopt(.showsSeconds(true))

        // Stored in the table's units, converted once, by the rules.
        XCTAssertEqual(pane.values.dailyResetHour24, 2)
        XCTAssertEqual(pane.values.fetchIntervalSeconds, 540)
        XCTAssertTrue(pane.values.showsSeconds)
    }

    func testAdoptingMidnightStoresItAsZero() {
        let pane = AppSettingsPane()
        pane.show(stored)

        pane.adopt(.dailyResetHour12(12))

        XCTAssertEqual(pane.values.dailyResetHour24, 0, "12 on the face is 0 on the clock")
    }

    func testRestoringPutsEveryRowBackToWhatThePaneHolds() throws {
        let pane = AppSettingsPane()
        pane.show(stored)
        let field = try XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane))
        field.value = 29

        pane.restore()

        XCTAssertEqual(field.value, 2, "which is what a refused write needs: the row was showing what the table refused")
    }

    // MARK: - layout

    /// Hosts the pane the way `NSTabView` does: a content view of a given width, the pane filling it and resizing
    /// with it.
    ///
    /// **Setting the pane's own frame is not the same test.** A pane on its own keeps whatever frame it is handed,
    /// even one that has thrown its autoresizing away, so a test that skips the container passes on the broken
    /// version -- measured: it did, before this was written this way.
    private func hosted(_ pane: AppSettingsPane, width: CGFloat) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        pane.autoresizingMask = [.width, .height]
        pane.frame = content.bounds
        content.addSubview(pane)
        content.layoutSubtreeIfNeeded()
        return content
    }

    /// The App settings section's tinted box. **The box rather than the section around it**: since the heading moved
    /// onto the panel the two are different views, even though they measure the same, and a test about where a panel
    /// reaches should be asking the panel.
    private func panel(of pane: AppSettingsPane) throws -> NSView {
        try XCTUnwrap(
            descendants(of: pane).first { $0.accessibilityIdentifier() == AppSettingsPane.Identifier.panel }
        )
    }

    private func view(_ identifier: String, in pane: AppSettingsPane) throws -> NSView {
        try XCTUnwrap(descendants(of: pane).first { $0.accessibilityIdentifier() == identifier })
    }

    /// The App settings section itself, for scoping a search to one of the tab's two groups.
    ///
    /// **Not the panel, and that is a real distinction rather than a pedantic one.** `PanelSection` puts its box
    /// *behind* the heading and the content rather than around them, so a click lands on the heading button in front
    /// instead of on a box that would swallow it -- which means the rows are siblings of the box, not descendants of
    /// it. Searching inside the box for them finds nothing at all.
    private func section(of pane: AppSettingsPane) throws -> NSView {
        try XCTUnwrap(
            descendants(of: pane).first { $0.accessibilityIdentifier() == AppSettingsPane.Identifier.section }
        )
    }

    func testThePanelSpansTheWindow() throws {
        // The rule in CLAUDE.md, for every tab: a panel is inset by the tab's own padding and nothing more. The trap
        // it exists for is that a pane which sets `translatesAutoresizingMaskIntoConstraints = false` on *itself*
        // throws away the frame the tab view gives it and is sized by its own contents instead, which looks like a
        // panel stopping short of the right-hand edge with nothing in the constraints to explain it.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        XCTAssertEqual(pane.frame.width, 640, "the pane fills the tab before anything inside it can span")
        let frame = content.convert(try panel(of: pane).bounds, from: try panel(of: pane))
        XCTAssertEqual(frame.minX, 20, accuracy: 0.5, "the tab's padding, on the left")
        XCTAssertEqual(frame.maxX, 620, accuracy: 0.5, "and the same on the right")
    }

    func testThePanelStillSpansAfterAResize() throws {
        // Resizing is where a panel that merely happened to fit gives itself away.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        content.frame = NSRect(x: 0, y: 0, width: 1_000, height: 500)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(pane.frame.width, 1_000)
        XCTAssertEqual(
            content.convert(try panel(of: pane).bounds, from: try panel(of: pane)).maxX, 980, accuracy: 0.5
        )
    }

    func testEveryControlIsPinnedToTheRightHandEdge() throws {
        // The archive's shape: the controls run down the right-hand side of the panel rather than following the words.
        // A fixed label column would line them up too, and would park them in the middle with dead space beyond.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let panel = try panel(of: pane)
        let right = content.convert(panel.bounds, from: panel).maxX
        let controls: [NSView] = try [
            XCTUnwrap(control(AppSettingsPane.Identifier.showSeconds, in: pane) as NSButton?),
            XCTUnwrap(field(AppSettingsPane.Identifier.dailyReset, in: pane)),
            XCTUnwrap(field(AppSettingsPane.Identifier.fetchInterval, in: pane)),
            XCTUnwrap(field(AppSettingsPane.Identifier.blipTime, in: pane)),
        ]

        for control in controls {
            // **The alignment rect, not the frame**, because the alignment rect is what a trailing constraint pins and
            // what the eye reads as the control's edge. AppKit pads some controls beyond their visible bounds -- a
            // titleless checkbox is 2pt wider than it draws on macOS 15 -- and the padding is exactly what
            // `alignmentRectInsets` exists to take back out, so a row of controls whose alignment rects line up is a
            // row that looks lined up.
            //
            // Asserting on the frame instead measured that padding and called it misalignment: the checkbox read
            // 602 against the panel's 600 on CI, while macOS 26 (where the inset is zero) agreed with the frame and
            // said nothing. The layout was right on both.
            let aligned = try XCTUnwrap(control.superview).convert(
                control.alignmentRect(forFrame: control.frame), to: content
            )
            // **The shared inset, read rather than written down.** It was 20 here, this tab's own number, while the
            // rows ran the panel's full width and held their own labels off the edge to place the hairlines. The
            // panel insets the list now, exactly as it does on the Categories tab.
            XCTAssertEqual(
                aligned.maxX, right - SettingsMetrics.panelPadding, accuracy: 0.5,
                "\(control.accessibilityIdentifier()) does not reach the panel's inset"
            )
        }
    }

    func testTheRowsSpanThePanelsContent() throws {
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let panel = try panel(of: pane)
        let panelFrame = content.convert(panel.bounds, from: panel)
        // Every row is one width, and that width is the panel inset by the shared padding on both sides. It used to
        // be the panel's own full width, the rows holding their labels off the edge themselves so that the hairlines
        // between them ended where the archive's did; with no hairlines the panel insets the list instead, which is
        // what the Categories tab has always done.
        let stack = try XCTUnwrap(descendants(of: try section(of: pane)).compactMap { $0 as? NSStackView }.first)
        XCTAssertEqual(stack.views.count, 4)
        let rowWidths = Set(stack.views.map(\.frame.width))
        XCTAssertEqual(
            rowWidths, [panelFrame.width - 2 * SettingsMetrics.panelPadding], "one width: \(rowWidths)"
        )
    }

    func testNothingIsDrawnBetweenTheRows() throws {
        // **No hairlines anywhere on this tab.** They were what made it read as a different list from the Categories
        // tab, which has never drawn one: the gap between rows is what divides them. Asserted as an absence because
        // that is what changed -- five separators used to be the check here.
        let pane = AppSettingsPane()
        _ = hosted(pane, width: 640)

        let separators = descendants(of: pane)
            .compactMap { $0 as? NSBox }
            .filter { $0.boxType == .separator }

        XCTAssertEqual(separators.count, 0, "the gap between rows is what divides them")
    }

    // MARK: - the sections fold

    func testBothSectionsStartOpen() {
        // **Not the Categories tab's answer, deliberately.** There, Inactive is an archive and starts shut; here the
        // two sections are what somebody opens the tab to change, so opening it folded would show headings and
        // nothing to change.
        let pane = AppSettingsPane()

        XCTAssertTrue(pane.appSection.isExpanded)
        XCTAssertTrue(pane.googleSection.isExpanded)
    }

    func testTheDebugSectionStartsFolded() {
        // **The Categories tab's Inactive case, on this tab.** Its two rows are of no interest until something needs
        // looking into, which is what a fold is for.
        let pane = AppSettingsPane()

        XCTAssertFalse(pane.debugSection.isExpanded)
    }

    func testTheDebugSectionComesBackFoldedWhenTheWindowResetsIt() {
        // Opening Settings puts every section back to what it was built as, and each section owns which that is
        // (`CollapsibleSection`). The three on this tab do not agree, which is the case a reset that put everything
        // one way would get wrong.
        let pane = AppSettingsPane()
        pane.debugSection.setExpanded(true)

        pane.debugSection.restoreDefaultState()
        pane.appSection.restoreDefaultState()

        XCTAssertFalse(pane.debugSection.isExpanded)
        XCTAssertTrue(pane.appSection.isExpanded, "and the other two come back to their own answer")
    }

    func testFoldingASectionTakesTheSpaceBack() throws {
        // The trap this is really about: Auto Layout does not care that a view is hidden, so hiding the rows alone
        // leaves their full height behind and a folded section measures exactly as tall as an open one.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)
        let open = pane.appSection.frame.height

        pane.appSection.setExpanded(false)
        content.layoutSubtreeIfNeeded()

        XCTAssertLessThan(pane.appSection.frame.height, open, "folded, it is shorter than it was open")
        // Down to the heading line and its padding, rather than to nothing: the panel closes around the heading.
        let heading = try view(AppSettingsPane.Identifier.heading, in: pane)
        XCTAssertGreaterThan(pane.appSection.frame.height, heading.frame.height)
    }

    func testTheHeadingSitsOnItsOwnPanel() throws {
        // `CLAUDE.md`: a collapsible group's heading is the first row of the panel it folds, not a caption floating
        // above it. This is the measurement that tells the two apart.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let panel = try panel(of: pane)
        let panelFrame = content.convert(panel.bounds, from: panel)
        let heading = try view(AppSettingsPane.Identifier.heading, in: pane)
        let headingFrame = content.convert(heading.bounds, from: heading)

        XCTAssertTrue(panelFrame.contains(headingFrame), "\(headingFrame) is not on \(panelFrame)")
    }

    func testTheWholeHeadingLineFolds() throws {
        // `CLAUDE.md` again: the triangle, the words, and the space after them to the end of the row. A triangle
        // alone is a small target for a gesture the heading beside it is obviously about.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let button = try view("\(AppSettingsPane.Identifier.section)-heading-button", in: pane)
        let panel = try panel(of: pane)
        XCTAssertEqual(
            content.convert(button.bounds, from: button).width,
            content.convert(panel.bounds, from: panel).width,
            accuracy: 0.5
        )
    }

    func testAFoldIsReportedWithTheSectionItWasMadeOn() {
        // Nothing stores a fold, so the row the window writes is the only record it happened -- and the identifier is
        // what tells a scripted check which of the two it was.
        let pane = AppSettingsPane()
        var reported: [(String, Bool)] = []
        pane.onSectionToggle = { reported.append(($0, $1)) }

        pane.appSection.setExpanded(false)
        pane.googleSection.setExpanded(false)

        // `setExpanded` is the state changing, not somebody pressing the heading, so it reports nothing at all.
        XCTAssertTrue(reported.isEmpty, "a fold nobody made is not a fold: \(reported)")
    }

    // MARK: - the footnote goes with the section it explains

    func testTheGoogleNoteIsTakenAwayWithItsSection() throws {
        // It says why the button above it cannot be pressed. Folded, that button is not on screen, so a sentence
        // explaining it is an answer to a question nobody can see being asked.
        let pane = AppSettingsPane()
        let note = try view(AppSettingsPane.Identifier.googleNote, in: pane)
        XCTAssertFalse(note.isHidden, "precondition: this build has no credentials, so there is a note")

        pane.googleSection.setExpanded(false)
        XCTAssertTrue(note.isHidden)

        pane.googleSection.setExpanded(true)
        XCTAssertFalse(note.isHidden, "and it comes back with the section")
    }

    func testRedrawingTheAccountWhileFoldedLeavesTheNoteAway() throws {
        // The reason the two questions are asked in one place. `showGoogle` rebuilds the rows whenever the account
        // changes, and setting the note's visibility from there alone would put it back under a folded section.
        let pane = AppSettingsPane()
        let note = try view(AppSettingsPane.Identifier.googleNote, in: pane)
        pane.googleSection.setExpanded(false)

        pane.show(stored)

        XCTAssertTrue(note.isHidden)
    }

    func testTheNoteComesBackWhenTheWindowResetsTheFold() throws {
        // **The regression this pair of hooks exists for.** Opening Settings puts every section back to what it was
        // built as, and that path is deliberately silent -- no gesture callback, no `debug_log` row. Hanging the note
        // off the gesture left it hidden under a section the reset had just opened, which is a footnote that
        // disappears for the rest of the launch because of a fold made in a previous window.
        let pane = AppSettingsPane()
        let note = try view(AppSettingsPane.Identifier.googleNote, in: pane)
        pane.googleSection.setExpanded(false)
        XCTAssertTrue(note.isHidden, "precondition: folded away with its section")

        pane.googleSection.restoreDefaultState()

        XCTAssertTrue(pane.googleSection.isExpanded)
        XCTAssertFalse(note.isHidden)
    }

    // MARK: - the Debug section

    func testTheDebugSectionCarriesBothFieldsOfTheDebugRow() {
        let pane = AppSettingsPane()

        for title in ["Debug", "Debug logging", "Directory", "Trace file"] {
            XCTAssertTrue(labels(of: pane).contains(title), "missing: \(title)")
        }
        for identifier in [
            AppSettingsPane.Identifier.debugEnabled,
            AppSettingsPane.Identifier.debugDirectory,
            AppSettingsPane.Identifier.debugDirectoryChoose,
            AppSettingsPane.Identifier.debugReveal,
            AppSettingsPane.Identifier.debugCopy,
            AppSettingsPane.Identifier.debugClear,
        ] {
            XCTAssertTrue(
                descendants(of: pane).contains { $0.accessibilityIdentifier() == identifier },
                "missing: \(identifier)"
            )
        }
    }

    func testGettingHoldOfTheTraceIsAskedForRatherThanDoneHere() throws {
        // Both open somebody else's window -- the Finder, or a save panel -- which is the window controller's to do.
        let pane = AppSettingsPane()
        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        var reported: [AppSettingsPane.Change] = []
        pane.onChange = { reported.append($0) }
        var values = stored
        values.hasDebugTrace = true
        pane.show(values)
        pane.layoutSubtreeIfNeeded()

        try XCTUnwrap(control(AppSettingsPane.Identifier.debugReveal, in: pane) as NSButton?).performClick(nil)
        try XCTUnwrap(control(AppSettingsPane.Identifier.debugCopy, in: pane) as NSButton?).performClick(nil)
        try XCTUnwrap(control(AppSettingsPane.Identifier.debugClear, in: pane) as NSButton?).performClick(nil)

        // Clearing in particular: the pane asks, and the window confirms it before anything is emptied.
        XCTAssertEqual(reported, [.debugRevealRequested, .debugCopyRequested, .debugClearRequested])
    }

    func testTheTraceButtonsAreDeadWhenThereIsNoTrace() throws {
        // **No *file*, rather than no logger.** The file outlives logging being on, and keying these to the logger
        // left all three dead beside a trace somebody had just been asked to send in.
        let pane = AppSettingsPane()
        pane.show(stored)

        let reveal: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.debugReveal, in: pane))
        let copy: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.debugCopy, in: pane))
        let clear: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.debugClear, in: pane))
        XCTAssertFalse(reveal.isEnabled)
        XCTAssertFalse(copy.isEnabled)
        XCTAssertFalse(clear.isEnabled)

        var values = stored
        values.hasDebugTrace = true
        pane.show(values)
        XCTAssertTrue(reveal.isEnabled, "and they come alive when there is a file")
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(clear.isEnabled)
    }

    func testTheDebugRowsShowWhatTheTableSays() throws {
        let pane = AppSettingsPane()
        var values = stored
        values.isDebugEnabled = true
        values.debugDirectory = "~/Documents/Facet"

        pane.show(values)

        let box: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.debugEnabled, in: pane))
        XCTAssertEqual(box.state, .on)
        let folder: NSTextField = try XCTUnwrap(control(AppSettingsPane.Identifier.debugDirectory, in: pane))
        XCTAssertEqual(folder.stringValue, "~/Documents/Facet", "the stored form, tilde and all")
    }

    func testAPaneNobodyHasReadIntoShowsTheSeededDebugRow() throws {
        let pane = AppSettingsPane()

        XCTAssertFalse(pane.values.isDebugEnabled)
        let folder: NSTextField = try XCTUnwrap(control(AppSettingsPane.Identifier.debugDirectory, in: pane))
        XCTAssertEqual(folder.stringValue, DebugTraceRules.defaultDirectory)
    }

    func testTheDebugSwitchIsReportedAndNotAdoptedUntilItIsStored() throws {
        let pane = AppSettingsPane()
        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        var reported: [AppSettingsPane.Change] = []
        pane.onChange = { reported.append($0) }
        pane.show(stored)
        pane.layoutSubtreeIfNeeded()

        let box: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.debugEnabled, in: pane))
        box.performClick(nil)

        XCTAssertEqual(reported, [.debugEnabled(true)])
        XCTAssertFalse(pane.values.isDebugEnabled, "what the pane holds is still what the table said")
    }

    func testChoosingAFolderIsAskedForRatherThanDoneHere() throws {
        // The window runs the panel: anything modal belongs to whoever owns the window.
        let pane = AppSettingsPane()
        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        var reported: [AppSettingsPane.Change] = []
        pane.onChange = { reported.append($0) }
        pane.show(stored)
        pane.layoutSubtreeIfNeeded()

        let choose: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.debugDirectoryChoose, in: pane))
        choose.performClick(nil)

        XCTAssertEqual(reported, [.debugDirectoryRequested])
        XCTAssertEqual(pane.values.debugDirectory, stored.debugDirectory, "nothing has been chosen yet")
    }

    func testAdoptingAFolderRedrawsTheRow() throws {
        // Nobody types into this row, so there is no field to take out from under them -- and a row still naming the
        // previous folder would be the window showing something the table no longer says.
        let pane = AppSettingsPane()
        pane.show(stored)

        pane.adopt(.debugDirectory("/Volumes/Spare/Facet"))

        XCTAssertEqual(pane.values.debugDirectory, "/Volumes/Spare/Facet")
        let folder: NSTextField = try XCTUnwrap(control(AppSettingsPane.Identifier.debugDirectory, in: pane))
        XCTAssertEqual(folder.stringValue, "/Volumes/Spare/Facet")
    }

    func testRestoringPutsTheDebugRowsBackToWhatThePaneHolds() throws {
        let pane = AppSettingsPane()
        pane.show(stored)
        let box: NSButton = try XCTUnwrap(control(AppSettingsPane.Identifier.debugEnabled, in: pane))
        box.state = .on

        pane.restore()

        XCTAssertEqual(box.state, .off, "which is what a refused write needs")
    }

    func testAFoldOfTheDebugSectionIsReportedUnderItsOwnIdentifier() throws {
        // Nothing stores a fold, so the row the window writes is the only record it happened -- and the identifier is
        // what tells a scripted check which of the three it was.
        let pane = AppSettingsPane()
        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        var reported: [(String, Bool)] = []
        pane.onSectionToggle = { reported.append(($0, $1)) }
        pane.layoutSubtreeIfNeeded()

        let heading = try view("\(AppSettingsPane.Identifier.debugSection)-heading-button", in: pane)
        try XCTUnwrap(heading as? NSButton).performClick(nil)

        XCTAssertEqual(reported.map(\.0), [AppSettingsPane.Identifier.debugSection])
        XCTAssertEqual(reported.map(\.1), [true], "it was built folded, so a press opens it")
    }

    func testTheDebugSectionHangsUnderTheGoogleFootnoteWhenThereIsOne() throws {
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)
        let note = try view(AppSettingsPane.Identifier.googleNote, in: pane)
        XCTAssertFalse(note.isHidden, "precondition: this build has no credentials, so there is a note")

        content.layoutSubtreeIfNeeded()

        // Unflipped coordinates: a view below another has the smaller y, so the gap runs from the note's bottom edge
        // down to the section's top.
        let debug = try view(AppSettingsPane.Identifier.debugSection, in: pane)
        XCTAssertEqual(
            note.frame.minY - debug.frame.maxY, SettingsMetrics.sectionSpacing, accuracy: 0.5
        )
    }

    func testAFootnoteNobodyCanSeeDoesNotPushTheDebugSectionDown() throws {
        // **The trap this pair of constraints exists for.** A hidden view keeps its height in Auto Layout, so a
        // section anchored to the note alone would be held down the tab by a sentence nobody can see.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)
        var values = stored
        values.googleAccount = GoogleAccountRules.Account(name: "Harry", email: "harry@example.com")
        values.googleCredential = .present

        pane.show(values)
        content.layoutSubtreeIfNeeded()

        let note = try view(AppSettingsPane.Identifier.googleNote, in: pane)
        XCTAssertTrue(note.isHidden, "precondition: a connected account is explained by the rows themselves")
        let google = try view(AppSettingsPane.Identifier.googleSection, in: pane)
        let debug = try view(AppSettingsPane.Identifier.debugSection, in: pane)
        XCTAssertEqual(
            google.frame.minY - debug.frame.maxY, SettingsMetrics.sectionSpacing, accuracy: 0.5,
            "the same gap the other two sections are held apart by"
        )
    }

    func testFoldingGoogleTakesItsFootnoteOutOfTheWayToo() throws {
        // The note has two reasons to be away and both move the section under it, which is why one place decides.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        pane.googleSection.setExpanded(false)
        content.layoutSubtreeIfNeeded()

        let google = try view(AppSettingsPane.Identifier.googleSection, in: pane)
        let debug = try view(AppSettingsPane.Identifier.debugSection, in: pane)
        XCTAssertEqual(google.frame.minY - debug.frame.maxY, SettingsMetrics.sectionSpacing, accuracy: 0.5)
    }

    func testAFootnoteCannotWidenTheTab() throws {
        // **The fault this pins, measured on the running app**: selecting the App tab widened the window. A wrapping
        // label's `maximumNumberOfLines = 0` decides how it *draws*, not what it asks for -- its intrinsic width is
        // still the whole string on one line, and the Debug footnote is the longest run of text on the tab. It asked
        // for 763pt inside a 640pt window and the window obliged.
        //
        // Asserted of both notes, because a note that happens to be short enough today is the same fault waiting for
        // a longer sentence: the Google one is 367pt only because of what it currently says.
        let pane = AppSettingsPane()

        for identifier in [AppSettingsPane.Identifier.debugNote, AppSettingsPane.Identifier.googleNote] {
            let note = try XCTUnwrap(view(identifier, in: pane) as? NSTextField)
            XCTAssertEqual(
                note.contentCompressionResistancePriority(for: .horizontal), .defaultLow,
                "\(identifier) may still insist on its own width, which is what widened the window"
            )
        }
    }

    func testAFootnoteIsDrawnAtTheHeightItsWrappedTextNeeds() throws {
        // The other half of the same thing: a label nobody may widen has to be given the height to wrap into, or the
        // fix for the window trades one fault for text with its tail cut off.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)
        content.layoutSubtreeIfNeeded()

        let note = try XCTUnwrap(view(AppSettingsPane.Identifier.debugNote, in: pane) as? NSTextField)
        XCTAssertGreaterThan(note.frame.height, 20, "this sentence does not fit on one line at 640pt")
        XCTAssertLessThan(note.frame.width, 640, "and it is inside the tab rather than reaching past it")
    }

    func testTheDebugPanelSpansTheWindowToo() throws {
        // `CLAUDE.md`: every panel on every tab runs the full width of the window, inset by the tab's own padding.
        let pane = AppSettingsPane()
        let content = hosted(pane, width: 640)

        let panel = try view(AppSettingsPane.Identifier.debugPanel, in: pane)
        let frame = content.convert(panel.bounds, from: panel)
        XCTAssertEqual(frame.minX, 20, accuracy: 0.5)
        XCTAssertEqual(frame.maxX, 620, accuracy: 0.5)
    }

    func testAConnectedAccountHasNoNoteToPutBack() throws {
        // The other half: the note is hidden because there is nothing to say, and opening the section does not
        // invent one.
        let pane = AppSettingsPane()
        var values = stored
        values.googleAccount = GoogleAccountRules.Account(name: "Harry", email: "harry@example.com")
        // Both halves, because an identity on its own is now `signedOut` and `signedOut` has a note: the row names
        // somebody and there is no token for them, which is exactly the thing worth saying out loud.
        values.googleCredential = .present
        pane.show(values)
        let note = try view(AppSettingsPane.Identifier.googleNote, in: pane)
        XCTAssertTrue(note.isHidden, "precondition: a connected account is explained by the rows themselves")

        pane.googleSection.setExpanded(false)
        pane.googleSection.setExpanded(true)

        XCTAssertTrue(note.isHidden)
    }
}

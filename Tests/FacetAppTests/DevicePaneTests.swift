@testable import FacetApp
import AppKit
import XCTest

/// Covers the Device tab: that it draws the archive's three sections, that every value on it comes from what it was
/// shown, and that the three folding rows fold.
///
/// **Nothing above the TimeFlip section writes**, which is the tab's shape at this point rather than an omission. So
/// what is worth pinning there is the drawing and the reading, plus the folds; the section that does reach a cube is
/// pinned by what it asks for and what it does while it waits, the radio itself being somebody else's test.
@MainActor
final class DevicePaneTests: XCTestCase {
    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func labels(of pane: DevicePane) -> [String] {
        descendants(of: pane).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func value(_ identifier: String, in pane: DevicePane) -> String? {
        descendants(of: pane)
            .first { $0.accessibilityIdentifier() == identifier }
            .flatMap { ($0 as? NSTextField)?.stringValue }
    }

    /// A scan result's row. It is a button rather than a label, the whole row being the way to reach the device, so
    /// its name is a title and not a value.
    private func deviceRow(_ id: UUID, in pane: DevicePane) -> NSButton? {
        descendants(of: pane).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == DevicePane.Identifier.scanResult(id) }
    }

    private func view(_ identifier: String, in pane: DevicePane) -> NSView? {
        descendants(of: pane).first { $0.accessibilityIdentifier() == identifier }
    }

    /// The field *inside* the control carries the identifier, so the control itself is its owner. The App tab's tests
    /// reach for one the same way, for the same reason.
    private func stepper(_ identifier: String, in pane: DevicePane) -> SteppedNumberField? {
        descendants(of: pane).compactMap { $0 as? SteppedNumberField }
            .first { descendants(of: $0).contains { $0.accessibilityIdentifier() == identifier } }
    }

    private var paired: DevicePane.Values {
        var values = DevicePane.Values.seeded
        values.isPaired = true
        values.isConnected = true
        values.isManualMode = false
        values.deviceName = "Dibby"
        values.batteryPercent = 34
        values.manufacturer = "DI_LABS 2.0"
        values.model = "TimeFlip2"
        values.hardware = "TFv4.1"
        values.firmware = "FW_v3.64"
        return values
    }

    // MARK: - scanning

    private func button(_ identifier: String, in pane: DevicePane) -> NSButton? {
        descendants(of: pane).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier }
    }

    func testTheButtonSaysWhatPressingItWouldDo() {
        // It reads Stop Scan while one is running, which is the same rule the dropdown's Pause item follows: a
        // control names its action, not its state.
        let pane = DevicePane()
        XCTAssertEqual(button(DevicePane.Identifier.scan, in: pane)?.title, "Scan for Devices")

        pane.showScanning(true)
        XCTAssertEqual(button(DevicePane.Identifier.scan, in: pane)?.title, "Stop Scan")

        pane.showScanning(false)
        XCTAssertEqual(button(DevicePane.Identifier.scan, in: pane)?.title, "Scan for Devices")
    }

    func testPressingScanReportsWhetherAllDevicesIsTicked() {
        // The filter is chosen when the button is pressed, so the box has to be read at that moment rather than
        // watched: ticking it mid-scan changes nothing until the next press.
        let pane = DevicePane()
        var asked: [Bool] = []
        pane.onScan = { asked.append($0) }

        button(DevicePane.Identifier.scan, in: pane)?.performClick(nil)
        button(DevicePane.Identifier.scanAll, in: pane)?.state = .on
        button(DevicePane.Identifier.scan, in: pane)?.performClick(nil)

        XCTAssertEqual(asked, [false, true])
    }

    func testPressingItWhileScanningStopsRatherThanStartsAgain() {
        let pane = DevicePane()
        var starts = 0
        var stops = 0
        pane.onScan = { _ in starts += 1 }
        pane.onStopScan = { stops += 1 }

        pane.showScanning(true)
        button(DevicePane.Identifier.scan, in: pane)?.performClick(nil)

        XCTAssertEqual(stops, 1)
        XCTAssertEqual(starts, 0, "a second scan must not be started on top of the one running")
    }

    func testTheFoundDevicesAreDrawnUnderTheButton() {
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "Hazza cuber", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: false
        )

        pane.showFound([cube])

        XCTAssertEqual(
            deviceRow(cube.id, in: pane)?.title, "Hazza cuber",
            "the row shows the name the user chose, not the one the cube advertises"
        )
    }

    func testAFoundDeviceIsNamedOnceNotTwice() {
        // **Reported from a running app**: one cube was drawn as "TimeFlip v2.0 ... TimeFlip v2.0", which read as two
        // devices. It was one row built as a label-and-value pair with the same name passed as both, because a scan
        // result had been made to look like a settings row. It is a list item: the name appears once, on the left.
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "TimeFlip v2.0", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: false
        )

        pane.showFound([cube])

        let labelled = descendants(of: pane)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && $0.stringValue == "TimeFlip v2.0" }
        let titled = descendants(of: pane)
            .compactMap { $0 as? NSButton }
            .filter { !$0.isHidden && $0.title == "TimeFlip v2.0" }
        XCTAssertEqual(
            labelled.count + titled.count, 1, "the name is drawn once per device, not at both ends of the row"
        )
    }

    func testASecondScanReplacesTheListRatherThanAddingToIt() {
        // The pane holds no list of its own: it draws what it was last handed, so a device that has dropped out
        // cannot linger because nothing here remembers it.
        let pane = DevicePane()
        let first = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "One", advertisedName: nil, advertisesTimeFlipService: false
        )
        let second = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
            peripheralName: "Two", advertisedName: nil, advertisesTimeFlipService: false
        )

        pane.showFound([first])
        pane.showFound([second])

        XCTAssertNil(deviceRow(first.id, in: pane), "the first list is gone")
        XCTAssertEqual(deviceRow(second.id, in: pane)?.title, "Two")
    }

    // MARK: - reaching one

    func testPressingADeviceAsksForThatDevice() {
        // **The whole row is the target**, which is why the name is the button's title rather than a label sitting on
        // one: there is one thing to do with a scan result, so aiming at a second control inside the row would be the
        // triangle-versus-heading mistake `CLAUDE.md` describes.
        let pane = DevicePane()
        let first = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "One", advertisedName: nil, advertisesTimeFlipService: false
        )
        let second = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
            peripheralName: "Two", advertisedName: nil, advertisesTimeFlipService: false
        )
        var asked: [UUID] = []
        pane.onConnect = { asked.append($0) }

        pane.showFound([first, second])
        deviceRow(second.id, in: pane)?.performClick(nil)

        XCTAssertEqual(asked, [second.id], "the press has to carry which row it was")
    }

    func testTheListGoesDeadWhileOneOfThemIsBeingReached() {
        // A connect takes several seconds and nothing else on the row changes, so the obvious thing to do is press it
        // again. Ignoring that press quietly is what makes a control look broken; the row going dead says so.
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "One", advertisedName: nil, advertisesTimeFlipService: false
        )
        pane.showFound([cube])

        pane.showReaching(true)
        XCTAssertEqual(deviceRow(cube.id, in: pane)?.isEnabled, false)

        pane.showReaching(false)
        XCTAssertEqual(deviceRow(cube.id, in: pane)?.isEnabled, true)
    }

    func testARedrawnListStaysDeadWhileOneOfThemIsBeingReached() {
        // The rows are rebuilt on every advertisement, so a list redrawn mid-attempt would come back live and undo
        // the greying above. That is not hypothetical: a scan that is still running behind a connect is exactly the
        // case, and the fix has to be in the redraw rather than in whoever called it.
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "One", advertisedName: nil, advertisesTimeFlipService: false
        )

        pane.showReaching(true)
        pane.showFound([cube])

        XCTAssertEqual(deviceRow(cube.id, in: pane)?.isEnabled, false)
    }

    func testStoppingTakesDownTheLookingMessage() {
        // **Reported from a running app**: the scan was stopped, the button read Scan for Devices again, and the line
        // under it still said "Looking for devices..." beside a finished list. The app had switched the radio off and
        // gone on saying it was searching.
        let pane = DevicePane()

        pane.showScanning(true)
        XCTAssertEqual(value(DevicePane.Identifier.scanStatus, in: pane), "Looking for devices...")

        pane.showScanning(false)

        XCTAssertNotEqual(
            value(DevicePane.Identifier.scanStatus, in: pane), "Looking for devices...",
            "a stopped scan must not go on claiming to look"
        )
    }

    func testStoppingDoesNotWipeTheReasonItStopped() {
        // The radio going away stops the scan *and* explains itself, in that order. Clearing everything on stop
        // would take the explanation down a moment after it appeared, leaving an empty line where the reason was.
        let pane = DevicePane()
        pane.showScanning(true)

        pane.showScanning(false)
        pane.showScanMessage(ScanUnavailable.bluetoothOff.message)

        XCTAssertEqual(value(DevicePane.Identifier.scanStatus, in: pane), ScanUnavailable.bluetoothOff.message)
    }

    func testTheStatusRowSaysWhyAScanIsNotRunning() {
        // An empty list means "found nothing", "Bluetooth is off" and "not allowed to use Bluetooth" all at once,
        // and those want three different things done about them.
        let pane = DevicePane()

        pane.showScanMessage(ScanUnavailable.bluetoothOff.message)

        XCTAssertEqual(value(DevicePane.Identifier.scanStatus, in: pane), ScanUnavailable.bluetoothOff.message)
    }

    // MARK: - the sections

    func testTheThreeSectionsTheArchiveHadAreThere() {
        let pane = DevicePane()

        for title in ["Info", "Settings", "TimeFlip"] {
            XCTAssertTrue(labels(of: pane).contains(title), "missing section: \(title)")
        }
    }

    func testEveryRowIsNamedForWhatItSays() {
        let pane = DevicePane()

        // Named so a scripted step can read one without hunting by position, which is the whole reason the old
        // locator layer existed and this app does not need one.
        for identifier in [
            DevicePane.Identifier.name,
            DevicePane.Identifier.connection,
            DevicePane.Identifier.battery,
            DevicePane.Identifier.more,
            DevicePane.Identifier.autoPause,
            DevicePane.Identifier.led,
            DevicePane.Identifier.doubleTap,
            DevicePane.Identifier.scan,
            DevicePane.Identifier.scanAll,
        ] {
            XCTAssertNotNil(view(identifier, in: pane), "missing: \(identifier)")
        }
    }

    // MARK: - what it shows

    func testAPaneNobodyHasReadIntoShowsWhatAFreshDatabaseHolds() {
        // The seeds in `database/011_setting.sql`, so an unread pane shows what a new database would rather than
        // zeroes that mean nothing. The only guess made anywhere on this tab.
        let pane = DevicePane()

        XCTAssertEqual(pane.values, .seeded)
        XCTAssertEqual(value(DevicePane.Identifier.name, in: pane), "Not paired")
        XCTAssertEqual(value(DevicePane.Identifier.connection, in: pane), "Manual mode, no device")
        XCTAssertEqual(value(DevicePane.Identifier.battery, in: pane), "Not paired")
    }

    func testTheInfoRowsComeFromWhatItWasShown() {
        let pane = DevicePane()

        pane.show(paired)

        XCTAssertEqual(value(DevicePane.Identifier.name, in: pane), "Dibby")
        XCTAssertEqual(value(DevicePane.Identifier.connection, in: pane), "Connected")
        XCTAssertEqual(value(DevicePane.Identifier.battery, in: pane), "34%")
        XCTAssertEqual(value(DevicePane.Identifier.manufacturer, in: pane), "DI_LABS 2.0")
        XCTAssertEqual(value(DevicePane.Identifier.firmware, in: pane), "FW_v3.64")
    }

    func testTheSettingsRowsCarryTheirUnits() {
        var values = DevicePane.Values.seeded
        values.autoPauseMinutes = 12
        values.ledBrightnessPercent = 70
        values.ledBlinkSeconds = 20
        let pane = DevicePane()

        pane.show(values)

        // The unit is part of the answer: "20" against Blink Interval could be seconds or minutes, and the archive
        // wrote both out for that reason.
        XCTAssertEqual(value(DevicePane.Identifier.ledBrightness, in: pane), "70 %")
        XCTAssertEqual(value(DevicePane.Identifier.ledBlink, in: pane), "20 sec")
        XCTAssertEqual(stepper(DevicePane.Identifier.autoPause, in: pane)?.value, 12)
    }

    func testTheDoubleTapBoxIsTickedWhenTheGestureIsOff() throws {
        // "Disable", not "Enable", which is the archive's wording and the right way round: the setting is on by
        // default, so the box somebody ticks is the one that turns the gesture off. Ticked means disabled, and
        // getting this backwards would be invisible in a screenshot.
        var values = DevicePane.Values.seeded
        values.isDoubleTapEnabled = false
        let pane = DevicePane()

        pane.show(values)

        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)
        XCTAssertEqual(box.state, .on)
        pane.show(.seeded)
        XCTAssertEqual(box.state, .off, "the gesture is on by default, so the Disable box is clear")
    }

    func testValuesGreyWhenNothingCanBeHeardFrom() throws {
        let pane = DevicePane()

        pane.show(.seeded)
        let name = try XCTUnwrap(view(DevicePane.Identifier.name, in: pane) as? NSTextField)
        XCTAssertEqual(name.textColor, .secondaryLabelColor, "a placeholder is not a reading")

        pane.show(paired)
        XCTAssertEqual(name.textColor, .labelColor)
    }

    // MARK: - the TimeFlip section's two states

    /// Hidden through an enclosing stack as well as on the view itself, so this asks the question the eye asks:
    /// is it on screen at all?
    private func isShowing(_ identifier: String, in pane: DevicePane) -> Bool {
        guard let target = view(identifier, in: pane) else { return false }
        var node: NSView? = target
        while let current = node, current !== pane {
            if current.isHidden { return false }
            node = current.superview
        }
        return true
    }

    func testAnAppWithNoDeviceIsOfferedAScan() {
        let pane = DevicePane()

        pane.show(.seeded)

        XCTAssertTrue(isShowing(DevicePane.Identifier.scan, in: pane))
        XCTAssertTrue(isShowing(DevicePane.Identifier.scanAll, in: pane))
        XCTAssertFalse(isShowing(DevicePane.Identifier.forget, in: pane))
        XCTAssertFalse(isShowing(DevicePane.Identifier.reset, in: pane))
    }

    func testAPairedAppGetsForgetAndResetInPlaceOfTheScan() {
        let pane = DevicePane()

        pane.show(paired)

        // The section stops being about finding a cube the moment there is one.
        XCTAssertFalse(isShowing(DevicePane.Identifier.scan, in: pane))
        XCTAssertFalse(isShowing(DevicePane.Identifier.scanAll, in: pane))
        XCTAssertTrue(isShowing(DevicePane.Identifier.forget, in: pane))
        XCTAssertTrue(isShowing(DevicePane.Identifier.reset, in: pane))
    }

    func testTheSwapGoesBothWays() {
        let pane = DevicePane()

        pane.show(paired)
        pane.show(.seeded)

        // Forgetting a device is what puts the Scan button back, so the swap has to survive being made twice.
        XCTAssertTrue(isShowing(DevicePane.Identifier.scan, in: pane))
        XCTAssertFalse(isShowing(DevicePane.Identifier.forget, in: pane))
    }

    func testPairingClearsTheListOfFoundDevices() {
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "Dibby", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        pane.showFound([cube])
        XCTAssertNotNil(deviceRow(cube.id, in: pane), "precondition: the scan found one")

        pane.show(paired)

        // The list goes with the Scan button, being the same answer: once there is a device there is nothing left to
        // choose, and a row left up would silently drop the pairing just made if it were pressed.
        XCTAssertNil(deviceRow(cube.id, in: pane))
    }

    func testARedrawWithNothingPairedLeavesALiveScanListAlone() {
        // The guard that matters: `show` runs on every redraw, including one that happens while a scan is going, and
        // clearing unconditionally would empty the list out from under somebody about to press a row.
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "Dibby", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        pane.showFound([cube])

        pane.show(.seeded)

        XCTAssertNotNil(deviceRow(cube.id, in: pane))
    }

    func testAPairedPaneStaysEmptyAcrossRedraws() {
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "Dibby", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        pane.showFound([cube])
        pane.show(paired)

        // Every later redraw goes through the same rule, so a reopened window cannot bring the stale list back.
        pane.show(paired)

        XCTAssertNil(deviceRow(cube.id, in: pane))
    }

    func testAScanStillRunningCannotDrawRowsIntoAPairedTab() {
        // The radio calls `showFound` on every advertisement, so the rule cannot live only in `show`: a scan carrying
        // on behind a pairing would otherwise put the list straight back, under controls with no way to stop it.
        let pane = DevicePane()
        let cube = ScannedDevice(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            peripheralName: "Dibby", advertisedName: "TimeFlip v2.0", advertisesTimeFlipService: true
        )
        pane.show(paired)

        pane.showFound([cube])

        XCTAssertNil(deviceRow(cube.id, in: pane))
    }

    func testPressingForgetReportsItWithNothingAskedFirst() {
        // No confirmation, which is the archive's decision: forgetting is local bookkeeping with no round trip to
        // await, and a step in front of the one control that gets a stuck app moving is a step too many.
        let pane = DevicePane()
        pane.show(paired)
        var asked = 0
        pane.onForget = { asked += 1 }

        button(DevicePane.Identifier.forget, in: pane)?.performClick(nil)

        XCTAssertEqual(asked, 1)
    }

    func testForgetStaysPressableWithNothingConnected() {
        let pane = DevicePane()
        var values = paired
        values.isConnected = false

        pane.show(values)

        // It reaches no radio, which is what makes it the way back from a cube on a PIN this app cannot present.
        XCTAssertEqual(button(DevicePane.Identifier.forget, in: pane)?.isEnabled, true)
    }

    func testForgetGoesDeadWhileADeviceIsBeingReached() {
        let pane = DevicePane()
        pane.show(paired)

        pane.showReaching(true)

        // Set by `showReaching` as well as by `show`, because this is what actually moves: an attempt begins and ends
        // without the tab being redrawn from the table.
        XCTAssertEqual(button(DevicePane.Identifier.forget, in: pane)?.isEnabled, false)

        pane.showReaching(false)
        XCTAssertEqual(button(DevicePane.Identifier.forget, in: pane)?.isEnabled, true)
    }

    func testPressingResetReportsIt() {
        let pane = DevicePane()
        pane.show(paired)
        var asked = 0
        pane.onReset = { asked += 1 }

        button(DevicePane.Identifier.reset, in: pane)?.performClick(nil)

        XCTAssertEqual(asked, 1)
    }

    func testResetGoesDeadWithNothingConnectedWhileForgetStaysLive() {
        let pane = DevicePane()
        var values = paired
        values.isConnected = false

        pane.show(values)

        // One is a command that has to arrive somewhere; the other is this app's own rows.
        XCTAssertEqual(button(DevicePane.Identifier.reset, in: pane)?.isEnabled, false)
        XCTAssertEqual(button(DevicePane.Identifier.forget, in: pane)?.isEnabled, true)
    }

    func testResetGoesDeadWhileADeviceIsBeingReached() {
        let pane = DevicePane()
        pane.show(paired)

        pane.showReaching(true)

        XCTAssertEqual(button(DevicePane.Identifier.reset, in: pane)?.isEnabled, false)
    }

    func testACubeOutOfRangeStillCountsAsPaired() {
        let pane = DevicePane()
        var values = paired
        values.isConnected = false

        pane.show(values)

        // Gated on the pairing, not the connection: a cube in another room has not gone anywhere.
        XCTAssertFalse(isShowing(DevicePane.Identifier.scan, in: pane))
        XCTAssertTrue(isShowing(DevicePane.Identifier.forget, in: pane))
    }

    // MARK: - the folds

    func testTheThreeGroupsStartFolded() {
        // Each is the least urgent thing in its panel, which is why the archive folded them too.
        let pane = DevicePane()

        XCTAssertFalse(pane.moreRow.isExpanded)
        XCTAssertFalse(pane.ledRow.isExpanded)
        XCTAssertFalse(pane.doubleTapRow.isExpanded)
    }

    func testFoldingTakesTheSpaceBackRatherThanLeavingItBehind() {
        // Auto Layout does not care that a view is hidden, so hiding alone leaves the full height behind. This is the
        // check that a folded row is actually shorter than an open one -- the fault it guards against measured 150pt
        // either way and looked like a gap nobody could explain.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()
        let folded = pane.ledRow.frame.height

        pane.ledRow.setExpanded(true)
        pane.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(pane.ledRow.frame.height, folded)
    }

    func testTheWholeHeadingLineFoldsIt() throws {
        // `CLAUDE.md`: the triangle, the words, and the space after them. The words sit inside the button because a
        // click on a label goes up the responder chain to the label's own superview -- a button merely behind a
        // sibling label is never pressed, which shipped once on the Categories headings.
        let pane = DevicePane()
        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(
            view("\(DevicePane.Identifier.led)-heading-button", in: pane) as? NSButton
        )
        button.performClick(nil)

        XCTAssertTrue(pane.ledRow.isExpanded)
    }

    func testAFoldIsReported() throws {
        let pane = DevicePane()
        var reported: [(String, Bool)] = []
        pane.onToggle = { reported.append(($0, $1)) }

        pane.moreRow.setExpanded(true)
        XCTAssertTrue(reported.isEmpty, "setting it directly is the window drawing, not somebody clicking")

        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            view("\(DevicePane.Identifier.more)-heading-button", in: pane) as? NSButton
        )
        button.performClick(nil)

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.0, DevicePane.Identifier.more)
        XCTAssertEqual(reported.first?.1, false, "it was open, so the click shut it")
    }

    // MARK: - the width

    func testThePanelsSpanTheTab() throws {
        // `CLAUDE.md`, for every tab: a panel is inset by the tab's own padding and nothing more. The trap this
        // guards is a stack aligned to its leading edge, where each row is only as wide as its own contents and
        // every value ends up against the widest label instead of the right-hand edge.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        for identifier in [
            DevicePane.Identifier.infoPanel,
            DevicePane.Identifier.settingsPanel,
            DevicePane.Identifier.pairingPanel,
        ] {
            let panel = try XCTUnwrap(view(identifier, in: pane))
            XCTAssertEqual(pane.convert(panel.bounds, from: panel).maxX, 620, accuracy: 0.5, identifier)
        }
    }

    func testTheValuesAreAgainstTheRightHandEdge() throws {
        // The archive's shape: the column of answers runs down the right-hand side rather than following the words.
        // Measured on the alignment rect, not the frame, because AppKit pads some controls beyond what they draw and
        // the padding differs by OS version -- see `Tests/Methods.md`.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        for identifier in [
            DevicePane.Identifier.name,
            DevicePane.Identifier.connection,
            DevicePane.Identifier.battery,
        ] {
            let field = try XCTUnwrap(view(identifier, in: pane))
            let aligned = try XCTUnwrap(field.superview).convert(
                field.alignmentRect(forFrame: field.frame), to: pane
            )
            XCTAssertEqual(aligned.maxX, 600, accuracy: 0.5, identifier)
        }
    }
}

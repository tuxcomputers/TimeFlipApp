@testable import FacetApp
import AppKit
import XCTest

/// Covers the Device tab: that it draws its two sections, that every value on it comes from what it was
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
    private func stepper(_ identifier: String, in root: NSView) -> SteppedNumberField? {
        descendants(of: root).compactMap { $0 as? SteppedNumberField }
            .first { descendants(of: $0).contains { $0.accessibilityIdentifier() == identifier } }
    }

    /// One of a stepped field's two arrows, pressed rather than held. What a *hold* does is `StepperHoldRules`,
    /// tested on its own -- driving it here would mean holding a real mouse button down for several seconds.
    private func arrow(_ direction: Int, of field: SteppedNumberField) throws -> HoldArrow {
        try XCTUnwrap(descendants(of: field).compactMap { $0 as? HoldArrow }.first { $0.direction == direction })
    }

    /// The tab with the gesture on, whatever the seed says.
    ///
    /// **Stated rather than inherited.** These tests are about what the box and the four registers do when it is
    /// switched, not about which way the database seeds it -- and a test that reads the default is a test that breaks
    /// when the default changes, which is exactly what happened when it was seeded off on 2026-08-28.
    private var gestureOn: DevicePane.Values {
        var values = DevicePane.Values.seeded
        values.isDoubleTapEnabled = true
        return values
    }

    private var paired: DevicePane.Values {
        var values = DevicePane.Values.seeded
        values.isCubePaired = true
        values.isCubeConnected = true
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

    func testTheTabHasTwoSections() {
        // **The archive had three -- Info, Settings and TimeFlip -- and this is a deliberate departure from it.**
        // What a cube *is* and how to *get* one were a panel apart, so the name of the paired device sat in one
        // section and the button that pairs it in another, and the status answering "Scan for Devices" was nowhere
        // near the Connection row saying the same thing in other words. One section, named for the cube.
        let pane = DevicePane()

        for title in ["TimeFlip", "Settings"] {
            XCTAssertTrue(labels(of: pane).contains(title), "missing section: \(title)")
        }
        XCTAssertFalse(labels(of: pane).contains("Info"), "Info was merged into TimeFlip, not kept alongside it")
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

    // MARK: - the low-battery flash

    func testTheBatteryRowFlashesRedWhileTheCubeIsFlat() {
        // The Device tab's half of the warning. Red on the coloured phase and back to the ordinary label colour on
        // the other, in step with the menu bar because both are told by the same watch.
        let pane = DevicePane()
        pane.show(paired)
        let battery = try? XCTUnwrap(view(DevicePane.Identifier.battery, in: pane) as? NSTextField)

        pane.showLowBattery(LowBatteryAlert(isBatteryLow: true, isBlinkOn: true))
        XCTAssertEqual(battery?.textColor, .systemRed)

        pane.showLowBattery(LowBatteryAlert(isBatteryLow: true, isBlinkOn: false))
        XCTAssertEqual(battery?.textColor, .labelColor)
    }

    func testARedrawKeepsThePhaseTheFlashIsOn() {
        // A reading arriving redraws the whole tab, and every row on it is greyed or ungreyed together. Without the
        // row being repainted from the warning afterwards, each new reading would knock the flash back to plain text
        // -- which on this hardware is several times a minute.
        let pane = DevicePane()
        pane.show(paired)
        pane.showLowBattery(LowBatteryAlert(isBatteryLow: true, isBlinkOn: true))

        var values = paired
        values.batteryPercent = 4
        pane.show(values)

        let battery = try? XCTUnwrap(view(DevicePane.Identifier.battery, in: pane) as? NSTextField)
        XCTAssertEqual(value(DevicePane.Identifier.battery, in: pane), "4%")
        XCTAssertEqual(battery?.textColor, .systemRed)
    }

    func testAWarningThatHasClearedLeavesTheRowGreyedWithTheRest() {
        // Nothing connected greys the whole Info panel, and the Battery row goes back to sitting with it rather than
        // keeping a colour from a cube that is no longer there.
        let pane = DevicePane()
        pane.show(paired)
        pane.showLowBattery(LowBatteryAlert(isBatteryLow: true, isBlinkOn: true))

        pane.showLowBattery(.none)
        var values = paired
        values.isCubeConnected = false
        values.batteryPercent = nil
        pane.show(values)

        let battery = try? XCTUnwrap(view(DevicePane.Identifier.battery, in: pane) as? NSTextField)
        XCTAssertEqual(value(DevicePane.Identifier.battery, in: pane), "Unknown")
        XCTAssertEqual(battery?.textColor, .secondaryLabelColor)
    }

    func testAutoPauseIsTheSameControlAtTheSameSizeAsTheAppTabsFields() throws {
        // **One width for every stepped field in the window**, and one place it comes from. The Device tab used to
        // pin this one to 90 of its own, which is the width of the *box* -- so the box, its unit and its arrows were
        // being squeezed into the space of the box alone, and the one row on this tab with arrows was the one row
        // whose arrows did not line up with anybody's.
        let device = DevicePane()
        device.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        device.layoutSubtreeIfNeeded()
        let app = AppSettingsPane()
        app.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        app.layoutSubtreeIfNeeded()

        let autoPause = try XCTUnwrap(stepper(DevicePane.Identifier.autoPause, in: device))
        let warning = try XCTUnwrap(stepper(AppSettingsPane.Identifier.batteryWarning, in: app))

        XCTAssertEqual(autoPause.frame.width, warning.frame.width, accuracy: 0.5)
        XCTAssertEqual(autoPause.frame.height, warning.frame.height, accuracy: 0.5)
    }

    func testEveryFieldFollowsTheOneWidthThatDecidesThem() throws {
        // The single value: `SteppedNumberField.Layout.fieldWidth`. Changing it has to move every box in the app,
        // which is only true while nothing outside the control has a width of its own to disagree with.
        let device = DevicePane()
        device.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        device.layoutSubtreeIfNeeded()
        let app = AppSettingsPane()
        app.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        app.layoutSubtreeIfNeeded()

        for (identifier, root) in [
            (DevicePane.Identifier.autoPause, device as NSView),
            (DevicePane.Identifier.ledBrightness, device as NSView),
            (DevicePane.Identifier.ledBlink, device as NSView),
            (AppSettingsPane.Identifier.batteryWarning, app as NSView),
            (AppSettingsPane.Identifier.dailyReset, app as NSView),
            (AppSettingsPane.Identifier.fetchInterval, app as NSView),
            (AppSettingsPane.Identifier.blipTime, app as NSView),
        ] {
            let box = try XCTUnwrap(
                descendants(of: root).first { $0.accessibilityIdentifier() == identifier } as? NSTextField,
                identifier
            )
            XCTAssertEqual(box.frame.width, SteppedNumberField.Layout.fieldWidth, accuracy: 0.5, identifier)
        }
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
        //
        // **It is the field's suffix now rather than part of the value**, the two LED rows having become stepped
        // fields like the rest of the tab. The unit has to be checked where it actually is: a number and a suffix
        // that had drifted apart would read as the right value in the wrong unit, which is the fault this pins.
        XCTAssertEqual(stepper(DevicePane.Identifier.ledBrightness, in: pane)?.value, 70)
        XCTAssertEqual(stepper(DevicePane.Identifier.ledBrightness, in: pane)?.suffix, "%")
        XCTAssertEqual(stepper(DevicePane.Identifier.ledBlink, in: pane)?.value, 20)
        XCTAssertEqual(stepper(DevicePane.Identifier.ledBlink, in: pane)?.suffix, "sec")
        XCTAssertEqual(stepper(DevicePane.Identifier.autoPause, in: pane)?.value, 12)
    }

    func testEveryRowOnTheTabIsTheSameHeight() throws {
        // **The rhythm of the list, and it is the Categories tab's 24.** Worth pinning because it broke silently once
        // and in a way no test noticed: the four double-tap registers were plain labels at 16, so `minimumRowHeight`
        // decided their rows; making them `SteppedNumberField`s at 24 put them over it, the padding added itself
        // twice on top, and those four rows alone came out at 46 while everything around them stayed at 38.
        //
        // A control taller than a row is still allowed to push it -- the padding constraints are inequalities -- so
        // this is not a cap. It is that nothing on this tab should be reaching for one.
        //
        // **The two LED rows are in the list for the same reason the four registers are**: they became stepped
        // fields the same way, and a row that is the only one at a different height is what nobody notices.
        let pane = DevicePane()
        pane.show(paired)
        pane.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        pane.layoutSubtreeIfNeeded()

        for identifier in [
            DevicePane.Identifier.connection,
            DevicePane.Identifier.battery,
            DevicePane.Identifier.autoPause,
            DevicePane.Identifier.ledBrightness,
            DevicePane.Identifier.ledBlink,
            DevicePane.Identifier.doubleTapDisable,
            DevicePane.Identifier.doubleTapThreshold,
            DevicePane.Identifier.doubleTapLimit,
            DevicePane.Identifier.doubleTapLatency,
            DevicePane.Identifier.doubleTapWindow,
        ] {
            let control = try XCTUnwrap(view(identifier, in: pane), identifier)
            // The row is the ancestor that `settled` sized, which is the first plain `NSView` above the control.
            var node: NSView? = control
            while let current = node, !(current.superview is NSStackView) { node = current.superview }
            let row = try XCTUnwrap(node, identifier)

            XCTAssertEqual(
                row.frame.height, DevicePane.Layout.minimumRowHeight, accuracy: 0.5,
                "\(identifier) is \(row.frame.height) where every other row is \(DevicePane.Layout.minimumRowHeight)"
            )
        }
    }

    func testAFoldedGroupsRowsSitAtTheCategoriesTabsPitch() throws {
        // **Height was only half of it.** The rows were made 24 to match the Categories tab and still did not look
        // like it, because that tab puts 8 between its rows and this one put nothing: same height, two thirds of the
        // rhythm. Measured on screen at 64px against Categories' 64px on a 2x display (2026-08-23).
        //
        // Only the folded groups. The lists above them are divided by hairlines and are meant to run together -- a
        // gap there would leave each hairline floating above the row it divides rather than between the two.
        let pane = DevicePane()
        pane.show(paired)
        pane.frame = NSRect(x: 0, y: 0, width: 520, height: 1200)
        pane.layoutSubtreeIfNeeded()

        let centres = try [
            DevicePane.Identifier.doubleTapThreshold,
            DevicePane.Identifier.doubleTapLimit,
            DevicePane.Identifier.doubleTapLatency,
            DevicePane.Identifier.doubleTapWindow,
        ].map { identifier -> CGFloat in
            let control = try XCTUnwrap(view(identifier, in: pane), identifier)
            return control.convert(control.bounds, to: pane).midY
        }

        let expected = DevicePane.Layout.minimumRowHeight + DevicePane.Layout.rowSpacing
        for (above, below) in zip(centres, centres.dropFirst()) {
            XCTAssertEqual(abs(below - above), expected, accuracy: 0.5)
        }
        XCTAssertEqual(expected, 32, "the Categories tab's row plus its gap")
    }

    func testTheGapIsTheCategoriesTabsOwnNumber() {
        // Read from there rather than repeated, so moving that tab's rhythm moves this one with it.
        XCTAssertEqual(DevicePane.Layout.rowSpacing, CategoryTable.Layout.rowSpacing)
    }

    func testTheTabSitsAtTheCategoriesTabsRowHeight() {
        // The number itself, stated once so that moving it is a decision rather than a drift. The two tabs separate
        // their rows differently -- Categories with stack spacing, this one with hairlines and none -- so the height
        // is the part they share.
        XCTAssertEqual(DevicePane.Layout.minimumRowHeight, 24)
    }

    func testTheFourRegistersAreSteppedFields() throws {
        // The same control the rest of the app uses, so an arrow steps them and a script can drive them by name.
        // They were read-only labels until the registers could actually be sent.
        let pane = DevicePane()
        var values = DevicePane.Values.seeded
        values.doubleTapThreshold = 90
        values.doubleTapWindow = 50
        pane.show(values)

        let threshold = try XCTUnwrap(stepper(DevicePane.Identifier.doubleTapThreshold, in: pane))
        let window = try XCTUnwrap(stepper(DevicePane.Identifier.doubleTapWindow, in: pane))

        XCTAssertEqual(threshold.value, 90)
        XCTAssertEqual(window.value, 50)
    }

    func testTheRegistersRunTheWholeByte() throws {
        // 0 to 255 is the register, not a judgement about useful values -- and 0 in particular has to be reachable on
        // Window, that being how the gesture is turned off.
        let pane = DevicePane()
        pane.show(.seeded)
        let window = try XCTUnwrap(stepper(DevicePane.Identifier.doubleTapWindow, in: pane))

        window.value = 0
        XCTAssertEqual(window.value, 0)
        window.value = 255
        XCTAssertEqual(window.value, 255)
    }

    func testTheParametersComeOffTheFieldsRatherThanTheLastShownValues() throws {
        // A held arrow moves the field several times a second and nothing writes those back to `values`, so a command
        // built from `values` would carry the number the row opened with.
        let pane = DevicePane()
        var values = DevicePane.Values.seeded
        values.doubleTapLatency = 50
        pane.show(values)
        let latency = try XCTUnwrap(stepper(DevicePane.Identifier.doubleTapLatency, in: pane))

        latency.value = 77

        XCTAssertEqual(pane.doubleTapParameters.latency, 77)
    }

    func testMovingARegisterSaysSo() throws {
        // The pane reports that a value moved and nothing else: when to act on it is the window's, which debounces.
        let pane = DevicePane()
        pane.show(.seeded)
        var changes = 0
        pane.onDoubleTapValueChanged = { changes += 1 }
        let limit = try XCTUnwrap(stepper(DevicePane.Identifier.doubleTapLimit, in: pane))

        limit.onChange?(21)

        XCTAssertEqual(changes, 1)
    }

    func testTheBoxReportsWhichWayRoundItIs() throws {
        // It says "Disable", so ticked is the gesture being unwanted. Reported the right way round once, here, rather
        // than at every reader of it.
        let pane = DevicePane()
        pane.show(gestureOn)
        var reported: [Bool] = []
        pane.onDoubleTapEnabledChanged = { reported.append($0) }
        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)

        // `performClick` toggles the box and then fires the action, so the state is not set here: doing both would
        // report the value it had on the way past rather than the one it landed on.
        box.performClick(nil)
        box.performClick(nil)

        XCTAssertEqual(box.state, .off, "back where it started after two clicks")
        XCTAssertEqual(reported, [false, true], "ticked means off, unticked means on")
    }

    func testTickingDisableTakesTheFourRegistersOutOfUse() throws {
        // With the gesture off there is nothing for the four to describe: `DoubleTapRules.asSent` sends Window as 0
        // whatever they hold, so a live field would take a number and then not send it.
        let pane = DevicePane()
        pane.show(gestureOn)
        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)

        box.performClick(nil)

        for identifier in [
            DevicePane.Identifier.doubleTapThreshold,
            DevicePane.Identifier.doubleTapLimit,
            DevicePane.Identifier.doubleTapLatency,
            DevicePane.Identifier.doubleTapWindow,
        ] {
            XCTAssertEqual(stepper(identifier, in: pane)?.isEnabled, false, identifier)
        }
    }

    func testUntickingItGivesThemBack() throws {
        let pane = DevicePane()
        pane.show(gestureOn)
        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)

        box.performClick(nil)
        box.performClick(nil)

        for identifier in [
            DevicePane.Identifier.doubleTapThreshold,
            DevicePane.Identifier.doubleTapLimit,
            DevicePane.Identifier.doubleTapLatency,
            DevicePane.Identifier.doubleTapWindow,
        ] {
            XCTAssertEqual(stepper(identifier, in: pane)?.isEnabled, true, identifier)
        }
    }

    func testTheDeadFieldsKeepTheirNumbers() throws {
        // The values are what the gesture goes back to when somebody unticks the box, and they are still what the
        // table holds -- so emptying them would lose a setting to a display decision.
        let pane = DevicePane()
        var values = DevicePane.Values.seeded
        values.doubleTapThreshold = 90
        values.doubleTapWindow = 50
        pane.show(values)
        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)

        box.performClick(nil)

        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapThreshold, in: pane)?.value, 90)
        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapWindow, in: pane)?.value, 50)
        XCTAssertEqual(pane.doubleTapParameters, DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 50))
    }

    func testATabDrawnWithTheGestureOffOpensWithTheFieldsDead() throws {
        // The other way into the same state: the box is not clicked here, the table simply says the gesture is off.
        // Both paths go through one method, so the fields cannot come to disagree with the box beside them.
        let pane = DevicePane()
        var values = DevicePane.Values.seeded
        values.isDoubleTapEnabled = false

        pane.show(values)

        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)
        XCTAssertEqual(box.state, .on)
        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapThreshold, in: pane)?.isEnabled, false)
    }

    func testARefusedWriteTakesTheFieldsBackWithTheBox() throws {
        // The correction path moves both, for the same reason the click does: a box put back to ticked with four live
        // fields under it is the two controls answering one question differently.
        let pane = DevicePane()
        pane.show(.seeded)

        pane.showDoubleTapEnabled(false)

        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapWindow, in: pane)?.isEnabled, false)

        pane.showDoubleTapEnabled(true)

        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapWindow, in: pane)?.isEnabled, true)
    }

    func testARefusedWriteCanPutTheBoxBackWithoutSayingSo() throws {
        // The correction path. `state` is assigned rather than the action fired, so putting the box back cannot be
        // mistaken for somebody ticking it and start a second write.
        let pane = DevicePane()
        pane.show(.seeded)
        var reported = 0
        pane.onDoubleTapEnabledChanged = { _ in reported += 1 }
        let box = try XCTUnwrap(view(DevicePane.Identifier.doubleTapDisable, in: pane) as? NSButton)

        pane.showDoubleTapEnabled(false)

        XCTAssertEqual(box.state, .on, "ticked, the gesture being off")
        XCTAssertEqual(reported, 0, "and nobody was told, because nobody did it")
    }

    func testARefusedWriteCanPutTheFourFieldsBackWithoutSayingSo() throws {
        // The mirror of the box's correction path. `SteppedNumberField.value` is assigned rather than the arrow
        // pressed, so putting a field back cannot be mistaken for somebody moving it and start a second write.
        let pane = DevicePane()
        pane.show(.seeded)
        var changes = 0
        pane.onDoubleTapValueChanged = { changes += 1 }

        pane.showDoubleTapValues(DoubleTapParameters(threshold: 200, limit: 45, latency: 34, window: 0))

        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapThreshold, in: pane)?.value, 200)
        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapLimit, in: pane)?.value, 45)
        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapLatency, in: pane)?.value, 34)
        XCTAssertEqual(stepper(DevicePane.Identifier.doubleTapWindow, in: pane)?.value, 0)
        XCTAssertEqual(changes, 0, "and nobody was told, because nobody did it")
    }

    // MARK: - the LED fields

    func testTheLEDFieldsTakeTheRangesTheCommandsAccept() throws {
        // The ranges are `DeviceCommandRules`, not numbers written out again here, so a field cannot come to accept
        // something the command would then quietly change. Stepping down from the seed is what shows it: brightness
        // stops at 1 and the blink period at 5, neither of them at 0.
        let pane = DevicePane()
        var values = DevicePane.Values.seeded
        values.ledBrightnessPercent = DeviceCommandRules.brightnessRange.lowerBound
        values.ledBlinkSeconds = DeviceCommandRules.blinkRange.lowerBound
        pane.show(values)

        try arrow(-1, of: XCTUnwrap(stepper(DevicePane.Identifier.ledBrightness, in: pane))).performClick(nil)
        try arrow(-1, of: XCTUnwrap(stepper(DevicePane.Identifier.ledBlink, in: pane))).performClick(nil)

        XCTAssertEqual(pane.ledBrightnessPercent, 1, "brightness has no 0")
        XCTAssertEqual(pane.ledBlinkSeconds, 5, "and neither has the blink period")
    }

    func testMovingOneLEDArrowReportsThatOneAndNotTheOther() throws {
        // **Two settings, two commands, two reports.** Brightness goes as 0x09 and the blink period as 0x0A, so a
        // cube told about one has been told nothing about the other -- and the window debounces them separately for
        // the same reason. One callback firing for both would put that back together again.
        let pane = DevicePane()
        pane.show(.seeded)
        var brightness = 0
        var blink = 0
        pane.onLEDBrightnessChanged = { brightness += 1 }
        pane.onLEDBlinkChanged = { blink += 1 }

        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.ledBrightness, in: pane))).performClick(nil)

        XCTAssertEqual(pane.ledBrightnessPercent, 51)
        XCTAssertEqual(brightness, 1)
        XCTAssertEqual(blink, 0, "the blink period was not touched")
    }

    func testTheLEDValuesAreReadOffTheFieldsRatherThanOffWhatWasLastShown() throws {
        // What a command is built from. A held arrow moves the field several times a second and nothing writes those
        // back to `values` until one lands, so reading `values` would send the number the row opened with.
        let pane = DevicePane()
        pane.show(.seeded)

        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.ledBrightness, in: pane))).performClick(nil)

        XCTAssertEqual(pane.ledBrightnessPercent, 51, "what is on screen")
        XCTAssertEqual(pane.values.ledBrightnessPercent, 50, "and what was last shown, still")
    }

    func testARefusedLEDWriteCanPutAFieldBackWithoutSayingSo() throws {
        // The mirror of the registers correction path, and for the same reason: `SteppedNumberField.value` is
        // assigned rather than the arrow pressed, so putting a field back cannot be mistaken for somebody moving it
        // and start a second write.
        let pane = DevicePane()
        pane.show(.seeded)
        var changes = 0
        pane.onLEDBrightnessChanged = { changes += 1 }

        pane.showLEDBrightness(30)

        XCTAssertEqual(stepper(DevicePane.Identifier.ledBrightness, in: pane)?.value, 30)
        XCTAssertEqual(pane.values.ledBrightnessPercent, 30, "and `values` moved with it, so the next read agrees")
        XCTAssertEqual(changes, 0, "and nobody was told, because nobody did it")
    }

    func testAWriteThatLandedIsRecordedWithoutTouchingTheField() throws {
        // **The race this exists to lose.** A command is out with 51 on it, somebody steps the field on to 52 while
        // it is in flight, and the cube then says yes to the 51. Writing 51 back into the field would take 52 off the
        // screen -- and the next debounced write reads the field, so it would send 51 again and the 52 nobody refused
        // would be gone. What landed is recorded; what is on screen is left where its owner put it.
        let pane = DevicePane()
        pane.show(.seeded)
        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.ledBrightness, in: pane))).performClick(nil)
        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.ledBrightness, in: pane))).performClick(nil)

        pane.recordLEDBrightness(51)

        XCTAssertEqual(pane.ledBrightnessPercent, 52, "still what was stepped to")
        XCTAssertEqual(pane.values.ledBrightnessPercent, 51, "and what landed is what was recorded")
    }

    func testPuttingOneLEDFieldBackLeavesTheOtherAlone() {
        // A failure puts back the setting that failed. The other may have an edit of its own still waiting on its
        // own debounce, and taking that out from under somebody would lose a change nothing had refused.
        let pane = DevicePane()
        pane.show(.seeded)

        pane.showLEDBrightness(30)

        XCTAssertEqual(pane.ledBlinkSeconds, 15, "untouched")
    }

    // MARK: - the Auto-pause field

    func testMovingTheAutoPauseArrowReportsItAndNothingElse() throws {
        // **Its own report, like the two LED fields.** The window schedules a debounce per report and each scheduling
        // displaces the last, so a report covering more than one setting would drop whichever write was still waiting.
        let pane = DevicePane()
        pane.show(.seeded)
        var autoPause = 0
        var brightness = 0
        pane.onAutoPauseChanged = { autoPause += 1 }
        pane.onLEDBrightnessChanged = { brightness += 1 }

        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.autoPause, in: pane))).performClick(nil)

        XCTAssertEqual(pane.autoPauseMinutes, 1)
        XCTAssertEqual(autoPause, 1)
        XCTAssertEqual(brightness, 0, "the LED was not touched")
    }

    func testTheAutoPauseValueIsReadOffTheFieldRatherThanOffWhatWasLastShown() throws {
        // What the write carries. A held arrow moves the field several times a second and nothing writes those back
        // to `values` until one lands, so reading `values` would store the number the row opened with.
        let pane = DevicePane()
        pane.show(.seeded)

        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.autoPause, in: pane))).performClick(nil)

        XCTAssertEqual(pane.autoPauseMinutes, 1, "what is on screen")
        XCTAssertEqual(pane.values.autoPauseMinutes, 0, "and what was last shown, still")
    }

    func testARefusedAutoPauseWriteCanPutTheFieldBackWithoutSayingSo() throws {
        // The mirror of the LED correction path, and for the same reason: `SteppedNumberField.value` is assigned
        // rather than the arrow pressed, so putting the field back cannot be mistaken for somebody moving it and
        // start a second write on top of the one that just failed.
        let pane = DevicePane()
        pane.show(.seeded)
        var changes = 0
        pane.onAutoPauseChanged = { changes += 1 }

        pane.showAutoPause(15)

        XCTAssertEqual(stepper(DevicePane.Identifier.autoPause, in: pane)?.value, 15)
        XCTAssertEqual(pane.values.autoPauseMinutes, 15, "and `values` moved with it, so the next read agrees")
        XCTAssertEqual(changes, 0, "and nobody was told, because nobody did it")
    }

    func testAnAutoPauseWriteThatLandedIsRecordedWithoutTouchingTheField() throws {
        // The same race the LED path loses on purpose: a write is being made with 1 on it, somebody steps the field
        // on to 2 while it is, and writing 1 back would take the 2 off the screen and store it again on the next tick.
        let pane = DevicePane()
        pane.show(.seeded)
        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.autoPause, in: pane))).performClick(nil)
        try arrow(1, of: XCTUnwrap(stepper(DevicePane.Identifier.autoPause, in: pane))).performClick(nil)

        pane.recordAutoPause(1)

        XCTAssertEqual(pane.autoPauseMinutes, 2, "still what was stepped to")
        XCTAssertEqual(pane.values.autoPauseMinutes, 1, "and what landed is what was recorded")
    }

    func testTheCorrectedFieldsAreWhatTheNextReadOfThePaneGives() {
        // `values` is what `doubleTapParameters` falls back to and what the next write carries, so a correction that
        // moved the fields and left it behind would send the refused numbers again on the following change.
        let pane = DevicePane()
        pane.show(.seeded)

        pane.showDoubleTapValues(DoubleTapParameters(threshold: 200, limit: 45, latency: 34, window: 0))

        XCTAssertEqual(pane.values.doubleTapThreshold, 200)
        XCTAssertEqual(pane.values.doubleTapLimit, 45)
        XCTAssertEqual(pane.values.doubleTapLatency, 34)
        XCTAssertEqual(pane.values.doubleTapWindow, 0)
        XCTAssertEqual(
            pane.doubleTapParameters,
            DoubleTapParameters(threshold: 200, limit: 45, latency: 34, window: 0)
        )
    }

    func testAFieldAlreadyOnTheValueIsLeftAlone() throws {
        // This runs on the way out of a write that took, as well as one that did not, so it lands on fields already
        // holding these numbers. Assigning `value` replaces the text in the field, which would take it out from under
        // whoever is typing -- so a field already on the value is not touched.
        let pane = DevicePane()
        pane.show(.seeded)
        let field = try XCTUnwrap(stepper(DevicePane.Identifier.doubleTapThreshold, in: pane))
        let text = try XCTUnwrap(descendants(of: field).compactMap { $0 as? NSTextField }.first)
        text.stringValue = "9"

        pane.showDoubleTapValues(DoubleTapParameters(threshold: 90, limit: 20, latency: 50, window: 50))

        XCTAssertEqual(text.stringValue, "9", "the field is already on 90, so it was not rebuilt")
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
        pane.show(gestureOn)
        XCTAssertEqual(box.state, .off, "and clear again when the gesture is on")
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
        values.isCubeConnected = false

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
        values.isCubeConnected = false

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
        values.isCubeConnected = false

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
            DevicePane.Identifier.timeflipPanel,
            DevicePane.Identifier.settingsPanel,
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
            // 640 wide, less the tab's own padding at each side and the panel's inset inside that. Derived rather
            // than the 600 it used to be written as: the numbers moved when the three tabs were put on one set, and
            // a literal here would have had to be found by running the test rather than by reading it.
            let expected = 640 - SettingsMetrics.tabPadding - SettingsMetrics.panelPadding
            XCTAssertEqual(aligned.maxX, expected, accuracy: 0.5, identifier)
        }
    }

    // MARK: - the readings and the way to get a cube are one section

    /// Every identifier under one section, for asking which section something ended up in.
    private func identifiers(under section: NSView) -> [String] {
        descendants(of: section).map { $0.accessibilityIdentifier() }.filter { !$0.isEmpty }
    }

    func testTheReadingsAndTheScanControlsAreOneSection() {
        // **This is the merge, asserted rather than assumed.** Info and TimeFlip were separate sections until
        // 2026-08-22, which put `Name: Not paired` a panel away from the button that pairs it and left the scan
        // status nowhere near the Connection row saying the same thing in other words.
        let pane = DevicePane()

        let inside = identifiers(under: pane.timeflipSection)
        for identifier in [
            DevicePane.Identifier.name,
            DevicePane.Identifier.connection,
            DevicePane.Identifier.battery,
            DevicePane.Identifier.more,
            DevicePane.Identifier.scan,
            DevicePane.Identifier.scanAll,
            DevicePane.Identifier.scanStatus,
        ] {
            XCTAssertTrue(inside.contains(identifier), "\(identifier) is not in the TimeFlip section")
        }
    }

    func testNoneOfThatLandedInSettings() {
        // The other half, because "is in TimeFlip" would also be true of a view that had been added to both or to
        // neither and was simply found by a search that reached the whole pane.
        let pane = DevicePane()

        let inside = identifiers(under: pane.settingsSection)
        for identifier in [DevicePane.Identifier.name, DevicePane.Identifier.scan] {
            XCTAssertFalse(inside.contains(identifier), "\(identifier) should not be in Settings")
        }
        XCTAssertTrue(inside.contains(DevicePane.Identifier.autoPause), "precondition: this is the Settings section")
    }

    func testTheScanControlsComeAfterMore() {
        // **The order somebody reads the section in**: what the app knows about the cube, then the thing to press
        // about it. Measured down the screen rather than by subview order, since the two can disagree and it is the
        // screen that somebody reads.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        guard let name = view(DevicePane.Identifier.name, in: pane),
              let more = view(DevicePane.Identifier.more, in: pane),
              let scan = view(DevicePane.Identifier.scan, in: pane) else {
            return XCTFail("the three rows this is about are not all on the tab")
        }
        // **AppKit's y grows upward unless a view is flipped, so "further down the screen" is not one comparison.**
        // This pane is unflipped, where the row nearer the top has the *larger* minY -- the reverse of the obvious
        // reading, and it inverts silently: written the other way round this test failed against a tab that was
        // perfectly correct. Asked of the view rather than hard-coded, so flipping the pane later cannot quietly
        // turn this into its own opposite.
        func isAbove(_ upper: NSView, _ lower: NSView) -> Bool {
            let upperY = pane.convert(upper.bounds, from: upper).minY
            let lowerY = pane.convert(lower.bounds, from: lower).minY
            return pane.isFlipped ? upperY < lowerY : upperY > lowerY
        }
        XCTAssertTrue(isAbove(name, more), "the readings come first")
        XCTAssertTrue(isAbove(more, scan), "and the controls come last")
    }

    func testFoldingTheSectionTakesTheScanControlsWithTheReadings() {
        // They are rows of one section now rather than of two, so one fold takes both. Before the merge this was two
        // separate folds, and a check that only looked at the readings would still have passed.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        pane.timeflipSection.setExpanded(false)
        pane.layoutSubtreeIfNeeded()

        for identifier in [DevicePane.Identifier.name, DevicePane.Identifier.scan] {
            let view = view(identifier, in: pane)
            XCTAssertTrue(view?.isHiddenOrHasHiddenAncestor ?? false, "\(identifier) is still on show")
        }
    }

    // MARK: - the two sections fold

    private func sections(of pane: DevicePane) -> [PanelSection] {
        [pane.timeflipSection, pane.settingsSection]
    }

    func testBothSectionsStartOpen() {
        // **The App tab's answer, not the Categories tab's.** These three are the whole of the tab, so opening it
        // folded would show three headings and nothing to read. TimeFlip stays open in particular because the scan
        // results appear inside it, and a folded section would hide the answer to the thing somebody just pressed.
        let pane = DevicePane()

        for section in sections(of: pane) {
            XCTAssertTrue(section.isExpanded, section.title)
        }
    }

    func testFoldingASectionTakesTheSpaceBack() {
        // Auto Layout does not care that a view is hidden, so hiding the rows alone leaves their full height behind
        // and a folded section measures exactly as tall as an open one.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()
        let open = pane.settingsSection.frame.height

        pane.settingsSection.setExpanded(false)
        pane.layoutSubtreeIfNeeded()

        XCTAssertLessThan(pane.settingsSection.frame.height, open)
    }

    func testEachHeadingSitsOnItsOwnPanel() throws {
        // `CLAUDE.md`: a collapsible group's heading is the first row of the panel it folds, not a caption floating
        // above it. This is the measurement that tells the two apart.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        for identifier in [
            DevicePane.Identifier.timeflipSection,
            DevicePane.Identifier.settingsSection,
        ] {
            let panel = try XCTUnwrap(view("\(identifier)-panel", in: pane), identifier)
            let heading = try XCTUnwrap(view("\(identifier)-heading", in: pane), identifier)
            XCTAssertTrue(
                pane.convert(panel.bounds, from: panel).contains(pane.convert(heading.bounds, from: heading)),
                identifier
            )
        }
    }

    func testTheWholeHeadingLineFolds() throws {
        // The triangle, the words, and the space after them to the end of the row. A triangle alone is a small
        // target for a gesture the heading beside it is obviously about.
        let pane = DevicePane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        pane.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(
            view("\(DevicePane.Identifier.timeflipSection)-heading-button", in: pane)
        )
        let panel = try XCTUnwrap(view("\(DevicePane.Identifier.timeflipSection)-panel", in: pane))
        XCTAssertEqual(button.frame.width, panel.frame.width, accuracy: 0.5)
    }

    func testPressingASectionHeadingIsReportedByName() throws {
        // Nothing stores a fold, so the row the window writes is the only record it happened -- and the identifier
        // is what tells a scripted check which of the three it was.
        let pane = DevicePane()
        var reported: [(String, Bool)] = []
        pane.onToggle = { reported.append(($0, $1)) }

        pane.settingsSection.setExpanded(false)
        XCTAssertTrue(reported.isEmpty, "setting it directly is the window drawing, not somebody clicking")

        let window = OffscreenWindow.host(pane)
        defer { window.close() }
        pane.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            view("\(DevicePane.Identifier.settingsSection)-heading-button", in: pane) as? NSButton
        )
        button.performClick(nil)

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.0, DevicePane.Identifier.settingsSection)
        XCTAssertEqual(reported.first?.1, true, "it was shut, so the click opened it")
    }

    // MARK: - a fold inside a fold

    func testFoldingASectionLeavesTheRowInsideItAlone() {
        // **The case this tab has and the others do not.** `More` is built folded inside an `Info` built open, so
        // the two levels disagree by design. A section that rebuilt its contents on a fold would lose whatever the
        // inner row was left as, and the loss would only show on the second look.
        let pane = DevicePane()
        pane.moreRow.setExpanded(true)

        pane.timeflipSection.setExpanded(false)
        pane.timeflipSection.setExpanded(true)

        XCTAssertTrue(pane.moreRow.isExpanded, "opened by hand, so it is still open")
    }

    func testResettingPutsBothLevelsBackToTheirOwnDefaults() {
        // The two defaults are opposite, which is the whole point of each holding its own rather than the reset
        // naming one: a reset that put everything open would be exactly as wrong as one that folded everything.
        let pane = DevicePane()
        pane.timeflipSection.setExpanded(false)
        pane.moreRow.setExpanded(true)

        let folding: [CollapsibleSection] = [pane.timeflipSection, pane.moreRow]
        for section in folding {
            section.restoreDefaultState()
        }

        XCTAssertTrue(pane.timeflipSection.isExpanded, "a section is built open")
        XCTAssertFalse(pane.moreRow.isExpanded, "and More is built folded")
    }
}

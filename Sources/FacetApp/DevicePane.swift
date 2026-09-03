import AppKit

/// The Device tab: what the app knows about a cube, the way to go and find one, and the settings that live on one.
///
/// Two sections:
///
/// - **TimeFlip**, which is the cube itself: what the app knows about it, and what to press to get one. Its rows say
///   plainly when the answer is that it knows nothing (`DeviceInfoRules`, where the wording and the three different
///   kinds of "no device" live), and under them sit the controls that change with the state -- Scan while there is
///   nothing paired, Forget and Reset once there is (`DevicePairingRules.showsScanControls`).
/// - **Settings**, which are what the cube is set to: stored here and sent to it on connect, so they are readable and
///   meaningful with no cube present, which is why they are drawn rather than hidden. **Every row here writes.** All
///   but the first send to the cube, record what the cube took, and put themselves back with an alert if either
///   refuses, so a row is never left showing a number that reached neither. Auto-pause and the four double-tap
///   registers are read back off the cube before they are believed; the two LED values are not, the vendor spec
///   defining no read-back for either, so for those the write is genuinely all there is.
///
///   **The first two rows are the exception to how they are written, and only that: no command carries either.**
///   Pause on lock says what the app does to the cube when it locks it (`CubeLock.lock` reads `pause_on_lock` at
///   the step that needs it), and Battery warning at says what the app treats as flat (`LowBatteryWatch` reads
///   `low_battery_level` every time it judges a reading), so for both the whole of writing it is the table taking
///   it. They are about the cube all the same, which is what this section is, and they were on the App tab until
///   2026-09-03 because the app is what reads them.
///
///   **The whole section is dead while no cube is connected**, that row included, and `drawSettingsGate` is where
///   that is decided for all of them at once. It is a section about a cube, so it answers the question about a cube
///   the same way in every row of it; a sixth row staying live because of how it happens to be stored would be
///   asking somebody reading the section to work out which kind each row is.
///
/// **These were three sections until 2026-08-22**, with the readings under "Info" and the scan under a "TimeFlip" of
/// its own. One section, because the split asked somebody to know that what a cube *is* and how to *get* one are
/// different subjects: the name of the paired device and the button that pairs it were a panel apart, and the status
/// answering "Scan for Devices" sat nowhere near the Connection row saying the same thing in other words.
///
/// **The layout is the previous app's**, measured off `image/preferences-device.png` and its final source rather than
/// recalled: a heading above a rounded panel, labels down the left, values and controls pinned to the right-hand
/// edge. It is `AppSettingsPane`'s shape too, and deliberately so -- these are the two tabs made of settings rows, and
/// two tabs of rows that sat at different rhythms would read as two windows.
@MainActor
final class DevicePane: NSView {
    enum Identifier {
        static let timeflipSection = "device-timeflip-section"
        static let timeflipPanel = "device-timeflip-section-panel"
        static let name = "device-name"
        static let connection = "device-connection"
        static let battery = "device-battery"
        static let more = "device-more"
        static let manufacturer = "device-manufacturer"
        static let model = "device-model"
        static let hardware = "device-hardware"
        static let firmware = "device-firmware"

        static let settingsSection = "device-settings-section"
        static let settingsPanel = "device-settings-section-panel"
        static let pauseOnLock = "device-pause-on-lock"
        static let batteryWarning = "device-battery-warning"
        static let autoPause = "device-auto-pause"
        static let led = "device-led"
        static let ledBrightness = "device-led-brightness"
        static let ledBlink = "device-led-blink"
        static let doubleTap = "device-double-tap"
        static let doubleTapDisable = "device-double-tap-disable"
        static let doubleTapThreshold = "device-double-tap-threshold"
        static let doubleTapLimit = "device-double-tap-limit"
        static let doubleTapLatency = "device-double-tap-latency"
        static let doubleTapWindow = "device-double-tap-window"

        static let scan = "device-scan"
        static let scanAll = "device-scan-all"
        static let scanStatus = "device-scan-status"
        static let forget = "device-forget"
        static let reset = "device-reset"
        /// One per listed device, suffixed with the peripheral identifier.
        static func scanResult(_ id: UUID) -> String { "device-scan-result-\(id.uuidString)" }
    }

    /// Shared with `DisclosureRow`, so a folding row sits at the same rhythm as the plain rows around it.
    enum Layout {
        /// **Every number here comes from `SettingsMetrics`**, which is where the look of a tab is decided. This tab
        /// used to carry its own copies and had drifted the other way from the App tab: rows at the right height
        /// with no gap at all between them, which reads as a tighter list than the Categories tab rather than the
        /// same one.
        static let padding = SettingsMetrics.tabPadding
        static let headingSpacing = SettingsMetrics.headingSpacing
        static let sectionSpacing = SettingsMetrics.sectionSpacing
        /// Inside a row, to the left of a label and to the right of a value. **Nothing**: the panel insets the list
        /// now, exactly as it does on the Categories tab, so a row inset of its own would indent every row twice
        /// over. It was 20 while this tab drew its own hairlines and had to place their ends.
        static let rowInset: CGFloat = 0

        /// **Nothing, so a row is exactly `minimumRowHeight` unless its own content is taller.** It was 11, which is
        /// what made a row holding a `SteppedNumberField` come out at 46: the field is 24 and the padding added
        /// itself twice on top. That was invisible while these rows held plain labels at 16 and the minimum decided
        /// them, and became visible the moment the double-tap registers became fields somebody could step.
        ///
        /// **Still an inequality wherever it is used**, so this being zero does not stop content taller than the row
        /// pushing the row taller. What it stops is padding deciding a height the list has already decided.
        static let rowPadding: CGFloat = 0

        /// How wide the Name row's editable cell is, which is the App tab's calendar name to the point: they are the
        /// same control doing the same job in the same shape of row, and two widths would be two answers to how wide
        /// a name is. It is a fixed width because `EditableNameCell` swaps a label for a field, and a cell sized to
        /// its label would change width as the field appeared.
        static let nameWidth: CGFloat = 240

        /// The one row that keeps breathing space, and it is not a list row: the scan controls are buttons, taller
        /// than any row here, and flush against the edges they read as a toolbar rather than as part of the panel.
        static let controlRowPadding: CGFloat = 11

        /// The gap between one row and the next, which is what divides them now that nothing is drawn between them.
        /// **Every list on this tab takes it**, where before only the folded ones did and the top-level rows ran
        /// together.
        static let rowSpacing = SettingsMetrics.rowSpacing

        /// The least a row can be. Shared with `DisclosureRow`, which only this tab builds, so a folding heading
        /// sits at the same rhythm as the plain rows around it.
        static let minimumRowHeight = SettingsMetrics.rowHeight
    }

    /// What the tables say, at the moment the tab was shown.
    ///
    /// **Every field is what is stored**, in the unit it is stored in, so nothing here is a second opinion about a
    /// row. The optional ones are optional because absence is a state the table can be in: the four More details are
    /// read off the cube on each login and are absent until one has answered for them, and the battery level has no
    /// store at all and arrives `nil` every time -- a remembered level being a number that was true at some moment
    /// nobody can name, which is exactly what a manufacturer string is not.
    struct Values: Equatable {
        var isCubePaired: Bool
        var isCubeConnected: Bool
        var deviceName: String?
        var batteryPercent: Int?
        var manufacturer: String?
        var model: String?
        var hardware: String?
        var firmware: String?
        var pausesOnLock: Bool
        var batteryWarningPercent: Int
        var autoPauseMinutes: Int
        var ledBrightnessPercent: Int
        var ledBlinkSeconds: Int
        var isDoubleTapEnabled: Bool
        var doubleTapThreshold: Int
        var doubleTapLimit: Int
        var doubleTapLatency: Int
        var doubleTapWindow: Int

        /// What a database missing every one of these rows would give, and the only guess made anywhere on this tab.
        /// The numbers are `database/011_setting.sql`'s own seeds, so a pane nobody has read into shows what a fresh
        /// database holds rather than zeroes that mean nothing.
        static let seeded = Values(
            isCubePaired: false,
            isCubeConnected: false,
            deviceName: nil,
            batteryPercent: nil,
            manufacturer: nil,
            model: nil,
            hardware: nil,
            firmware: nil,
            // **On, matching `database/011_setting.sql`.** A cube left locked and still counting against whatever
            // face happens to be up is the thing locking it was meant to stop.
            pausesOnLock: true,
            batteryWarningPercent: BatteryRules.defaultWarningPercent,
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            ledBlinkSeconds: 15,
            // **Off, matching `database/011_setting.sql`.** The gesture pauses the cube on any knock hard enough,
            // which includes one through the desk it is sitting on, so a cube nobody has asked for it should not be
            // stopping the clock.
            isDoubleTapEnabled: false,
            doubleTapThreshold: 90,
            doubleTapLimit: 20,
            doubleTapLatency: 50,
            doubleTapWindow: 50
        )
    }

    private(set) var values: Values = .seeded

    /// What a device setting says when there is no cube to be told about it.
    ///
    /// **One string rather than one per control**, so the rows that gain the same gate cannot come to explain it
    /// differently. It names the device rather than the row, because what is wrong is not the value somebody was
    /// reaching for.
    private static let notConnectedHelp = "The TimeFlip is not connected, so this cannot be changed."

    /// What the Name row says when it will not open. **The words are here and the decision is not**, which is the
    /// split every rules type on this tab keeps -- and the not-connected case deliberately reads the same sentence
    /// the settings rows do, since it is the same fact about the same cube said in the same place.
    private static func renameHelp(_ refusal: DeviceNameRules.RenameRefusal) -> String {
        switch refusal {
        case .notPaired: return "No TimeFlip is paired, so there is no name to change."
        case .notConnected: return notConnectedHelp
        case .nameUnknown: return "The TimeFlip has not said what it is called yet, so there is nothing to rename."
        }
    }

    /// Which half of the low-battery flash the Battery row is currently drawing. See `showLowBattery`.
    private var lowBattery = LowBatteryAlert.none

    /// The Name row, which is a control rather than a reading: the cube's name is the one thing on this tab the app
    /// can change about *what a cube is* rather than what it is set to. Exposed so a test can ask whether it will
    /// open without a window on screen.
    private(set) var nameCell: EditableNameCell!
    private var connectionValue: NSTextField!
    private var batteryValue: NSTextField!
    private var manufacturerValue: NSTextField!
    private var modelValue: NSTextField!
    private var hardwareValue: NSTextField!
    private var firmwareValue: NSTextField!
    private var pauseOnLockBox: NSButton!
    private var batteryWarningField: SteppedNumberField!
    private var autoPauseField: SteppedNumberField!
    private var ledBrightnessField: SteppedNumberField!
    private var ledBlinkField: SteppedNumberField!
    private var doubleTapDisableBox: NSButton!
    private var doubleTapValues: [String: SteppedNumberField] = [:]

    /// The scan's own controls and its results, held because they are redrawn as the radio answers rather than
    /// built once. **The list itself is not held here**: what has been found is the scanner's, and this draws
    /// whatever it is last handed, so the tab cannot come to show a device the scan no longer has.
    private var scanButton: NSButton!
    private var scanAllBox: NSButton!
    private var scanStatusLabel: NSTextField!
    /// What a paired app gets instead of the scan controls. Held in one stack so the swap is one thing being shown or
    /// hidden rather than two that could disagree about which state the section is in.
    private var scanControls: NSStackView!
    private var pairedControls: NSStackView!
    private var forgetButton: NSButton!
    private var resetButton: NSButton!
    private var scanResults: NSStackView!
    /// The rows the scan produced, held only so they can be greyed together while one of them is being reached.
    private var deviceButtons: [NSButton] = []

    /// Pressed when the scan button is clicked, carrying whether **All Devices** is ticked at that moment.
    var onScan: ((Bool) -> Void)?

    /// Pressed when the button is clicked while a scan is running.
    var onStopScan: (() -> Void)?

    /// A listed device was clicked, and the app should go and reach it.
    var onConnect: ((UUID) -> Void)?

    /// **Forget Device** was pressed: the app should stop having a device.
    var onForget: (() -> Void)?

    /// **Reset Device** was pressed: the cube should be put back to how it left the factory.
    var onReset: (() -> Void)?

    private(set) var moreRow: DisclosureRow!
    private(set) var ledRow: DisclosureRow!
    private(set) var doubleTapRow: DisclosureRow!

    /// The tab's two sections, each folding away behind its own triangle. Exposed so a test can measure one without
    /// a window on screen.
    ///
    /// **The folds nest**, which is the thing this tab has and the others do not: *More* sits inside TimeFlip, and
    /// *LED* and *Double tap* inside Settings. A `DisclosureRow` inside a folded `PanelSection` keeps whatever it was
    /// left as, and the window's walk goes on into a section it has just folded rather than stopping at it
    /// (`SettingsWindowController.restoreDefaultSectionStates`), so both levels come back to their own defaults.
    private(set) var timeflipSection: PanelSection!
    private(set) var settingsSection: PanelSection!

    /// Called when one of the folding rows or sections opens or closes, so the window can record it. The identifier
    /// is what says which, and it is the only thing that does: nothing stores a fold.
    var onToggle: ((String, Bool) -> Void)?

    /// One of the four register fields moved. What it moved to is on the pane; this only says that it did.
    ///
    /// **Every tick of a held arrow fires this**, which is the whole reason the window debounces rather than sending
    /// from here: a hold repeats every 0.1s (`StepperHoldRules`) and each of those would be a command on the wire.
    var onDoubleTapValueChanged: (() -> Void)?

    /// One of the two LED fields moved. What it moved to is on the pane; this only says that it did.
    ///
    /// **One each rather than one between them**, because they are two settings and not one: brightness goes as
    /// `0x09` and the blink period as `0x0A`, and a cube told about the first has been told nothing about the second.
    /// The archive found the cost of running them together, and it was not tidiness -- one debounce shared across two
    /// settings drops whichever write is still waiting when the other one is scheduled
    /// (`Archive/TimeFlipAppTests/Workflows/W07-debounced-device-writes.swift`).
    ///
    /// **Every tick of a held arrow fires these**, as it does for the registers, which is why the window debounces
    /// rather than sending from here.
    var onLEDBrightnessChanged: (() -> Void)?
    var onLEDBlinkChanged: (() -> Void)?

    /// Somebody ticked or unticked **Pause the device when locking it**. `true` means a lock should pause first.
    ///
    /// **Not debounced, unlike the four rows under it**, and it carries its value rather than being read back off the
    /// pane: a box is one press with one answer, where a held arrow produces a value a tenth of a second at a time
    /// and only the last one is meant.
    var onPauseOnLockChanged: ((Bool) -> Void)?

    /// The Battery warning field moved. What it moved to is on the pane; this only says that it did.
    ///
    /// **Its own report, on its own debounce**, for the reason every stepper on this tab has one: a hold repeats
    /// every 0.1s (`StepperHoldRules`), and each tick would otherwise be a row read, rewritten and read back
    /// (`SettingStore.write`) and a warning asked to think again. It was written per tick while it sat on the App
    /// tab, which has no debounce in it at all.
    var onBatteryWarningChanged: (() -> Void)?

    /// The Auto-pause field moved. What it moved to is on the pane; this only says that it did.
    ///
    /// **Its own report rather than a share of the LED pair's**, for the reason they are two: a debounce is scheduled
    /// per report and `WriteDebounce.schedule` displaces whatever was already queued, so a report covering two
    /// settings would drop whichever of them was still waiting.
    ///
    /// **Every tick of a held arrow fires this**, as it does for the LED fields, which is why the window waits for the
    /// value to settle rather than writing from here: a hold repeats every 0.1s (`StepperHoldRules`), and each of
    /// those would otherwise be a row read, rewritten and read back (`SettingStore.write`).
    var onAutoPauseChanged: (() -> Void)?

    /// A new name was typed into the Name row and committed with Return. Whether the cube takes it is the window's to
    /// find out and the cube's to answer: this only says what was typed.
    ///
    /// **The row does not move here.** The name on screen changes when `device_name` has been written and read back,
    /// which is the same rule every other writing row on this tab keeps -- and it matters more here, `device_name`
    /// being what the scan filter matches a renamed cube on.
    var onRename: ((String) -> Void)?

    /// The Name row opened or closed its field, so the window can lend Escape to it: a key equivalent is dispatched
    /// before the focused field ever sees the key, so the Close button would otherwise shut the window instead of the
    /// field abandoning the edit.
    var onRenameEditingChanged: ((Bool) -> Void)?

    /// Somebody ticked or unticked **Disable** under Double tap. `true` means the gesture is wanted.
    ///
    /// **The box reports what it now shows, and does not decide anything.** Whether the cube accepts it is the
    /// window's to find out and the cube's to answer, and a refusal puts the box back (`showDoubleTapEnabled`) --
    /// which is `CLAUDE.md`'s rule about a control never being left showing something the table does not hold.
    var onDoubleTapEnabledChanged: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        addSections()
        show(values)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Puts what the tables say on screen.
    ///
    /// Called with everything at once rather than a row at a time, which is the window's licence in `CLAUDE.md`: the
    /// open window reads every tab's settings in one go and is then the answer until it closes.
    func show(_ values: Values) {
        self.values = values

        let live = values.isCubeConnected
        nameCell.name = DeviceInfoRules.name(isCubePaired: values.isCubePaired, deviceName: values.deviceName)
        // **Whether the name will open is the cube's question, not the row's**, which is why the decision is
        // `DeviceNameRules`' and only the words are here: renaming is a command (`0x15`) that has to reach the
        // hardware, so with nothing on the other end there is nothing to rename.
        let refusal = DeviceNameRules.renameRefusal(
            isCubePaired: values.isCubePaired, isCubeConnected: values.isCubeConnected, deviceName: values.deviceName
        )
        nameCell.isEnabled = refusal == nil
        nameCell.disabledHelp = refusal.map(Self.renameHelp)
        connectionValue.stringValue = DeviceInfoRules.connection(
            isCubePaired: values.isCubePaired, isCubeConnected: values.isCubeConnected
        )
        batteryValue.stringValue = DeviceInfoRules.battery(
            isCubePaired: values.isCubePaired, isCubeConnected: values.isCubeConnected, batteryPercent: values.batteryPercent
        )
        manufacturerValue.stringValue = DeviceInfoRules.detail(isCubePaired: values.isCubePaired, reported: values.manufacturer)
        modelValue.stringValue = DeviceInfoRules.detail(isCubePaired: values.isCubePaired, reported: values.model)
        hardwareValue.stringValue = DeviceInfoRules.detail(isCubePaired: values.isCubePaired, reported: values.hardware)
        firmwareValue.stringValue = DeviceInfoRules.detail(isCubePaired: values.isCubePaired, reported: values.firmware)

        // Greyed together while nothing is live, so the placeholders sit back as the placeholders they are rather
        // than presenting as readings: a greyed row is the difference between a value the app is standing behind and
        // one it is not, which is what the archive greyed them together for.
        for field in [connectionValue, batteryValue, manufacturerValue, modelValue, hardwareValue, firmwareValue] {
            field?.textColor = live ? .labelColor : .secondaryLabelColor
        }
        // The Name row greys with them, and separately only because it is a control rather than a label: the cell
        // draws the name itself, and its button is left enabled even when the name will not open so that the tooltip
        // saying why survives (see `EditableNameCell.isEnabled`).
        nameCell.textColor = live ? .labelColor : .secondaryLabelColor
        // After the greying, because the warning outranks it: the loop above has just painted the Battery row the same
        // colour as everything beside it, and a flat cube is the one row that must not read like the rest.
        paintBattery()

        // **The TimeFlip section's controls, swapped on the pairing.** Exactly one set is up at a time: looking for a
        // cube is what an app with no cube does, and once there is one the section is about managing it instead. Both
        // are hidden through the stack rather than removed, so the row keeps its height and the status label opposite
        // does not jump as the section changes state.
        scanControls.isHidden = !DevicePairingRules.showsScanControls(isCubePaired: values.isCubePaired)
        pairedControls.isHidden = !DevicePairingRules.showsPairedControls(isCubePaired: values.isCubePaired)
        // **The list of found devices goes with the Scan button**, because it is the same answer: a scan result is a
        // device the app might pair with, and once it has one there is nothing left to choose. Leaving the list up
        // would offer a row that silently drops the pairing just made (`BluetoothRadio.connect` lets go of anything
        // already connected), sitting under controls that no longer include a way to search.
        //
        // **Driven by `isCubePaired` here rather than cleared by whoever pairs**, so the list and the controls cannot
        // disagree: one fact decides both, and every path that reaches a pairing redraws through this method.
        if values.isCubePaired { showFound([]) }
        // Dead while a connect is in flight, for the reason `showReaching` greys the device rows: an attempt owns the
        // pairing state until it resolves, and dropping it from underneath one leaves the two disagreeing about
        // whether there is a device.
        forgetButton.isEnabled = DevicePairingRules.allowsForget(isCubePaired: values.isCubePaired, isReachingForCube: isReachingForCube)
        // Reset needs the cube, Forget does not: one is a command that has to arrive somewhere, the other is this
        // app's own rows.
        resetButton.isEnabled = DevicePairingRules.allowsReset(
            isCubePaired: values.isCubePaired, isCubeConnected: values.isCubeConnected, isReachingForCube: isReachingForCube
        )

        pauseOnLockBox.state = values.pausesOnLock ? .on : .off
        batteryWarningField.value = values.batteryWarningPercent
        autoPauseField.value = values.autoPauseMinutes
        ledBrightnessField.value = values.ledBrightnessPercent
        ledBlinkField.value = values.ledBlinkSeconds
        drawSettingsGate()
        drawDoubleTap(isEnabled: values.isDoubleTapEnabled)
        doubleTapValues[Identifier.doubleTapThreshold]?.value = values.doubleTapThreshold
        doubleTapValues[Identifier.doubleTapLimit]?.value = values.doubleTapLimit
        doubleTapValues[Identifier.doubleTapLatency]?.value = values.doubleTapLatency
        doubleTapValues[Identifier.doubleTapWindow]?.value = values.doubleTapWindow
    }

    /// Puts the whole Settings section out of use while no cube is connected, and gives it back the moment one
    /// answers.
    ///
    /// **Every row in that section, asked once.** Each of them changes something about the cube, so with nothing on
    /// the other end an arrow or a tick could only ever end in the refusal sheet -- and a control that looks live and
    /// then refuses is worse than one that says up front why nothing will happen. Asked here rather than at each row
    /// because a gate written once per control is one chance per control to write it differently, which is
    /// `CLAUDE.md`'s first rule applied to a decision instead of a value.
    ///
    /// **`isCubeConnected`, not the pairing.** The two are not the same question and only one of them is this one: a
    /// paired cube in another room can be told nothing, and an unpaired app has nothing to tell anyway -- so the
    /// pairing is covered by this gate rather than by a second one beside it. See `docs/state-reference.md` §2.
    ///
    /// **The two rows no command carries are gated with the rest.** Pause on lock and Battery warning at are
    /// settings about what happens to the cube, and a section where every row but two goes grey would be saying
    /// those two are a different kind of thing -- which is not something somebody reading a row should have to work
    /// out. What it costs is arranging them before pairing; what it buys is a section with one answer in it.
    ///
    /// **The section follows the link rather than the window.** Every path that changes the connection redraws this
    /// tab through `show` (`recordConnected` on the way up, `markConnectionDown` on the way back), so this is not
    /// decided when the window opened.
    ///
    /// The four double-tap registers are not here: they have a second gate of their own and both have to be open, so
    /// `drawDoubleTap` owns them and reads the connection itself.
    private func drawSettingsGate() {
        let live = values.isCubeConnected
        let help = live ? nil : Self.notConnectedHelp

        for box in [pauseOnLockBox, doubleTapDisableBox] {
            box?.isEnabled = live
            box?.toolTip = help
        }
        for field in [batteryWarningField, autoPauseField, ledBrightnessField, ledBlinkField] {
            field?.isEnabled = live
            field?.disabledHelp = help
        }
    }

    /// The four registers as this window currently holds them.
    /// The four registers as this window currently holds them.
    ///
    /// **From the window rather than from the table**, which is the licence `CLAUDE.md` grants an open Settings
    /// window and the reason it grants it: these are what somebody is looking at, so they are what a command built
    /// now should carry. The `enabled` flag is deliberately not folded in -- what is sent when the gesture is off is
    /// `DoubleTapRules.asSent`'s to decide, and it is one decision in one place.
    /// **Read off the fields, not off `values`**, which is the difference between what is on screen and what was
    /// last shown. A held arrow moves the field several times a second and nothing writes those back to `values`
    /// until one lands, so a command built from `values` would carry the number the row opened with.
    var doubleTapParameters: DoubleTapParameters {
        func register(_ identifier: String, or fallback: Int) -> UInt8 {
            UInt8(clamping: doubleTapValues[identifier]?.value ?? fallback)
        }
        return DoubleTapParameters(
            threshold: register(Identifier.doubleTapThreshold, or: values.doubleTapThreshold),
            limit: register(Identifier.doubleTapLimit, or: values.doubleTapLimit),
            latency: register(Identifier.doubleTapLatency, or: values.doubleTapLatency),
            window: register(Identifier.doubleTapWindow, or: values.doubleTapWindow)
        )
    }

    /// The two LED values as this window currently holds them.
    ///
    /// **Read off the fields rather than off `values`**, for the reason `doubleTapParameters` gives directly above:
    /// a held arrow moves the field several times a second and nothing writes those back to `values` until one
    /// lands, so a command built from `values` would carry the number the row opened with.
    var ledBrightnessPercent: Int { ledBrightnessField.value }
    var ledBlinkSeconds: Int { ledBlinkField.value }

    /// Records that a LED value reached the cube and the table, **without touching the field it came from**.
    ///
    /// What this is for is `values`, which the field has been ahead of since the first arrow moved. Writing the field
    /// as well would be wrong rather than merely redundant: by the time a command has been out and back, the field
    /// may hold a newer number that already has a write of its own queued, and assigning this one would take that
    /// number off the screen and then send it again on the next tick -- losing an edit nothing had refused.
    ///
    /// So the two paths are separate on purpose. This one is a write that landed and has nothing to correct; the
    /// pair below are a write that did not, where the number on screen is precisely what is wrong with it.
    func recordLEDBrightness(_ percent: Int) {
        values.ledBrightnessPercent = percent
    }

    func recordLEDBlink(_ seconds: Int) {
        values.ledBlinkSeconds = seconds
    }

    /// Puts a LED field back where the table says it should be, without telling anybody it moved.
    ///
    /// **The mirror of `showDoubleTapValues`, and for the same reason**: a refused write has to correct one row
    /// while every other row on the tab goes on showing what it was showing, so this is a path that must not re-read
    /// the whole tab. `values` moves with the field, so the two cannot part company.
    func showLEDBrightness(_ percent: Int) {
        recordLEDBrightness(percent)
        put(percent, in: ledBrightnessField)
    }

    func showLEDBlink(_ seconds: Int) {
        recordLEDBlink(seconds)
        put(seconds, in: ledBlinkField)
    }

    /// Puts the Pause on lock box where the table says it should be, without telling anybody it moved.
    ///
    /// **Set directly rather than through `show`**, for the reason `showDoubleTapEnabled` is: a refused write has to
    /// put this one control back while every other row goes on showing what it was showing. `state` is assigned
    /// rather than the action fired, so a correction cannot be mistaken for somebody ticking it.
    func showPauseOnLock(_ pausesOnLock: Bool) {
        values.pausesOnLock = pausesOnLock
        pauseOnLockBox.state = pausesOnLock ? .on : .off
    }

    /// The battery warning level as this window currently holds it, as a percentage.
    ///
    /// **Read off the field rather than off `values`**, for the reason every other stepper here is read that way: a
    /// held arrow moves the field several times a second and nothing writes those back to `values` until one lands,
    /// so a write built from `values` would carry the number the row opened with.
    var batteryWarningPercent: Int { batteryWarningField.value }

    /// Records that a battery warning level reached the table, **without touching the field it came from**.
    func recordBatteryWarning(_ percent: Int) {
        values.batteryWarningPercent = percent
    }

    /// Puts the Battery warning field back where the table says it should be, without telling anybody it moved.
    func showBatteryWarning(_ percent: Int) {
        recordBatteryWarning(percent)
        put(percent, in: batteryWarningField)
    }

    /// Auto-pause as this window currently holds it, in whole minutes.
    ///
    /// **Read off the field rather than off `values`**, for the reason the LED pair are read that way: a held arrow
    /// moves the field several times a second and nothing writes those back to `values` until one lands, so a write
    /// built from `values` would carry the number the row opened with.
    var autoPauseMinutes: Int { autoPauseField.value }

    /// Records that an Auto-pause value reached the table, **without touching the field it came from**.
    ///
    /// The counterpart of `recordLEDBrightness` above, and separate from the correction below for the same reason:
    /// by the time a write has been made and read back, the field may hold a newer number with a write of its own
    /// already queued, and assigning this one would take that number off the screen.
    func recordAutoPause(_ minutes: Int) {
        values.autoPauseMinutes = minutes
    }

    /// Puts the Auto-pause field back where the table says it should be, without telling anybody it moved.
    ///
    /// `SteppedNumberField.value` does not fire `onChange`, so a correction cannot be mistaken for somebody moving an
    /// arrow and start a second write, and `put` leaves a field already on the number alone.
    func showAutoPause(_ minutes: Int) {
        recordAutoPause(minutes)
        put(minutes, in: autoPauseField)
    }

    /// Puts the Disable box where the answer says it should be, without telling anybody it moved.
    ///
    /// **Set directly rather than through `show`**, because this is the one path that must not re-read the whole tab:
    /// a refused write has to put this one control back while every other row goes on showing what it was showing.
    /// `state` is assigned rather than the action fired, so a correction cannot be mistaken for somebody ticking it.
    func showDoubleTapEnabled(_ isEnabled: Bool) {
        values.isDoubleTapEnabled = isEnabled
        drawDoubleTap(isEnabled: isEnabled)
    }

    /// The Disable box and the four registers under it, drawn together.
    ///
    /// **Ticking Disable puts the four fields out of use**, because with the gesture off there is nothing for them to
    /// describe: `DoubleTapRules.asSent` sends `Window` as 0 whatever the field holds, so a live-looking field is a
    /// control that would take a number and then not send it. A dead one says why nothing happens, which is the same
    /// reasoning the Faces tab greys its category rows with while a click would be refused.
    ///
    /// **The values stay in the fields rather than being cleared.** They are what the gesture goes back to when
    /// somebody unticks the box, and they are still what the table holds -- emptying them would lose a setting to a
    /// display decision.
    ///
    /// **One method for both, called from all three paths** -- the tab being drawn, a refused write being put back,
    /// and somebody ticking the box -- so the fields cannot come to disagree with the box beside them. That is the
    /// same fault in miniature that the first rule in `CLAUDE.md` is about: two controls answering one question.
    private func drawDoubleTap(isEnabled: Bool) {
        doubleTapDisableBox.state = isEnabled ? .off : .on
        // **Two gates, and a register is live only with both open**: the gesture has to be wanted, and there has to
        // be a cube to tell about it. Folded in here rather than left to `drawSettingsGate` because this method is
        // also reached from the box being ticked and from a refused write being put back, neither of which has any
        // business re-enabling a field the connection has closed.
        let live = isEnabled && values.isCubeConnected
        for field in doubleTapValues.values {
            field.isEnabled = live
            // **Only the connection gets a tooltip.** A register dead because the gesture is off is explained by the
            // ticked box directly above it; one dead because there is no cube has nothing on screen saying so.
            field.disabledHelp = values.isCubeConnected ? nil : Self.notConnectedHelp
        }
    }

    /// Puts the four registers where the table says they should be, without telling anybody they moved.
    ///
    /// **The mirror of `showDoubleTapEnabled`, and for the same reason**: a refused write has to correct these four
    /// rows while every other row on the tab goes on showing what it was showing, so this is the one path that must
    /// not re-read the whole tab.
    ///
    /// **Called on the way out of a write that took, as well as one that did not**, so `values` never drifts from
    /// what the fields hold -- and the guard below is what makes that safe. `SteppedNumberField.value` does not fire
    /// `onChange`, so no correction can be mistaken for somebody moving an arrow, but assigning it does replace the
    /// text in the field: doing that to a field already showing the number would take it out from under whoever is
    /// typing, which `CLAUDE.md` names as its own fault. A field already on the value is left alone.
    func showDoubleTapValues(_ parameters: DoubleTapParameters) {
        values.doubleTapThreshold = Int(parameters.threshold)
        values.doubleTapLimit = Int(parameters.limit)
        values.doubleTapLatency = Int(parameters.latency)
        values.doubleTapWindow = Int(parameters.window)
        put(Int(parameters.threshold), in: Identifier.doubleTapThreshold)
        put(Int(parameters.limit), in: Identifier.doubleTapLimit)
        put(Int(parameters.latency), in: Identifier.doubleTapLatency)
        put(Int(parameters.window), in: Identifier.doubleTapWindow)
    }

    private func put(_ value: Int, in identifier: String) {
        put(value, in: doubleTapValues[identifier])
    }

    /// **A field already on the value is left alone**, which is what keeps a correction from taking the text out
    /// from under whoever is typing: `SteppedNumberField.value` replaces the box's contents whatever it held, and
    /// rebuilding a row to show a number it is already showing is a fault `CLAUDE.md` names on its own.
    private func put(_ value: Int, in field: SteppedNumberField?) {
        guard let field, field.value != value else { return }
        field.value = value
    }

    private func doubleTapValueChanged() {
        onDoubleTapValueChanged?()
    }

    @objc private func pauseOnLockChanged() {
        // **`values` moves with the box, here rather than on the way back.** Nothing else on this tab reads it
        // between the press and the write landing, and a refusal puts both back through `showPauseOnLock` -- so the
        // two cannot part company. `doubleTapDisableChanged` below does the same, for the same reason.
        let pausesOnLock = pauseOnLockBox.state == .on
        values.pausesOnLock = pausesOnLock
        onPauseOnLockChanged?(pausesOnLock)
    }

    @objc private func doubleTapDisableChanged() {
        // The box says "Disable", so ticked is the gesture being unwanted. Reported the right way round here, once,
        // rather than at every reader of it.
        let isEnabled = doubleTapDisableBox.state == .off
        values.isDoubleTapEnabled = isEnabled
        // The four registers go dead with the box, at the moment it is ticked rather than when the write comes back:
        // the fields are the thing somebody is looking at, and a field that stays live until a round trip finishes is
        // a field that accepts a number nobody will send. A refused write puts both back through `showDoubleTapEnabled`.
        drawDoubleTap(isEnabled: isEnabled)
        onDoubleTapEnabledChanged?(isEnabled)
    }

    /// Flashes the Battery row while the cube is flat, in step with the menu bar.
    ///
    /// **Told, not worked out here**, and told by the one object that owns the warning (`LowBatteryWatch`): the row
    /// and the status item flash together, which is only true if one thing decides when. A pane that ran its own
    /// timer would drift out of step within seconds of opening.
    ///
    /// The alert is held rather than read because it is not a value the tab shows -- it is which half of a flash is
    /// currently up, told twice a second -- and `show(_:)` repaints from it so a redraw part way through a flash
    /// does not land on the wrong phase.
    func showLowBattery(_ alert: LowBatteryAlert) {
        guard alert != lowBattery else { return }
        lowBattery = alert
        paintBattery()
    }

    private func paintBattery() {
        guard let batteryValue else { return }
        let live = values.isCubeConnected
        batteryValue.textColor = lowBattery.isBlinkOn ? .systemRed : (live ? .labelColor : .secondaryLabelColor)
    }

    // MARK: - the sections

    /// Two sections, each folding away behind its own triangle.
    ///
    /// **Both open**, for the App tab's reason rather than the Categories tab's: these are the whole of the tab, so
    /// opening it folded would show two headings and nothing to read. TimeFlip in particular stays open because the
    /// scan results appear inside it, and a folded section would hide the answer to the thing somebody just pressed.
    ///
    /// **The pairing controls are the last rows of the TimeFlip section**, under *More*, which is where the button
    /// sat relative to its own section before the two were merged. What is above them is what the app knows about
    /// the cube and what is below is how to get one, which is the order somebody reads the section in: the question
    /// first, then the thing to press about it.
    private func addSections() {
        let timeflipRows = stack()
        add(infoRowViews() + pairingRowViews(), to: timeflipRows)
        let settingsRows = stack()
        add(settingsRowViews(), to: settingsRows)

        timeflipSection = section(title: "TimeFlip", identifier: Identifier.timeflipSection, content: timeflipRows)
        settingsSection = section(title: "Settings", identifier: Identifier.settingsSection, content: settingsRows)
        guard let timeflip = timeflipSection, let settings = settingsSection else { return }

        for view in [timeflip, settings] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            timeflip.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            settings.topAnchor.constraint(equalTo: timeflip.bottomAnchor, constant: Layout.sectionSpacing),
            // Only as tall as its content: the sections grow down from the top of the tab rather than being stretched
            // to a height they have nothing to put in.
            settings.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.padding),
        ])

        // Each section spans the tab (`CLAUDE.md`: a tab's content spans the width of the window, inset by the tab's
        // own padding and nothing more).
        for view in [timeflip, settings] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            ])
        }
    }

    /// One of the tab's two sections.
    ///
    /// **Nothing is overridden any more**, exactly as on the App tab. The `contentInset: 0` this used to pass was
    /// there so the hairlines between rows ended where the archive's did; with no hairlines it buys nothing, and one
    /// inset for all three tabs is what puts a row at the same x on each of them. See `SettingsMetrics`.
    ///
    /// **No label is passed**: "TimeFlip" and "Settings" say what they are on their own.
    private func section(title: String, identifier: String, content: NSView) -> PanelSection {
        let section = PanelSection(
            title: title,
            identifier: identifier,
            isExpanded: true,
            content: content
        )
        section.onToggle = { [weak self] expanded in self?.onToggle?(identifier, expanded) }
        return section
    }

    /// Name, Connection, Battery, and the four the cube only reports once it is connected.
    private func infoRowViews() -> [NSView] {
        nameCell = makeNameCell()
        connectionValue = value(identifier: Identifier.connection)
        batteryValue = value(identifier: Identifier.battery)
        manufacturerValue = value(identifier: Identifier.manufacturer)
        modelValue = value(identifier: Identifier.model)
        hardwareValue = value(identifier: Identifier.hardware)
        firmwareValue = value(identifier: Identifier.firmware)

        let details = stack()
        add(
            [
                SettingsRow.make("Manufacturer", manufacturerValue),
                SettingsRow.make("Model", modelValue),
                SettingsRow.make("Hardware", hardwareValue),
                SettingsRow.make("Firmware", firmwareValue),
            ],
            to: details
        )

        // **Closed.** Four rows of strings a cube reports about itself are the tab's least urgent fact, which is why
        // the archive folded them away too.
        // **Separated now that the pairing controls follow it.** It was the last row of its own section and so had no
        // hairline; with the scan under it, a divider is what keeps the readings above and the controls below reading
        // as two halves of one section rather than as one undifferentiated list.
        moreRow = DisclosureRow(
            title: "More", identifier: Identifier.more, isExpanded: false, content: details
        )
        moreRow.onToggle = { [weak self] expanded in self?.onToggle?(Identifier.more, expanded) }

        return [
            SettingsRow.make("Name", nameCell),
            SettingsRow.make("Connection", connectionValue),
            SettingsRow.make("Battery", batteryValue),
            moreRow,
        ]
    }

    /// The cube's own settings: stored here, and sent to it when there is one to send them to.
    private func settingsRowViews() -> [NSView] {
        // **The archive's wording, on the archive's control, moved off the archive's tab.** It sat among the App
        // tab's six switches and numbers, which is where the setting the app reads was assumed to belong. What it
        // actually decides is what happens to the cube -- whether a lock stops it counting first -- so it belongs
        // with the rest of what the cube is set to, above the other setting about the cube pausing itself.
        pauseOnLockBox = NSButton(checkboxWithTitle: "", target: self, action: #selector(pauseOnLockChanged))
        pauseOnLockBox.translatesAutoresizingMaskIntoConstraints = false
        pauseOnLockBox.setAccessibilityIdentifier(Identifier.pauseOnLock)

        // **The archive's wording and bounds, on the archive's control, moved off the archive's tab.** What it
        // decides is what counts as this device running flat, so it reads under the lock row and above Auto-pause.
        // `BatteryRules` owns the range now: that type already holds every other number the threshold is judged by
        // (`recoveryMargin`, `riseToAdopt`), so a field that would accept a level the warning could not act on is
        // ruled out by the same file that acts on it.
        batteryWarningField = SteppedNumberField(
            value: values.batteryWarningPercent,
            range: BatteryRules.warningRange,
            suffix: BatteryRules.warningSuffix,
            identifier: Identifier.batteryWarning
        )
        batteryWarningField.onChange = { [weak self] _ in self?.onBatteryWarningChanged?() }

        // **Its label states the ceiling, and takes it from the same place the field does.** The archive's wording,
        // with the number now interpolated rather than typed twice: `DeviceCommandRules.autoPauseRange` is what the
        // command clamps to, so the label cannot come to promise a limit the wire does not keep. 0 disables it, which
        // is the vendor protocol's own disabled-by-default behaviour.
        //
        // **It is given no width here**, which is what makes this row read like the App tab's four.
        // `SteppedNumberField.Layout.fieldWidth` is the one number that sizes every stepped field in the app, and a
        // width set from outside is not a second opinion about the box -- it is a cap on the whole control, box,
        // unit and arrows together. At 90 it was capping the lot at the width of the box alone, which is why this
        // one field came out narrower than the others and its arrows sat where nobody else's did.
        autoPauseField = SteppedNumberField(
            value: values.autoPauseMinutes,
            range: DeviceCommandRules.autoPauseRange,
            suffix: "min",
            identifier: Identifier.autoPause
        )
        autoPauseField.onChange = { [weak self] _ in self?.onAutoPauseChanged?() }

        // **These ranges come from the commands that carry them too**, as Auto-pause's does above:
        // `DeviceCommandRules` is where 1-100 % and 5-60 seconds are kept, and it clamps to the same bounds on the
        // way to the wire. A field that would accept a number the command then quietly changed is two answers to one
        // question, which is the fault the first rule in `CLAUDE.md` is about.
        //
        // **Arrows rather than a slider**, which is the archive's finding and worth keeping the reason for: a slider
        // commits a value per pixel of travel, and one brightness drag logged thirty-odd changes -- every one of them
        // a device write once the debounce settles. A stepped field commits one number at a time, and both ranges are
        // short enough to cross by holding an arrow (`StepperHoldRules` accelerates).
        ledBrightnessField = SteppedNumberField(
            value: values.ledBrightnessPercent,
            range: DeviceCommandRules.brightnessRange,
            suffix: "%",
            identifier: Identifier.ledBrightness
        )
        ledBrightnessField.onChange = { [weak self] _ in self?.onLEDBrightnessChanged?() }
        ledBlinkField = SteppedNumberField(
            value: values.ledBlinkSeconds,
            range: DeviceCommandRules.blinkRange,
            suffix: "sec",
            identifier: Identifier.ledBlink
        )
        ledBlinkField.onChange = { [weak self] _ in self?.onLEDBlinkChanged?() }
        let led = stack()
        add(
            [
                SettingsRow.make("Brightness", ledBrightnessField),
                SettingsRow.make("Blink Interval", ledBlinkField),
            ],
            to: led
        )
        ledRow = DisclosureRow(title: "LED", identifier: Identifier.led, isExpanded: false, content: led)
        ledRow.onToggle = { [weak self] expanded in self?.onToggle?(Identifier.led, expanded) }

        // **"Disable", not "Enable".** The archive's wording, and the right way round: the setting is on by default,
        // so the box somebody ticks is the one that turns the gesture off.
        doubleTapDisableBox = NSButton(
            checkboxWithTitle: "Disable", target: self, action: #selector(doubleTapDisableChanged)
        )
        doubleTapDisableBox.translatesAutoresizingMaskIntoConstraints = false
        doubleTapDisableBox.setAccessibilityIdentifier(Identifier.doubleTapDisable)

        let doubleTap = stack()
        var doubleTapRows: [NSView] = [leading(doubleTapDisableBox)]
        // **0 to 255, because that is the register.** Each of the four is one `UInt8` written straight to the
        // accelerometer (`0x16`), so the range is the hardware's and not a judgement about useful values. `Window` at
        // 0 is the one meaningful edge, being how the gesture is turned off (`DoubleTapRules.asSent`) -- somebody can
        // reach it here as well as through the box above, and it means the same thing either way.
        //
        // **No suffix**, unlike Auto-pause's "min": these are register values and there is no unit to name.
        for (title, identifier, current) in [
            ("Threshold", Identifier.doubleTapThreshold, values.doubleTapThreshold),
            ("Limit", Identifier.doubleTapLimit, values.doubleTapLimit),
            ("Latency", Identifier.doubleTapLatency, values.doubleTapLatency),
            ("Window", Identifier.doubleTapWindow, values.doubleTapWindow),
        ] {
            let field = SteppedNumberField(value: current, range: 0...255, suffix: "", identifier: identifier)
            field.onChange = { [weak self] _ in self?.doubleTapValueChanged() }
            doubleTapValues[identifier] = field
            doubleTapRows.append(SettingsRow.make(title, field))
        }
        add(doubleTapRows, to: doubleTap)
        doubleTapRow = DisclosureRow(
            title: "Double tap", identifier: Identifier.doubleTap, isExpanded: false, content: doubleTap
        )
        doubleTapRow.onToggle = { [weak self] expanded in self?.onToggle?(Identifier.doubleTap, expanded) }

        return [
            SettingsRow.make("Pause the device when locking it", pauseOnLockBox),
            SettingsRow.make("Battery warning at", batteryWarningField),
            SettingsRow.make(
                "Auto-pause (0 disable, max \(DeviceCommandRules.autoPauseRange.upperBound)m)", autoPauseField
            ),
            ledRow,
            doubleTapRow,
        ]
    }

    /// Finding a cube, and reaching the one that is chosen.
    private func pairingRowViews() -> [NSView] {
        scanButton = NSButton(title: "Scan for Devices", target: self, action: #selector(scanPressed))
        scanButton.bezelStyle = .rounded
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        scanButton.setAccessibilityIdentifier(Identifier.scan)

        // **A filtered scan is the default and this is the way out of it.** The filter matches the vendor name and
        // the names this cube has carried, which is what finds a renamed device -- and is also what hides a cube
        // whose name the app has never seen. See `database/011_setting.sql`'s `device_name` row.
        //
        // Ticking it mid-scan does nothing until the next press, deliberately: the filter is applied to
        // advertisements as they arrive, so honouring it live would show a half-filtered list whose contents
        // depended on when the box was ticked.
        scanAllBox = NSButton(checkboxWithTitle: "All Devices", target: nil, action: nil)
        scanAllBox.translatesAutoresizingMaskIntoConstraints = false
        scanAllBox.setAccessibilityIdentifier(Identifier.scanAll)

        scanControls = NSStackView(views: [scanButton, scanAllBox])
        scanControls.orientation = .horizontal
        scanControls.alignment = .centerY
        scanControls.spacing = 12
        scanControls.translatesAutoresizingMaskIntoConstraints = false

        // **What a paired app gets in place of the scan controls.** The section stops being about finding a cube the
        // moment there is one, so the controls change with it rather than a scan sitting beside a device that is
        // already paired -- see `DevicePairingRules.showsScanControls`.
        forgetButton = NSButton(title: "Forget Device", target: self, action: #selector(forgetPressed))
        forgetButton.bezelStyle = .rounded
        forgetButton.translatesAutoresizingMaskIntoConstraints = false
        forgetButton.setAccessibilityIdentifier(Identifier.forget)

        resetButton = NSButton(title: "Reset Device", target: self, action: #selector(resetPressed))
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.setAccessibilityIdentifier(Identifier.reset)

        pairedControls = NSStackView(views: [forgetButton, resetButton])
        pairedControls.orientation = .horizontal
        pairedControls.alignment = .centerY
        pairedControls.spacing = 12
        pairedControls.translatesAutoresizingMaskIntoConstraints = false

        // Both in one place, so whichever is up sits exactly where the other did and the status label opposite it
        // does not move as the section changes state.
        let pair = NSStackView(views: [scanControls, pairedControls])
        pair.orientation = .horizontal
        pair.alignment = .centerY
        pair.spacing = 12
        pair.translatesAutoresizingMaskIntoConstraints = false

        // **Says what the radio is doing, and it is not decoration.** An empty list means "nothing found", "Bluetooth
        // is off" and "not allowed to use Bluetooth" all at once, and those want three different things done about
        // them. `ScanUnavailable` is where the words live.
        scanStatusLabel = NSTextField(labelWithString: "")
        scanStatusLabel.textColor = .secondaryLabelColor
        scanStatusLabel.lineBreakMode = .byWordWrapping
        scanStatusLabel.maximumNumberOfLines = 2
        scanStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        scanStatusLabel.setAccessibilityIdentifier(Identifier.scanStatus)

        // **On the button's own row, at the trailing edge.** It is the answer to the question the button asks, and
        // every other answer on this tab sits opposite the thing it answers rather than on a line of its own. A row
        // to itself also made the panel taller by an empty line whenever there was nothing to say.
        let controls = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(pair)
        controls.addSubview(scanStatusLabel)
        NSLayoutConstraint.activate([
            pair.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: Layout.rowInset),
            pair.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            pair.topAnchor.constraint(greaterThanOrEqualTo: controls.topAnchor, constant: Layout.controlRowPadding),
            pair.bottomAnchor.constraint(
                lessThanOrEqualTo: controls.bottomAnchor, constant: -Layout.controlRowPadding
            ),

            // The words give way before the controls do: a window too narrow for both should shorten the message,
            // not clip the button that starts the scan.
            scanStatusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: pair.trailingAnchor, constant: Layout.rowInset
            ),
            scanStatusLabel.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -Layout.rowInset),
            scanStatusLabel.centerYAnchor.constraint(equalTo: controls.centerYAnchor),

        ])
        SettingsRow.settle(controls)
        scanStatusLabel.alignment = .right
        scanStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pair.setContentCompressionResistancePriority(.required, for: .horizontal)

        scanResults = stack()
        // **Born hidden, because it is born empty.** A stack view skips a hidden arranged subview and the spacing
        // that would have gone before it, so this is what stops an empty scan list leaving a row's worth of gap
        // under the Scan button. `showFound` keeps it in step from then on -- and it is set here as well as there
        // because that only runs once something has been scanned for or a pairing has landed, so a launch with no
        // cube would otherwise never reach it.
        scanResults.isHidden = true
        return [controls, scanResults]
    }

    /// One found device: its name, on the left, where a list puts a thing rather than where a form puts an answer.
    ///
    /// **The whole row is the button, and its title is the name.** Not a label with a Connect button beside it: the
    /// row is one thing to do, so making somebody aim at a second control in it would be the triangle-versus-heading
    /// mistake `CLAUDE.md` describes, one list along. Borderless, so a list still reads as a list.
    ///
    /// **The separator is at the top, not the bottom.** The first one divides the list from the controls above it and
    /// every later one divides two devices, which is what a bottom edge cannot do without also drawing a line under
    /// the last row with nothing beneath it.
    private func deviceRow(_ device: ScannedDevice) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let name = NSButton(title: DeviceScanRules.label(for: device), target: self, action: #selector(devicePressed))
        name.isBordered = false
        name.alignment = .left
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setAccessibilityIdentifier(Identifier.scanResult(device.id))
        // The identifier is how the press finds its way back to a device: the button is the only thing that knows
        // which row was clicked, and a closure captured per row would keep the pane holding a list of its own.
        name.identifier = NSUserInterfaceItemIdentifier(device.id.uuidString)
        deviceButtons.append(name)

        row.addSubview(name)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            name.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -Layout.rowInset),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Layout.rowPadding),
            name.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -Layout.rowPadding),

        ])
        return SettingsRow.settle(row)
    }

    @objc private func scanPressed() {
        if isScanning {
            onStopScan?()
        } else {
            onScan?(scanAllBox.state == .on)
        }
    }

    @objc private func devicePressed(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue, let id = UUID(uuidString: identifier) else { return }
        onConnect?(id)
    }

    // **Nothing is asked before it, deliberately, which is the archive's decision copied.** Forgetting is local
    // bookkeeping: there is no device round trip to await, no failure to report, and nothing on the cube changes -- it
    // keeps its name and its PIN. What it costs to undo is pairing again, and a confirmation in front of the one
    // control that gets a stuck app moving is a step between somebody and the way out.
    @objc private func forgetPressed() { onForget?() }

    // **This one is asked about first, unlike Forget, and the difference is what it costs to be wrong.** Forgetting
    // changes nothing on the cube and is undone by pairing again; this erases the device and cannot be undone. The
    // asking is the window's, for the reason above.
    @objc private func resetPressed() { onReset?() }

    // MARK: - what the scan is doing

    private(set) var isScanning = false

    /// The button says what pressing it would do, which while a scan runs is stop it.
    ///
    /// **Stopping takes the "looking" message down, and that is this method's job rather than the caller's.** It was
    /// the caller's, and the result was an app that had switched the radio off while still saying it was searching:
    /// the button flipped back to Scan for Devices and the line under it went on reading "Looking for devices..."
    /// beside a finished list. Whatever replaces it -- a count, or a reason the radio is unusable -- is said by
    /// whoever knows it, immediately after; what cannot be left to them is the clearing, because a caller that
    /// forgets produces exactly the screen above.
    func showScanning(_ isScanning: Bool) {
        self.isScanning = isScanning
        scanButton.title = isScanning ? "Stop Scan" : "Scan for Devices"
        if isScanning {
            showScanMessage("Looking for devices...")
        } else if scanStatusLabel.stringValue == "Looking for devices..." {
            // Only that one message, so a reason the scan could not run is not wiped by the stop it caused.
            showScanMessage("")
        }
    }

    func showScanMessage(_ message: String) {
        scanStatusLabel.stringValue = message
        scanStatusLabel.isHidden = message.isEmpty
    }

    /// Draws the devices found so far.
    ///
    /// **Handed the whole list rather than each arrival**, so this holds no list of its own: what is on screen is
    /// what the scanner last said, and a device that has dropped out cannot linger here because nothing here
    /// remembers it. That is the database rule's reasoning applied to something that has no table.
    func showFound(_ devices: [ScannedDevice]) {
        // **A paired app lists nothing, whoever is asking.** The radio calls this directly on every advertisement, so
        // the rule cannot live only in `show`: a scan that is still running when a pairing lands -- or one the radio
        // starts by itself when Bluetooth comes back on (`centralManagerDidUpdateState`) -- would otherwise draw rows
        // straight back under controls that no longer offer any way to stop it.
        let devices = values.isCubePaired ? [] : devices
        for view in scanResults.arrangedSubviews {
            scanResults.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        deviceButtons = []
        add(devices.map { deviceRow($0) }, to: scanResults)
        // **An empty list takes no room, gap included.** A stack view skips a hidden arranged subview *and* the
        // spacing that would have gone before it, so hiding this is what stops an empty scan list leaving a row's
        // worth of gap under the Scan button. It cost nothing while the lists here had no spacing at all; giving
        // every list the shared gap is what made an empty one visible.
        scanResults.isHidden = devices.isEmpty
        // A list redrawn mid-attempt must not come back live. The rows are rebuilt on every advertisement, so
        // whatever the tab last decided about them has to be applied again here rather than assumed to have
        // survived -- and a scan carrying on behind a connect is exactly when this happens.
        showReaching(isReachingForCube)
    }

    /// Whether an attempt to reach a device is in flight, which is what greys the list.
    ///
    /// **The rows go dead rather than merely being ignored.** A second press during the several seconds a connect
    /// takes is the obvious thing to do when nothing has visibly happened, and a control that quietly discards it is
    /// the one that looks broken. The status line says what is going on; this says it cannot be interrupted.
    private(set) var isReachingForCube = false

    func showReaching(_ isReachingForCube: Bool) {
        self.isReachingForCube = isReachingForCube
        // **Forget and Reset go dead with them**, and it is set here as well as in `show` because this is what actually
        // moves: an attempt begins and ends without the tab being redrawn from the table, so a rule applied only there
        // would leave the buttons live for the whole of the one moment they must not be.
        forgetButton.isEnabled = DevicePairingRules.allowsForget(isCubePaired: values.isCubePaired, isReachingForCube: isReachingForCube)
        resetButton.isEnabled = DevicePairingRules.allowsReset(
            isCubePaired: values.isCubePaired, isCubeConnected: values.isCubeConnected, isReachingForCube: isReachingForCube
        )
        for button in deviceButtons {
            button.isEnabled = !isReachingForCube
        }
    }

    // MARK: - the pieces a row is made of

    /// - Parameter spacing: the gap between rows. **Nothing for a list with hairlines**, which is what the two
    ///   outer lists are: a divider between rows is what separates them, and a gap would leave each hairline
    ///   floating above the row it divides rather than between the two.
    ///
    ///   **`Layout.rowSpacing` for a list without them**, which is the folded groups: nothing divides those rows, so
    ///   with no gap they run together into a block. That is the Categories tab's arrangement, and this is its
    ///   number -- the two tabs then share both halves of the rhythm rather than only the row height.
    /// A list of rows, held apart by the one gap every tab uses.
    ///
    /// **The default is the gap, not nothing.** It was 0, which is what made this tab's top-level rows run together
    /// while its folded lists breathed: two rhythms on one tab, and neither of them the Categories tab's.
    private func stack(spacing: CGFloat = Layout.rowSpacing) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Adds rows to a list, each one spanning it.
    ///
    /// **The width constraint is the part that cannot be left out.** The stack aligns its rows to the leading edge,
    /// so without it each row is only as wide as its own contents -- which puts every value against the widest
    /// label rather than against the panel's right-hand edge, and stops the hairlines reaching across. That is
    /// `CLAUDE.md`'s "a tab's content spans the width of the window" seen one level down.
    private func add(_ rows: [NSView], to stack: NSStackView) {
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// The Name row's cell: a name that becomes a field when it is clicked.
    ///
    /// **The same control the Categories tab renames with, and the App tab names its calendar with**, which is what
    /// makes this the same act rather than a third way of doing it. The archive put the rename behind a right-click
    /// menu with one item in it (`TimeFlipSettingsView`); `EditableNameCell` exists because that is a gesture nobody
    /// finds, and the answer arrived at there is the answer here too.
    ///
    /// **It is held to the cube's limit as it is typed** (`DeviceNameRules.maximumLength`), so what is on screen is
    /// what a rename would send. Which *characters* the cube accepts is refused at submit instead, with an alert that
    /// says why -- see `DeviceNameRules.renameDecision`.
    private func makeNameCell() -> EditableNameCell {
        let cell = EditableNameCell(
            name: "",
            width: Layout.nameWidth,
            identifier: Identifier.name,
            alignment: .right
        )
        cell.maximumLength = DeviceNameRules.maximumLength
        cell.onCommit = { [weak self] typed in self?.onRename?(typed) }
        cell.onEditingChanged = { [weak self] isEditing in self?.onRenameEditingChanged?(isEditing) }
        return cell
    }

    private func value(identifier: String) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.alignment = .right
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    /// A row whose content sits at the left rather than being split across it, for the two controls that are not a
    /// label and an answer.
    private func leading(_ content: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -Layout.rowInset),
            content.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Layout.rowPadding),
            content.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -Layout.rowPadding),
        ])
        return SettingsRow.settle(row)
    }
}

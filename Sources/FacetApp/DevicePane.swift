import AppKit

/// The Device tab: what the app knows about a cube, the settings that live on one, and the way to go and find one.
///
/// **Only the bottom section reaches anything.** Every value in the two above it is read from the database and shown,
/// and no control in them writes; what each of those will do arrives with the feature that can honestly do it.
///
/// So read this as three sections, two of which describe a device and one of which goes and gets one:
///
/// - **Info**, which is a report. Its rows say what the app knows, and say plainly when the answer is that it knows
///   nothing (`DeviceInfoRules`, where the wording and the three different kinds of "no device" live).
/// - **Settings**, which are the cube's own: they are stored here and sent to it on connect, so they are readable and
///   meaningful with no cube present, which is why they are drawn rather than hidden.
/// - **TimeFlip**, which finds a cube and reaches it. Pressing Scan lists what answers; pressing a listed device
///   connects to it and presents a PIN.
///
/// **The layout is the previous app's**, measured off `image/preferences-device.png` and its final source rather than
/// recalled: a heading above a rounded panel, labels down the left, values and controls pinned to the right-hand
/// edge. It is `AppSettingsPane`'s shape too, and deliberately so -- these are the two tabs made of settings rows, and
/// two tabs of rows that sat at different rhythms would read as two windows.
@MainActor
final class DevicePane: NSView {
    enum Identifier {
        static let infoSection = "device-info-section"
        static let infoPanel = "device-info-panel"
        static let name = "device-name"
        static let connection = "device-connection"
        static let battery = "device-battery"
        static let more = "device-more"
        static let manufacturer = "device-manufacturer"
        static let model = "device-model"
        static let hardware = "device-hardware"
        static let firmware = "device-firmware"

        static let settingsSection = "device-settings-section"
        static let settingsPanel = "device-settings-panel"
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

        static let pairingSection = "device-pairing-section"
        static let pairingPanel = "device-pairing-panel"
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
        static let padding: CGFloat = 20
        static let headingSpacing: CGFloat = 12
        static let sectionSpacing: CGFloat = 24
        static let cornerRadius: CGFloat = 8
        static let rowInset: CGFloat = 20
        static let rowPadding: CGFloat = 11
        static let minimumRowHeight: CGFloat = 38
        static let separatorHeight: CGFloat = 1
    }

    /// What the tables say, at the moment the tab was shown.
    ///
    /// **Every field is what is stored**, in the unit it is stored in, so nothing here is a second opinion about a
    /// row. The optional ones are optional because absence is a state the table can be in: the four More details are
    /// read off the cube on each login and are absent until one has answered for them, and the battery level has no
    /// store at all and arrives `nil` every time -- a remembered level being a number that was true at some moment
    /// nobody can name, which is exactly what a manufacturer string is not.
    struct Values: Equatable {
        var isPaired: Bool
        var isConnected: Bool
        var isManualMode: Bool
        var deviceName: String?
        var batteryPercent: Int?
        var manufacturer: String?
        var model: String?
        var hardware: String?
        var firmware: String?
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
            isPaired: false,
            isConnected: false,
            isManualMode: true,
            deviceName: nil,
            batteryPercent: nil,
            manufacturer: nil,
            model: nil,
            hardware: nil,
            firmware: nil,
            autoPauseMinutes: 0,
            ledBrightnessPercent: 50,
            ledBlinkSeconds: 15,
            isDoubleTapEnabled: true,
            doubleTapThreshold: 90,
            doubleTapLimit: 20,
            doubleTapLatency: 50,
            doubleTapWindow: 50
        )
    }

    private(set) var values: Values = .seeded

    /// Which half of the low-battery flash the Battery row is currently drawing. See `showLowBattery`.
    private var lowBattery = LowBatteryAlert.none

    private var nameValue: NSTextField!
    private var connectionValue: NSTextField!
    private var batteryValue: NSTextField!
    private var manufacturerValue: NSTextField!
    private var modelValue: NSTextField!
    private var hardwareValue: NSTextField!
    private var firmwareValue: NSTextField!
    private var autoPauseField: SteppedNumberField!
    private var ledBrightnessValue: NSTextField!
    private var ledBlinkValue: NSTextField!
    private var doubleTapDisableBox: NSButton!
    private var doubleTapValues: [String: NSTextField] = [:]

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

    /// Called when one of the folding rows opens or closes, so the window can record it.
    var onToggle: ((String, Bool) -> Void)?

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

        let live = DeviceInfoRules.isLive(isConnected: values.isConnected)
        nameValue.stringValue = DeviceInfoRules.name(isPaired: values.isPaired, deviceName: values.deviceName)
        connectionValue.stringValue = DeviceInfoRules.connection(
            isPaired: values.isPaired, isConnected: values.isConnected, isManualMode: values.isManualMode
        )
        batteryValue.stringValue = DeviceInfoRules.battery(
            isPaired: values.isPaired, isConnected: values.isConnected, percent: values.batteryPercent
        )
        manufacturerValue.stringValue = DeviceInfoRules.detail(isPaired: values.isPaired, reported: values.manufacturer)
        modelValue.stringValue = DeviceInfoRules.detail(isPaired: values.isPaired, reported: values.model)
        hardwareValue.stringValue = DeviceInfoRules.detail(isPaired: values.isPaired, reported: values.hardware)
        firmwareValue.stringValue = DeviceInfoRules.detail(isPaired: values.isPaired, reported: values.firmware)

        // Greyed together while nothing is live, so the placeholders sit back as the placeholders they are rather
        // than presenting as readings. See `DeviceInfoRules.isLive`.
        for field in [nameValue, connectionValue, batteryValue, manufacturerValue, modelValue, hardwareValue, firmwareValue] {
            field?.textColor = live ? .labelColor : .secondaryLabelColor
        }
        // After the greying, because the warning outranks it: the loop above has just painted the Battery row the same
        // colour as everything beside it, and a flat cube is the one row that must not read like the rest.
        paintBattery()

        // **The TimeFlip section's controls, swapped on the pairing.** Exactly one set is up at a time: looking for a
        // cube is what an app with no cube does, and once there is one the section is about managing it instead. Both
        // are hidden through the stack rather than removed, so the row keeps its height and the status label opposite
        // does not jump as the section changes state.
        scanControls.isHidden = !DevicePairingRules.showsScanControls(isPaired: values.isPaired)
        pairedControls.isHidden = !DevicePairingRules.showsPairedControls(isPaired: values.isPaired)
        // **The list of found devices goes with the Scan button**, because it is the same answer: a scan result is a
        // device the app might pair with, and once it has one there is nothing left to choose. Leaving the list up
        // would offer a row that silently drops the pairing just made (`BluetoothRadio.connect` lets go of anything
        // already connected), sitting under controls that no longer include a way to search.
        //
        // **Driven by `isPaired` here rather than cleared by whoever pairs**, so the list and the controls cannot
        // disagree: one fact decides both, and every path that reaches a pairing redraws through this method.
        if values.isPaired { showFound([]) }
        // Dead while a connect is in flight, for the reason `showReaching` greys the device rows: an attempt owns the
        // pairing state until it resolves, and dropping it from underneath one leaves the two disagreeing about
        // whether there is a device.
        forgetButton.isEnabled = DevicePairingRules.allowsForget(isPaired: values.isPaired, isReaching: isReaching)
        // Reset needs the cube, Forget does not: one is a command that has to arrive somewhere, the other is this
        // app's own rows.
        resetButton.isEnabled = DevicePairingRules.allowsReset(
            isPaired: values.isPaired, isConnected: values.isConnected, isReaching: isReaching
        )

        autoPauseField.value = values.autoPauseMinutes
        ledBrightnessValue.stringValue = "\(values.ledBrightnessPercent) %"
        ledBlinkValue.stringValue = "\(values.ledBlinkSeconds) sec"
        doubleTapDisableBox.state = values.isDoubleTapEnabled ? .off : .on
        doubleTapValues[Identifier.doubleTapThreshold]?.stringValue = "\(values.doubleTapThreshold)"
        doubleTapValues[Identifier.doubleTapLimit]?.stringValue = "\(values.doubleTapLimit)"
        doubleTapValues[Identifier.doubleTapLatency]?.stringValue = "\(values.doubleTapLatency)"
        doubleTapValues[Identifier.doubleTapWindow]?.stringValue = "\(values.doubleTapWindow)"
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
        let live = DeviceInfoRules.isLive(isConnected: values.isConnected)
        batteryValue.textColor = lowBattery.isBlinkOn ? .systemRed : (live ? .labelColor : .secondaryLabelColor)
    }

    // MARK: - the sections

    private func addSections() {
        let infoHeading = heading("Info", identifier: Identifier.infoSection)
        let infoPanel = panel(identifier: Identifier.infoPanel)
        let infoRows = stack()
        add(infoRowViews(), to: infoRows)

        let settingsHeading = heading("Settings", identifier: Identifier.settingsSection)
        let settingsPanel = panel(identifier: Identifier.settingsPanel)
        let settingsRows = stack()
        add(settingsRowViews(), to: settingsRows)

        let pairingHeading = heading("TimeFlip", identifier: Identifier.pairingSection)
        let pairingPanel = panel(identifier: Identifier.pairingPanel)
        let pairingRows = stack()
        add(pairingRowViews(), to: pairingRows)

        infoPanel.contentView?.addSubview(infoRows)
        settingsPanel.contentView?.addSubview(settingsRows)
        pairingPanel.contentView?.addSubview(pairingRows)
        for view in [infoHeading, infoPanel, settingsHeading, settingsPanel, pairingHeading, pairingPanel] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            infoHeading.topAnchor.constraint(equalTo: topAnchor, constant: Layout.padding),
            infoPanel.topAnchor.constraint(equalTo: infoHeading.bottomAnchor, constant: Layout.headingSpacing),
            settingsHeading.topAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: Layout.sectionSpacing),
            settingsPanel.topAnchor.constraint(equalTo: settingsHeading.bottomAnchor, constant: Layout.headingSpacing),
            pairingHeading.topAnchor.constraint(equalTo: settingsPanel.bottomAnchor, constant: Layout.sectionSpacing),
            pairingPanel.topAnchor.constraint(equalTo: pairingHeading.bottomAnchor, constant: Layout.headingSpacing),
            // Only as tall as its content: the sections grow down from the top of the tab rather than being stretched
            // to a height they have nothing to put in.
            pairingPanel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Layout.padding),
        ])

        // A heading may be shorter than the pane; a panel always spans it (`CLAUDE.md`: a tab's content spans the
        // width of the window, inset by the tab's own padding and nothing more).
        for view in [infoHeading, settingsHeading, pairingHeading] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
                view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.padding),
            ])
        }
        for view in [infoPanel, settingsPanel, pairingPanel] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.padding),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.padding),
            ])
        }
        // Flush to the panel on all four sides: a row runs the whole width, and its own inset is what holds the label
        // and the value off the edges. That is what puts a separator's ends where the archive's are.
        for (rows, panel) in [(infoRows, infoPanel), (settingsRows, settingsPanel), (pairingRows, pairingPanel)] {
            guard let content = panel.contentView else { continue }
            NSLayoutConstraint.activate([
                rows.topAnchor.constraint(equalTo: content.topAnchor),
                rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                rows.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    /// Name, Connection, Battery, and the four the cube only reports once it is connected.
    private func infoRowViews() -> [NSView] {
        nameValue = value(identifier: Identifier.name)
        connectionValue = value(identifier: Identifier.connection)
        batteryValue = value(identifier: Identifier.battery)
        manufacturerValue = value(identifier: Identifier.manufacturer)
        modelValue = value(identifier: Identifier.model)
        hardwareValue = value(identifier: Identifier.hardware)
        firmwareValue = value(identifier: Identifier.firmware)

        let details = stack()
        add(
            [
                row("Manufacturer", manufacturerValue, identifier: Identifier.manufacturer, separated: false),
                row("Model", modelValue, identifier: Identifier.model, separated: false),
                row("Hardware", hardwareValue, identifier: Identifier.hardware, separated: false),
                row("Firmware", firmwareValue, identifier: Identifier.firmware, separated: false),
            ],
            to: details
        )

        // **Closed.** Four rows of strings a cube reports about itself are the tab's least urgent fact, which is why
        // the archive folded them away too.
        moreRow = DisclosureRow(
            title: "More", identifier: Identifier.more, isExpanded: false, content: details
        )
        moreRow.onToggle = { [weak self] expanded in self?.onToggle?(Identifier.more, expanded) }

        return [
            row("Name", nameValue, identifier: Identifier.name, separated: true),
            row("Connection", connectionValue, identifier: Identifier.connection, separated: true),
            row("Battery", batteryValue, identifier: Identifier.battery, separated: true),
            moreRow,
        ]
    }

    /// The cube's own settings: stored here, and sent to it when there is one to send them to.
    private func settingsRowViews() -> [NSView] {
        // **Its label states the ceiling**, which is the archive's wording kept as it stands: 240 minutes is the
        // device's own limit (command 0x05), and a number the cube would refuse is worth naming before it is typed
        // rather than after. 0 disables it, which is the vendor protocol's own disabled-by-default behaviour.
        //
        // **It is given no width here**, which is what makes this row read like the App tab's four.
        // `SteppedNumberField.Layout.fieldWidth` is the one number that sizes every stepped field in the app, and a
        // width set from outside is not a second opinion about the box -- it is a cap on the whole control, box,
        // unit and arrows together. At 90 it was capping the lot at the width of the box alone, which is why this
        // one field came out narrower than the others and its arrows sat where nobody else's did.
        autoPauseField = SteppedNumberField(
            value: values.autoPauseMinutes, range: 0...240, suffix: "min", identifier: Identifier.autoPause
        )

        ledBrightnessValue = value(identifier: Identifier.ledBrightness)
        ledBlinkValue = value(identifier: Identifier.ledBlink)
        let led = stack()
        add(
            [
                row("Brightness", ledBrightnessValue, identifier: Identifier.ledBrightness, separated: false),
                row("Blink Interval", ledBlinkValue, identifier: Identifier.ledBlink, separated: false),
            ],
            to: led
        )
        ledRow = DisclosureRow(title: "LED", identifier: Identifier.led, isExpanded: false, content: led, separated: true)
        ledRow.onToggle = { [weak self] expanded in self?.onToggle?(Identifier.led, expanded) }

        // **"Disable", not "Enable".** The archive's wording, and the right way round: the setting is on by default,
        // so the box somebody ticks is the one that turns the gesture off.
        doubleTapDisableBox = NSButton(checkboxWithTitle: "Disable", target: nil, action: nil)
        doubleTapDisableBox.translatesAutoresizingMaskIntoConstraints = false
        doubleTapDisableBox.setAccessibilityIdentifier(Identifier.doubleTapDisable)

        let doubleTap = stack()
        var doubleTapRows: [NSView] = [leading(doubleTapDisableBox)]
        for (title, identifier) in [
            ("Threshold", Identifier.doubleTapThreshold),
            ("Limit", Identifier.doubleTapLimit),
            ("Latency", Identifier.doubleTapLatency),
            ("Window", Identifier.doubleTapWindow),
        ] {
            let field = value(identifier: identifier)
            doubleTapValues[identifier] = field
            doubleTapRows.append(row(title, field, identifier: identifier, separated: false))
        }
        add(doubleTapRows, to: doubleTap)
        doubleTapRow = DisclosureRow(
            title: "Double tap", identifier: Identifier.doubleTap, isExpanded: false, content: doubleTap
        )
        doubleTapRow.onToggle = { [weak self] expanded in self?.onToggle?(Identifier.doubleTap, expanded) }

        return [
            row("Auto-pause (0 disable, max 240m)", autoPauseField, identifier: Identifier.autoPause, separated: true),
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
            pair.topAnchor.constraint(greaterThanOrEqualTo: controls.topAnchor, constant: Layout.rowPadding),
            pair.bottomAnchor.constraint(lessThanOrEqualTo: controls.bottomAnchor, constant: -Layout.rowPadding),

            // The words give way before the controls do: a window too narrow for both should shorten the message,
            // not clip the button that starts the scan.
            scanStatusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: pair.trailingAnchor, constant: Layout.rowInset
            ),
            scanStatusLabel.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -Layout.rowInset),
            scanStatusLabel.centerYAnchor.constraint(equalTo: controls.centerYAnchor),

        ])
        _ = settled(controls)
        scanStatusLabel.alignment = .right
        scanStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pair.setContentCompressionResistancePriority(.required, for: .horizontal)

        scanResults = stack()
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

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(name)
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Layout.rowInset),
            separator.topAnchor.constraint(equalTo: row.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: Layout.separatorHeight),

            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            name.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -Layout.rowInset),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Layout.rowPadding),
            name.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -Layout.rowPadding),

        ])
        return settled(row)
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
        let devices = values.isPaired ? [] : devices
        for view in scanResults.arrangedSubviews {
            scanResults.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        deviceButtons = []
        add(devices.map { deviceRow($0) }, to: scanResults)
        // A list redrawn mid-attempt must not come back live. The rows are rebuilt on every advertisement, so
        // whatever the tab last decided about them has to be applied again here rather than assumed to have
        // survived -- and a scan carrying on behind a connect is exactly when this happens.
        showReaching(isReaching)
    }

    /// Whether an attempt to reach a device is in flight, which is what greys the list.
    ///
    /// **The rows go dead rather than merely being ignored.** A second press during the several seconds a connect
    /// takes is the obvious thing to do when nothing has visibly happened, and a control that quietly discards it is
    /// the one that looks broken. The status line says what is going on; this says it cannot be interrupted.
    private(set) var isReaching = false

    func showReaching(_ isReaching: Bool) {
        self.isReaching = isReaching
        // **Forget and Reset go dead with them**, and it is set here as well as in `show` because this is what actually
        // moves: an attempt begins and ends without the tab being redrawn from the table, so a rule applied only there
        // would leave the buttons live for the whole of the one moment they must not be.
        forgetButton.isEnabled = DevicePairingRules.allowsForget(isPaired: values.isPaired, isReaching: isReaching)
        resetButton.isEnabled = DevicePairingRules.allowsReset(
            isPaired: values.isPaired, isConnected: values.isConnected, isReaching: isReaching
        )
        for button in deviceButtons {
            button.isEnabled = !isReaching
        }
    }

    // MARK: - the pieces a row is made of

    private func heading(_ title: String, identifier: String) -> NSTextField {
        let heading = NSTextField(labelWithString: title)
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.setAccessibilityIdentifier(identifier)
        return heading
    }

    /// The same tinted panel the Categories tab's lists and the App tab's settings sit on.
    private func panel(identifier: String) -> NSBox {
        let panel = NSBox()
        panel.boxType = .custom
        panel.fillColor = .quaternarySystemFill
        panel.borderWidth = 0
        panel.cornerRadius = Layout.cornerRadius
        panel.contentViewMargins = .zero
        panel.titlePosition = .noTitle
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityIdentifier(identifier)
        return panel
    }

    private func stack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        // No gap: these are a list with hairlines between them, not separate controls, and the padding inside each
        // row is what keeps them apart.
        stack.spacing = 0
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

    private func value(identifier: String) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.alignment = .right
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    /// Gives a row a height that is **decided**, not merely bounded.
    ///
    /// **This is the fault this tab kept producing, three times over.** A row here is a bare `NSView`, which has no
    /// intrinsic content size, so `heightAnchor >= minimumRowHeight` is the only thing saying how tall it is -- and a
    /// minimum is not a value. Auto Layout is then free to pick anything at or above it, and inside a `.fill` stack
    /// pinned to the panel on all four sides it picks bigger: the auto-pause row drew several times its height, and
    /// once that was pinned down the slack moved to the scan controls row and did it again.
    ///
    /// The low-priority equality is what decides it. Anything real -- a taller control, a wrapped label -- outranks
    /// it and the row grows properly; with nothing pushing, the row sits at the rhythm of the list.
    ///
    /// **Every row builder on this tab ends here**, which is the point. Applying it per row is what let the third one
    /// be written without it.
    private func settled(_ row: NSView) -> NSView {
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.minimumRowHeight).isActive = true
        let preferred = row.heightAnchor.constraint(equalToConstant: Layout.minimumRowHeight)
        preferred.priority = .defaultLow
        preferred.isActive = true
        return row
    }

    /// One row: the words on the left, the value or control pinned to the right-hand edge.
    ///
    /// **The control is pinned to the trailing edge rather than following the label**, which is what the archive's
    /// form did and what makes the column line up down the right whatever the words in front of it. A fixed label
    /// column would line them up too, and park them in the middle with dead space beyond.
    private func row(_ title: String, _ control: NSView?, identifier: String, separated: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        guard let control else { return row }

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)

        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // The label gives way before the value does: a window narrow enough to squeeze one of these should
            // truncate the words, not the answer.
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -Layout.rowInset),

            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Layout.rowInset),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Layout.rowPadding),
            control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -Layout.rowPadding),

        ])

        // The control is told to hug as well, because a control with a width constraint and no height --
        // `SteppedNumberField` is exactly that -- has nothing of its own to stop it stretching and taking the row
        // with it. `settled` decides the row; this stops the control arguing with it.
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        _ = settled(row)
        guard separated else { return row }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            // From the label's left edge to the value's right one, which is where the archive drew it: a hairline
            // running the full width would cut the panel in two rather than divide a list.
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Layout.rowInset),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Layout.rowInset),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: Layout.separatorHeight),
        ])
        return row
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
        return settled(row)
    }
}

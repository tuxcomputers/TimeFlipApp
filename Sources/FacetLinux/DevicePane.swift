import CGtk
import FacetCore
import Foundation

/// The Device tab: what the app knows about a cube, the way to go and find one, and the settings that live on one.
///
/// **Two sections, as on the Mac.** *TimeFlip* is the cube itself -- what the app knows about it, with *More* folded
/// away under it, and the control that pairs or forgets one. *Settings* are what the cube is set to: stored here and
/// sent to it on connect, so they are readable and meaningful with no cube present, which is why they are drawn
/// rather than hidden.
///
/// **Every row in the second section writes, and three of them reach the cube first.** All of that is
/// `DeviceSettingRows`, which is core: the ordering the first design rule turns on -- the cube first, the table only
/// once the cube has taken it -- lives in `DeviceSettingWrite` under it, and which command each row carries lives in
/// `DeviceCommandRules`. What is here is the controls.
///
/// **The whole Settings section is dead while no cube is connected**, which is the Mac's decision and its reasoning:
/// it is a section about a cube, so it answers the question about a cube the same way in every row of it. A row
/// staying live because of how it happens to be stored would ask somebody to work out which kind each row is.
///
/// **Two things the Mac has that are not here yet**, each named rather than quietly missing:
/// - **Renaming the cube.** Its decision is still inside `SettingsWindowController`, which this box cannot compile;
///   item 17 of `docs/linux-port.md` is the Mac folding it onto `DeviceSettingWrite`, and the item says plainly that
///   it is wanted the moment a Linux Settings window wants a rename control. This is that moment.
/// - **The four double-tap registers.** They have a second gate of their own on the Mac and the one folding decision
///   about them is struck in `docs/architecture-ports-plan.md`; they wait for a device run rather than a window.
///
/// **The factory reset was the third until 2026-09-16**, when the radio grew one: `BlueZCubeRadio.factoryReset`
/// drives `CubeResetProof` and `DeviceLogin.factoryReset`, both core. Confirmed on the cube the same day -- the
/// command went out, the cube rebooted, and it came back on the vendor PIN, which is the only proof there is.
@MainActor
final class DevicePane {
    let widget: UnsafeMutablePointer<GtkWidget>

    /// What the tab shows, read in one pass when the window opens.
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
    }

    private let settings: SettingStore
    private let rows: DeviceSettingRows

    /// Where a rename says what it came to. **The only row on this tab that raises one from the pane**: the other
    /// five are answered inside `DeviceSettingRows`, which tells the same presenter, and a rename is the one whose
    /// notices differ per outcome -- including on success.
    private let dialogues: DialoguePresenter
    private let debugLog: DebugLog?
    private let battery: () -> Int?
    private let isReachingForCube: () -> Bool
    private let pair: () -> Void
    private let forget: () -> Void
    private let reset: () -> Void

    /// The three boxes whose *contents* are thrown away on every redraw, and nothing else.
    ///
    /// **The sections themselves are built once and never destroyed**, which is not tidiness: a `PanelSection` is a
    /// Swift object holding a `GtkWidget` pointer, and destroying that widget leaves the object pointing at freed
    /// memory. Packing it again on the next draw is a use-after-free, and it is the one this pane shipped with for
    /// an hour -- the app segfaulted the moment a real cube reported what it was, because that is the first thing
    /// that redraws this tab while it is open. Measured on the cube, 2026-09-16.
    private let readings: UnsafeMutablePointer<GtkWidget>
    private let moreRows: UnsafeMutablePointer<GtkWidget>
    private let controls: UnsafeMutablePointer<GtkWidget>
    private let settingRows: UnsafeMutablePointer<GtkWidget>
    private var sections: [PanelSection] = []
    private var signals = GtkSignals()

    /// The name cell on show, held for the reason every `EditableNameCell` is: it owns the handlers on its own
    /// widgets, and GTK retains the widgets rather than the Swift object around them.
    private var nameCell: EditableNameCell?
    private var values = Values(
        isCubePaired: false,
        isCubeConnected: false,
        deviceName: nil,
        batteryPercent: nil,
        manufacturer: nil,
        model: nil,
        hardware: nil,
        firmware: nil,
        pausesOnLock: true,
        batteryWarningPercent: BatteryRules.defaultWarningPercent,
        autoPauseMinutes: 0,
        ledBrightnessPercent: 0,
        ledBlinkSeconds: 0
    )

    init(
        settings: SettingStore,
        rows: DeviceSettingRows,
        dialogues: DialoguePresenter,
        battery: @escaping () -> Int?,
        isReachingForCube: @escaping () -> Bool,
        pair: @escaping () -> Void,
        forget: @escaping () -> Void,
        reset: @escaping () -> Void,
        debugLog: DebugLog?
    ) {
        self.settings = settings
        self.rows = rows
        self.dialogues = dialogues
        self.battery = battery
        self.isReachingForCube = isReachingForCube
        self.pair = pair
        self.forget = forget
        self.reset = reset
        self.debugLog = debugLog

        widget = SettingsWidgets.column(spacing: Int(SettingsMetrics.sectionSpacing))
        SettingsWidgets.identify(widget, SettingsTab.device.paneIdentifier)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(widget, Int32(SettingsMetrics.tabPadding))
        }
        let timeflipRows = SettingsWidgets.column()
        readings = SettingsWidgets.column()
        moreRows = SettingsWidgets.column()
        controls = SettingsWidgets.row(spacing: Int(SettingsMetrics.rowSpacing))
        settingRows = SettingsWidgets.column()

        let timeflip = PanelSection(
            title: "TimeFlip",
            identifier: "device-timeflip-section",
            isExpanded: true,
            content: timeflipRows
        )
        let settingsSection = PanelSection(
            title: "Settings",
            identifier: "device-settings-section",
            isExpanded: true,
            content: settingRows
        )
        // **Folds nest, and each level keeps its own default** (`CLAUDE.md`): *More* is shut inside a *TimeFlip*
        // section that is open, and both come back to their own answer because each is built fresh.
        let more = PanelSection(
            title: "More",
            identifier: "device-more",
            isExpanded: false,
            content: moreRows
        )
        for section in [timeflip, settingsSection, more] {
            section.onToggle = { [weak self] isExpanded in
                self?.debugLog?.record(.tab, "Device section \(section.title) \(isExpanded ? "opened" : "folded")")
            }
        }
        sections = [timeflip, settingsSection, more]
        // Built once, in this order, and never taken apart again: the readings, the nested fold, then the controls.
        facet_box_pack_start(timeflipRows, readings, 0, 1, 0)
        facet_box_pack_start(timeflipRows, more.widget, 0, 1, 0)
        facet_box_pack_start(timeflipRows, controls, 0, 1, 0)
        facet_box_pack_start(widget, timeflip.widget, 0, 1, 0)
        facet_box_pack_start(widget, settingsSection.widget, 0, 1, 0)
    }

    /// What this pane does about a write that did not land: read the whole tab again.
    ///
    /// **Blunter than the Mac's, and it can afford to be.** There each row has a `show*` that puts one field back,
    /// because its fields are debounced and a second write can be out while the first is being answered. Nothing
    /// here is debounced -- GTK emits `value-changed` when a value settles rather than per tick -- so a rebuild
    /// cannot take an edit off the screen that a write has not already been made for.
    ///
    /// **Worth revisiting the first time somebody holds an arrow down against a real cube**, which is the note the
    /// stepper carries: if a held arrow turns out to queue commands, this becomes the fault the Mac's two halves
    /// exist to avoid and this pane needs them too.
    private func settled(_ outcome: DeviceSettingWrite.Outcome) {
        guard outcome.putsTheRowBack else { return }
        reload()
    }

    /// Reads every value this tab shows, in one go.
    func reload() {
        values = Values(
            isCubePaired: settings.flag("paired", field: "paired") ?? false,
            isCubeConnected: settings.flag("connection", field: "connected") ?? false,
            deviceName: settings.string("device_name", field: "name"),
            // **Not a row.** The charge has no setting of its own and is not going to get one, so it comes from the
            // radio at the moment the tab is drawn.
            batteryPercent: battery(),
            manufacturer: settings.string("device_info", field: "manufacturer"),
            model: settings.string("device_info", field: "model"),
            hardware: settings.string("device_info", field: "hardware"),
            firmware: settings.string("device_info", field: "firmware"),
            pausesOnLock: settings.flag("pause_on_lock", field: "enabled") ?? true,
            batteryWarningPercent: settings.integer("low_battery_level", field: "percent")
                ?? BatteryRules.defaultWarningPercent,
            autoPauseMinutes: settings.integer("auto_pause_minutes", field: "minutes") ?? 0,
            ledBrightnessPercent: settings.integer("led_settings", field: "brightness") ?? 0,
            ledBlinkSeconds: settings.integer("led_settings", field: "blink_interval") ?? 0
        )
        redraw()
    }

    private func redraw() {
        for child in SettingsWidgets.children(of: readings)
            + SettingsWidgets.children(of: moreRows)
            + SettingsWidgets.children(of: controls)
            + SettingsWidgets.children(of: settingRows)
        {
            gtk_widget_destroy(child)
        }
        signals = GtkSignals()
        nameCell = nil
        drawTimeFlip()
        drawSettings()
        gtk_widget_show_all(widget)
    }

    // MARK: - what the app knows about a cube

    /// **Every reading's wording is `DeviceInfoRules`'**, including the three different kinds of "no device": not
    /// paired, paired but unreachable, and paired and connected but not having said yet.
    private func drawTimeFlip() {
        facet_box_pack_start(readings, nameRow(), 0, 1, 0)
        facet_box_pack_start(
            readings,
            reading(
                "Connection",
                DeviceInfoRules.connection(isCubePaired: values.isCubePaired, isCubeConnected: values.isCubeConnected),
                "device-connection"
            ),
            0, 1, 0
        )
        facet_box_pack_start(
            readings,
            reading(
                "Battery",
                DeviceInfoRules.battery(
                    isCubePaired: values.isCubePaired,
                    isCubeConnected: values.isCubeConnected,
                    batteryPercent: values.batteryPercent
                ),
                "device-battery"
            ),
            0, 1, 0
        )

        for (label, value, identifier) in [
            ("Manufacturer", values.manufacturer, "device-manufacturer"),
            ("Model", values.model, "device-model"),
            ("Hardware", values.hardware, "device-hardware"),
            ("Firmware", values.firmware, "device-firmware"),
        ] {
            facet_box_pack_start(
                moreRows,
                reading(label, DeviceInfoRules.detail(isCubePaired: values.isCubePaired, reported: value), identifier),
                0, 1, 0
            )
        }
        // **Which controls are offered is `DevicePairingRules`'**, asked here rather than decided: an app with a
        // cube on record offers to forget it, and one without offers to go and find one.
        if DevicePairingRules.showsScanControls(isCubePaired: values.isCubePaired) {
            let button = gtk_button_new_with_label("Pair a cube")!
            SettingsWidgets.identify(button, "device-pair")
            // Dead while a login is already out, for the reason forgetting is: a second attempt on top of the first
            // is two conversations with one cube.
            gtk_widget_set_sensitive(button, isReachingForCube() ? 0 : 1)
            signals.connect(button, "clicked") { [weak self] in
                self?.debugLog?.record(.pair, "Button clicked: Pair a cube")
                self?.pair()
            }
            facet_box_pack_start(controls, button, 0, 0, 0)
        }
        if DevicePairingRules.showsPairedControls(isCubePaired: values.isCubePaired) {
            let button = gtk_button_new_with_label("Forget this cube")!
            SettingsWidgets.identify(button, "device-forget")
            gtk_widget_set_sensitive(
                button,
                DevicePairingRules.allowsForget(
                    isCubePaired: values.isCubePaired,
                    isReachingForCube: isReachingForCube()
                ) ? 1 : 0
            )
            signals.connect(button, "clicked") { [weak self] in
                self?.debugLog?.record(.pair, "Button clicked: Forget this cube")
                self?.forget()
            }
            facet_box_pack_start(controls, button, 0, 0, 0)

            // **Only while the cube is actually connected**, which is `DevicePairingRules.allowsReset` and is
            // stricter than forgetting: forgetting is a change to this app's own record and can be made about a
            // cube nobody can hear, where a wipe is a command that has to reach one.
            let wipe = gtk_button_new_with_label("Reset device")!
            SettingsWidgets.identify(wipe, "device-reset")
            gtk_widget_set_sensitive(
                wipe,
                DevicePairingRules.allowsReset(
                    isCubePaired: values.isCubePaired,
                    isCubeConnected: values.isCubeConnected,
                    isReachingForCube: isReachingForCube()
                ) ? 1 : 0
            )
            signals.connect(wipe, "clicked") { [weak self] in
                self?.debugLog?.record(.pair, "Button clicked: Reset device")
                self?.reset()
            }
            facet_box_pack_start(controls, wipe, 0, 0, 0)
        }
    }

    // MARK: - what the cube is set to

    private func drawSettings() {
        // **One gate for the whole section**, which is `drawSettingsGate` on the Mac: these are settings about a
        // cube, and with none connected there is nothing for any of them to reach.
        let isLive = values.isCubeConnected

        let pauseBox = gtk_check_button_new_with_label("Pause the device when locking it")!
        SettingsWidgets.identify(pauseBox, "device-pause-on-lock")
        facet_toggle_set_active(pauseBox, values.pausesOnLock ? 1 : 0)
        gtk_widget_set_sensitive(pauseBox, isLive ? 1 : 0)
        signals.connect(pauseBox, "toggled") { [weak self] in
            guard let self else { return }
            let wanted = facet_toggle_get_active(pauseBox) != 0
            guard wanted != values.pausesOnLock else { return }
            values.pausesOnLock = wanted
            rows.pauseOnLock(wanted, then: settled)
        }
        facet_box_pack_start(settingRows, row("", control: pauseBox, live: isLive), 0, 1, 0)

        facet_box_pack_start(
            settingRows,
            stepper(
                "Battery warning at",
                value: values.batteryWarningPercent,
                range: BatteryRules.warningRange,
                suffix: "percent",
                identifier: "device-battery-warning",
                live: isLive
            ) { [weak self] percent in
                self?.values.batteryWarningPercent = percent
                self?.rows.batteryWarning(percent) { [weak self] in self?.settled($0) }
            },
            0, 1, 0
        )
        facet_box_pack_start(
            settingRows,
            stepper(
                "Pause the device after",
                value: values.autoPauseMinutes,
                range: DeviceCommandRules.autoPauseRange,
                suffix: "min",
                identifier: "device-auto-pause",
                live: isLive
            ) { [weak self] minutes in
                self?.values.autoPauseMinutes = minutes
                self?.rows.autoPause(minutes) { [weak self] in self?.settled($0) }
            },
            0, 1, 0
        )
        facet_box_pack_start(
            settingRows,
            stepper(
                "LED brightness",
                value: values.ledBrightnessPercent,
                range: DeviceCommandRules.brightnessRange,
                suffix: "percent",
                identifier: "device-led-brightness",
                live: isLive
            ) { [weak self] percent in
                self?.values.ledBrightnessPercent = percent
                self?.rows.ledBrightness(percent) { [weak self] in self?.settled($0) }
            },
            0, 1, 0
        )
        facet_box_pack_start(
            settingRows,
            stepper(
                "LED blink interval",
                value: values.ledBlinkSeconds,
                range: DeviceCommandRules.blinkRange,
                suffix: "sec",
                identifier: "device-led-blink",
                live: isLive
            ) { [weak self] seconds in
                self?.values.ledBlinkSeconds = seconds
                self?.rows.ledBlink(seconds) { [weak self] in self?.settled($0) }
            },
            0, 1, 0
        )
    }

    // MARK: - the shapes a row comes in

    private func reading(_ label: String, _ value: String, _ identifier: String) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row()
        gtk_widget_set_size_request(line, -1, Int32(SettingsMetrics.rowHeight))
        facet_box_pack_start(line, SettingsWidgets.label(label), 0, 1, 0)
        let text = SettingsWidgets.label(value)
        SettingsWidgets.identify(text, identifier, saying: value)
        facet_box_pack_end(line, text, 0, 0, 0)
        return line
    }

    /// The cube's own name, which is a reading until it is clicked and a field after that.
    ///
    /// **The same cell the Categories tab renames a category with**, which is deliberate: a name edited in place
    /// behaves the same way wherever this app offers one -- Return commits, Escape abandons, a click elsewhere
    /// abandons.
    ///
    /// **Editable only while a cube is connected.** A rename is a command, so with nothing to send it to there is
    /// nothing the field could do but fail -- and `DeviceInfoRules.name` is already saying *Not paired* in that
    /// case, which is a reading rather than a value to edit.
    private func nameRow() -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row()
        gtk_widget_set_size_request(line, -1, Int32(SettingsMetrics.rowHeight))
        facet_box_pack_start(line, SettingsWidgets.label("Name"), 0, 1, 0)

        let cell = EditableNameCell(
            name: DeviceInfoRules.name(isCubePaired: values.isCubePaired, deviceName: values.deviceName),
            identifier: "device-name",
            isEnabled: values.isCubeConnected,
            refusalHelp: values.isCubeConnected ? nil : "Connect to the cube to rename it"
        )
        cell.onCommit = { [weak self] typed in self?.rename(to: typed) }
        nameCell = cell
        facet_box_pack_end(line, cell.widget, 0, 0, 0)
        return line
    }

    /// Sends a typed name to the cube, and says whatever the sequence answers with.
    ///
    /// **The row is re-read on every outcome, success included**, which is where a rename departs from the other
    /// five: the field has committed and closed itself by then, and on success the new name is exactly what the row
    /// should start showing.
    private func rename(to typed: String) {
        rows.rename(to: typed, replacing: values.deviceName) { [weak self] notice in
            guard let self else { return }
            reload()
            guard let notice else { return }
            dialogues.tell(notice)
        }
    }

    /// A number with arrows, bounded by the command that carries it.
    ///
    /// **The ranges come from `DeviceCommandRules` and `BatteryRules`**, never written down here: what a cube will
    /// take is a fact about the command, and a field that offered more than the wire does would be a control that
    /// cannot mean what it says.
    ///
    /// **`value-changed` rather than a debounce.** The Mac debounces these because an arrow held down produces a
    /// value a tenth of a second at a time and only the last one is meant; GTK emits this when the value settles --
    /// on Return, on focus leaving, and on each arrow -- so a held arrow is one write per step rather than per tick.
    /// Worth revisiting the first time somebody watches a held arrow send a queue of commands to a real cube.
    private func stepper(
        _ label: String,
        value: Int,
        range: ClosedRange<Int>,
        suffix: String,
        identifier: String,
        live: Bool,
        onChange: @escaping (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let field = gtk_spin_button_new_with_range(Double(range.lowerBound), Double(range.upperBound), 1)!
        SettingsWidgets.identify(field, identifier)
        facet_spin_set_value(field, Double(value))
        gtk_widget_set_sensitive(field, live ? 1 : 0)
        signals.connect(field, "value-changed") { [weak self] in
            guard self != nil else { return }
            let wanted = Int(facet_spin_get_value_as_int(field))
            guard wanted != value else { return }
            onChange(wanted)
        }
        return row(label, control: field, suffix: suffix, live: live)
    }

    private func row(
        _ label: String,
        control: UnsafeMutablePointer<GtkWidget>,
        suffix: String? = nil,
        live: Bool = true
    ) -> UnsafeMutablePointer<GtkWidget> {
        let line = SettingsWidgets.row()
        gtk_widget_set_size_request(line, -1, Int32(SettingsMetrics.rowHeight))
        if !label.isEmpty {
            let text = SettingsWidgets.label(label)
            // The label greys with its control, so a dead row reads as one thing rather than as a live name beside
            // a dead field.
            gtk_widget_set_sensitive(text, live ? 1 : 0)
            facet_box_pack_start(line, text, 0, 1, 0)
        }
        // **The unit first, because `pack_end` stacks inward from the right**: whichever is packed first is
        // rightmost, so packing the control first put "percent" on the wrong side of the number. Seen on screen
        // rather than reasoned about.
        if let suffix {
            let unit = SettingsWidgets.secondary(suffix)
            gtk_widget_set_sensitive(unit, live ? 1 : 0)
            facet_box_pack_end(line, unit, 0, 0, 0)
        }
        facet_box_pack_end(line, control, 0, 0, 0)
        return line
    }
}

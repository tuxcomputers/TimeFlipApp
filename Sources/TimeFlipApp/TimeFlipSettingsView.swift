import SwiftUI

struct TimeFlipSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var autoPauseValue: Int = 0
    @State private var lastAppliedAutoPause: UInt16 = 0
    @State private var ledBrightnessValue: Int = 50
    @State private var lastAppliedLEDBrightness: UInt8 = 50
    @State private var blinkIntervalValue: Int = 5
    @State private var lastAppliedBlinkInterval: UInt8 = 5
    @State private var doubleTapParams: DoubleTapParameters = .default
    @State private var scanAllDevices: Bool = false
    @State private var showingFactoryResetConfirmation: Bool = false

    var body: some View {
        Form {
            deviceSection
            settingsSection
            pairingSection
        }
        .formStyle(.grouped)
        .onAppear(perform: syncViewState)
        .onChange(of: appState.autoPauseMinutes) { _, newValue in
            autoPauseValue = Int(newValue)
            lastAppliedAutoPause = newValue
        }
        .onChange(of: appState.ledBrightnessPercent) { _, newValue in
            let clamped = max(1, min(100, Int(newValue)))
            ledBrightnessValue = clamped
            lastAppliedLEDBrightness = UInt8(clamped)
        }
        .onChange(of: appState.blinkIntervalSeconds) { _, newValue in
            let clamped = max(5, min(60, Int(newValue)))
            blinkIntervalValue = clamped
            lastAppliedBlinkInterval = UInt8(clamped)
        }
        .onChange(of: appState.doubleTapParameters) { _, newValue in
            doubleTapParams = newValue
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        Section("Info") {
            LabeledContent("Name") {
                Text(appState.pairedDeviceName)
                    .foregroundStyle(infoValueColor)
            }
            LabeledContent("Connection") {
                Text(statusText)
                    .foregroundStyle(infoValueColor)
            }
            LabeledContent {
                Text(batteryText)
                    .foregroundStyle(batteryTextColor)
            } label: {
                Text("Battery")
                    .foregroundStyle(batteryLabelColor)
            }
            DisclosureGroup(isExpanded: $appState.isMoreExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Manufacturer") {
                        Text(manufacturerText)
                    }
                    LabeledContent("Model") {
                        Text(modelText)
                    }
                    LabeledContent("Hardware") {
                        Text(hardwareText)
                    }
                    LabeledContent("Firmware") {
                        Text(firmwareText)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                DisclosureRowLabel("More", isExpanded: appState.isMoreExpanded) {
                    appState.isMoreExpanded.toggle()
                }
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            LabeledContent("Auto-pause (0 disable, max 240m)") {
                autoPauseControls
            }
            .disabled(!appState.isConnected)
            DisclosureGroup(isExpanded: $appState.isLEDExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Brightness") {
                        brightnessControls
                    }
                    .disabled(!appState.isConnected)
                    LabeledContent("Blink Interval") {
                        blinkIntervalControls
                    }
                    .disabled(!appState.isConnected)
                }
                .padding(.vertical, 4)
            } label: {
                DisclosureRowLabel("LED", isExpanded: appState.isLEDExpanded) {
                    appState.isLEDExpanded.toggle()
                }
            }
            DisclosureGroup(isExpanded: $appState.isDoubleTapExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Disable", isOn: Binding(
                        get: { !appState.isDoubleTapEnabled },
                        set: { setDoubleTapEnabled(!$0) }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(!appState.isConnected)
                    doubleTapControls
                        .disabled(!appState.isConnected || !appState.isDoubleTapEnabled)
                }
                .padding(.vertical, 4)
            } label: {
                DisclosureRowLabel("Double tap", isExpanded: appState.isDoubleTapExpanded) {
                    appState.isDoubleTapExpanded.toggle()
                }
            }
        }
    }

    private var pairingSection: some View {
        Section("TimeFlip") {
            HStack {
                if appState.connectionStatus == .resetting {
                    // Reset confirmed and in progress: show only a progress indicator -- no Forget/
                    // Reset buttons, so they can't be clicked mid-reset and disrupt the confirm cycle.
                    ProgressView()
                        .controlSize(.small)
                    Text("Resetting device…")
                        .foregroundStyle(.secondary)
                } else if appState.isPaired {
                    Button("Forget Device") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Forget Device")
                        Task { await appState.resetAndForgetDevice() }
                    }
                    .disabled(appState.connectionStatus == .pairing)

                    Button("Reset Device") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Reset Device")
                        showingFactoryResetConfirmation = true
                    }
                    .disabled(appState.connectionStatus == .pairing)
                    .confirmationDialog(
                        "Reset this TimeFlip to factory settings?",
                        isPresented: $showingFactoryResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reset Device", role: .destructive) {
                            DeveloperMode.debugPrint(.click, "Button clicked: Reset Device (confirm factory reset)")
                            Task { await appState.factoryResetAndForgetDevice() }
                        }
                        Button("Cancel", role: .cancel) {
                            DeveloperMode.debugPrint(.click, "Button clicked: Cancel (factory-reset dialog)")
                        }
                    } message: {
                        Text("""
                        This erases everything stored on the device -- facet colors, task \
                        settings, name, and password -- back to factory defaults. This cannot be \
                        undone.
                        """)
                    }
                } else {
                    Button(appState.isScanningForDevices ? "Stop Scan" : "Scan for Devices") {
                        if appState.isScanningForDevices {
                            DeveloperMode.debugPrint(.click, "Button clicked: Stop Scan")
                            appState.stopDeviceScan()
                        } else {
                            DeveloperMode.debugPrint(.click, "Button clicked: Scan for Devices (allDevices=\(scanAllDevices))")
                            appState.startDeviceScan(filterToTimeFlip: !scanAllDevices)
                        }
                    }
                    Toggle("All Devices", isOn: $scanAllDevices)
                        .toggleStyle(.checkbox)
                        .disabled(appState.isScanningForDevices)
                        .onChange(of: scanAllDevices) { oldValue, newValue in
                            DeveloperMode.debugPrint(.field, "Field changed: All Devices toggle: \(oldValue) -> \(newValue)")
                        }
                    if appState.isScanningForDevices {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            if !appState.isPaired, !appState.discoveredDevices.isEmpty {
                Text("Click a device below to pair with it.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.discoveredDevices) { device in
                        let isInvalid = appState.invalidDeviceIDs.contains(device.id)
                        let statusMessage = appState.deviceStatusMessages[device.id]
                        HStack(spacing: 6) {
                            Text(device.name)
                                .strikethrough(isInvalid)
                                .foregroundStyle(isInvalid ? .secondary : .primary)
                            if let statusMessage {
                                if statusMessage.hasPrefix("Connecting…") {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(statusMessage)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            DeveloperMode.debugPrint(.click, "Discovered-device row tapped: \(device.name)\(isInvalid ? " (invalid, ignored)" : "")")
                            guard !isInvalid else { return }
                            let wasThisDevicePending = appState.connectionStatus == .pairing
                                && appState.pendingPairingDeviceID == device.id
                            if appState.connectionStatus == .pairing {
                                appState.cancelPairingAttempt()
                            }
                            guard !wasThisDevicePending else { return }
                            appState.selectDiscoveredDevice(device)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Controls

    // Both LED values step with held arrows rather than dragging a slider. A slider commits a value
    // per pixel of travel, and every commit is a device write once the 1s debounce settles -- see the
    // brightness run in the 19:32 debug log, where one drag logged 30-odd changes. Arrows commit one
    // step at a time, and the range is small enough to cross by holding.
    private var brightnessControls: some View {
        SteppedNumberField(
            appState: appState,
            holdKey: "ledBrightness",
            value: ledBrightnessValue,
            range: 1...100,
            suffix: "%",
            fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth(
                suffixWidth: SettingsLayoutConstants.Stepper.percentSuffixWidth
            ),
            suffixWidth: SettingsLayoutConstants.Stepper.percentSuffixWidth,
            onCommit: { applyLEDBrightness(newValue: $0) }
        )
    }

    private var blinkIntervalControls: some View {
        SteppedNumberField(
            appState: appState,
            holdKey: "blinkInterval",
            value: blinkIntervalValue,
            range: 5...60,
            suffix: "sec",
            fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth(
                suffixWidth: SettingsLayoutConstants.Stepper.secondsSuffixWidth
            ),
            suffixWidth: SettingsLayoutConstants.Stepper.secondsSuffixWidth,
            onCommit: { applyBlinkInterval(newValue: $0) }
        )
    }

    // Field, then suffix, then arrows -- the order every other stepper in the window uses
    // (SteppedNumberField), so the arrows sit on the right of the row rather than ahead of the value.
    private var autoPauseControls: some View {
        HStack(spacing: SettingsLayoutConstants.Stepper.itemSpacing) {
            TextField(
                "",
                value: Binding(
                    get: { autoPauseValue },
                    set: { applyAutoPause(newValue: $0) }
                ),
                format: .number
            )
            .frame(width: 50)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            Text("min")
                .foregroundStyle(.secondary)
            // A plain SwiftUI Stepper's press-and-hold repeat runs at a fixed system rate we
            // can't vary, so the accelerating-then-slower behavior (see AutoPauseStepper) needs
            // custom buttons driving our own repeat loop instead.
            VStack(spacing: SettingsLayoutConstants.Stepper.arrowSpacing) {
                autoPauseStepButton(direction: 1, systemImage: "chevron.up")
                autoPauseStepButton(direction: -1, systemImage: "chevron.down")
            }
        }
    }

    private func autoPauseStepButton(direction: Int, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: SettingsLayoutConstants.Stepper.arrowPointSize, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(
                width: SettingsLayoutConstants.Stepper.arrowsWidth,
                height: SettingsLayoutConstants.Stepper.arrowHeight
            )
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 50, pressing: { isPressing in
                if isPressing {
                    guard appState.isConnected, appState.autoPauseHoldDirection != direction else { return }
                    DeveloperMode.debugPrint(.click, "Button clicked: Auto-pause \(direction > 0 ? "up" : "down") arrow")
                    appState.autoPauseHoldDirection = direction
                    let startValue = autoPauseValue
                    applyAutoPause(newValue: startValue + direction)
                    beginAutoPauseHold(direction: direction, startValue: startValue)
                } else if appState.autoPauseHoldDirection == direction {
                    appState.autoPauseHoldDirection = nil
                    endAutoPauseHold()
                }
            }, perform: {})
    }

    // Label, hint, then field: the fields form a column down the right of the group, all one size,
    // ending where the stepper rows above them end. The hint in the middle absorbs the difference
    // between the four labels and the four hint lengths.
    private var doubleTapControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Threshold")
                doubleTapFieldCaption("Lower number = lighter tap needed (0-255 scale)")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.clickThreshold },
                        set: { doubleTapParams.clickThreshold = $0 }
                    )
                )
            }
            GridRow {
                Text("Limit")
                doubleTapFieldCaption("Lower number = sharper, quicker tap needed (0-255 scale)")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.limit },
                        set: { doubleTapParams.limit = $0 }
                    )
                )
            }
            GridRow {
                Text("Latency")
                doubleTapFieldCaption("Lower number = sooner it starts listening for the 2nd tap (0-255 scale)")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.latency },
                        set: { doubleTapParams.latency = $0 }
                    )
                )
            }
            GridRow {
                Text("Window")
                doubleTapFieldCaption("Lower number = less time to land the 2nd tap once listening (0-255 scale)")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.window },
                        set: { doubleTapParams.window = $0 }
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The hint between a row's label and its field. Takes the slack in the middle of the row, which
    /// is what pushes the fields over to the right.
    private func doubleTapFieldCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numericField(
        value: Binding<UInt8>
    ) -> some View {
        TextField(
            "",
            value: Binding(
                get: { Int(value.wrappedValue) },
                set: { newValue in
                    let clamped = UInt8(max(0, min(255, newValue)))
                    value.wrappedValue = clamped
                    applyDoubleTapParameters(doubleTapParams)
                }
            ),
            format: .number
        )
        // The same block width every other value control in the window occupies, so these fields end
        // on the same right edge as the steppers' arrows above them. They carry no suffix and no
        // arrows of their own, so the whole width goes to the field.
        .frame(width: SettingsLayoutConstants.Stepper.rowWidth)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
    }

    // MARK: - Helpers

    private func syncViewState() {
        let minutes = appState.autoPauseMinutes
        autoPauseValue = Int(minutes)
        lastAppliedAutoPause = minutes
        let brightness = appState.ledBrightnessPercent
        ledBrightnessValue = Int(brightness)
        lastAppliedLEDBrightness = brightness
        let blink = appState.blinkIntervalSeconds
        blinkIntervalValue = Int(blink)
        lastAppliedBlinkInterval = blink
        doubleTapParams = appState.doubleTapParameters
    }

    private func applyAutoPause(newValue: Int) {
        guard appState.isConnected else { return }
        let clamped = max(0, min(240, newValue))
        autoPauseValue = clamped
        let minutes = UInt16(clamped)
        guard minutes != lastAppliedAutoPause else { return }
        DeveloperMode.debugPrint(.field, "Field changed: Auto-pause: \(lastAppliedAutoPause)m -> \(minutes)m")
        lastAppliedAutoPause = minutes
        appState.autoPauseMinutes = minutes
        appState.onAutoPauseChange?(minutes)
    }

    /// Starts the repeat loop for a held auto-pause arrow. `startValue` is the value from just
    /// before this hold began -- fixed for the whole hold, since it's what AutoPauseStepper uses
    /// to compute the boundary where ticking switches from step 1 to step 5.
    private func beginAutoPauseHold(direction: Int, startValue: Int) {
        appState.autoPauseHoldTask?.cancel()
        appState.autoPauseHoldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(AutoPauseStepper.initialHoldDelay * 1_000_000_000))
            while !Task.isCancelled {
                let current = autoPauseValue
                let next = AutoPauseStepper.nextValue(current: current, holdStartValue: startValue, direction: direction)
                applyAutoPause(newValue: next)
                // Interval before the *next* tick is based on the value just reached (next), not
                // the pre-tick value -- otherwise the first step-5 tick after crossing the
                // boundary fires at the fast single-digit cadence instead of the slower one.
                let interval = AutoPauseStepper.tickInterval(current: next, holdStartValue: startValue, direction: direction)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func endAutoPauseHold() {
        appState.autoPauseHoldTask?.cancel()
        appState.autoPauseHoldTask = nil
    }

    private func applyLEDBrightness(newValue: Int) {
        guard appState.isConnected else { return }
        let clamped = max(1, min(100, newValue))
        ledBrightnessValue = clamped
        let percent = UInt8(clamped)
        guard percent != lastAppliedLEDBrightness else { return }
        DeveloperMode.debugPrint(.field, "Field changed: LED brightness: \(lastAppliedLEDBrightness)% -> \(percent)%")
        lastAppliedLEDBrightness = percent
        appState.ledBrightnessPercent = percent
        appState.onLEDBrightnessChange?(percent)
    }

    private func applyBlinkInterval(newValue: Int) {
        guard appState.isConnected else { return }
        let clamped = max(5, min(60, newValue))
        blinkIntervalValue = clamped
        let seconds = UInt8(clamped)
        guard seconds != lastAppliedBlinkInterval else { return }
        DeveloperMode.debugPrint(.field, "Field changed: LED blink interval: \(lastAppliedBlinkInterval)s -> \(seconds)s")
        lastAppliedBlinkInterval = seconds
        appState.blinkIntervalSeconds = seconds
        appState.onBlinkIntervalChange?(seconds)
    }

    private func applyDoubleTapParameters(_ params: DoubleTapParameters) {
        guard appState.isConnected else { return }
        DeveloperMode.debugPrint(.field, "Field changed: Double-tap params: ths=\(params.clickThreshold) lim=\(params.limit) lat=\(params.latency) win=\(params.window)")
        doubleTapParams = params
        appState.doubleTapParameters = params
        appState.onDoubleTapParametersChange?(effectiveDoubleTapParameters(params), false)
        appState.onDoubleTapSettingsPersist?(params, appState.isDoubleTapEnabled)
    }

    private func setDoubleTapEnabled(_ enabled: Bool) {
        guard appState.isConnected else { return }
        DeveloperMode.debugPrint(.field, "Field changed: Double-tap enabled: \(appState.isDoubleTapEnabled) -> \(enabled)")
        appState.isDoubleTapEnabled = enabled
        // A checkbox, not a value being dialled in: send it straight away rather than debouncing.
        appState.onDoubleTapParametersChange?(effectiveDoubleTapParameters(doubleTapParams), true)
        appState.onDoubleTapSettingsPersist?(doubleTapParams, enabled)
    }

    /// The real, on-screen parameters when enabled; the same parameters with `window` forced to
    /// 0 when disabled -- window 0 makes the accelerometer's double-tap gesture unrecognizable,
    /// which is how "disable" is faked without a real on/off on the device itself.
    private func effectiveDoubleTapParameters(_ params: DoubleTapParameters) -> DoubleTapParameters {
        guard appState.isDoubleTapEnabled else {
            var zeroed = params
            zeroed.window = 0
            return zeroed
        }
        return params
    }

    /// Whether the Info rows are showing values that mean something right now. True while
    /// connected, and kept true through a `.reconnecting` blip so the last known name/battery stay
    /// solid rather than flickering grey every time the device dips out of range. Everything else
    /// -- never paired, paired but not reached yet, pairing, resetting, failed -- reads as stale.
    ///
    /// Note this is deliberately not `isPaired`: a paired app that hasn't reached its device since
    /// launch has a device name to show but no live values behind it.
    private var isShowingLiveValues: Bool {
        appState.isConnected || appState.connectionStatus == .reconnecting
    }

    /// Name/Connection value colour: black (primary) while the values are live, greyed (secondary)
    /// otherwise -- so the Info values read solid black when there's a device behind them,
    /// matching the battery %, and fall back to grey together when there isn't.
    private var infoValueColor: Color {
        isShowingLiveValues ? .primary : .secondary
    }

    private var batteryText: String {
        // No device at all is a different answer from a device we just can't hear from.
        guard appState.isPaired else {
            return "Not paired"
        }
        guard isShowingLiveValues, let level = appState.batteryLevel else {
            return "Unknown"
        }
        return "\(level)%"
    }

    /// The battery *value* colour: greyed (secondary) when the reading isn't live, so "Not
    /// paired"/"Unknown" match the Name/Connection rows; otherwise it flashes red/default in sync
    /// with the menu bar's low-battery blink (see `batteryLabelColor`).
    private var batteryTextColor: Color {
        if !isShowingLiveValues { return .secondary }
        return batteryLabelColor
    }

    /// The "Battery" *label* colour: primary like the other row labels, but still flashes red with
    /// the low-battery blink (mirrored via AppState.isLowBattery/lowBatteryBlinkPhaseOn) so a
    /// first-time low-battery warning is obvious here too, not just in the menu bar text.
    private var batteryLabelColor: Color {
        guard appState.isLowBattery else { return .primary }
        return appState.lowBatteryBlinkPhaseOn ? .red : .primary
    }

    private var manufacturerText: String {
        appState.deviceInfo?.manufacturer ?? "Unknown"
    }

    private var modelText: String {
        appState.deviceInfo?.modelNumber ?? "Unknown"
    }

    private var hardwareText: String {
        appState.deviceInfo?.hardwareRevision ?? "Unknown"
    }

    private var firmwareText: String {
        appState.deviceInfo?.firmwareRevision ?? "Unknown"
    }

    private var statusText: String {
        switch appState.connectionStatus {
        case .disconnected:
            // The connection is down either way; which of the two it is depends on whether there
            // is a device to be disconnected *from*.
            return appState.isPaired ? "Disconnected" : "Not paired"
        case .pairing:
            if let name = appState.pendingPairingDeviceName {
                return "Trying to pair with \(name)....."
            }
            return "Pairing..."
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting..."
        case .resetting:
            return "Resetting..."
        case .failed(let message):
            return "Failed" + (message.map { ": \($0)" } ?? "")
        }
    }

}

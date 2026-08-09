import SwiftUI

struct TimeFlipSettingsView: View {
    /// The device's own ceiling on the auto-pause delay, named so the stepper's range and
    /// `applyAutoPause`'s clamp cannot drift apart -- and so the row's label, which states the
    /// limit to the user, has something to be checked against.
    static let maximumAutoPauseMinutes = 240
    /// The 0-255 range every double-tap register accepts, per the vendor spec's 0x16 command.
    static let doubleTapRegisterRange = 0...255

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
    @State private var isEditingDeviceName: Bool = false
    @State private var draftDeviceName: String = ""
    @State private var deviceNameProblem: DeviceNameProblem?
    @FocusState private var isDeviceNameFieldFocused: Bool

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
                deviceNameValue
            }
            // On the whole LabeledContent, not just the value: the right-click target is the row,
            // so the "Name" label and the gap between it and the value open the menu too. The
            // content shape is what makes that gap hittable -- without it the menu only opens over
            // the glyphs themselves, which on a short name is a small target.
            .contentShape(Rectangle())
            .contextMenu { renameMenuItems }
            // Title from the problem itself, the same way the Categories tab titles its rename
            // alert: "the cube cannot hold this" and "the cube did not answer" are different
            // problems and a single heading covering both would misdirect one of them.
            .alert(
                deviceNameProblem?.title ?? "",
                isPresented: Binding(
                    get: { deviceNameProblem != nil },
                    set: { if !$0 { deviceNameProblem = nil } }
                ),
                presenting: deviceNameProblem
            ) { _ in
                Button("OK", role: .cancel) { deviceNameProblem = nil }
            } message: { problem in
                Text(problem.message)
            }
            // Set by a rename and cleared once the device reports the new name, so it is on screen
            // for exactly as long as the app and the device disagree about what the cube is called.
            // A caption under the row rather than an alert: a successful rename should not need
            // dismissing, and this is most useful sitting there while the user goes and looks at a
            // scan list showing the old name. See DeviceNameRules.renameLagNotice.
            if let notice = appState.renameLagNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rename-lag-notice")
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

    /// Read-only until Rename is chosen from the row's right-click menu, then an inline field.
    /// Return submits, Escape abandons the edit. Mirrors the Categories tab's inline rename, which
    /// is the pattern this app already renames things by.
    @ViewBuilder
    private var deviceNameValue: some View {
        if isEditingDeviceName {
            TextField("", text: $draftDeviceName)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($isDeviceNameFieldFocused)
                .onAppear {
                    // Deferred a runloop turn: at onAppear the field is not yet in the window's
                    // responder chain, so focusing it synchronously is dropped.
                    DispatchQueue.main.async { isDeviceNameFieldFocused = true }
                }
                // Holds the field to what command 0x15 can carry. Length only -- a character the
                // device cannot take is left visible and refused on submit, so the user is told
                // why rather than watching a keystroke vanish (see DeviceNameRules).
                .onChange(of: draftDeviceName) { _, typed in
                    let truncated = DeviceNameRules.truncatedInput(typed)
                    if truncated != typed { draftDeviceName = truncated }
                }
                .onSubmit(submitDeviceName)
                .onExitCommand(perform: cancelDeviceNameEdit)
                .frame(width: 180)
        } else {
            Text(appState.pairedDeviceName)
                .foregroundStyle(infoValueColor)
                // `LabeledContent` makes its value selectable on macOS, and selectable text hands
                // its right-click to AppKit: the glyphs got "Look Up", "Translate", "Search With
                // Google" and the row's Rename never appeared. Screenshotted on 2026-08-02 with
                // the name highlighted blue under the menu. An inner `.contextMenu` alone does not
                // win that fight; the selection has to go first, and then it does.
                //
                // The cost is that the name can no longer be selected and copied. Worth it: it is
                // a short string the user typed, and the row's one job here is renaming.
                .textSelection(.disabled)
                // The same menu again, on the name itself. It has to be repeated rather than
                // inherited from the row, because the row's `.contentShape` claims the bare part
                // of the row and not the glyphs. Matches the Categories tab's name column.
                .contextMenu { renameMenuItems }
        }
    }

    /// One definition, applied to both the row and the name inside it, so the two right-click
    /// targets cannot drift into offering different menus.
    @ViewBuilder
    private var renameMenuItems: some View {
        Button("Rename") {
            DeveloperMode.debugPrint(.click, "Button clicked: Rename device")
            draftDeviceName = appState.deviceName ?? ""
            isEditingDeviceName = true
        }
        // The device is what holds the name, so there is nothing to rename while it cannot be
        // reached; 0x15 would just fail on the not-logged-in guard.
        .disabled(!appState.isConnected)
    }

    /// Applies the typed name, and **leaves the field open if it could not be applied**: an alert
    /// that closed the editor would take the rejected text with it, so fixing a name the device
    /// refused would mean typing the whole thing again from the context menu.
    private func submitDeviceName() {
        let typed = draftDeviceName
        Task { @MainActor in
            if let problem = await appState.renameDevice(to: typed) {
                deviceNameProblem = problem
                isDeviceNameFieldFocused = true
            } else {
                cancelDeviceNameEdit()
            }
        }
    }

    private func cancelDeviceNameEdit() {
        isEditingDeviceName = false
        draftDeviceName = ""
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
                    // These carry an accessibility *identifier* so a test can address them by name.
                    // A plain SwiftUI Button in this Form exposes no readable name whatsoever --
                    // AXTitle, AXDescription and AXHelp aren't merely empty, they're absent from the
                    // element's attribute list entirely, and it has no children to read either. So
                    // the only way to tell Forget from Reset was their index, and addressing two
                    // adjacent buttons by index when one of them wipes the device is exactly the
                    // fragility that silently broke the tab steps when a tab was inserted
                    // (Methods.md Method 10).
                    //
                    // `.accessibilityLabel` does NOT fix this here -- verified on the device
                    // 2026-07-31, AXDescription still never appears. `.accessibilityIdentifier`
                    // does: it adds AXIdentifier, which System Events can filter on.
                    // No confirmation here, deliberately. Forgetting cannot leave the device on a
                    // PIN nobody knows: `resetAndForgetDevice` writes the factory default over
                    // 0x30, logs in again with that default to prove the device took it, and only
                    // then unpairs. A failed reset leaves the device paired and says so, so there
                    // is no state to warn the user about in advance.
                    Button("Forget Device") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Forget Device")
                        Task { await appState.resetAndForgetDevice() }
                    }
                    .accessibilityIdentifier("forget-device")
                    .disabled(!pairingActionsEnabled)

                    Button("Reset Device") {
                        DeveloperMode.debugPrint(.click, "Button clicked: Reset Device")
                        showingFactoryResetConfirmation = true
                    }
                    .accessibilityIdentifier("reset-device")
                    .disabled(!pairingActionsEnabled)
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
                        This erases everything stored on the device -- face colors, task \
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
                    // One identifier, not two: the button is the same control whichever title it
                    // shows, and a test that had to guess which name to look for would be back to
                    // racing the scan state. Read `title`/the debug log to tell which mode it's in.
                    .accessibilityIdentifier("scan-for-devices")
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
                        // Every row shares one identifier deliberately: a test wants "the first
                        // discovered device", and keying on the device's own name or UUID would
                        // mean knowing them before the scan has found anything. Locating the row
                        // by its name text still works; this just doesn't depend on the cube being
                        // called "TimeFlip". Actuating it still needs a real CGEvent click
                        // (Methods.md Method 9) -- an identifier makes it findable, not clickable.
                        .accessibilityIdentifier("discovered-device-row")
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
            fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth,
            suffixWidth: SettingsLayoutConstants.Stepper.suffixWidth,
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
            fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth,
            suffixWidth: SettingsLayoutConstants.Stepper.suffixWidth,
            onCommit: { applyBlinkInterval(newValue: $0) }
        )
    }

    /// Was a bespoke field, suffix and arrow pair of its own: a 50pt box, a `min` label that sized
    /// itself, and buttons driving a private repeat loop. It is a `SteppedNumberField` like every
    /// other value in the window now. Nothing is lost by that -- the accelerating hold this row
    /// used to be the only one with is what the shared control does for all of them now -- and what
    /// is gained is that it stops being the one row that looks and behaves unlike its neighbours.
    private var autoPauseControls: some View {
        SteppedNumberField(
            appState: appState,
            holdKey: "autoPause",
            value: autoPauseValue,
            range: 0...Self.maximumAutoPauseMinutes,
            suffix: "min",
            fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth,
            suffixWidth: SettingsLayoutConstants.Stepper.suffixWidth,
            onCommit: { applyAutoPause(newValue: $0) }
        )
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
                    holdKey: "doubleTap.clickThreshold",
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
                    holdKey: "doubleTap.limit",
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
                    holdKey: "doubleTap.latency",
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
                    holdKey: "doubleTap.window",
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

    /// One double-tap register. A `SteppedNumberField` like every other value in the window, so
    /// these gain the arrows they never had: 0-255 is a long way to travel by typing, and it is the
    /// range the accelerating hold was built for.
    ///
    /// No suffix -- these are raw register values with no unit to name -- but the slot is still
    /// reserved (`suffixWidth`), so the arrows line up with the stepper rows above rather than
    /// sliding left into the empty space.
    ///
    /// `holdKey` has to differ per field, or two of them would share one hold and the second press
    /// would be taken for the first still being down (see `AppState.steppedFieldHoldKey`).
    private func numericField(
        holdKey: String,
        value: Binding<UInt8>
    ) -> some View {
        SteppedNumberField(
            appState: appState,
            holdKey: holdKey,
            value: Int(value.wrappedValue),
            range: Self.doubleTapRegisterRange,
            suffix: "",
            fieldWidth: SettingsLayoutConstants.Stepper.fieldWidth,
            suffixWidth: SettingsLayoutConstants.Stepper.suffixWidth,
            onCommit: { newValue in
                value.wrappedValue = UInt8(clamping: newValue)
                applyDoubleTapParameters(doubleTapParams)
            }
        )
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
        let clamped = max(0, min(Self.maximumAutoPauseMinutes, newValue))
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

    /// Whether Forget Device and Reset Device are live. See `DeviceTabRules.allowsPairingActions`
    /// for why manual mode has to switch them off, which is not the reason it sounds like.
    private var pairingActionsEnabled: Bool {
        DeviceTabRules.allowsPairingActions(
            connectionStatus: appState.connectionStatus,
            isManualMode: appState.isManualMode
        )
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

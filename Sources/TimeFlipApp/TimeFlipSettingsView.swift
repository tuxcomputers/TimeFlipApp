import SwiftUI

struct TimeFlipSettingsView: View {
    private static let eventFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @ObservedObject var appState: AppState
    @State private var autoPauseValue: Int = 0
    @State private var lastAppliedAutoPause: UInt16 = 0
    @State private var ledBrightnessValue: Int = 50
    @State private var lastAppliedLEDBrightness: UInt8 = 50
    @State private var blinkIntervalValue: Int = 5
    @State private var lastAppliedBlinkInterval: UInt8 = 5
    @State private var isAdvancedExpanded: Bool = false
    @State private var isMoreExpanded: Bool = false
    @State private var isLEDExpanded: Bool = false
    @State private var isDoubleTapExpanded: Bool = false
    @State private var doubleTapParams: DoubleTapParameters = .default
    @State private var scanAllDevices: Bool = false
    @State private var showingFactoryResetConfirmation: Bool = false

    var body: some View {
        Form {
            deviceSection
            settingsSection
            pairingSection
            advancedSection
        }
        .formStyle(.grouped)
        .onAppear(perform: syncViewState)
        .onChange(of: appState.autoPauseMinutes) { _, newValue in
            let minutes = newValue ?? 0
            autoPauseValue = Int(minutes)
            lastAppliedAutoPause = minutes
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
            doubleTapParams = newValue ?? .default
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        Section("Info") {
            LabeledContent("Name") {
                Text(appState.pairedDeviceName)
            }
            LabeledContent("Connection") {
                Text(statusText)
            }
            LabeledContent("Battery") {
                Text(batteryText)
            }
            DisclosureGroup(isExpanded: $isMoreExpanded) {
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
                Button {
                    isMoreExpanded.toggle()
                } label: {
                    Text("More")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            DisclosureGroup(isExpanded: $isLEDExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Brightness") {
                        brightnessControls
                    }
                    .disabled(!appState.isPaired)
                    LabeledContent("Blink Interval") {
                        blinkIntervalControls
                    }
                    .disabled(!appState.isPaired)
                }
                .padding(.vertical, 4)
            } label: {
                Button {
                    isLEDExpanded.toggle()
                } label: {
                    Text("LED")
                }
                .buttonStyle(.plain)
            }
            DisclosureGroup(isExpanded: $isDoubleTapExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Disable", isOn: Binding(
                        get: { !appState.isDoubleTapEnabled },
                        set: { setDoubleTapEnabled(!$0) }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(!appState.isPaired)
                    doubleTapControls
                        .disabled(!appState.isDoubleTapEnabled)
                    Button("Apply") {
                        applyDoubleTapParameters(doubleTapParams)
                    }
                    .disabled(!appState.isPaired || !appState.isDoubleTapEnabled)
                }
                .padding(.vertical, 4)
            } label: {
                Button {
                    isDoubleTapExpanded.toggle()
                } label: {
                    Text("Double tap")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pairingSection: some View {
        Section("TimeFlip") {
            HStack {
                if appState.isPaired {
                    Button("Forget Device") {
                        Task { await appState.resetAndForgetDevice() }
                    }
                    .disabled(appState.pairingStatus == .pairing)

                    Button("Reset Device") {
                        showingFactoryResetConfirmation = true
                    }
                    .disabled(appState.pairingStatus == .pairing)
                    .confirmationDialog(
                        "Reset this TimeFlip to factory settings?",
                        isPresented: $showingFactoryResetConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reset Device", role: .destructive) {
                            Task { await appState.factoryResetAndForgetDevice() }
                        }
                        Button("Cancel", role: .cancel) {}
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
                            appState.stopDeviceScan()
                        } else {
                            appState.startDeviceScan(filterToTimeFlip: !scanAllDevices)
                        }
                    }
                    Toggle("All Devices", isOn: $scanAllDevices)
                        .toggleStyle(.checkbox)
                        .disabled(appState.isScanningForDevices)
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
                            guard !isInvalid else { return }
                            let wasThisDevicePending = appState.pairingStatus == .pairing
                                && appState.pendingPairingDeviceID == device.id
                            if appState.pairingStatus == .pairing {
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

    private var brightnessControls: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { Double(ledBrightnessValue) },
                    set: { applyLEDBrightness(newValue: Int($0.rounded())) }
                ),
                in: 1...100
            )
            .frame(width: 160)
            TextField(
                "",
                value: Binding(
                    get: { ledBrightnessValue },
                    set: { applyLEDBrightness(newValue: $0) }
                ),
                format: .number
            )
            .frame(width: 50)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            Text("%")
                .foregroundStyle(.secondary)
        }
    }

    private var blinkIntervalControls: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { Double(blinkIntervalValue) },
                    set: { applyBlinkInterval(newValue: Int($0.rounded())) }
                ),
                in: 5...60
            )
            .frame(width: 160)
            TextField(
                "",
                value: Binding(
                    get: { blinkIntervalValue },
                    set: { applyBlinkInterval(newValue: $0) }
                ),
                format: .number
            )
            .frame(width: 50)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            Text("sec")
                .foregroundStyle(.secondary)
        }
    }

    private var autoPauseControls: some View {
        HStack {
            Stepper(
                value: Binding(
                    get: { autoPauseValue },
                    set: { applyAutoPause(newValue: $0) }
                ),
                in: 0...240
            ) {
                EmptyView()
            }
            .labelsHidden()
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
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("System") {
                        Text(systemText)
                    }
                    LabeledContent("Last event") {
                        Text(lastEventText)
                    }
                    Divider()
                    LabeledContent("Auto-pause (0 disable, max 240m)") {
                        autoPauseControls
                    }
                    .disabled(!appState.isPaired)
                }
                .padding(.vertical, 4)
            } label: {
                Button {
                    isAdvancedExpanded.toggle()
                } label: {
                    Text("Advanced")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var doubleTapControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Threshold")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.clickThreshold },
                        set: { doubleTapParams.clickThreshold = $0 }
                    )
                )
                doubleTapFieldCaption("Lower number = lighter tap needed (0-255 scale)")
            }
            GridRow {
                Text("Limit")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.limit },
                        set: { doubleTapParams.limit = $0 }
                    )
                )
                doubleTapFieldCaption("Lower number = sharper, quicker tap needed (0-255 scale)")
            }
            GridRow {
                Text("Latency")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.latency },
                        set: { doubleTapParams.latency = $0 }
                    )
                )
                doubleTapFieldCaption("Lower number = sooner it starts listening for the 2nd tap (0-255 scale)")
            }
            GridRow {
                Text("Window")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.window },
                        set: { doubleTapParams.window = $0 }
                    )
                )
                doubleTapFieldCaption("Lower number = less time to land the 2nd tap once listening (0-255 scale)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func doubleTapFieldCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
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
                }
            ),
            format: .number
        )
        .frame(width: 60)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .onSubmit {
            applyDoubleTapParameters(doubleTapParams)
        }
    }

    // MARK: - Helpers

    private func syncViewState() {
        let minutes = appState.autoPauseMinutes ?? 0
        autoPauseValue = Int(minutes)
        lastAppliedAutoPause = minutes
        let brightness = appState.ledBrightnessPercent
        ledBrightnessValue = Int(brightness)
        lastAppliedLEDBrightness = brightness
        let blink = appState.blinkIntervalSeconds
        blinkIntervalValue = Int(blink)
        lastAppliedBlinkInterval = blink
        doubleTapParams = appState.doubleTapParameters ?? .default
    }

    private func applyAutoPause(newValue: Int) {
        guard appState.isPaired else { return }
        let clamped = max(0, min(240, newValue))
        autoPauseValue = clamped
        let minutes = UInt16(clamped)
        guard minutes != lastAppliedAutoPause else { return }
        lastAppliedAutoPause = minutes
        appState.autoPauseMinutes = minutes
        appState.onAutoPauseChange?(minutes)
    }

    private func applyLEDBrightness(newValue: Int) {
        guard appState.isPaired else { return }
        let clamped = max(1, min(100, newValue))
        ledBrightnessValue = clamped
        let percent = UInt8(clamped)
        guard percent != lastAppliedLEDBrightness else { return }
        lastAppliedLEDBrightness = percent
        appState.ledBrightnessPercent = percent
        appState.onLEDBrightnessChange?(percent)
    }

    private func applyBlinkInterval(newValue: Int) {
        guard appState.isPaired else { return }
        let clamped = max(5, min(60, newValue))
        blinkIntervalValue = clamped
        let seconds = UInt8(clamped)
        guard seconds != lastAppliedBlinkInterval else { return }
        lastAppliedBlinkInterval = seconds
        appState.blinkIntervalSeconds = seconds
        appState.onBlinkIntervalChange?(seconds)
    }

    private func applyDoubleTapParameters(_ params: DoubleTapParameters) {
        guard appState.isPaired else { return }
        doubleTapParams = params
        appState.doubleTapParameters = params
        appState.onDoubleTapParametersChange?(effectiveDoubleTapParameters(params))
    }

    private func setDoubleTapEnabled(_ enabled: Bool) {
        guard appState.isPaired else { return }
        appState.isDoubleTapEnabled = enabled
        appState.onDoubleTapParametersChange?(effectiveDoubleTapParameters(doubleTapParams))
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

    private var batteryText: String {
        guard let level = appState.batteryLevel else {
            return "Unknown"
        }
        return "\(level)%"
    }

    private var systemText: String {
        if let state = appState.systemState {
            let sync = state.syncStatus.description
            let hardware = state.hardwareStatus.description
            let raw = String(format: "0x%04X/0x%04X", state.rawStatus, state.rawHardware)
            return "Sync: \(sync), HW: \(hardware) (\(raw))"
        }
        return "Unknown (no system report yet)"
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
        switch appState.pairingStatus {
        case .notPaired:
            return "Not paired"
        case .pairing:
            if let name = appState.pendingPairingDeviceName {
                return "Trying to pair with \(name)....."
            }
            return "Pairing..."
        case .paired:
            return "Connected"
        case .reconnecting:
            return "Reconnecting..."
        case .failed(let message):
            return "Failed" + (message.map { ": \($0)" } ?? "")
        }
    }

    private var lastEventText: String {
        guard let date = appState.lastEventDate else {
            return "No events yet"
        }
        let formatted = Self.eventFormatter.string(from: date)
        if let detail = appState.lastEventDescription {
            return "\(formatted) (\(detail))"
        }
        return formatted
    }
}

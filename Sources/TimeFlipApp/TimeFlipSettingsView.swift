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
    @State private var doubleTapParams: DoubleTapParameters = .default

    var body: some View {
        Form {
            deviceSection
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
        Section("Device") {
            LabeledContent("Name") {
                Text(appState.pairedDeviceName)
            }
            LabeledContent("Status") {
                Text(statusText)
            }
            LabeledContent("Battery") {
                Text(batteryText)
            }
            LabeledContent("System") {
                Text(systemText)
            }
            LabeledContent("Last event") {
                Text(lastEventText)
            }
            LabeledContent("LED Brightness") {
                brightnessControls
            }
            .disabled(!appState.isPaired)
            LabeledContent("LED Blink Interval") {
                blinkIntervalControls
            }
            .disabled(!appState.isPaired)
            LabeledContent("Auto-pause (0 disable, max 240m)") {
                autoPauseControls
            }
            .disabled(!appState.isPaired)
        }
    }

    private var pairingSection: some View {
        Section("TimeFlip") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Password (6 digits)", text: $appState.devicePassword)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: appState.devicePassword) { _, newValue in
                        appState.devicePassword = String(newValue.prefix(6))
                    }
            }
            HStack {
                Button("Pair / Connect") {
                    appState.requestPairing()
                }
                .disabled(appState.pairingStatus == .pairing || appState.isPaired)

                Button("Forget Device") {
                    appState.forgetDevice()
                }
                .disabled(appState.pairingStatus == .pairing)
            }
            Text("Put the TimeFlip into pairing mode and tap Pair.")
                .foregroundStyle(.secondary)
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
                    Text("Double-tap sensitivity (accelerometer registers)")
                        .foregroundStyle(.secondary)
                    doubleTapControls
                    HStack {
                        Button("Sync from device") {
                            Task { await fetchDoubleTapParameters() }
                        }
                        .disabled(appState.onDoubleTapParametersRequest == nil || !appState.isPaired)
                        Spacer()
                        Button("Apply") {
                            applyDoubleTapParameters(doubleTapParams)
                        }
                        .disabled(!appState.isPaired)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Text("Advanced")
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
            }
            GridRow {
                Text("Limit")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.limit },
                        set: { doubleTapParams.limit = $0 }
                    )
                )
            }
            GridRow {
                Text("Latency")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.latency },
                        set: { doubleTapParams.latency = $0 }
                    )
                )
            }
            GridRow {
                Text("Window")
                numericField(
                    value: Binding(
                        get: { doubleTapParams.window },
                        set: { doubleTapParams.window = $0 }
                    )
                )
            }
        }
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
        appState.onDoubleTapParametersChange?(params)
    }

    private func fetchDoubleTapParameters() async {
        guard let loader = appState.onDoubleTapParametersRequest, appState.isPaired else { return }
        if let params = await loader() {
            await MainActor.run {
                doubleTapParams = params
                appState.doubleTapParameters = params
            }
        }
    }

    private var batteryText: String {
        guard let level = appState.batteryLevel else {
            return "Unknown"
        }
        return "\(level)%"
    }

    private var systemText: String {
        if let info = appState.deviceInfo {
            let manufacturer = info.manufacturer ?? "Unknown manufacturer"
            let model = info.modelNumber ?? "Unknown model"
            let firmware = info.firmwareRevision ?? "FW n/a"
            let hardware = info.hardwareRevision ?? "HW n/a"
            return "\(manufacturer) \(model) • FW \(firmware) • HW \(hardware)"
        }
        if let state = appState.systemState {
            let sync = state.syncStatus.description
            let hardware = state.hardwareStatus.description
            let raw = String(format: "0x%04X/0x%04X", state.rawStatus, state.rawHardware)
            return "Sync: \(sync), HW: \(hardware) (\(raw))"
        }
        return "Unknown (no system report yet)"
    }

    private var statusText: String {
        switch appState.pairingStatus {
        case .notPaired:
            return "Not paired"
        case .pairing:
            return "Pairing..."
        case .paired:
            return "Connected"
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

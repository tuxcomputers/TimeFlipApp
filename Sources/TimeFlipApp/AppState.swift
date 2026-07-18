import Combine
import OSLog
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private let preferencesStore: PreferencesStore
    private let googleClientSecretStore: GoogleClientSecretStore
    private let devicePasswordStore: TimeFlipDevicePasswordStoring
    private let developerConfigStore: DeveloperConfigStoring // Developer mode; see DeveloperConfigStore.swift
    private var preferencesCancellables: Set<AnyCancellable> = []
    private var isApplyingPreferences = false
    private var hasLoadedClientSecret = false
    // Set when a stored preferences blob existed but failed to decode, so the very next
    // debounced persist (which would otherwise fire from incidental startup state changes,
    // before the user has made any real edit) doesn't silently clobber it with defaults.
    private var suppressNextPersist = false
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "app-state")

    @Published var currentFacetID: UInt8
    @Published var isPaused: Bool
    @Published var isLocked: Bool
    @Published var batteryLevel: UInt8?
    @Published var systemState: TimeFlipSystemState?
    @Published var lastEventDescription: String?
    @Published var lastEventDate: Date?
    @Published var isPaired: Bool
    @Published var pairedDeviceName: String
    @Published var facetMappings: [FacetMapping]
    @Published var googleCalendarID: String?
    @Published var googleCalendarName: String?
    @Published var googleClientID: String
    @Published var googleClientSecret: String
    @Published var devicePassword: String
    @Published var pairedDeviceUUID: String?
    @Published var pairingStatus: PairingStatus
    @Published var wantsPairing: Bool
    @Published var autoPauseMinutes: UInt16?
    @Published var deviceInfo: TimeFlipDeviceInfo?
    @Published var ledBrightnessPercent: UInt8
    @Published var blinkIntervalSeconds: UInt8
    @Published var doubleTapParameters: DoubleTapParameters
    // Whether double-tap-to-pause is enabled. Disabling it is a UI-level trick: the device has
    // no real on/off for this, so we keep the user's real settings here and, whenever disabled,
    // send them to the device with `window` forced to 0 (which makes the accelerometer's
    // double-tap gesture unrecognizable) instead of the real value. See effectiveDoubleTapParameters.
    @Published var isDoubleTapEnabled: Bool
    @Published var dailyFacetDurations: [UInt8: TimeInterval]
    @Published var dailyWindowStart: Date
    // Developer mode: true once config.json has been found and read (see the "Developer mode"
    // section below and DeveloperConfigStore.swift). Remove together with that section.
    @Published private(set) var isDeveloperConfigLoaded: Bool = false
    @Published var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published var isScanningForDevices: Bool = false
    @Published var invalidDeviceIDs: Set<UUID> = []
    @Published var deviceStatusMessages: [UUID: String] = [:]
    @Published var pendingPairingDeviceName: String?
    @Published var pendingPairingDeviceID: UUID?
    var onPairingChange: ((Bool) -> Void)?
    var onDeviceSelectedForPairing: ((UUID) -> Void)?
    var onCancelPairingAttempt: (() -> Void)?
    var onResetDevicePasswordRequest: (() async -> Bool)?
    var onFactoryResetRequest: (() async -> Bool)?
    var onCurrentFacetMappingChange: (() -> Void)?
    var onAutoPauseChange: ((UInt16) -> Void)?
    var onLEDBrightnessChange: ((UInt8) -> Void)?
    var onBlinkIntervalChange: ((UInt8) -> Void)?
    var onDoubleTapParametersChange: ((DoubleTapParameters) -> Void)?
    // Fired with the real (never window-zeroed) parameters/enabled flag whenever either changes
    // from the UI, so a listener can persist them -- separate from onDoubleTapParametersChange,
    // which instead receives whatever should actually be sent to the device (see
    // effectiveDoubleTapParameters).
    var onDoubleTapSettingsPersist: ((DoubleTapParameters, Bool) -> Void)?
    var onStartDeviceScan: ((Bool) -> Void)?
    var onStopDeviceScan: (() -> Void)?

    init(
        preferencesStore: PreferencesStore = UserDefaultsPreferencesStore(),
        googleClientSecretStore: GoogleClientSecretStore = KeychainGoogleClientSecretStore(),
        devicePasswordStore: TimeFlipDevicePasswordStoring = TimeFlipDevicePasswordStore.shared,
        developerConfigStore: DeveloperConfigStoring = DeveloperConfigStore.shared,
        ledBrightnessPercent: UInt8,
        blinkIntervalSeconds: UInt8,
        doubleTapParameters: DoubleTapParameters,
        isDoubleTapEnabled: Bool
    ) {
        self.preferencesStore = preferencesStore
        self.googleClientSecretStore = googleClientSecretStore
        self.devicePasswordStore = devicePasswordStore
        self.developerConfigStore = developerConfigStore
        currentFacetID = TimeFlipConstants.minFacetID
        isPaused = false
        isLocked = false
        batteryLevel = nil
        systemState = nil
        lastEventDescription = nil
        lastEventDate = nil
        isPaired = false
        pairedDeviceName = "Not paired"
        facetMappings = ActivityLibrary.defaultMappings()
        googleCalendarID = nil
        googleCalendarName = nil
        googleClientID = ""
        googleClientSecret = ""
        // Developer Mode's config.json is meant to supply this (see applyDeveloperConfig below),
        // but the symlink some dev setups point it at (a repo-tracked file) keeps getting lost --
        // rather than chase that, dev builds just start on a fixed, easy-to-type password instead
        // of the real factory default, independent of whether config.json actually loads.
        devicePassword = DeveloperMode.isEnabled ? "123456" : TimeFlipConstants.defaultPassword
        pairedDeviceUUID = nil
        pairingStatus = .notPaired
        wantsPairing = false
        autoPauseMinutes = nil
        deviceInfo = nil
        self.ledBrightnessPercent = ledBrightnessPercent
        self.blinkIntervalSeconds = blinkIntervalSeconds
        self.doubleTapParameters = doubleTapParameters
        self.isDoubleTapEnabled = isDoubleTapEnabled
        dailyFacetDurations = [:]
        dailyWindowStart = Date()

        applyPreferences()
        if DeveloperMode.isEnabled { applyDeveloperConfig() }
        loadClientSecretOnce()
        loadDevicePassword()
        observePreferences()
    }

    // MARK: - Developer mode
    // To remove developer mode: delete this section, the `isDeveloperConfigLoaded` property,
    // the `developerConfigStore` property/init param, and every other `DeveloperMode.isEnabled`
    // call site below (in persistGoogleClientSecret, persistDevicePassword, persistPreferences).

    private var isDeveloperConfigActive: Bool {
        DeveloperMode.isEnabled && isDeveloperConfigLoaded
    }

    private func applyDeveloperConfig() {
        guard let config = developerConfigStore.load() else { return }
        isDeveloperConfigLoaded = true
        googleClientID = config.googleClientID ?? googleClientID
        googleClientSecret = config.googleClientSecret ?? googleClientSecret
        devicePassword = config.devicePassword ?? devicePassword
    }

    private func persistDeveloperConfig() {
        developerConfigStore.save(
            DeveloperConfigPayload(
                googleClientID: sanitizedClientID(),
                googleClientSecret: googleClientSecret.isEmpty ? nil : googleClientSecret,
                devicePassword: devicePassword
            )
        )
    }

    private func loadDevicePassword() {
        // Guard on DeveloperMode.isEnabled itself, not isDeveloperConfigActive (which also
        // requires config.json to have actually loaded) -- otherwise a dev build whose config.json
        // symlink is broken falls through to Keychain here and clobbers the "123456" default set
        // in init above.
        guard !DeveloperMode.isEnabled else { return }
        let wasApplying = isApplyingPreferences
        isApplyingPreferences = true
        devicePassword = (try? devicePasswordStore.loadPassword()) ?? nil ?? TimeFlipConstants.defaultPassword
        isApplyingPreferences = wasApplying
    }

    func loadClientSecretOnce() {
        guard !hasLoadedClientSecret, !isDeveloperConfigActive else { return }
        hasLoadedClientSecret = true

        // Temporarily set isApplyingPreferences to prevent the observer from saving
        let wasApplying = isApplyingPreferences
        isApplyingPreferences = true
        googleClientSecret = (try? googleClientSecretStore.loadSecret()) ?? ""
        isApplyingPreferences = wasApplying
    }

    func update(from event: TimeFlipEvent) {
        lastEventDate = Date()
        lastEventDescription = event.description

        switch event {
        case .facetChanged, .doubleTap:
            // Live events only trigger history fetch; state comes from history
            break
        case .autoPauseMinutes(let minutes):
            autoPauseMinutes = clampAutoPause(minutes)
        case .batteryLevel(let level):
            batteryLevel = level
        case .systemState(let state):
            systemState = state
        case .deviceInfo(let info):
            deviceInfo = info
        case .eventLog:
            break
        case .lockChanged(let locked):
            isLocked = locked
        }
    }

    func activity(for facetID: UInt8) -> Activity? {
        Self.activity(for: facetID, in: facetMappings)
    }

    /// Free-function form so callers holding a freshly emitted `$facetMappings` payload (e.g. a
    /// Combine sink) can resolve against it directly instead of the property, which under
    /// `@Published`'s willSet-based emission hasn't been updated yet at emission time.
    static func activity(for facetID: UInt8, in mappings: [FacetMapping]) -> Activity? {
        guard let mapping = mappings.first(where: { $0.facetID == facetID }) else {
            return nil
        }
        let iconName = ActivityLibrary.sanitizeIconName(mapping.iconName)
        let name = ActivityLibrary.sanitizeActivityName(mapping.displayName)
        let resolvedIcon = iconName.isEmpty ? nil : iconName
        return Activity(name: name, iconName: resolvedIcon, limitMinutes: mapping.limitMinutes)
    }

    func mappingIndex(for facetID: UInt8) -> Int? {
        facetMappings.firstIndex { $0.facetID == facetID }
    }

    func updateMapping(_ mapping: FacetMapping) {
        guard let index = mappingIndex(for: mapping.facetID) else { return }
        var updated = facetMappings
        updated[index] = mapping
        facetMappings = updated
        if mapping.facetID == currentFacetID {
            onCurrentFacetMappingChange?()
        }
    }

    func startDeviceScan(filterToTimeFlip: Bool) {
        // invalidDeviceIDs is intentionally NOT reset here: it's a running memory of
        // confirmed-not-TimeFlip devices, so they stay struck-through/unclickable on rescans.
        // Transient per-device messages (connecting/wrong PIN/etc.) don't survive a fresh scan.
        discoveredDevices = []
        for id in deviceStatusMessages.keys where !invalidDeviceIDs.contains(id) {
            deviceStatusMessages[id] = nil
        }
        isScanningForDevices = true
        onStartDeviceScan?(filterToTimeFlip)
    }

    func stopDeviceScan() {
        isScanningForDevices = false
        onStopDeviceScan?()
    }

    func deviceScanStopped() {
        isScanningForDevices = false
    }

    func clearDiscoveredDevicesOnClose() {
        if isScanningForDevices {
            stopDeviceScan()
        }
        discoveredDevices = []
    }

    func selectDiscoveredDevice(_ device: DiscoveredBLEDevice) {
        pendingPairingDeviceID = device.id
        pendingPairingDeviceName = device.name
        deviceStatusMessages[device.id] = "Connecting… (click to cancel)"
        onDeviceSelectedForPairing?(device.id)
    }

    func cancelPairingAttempt() {
        onCancelPairingAttempt?()
        if let id = pendingPairingDeviceID {
            deviceStatusMessages[id] = nil
        }
        pendingPairingDeviceID = nil
        pendingPairingDeviceName = nil
        pairingStatus = .notPaired
        wantsPairing = false
    }

    func markDeviceInvalid(_ id: UUID) {
        invalidDeviceIDs.insert(id)
        deviceStatusMessages[id] = "Not a TimeFlip"
        if pendingPairingDeviceID == id {
            pendingPairingDeviceID = nil
            pendingPairingDeviceName = nil
        }
    }

    func addDiscoveredDevice(_ device: DiscoveredBLEDevice) {
        guard !discoveredDevices.contains(where: { $0.id == device.id }) else { return }
        discoveredDevices.append(device)
    }

    func resetAndForgetDevice() async {
        let confirmed = await onResetDevicePasswordRequest?() ?? true
        guard confirmed else {
            pairingStatus = .failed("Could not confirm password reset — device left paired")
            return
        }
        forgetDevice()
    }

    /// Full factory reset (erases facet colors, task parameters, name, password -- everything --
    /// back to defaults), confirmed via a real re-login with the factory default password, then
    /// forgets the device -- mirrors `resetAndForgetDevice()`'s "only forget once confirmed" shape,
    /// but for a full reset rather than just the password. The caller (the Settings UI) is
    /// responsible for confirming with the user before calling this -- it proceeds immediately.
    func factoryResetAndForgetDevice() async {
        let confirmed = await onFactoryResetRequest?() ?? true
        guard confirmed else {
            pairingStatus = .failed("Could not confirm device reset — device left paired")
            return
        }
        forgetDevice()
    }

    func forgetDevice() {
        wantsPairing = false
        isPaired = false
        pairedDeviceName = "Not paired"
        pairedDeviceUUID = nil
        pairingStatus = .notPaired
        currentFacetID = TimeFlipConstants.unassignedFacetID
        isPaused = true
        isLocked = false
        batteryLevel = nil
        systemState = nil
        lastEventDescription = nil
        lastEventDate = nil
        deviceInfo = nil
        autoPauseMinutes = nil
        devicePassword = TimeFlipConstants.defaultPassword
        onPairingChange?(false)
    }

    private func applyPreferences() {
        guard let payload = preferencesStore.load() else {
            if preferencesStore.hasStoredPayload() {
                logger.error("Stored preferences failed to decode; keeping in-memory defaults for this session without overwriting the stored blob")
                suppressNextPersist = true
            }
            return
        }
        isApplyingPreferences = true
        let mappings = payload.facetMappings.map { record in
            FacetMapping(
                facetID: record.facetID,
                name: ActivityLibrary.sanitizeActivityName(record.name),
                iconName: ActivityLibrary.sanitizeIconName(record.iconName),
                color: record.color.color,
                limitMinutes: clampLimit(record.limitMinutes ?? 0)
            )
        }
        if !mappings.isEmpty {
            facetMappings = mappings.sorted { $0.facetID < $1.facetID }
        }
        googleCalendarID = payload.googleCalendarID
        googleCalendarName = payload.googleCalendarName
        googleClientID = payload.googleClientID ?? ""
        wantsPairing = payload.wantsPairing ?? payload.isPaired
        isPaired = false
        pairingStatus = wantsPairing ? .pairing : .notPaired
        pairedDeviceName = payload.pairedDeviceName ?? pairedDeviceName
        pairedDeviceUUID = payload.pairedDeviceUUID
        if let storedAutoPause = payload.autoPauseMinutes {
            autoPauseMinutes = clampAutoPause(storedAutoPause)
        }
        isApplyingPreferences = false
    }

    func setDailyWindowStart(_ date: Date) {
        dailyWindowStart = date
    }

    func replaceDailyTotals(_ totals: [UInt8: TimeInterval]) {
        dailyFacetDurations = totals
    }

    func incrementDailyTotal(facetID: UInt8, by delta: TimeInterval) {
        guard delta > 0 else { return }
        dailyFacetDurations[facetID, default: 0] += delta
    }

    func resetDailyTotals() {
        dailyFacetDurations = [:]
    }

    private func observePreferences() {
        // Coalesce all preference changes into a single debounced sink
        // to avoid cascading persistence calls and reduce disk I/O
        Publishers.MergeMany([
            $facetMappings.map { _ in () }.eraseToAnyPublisher(),
            $googleCalendarID.map { _ in () }.eraseToAnyPublisher(),
            $googleCalendarName.map { _ in () }.eraseToAnyPublisher(),
            $googleClientID.map { _ in () }.eraseToAnyPublisher(),
            $isPaired.map { _ in () }.eraseToAnyPublisher(),
            $pairedDeviceName.map { _ in () }.eraseToAnyPublisher(),
            $pairedDeviceUUID.map { _ in () }.eraseToAnyPublisher(),
            $autoPauseMinutes.map { _ in () }.eraseToAnyPublisher()
        ])
        .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.persistPreferences()
        }
        .store(in: &preferencesCancellables)

        // Google client secret has its own persistence mechanism, but still needs debouncing
        // like the general preferences pipeline above — otherwise every keystroke while editing
        // it in Settings triggers its own Keychain write.
        $googleClientSecret
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] secret in
                guard let self else { return }
                self.persistGoogleClientSecret(secret)
            }
            .store(in: &preferencesCancellables)

        // Device password is Keychain-backed, not part of the plaintext preferences blob
        $devicePassword
            .sink { [weak self] password in
                guard let self, !self.isApplyingPreferences else { return }
                self.persistDevicePassword(password)
            }
            .store(in: &preferencesCancellables)
    }

    private func persistPreferences() {
        guard !isApplyingPreferences else {
            return
        }
        if suppressNextPersist {
            suppressNextPersist = false
            logger.warning("Skipped one persist after a failed preferences decode to avoid clobbering the stored blob")
            return
        }
        let records = facetMappings.map { mapping -> FacetMappingRecord in
            let sanitizedName = ActivityLibrary.sanitizeActivityName(mapping.name)
            let sanitizedIcon = ActivityLibrary.sanitizeIconName(mapping.iconName)
            let sanitized = FacetMapping(
                facetID: mapping.facetID,
                name: sanitizedName,
                iconName: sanitizedIcon,
                color: mapping.color,
                limitMinutes: clampLimit(mapping.limitMinutes)
            )
            return FacetMappingRecord(mapping: sanitized)
        }
        let payload = PreferencesPayload(
            facetMappings: records,
            googleCalendarID: googleCalendarID,
            googleCalendarName: googleCalendarName,
            googleClientID: sanitizedClientID(),
            isPaired: wantsPairing,
            wantsPairing: wantsPairing,
            pairedDeviceName: pairedDeviceName,
            pairedDeviceUUID: pairedDeviceUUID,
            autoPauseMinutes: autoPauseMinutes.map { clampAutoPause($0) }
        )
        preferencesStore.save(payload)
        if isDeveloperConfigActive {
            persistDeveloperConfig()
        }
    }

    private func sanitizedClientID() -> String? {
        let trimmed = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistGoogleClientSecret(_ secret: String) {
        guard !isApplyingPreferences else { return }
        if isDeveloperConfigActive {
            persistDeveloperConfig()
            return
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try googleClientSecretStore.saveSecret(trimmed.isEmpty ? nil : trimmed)
        } catch {
            // Ignore persistence errors; UI will surface during auth if needed.
        }
    }

    private func persistDevicePassword(_ password: String) {
        if isDeveloperConfigActive {
            persistDeveloperConfig()
            return
        }
        do {
            try devicePasswordStore.savePassword(password)
        } catch {
            // Ignore persistence errors; the in-memory value still drives the current session.
        }
    }

    /// What should actually be sent to the device: the real parameters when double-tap is
    /// enabled, or the same parameters with `window` forced to 0 when disabled.
    var effectiveDoubleTapParameters: DoubleTapParameters {
        var params = doubleTapParameters
        if !isDoubleTapEnabled {
            params.window = 0
        }
        return params
    }

    func limitMinutes(for facetID: UInt8) -> Int {
        mappingIndex(for: facetID).map { clampLimit(facetMappings[$0].limitMinutes) } ?? 0
    }

    private func clampLimit(_ value: Int) -> Int {
        return max(0, min(480, value))
    }

    private func clampAutoPause(_ value: UInt16) -> UInt16 {
        // UI clamps to 0–240 minutes; keep the same guardrails at persistence.
        return UInt16(max(0, min(240, Int(value))))
    }


    func confirmPaired(name: String, uuid: String?) {
        isPaired = true
        wantsPairing = true
        pairingStatus = .paired
        pairedDeviceName = name
        pairedDeviceUUID = uuid ?? pairedDeviceUUID ?? UUID().uuidString
        if let id = pendingPairingDeviceID {
            deviceStatusMessages[id] = nil
            pendingPairingDeviceID = nil
            pendingPairingDeviceName = nil
        }
        discoveredDevices = []
        onPairingChange?(true)
        persistPreferences()
    }

    func pairingFailed(message: String?) {
        isPaired = false
        pairingStatus = .failed(message)
        if let id = pendingPairingDeviceID {
            deviceStatusMessages[id] = message ?? "Failed"
            pendingPairingDeviceID = nil
            pendingPairingDeviceName = nil
        }
        onPairingChange?(false)
        persistPreferences()
    }
}

enum PairingStatus: Equatable {
    case notPaired
    case pairing
    case paired
    /// Connection to an already-paired device was lost (BLE range, sleep, etc.) and an automatic
    /// reconnect is in progress. Distinct from `.failed`/`.notPaired` so the menu bar keeps
    /// showing the last known activity/icon instead of tearing down to an unpaired look.
    case reconnecting
    case failed(String?)
}

import Combine
import OSLog
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private let preferencesStore: PreferencesStore
    private let googleClientSecretStore: GoogleClientSecretStore
    private let devicePasswordStore: TimeFlipDevicePasswordStoring
    private let developerConfigStore: DeveloperConfigStoring // Developer mode; see DeveloperConfigStore.swift
    /// The face colour-picker palette, loaded once from the `colour` reference table at launch
    /// (see `ActivityLibrary.colorOptions(from:)`). Fixed for the session — no UI edits it.
    let colourOptions: [ActivityColorOption]
    /// The Categories tab's icon-grid palette, loaded once from the `icon` reference table at
    /// launch (see `ActivityLibrary.iconOptions(from:)`). Fixed for the session -- no UI edits it.
    let iconOptions: [CategoryIconOption]
    /// Each face's assigned category, keyed by face id, from the `face` table
    /// (`database/008_face.sql`). This is what the menu bar shows -- see `categoryActivity(for:)`.
    /// Published so an edit on the Categories tab reaches the menu bar without a relaunch.
    @Published var faceCategories: [UInt8: CategoryRecord]
    /// Which faces are locked, keyed by `face_id` (`database/008_face.sql`). A locked face keeps
    /// the category it has: the Faces tab refuses to reassign it, and so does the write itself.
    @Published var faceLocks: [UInt8: Bool]
    private var preferencesCancellables: Set<AnyCancellable> = []
    private var isApplyingPreferences = false
    private var hasLoadedClientSecret = false
    // Set when a stored preferences blob existed but failed to decode, so the very next
    // debounced persist (which would otherwise fire from incidental startup state changes,
    // before the user has made any real edit) doesn't silently clobber it with defaults.
    private var suppressNextPersist = false
    private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "app-state")

    @Published var currentFaceID: UInt8
    @Published var isPaused: Bool
    @Published var isLocked: Bool
    @Published var batteryLevel: UInt8?
    @Published var systemState: TimeFlipSystemState?
    @Published var lastEventDescription: String?
    @Published var lastEventDate: Date?
    /// Whether the app knows which device it is meant to talk to. **Durable**: set once the user
    /// picks a device and the pairing succeeds, and cleared only by `forgetDevice()` (which the
    /// Forget Device button and the end of a factory reset call). It deliberately survives a
    /// disconnect, going out of range, a rejected password and a quit -- none of those change
    /// which device the app is paired to, they only stop it reaching that device right now. That
    /// transient side is `connectionStatus`; see `isConnected` for the two combined.
    @Published var isPaired: Bool
    @Published var pairedDeviceName: String
    @Published var faceMappings: [FaceMapping]
    @Published var googleCalendarID: String?
    @Published var googleCalendarName: String?
    /// The signed-in account's calendars, as last listed from Google. Held here rather than on the
    /// App tab's view so it outlives a tab switch: a `.task` restarts every time its view reappears,
    /// so a view-owned list meant a `calendars.list` round trip on every visit to the tab. `nil`
    /// means "never listed" (fetch on next look), an empty array means "listed, and there were
    /// none". In memory only, so a restart lists afresh rather than showing a stale cache; the
    /// Refresh calendars button re-lists on demand in between.
    @Published var googleCalendars: [GoogleCalendarSummary]?
    @Published var googleClientID: String
    @Published var googleClientSecret: String
    @Published var devicePassword: String
    @Published var pairedDeviceUUID: String?
    /// Whether the app can reach the paired device right now. **Transient**: it changes on every
    /// connect, drop, retry and reset, and it means nothing on its own -- a status of `.connected`
    /// while `isPaired` is false is not a state the app can be in. Read `isConnected` rather than
    /// comparing this to `.connected` directly, so that gating isn't re-derived at each call site.
    @Published var connectionStatus: ConnectionStatus
    @Published var autoPauseMinutes: UInt16
    @Published var deviceInfo: TimeFlipDeviceInfo?
    @Published var ledBrightnessPercent: UInt8
    @Published var blinkIntervalSeconds: UInt8
    @Published var doubleTapParameters: DoubleTapParameters
    // Whether double-tap-to-pause is enabled. Disabling it is a UI-level trick: the device has
    // no real on/off for this, so we keep the user's real settings here and, whenever disabled,
    // send them to the device with `window` forced to 0 (which makes the accelerometer's
    // double-tap gesture unrecognizable) instead of the real value. See effectiveDoubleTapParameters.
    @Published var isDoubleTapEnabled: Bool
    @Published var dailyFaceDurations: [UInt8: TimeInterval]
    @Published var dailyWindowStart: Date
    // Local time (24-hour) at which each category's daily accounting rolls over, mirroring the
    // `daily_reset_time` setting. The App-tab stepper edits it in whole hours + AM/PM, but the
    // stored value keeps hour AND minute so a finer time can be set for testing the reset firing.
    @Published var dailyResetHour: Int
    @Published var dailyResetMinute: Int
    // Whether the menu bar duration shows a seconds component, mirroring the `display_seconds`
    // setting. Held here rather than read once at launch so the App tab's toggle can take effect
    // immediately instead of at the next launch.
    @Published var displaySecondsEnabled: Bool
    // Whether locking the device from the app pauses it first, mirroring the `pause_on_lock`
    // setting. The lock and quit paths read the store directly on every action, so this copy exists
    // for the App tab's toggle to have something to show and drive.
    @Published var pauseOnLockEnabled: Bool
    // Battery level at or below which the low-battery warning shows, mirroring the
    // `low_battery_level` setting. Held here for the same reason as `displaySecondsEnabled`: so the
    // App tab's control applies immediately rather than at the next launch.
    @Published var lowBatteryThresholdPercent: Int
    // How often history is re-fetched, in seconds, matching the stored setting. The App tab's
    // control is the only thing that turns this into minutes, for display.
    @Published var fetchHistoryIntervalSeconds: Int
    // Developer mode: true once config.json has been found and read (see the "Developer mode"
    // section below and DeveloperConfigStore.swift). Remove together with that section.
    @Published private(set) var isDeveloperConfigLoaded: Bool = false
    // Which physical database this launch opened -- "production" or "test" (see
    // AppDataStore.loadDbType()). Fixed for the session; set once at launch by ApplicationDelegate.
    // Surfaced at the far left of the menu bar in developer mode only, so a developer can't mistake
    // a test database for the real one and record real timings into it. Remove with dev mode.
    @Published var dbType: String = "production"
    @Published var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published var isScanningForDevices: Bool = false
    @Published var invalidDeviceIDs: Set<UUID> = []
    @Published var deviceStatusMessages: [UUID: String] = [:]
    @Published var pendingPairingDeviceName: String?
    @Published var pendingPairingDeviceID: UUID?
    // Device tab disclosure-group expand states. Deliberately not persisted -- the Preferences
    // window is hidden rather than deallocated on close (see SettingsWindowController), so plain
    // View @State would otherwise keep whatever was expanded across a close/reopen. Reset to
    // false via collapseDeviceTabDisclosures() from windowWillClose instead.
    // How many category-name fields are open across the tabs. The Close button at the window root
    // owns Escape (`keyboardShortcut(.cancelAction)`), and AppKit dispatches a key equivalent before
    // the focused field ever sees the key, so the only way Escape can cancel a name field instead of
    // closing the window is for that button to give the shortcut up while one is open.
    //
    // Counted rather than a flag because the Categories and Faces tabs each have their own create
    // control: closing one field must not hand Escape back while the other is still open.
    @Published private(set) var openCategoryNameFields = 0
    @Published var isMoreExpanded: Bool = false
    @Published var isLEDExpanded: Bool = false
    @Published var isDoubleTapExpanded: Bool = false
    // The auto-pause arrows' press-and-hold repeat loop (see TimeFlipSettingsView), owned here --
    // along with which direction is currently held -- rather than as View @State, for the same
    // reason as the disclosure-group states above: the window survives close, and a
    // physically-still-held mouse button never delivers its release event to the view if the
    // window closes out from under it (e.g. a keyboard-driven close). Both are reset together
    // from collapseDeviceTabDisclosures() so the task can't keep ticking (and keep sending
    // device/DB writes) in the background after the window closes, and so the arrow it was
    // holding isn't left stuck "pressed" once the window reopens.
    var autoPauseHoldTask: Task<Void, Never>?
    var autoPauseHoldDirection: Int?
    // The App tab's held stepper arrows, owned here for the same reasons as the auto-pause pair
    // above: the window is hidden rather than deallocated, and a physically-held mouse button never
    // delivers its release to a view whose window has closed under it. One key rather than one pair
    // per control, since only one arrow can be held at a time.
    var steppedFieldHoldTask: Task<Void, Never>?
    var steppedFieldHoldKey: String?
    // Mirrors MenuBarController's low-battery blink state so the Settings window's Battery line
    // (a different view hierarchy from the status bar) can flash in sync with it and with the
    // "Preferences..." menu item -- MenuBarController owns the actual timer/latch and pushes
    // updates here via setLowBatteryBlinkState(). Deliberately not persisted.
    @Published private(set) var isLowBattery: Bool = false
    @Published private(set) var lowBatteryBlinkPhaseOn: Bool = false
    // Set by MenuBarController.openPreferences() when Preferences is opened while low-battery is
    // flashing, so the window jumps straight to the Device tab (where the battery line lives)
    // instead of leaving whatever tab was last selected. SettingsRootView consumes and clears it.
    @Published var pendingSettingsTab: SettingsTab?
    var onPairingChange: ((Bool) -> Void)?
    var onDeviceSelectedForPairing: ((UUID) -> Void)?
    var onCancelPairingAttempt: (() -> Void)?
    var onResetDevicePasswordRequest: (() async -> Bool)?
    var onFactoryResetRequest: (() async -> Bool)?
    var onCurrentFaceMappingChange: (() -> Void)?
    // Fired with the new daily-reset time (24-hour hour, minute) when the App-tab picker changes it,
    // so the setting can be persisted and the running day-window/timer re-armed (see ApplicationDelegate).
    var onDailyResetTimeChange: ((_ hour: Int, _ minute: Int) -> Void)?
    var onDisplaySecondsChange: ((Bool) -> Void)?
    var onPauseOnLockChange: ((Bool) -> Void)?
    var onLowBatteryThresholdChange: ((Int) -> Void)?
    /// Passes seconds, like everything outside the App tab's own control.
    var onFetchHistoryIntervalChange: ((Int) -> Void)?
    var onAutoPauseChange: ((UInt16) -> Void)?
    var onLEDBrightnessChange: ((UInt8) -> Void)?
    var onBlinkIntervalChange: ((UInt8) -> Void)?
    /// `immediately` skips the usual debounce, for a change that has no run of intermediate values to
    /// wait out: the Disable checkbox is a boolean, so there is nothing to settle. The register
    /// values, which a held stepper walks through, leave it `false`.
    var onDoubleTapParametersChange: ((DoubleTapParameters, _ immediately: Bool) -> Void)?
    // Fired with the real (never window-zeroed) parameters/enabled flag whenever either changes
    // from the UI, so a listener can persist them -- separate from onDoubleTapParametersChange,
    // which instead receives whatever should actually be sent to the device (see
    // effectiveDoubleTapParameters).
    var onDoubleTapSettingsPersist: ((DoubleTapParameters, Bool) -> Void)?
    var onStartDeviceScan: ((Bool) -> Void)?
    var onStopDeviceScan: (() -> Void)?

    /// Whether the app is talking to its device right now: paired to one **and** currently
    /// connected to it. The `isPaired` half is the gate -- an unpaired app has no device to be
    /// connected to, so this can never be true without it. Everything that needs a live device
    /// (sending pause/lock, showing a battery level, enabling the Device tab's controls) should
    /// ask this rather than either half alone.
    var isConnected: Bool {
        isPaired && connectionStatus == .connected
    }

    /// Whether the app should be trying to reach a device at all -- the gate on every reconnect,
    /// backoff retry and wake-from-sleep attempt. True while paired, because a paired app is meant
    /// to keep its device reachable however long that takes; and true mid-pairing, because that
    /// attempt is still live and a drop during it should be retried rather than abandoned. False
    /// otherwise, which is what stops a forgotten device being chased forever.
    var shouldMaintainConnection: Bool {
        isPaired || connectionStatus == .pairing
    }

    init(
        preferencesStore: PreferencesStore = UserDefaultsPreferencesStore(),
        googleClientSecretStore: GoogleClientSecretStore = KeychainGoogleClientSecretStore(),
        devicePasswordStore: TimeFlipDevicePasswordStoring = TimeFlipDevicePasswordStore.shared,
        developerConfigStore: DeveloperConfigStoring = DeveloperConfigStore.shared,
        autoPauseMinutes: UInt16,
        ledBrightnessPercent: UInt8,
        blinkIntervalSeconds: UInt8,
        doubleTapParameters: DoubleTapParameters,
        isDoubleTapEnabled: Bool,
        colourOptions: [ActivityColorOption] = [],
        iconOptions: [CategoryIconOption] = [],
        faceCategories: [UInt8: CategoryRecord] = [:],
        faceLocks: [UInt8: Bool] = [:],
        googleCalendarID: String? = nil,
        googleCalendarName: String? = nil,
        googleClientID: String? = nil,
        isPaired: Bool = false,
        pairedDeviceName: String? = nil,
        pairedDeviceUUID: String? = nil,
        displaySecondsEnabled: Bool = true,
        pauseOnLockEnabled: Bool = true,
        lowBatteryThresholdPercent: Int = TimeFlipConstants.defaultLowBatteryWarningPercent,
        fetchHistoryIntervalSeconds: Int = 60,
        dailyResetHour: Int = 3,
        dailyResetMinute: Int = 0
    ) {
        self.preferencesStore = preferencesStore
        self.googleClientSecretStore = googleClientSecretStore
        self.devicePasswordStore = devicePasswordStore
        self.developerConfigStore = developerConfigStore
        self.colourOptions = colourOptions
        self.iconOptions = iconOptions
        self.faceCategories = faceCategories
        self.faceLocks = faceLocks
        currentFaceID = TimeFlipConstants.minFaceID
        isPaused = false
        isLocked = false
        batteryLevel = nil
        systemState = nil
        lastEventDescription = nil
        lastEventDate = nil
        self.isPaired = isPaired
        // "Not paired" is the placeholder the Device tab shows when no device is remembered;
        // the stored value is absent rather than that string.
        self.pairedDeviceName = pairedDeviceName ?? "Not paired"
        faceMappings = ActivityLibrary.defaultMappings()
        self.googleCalendarID = googleCalendarID
        self.googleCalendarName = googleCalendarName
        // Developer mode's config.json can override this in applyDeveloperConfig below, which runs
        // after this initialiser's assignments -- same precedence as before the move.
        self.googleClientID = googleClientID ?? ""
        googleClientSecret = ""
        // Developer Mode's config.json is meant to supply this (see applyDeveloperConfig below),
        // but the symlink some dev setups point it at (a repo-tracked file) keeps getting lost --
        // rather than chase that, dev builds just start on a fixed, easy-to-type password instead
        // of the real factory default, independent of whether config.json actually loads.
        devicePassword = DeveloperMode.isEnabled ? DeveloperMode.devicePassword : TimeFlipConstants.defaultPassword
        self.pairedDeviceUUID = pairedDeviceUUID
        // Nothing has been attempted yet, so the connection is down whether or not a device is
        // remembered. A paired app starts here and moves to `.connected` once it reaches the
        // device; an unpaired one stays here until the user pairs.
        connectionStatus = .disconnected
        self.autoPauseMinutes = autoPauseMinutes
        deviceInfo = nil
        self.ledBrightnessPercent = ledBrightnessPercent
        self.blinkIntervalSeconds = blinkIntervalSeconds
        self.doubleTapParameters = doubleTapParameters
        self.isDoubleTapEnabled = isDoubleTapEnabled
        dailyFaceDurations = [:]
        dailyWindowStart = Date()
        self.displaySecondsEnabled = displaySecondsEnabled
        self.pauseOnLockEnabled = pauseOnLockEnabled
        // Not clamped up to the minimum here: the value handed in has already been through
        // `loadFetchHistoryIntervalSeconds`, which applies the floor unless developer mode is on,
        // and forcing it again would hide a developer's deliberately sub-minute interval.
        self.fetchHistoryIntervalSeconds = min(
            TimeFlipConstants.maxFetchHistoryIntervalSeconds,
            max(1, fetchHistoryIntervalSeconds)
        )
        // Clamped on the way in as well as on the way out, so a stale or hand-edited
        // `low_battery_level` row can't surface as a threshold the UI would then refuse to set.
        // With developer mode on the stored value is left as it is, up to the reportable range, so a
        // deliberately high threshold set for testing survives a restart.
        self.lowBatteryThresholdPercent = max(
            Int(TimeFlipConstants.minBatteryLevel),
            min(TimeFlipConstants.effectiveMaxLowBatteryWarningPercent, lowBatteryThresholdPercent)
        )
        self.dailyResetHour = dailyResetHour
        self.dailyResetMinute = dailyResetMinute

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
        case .faceChanged, .doubleTap:
            // Live events only trigger history fetch; state comes from history
            break
        case .autoPauseMinutes(let minutes):
            autoPauseMinutes = clampAutoPauseMinutes(minutes)
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

    /// What the menu bar shows for a face: the name, icon and daily limit of the category the
    /// `face` table assigns it, rather than the face's own `FaceMapping` (whose fields live in
    /// the UserDefaults preferences blob and describe the face, not a category).
    ///
    /// All three come from the one `CategoryRecord`, which is the point: a limit belongs to the
    /// thing being measured. Two faces assigned the same category share its limit, where the blob
    /// gave each face its own and let the pair drift apart.
    ///
    /// `categories` is passed in rather than read off `self` so a Combine sink can supply the value
    /// it was handed: `@Published` publishes in `willSet`, so the property itself is still the old
    /// value while a subscriber runs.
    func categoryActivity(
        for faceID: UInt8,
        in categories: [UInt8: CategoryRecord]
    ) -> Activity? {
        guard let category = categories[faceID] else { return nil }
        let iconName = iconOptions.first { $0.iconId == category.iconID }?.iconName
        return Activity(
            name: category.name,
            iconName: iconName,
            limitMinutes: max(0, category.dailyLimitMinutes)
        )
    }

    func categoryActivity(for faceID: UInt8) -> Activity? {
        categoryActivity(for: faceID, in: faceCategories)
    }

    /// The colour of the category assigned to a face, for tinting it on screen. `.primary` when the
    /// category has no colour or the face has none — on screen that means "draw it in the ordinary
    /// foreground colour", which is not the same answer as the LED's (see `faceLEDColours`, where
    /// no colour means dark): an icon drawn black-on-black would just vanish.
    func faceCategoryColour(for faceID: UInt8) -> Color {
        let colourID = faceCategories[faceID]?.colourID
        return colourOptions.first { $0.colourId == colourID }?.color ?? .primary
    }

    /// The colour to draw the on-screen device in for a face: its category's colour, or **white**
    /// when there isn't one to show.
    ///
    /// White covers both a face with no category (the `Unassigned` sentinel) and a category with no
    /// colour of its own (`colour_id` 0), because on the body of the device both mean the same
    /// thing: nothing is lit. That's a third answer to the same question `faceCategoryColour` and
    /// `faceLEDColours` each answer differently, and deliberately so -- an icon falls back to
    /// `.primary` so it stays legible, the LED falls back to dark because that's off on the
    /// hardware, and the drawn body falls back to white because an unlit device is white plastic.
    func deviceBodyColour(for faceID: UInt8) -> Color {
        let colourID = faceCategories[faceID]?.colourID
        return colourOptions.first { $0.colourId == colourID }?.color ?? .white
    }

    /// The colour to draw the device's inner lines and centre icon in for a face: white when the
    /// face's colour is dark enough that black would disappear into it, black otherwise. Which
    /// colours flip is a per-row `white_lines` flag on the `colour` table, not a rule in code, so
    /// the choice can be retuned by editing the row.
    ///
    /// The device's outer outline is not this colour: it stays black whatever the face is lit in,
    /// so the shape still reads against the window behind it.
    func deviceLineColour(for faceID: UInt8) -> Color {
        let colourID = faceCategories[faceID]?.colourID
        let usesWhiteLines = colourOptions.first { $0.colourId == colourID }?.usesWhiteLines ?? false
        return usesWhiteLines ? .white : .black
    }

    /// Whether a face keeps the category it has. Unknown faces read as unlocked, which is also
    /// the column's default.
    func isFaceLocked(_ faceID: UInt8) -> Bool {
        faceLocks[faceID] ?? false
    }

    /// What the device's LED should show for each face: the `device_hex` of the colour assigned to
    /// the face's category, resolved through `colourOptions`.
    ///
    /// A face whose category has no colour — `colour_id` 0 (`None`), which has no `device_hex` and
    /// so isn't in `colourOptions` at all — goes **dark** rather than keeping whatever the LED was
    /// last set to. Clearing a colour is an instruction, and leaving the old one lit would make
    /// "None" mean "unchanged", which is invisible on the device and impossible to undo from the
    /// UI. Black is how the protocol expresses off: `0x11` takes an RGB triple with no separate
    /// enable, so all-zero is the only way to say it. Faces with no category resolve the same way.
    ///
    /// `categories` is passed in for the same reason as `categoryActivity`: a Combine sink has to
    /// use the value it was handed, not read the property back.
    func faceLEDColours(in categories: [UInt8: CategoryRecord]) -> [UInt8: ColorComponents] {
        var resolved: [UInt8: ColorComponents] = [:]
        for faceID in TimeFlipConstants.faceIDs {
            let colourID = categories[faceID]?.colourID
            resolved[faceID] = colourOptions.first { $0.colourId == colourID }?.components ?? .off
        }
        return resolved
    }

    func mappingIndex(for faceID: UInt8) -> Int? {
        faceMappings.firstIndex { $0.faceID == faceID }
    }

    func updateMapping(_ mapping: FaceMapping) {
        guard let index = mappingIndex(for: mapping.faceID) else { return }
        var updated = faceMappings
        updated[index] = mapping
        faceMappings = updated
        if mapping.faceID == currentFaceID {
            onCurrentFaceMappingChange?()
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

    /// Collapses every Device-tab disclosure group and cancels any in-progress auto-pause
    /// press-and-hold repeat. Called when the Preferences window closes so reopening it always
    /// starts fully collapsed, and so a hold that never received its release event (window closed
    /// out from under it) can't keep ticking in the background.
    /// Whether a category name is being typed somewhere in the window, so Escape belongs to that
    /// field rather than to the Close button -- see `openCategoryNameFields`.
    var isNamingCategory: Bool {
        openCategoryNameFields > 0
    }

    func categoryNameFieldAppeared() {
        openCategoryNameFields += 1
    }

    func categoryNameFieldDisappeared() {
        openCategoryNameFields = max(0, openCategoryNameFields - 1)
    }

    func collapseDeviceTabDisclosures() {
        isMoreExpanded = false
        isLEDExpanded = false
        isDoubleTapExpanded = false
        autoPauseHoldTask?.cancel()
        autoPauseHoldTask = nil
        autoPauseHoldDirection = nil
    }

    /// Stops a held App-tab stepper arrow. Called when the settings window closes, so a hold that
    /// never received its release can't keep ticking database writes in the background.
    func cancelSteppedFieldHold() {
        steppedFieldHoldTask?.cancel()
        steppedFieldHoldTask = nil
        steppedFieldHoldKey = nil
    }

    /// Called by MenuBarController every time its low-battery blink state changes (starts, stops,
    /// or toggles phase) so the Settings window's Battery line and the "Preferences..." menu item
    /// can mirror it.
    func setLowBatteryBlinkState(isLowBattery: Bool, blinkPhaseOn: Bool) {
        self.isLowBattery = isLowBattery
        self.lowBatteryBlinkPhaseOn = blinkPhaseOn
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
        // The attempt never got as far as pairing, so there is nothing to unpair -- just drop back
        // to no connection.
        connectionStatus = .disconnected
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
            connectionStatus = .failed("Could not confirm password reset — device left paired")
            return
        }
        forgetDevice()
    }

    /// Starts a full factory reset (erases face colors, task parameters, name, password --
    /// everything -- back to defaults). The caller (the Settings UI) confirms with the user first;
    /// this proceeds immediately.
    ///
    /// The reset is NOT confirmed synchronously here: the device erases flash and reboots, so
    /// `onFactoryResetRequest` only sends the 0xFF command and returns whether it was sent. The
    /// actual confirmation -- the device coming back on the factory default password -- happens
    /// asynchronously in ApplicationDelegate's reconnect path, which then drops the connection and
    /// forgets the device into the pristine never-paired state (that login is deliberately NOT
    /// treated as pairing). Until then we sit in `.resetting` ("Resetting...").
    func factoryResetAndForgetDevice() async {
        connectionStatus = .resetting
        pairedDeviceName = "Not paired"
        let sent = await onFactoryResetRequest?() ?? false
        if !sent {
            // Couldn't even send the command (e.g. not connected/logged in) -- surface it rather
            // than sit in "Resetting..." forever.
            connectionStatus = .failed("Couldn't send the reset command")
        }
    }

    /// Unpairs: forgets which device the app talks to and returns it to the never-paired state.
    /// **This is the only thing that clears `isPaired`** -- reached from the Forget Device button
    /// and from the end of a confirmed factory reset, both of which are the user deciding they no
    /// longer want this device. Nothing else may set `isPaired = false`; a dropped connection, a
    /// rejected password or a quit all leave the pairing intact and only change `connectionStatus`.
    func forgetDevice() {
        isPaired = false
        pairedDeviceName = "Not paired"
        pairedDeviceUUID = nil
        connectionStatus = .disconnected
        currentFaceID = TimeFlipConstants.unassignedFaceID
        isPaused = true
        isLocked = false
        batteryLevel = nil
        systemState = nil
        lastEventDescription = nil
        lastEventDate = nil
        deviceInfo = nil
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
        let mappings = payload.faceMappings.map { record in
            FaceMapping(
                faceID: record.faceID,
                name: ActivityLibrary.sanitizeActivityName(record.name),
                iconName: ActivityLibrary.sanitizeIconName(record.iconName)
            )
        }
        if !mappings.isEmpty {
            faceMappings = mappings.sorted { $0.faceID < $1.faceID }
        }
        isApplyingPreferences = false
    }

    func setDailyWindowStart(_ date: Date) {
        dailyWindowStart = date
    }

    /// Updates the daily-reset time (24-hour) from the App-tab picker and fires
    /// `onDailyResetTimeChange` so it's persisted and applied to the live day window.
    func setDailyResetTime(hour: Int, minute: Int) {
        let clampedHour = max(0, min(23, hour))
        let clampedMinute = max(0, min(59, minute))
        dailyResetHour = clampedHour
        dailyResetMinute = clampedMinute
        onDailyResetTimeChange?(clampedHour, clampedMinute)
    }

    /// Updates the menu bar's seconds preference from the App-tab toggle and fires
    /// `onDisplaySecondsChange` so it is persisted and applied to the live status item.
    func setDisplaySeconds(_ enabled: Bool) {
        guard enabled != displaySecondsEnabled else { return }
        displaySecondsEnabled = enabled
        onDisplaySecondsChange?(enabled)
    }

    /// Updates the pause-on-lock preference from the App-tab toggle and fires `onPauseOnLockChange`
    /// so it is persisted. Nothing else has to be applied: the lock and quit paths read the setting
    /// from the store each time they run, so the next lock picks this up whatever happens in between.
    func setPauseOnLock(_ enabled: Bool) {
        guard enabled != pauseOnLockEnabled else { return }
        pauseOnLockEnabled = enabled
        onPauseOnLockChange?(enabled)
    }

    /// Updates the low-battery threshold from the App-tab stepper and fires
    /// `onLowBatteryThresholdChange` so it is persisted and re-evaluated against the current level.
    /// Clamped to the range the device actually reports.
    func setLowBatteryThreshold(_ percent: Int) {
        let clamped = max(
            Int(TimeFlipConstants.minBatteryLevel),
            min(TimeFlipConstants.effectiveMaxLowBatteryWarningPercent, percent)
        )
        guard clamped != lowBatteryThresholdPercent else { return }
        lowBatteryThresholdPercent = clamped
        onLowBatteryThresholdChange?(clamped)
    }

    /// Updates the history-fetch interval, in seconds, and fires `onFetchHistoryIntervalChange`
    /// so it is persisted and the live timer re-armed.
    func setFetchHistoryIntervalSeconds(_ seconds: Int) {
        let clamped = max(
            TimeFlipConstants.minFetchHistoryIntervalSeconds,
            min(TimeFlipConstants.maxFetchHistoryIntervalSeconds, seconds)
        )
        guard clamped != fetchHistoryIntervalSeconds else { return }
        fetchHistoryIntervalSeconds = clamped
        onFetchHistoryIntervalChange?(clamped)
    }

    func replaceDailyTotals(_ totals: [UInt8: TimeInterval]) {
        dailyFaceDurations = totals
    }

    func incrementDailyTotal(faceID: UInt8, by delta: TimeInterval) {
        guard delta > 0 else { return }
        dailyFaceDurations[faceID, default: 0] += delta
    }

    private func observePreferences() {
        // Coalesce all preference changes into a single debounced sink
        // to avoid cascading persistence calls and reduce disk I/O
        Publishers.MergeMany([
            $faceMappings.map { _ in () }.eraseToAnyPublisher()
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
        let records = faceMappings.map { mapping -> FaceMappingRecord in
            let sanitizedName = ActivityLibrary.sanitizeActivityName(mapping.name)
            let sanitizedIcon = ActivityLibrary.sanitizeIconName(mapping.iconName)
            let sanitized = FaceMapping(
                faceID: mapping.faceID,
                name: sanitizedName,
                iconName: sanitizedIcon
            )
            return FaceMappingRecord(mapping: sanitized)
        }
        let payload = PreferencesPayload(faceMappings: records)
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

    private func clampAutoPauseMinutes(_ value: UInt16) -> UInt16 {
        // UI clamps to 0–240 minutes; keep the same guardrails at persistence.
        return UInt16(max(0, min(240, Int(value))))
    }


    /// The device is reachable and talking to us. Called on every successful connect, so it runs
    /// both at the end of a first pairing and after each routine reconnect.
    ///
    /// Pairing is the part that only happens once: `isPaired` is set unconditionally because
    /// reaching a device is proof the app is paired to it, but `onPairingChange` fires only on the
    /// false -> true edge, so a reconnect reports a connection and not a fresh pairing.
    func confirmConnected(name: String, uuid: String?) {
        let wasPaired = isPaired
        isPaired = true
        connectionStatus = .connected
        pairedDeviceName = name
        pairedDeviceUUID = uuid ?? pairedDeviceUUID ?? UUID().uuidString
        if let id = pendingPairingDeviceID {
            deviceStatusMessages[id] = nil
            pendingPairingDeviceID = nil
            pendingPairingDeviceName = nil
        }
        discoveredDevices = []
        if !wasPaired {
            onPairingChange?(true)
        }
        persistPreferences()
    }

    /// A pairing attempt failed: the user picked a device and the app could not get as far as
    /// talking to it. Nothing was ever paired, so this leaves `isPaired` false rather than
    /// clearing it -- for a device that *is* already paired, see `connectionFailed(message:)`.
    func pairingFailed(message: String?) {
        isPaired = false
        connectionStatus = .failed(message)
        if let id = pendingPairingDeviceID {
            deviceStatusMessages[id] = message ?? "Failed"
            pendingPairingDeviceID = nil
            pendingPairingDeviceName = nil
        }
        onPairingChange?(false)
        persistPreferences()
    }

    /// A connection to an already-paired device failed in a way that retrying will not fix -- in
    /// practice, the device rejecting the stored password. The pairing is deliberately left
    /// standing: the app still knows which device it is meant to talk to, and whether to give up
    /// on that device is the user's call, made with Forget Device. Surfacing the failure here and
    /// not scheduling another attempt is what stops the app quietly retrying a password the device
    /// no longer accepts.
    func connectionFailed(message: String?) {
        connectionStatus = .failed(message)
    }
}

/// Whether the app can currently reach the device it is paired to, and what it is doing about it.
/// Every case is transient -- see `AppState.isPaired` for the durable half, and `isConnected` for
/// the two combined. Deliberately says nothing about *which* device: that never changes here.
enum ConnectionStatus: Equatable {
    /// Not connected and not trying: either nothing is paired, or a paired device has been let go
    /// of after a deliberate teardown. Rendered as "Not paired" only when `isPaired` is false.
    case disconnected
    /// A pairing attempt is in flight: the user picked a device and the app is trying to reach it
    /// for the first time. The one case that can be live while `isPaired` is still false.
    case pairing
    /// Connected and logged in.
    case connected
    /// Connection to an already-paired device was lost (BLE range, sleep, etc.) and an automatic
    /// reconnect is in progress. Distinct from `.failed`/`.disconnected` so the menu bar keeps
    /// showing the last known activity/icon instead of tearing down to an unpaired look.
    case reconnecting
    /// A factory reset is in progress: the 0xFF command was sent and we're waiting for the device
    /// to reboot and come back on the default password (the confirmation), after which the app
    /// drops to the pristine never-paired state. Shown as "Resetting..." rather than a scary
    /// "Failed/Disconnected" while the device reboots. See ApplicationDelegate's reset flow.
    case resetting
    case failed(String?)
}

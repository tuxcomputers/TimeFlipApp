import Combine
import OSLog
import SwiftUI

@MainActor
final class AppState: ObservableObject {
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
    /// What the Device tab shows in its Name row: the device name while paired, the "Not paired"
    /// placeholder otherwise. Display only -- it is never persisted, because the placeholder is a
    /// rendering of "no device", not a device called that. The stored name is `deviceName`.
    @Published var pairedDeviceName: String
    /// The name the cube itself is carrying (its GAP Device Name `0x2A00`), read from the
    /// peripheral on each connect and persisted to the `device_name` setting.
    ///
    /// **Outlives Forget Device**, unlike `pairedDeviceUUID`: forgetting does not un-rename the
    /// cube, so this stays the only string the filtered scan can match a renamed device on. It is
    /// cleared only by a confirmed factory reset, which reverts the cube to the vendor name.
    /// `nil` until the app has actually connected to a device and been told a name.
    @Published var deviceName: String?
    /// Set the moment a rename is written, and shown under the Name row until the device next
    /// connects, which is when the lag it describes ends. In memory only and deliberately not
    /// persisted: it is a note about something that just happened in this session, and a relaunch
    /// is a reconnect, which is exactly the event that clears it. See
    /// `DeviceNameRules.renameLagNotice` for what it says and why the app says anything.
    @Published var renameLagNotice: String?
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
    /// Seconds of tracked time in the current day window, keyed by `category.category_id` -- the key
    /// a `daily_limit` is set against, so two faces sharing a category share one figure. Keyed by
    /// face until this branch, which is what let a shared limit go unnoticed; see
    /// `DailyCategoryTotals`.
    @Published var dailyCategoryDurations: [Int: TimeInterval]
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
    /// How short a segment has to be before it counts as the cube being turned past a face rather
    /// than time spent on it (the `blip_time` setting). `0` disables the filter.
    @Published var blipTimeSeconds: Int
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
    /// Writes a new name to the device (command `0x15`), reporting whether the write landed. The
    /// name is already validated by `DeviceNameRules` before this is called.
    var onDeviceRenameRequest: ((String) async -> Bool)?
    // Fired with the new daily-reset time (24-hour hour, minute) when the App-tab picker changes it,
    // so the setting can be persisted and the running day-window/timer re-armed (see ApplicationDelegate).
    var onDailyResetTimeChange: ((_ hour: Int, _ minute: Int) -> Void)?
    var onDisplaySecondsChange: ((Bool) -> Void)?
    var onPauseOnLockChange: ((Bool) -> Void)?
    var onLowBatteryThresholdChange: ((Int) -> Void)?
    /// Passes seconds, like everything outside the App tab's own control.
    var onFetchHistoryIntervalChange: ((Int) -> Void)?
    var onBlipTimeChange: ((Int) -> Void)?
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
        deviceName: String? = nil,
        pairedDeviceUUID: String? = nil,
        displaySecondsEnabled: Bool = true,
        pauseOnLockEnabled: Bool = true,
        lowBatteryThresholdPercent: Int = TimeFlipConstants.defaultLowBatteryWarningPercent,
        fetchHistoryIntervalSeconds: Int = 60,
        blipTimeSeconds: Int = TimeFlipConstants.defaultBlipTimeSeconds,
        dailyResetHour: Int = 3,
        dailyResetMinute: Int = 0
    ) {
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
        self.deviceName = deviceName
        // A remembered name survives Forget Device, so it is not on its own reason to show one --
        // the Device tab reads "Not paired" until there is a pairing for that name to belong to.
        self.pairedDeviceName = (isPaired ? deviceName : nil) ?? "Not paired"
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
        dailyCategoryDurations = [:]
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
        // Clamped on the way in as well as out, so a hand-edited row cannot surface a value the
        // App tab would then refuse to set.
        self.blipTimeSeconds = max(
            TimeFlipConstants.minBlipTimeSeconds,
            min(TimeFlipConstants.maxBlipTimeSeconds, blipTimeSeconds)
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

        if DeveloperMode.isEnabled { applyDeveloperConfig() }
        loadClientSecretOnce()
        loadDevicePassword()
        observePreferences()
    }

    // MARK: - Developer mode
    // To remove developer mode: delete this section, the `isDeveloperConfigLoaded` property,
    // the `developerConfigStore` property/init param, and every other `DeveloperMode.isEnabled`
    // call site below (in persistGoogleClientSecret and persistDevicePassword).

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

    /// Writes the Google keys back to `config.json`, **passing the PIN through from whatever is
    /// already on disk** rather than from memory.
    ///
    /// `config.json` is a file the developer maintains by hand, and the PIN in it is an input: it
    /// says what password to present to a cube this app has not paired with yet. The app writing
    /// its own current password over that turns the file into a race between the developer's editor
    /// and whatever state the app happens to hold, which the app always wins and never announces.
    ///
    /// Read from disk rather than simply omitted, because omitting it would encode the key as
    /// absent and delete the developer's PIN instead of leaving it alone.
    private func persistDeveloperConfig() {
        developerConfigStore.save(
            DeveloperConfigPayload(
                googleClientID: sanitizedClientID(),
                googleClientSecret: googleClientSecret.isEmpty ? nil : googleClientSecret,
                devicePassword: developerConfigStore.load()?.devicePassword
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
    /// `face` table assigns it. A face used to carry its own name and icon in a UserDefaults blob,
    /// independently of any category; that blob is gone and this is the only answer left.
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
            categoryID: category.id,
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

    /// Stops a held stepper arrow, on either tab -- every stepper in the window shares this one
    /// hold. Called when the settings window closes, so a hold that never received its release
    /// can't keep ticking database writes in the background.
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

    /// Renames the physical device, and adopts the new name locally only once the write lands.
    ///
    /// The order matters: the name shown on the Device tab and stored in `device_name` is meant to
    /// be what the cube is actually carrying, so a failed write must leave both saying what the
    /// cube still answers to. Getting this backwards would be worse than cosmetic -- `device_name`
    /// is what a scan filter matches a renamed device on, so a name the device never took would be
    /// a name nothing can be found by.
    ///
    /// Returns the problem to show, or `nil` when the rename was applied or there was nothing to do.
    @discardableResult
    func renameDevice(to typed: String) async -> DeviceNameProblem? {
        switch DeviceNameRules.renameDecision(typed: typed, current: deviceName) {
        case .ignore:
            return nil
        case .refuse(let problem):
            DeveloperMode.debugPrint(.field, "Device rename refused: \(problem.id) for \"\(typed)\"")
            return problem
        case .write(let name):
            guard await onDeviceRenameRequest?(name) == true else {
                DeveloperMode.debugPrint(.field, "Device rename failed to write: \"\(name)\"")
                return .writeFailed
            }
            // Nothing confirms this write at the time it is made, and the app cannot pretend
            // otherwise. The device never updates the command result characteristic for 0x15 (a
            // re-read ladder at +250ms, +500ms, +1s and +2s found the previous command's response
            // still sitting there every time), and `CBPeripheral.name` does not refresh until the
            // next connection. See docs/timeflip2-firmware-observations.md.
            //
            // So the new name is adopted on the strength of the write not having failed, and two
            // later signals correct it if that was wrong: the device narrates "Neme set" on the
            // events characteristic within ~250ms, and `peripheralDidUpdateName` reports the real
            // name about two seconds into the next connection.
            // Captured before the overwrite: the notice quotes the name the device will go on
            // reporting for the rest of this connection, which is the one being replaced here.
            let reportedUntilReconnect = deviceName
            deviceName = name
            pairedDeviceName = name
            renameLagNotice = DeviceNameRules.renameLagNotice(
                newName: name,
                previousName: reportedUntilReconnect
            )
            DeveloperMode.debugPrint(.field, "Device renamed to \"\(name)\"")
            return nil
        }
    }


    /// Unpairs: forgets which device the app talks to and returns it to the never-paired state.
    /// **This is the only thing that clears `isPaired`** -- reached from the Forget Device button
    /// and from the end of a confirmed factory reset, both of which are the user deciding they no
    /// longer want this device. Nothing else may set `isPaired = false`; a dropped connection, a
    /// rejected password or a quit all leave the pairing intact and only change `connectionStatus`.
    ///
    /// - Parameter deviceWasWiped: whether the device itself has been factory reset (cmd `0xFF`),
    ///   which reverts its name to the vendor default and so makes the remembered `deviceName`
    ///   wrong -- that gets discarded too. Plain Forget Device passes false and **keeps** the name:
    ///   forgetting does not un-rename the cube, so a renamed one still answers only to the name it
    ///   was given, and throwing that string away is throwing away the way to find it again.
    func forgetDevice(deviceWasWiped: Bool = false) {
        isPaired = false
        pairedDeviceName = "Not paired"
        pairedDeviceUUID = nil
        // Nothing left for it to describe: the Name row is back to "Not paired", and a factory
        // reset has taken the rename with it.
        renameLagNotice = nil
        if deviceWasWiped {
            deviceName = nil
        }
        connectionStatus = .disconnected
        currentFaceID = TimeFlipConstants.unassignedFaceID
        isPaused = true
        isLocked = false
        batteryLevel = nil
        systemState = nil
        lastEventDescription = nil
        lastEventDate = nil
        deviceInfo = nil
        // Correct in memory, and deliberately not persisted anywhere in developer mode: Forget
        // Device sends 0x30 to reset the cube first, so the factory default really is the password
        // the *next* pairing attempt should present. See `persistDevicePassword` for why that no
        // longer reaches `config.json`.
        devicePassword = TimeFlipConstants.defaultPassword
        onPairingChange?(false)
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

    /// Updates `blip_time` from the App-tab stepper and fires `onBlipTimeChange` so it is
    /// persisted. Nothing is re-armed or re-evaluated: the value is read when a segment is
    /// converted, so a change applies to the next conversion without anything being kept in sync.
    func setBlipTimeSeconds(_ seconds: Int) {
        let clamped = max(
            TimeFlipConstants.minBlipTimeSeconds,
            min(TimeFlipConstants.maxBlipTimeSeconds, seconds)
        )
        guard clamped != blipTimeSeconds else { return }
        blipTimeSeconds = clamped
        onBlipTimeChange?(clamped)
    }

    /// Publishes the day's per-face totals. The only way they are set: they are always a whole set
    /// re-derived from `device_event` (`DailyCategoryTotals.seedFromHistory`), never a running tally
    /// nudged one segment at a time. An `incrementDailyTotal(faceID:by:)` used to exist for the
    /// latter and was removed with it -- a figure the database cannot be asked to confirm is one
    /// that can quietly drift from the rows it is supposed to be summarising.
    func replaceDailyTotals(_ totals: [Int: TimeInterval]) {
        dailyCategoryDurations = totals
    }

    private func observePreferences() {
        // Debounced because it is edited by typing: without it every keystroke in the Settings
        // field triggers its own Keychain write. This used to be one of three sinks merged into a
        // shared debounce, alongside the UserDefaults blob's; the blob is gone and the other two
        // are what remain.
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
        // Developer mode persists nothing here, on purpose. The PIN lives in `config.json`, which
        // the developer maintains by hand and the app only ever reads (see `persistDeveloperConfig`).
        //
        // This used to rewrite that file with the app's current password, which is how a Forget
        // Device came to stamp "000000" over a hand-set PIN on 2026-08-01: the re-pair then rotated
        // the cube to 123456, the file still said 000000, and every launch afterwards was refused
        // at login with nothing pointing back at the forget. A file that is edited by hand and
        // silently rewritten by the app cannot be relied on by either.
        //
        // Nothing is lost by not storing it: in developer mode the rotation target is the fixed
        // `DeveloperMode.devicePassword`, which is also where a dev build starts, so the two agree
        // across launches without anything being written down.
        if isDeveloperConfigActive { return }
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


    /// Whether the name the cube just reported should replace the one already stored.
    ///
    /// Only on a first pairing, or when nothing is stored at all. On a routine reconnect the stored
    /// name wins, which is the opposite of what "mirror the device" would suggest, and it is the
    /// hardware that forces it: the reported name is `CBPeripheral.name`, which macOS caches and
    /// refreshes only when it next connects and re-reads `0x2A00`, so straight after a rename it is
    /// **one connection behind**.
    ///
    /// Measured on 2026-08-01. The cube was renamed to `Plopper` at 22:44:43; the next connect
    /// reported `Dibby`, the name from before that rename, and overwrote the correct stored value;
    /// the connect after that reported `Plopper` and overwrote it back. So a rename was followed by
    /// exactly one session showing and storing the previous name.
    ///
    /// That window is not cosmetic: `device_name` is what the scan filter matches a renamed cube
    /// on, so during it the app hunts for a name the device stopped answering to. Only the cube's
    /// unchanged advertised name kept reconnects working at all.
    ///
    /// A first pairing is the one moment the cube's answer genuinely beats ours, because we have no
    /// answer of our own, and a peripheral this Mac has not connected to before has nothing cached
    /// to be stale. It also has to be the rule rather than "adopt when nothing is stored", because
    /// Forget Device deliberately keeps `deviceName`: pairing a *different* cube afterwards must
    /// take the new cube's name rather than inherit the old one's.
    ///
    /// The cost is that a rename made in some other app is not noticed until this one re-pairs.
    /// That is the better failure: it leaves a name merely out of date, where trusting the cache
    /// silently reverts a name the user just set.
    private func shouldAdoptReportedName(wasPaired: Bool) -> Bool {
        !wasPaired || deviceName == nil
    }

    /// The device has told us what it is actually called, from `peripheralDidUpdateName` -- the one
    /// signal that fires *because* the name changed rather than reporting a cached one, so it
    /// outranks the stored name `confirmConnected` otherwise keeps.
    func adoptReportedDeviceName(_ name: String) {
        deviceName = name
        pairedDeviceName = name
        clearRenameLagNoticeIfCaughtUp(reported: name)
    }

    /// Drops the post-rename notice once the device is reporting the name it was given, because at
    /// that point the lag the notice describes is over and it would be describing nothing.
    ///
    /// Keyed on the names agreeing rather than on "a connection happened", because one connection
    /// is not reliably enough. Measured 2026-08-01: a cube renamed to `Plopper` reported `Dibby` on
    /// the next connect and only `Plopper` on the one after, so clearing on the first reconnect
    /// would retire the notice while the stale name was still exactly what the user would find.
    private func clearRenameLagNoticeIfCaughtUp(reported: String?) {
        guard renameLagNotice != nil, let reported, reported == deviceName else { return }
        renameLagNotice = nil
        DeveloperMode.debugPrint(.deviceName, "rename lag notice cleared: device now reports \"\(reported)\"")
    }

    /// The device is reachable and talking to us. Called on every successful connect, so it runs
    /// both at the end of a first pairing and after each routine reconnect.
    ///
    /// Pairing is the part that only happens once: `isPaired` is set unconditionally because
    /// reaching a device is proof the app is paired to it, but `onPairingChange` fires only on the
    /// false -> true edge, so a reconnect reports a connection and not a fresh pairing.
    /// `name` is what the cube reports carrying (`TimeFlipDevice.deviceName`), and it is trusted
    /// **only on a first pairing**. See `shouldAdoptReportedName`.
    func confirmConnected(name: String?, uuid: String?) {
        let wasPaired = isPaired
        isPaired = true
        connectionStatus = .connected
        let reported = (name?.isEmpty == false) ? name : nil
        if let reported, shouldAdoptReportedName(wasPaired: wasPaired) {
            deviceName = reported
        } else if let reported, reported != deviceName {
            DeveloperMode.debugPrint(
                .deviceName,
                "keeping stored name \"\(deviceName ?? "nil")\" over reported \"\(reported)\" (reconnect, reported name lags by one connection)"
            )
        }
        // The stored name first, the reported one only as a fallback for a device we have never
        // been told the name of.
        if let known = deviceName ?? reported {
            pairedDeviceName = known
        }
        clearRenameLagNoticeIfCaughtUp(reported: reported)
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

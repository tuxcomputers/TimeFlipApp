#if canImport(CDBus)
import FacetCore
import Foundation

/// The Linux slot in the radio square: scanning, connecting and logging in, over BlueZ.
///
/// **`BluetoothRadio` is the reference and this is the same job**, minus everything the Settings window drives:
/// there is no device list to draw here yet, so what is left is the one path a paired app takes -- reach for the
/// cube, work through what answered, and hand a live GATT table to `DeviceLogin`. Every decision inside it is
/// somebody else's: `DeviceScanRules` says which advertisement is a cube and in what order to try them, and
/// `DeviceLogin` says what a login is. This makes the calls and holds the state machine.
///
/// **The one rule this file exists to keep is the archive's**, and both platforms keep it the same way: a reach
/// asks "does this one take our PIN", never "is this the right identifier". Neither identifier available is unique
/// to a cube -- BlueZ's is the device's own address, which is the same shape on every TimeFlip in the room -- so a
/// refusal is an answer rather than a failure and the queue moves on. Connecting to whichever answered first is
/// what the archive recorded as "a colleague's cube advertising a moment sooner was enough to lock this user out of
/// their own device".
///
/// **What is polled, and why it is polled.** BlueZ says everything through its object tree: a device appearing, its
/// services resolving, a link dropping. libdbus dispatches into its own main loop or when it is pumped, and pumping
/// is the half that does not ask GLib and libdbus to share a file descriptor -- so a wake on the app's own clock
/// reads the tree instead. `CLAUDE.md` asks a repeating read to say so, and this is it: what is on the timer is the
/// bus, and every answer still comes from BlueZ at the moment it is asked for.
///
/// **What is missing, said plainly rather than left to be discovered.** There is no factory reset here, because
/// nothing on this platform can ask for one yet -- the reset is a Device tab control and this platform has no
/// window. `isFactoryResetRunning` therefore answers `false` and means it.
@MainActor
final class BlueZCubeRadio: CubeRadio {
    // MARK: - what it says happened

    /// Every device this scan has seen, whether or not it is a cube.
    var onDevicesChanged: (([ScannedDevice]) -> Void)?
    var onScanningChanged: ((Bool) -> Void)?
    var onLoginBegan: ((UUID) -> Void)?
    var onLoginEnded: ((UUID, DeviceLoginOutcome) -> Void)?
    /// The link going, deliberately or not. **Not the same as a login ending**: a login that failed never had a link.
    var onConnectionDropped: ((UUID) -> Void)?
    /// The link ending, for whatever holds per-link state and has to let go of it.
    var onLinkEnded: ((UUID) -> Void)?
    var onPINChanged: ((String) -> Void)?
    var onPINAccepted: ((UUID, String) -> Void)?
    var onBatteryLevel: ((UUID, Int?) -> Void)?
    var onFace: ((UUID, Int?) -> Void)?
    var onDeviceName: ((UUID, String) -> Void)?
    var onCubeStatus: ((UUID, DeviceCommandRules.Status?) -> Void)?
    var onSystemState: ((UUID, DeviceSystemStateRules.State) -> Void)?
    var onDoubleTapParameters: ((UUID, DoubleTapParameters) -> Void)?
    var onDeviceInfo: ((UUID, DeviceInfo) -> Void)?
    /// The characteristics are discovered and the cube can be asked things. What the history fetch waits for.
    var onCubeReady: ((UUID) -> Void)?
    /// The login has finished asking its own questions, so a command sent now is not writing over one.
    var onCubeSettled: ((UUID) -> Void)?

    // MARK: - the timings

    /// How long one scan looks before giving up on finding anything eligible. **`BluetoothRadio.timeoutSeconds` is
    /// fifteen and this matches it deliberately**: `DeviceReconnector` says out loud that it does not time a reach
    /// itself because the radio already does, and two clocks answering "how long do we look for" is the two-answers
    /// fault applied to a scan.
    static let scanSeconds: TimeInterval = 15
    /// How often the tree is read while a scan is running.
    static let scanPollSeconds: TimeInterval = 0.5
    /// How long a `Connect` is given to reach `ServicesResolved`. BlueZ reports a device connected several round
    /// trips before its GATT tree has been read, and nothing may be looked up by UUID until it has.
    static let resolveSeconds: TimeInterval = 20
    static let resolvePollSeconds: TimeInterval = 0.25
    /// How often the link is checked while one is up. **Two seconds rather than a tenth**, because what this catches
    /// is a cube leaving the room: it is not on the path of anything a person is waiting for.
    static let linkPollSeconds: TimeInterval = 2

    // MARK: - what it is doing

    private let link: BlueZLink
    private let scheduler: Scheduler
    private let debugLog: DebugLog?

    private(set) var isScanning = false {
        didSet {
            guard isScanning != oldValue else { return }
            onScanningChanged?(isScanning)
        }
    }

    private(set) var connectedDevice: UUID?

    var isReachingForCube: Bool { reaching != nil || attempt != nil }

    /// **Always `false`, and it means it.** A factory reset is asked for from the Device tab, which this platform
    /// does not have; there is no path here that starts one, so there is none to be waiting on. `DeviceReconnector`
    /// reads this to decide whether to stand down, and standing down for something that cannot be happening would
    /// be a loop that never runs.
    var isFactoryResetRunning: Bool { false }

    /// What this scan has seen. **Not a fact being remembered**: it is the last answer BlueZ gave, kept only so a
    /// change can be published, and `forgetWhatWasFound` empties it.
    private var found: [ScannedDevice] = []

    /// The charge the connected cube last reported, or `nil` when there is no live reading.
    ///
    /// **What is held is the *shown* figure, not the last byte received**, which is `BluetoothRadio`'s arrangement
    /// and its reason: `BatteryRules.shown` needs the figure on show to judge the next reading against, this
    /// hardware reporting a charge that wavers across one percent all day. It lives for as long as the connection
    /// that reported it, which is why it is not a table value.
    private(set) var batteryPercent: Int?

    /// The face the connected cube is resting on, or `nil` when there is no live reading. **Not a table value for
    /// the charge's reason**: which way up a cube is lying is a fact about this minute.
    private(set) var cubeFace: Int?

    /// What the cube last said about being locked, being paused, and its auto-pause delay.
    ///
    /// **Held rather than asked for on demand, and that is forced rather than chosen.** Asking is a round trip and
    /// the thing that needs the answer is a menu item's title at the instant the menu opens, so it is read when the
    /// link comes up and refreshed by the read-back of every command the app sends. What it cannot cover is the
    /// cube being changed by something else -- a double tap, auto-pause, the vendor's app -- which is why nothing
    /// draws its `isPaused`.
    private(set) var cubeStatus: DeviceCommandRules.Status?

    private var reaching: Reach?
    private var attempt: Attempt?

    private var scanPoll: ScheduledWake?
    private var scanDeadline: ScheduledWake?
    private var resolvePoll: ScheduledWake?
    private var resolveDeadline: ScheduledWake?
    private var linkPoll: ScheduledWake?

    private var login: DeviceLogin?

    init(link: BlueZLink, scheduler: Scheduler, debugLog: DebugLog?) {
        self.link = link
        self.scheduler = scheduler
        self.debugLog = debugLog
    }

    /// A run at getting back to this app's cube: which PINs to present, and every device still worth presenting them
    /// to.
    ///
    /// **There is no "the" device here, and that is the point** -- see this type's own note. `preferred` is a hint
    /// and never a gate: worth trying first when it turns up, worth nothing when it does not.
    private struct Reach {
        let preferred: UUID?
        let candidates: [String]
        let rotatingTo: String?
        let remembered: String?
        let previouslyKnown: String?
        var queue: [UUID] = []
        var tried: Set<UUID> = []
        /// Whether anything refused a PIN, which is what tells "nothing was in range" from "none of them was ours".
        var anyRefused = false
    }

    /// One device being tried, and which of the PINs it is on.
    private struct Attempt {
        let id: UUID
        let candidates: [String]
        var index = 0
        var pin: String { candidates.isEmpty ? DeviceLoginRules.defaultPIN : candidates[index] }
    }

    // MARK: - reaching one

    func reach(
        _ id: UUID,
        presenting candidates: [String],
        rotatingTo: String?,
        remembered: String?,
        previouslyKnown: String?
    ) {
        guard connectedDevice != id else { return }
        begin(
            reaching: Reach(
                preferred: id,
                candidates: candidates,
                rotatingTo: rotatingTo,
                remembered: remembered,
                previouslyKnown: previouslyKnown
            ),
            because: "Reaching for the paired cube: scanning, and every device with the name will be tried"
        )
    }

    /// Looks for any cube at all and stops at the first that takes one of these PINs.
    ///
    /// **The same reach with no preferred identifier**, which is what pairing is: this app has never met the cube,
    /// so there is nothing to prefer and the PIN is the whole of the test. On the Mac this is the Device tab's
    /// press; here it is the menu bar's *Pair a cube*, there being no window.
    func pair(presenting candidates: [String], rotatingTo: String?) {
        begin(
            reaching: Reach(
                preferred: nil,
                candidates: candidates,
                rotatingTo: rotatingTo,
                // **No remembered name**, deliberately: an unpaired app has none, and `DeviceScanRules` still
                // matches anything carrying the vendor's name, which is what a factory-fresh cube advertises.
                remembered: nil,
                previouslyKnown: nil
            ),
            because: "Looking for a cube to pair with: every device with the name will be tried"
        )
    }

    private func begin(reaching: Reach, because reason: String) {
        guard !isReachingForCube else {
            debugLog?.record(.login, "Already busy with a device; not looking again")
            return
        }
        debugLog?.record(.login, reason)
        self.reaching = reaching
        beginScan()
    }

    func forgetWhatWasFound() {
        guard !found.isEmpty else { return }
        found = []
        debugLog?.record(.scan, "Dropped what the last scan found, so the next one has to look again")
        onDevicesChanged?(found)
    }

    // MARK: - looking

    private func beginScan() {
        do {
            guard try link.powerOn() else {
                endReach(reporting: .unreachable, because: "the Bluetooth adapter would not power on")
                return
            }
            try link.startDiscovery()
        } catch {
            endReach(reporting: .unreachable, because: Self.describe(error))
            return
        }
        isScanning = true
        debugLog?.record(.scan, "Scanning for up to \(Int(Self.scanSeconds))s")

        scanPoll = scheduler.wake(in: Self.scanPollSeconds, repeating: true) { [weak self] in
            self?.readWhatIsThere()
        }
        scanDeadline = scheduler.wake(in: Self.scanSeconds) { [weak self] in
            guard let self else { return }
            debugLog?.record(.scan, "The scan window closed")
            // **Read once more on the way out**, rather than deciding from whatever the last poll happened to see.
            // The window and the poll are two different wakes, and a device that answered in between them would
            // otherwise be a cube that was in the room and was never tried.
            refreshWhatIsThere()
            closeTheScan()
            beginTryingWhatWasFound()
        }
    }

    /// Reads the tree and publishes what changed.
    private func refreshWhatIsThere() {
        let devices: [ScannedDevice]
        do {
            devices = try link.scannedDevices()
        } catch {
            debugLog?.record(.scan, "The device list could not be read: \(Self.describe(error))")
            return
        }
        guard devices != found else { return }
        found = devices
        onDevicesChanged?(devices)
    }

    /// One turn of the scan: read the tree, and cut the window short if the remembered cube is already there.
    private func readWhatIsThere() {
        refreshWhatIsThere()

        // **The remembered identifier may end the window early, and only it.** Anything else eligible is worth
        // trying but is not worth cutting the look short for: a room may hold a cube that answers a moment later
        // and is the one this app paired with.
        guard let reaching, let preferred = reaching.preferred else { return }
        guard eligible(from: found, for: reaching).contains(where: { $0.id == preferred }) else { return }
        debugLog?.record(.scan, "The remembered cube answered, so the scan window ends here")
        closeTheScan()
        beginTryingWhatWasFound()
    }

    private func eligible(from devices: [ScannedDevice], for reaching: Reach) -> [ScannedDevice] {
        devices.filter {
            DeviceScanRules.isEligible(
                $0, remembered: reaching.remembered, previouslyKnown: reaching.previouslyKnown
            )
        }
    }

    private func closeTheScan() {
        scanPoll?.cancel()
        scanPoll = nil
        scanDeadline?.cancel()
        scanDeadline = nil
        do {
            try link.stopDiscovery()
        } catch {
            // Said rather than swallowed: a discovery left running is a radio nobody turned off, and the next
            // reach behaves differently because of it.
            debugLog?.record(.scan, "Discovery would not stop: \(Self.describe(error))")
        }
        isScanning = false
    }

    private func beginTryingWhatWasFound() {
        guard var reaching else { return }
        let candidates = eligible(from: found, for: reaching).filter { !reaching.tried.contains($0.id) }
        reaching.queue = DeviceScanRules.reachOrder(
            candidates,
            preferring: reaching.preferred,
            remembered: reaching.remembered,
            previouslyKnown: reaching.previouslyKnown
        )
        self.reaching = reaching
        debugLog?.record(.login, "\(reaching.queue.count) devices to try")
        tryNextCandidate()
    }

    private func tryNextCandidate() {
        guard var reaching else { return }
        guard !reaching.queue.isEmpty else {
            // **Which of the two endings is the whole of what this decides.** Something refusing a PIN means the
            // cube was there and was not ours, or ours has lost the PIN; nothing at all means no cube answered. The
            // reconnect loop tells the user different things about them.
            endReach(
                reporting: reaching.anyRefused ? .wrongPIN : .unreachable,
                because: reaching.anyRefused
                    ? "everything that answered refused this app's PINs"
                    : "nothing that answered was a cube"
            )
            return
        }
        let id = reaching.queue.removeFirst()
        reaching.tried.insert(id)
        self.reaching = reaching
        attempt = Attempt(id: id, candidates: reaching.candidates)
        connectToTheAttempt()
    }

    private func connectToTheAttempt() {
        guard let attempt else { return }
        do {
            try link.connect(attempt.id)
        } catch {
            debugLog?.record(.login, "Could not connect: \(Self.describe(error))")
            giveUpOnThisDevice(.unreachable)
            return
        }
        waitForTheServicesToResolve()
    }

    /// **Connected and resolved are different facts, and the app needs the second.** Nothing can be looked up by
    /// UUID until BlueZ has read the GATT tree, which is several round trips after the link is reported up.
    private func waitForTheServicesToResolve() {
        resolvePoll?.cancel()
        resolvePoll = scheduler.wake(in: Self.resolvePollSeconds, repeating: true) { [weak self] in
            self?.readWhetherItResolved()
        }
        resolveDeadline?.cancel()
        resolveDeadline = scheduler.wake(in: Self.resolveSeconds) { [weak self] in
            self?.debugLog?.record(.login, "Connected, and the services were not resolved in time")
            self?.stopWaitingToResolve()
            self?.giveUpOnThisDevice(.unreachable)
        }
    }

    private func stopWaitingToResolve() {
        resolvePoll?.cancel()
        resolvePoll = nil
        resolveDeadline?.cancel()
        resolveDeadline = nil
    }

    private func readWhetherItResolved() {
        guard let attempt else { return }
        guard let device = try? link.device(attempt.id), device.areServicesResolved else { return }
        stopWaitingToResolve()
        beginLogin(on: device)
    }

    // MARK: - logging in

    private func beginLogin(on device: BlueZObjectTree.Device) {
        guard let attempt, let reaching else { return }
        let id = attempt.id
        onLoginBegan?(id)
        debugLog?.record(.login, "Presenting a PIN to \(device.name.isEmpty ? device.address : device.name)")

        login = DeviceLogin(
            gatt: link.gatt(for: device),
            pin: attempt.pin,
            rotatingTo: reaching.rotatingTo,
            debugLog: debugLog,
            scheduler: scheduler,
            rotated: { [weak self] pin in self?.onPINChanged?(pin) },
            accepted: { [weak self] pin in self?.onPINAccepted?(id, pin) },
            tapsReported: { [weak self] parameters in self?.onDoubleTapParameters?(id, parameters) },
            reported: { [weak self] info in self?.onDeviceInfo?(id, info) },
            battery: { [weak self] percent in self?.received(batteryLevel: percent, from: id) },
            face: { [weak self] face in self?.received(face: face, from: id) },
            nameReported: { [weak self] name in self?.onDeviceName?(id, name) },
            status: { [weak self] status in self?.received(status: status, from: id) },
            systemState: { [weak self] state in self?.onSystemState?(id, state) },
            ready: { [weak self] in self?.onCubeReady?(id) },
            settled: { [weak self] in self?.onCubeSettled?(id) },
            finished: { [weak self] outcome in self?.loginEnded(id, outcome) }
        )
        login?.begin()
    }

    private func loginEnded(_ id: UUID, _ outcome: DeviceLoginOutcome) {
        guard outcome != .loggedIn else {
            connectedDevice = id
            reaching = nil
            attempt = nil
            watchTheLink()
            onLoginEnded?(id, .loggedIn)
            return
        }

        // **A refusal is an answer, not a failure**, so the next PIN on the same device comes before the next
        // device. Only when a device has refused every PIN this app holds does the queue move on.
        if outcome == .wrongPIN, var attempt, attempt.index + 1 < attempt.candidates.count {
            attempt.index += 1
            self.attempt = attempt
            reaching?.anyRefused = true
            debugLog?.record(.login, "That PIN was refused; presenting the next one")
            letGoOfTheLink(id, because: "a refused PIN, before the next one is presented")
            connectToTheAttempt()
            return
        }
        giveUpOnThisDevice(outcome)
    }

    /// This device is not the one, so let the link go and try the next.
    ///
    /// **Nothing is reported here, and that is `BluetoothRadio`'s rule rather than an omission.** A reach is not
    /// over because one candidate refused: the PIN is what identifies this app's cube, so a refusal answers "is
    /// this one mine?" with no. Telling the reconnect loop about each one would have it offer manual mode on the
    /// first colleague's cube that answered. Only `endReach` reports, and only once.
    private func giveUpOnThisDevice(_ outcome: DeviceLoginOutcome) {
        guard let attempt else { return }
        let id = attempt.id
        self.attempt = nil
        if outcome == .wrongPIN { reaching?.anyRefused = true }
        letGoOfTheLink(id, because: "the device was not this app's cube")
        guard reaching != nil else { return }
        tryNextCandidate()
    }

    /// The reach is over, one way or the other, and this is the one place it is reported.
    ///
    /// **A reach with no remembered identifier still reports**, which is why the fallback is a fresh `UUID` rather
    /// than silence: pairing is a reach for a cube this app has never met, and whatever asked for it is waiting to
    /// hear. `BluetoothRadio` does the same and for the same reason. Nothing downstream reads the identifier when
    /// the outcome is not `loggedIn`.
    private func endReach(reporting outcome: DeviceLoginOutcome, because reason: String) {
        let id = reaching?.preferred ?? UUID()
        debugLog?.record(.login, "The reach ended: \(reason)")
        closeTheScan()
        reaching = nil
        attempt = nil
        onLoginEnded?(id, outcome)
    }

    private func letGoOfTheLink(_ id: UUID, because reason: String) {
        login = nil
        try? link.disconnect(id)
        debugLog?.record(.login, "Let go of the link: \(reason)")
    }

    // MARK: - keeping the link, and noticing when it goes

    private func watchTheLink() {
        linkPoll?.cancel()
        linkPoll = scheduler.wake(in: Self.linkPollSeconds, repeating: true) { [weak self] in
            self?.readWhetherTheLinkIsStillUp()
        }
    }

    private func readWhetherTheLinkIsStillUp() {
        guard let id = connectedDevice else { return }
        // A tree that cannot be read is a bus problem rather than a cube leaving, and reporting a drop for it would
        // have the reconnect loop chasing a cube that never went anywhere.
        guard let device = try? link.device(id) else { return }
        guard !device.isConnected else { return }
        dropTheLink(id, because: "the cube stopped answering")
    }

    private func dropTheLink(_ id: UUID, because reason: String) {
        linkPoll?.cancel()
        linkPoll = nil
        connectedDevice = nil
        login = nil
        // **The three live readings go with the link**, which is what makes them not-table-values in practice
        // rather than only in the comment: a face, a charge and a lock state are claims about a cube that is
        // answering, and holding them past the link would have the menu bar drawing a cube nobody can hear.
        cubeFace = nil
        batteryPercent = nil
        cubeStatus = nil
        debugLog?.record(.status, "The link went: \(reason)")
        onLinkEnded?(id)
        onConnectionDropped?(id)
    }

    /// Gives the cube back, which is what a quit does with it.
    func disconnect(because reason: String) {
        guard let id = connectedDevice else { return }
        try? link.disconnect(id)
        dropTheLink(id, because: reason)
    }

    // MARK: - asking the cube things

    /// Sends one command to the connected cube, and reports whether it took the write.
    ///
    /// `false` with no cube connected, rather than nothing at all: a caller waiting on a completion that never
    /// comes is the failure mode that hangs a quit, and "there was no device" is a perfectly good answer.
    func send(_ command: Data, _ reported: @escaping (Bool) -> Void) {
        guard connectedDevice != nil, let login else {
            debugLog?.record(.command, "Asked to send a command with no cube connected")
            reported(false)
            return
        }
        login.send(command, then: reported)
    }

    func askStatus(_ answered: @escaping (DeviceCommandRules.Status?) -> Void = { _ in }) {
        guard connectedDevice != nil, let login else {
            answered(nil)
            return
        }
        login.askStatus(then: answered)
    }

    func readLastEvent(_ answered: @escaping (DeviceEventSegment?) -> Void) {
        guard connectedDevice != nil, let login else {
            answered(nil)
            return
        }
        login.readLastEvent(then: answered)
    }

    func fetchHistory(from eventNumber: Int, _ answered: @escaping ([DeviceEventSegment]) -> Void) {
        guard connectedDevice != nil, let login else {
            answered([])
            return
        }
        login.fetchHistory(from: eventNumber, then: answered)
    }

    /// What this app knows about a device it has seen, or a placeholder for one it has not.
    func device(_ id: UUID) -> ScannedDevice {
        found.first { $0.id == id }
            ?? ScannedDevice(
                id: id,
                peripheralName: nil,
                advertisedName: nil,
                advertisesTimeFlipService: false
            )
    }

    // MARK: - filing what the cube reports

    /// Files one reading off the cube, and says so only if it changed what is being shown.
    ///
    /// The judgement is `BatteryRules.shown`'s: this hardware reports a charge that wavers across one percent all
    /// day, so the figure follows the lower of the two until a reading genuinely climbs past it. Every reading,
    /// absorbed or not, is already in the trace as `ble-rx`; a `battery` row means the answer moved.
    private func received(batteryLevel raw: Int, from id: UUID) {
        let shown = BatteryRules.shown(batteryPercent, reading: raw)
        guard shown != batteryPercent else { return }
        batteryPercent = shown
        debugLog?.record(
            .battery,
            "Charge \(shown.map(String.init) ?? "?")%"
                + (raw == shown ? "" : " (the cube said \(raw)%)")
        )
        onBatteryLevel?(id, shown)
    }

    /// Files the face the cube is resting on, and says so only if it moved.
    ///
    /// No rule absorbing anything, unlike the charge beside it: a face is one of twelve discrete answers rather
    /// than a noisy measurement. What this does guard against is the read taken when a link comes up naming the
    /// face already on show, which is the ordinary case for a cube nobody has touched since the last connection.
    private func received(face: Int, from id: UUID) {
        guard face != cubeFace else { return }
        cubeFace = face
        debugLog?.record(.face, "Face \(face) is up")
        onFace?(id, face)
    }

    /// Files what the cube says about its own condition.
    private func received(status: DeviceCommandRules.Status, from id: UUID) {
        guard status != cubeStatus else { return }
        cubeStatus = status
        debugLog?.record(
            .command,
            "The cube is \(status.isLocked ? "locked" : "unlocked") and \(status.isPaused ? "paused" : "running")"
                // Said only when it is set: `0x10` carries the delay on every answer, and a cube told to stop
                // itself after five minutes looks exactly like one that has not been until it stops. A delay of
                // zero is the ordinary state and would be noise on every status.
                + (status.autoPauseMinutes > 0 ? ", pausing itself after \(status.autoPauseMinutes)m" : "")
        )
        onCubeStatus?(id, status)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as BlueZRadio.Failure:
            switch failure {
            case .noAdapter: return "there is no Bluetooth adapter"
            case let .notFound(address): return "\(address) is not a device BlueZ knows"
            case let .refused(message): return message
            }
        case let failure as BlueZGatt.Failure:
            switch failure {
            case let .noSuchCharacteristic(uuid): return "there is no characteristic \(uuid)"
            case let .refused(message): return message
            }
        default: return "\(error)"
        }
    }
}

/// What `BlueZCubeRadio` needs of BlueZ, and the seam its tests take the place of.
///
/// **Addressed by `UUID` rather than by address or path**, because that is what the app is written in and
/// `BlueZAddress` makes the mapping reversible in both directions. The one exception is `gatt(for:)`, which takes
/// the device record it was just handed: the GATT adapter is addressed by object path, and the record is where the
/// path came from.
@MainActor
package protocol BlueZLink: AnyObject {
    /// Turns the adapter on if it is off, and answers whether it is on now.
    func powerOn() throws -> Bool
    func startDiscovery() throws
    func stopDiscovery() throws
    /// Everything BlueZ knows, as the values `DeviceScanRules` decides about.
    func scannedDevices() throws -> [ScannedDevice]
    /// What BlueZ currently says about one device, or `nil` if it has never heard of it.
    func device(_ id: UUID) throws -> BlueZObjectTree.Device?
    /// Asks for a link. **Answers as soon as BlueZ has taken the request**: whether the services resolved is a
    /// separate question, asked of `device(_:)` afterwards.
    func connect(_ id: UUID) throws
    func disconnect(_ id: UUID) throws
    /// A GATT table for a device whose services BlueZ has resolved.
    func gatt(for device: BlueZObjectTree.Device) -> CubeGatt
}

/// The real one: `BlueZRadio` and the GATT adapter, with the UUID-to-address mapping in between.
@MainActor
package final class BlueZBusLink: BlueZLink {
    private let bus: SystemBus
    private let radio: BlueZRadio
    private let scheduler: Scheduler
    private let debugLog: DebugLog?

    package init(bus: SystemBus, scheduler: Scheduler, debugLog: DebugLog?) {
        self.bus = bus
        radio = BlueZRadio(bus: bus)
        self.scheduler = scheduler
        self.debugLog = debugLog
    }

    package func powerOn() throws -> Bool { try radio.powerOn() }
    package func startDiscovery() throws { try radio.startDiscovery() }
    package func stopDiscovery() throws { try radio.stopDiscovery() }
    package func scannedDevices() throws -> [ScannedDevice] { try radio.scannedDevices() }

    package func device(_ id: UUID) throws -> BlueZObjectTree.Device? {
        guard let address = BlueZAddress.address(fromIdentifier: id) else { return nil }
        return try radio.tree().device(withAddress: address)
    }

    /// **`BlueZRadio.connect` is not used here, and this is the difference.** That method waits for the services to
    /// resolve by sleeping the thread in a loop, which is exactly right for a probe script and exactly wrong for an
    /// app whose main loop draws a menu bar: twenty seconds of `Thread.sleep` is twenty seconds of a frozen panel.
    /// `BlueZCubeRadio` waits on its own clock instead, so this only has to ask.
    ///
    /// **The `Connect` call itself still blocks**, for as long as BlueZ takes to answer it, and that is a real cost
    /// rather than a hidden one: it is a single round trip in the ordinary case and the D-Bus timeout in the worst.
    /// Making it asynchronous means matching replies by serial inside `SystemBus`, which is worth doing and is not
    /// what this item is.
    package func connect(_ id: UUID) throws {
        guard let address = BlueZAddress.address(fromIdentifier: id) else {
            throw BlueZRadio.Failure.notFound(id.uuidString)
        }
        guard let device = try radio.tree().device(withAddress: address) else {
            throw BlueZRadio.Failure.notFound(address)
        }
        guard !device.isConnected else { return }
        try bus.call(
            destination: "org.bluez", path: device.path,
            interface: BlueZObjectTree.deviceInterface, method: "Connect",
            timeoutMilliseconds: 30_000
        )
    }

    package func disconnect(_ id: UUID) throws {
        guard let address = BlueZAddress.address(fromIdentifier: id) else { return }
        try radio.disconnect(address: address)
    }

    package func gatt(for device: BlueZObjectTree.Device) -> CubeGatt {
        BlueZCubeGatt(
            devicePath: device.path,
            transport: BlueZBusTransport(bus: bus, radio: radio),
            scheduler: scheduler,
            debugLog: debugLog
        )
    }
}
#endif

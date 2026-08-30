import CoreBluetooth
import Foundation

/// Why a scan is not running, in the words the tab shows.
///
/// Separate from "found nothing" on purpose: a radio that is off, or that the user has refused this app, produces an
/// empty list exactly like a room with no cube in it, and an empty list is the one thing all three states have in
/// common. Saying which is the difference between somebody turning Bluetooth on and somebody buying a new cube.
enum ScanUnavailable: Equatable {
    case bluetoothOff
    case unauthorised
    case unsupported

    var message: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off. Turn it on to look for a TimeFlip."
        case .unauthorised: return "Facet is not allowed to use Bluetooth. Grant it in System Settings > Privacy & Security."
        case .unsupported: return "This Mac has no Bluetooth radio that Facet can use."
        }
    }
}

/// The radio, and nothing else.
///
/// **It decides nothing.** Every judgement about an advertisement belongs to `DeviceScanRules` and every judgement
/// about a PIN to `DeviceLoginRules`, both of which work on values and so are testable with no hardware; this turns
/// CoreBluetooth's callbacks into those values, keeps the list, and drives the sequence. That is the same split as
/// `DailyLimitEnforcement` and `DailyLimitWatch`, and for the same reason: the part worth testing must not be the
/// part that needs a device on the desk. Sequencing is not deciding -- which PIN to try, and what the answer to it
/// means, are both asked of the rules.
///
/// **It was `BluetoothScanner`, and the rename is the honest one.** Scanning and connecting cannot be two objects:
/// CoreBluetooth will only connect a peripheral through the very `CBCentralManager` that discovered it, so one owner
/// of the manager is not a design preference but the framework's rule. The class doc always did say "the radio".
///
/// **Nothing here is written to a table, and that is not a breach of the first rule in `CLAUDE.md`.** A scan result is
/// not a fact about the user's setup, it is what a radio heard in the last few seconds: it goes stale by itself, it is
/// gone when the window closes, and a stored copy would be a list of devices that were in the room once. A live
/// connection is the same kind of thing one step further on. What *is* durable about pairing already has rows
/// (`paired`, `device_uuid`, `device_name`) and this writes none of them, because reaching a cube is not pairing with
/// it -- `paired` is described in `database/011_setting.sql` as surviving every drop and every refusal, which is only
/// coherent if connecting never touches it. The two names the filter needs are read from the table when a scan starts,
/// at the point of use, and not held between scans.
@MainActor
final class BluetoothRadio: NSObject {
    /// Called as the list changes, already ordered. The whole list rather than each arrival, so the tab redraws from
    /// one answer instead of accumulating its own copy.
    var onDevicesChanged: (([ScannedDevice]) -> Void)?

    /// Called when scanning starts or stops, including when it stops itself because the radio went away.
    var onScanningChanged: ((Bool) -> Void)?

    /// Called when a scan cannot run, or `nil` when the reason has cleared.
    var onUnavailable: ((ScanUnavailable?) -> Void)?

    /// Called when an attempt to reach a device starts, and again when it ends. The two are separate because the
    /// first is the only thing that can be said for the several seconds in between, and a control that reports
    /// nothing until it succeeds is one somebody presses twice.
    var onLoginBegan: ((UUID) -> Void)?
    var onLoginEnded: ((UUID, DeviceLoginOutcome) -> Void)?

    /// Called when a connection this app was keeping goes away on its own: the cube out of range, switched off, or
    /// its batteries out. Not called for a disconnect this app asked for.
    var onConnectionDropped: ((UUID) -> Void)?

    /// Called whenever a link ends, **however it ended**: the cube going away, the window closing, another device
    /// being chosen, a reset, a forget.
    ///
    /// **Not the same as `onConnectionDropped`**, which reports only the involuntary kind and is what the Device tab
    /// listens to. This one fires for every ending, because whoever is holding something perishable needs to let go
    /// of it whether the parting was the cube's decision or the app's. It is fired from `connectedDevice`'s `didSet`,
    /// beside the charge, the face and the cube's status being let go of for exactly the same reason.
    var onLinkEnded: ((UUID) -> Void)?

    /// Called with a cube's new PIN, once the cube has proved it took it by logging in with it again.
    ///
    /// **Whoever handles this is the only thing standing between the app and a cube it cannot open**, so it fires
    /// before the outcome is reported and it fires from the exchange itself rather than from a summary afterwards.
    /// Where the PIN is written down is not the radio's business (`DeveloperConfigFile`), for the same reason the
    /// candidates are handed in rather than worked out here.
    var onPINChanged: ((String) -> Void)?

    /// Called when the charge to show for a device changes, with the figure or `nil` once there is no live reading.
    ///
    /// **Not called per notification.** The cube reports its level every time it wavers between two adjacent
    /// percentages, thousands of times a day, and `BatteryRules.shown` absorbs that: this fires when the answer moves,
    /// which is what anything drawing it or warning about it actually cares about. Every raw value is still in the
    /// trace.
    var onBatteryLevel: ((UUID, Int?) -> Void)?

    /// Called when the face a device is resting on changes, with the face or `nil` once there is no live reading.
    ///
    /// **Called per change, not per arrival**, matching `onBatteryLevel`: a cube left alone re-reports nothing, but
    /// the read taken when a link comes up can name the face the app is already showing, and a redraw for an answer
    /// that did not move is a redraw nobody asked for. Every raw value is still in the trace.
    var onFace: ((UUID, Int?) -> Void)?

    /// Called when the cube reports what it is called, a second or two into a connection.
    ///
    /// **The only confirmation a rename gets**, and the only way a rename made in somebody else's app is ever noticed:
    /// `0x15` has no answer of its own, and macOS re-reads the GAP name only on connecting. See
    /// `DeviceLogin.nameReported` for the measurements behind both halves.
    ///
    /// **Every arrival, not only the changes**, unlike the charge and the face. There is roughly one per connection,
    /// and what to do about a name that has not moved is the recorder's question (`DevicePairingRecorder.recordName`)
    /// rather than a reason to drop the report here.
    var onDeviceName: ((UUID, String) -> Void)?

    /// Called when what the cube says about its own state changes, or `nil` once there is no cube to say.
    ///
    /// **Only ever an answer to a question this app asked**, unlike the charge and the face: the cube pushes nothing
    /// when a double tap pauses it, when auto-pause fires, or when the vendor's app locks it. So this fires on
    /// connecting and after each command the app reads back, and at no other time.
    var onCubeStatus: ((UUID, DeviceCommandRules.Status?) -> Void)?

    /// Called with what the cube says about itself: what it wants pushed back, and whether its hardware is working.
    ///
    /// **Every arrival, not only the changes**, unlike the charge and the face. There are few of them, each one is
    /// either a request or a fault, and a repeat is the cube saying it is still waiting.
    var onSystemState: ((UUID, DeviceSystemStateRules.State) -> Void)?

    /// Told when the link is all the way up: every characteristic found, every notification subscribed to, and the
    /// cube able to answer a question. **The mirror of `onConnectionDropped`**, and the pair is the point -- the app
    /// has had a way to hear that a cube went since there were cubes, and nothing but a login *outcome* to hear that
    /// one arrived.
    ///
    /// **Not `onLoginEnded`, which is a different moment.** That one fires when the PIN is accepted, several round
    /// trips before the listening phase has discovered anything: a fetch made then finds no history characteristic,
    /// because there is not one yet. This is the first moment the cube can actually be asked.
    var onCubeReady: ((UUID) -> Void)?

    /// The cube has answered everything the login asks it, so the command channel is free for somebody else.
    ///
    /// **What to hang a command on, where `onCubeReady` is what to hang a question on.** The login writes to the
    /// command characteristic after `ready` -- the `0x17` read and the `0x10` behind it -- and the first of those
    /// does not set `isCommandInFlight`, so a command sent off `onCubeReady` writes over a question already out. See
    /// `DeviceLogin.settled`.
    var onCubeSettled: ((UUID) -> Void)?

    /// Called with what a cube says it is, once the Device Information reads that follow a login have come back.
    ///
    /// **Separate from `onLoginEnded` rather than carried on it**, because it arrives afterwards and may not arrive at
    /// all: a cube that answers none of these is still a cube this app logged in to and paired with, and folding the
    /// two together would make an optional read into something a pairing waits on.
    var onDeviceInfo: ((UUID, DeviceInfo) -> Void)?

    /// How long a scan runs before stopping itself.
    ///
    /// **A cube that is awake answers in about a second, and that is measured rather than assumed.** Across eight
    /// scans that found one (`logs/testlog.sqlite`, runs 29 and 33): fastest 0.33s, median 0.94s, slowest 2.12s. Ten
    /// seconds is roughly five times the worst of those, which leaves room for a slow one without leaving somebody
    /// watching a list that was never going to grow.
    ///
    /// **Waiting longer does not find a sleeping cube, it only looks like it might.** A cube that is not awake does
    /// not advertise at all, so it is not slow to answer -- it never answers, and no timeout reaches it. Two of the
    /// ten scans recorded found nothing for exactly that reason, and each was followed seconds later by one that
    /// found the cube immediately, because somebody had flipped it in between. Thirty seconds spent proving that is
    /// twenty-eight seconds of somebody wondering whether the app is broken.
    ///
    /// What the bound is really for is the other end: a scan with no timeout runs until somebody presses the button
    /// again, and the radio then stays listening for the rest of the session with nothing on screen saying so. It
    /// also lets the status line say "no devices found" and mean it, instead of "looking" for ever.
    static let timeoutSeconds: TimeInterval = 10

    /// How long a connect is given before it is called unreachable.
    ///
    /// **`CBCentralManager.connect` has no timeout of its own** and will sit there indefinitely waiting for a cube
    /// that is asleep or gone, so this is the only thing that ends it. Fifteen seconds against a measured worst case
    /// of 5.4 across 36 logged connects (`Archive/TimeFlipApp/TimeFlipConstants.swift`), which leaves room for a slow
    /// one without leaving somebody watching a button that will never come back.
    static let connectTimeoutSeconds: TimeInterval = 15

    /// The pause between a refused PIN and the next attempt.
    ///
    /// **Copied from the archive as it stands, and it is worth keeping verbatim.** A refused login drops the link on
    /// its way out, and an immediate reconnect to the same peripheral races that teardown and comes back as a failure
    /// before anything is sent -- which reads as "could not reach it" and abandons the candidate that would have
    /// worked. That is not reasoning, it is what happened on 2026-08-10: `000000` refused, no second login attempt in
    /// the log at all, and a cube on a rotated PIN left unreachable.
    static let settleSeconds: TimeInterval = 1

    private let debugLog: DebugLog?
    private var central: CBCentralManager?
    private var found: [UUID: ScannedDevice] = [:]
    private var timeout: Timer?

    /// The peripherals behind the values in `found`.
    ///
    /// **Held because CoreBluetooth requires it**: a `CBPeripheral` nobody retains is deallocated, and connecting to
    /// one needs the object the scan produced rather than its identifier. Cleared with the list at the start of each
    /// scan, except for one that is currently connected -- dropping that would sever a live link to tidy up a list.
    private var peripherals: [UUID: CBPeripheral] = [:]

    /// How many devices the scan now running has listed. What the tab's status line reports once it stops.
    var deviceCount: Int { found.count }

    /// What the filter is matching against for the scan now running. Held only for the length of a scan, which is the
    /// span of the question it answers: the next scan reads the table again.
    private var remembered: String?
    private var previouslyKnown: String?
    private var isFiltering = true

    private(set) var isScanning = false

    /// Whether anybody is still waiting for a scan. Not the same question as `isScanning`, and the gap between them
    /// is where the radio was being used by nobody.
    ///
    /// **Building the manager does not start a scan**, so between `start` and the delegate's first callback there is a
    /// request in flight with nothing to show for it. `centralManagerDidUpdateState` picks it up on `.poweredOn`, and
    /// that is deliberate: somebody who presses Scan with Bluetooth off and then switches it on gets the scan they
    /// asked for. But there was nothing recording whether they were *still* asking, so the pickup fired for requests
    /// that had already been abandoned.
    ///
    /// Measured on hardware 2026-08-19. A paired launch with Bluetooth off reaches for its cube, the manager comes up
    /// powered off, the reach is reported unreachable and the offer of manual mode is taken -- and then switching
    /// Bluetooth back on **forty minutes later** started a ten-second scan nobody had asked for, in an app that had
    /// been told to stop looking. Nothing connected, because the reach target was long gone, so the only trace was
    /// four rows in the log.
    private var isScanWanted = false

    /// One run at reaching a device: which one, which PINs are left to try on it, and what to leave it on.
    private struct Attempt {
        let id: UUID
        var remaining: [String]
        var presenting: String
        /// Carried across the reconnect between candidates: which PIN got the app in has no bearing on what the cube
        /// should be left on.
        let rotatingTo: String?
    }

    /// A reset waiting to be proved: which cube, and who to tell.
    ///
    /// **While this is set the radio is in a different conversation**, and the ordinary connect callbacks are
    /// suppressed for that cube: a login here is evidence about a wipe rather than a device being reached, so
    /// `onLoginBegan`, `onLoginEnded` and `onConnectionDropped` would all be reporting the wrong story to a tab that
    /// is already showing "Resetting".
    private struct ResetConfirmation {
        let id: UUID
        let reported: (FactoryResetOutcome) -> Void
    }

    /// How long a cube is given to come back on the vendor PIN before the reset is called unconfirmed.
    ///
    /// The archive's `factoryResetConfirmTimeout`, copied: erasing flash and rebooting is not quick, and the number
    /// was arrived at against real hardware.
    static let resetConfirmSeconds: TimeInterval = 120

    /// The gap between attempts to meet the cube again after a reset.
    ///
    /// Longer than `settleSeconds`, which exists only to let a refused link finish coming down: this one is waiting on
    /// a device that is erasing its flash and restarting, so the first attempt is deliberately not immediate. Each
    /// failed attempt costs `connectTimeoutSeconds` on top, which puts roughly six tries inside the window.
    static let resetRetrySeconds: TimeInterval = 3

    private var resetConfirmation: ResetConfirmation?
    private var resetDeadline: Timer?

    private var attempt: Attempt?
    private var connectTimeout: Timer?
    private var settle: Timer?
    /// Set while a disconnect is this app's doing, so the delegate can tell one apart from a cube that went away.
    private var isDisconnectingDeliberately = false

    /// The conversation with the connected peripheral, kept for as long as the connection is.
    ///
    /// **`CBPeripheral.delegate` is weak**, so this reference is what keeps the login from being deallocated mid
    /// exchange -- and afterwards it is what keeps every byte the cube sends unasked reaching the trace.
    private var login: DeviceLogin?

    /// The device this app is currently logged in to, or `nil`.
    ///
    /// **The charge and the face go with it**, in one place rather than at each of the several ways a link ends: the
    /// window closing, another device being chosen, a reset, and the cube simply going away all pass through here, and
    /// either of them outliving that would be a reading from a device nobody can hear.
    private(set) var connectedDevice: UUID? {
        didSet {
            guard oldValue != connectedDevice, let gone = oldValue else { return }
            // Said out loud, because the alternative is a figure that simply stops moving. A charge nobody can
            // confirm any more and a charge that has not changed look identical in a log otherwise, and the whole
            // point of the row above is that it appears only when the answer moves.
            if batteryPercent != nil { debugLog?.record(.battery, "The charge goes with the link") }
            batteryPercent = nil
            onBatteryLevel?(gone, nil)
            // The same reasoning one line down, and it matters more: a face is drawn as a lit cube with a category on
            // it, so a face left behind by a dropped link is a picture of hardware claiming to be somewhere it may no
            // longer be.
            if cubeFace != nil { debugLog?.record(.face, "The face goes with the link") }
            cubeFace = nil
            onFace?(gone, nil)
            // And the same for what it said about itself. This one is the most obviously perishable of the three: the
            // app cannot ask a cube it cannot reach, and a remembered lock would leave the dropdown offering to undo
            // something on a device that is not there.
            cubeStatus = nil
            onCubeStatus?(gone, nil)
            // And the same for a conversation half finished. A history fetch waits on closures this radio holds, so a
            // link ending between the question and the answer leaves it in flight for ever -- and because only one
            // fetch runs at a time, that is the app quietly ingesting no history again until it is relaunched.
            // Measured on a device run, 2026-08-22.
            onLinkEnded?(gone)
        }
    }

    /// The charge to show for the connected cube, or `nil` when there is no live reading.
    ///
    /// **Not a table value and deliberately not one.** `deviceSettings()` says why the level has no row: a remembered
    /// percentage is a number that was true at a moment nobody can name. It lives here for as long as the connection
    /// it describes, which is the same standing the scan list and `connectedDevice` have (see this class's note on
    /// why none of that is a breach of the database rule), and whoever draws it asks for it then.
    ///
    /// **What is held is the *shown* figure, not the last byte received.** `BatteryRules.shown` needs the figure on
    /// show to judge the next reading against, so this is both the answer and the state the rule works from -- one
    /// value, not a reading kept beside a rendering of it.
    private(set) var batteryPercent: Int?

    /// The face the connected cube is resting on, or `nil` when there is no live reading.
    ///
    /// **Not a table value, for the same reason the charge is not one.** Which way up a cube is lying is a fact about
    /// this minute, and a remembered face is a claim about hardware nobody can check. It lives for as long as the
    /// connection that reported it, and whoever draws it asks for it then.
    ///
    /// **What the app does with a face it has never seen before is not decided here.** This is the cube's answer to
    /// "which way up am I", and nothing more: turning a flip into recorded time is `device_event`'s question and is
    /// not built.
    private(set) var cubeFace: Int?

    /// What the cube last said about being locked, being paused, and its auto-pause delay -- `nil` when it has not
    /// been asked, or when there is no cube.
    ///
    /// **Held rather than asked for on demand, and that is forced rather than chosen.** Asking is a round trip, and
    /// the thing that needs the answer is a menu item's title at the instant the menu opens. So it is read when the
    /// link comes up and refreshed by the read-back of every command the app sends, which covers every way the app
    /// itself can change it.
    ///
    /// **What it cannot cover is the cube being changed by something else**: a double tap pauses it, auto-pause
    /// pauses it, and the vendor's app can do either. The `isPaused` here is therefore only as fresh as the last
    /// answer, and nothing draws it. `cubeLockState` is the one the dropdown reads, and lock has no such back door -- the
    /// cube offers no gesture that locks itself.
    private(set) var cubeStatus: DeviceCommandRules.Status?

    init(debugLog: DebugLog?) {
        self.debugLog = debugLog
        super.init()
    }

    // MARK: - looking

    /// Starts looking.
    ///
    /// **The manager is made here rather than at launch**, so an app nobody has asked to scan never touches the radio
    /// and never provokes the system's Bluetooth permission prompt. `centralManagerDidUpdateState` is what actually
    /// begins the scan, because a manager is not usable the instant it is created: its state arrives asynchronously,
    /// and scanning before `.poweredOn` is a call that silently does nothing.
    ///
    /// - Parameters:
    ///   - filterToTimeFlip: what the **All Devices** box turns off.
    ///   - remembered: `device_name.name`, read from the table by the caller at this moment.
    ///   - previouslyKnown: `device_name.previous_name`, likewise.
    /// Forgets every device the last scan turned up, so the next reach has to go and look again.
    ///
    /// **What Retry means.** Somebody pressing it is saying the app's answer was wrong and to try properly, so
    /// reusing what the failed attempt already had would be answering the same question with the same stale material.
    /// Clearing the list is what turns the next `reach` down the scanning path, since the shortcut there is gated on
    /// having a peripheral in hand.
    ///
    /// **The connected cube is kept**, exactly as `start` keeps it: a live link is not something a scan found, and
    /// dropping its handle would be letting go of a connection nobody asked to end.
    func forgetWhatWasFound() {
        found = [:]
        peripherals = peripherals.filter { $0.key == connectedDevice }
        onDevicesChanged?([])
        debugLog?.record(.scan, "Forgot what the last scan found, so the next reach has to look again")
    }

    func start(filterToTimeFlip: Bool, remembered: String?, previouslyKnown: String?) {
        isScanWanted = true
        self.isFiltering = filterToTimeFlip
        self.remembered = remembered
        self.previouslyKnown = previouslyKnown
        // A fresh list per scan: a device that has since been switched off should leave the list, and the only
        // honest way to know it has gone is to stop claiming to have seen it.
        found = [:]
        peripherals = peripherals.filter { $0.key == connectedDevice }
        onDevicesChanged?([])
        debugLog?.record(
            .scan,
            "Scan requested, \(filterToTimeFlip ? "TimeFlip only" : "all devices")"
                + ", remembered \(remembered ?? ""), previously \(previouslyKnown ?? "")"
        )

        if central == nil {
            // **Said out loud, because the gap it opens is otherwise silent.** Building the manager does not start a
            // scan: the state arrives on the delegate and `beginScanIfReady` runs there. That is usually immediate,
            // but the first time this app ever asks for the radio it is however long somebody takes to answer the
            // system's Bluetooth prompt -- once, on one machine, and never again once allowed. Without this row the
            // log jumps from "Scan requested" to nothing, and a button that has not changed looks broken rather than
            // waiting, which is exactly how run 24 read it.
            debugLog?.record(.scan, "Waiting for the radio: building the central manager")
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        beginScanIfReady()
    }

    func stop() {
        stop(because: "stopped")
    }

    /// Stops, saying why in the log. The reason is not shown to the user: what they see is the list and whether it
    /// is still growing, and "timed out" against a list with the cube in it would read as a failure.
    private func stop(because reason: String) {
        timeout?.invalidate()
        timeout = nil
        // **Withdrawn ahead of the guard, not inside it.** A stop can land while the manager is still powering up, when
        // there is no scan yet to stop -- pressing Scan with the radio off and pressing it again to cancel is exactly
        // that -- and leaving the want set would have the cancelled scan start whenever Bluetooth came back.
        isScanWanted = false
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        debugLog?.record(.scan, "Scan \(reason), \(found.count) device(s) listed")
        onScanningChanged?(false)
        // **The scan ending is where a reach starts asking, not where it gives up.** Every device with the name is
        // in hand at this moment and at no moment before it, so this is the first point at which they can be put in
        // the order they will be tried in. Running out of them is what ends a reach, and `tryNextCandidate` is where
        // that is noticed.
        //
        // **Only when nothing is being tried**, so the stop inside `connect` does not re-enter this. In practice that
        // guard never fires during a reach, because a reach connects to nothing until its scan is over: see
        // `beginTryingWhatWasFound` for why that ordering is the whole design rather than a detail of it.
        if reaching != nil, attempt == nil {
            beginTryingWhatWasFound()
        }
    }

    /// Puts every device the scan found into the order a reach will ask them in, and starts asking.
    ///
    /// **Collect, then try. This is the archive's shape, taken whole, and the reason is the bug it prevents.**
    /// `ApplicationDelegate.connectToPairedDevice` scanned its window out, built the list, and only then worked
    /// through it -- one sequence, one outcome at the end of it. The rebuild first tried each device as it was
    /// discovered instead, which reads as the faster answer and puts three things inside one another: a `connect`
    /// stops the scan, stopping the scan ends the reach, and ending the reach runs a modal dialog from inside the
    /// half-finished `connect`. Measured on 2026-08-23: the offer came up two seconds into a launch saying nothing
    /// answered, and the Retry made from inside that dialog was overwritten by the tail of the connect it had
    /// interrupted, leaving the app scanning for ten seconds and then silent for the rest of the launch.
    ///
    /// **Arriving first is not a reason to be tried first**, either, which is the other half of what the archive
    /// knew. Devices advertise in whatever order they happen to, so acting on the first one is how a colleague's
    /// cube gets asked and this app's own is never reached at all.
    private func beginTryingWhatWasFound() {
        guard reaching != nil else { return }
        let order = DeviceScanRules.reachOrder(
            Array(found.values),
            preferring: reaching!.preferred,
            remembered: remembered,
            previouslyKnown: previouslyKnown
        )
        reaching!.queue = order.filter { !reaching!.tried.contains($0) }
        debugLog?.record(.login, "\(reaching!.queue.count) device(s) to ask, in the order they will be asked")
        tryNextCandidate()
    }

    /// Starts the next queued candidate, if there is one and nothing else is in flight.
    ///
    /// **A short wait before each, which is measured rather than cautious.** Connecting to a peripheral while the
    /// previous attempt's teardown is still running fails in milliseconds and says nothing about the cube -- the
    /// archive measured it in 2026 and this rebuild measured it again at eight milliseconds (finding 8,
    /// `docs/timeflip2-firmware-observations.md`). Without the pause a queue of five cubes would refuse all five in
    /// under a tenth of a second and none of it would mean anything.
    private func tryNextCandidate() {
        guard reaching != nil, attempt == nil, resetConfirmation == nil else { return }
        guard !reaching!.queue.isEmpty else {
            // **The shortcut was wrong, so the shortcut is paid for.** The window was cut short because the
            // remembered identifier turned up, and that device has now refused this app's PIN -- so it was not this
            // app's cube, and the rest of the room has never been looked at. Saying nothing is here would be saying
            // it about a scan that stopped after one answer.
            if reaching!.windowWasCutShort {
                reaching!.windowWasCutShort = false
                debugLog?.record(.login, "The remembered device did not take the PIN, so looking at what else is there")
                start(filterToTimeFlip: true, remembered: remembered, previouslyKnown: previouslyKnown)
                return
            }
            endReach(because: "every device with the name has been tried")
            return
        }
        let id = reaching!.queue.removeFirst()
        reaching!.tried.insert(id)
        let candidates = reaching!.candidates
        let rotatingTo = reaching!.rotatingTo
        settleThenConnect = Timer(timeInterval: Self.settleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.reaching != nil, self.attempt == nil else { return }
                self.debugLog?.record(
                    .login,
                    "Trying \(id.uuidString), \(self.reaching!.queue.count) more with the name behind it"
                )
                self.connect(to: id, presenting: candidates, rotatingTo: rotatingTo)
            }
        }
        if let settleThenConnect { RunLoop.main.add(settleThenConnect, forMode: .common) }
    }

    /// Ends a reach that has run out of devices to ask, and says which of the two answers it is.
    ///
    /// **"None of them was ours" is not "nothing was there".** Both leave the app without its cube and they are
    /// different problems: one is a cube out of range, the other is cubes in range that this app cannot open. The
    /// dialog put to the user is the same either way (`CubeNotFoundAlert`), and the log line is not.
    private func endReach(because reason: String) {
        guard let target = reaching else { return }
        reaching = nil
        settleThenConnect?.invalidate()
        settleThenConnect = nil
        let outcome: DeviceLoginOutcome = target.anyRefused ? .wrongPIN : .unreachable
        debugLog?.record(
            .login,
            target.anyRefused
                ? "\(reason): \(target.tried.count) device(s) with the name, none took the PIN"
                : "\(reason): nothing with the name answered"
        )
        end(target.preferred ?? UUID(), outcome)
    }

    private func beginScanIfReady() {
        guard let central else { return }
        // **Nobody is waiting for this any more.** Reached when the radio comes back long after the request that built
        // the manager was abandoned -- see `isScanWanted`. Silent, because there is nothing to report about a scan that
        // is correctly not happening.
        guard isScanWanted else { return }
        guard central.state == .poweredOn else {
            report(unavailable(for: central.state))
            return
        }
        onUnavailable?(nil)
        // **No service filter, deliberately, even though the service UUID is known.** This hardware does not reliably
        // advertise it (measured by the archive's diagnostic scan, and the reason its own scan matched on names), so
        // asking CoreBluetooth for that service would find nothing at all. The filtering happens above, in
        // `DeviceScanRules`, where it can also match the names.
        //
        // `allowDuplicates` is left off: a second advertisement from a device already in the list tells this nothing
        // it does not know, and the callback fires many times a second per device.
        central.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
        // **The row that says the radio is actually listening**, as opposed to `Scan requested`, which says only that
        // somebody asked. The two are separated by however long the manager takes to power on, and the only other
        // evidence of the gap closing was `Bluetooth state:` -- which `centralManagerDidUpdateState` writes when the
        // state *changes*, so it appears on the first scan of a session and never again. From the second scan onwards
        // there was nothing at all between the request and the first advertisement, which is how `14-device-connect`
        // failed the first time it ran: it waited 60 seconds for a row that had already been written by `13`.
        debugLog?.record(.scan, "Scan started, listening for advertisements")
        // Armed here rather than in `start`, because `start` may only have built the manager: the clock should
        // measure the time the radio was actually listening, not the wait for it to power on.
        timeout?.invalidate()
        timeout = Timer(timeInterval: Self.timeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(because: "timed out after \(Int(Self.timeoutSeconds))s") }
        }
        // `.common`, so a scan still ends on time while a menu is being held open.
        if let timeout { RunLoop.main.add(timeout, forMode: .common) }
        onScanningChanged?(true)
    }

    private func unavailable(for state: CBManagerState) -> ScanUnavailable? {
        switch state {
        case .poweredOn: return nil
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .unauthorised
        case .unsupported: return .unsupported
        // `.resetting` and `.unknown` are both "ask again shortly": the delegate fires again when it settles, so
        // saying anything now would put a message on screen that a moment later is wrong.
        default: return nil
        }
    }

    private func report(_ reason: ScanUnavailable?) {
        if isScanning {
            isScanning = false
            onScanningChanged?(false)
        }
        guard let reason else {
            // `.resetting` and `.unknown`: ask again shortly. Nothing is ended here, because the delegate fires again
            // when the state settles and the reach is still perfectly good until it does.
            onUnavailable?(nil)
            return
        }
        debugLog?.record(.scan, "Scan unavailable: \(reason)")
        // **A reach that cannot even start is that cube being unreachable**, and saying so is what keeps the app
        // honest about it. Without this, Bluetooth being switched off at launch left `reaching` set for ever: no scan
        // to time out, so no outcome, so `isReachingForCube` stayed true and the reconnect loop stood down permanently --
        // no retry, no offer of manual mode, and nothing on screen saying the app had stopped. The three reasons that
        // get here are all settled states (off, unauthorised, unsupported) rather than "ask again shortly", which is
        // why ending on them does not race the radio coming up.
        if reaching != nil {
            // **The reach is over, so its scan is not wanted either.** This is the one that was missing: the request
            // outlived the thing that made it, and the radio coming back hours later ran it. A scan somebody pressed
            // Scan for is deliberately *not* withdrawn here -- it has no `reaching` target, and picking it up when the
            // radio returns is what they asked for.
            isScanWanted = false
            endReach(because: "cannot use the radio: \(reason)")
        }
        onUnavailable?(reason)
    }

    private func publish() {
        onDevicesChanged?(
            DeviceScanRules.ordered(Array(found.values), remembered: remembered, previouslyKnown: previouslyKnown)
        )
    }

    // MARK: - reaching one

    /// Connects to a listed device, presents PINs to it until one is accepted or they run out, and sets the PIN it
    /// should be left on.
    ///
    /// **The candidates and the new PIN are handed in rather than worked out here**, which keeps the rules about what
    /// to try and what to set in `DeviceLoginRules` where they can be tested without a cube. This drives the sequence
    /// and reports what came of it.
    ///
    /// **The scan stops first.** A radio doing both is slower at each, and the list is about to be acted on rather
    /// than added to.
    ///
    /// - Parameter rotatingTo: the PIN the cube should end up on, or `nil` to leave it on whichever one let the app
    ///   in. Only a developer build has one to give (`DeveloperMode.devicePIN`).
    func connect(to id: UUID, presenting candidates: [String], rotatingTo: String? = nil) {
        guard peripherals[id] != nil else {
            debugLog?.record(.login, "Asked to connect to \(id.uuidString), which is not a device this scan found")
            return
        }
        guard attempt == nil else {
            debugLog?.record(.login, "Already reaching a device; ignoring the request for \(id.uuidString)")
            return
        }
        guard let first = candidates.first else {
            debugLog?.record(.login, "No PIN to present to \(id.uuidString)")
            end(id, .wrongPIN)
            return
        }
        stop(because: "stopped: a device was chosen")
        // Anything already connected goes, before rather than after: two live links would leave the app holding a
        // cube nobody chose, and the one thing worse than not reaching a device is reaching the wrong one silently.
        disconnect(because: "another device was chosen")
        attempt = Attempt(
            id: id, remaining: Array(candidates.dropFirst()), presenting: first, rotatingTo: rotatingTo
        )
        onLoginBegan?(id)
        beginConnect()
    }

    /// Goes and finds a cube this app already knows, and logs in to it.
    ///
    /// **Reconnecting is a scan, and that is the whole reason this method exists.** CoreBluetooth will not hand back a
    /// peripheral by identifier: an object to connect to comes from a scan or from nowhere, so "reach the cube we are
    /// paired to" cannot be a connect. Getting this wrong has already cost this project once -- the device rename
    /// shipped with every test passing and left the cube unreachable on the next launch, because nothing in `swift test`
    /// scans (2026-08-01, the Device rename section of `docs/TODO-features-under-development.md`).
    ///
    /// **It scans the window out, then asks every device it found, in turn.** Not the first one to advertise, and not
    /// the one carrying `id`: neither identifier this app can see is unique to a cube (finding 8,
    /// `docs/timeflip2-firmware-observations.md`), so `id` orders the list rather than choosing from it, and what
    /// actually identifies this app's cube is the PIN it set on it. `beginTryingWhatWasFound` is where the order is
    /// made and what it cost to learn that the two steps must not overlap.
    ///
    /// **The target is admitted whatever it is called.** The filter is for the list a person reads, and a cube renamed
    /// out of band matches neither name in the table -- but an identifier is not a name, so `id` gets in regardless,
    /// which is the difference between a renamed cube being reachable and being lost.
    ///
    /// **It ends by itself, and reports once.** Running out of devices to ask is what says the cube is not there,
    /// reported through `onLoginEnded` as `.unreachable` when nothing answered and `.wrongPIN` when something did and
    /// would not open. A refusal along the way is reported to nobody: it is the answer to "is this one mine?", and
    /// telling the reconnect loop about it would have the app offer manual mode on the first stranger's cube in range.
    ///
    /// - Parameters:
    ///   - id: `device_uuid.uuid`, read from the table by the caller at this moment.
    ///   - candidates: the PINs to present, from `DeviceLoginRules.reconnectCandidates`.
    func reach(
        _ id: UUID,
        presenting candidates: [String],
        rotatingTo: String? = nil,
        remembered: String?,
        previouslyKnown: String?
    ) {
        guard attempt == nil, resetConfirmation == nil else {
            debugLog?.record(.login, "Already busy with a device; not reaching for \(id.uuidString)")
            return
        }
        guard connectedDevice != id else { return }
        // **Always a scan, and the identifier is only a preference within it.** This used to shortcut straight to a
        // known peripheral, which was right for a link that dropped and came back and wrong for everything else: after
        // a failed attempt the handle is one the teardown is still letting go of, and connecting to it fails in
        // milliseconds rather than saying anything about the cube (finding 8,
        // `docs/timeflip2-firmware-observations.md`). More importantly there may be several cubes in the room and
        // only one of them ours, and a shortcut to a remembered handle cannot find that out.
        debugLog?.record(
            .login,
            "Reaching for the paired cube: scanning, and every device with the name will be tried"
        )
        reaching = ReachTarget(preferred: id, candidates: candidates, rotatingTo: rotatingTo)
        start(filterToTimeFlip: true, remembered: remembered, previouslyKnown: previouslyKnown)
    }

    /// A run at getting back to this app's cube: which PINs to present, and every device still worth presenting them
    /// to. Cleared when one accepts, or when the scan ends with nothing left to try.
    ///
    /// **There is no "the" device here, and that is the point.** Neither identifier available to this app is unique to
    /// a cube: the one the device carries is the same on every TimeFlip, and the one CoreBluetooth hands out belongs
    /// to the Mac and can change (finding 8, `docs/timeflip2-firmware-observations.md`). So a reach cannot ask "is
    /// this the right identifier"; it asks "does this one take our PIN", which is the only question with a reliable
    /// answer -- the app set that PIN on the cube it paired with.
    ///
    /// It follows that **a refusal is not a failure**. It is the answer to "is this one mine?", and the queue moves
    /// on. Only running out of devices ends the reach. The archive reached the same conclusion and recorded what the
    /// alternative cost: connecting to whichever answered first meant "a colleague's cube advertising a moment sooner
    /// was enough to lock this user out of their own device".
    private struct ReachTarget {
        /// `device_uuid`, which is a **hint and never a gate**: worth trying first when it turns up, worth nothing
        /// when it does not.
        let preferred: UUID?
        let candidates: [String]
        let rotatingTo: String?
        /// Eligible devices seen this scan and not yet tried, in the order they will be tried.
        var queue: [UUID] = []
        /// Tried this reach, so a device advertising repeatedly is not tried twice in one pass. **Not remembered
        /// beyond it**: the next scan starts over, so a cube that refused for a passing reason is picked up again
        /// rather than needing a restart.
        var tried: Set<UUID> = []
        /// Whether anything refused, which is what tells "nothing was in range" from "none of them was ours".
        var anyRefused = false
        /// Whether the remembered identifier turning up may still cut the scan window short. False once it has, so
        /// the second look runs its full window: two scans is the most a reach ever does.
        var mayEndEarly = true
        /// Whether the window that just ended was cut short by that. If the shortcut turns out to have been wrong,
        /// this is what says there is a proper look still owed before the answer is "nothing is here".
        var windowWasCutShort = false
    }

    private var reaching: ReachTarget?

    /// The wait between one candidate and the next, on `settleSeconds` -- the same constant, and for the same reason
    /// it already existed: letting a refused link finish coming down before anything touches the radio again.
    private var settleThenConnect: Timer?

    /// Whether the radio is looking for a cube of its own accord, as opposed to for somebody watching the list.
    var isReachingForCube: Bool { reaching != nil || attempt != nil }

    /// Whether a reset is waiting on the cube to prove itself, which is what the tab shows instead of a connection.
    var isFactoryResetRunning: Bool { resetConfirmation != nil }

    /// Puts the connected cube back to how it left the factory, and reports only once the cube has **proved** it.
    ///
    /// **Sending `0xFF` is not the answer, and this is the archive's central insight about reset.** The command has no
    /// usable acknowledgement -- the cube reboots without writing a fresh command result, so the characteristic still
    /// holds the previous command's bytes (`DeviceLoginRules.factoryReset`) -- so a write that landed says only that
    /// the cube heard something. What proves the wipe took is the cube coming back **on the vendor PIN**: a device
    /// still holding this app's PIN has plainly not been erased. That is the same shape as setting a PIN, where the
    /// proof is a login with the new one rather than the command's own reply, and it is right for the same reason.
    ///
    /// The sequence, which is `ApplicationDelegate`'s and is kept whole:
    ///
    /// 1. Arm the confirmation window **before** sending, so the disconnect the reset causes is expected rather than
    ///    read as the cube going away.
    /// 2. Send `0xFF`. A write the cube refused ends it here, nothing having happened.
    /// 3. Wait for the link to drop, which is the cube rebooting.
    /// 4. Reach it again presenting **only** the vendor default, over and over until it answers or the window closes.
    ///    Only the default: the stored PIN would let an unwiped cube in and be mistaken for proof.
    /// 5. A login on the default is the confirmation. Report it, then let go -- **that login is deliberately not a
    ///    pairing**, which is the archive's rule: the cube is now a pristine unpaired device, and treating the proof
    ///    as a pairing would leave the app holding the very thing the user asked it to give up.
    /// Sends one command to the connected cube, and reports whether it took the write.
    ///
    /// **Nothing here decides what to send or what a refusal means.** The bytes are `DeviceCommandRules`' and the
    /// sequence is the caller's, which is the same split every other part of this class keeps: the radio owns the
    /// central manager and nothing else.
    ///
    /// `false` with no cube connected, rather than nothing at all. A caller waiting on a completion that never comes
    /// is the failure mode that hangs a quit, and "there was no device" is a perfectly good answer to give it.
    func send(_ command: Data, _ reported: @escaping (Bool) -> Void) {
        guard connectedDevice != nil, let login else {
            debugLog?.record(.command, "Asked to send a command with no cube connected")
            reported(false)
            return
        }
        login.send(command, then: reported)
    }

    /// Asks the cube what state it is in, so what the app holds is not older than it needs to be.
    ///
    /// **Because a cube pauses itself and does not say so.** A double tap stops its tracking, unconditionally and with
    /// no command to turn that off (`Archive/Tests/Methods.md` Method 22), and the vendor's own app can pause it too.
    /// Nothing arrives to announce either: `systemState` carries sync and hardware health, not pause. So the only way
    /// the app's answer stays true is by asking again, and the only honest moment to ask is one where the cube may
    /// have been handled.
    ///
    /// The answer is not returned. It goes where every other answer to this question goes -- `received(status:from:)`
    /// -- so there is one place that holds it and one row that says it moved.
    func askStatus() {
        guard connectedDevice != nil, let login else { return }
        login.askStatus { _ in }
    }

    /// Asks the cube which event it is on, and hands back that one frame.
    ///
    /// `nil` with no cube connected, which is a different answer from "the cube has no history": one means there was
    /// nobody to ask, and `DeviceHistoryRules.resumeFrom` leaves the stored position standing for it.
    func readLastEvent(_ answered: @escaping (DeviceEventSegment?) -> Void) {
        guard connectedDevice != nil, let login else {
            answered(nil)
            return
        }
        login.readLastEvent(then: answered)
    }

    /// Asks the cube for its history from `eventNumber` onwards.
    func fetchHistory(from eventNumber: Int, _ answered: @escaping ([DeviceEventSegment]) -> Void) {
        guard connectedDevice != nil, let login else {
            answered([])
            return
        }
        login.fetchHistory(from: eventNumber, then: answered)
    }

    func factoryReset(_ reported: @escaping (FactoryResetOutcome) -> Void) {
        guard let id = connectedDevice, let login else {
            debugLog?.record(.pair, "Asked to reset with no cube connected")
            reported(.notSent)
            return
        }
        // Armed first, for the reason above: the drop that follows is part of the reset.
        resetConfirmation = ResetConfirmation(id: id, reported: reported)
        resetDeadline?.invalidate()
        resetDeadline = Timer(timeInterval: Self.resetConfirmSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.debugLog?.record(
                    .pair,
                    "The cube never came back on the vendor PIN within \(Int(Self.resetConfirmSeconds))s,"
                        + " so the reset is not confirmed"
                )
                self?.endReset(.notConfirmed)
            }
        }
        if let resetDeadline { RunLoop.main.add(resetDeadline, forMode: .common) }

        login.factoryReset { [weak self] sent in
            guard let self else { return }
            guard sent else {
                self.debugLog?.record(.pair, "The cube would not take the reset command")
                self.endReset(.notSent)
                return
            }
            self.debugLog?.record(.pair, "Reset sent; letting go of the link so the cube can be met again")
            // **The link is dropped here rather than waited for, and that is a measured correction.** The archive
            // assumed the cube reboots and severs the connection, so this waited for `didDisconnectPeripheral` to
            // start the confirmation. On this firmware it does not: a reset on 2026-08-17 was acknowledged and the
            // link then stayed up for the whole 104 seconds somebody watched it, with no disconnect at all -- so
            // nothing was ever tried and a wipe that had actually happened went unconfirmed (finding 6 in
            // `docs/timeflip2-firmware-observations.md`). Dropping it here covers both firmwares: a cube that does
            // sever the link is handled by `didDisconnectPeripheral`, and one that does not is let go of anyway.
            self.disconnect(because: "the cube is being reset")
            self.retryResetConfirmation()
        }
    }

    /// Tries the vendor default on the rebooted cube, again and again until it answers or the window closes.
    ///
    /// **Only the vendor default is presented.** Offering the stored PIN as well would let a cube that ignored the
    /// command log in and be counted as proof, which is the one mistake this whole sequence exists to avoid.
    private func retryResetConfirmation() {
        guard resetConfirmation != nil else { return }
        settle?.invalidate()
        // **Which cube is read when the timer fires, not captured now.** A `ResetConfirmation` holds a closure and so
        // is not `Sendable`, which the compiler refuses to let across into a timer -- and re-reading is the better
        // answer anyway: if the window closed in the meantime there is nothing left to reach for.
        settle = Timer(timeInterval: Self.resetRetrySeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.resetConfirmation?.id else { return }
                self.debugLog?.record(.pair, "Trying the vendor PIN, to see whether the cube was really wiped")
                self.attempt = Attempt(
                    id: id, remaining: [], presenting: DeviceLoginRules.defaultPIN, rotatingTo: nil
                )
                self.beginConnect()
            }
        }
        if let settle { RunLoop.main.add(settle, forMode: .common) }
    }

    /// Ends the reset one way or the other, and says so exactly once.
    private func endReset(_ outcome: FactoryResetOutcome) {
        guard let confirmation = resetConfirmation else { return }
        resetConfirmation = nil
        resetDeadline?.invalidate()
        resetDeadline = nil
        settle?.invalidate()
        settle = nil
        connectTimeout?.invalidate()
        connectTimeout = nil
        attempt = nil
        debugLog?.record(.pair, "Reset: \(outcome)")
        // **Let go either way.** A confirmed reset leaves a pristine cube the app has been told to give up, and an
        // unconfirmed one leaves a device the app must not go on holding as though nothing had been asked.
        disconnect(because: "the reset is over")
        confirmation.reported(outcome)
    }

    /// Drops the connection, if there is one. Says nothing when there is nothing to drop: this is called on every
    /// window close and every tab change.
    func disconnect(because reason: String) {
        cancelAttempt()
        guard let id = connectedDevice, let peripheral = peripherals[id] else { return }
        debugLog?.record(.login, "Disconnecting from \(id.uuidString): \(reason)")
        isDisconnectingDeliberately = true
        connectedDevice = nil
        login = nil
        central?.cancelPeripheralConnection(peripheral)
    }

    /// Abandons an attempt in flight without reporting an outcome, for the two moments that are not the cube's doing:
    /// the window closing, and another device being chosen.
    private func cancelAttempt() {
        connectTimeout?.invalidate()
        connectTimeout = nil
        settle?.invalidate()
        settle = nil
        // A cube being looked for is abandoned along with one being connected to: both are this app going after a
        // device, and the two moments that call this -- the window closing, another device being chosen -- end either.
        // The wait before the next candidate goes with it: it guards on `reaching` when it fires, but a timer left
        // running for a reach nobody is having is a second thing to reason about for no gain.
        reaching = nil
        settleThenConnect?.invalidate()
        settleThenConnect = nil
        guard let attempt else { return }
        self.attempt = nil
        login = nil
        if let peripheral = peripherals[attempt.id], connectedDevice != attempt.id {
            isDisconnectingDeliberately = true
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func beginConnect() {
        guard let attempt else { return }
        guard let peripheral = peripherals[attempt.id], let central else {
            // **Ended out loud, never dropped.** A handle can go between an attempt being made and this running: the
            // settle between two PINs is a whole second, and anything that starts a scan in that second clears the
            // list. Returning quietly leaves `attempt` set for the life of the process, and every later reach then
            // refuses to begin with "already busy with a device" -- an app that has silently stopped looking for its
            // cube and will not start again until it is restarted. That is what 2026-08-23 cost: a Retry that scanned
            // for ten seconds, found the cube, and said nothing at all.
            debugLog?.record(.login, "Nothing left to connect to for \(attempt.id.uuidString)")
            end(attempt.id, .unreachable)
            return
        }
        debugLog?.record(
            .login,
            "Connecting to \(DeviceScanRules.label(for: found[attempt.id] ?? placeholder(attempt.id)))"
                + " (\(attempt.id.uuidString))"
        )
        isDisconnectingDeliberately = false
        central.connect(peripheral, options: nil)
        connectTimeout?.invalidate()
        connectTimeout = Timer(timeInterval: Self.connectTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let attempt = self.attempt else { return }
                self.debugLog?.record(.login, "No answer after \(Int(Self.connectTimeoutSeconds))s")
                self.end(attempt.id, .unreachable)
            }
        }
        if let connectTimeout { RunLoop.main.add(connectTimeout, forMode: .common) }
    }

    /// Presents the next PIN, once the one before it has been refused.
    private func retry() {
        guard var attempt, !attempt.remaining.isEmpty else { return }
        attempt.presenting = attempt.remaining.removeFirst()
        self.attempt = attempt
        login = nil
        // The link goes down between candidates rather than a second PIN being written over the first. The cube
        // forgets the password characteristic on disconnect and asks again on reconnect (protocol v4.3), so a fresh
        // connection is the state the exchange is specified in -- and the command result characteristic is left
        // holding the refusal, which finding 2 in `docs/timeflip2-firmware-observations.md` says is exactly the
        // circumstance where a stale value gets read as an answer.
        if let peripheral = peripherals[attempt.id] {
            isDisconnectingDeliberately = true
            central?.cancelPeripheralConnection(peripheral)
        }
        settle?.invalidate()
        settle = Timer(timeInterval: Self.settleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginConnect() }
        }
        if let settle { RunLoop.main.add(settle, forMode: .common) }
    }

    /// Ends the attempt, one way or the other, and says so once.
    ///
    /// **Every piece of state this radio holds is settled before `onLoginEnded` is called, and every caller returns
    /// the moment it comes back.** That is not tidiness, it is what makes the report safe to act on: the offer of
    /// manual mode is an `NSAlert.runModal`, so a listener can answer it, start a whole new reach and get a scan
    /// running -- all from inside this call. Anything left to do afterwards would be done to the new reach.
    ///
    /// Measured on 2026-08-23, when it was not so: a candidate was tried mid-scan, stopping the scan ended the reach,
    /// the reach reported from inside the half-finished `connect`, and the tail of that `connect` then overwrote the
    /// retry the dialog had just started. The app scanned for ten seconds, found the cube, and said nothing at all
    /// for the rest of the launch.
    private func end(_ id: UUID, _ outcome: DeviceLoginOutcome) {
        connectTimeout?.invalidate()
        connectTimeout = nil
        settle?.invalidate()
        settle = nil
        attempt = nil
        // **A reset confirmation is not a login anybody asked for**, so it reports through its own channel and none of
        // the connect callbacks fire. A cube that did not answer this time is not a failure either: it may still be
        // rebooting, and the window is what decides when to give up.
        if let confirmation = resetConfirmation, confirmation.id == id {
            guard outcome == .loggedIn else {
                debugLog?.record(.pair, "Not back yet (\(outcome)); trying again")
                retryResetConfirmation()
                return
            }
            debugLog?.record(.pair, "The cube let the app in on the vendor PIN, so the wipe took")
            endReset(.confirmed)
            return
        }
        debugLog?.record(.login, "\(id.uuidString): \(outcome)")
        // **A reach is not over because one candidate refused.** The PIN is what identifies this app's cube, so a
        // refusal answers "is this one mine?" with no, and the next device with the name gets asked. Only running out
        // of them ends it (`endReach`). Reported to nobody until then: telling the reconnect loop about each refusal
        // would have it offer manual mode on the first colleague's cube that answered.
        if reaching != nil, outcome != .loggedIn {
            if let peripheral = peripherals[id], connectedDevice != id {
                isDisconnectingDeliberately = true
                central?.cancelPeripheralConnection(peripheral)
                peripherals[id] = nil
            }
            if outcome == .wrongPIN { reaching!.anyRefused = true }
            tryNextCandidate()
            return
        }
        if outcome == .loggedIn, reaching != nil {
            debugLog?.record(.login, "That one took the PIN, so it is the cube this app is paired to")
            reaching = nil
            settleThenConnect?.invalidate()
            settleThenConnect = nil
        }
        if outcome != .loggedIn, let peripheral = peripherals[id], connectedDevice != id {
            isDisconnectingDeliberately = true
            central?.cancelPeripheralConnection(peripheral)
            // **And the handle goes with it, so the next reach scans rather than taking the shortcut in `reach`.**
            //
            // That shortcut exists for a link that dropped and a cube that came straight back, where the peripheral
            // is still good. It is not good here: the line above has just asked CoreBluetooth to tear this
            // connection down, and connecting to a handle mid-teardown fails instantly.
            //
            // Measured on hardware, 2026-08-23. A cube refused the PIN, somebody pressed Retry two seconds later,
            // and the whole attempt took **eight milliseconds**: "already known to this session", "Connecting",
            // "Disconnected unexpectedly", `unreachable`. So Retry never scanned, never waited the ten seconds it
            // looks like it is waiting, and the offer came back saying "nothing answered" about a cube sitting on
            // the desk that had answered a moment earlier. Forgetting the handle is what makes Retry mean what it
            // says: go and look again.
            peripherals[id] = nil
        }
        onLoginEnded?(id, outcome)
    }

    /// Files one reading off the cube, and says so only if it changed what is being shown.
    ///
    /// The judgement is `BatteryRules.shown`'s and the reasoning is there: this hardware reports a charge that
    /// wavers across one percent all day, so the figure follows the lower of the two until a reading genuinely
    /// climbs past it. Every reading, absorbed or not, is already in the trace as `ble-rx`; a `battery` row means
    /// the answer moved.
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
    /// No rule absorbing anything, unlike the charge beside it: a face is one of twelve discrete answers rather than a
    /// noisy measurement, and the cube has never been seen to repeat one unprompted. What this does guard against is
    /// the read taken when a link comes up naming the face already on show, which is the ordinary case for a cube
    /// nobody has touched since the last connection.
    private func received(face: Int, from id: UUID) {
        guard face != cubeFace else { return }
        cubeFace = face
        debugLog?.record(.face, "Face \(face) is up")
        onFace?(id, face)
    }

    /// Files what the cube says about its own condition.
    ///
    /// **Written down every time, and loudly when it is not "fine".** This is the one channel on which a cube reports
    /// that it has been put back to the factory or that its flash memory has failed, and a flash fault means it records
    /// no history at all -- which from the outside is indistinguishable from a cube that has simply been reset. Both of
    /// those are hours of confusion if they are not in the log, so the row goes in whether or not anything acts on it.
    private func received(systemState state: DeviceSystemStateRules.State, from id: UUID) {
        debugLog?.record(
            .info,
            state.isEverythingFine
                ? "The cube says it is fine: \(DeviceSystemStateRules.describe(state))"
                : "The cube says: \(DeviceSystemStateRules.describe(state))"
        )
        onSystemState?(id, state)
    }

    /// Files what the cube says about itself, and says so only when it is news.
    ///
    /// Quiet when nothing moved, matching the charge and the face: every command this app reads back produces one of
    /// these, and most of them say what the last one said.
    /// The cube has said what it is called, which is newer than anything the scan heard.
    ///
    /// **The listed device is corrected as well as the report going out**, and that is not tidiness: `device(_:)`
    /// answers from this list, and a pairing writes `device_name` from what it answers
    /// (`DevicePairingRules.gapName`). The name a scan captured is the GAP name macOS had cached at the time, which
    /// after a rename is the *previous* one -- so without this a pairing made on the connection that corrects the
    /// name would still record the stale one, and which of the two landed first would decide what the table held.
    ///
    /// The list is republished for the same reason it is republished when anything else about a device changes: a row
    /// on screen showing a name the radio no longer believes is a second answer to what the cube is called.
    private func received(name: String, from id: UUID) {
        if let device = found[id], device.peripheralName != name {
            found[id] = ScannedDevice(
                id: device.id,
                peripheralName: name,
                advertisedName: device.advertisedName,
                advertisesTimeFlipService: device.advertisesTimeFlipService
            )
            publish()
        }
        onDeviceName?(id, name)
    }

    private func received(status: DeviceCommandRules.Status, from id: UUID) {
        guard status != cubeStatus else { return }
        cubeStatus = status
        debugLog?.record(
            .command,
            "The cube is \(status.isLocked ? "locked" : "unlocked") and \(status.isPaused ? "paused" : "running")"
                // **Said only when it is set, and it is worth saying.** `0x10` carries the delay on every answer and
                // the app read it and threw it away, so a cube that had been told to stop itself after five minutes
                // looked exactly like one that had not -- until it stopped, half an hour into a run, and the script
                // watching it reported that the app had given up on a cube that was still going (run 135,
                // 2026-08-29). A delay of zero is the ordinary state and would be noise on every status.
                + (status.autoPauseMinutes > 0 ? ", pausing itself after \(status.autoPauseMinutes)m" : "")
        )
        onCubeStatus?(id, status)
    }

    /// What to call a device in a message about it.
    ///
    /// **Asked of the radio rather than remembered by the tab**, which is the same reasoning as handing the tab the
    /// whole list on every change: the scan owns what was found, so a caller keeping names by it would be a second
    /// copy of a list that moves.
    func label(for id: UUID) -> String {
        DeviceScanRules.label(for: found[id] ?? placeholder(id))
    }

    /// The advertisement a listed device was built from, for a caller that needs more of it than a label -- recording
    /// a pairing needs the GAP name specifically, which is not always the name shown (`DevicePairingRules.gapName`).
    ///
    /// The placeholder stands in for a device that has dropped out of the list while an attempt on it was still
    /// running, so this answers for anything the radio has reached rather than only for what is currently listed.
    func device(_ id: UUID) -> ScannedDevice {
        found[id] ?? placeholder(id)
    }

    /// Stands in for a device that has left the list while an attempt on it is still running, so a log line can name
    /// something rather than trailing off.
    private func placeholder(_ id: UUID) -> ScannedDevice {
        ScannedDevice(id: id, peripheralName: nil, advertisedName: nil, advertisesTimeFlipService: false)
    }
}

// **`@preconcurrency` rather than a hop to the main actor**, which is a change from the version of this file that only
// scanned. That one read the two names off each advertisement and carried the values across, precisely because
// `CBPeripheral` is not `Sendable`; connecting needs the peripheral object itself, and there is no value it reduces
// to. The manager is created with `queue: .main`, so every callback below already arrives on the main thread and the
// conformance's runtime check is the assertion of that rather than a hope.
extension BluetoothRadio: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debugLog?.record(.scan, "Bluetooth state: \(central.state.rawValue)")
        guard central.state == .poweredOn else {
            found = [:]
            publish()
            report(unavailable(for: central.state))
            return
        }
        // Only start on the state that made it possible: this also fires when the radio comes back mid-session,
        // and picking the scan up then is what the user asked for when they pressed the button.
        beginScanIfReady()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // Overflow and solicited lists as well as the plain one: a service can arrive in any of the three, and this
        // costs nothing when it arrives in none of them, which on this hardware is most of the time.
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
        let device = ScannedDevice(
            id: peripheral.identifier,
            peripheralName: peripheral.name,
            advertisedName: advertisedName,
            advertisesTimeFlipService: services.contains(TimeFlipUUIDs.service)
        )

        // The cube a `reach` is looking for gets in whatever it is called: see there for why an identifier outranks the
        // name filter.
        guard !isFiltering
            || DeviceScanRules.isEligible(device, remembered: remembered, previouslyKnown: previouslyKnown)
        else {
            return
        }
        // Logged once per device rather than per advertisement, which arrives several times a second. Both names
        // go in the line, because the list is exactly where they disagree and a label nobody chose is
        // explicable from this row and guesswork without it.
        if found[device.id] == nil {
            debugLog?.record(
                .scan,
                "Found \(device.id.uuidString): peripheral \(device.peripheralName ?? ""), "
                    + "advertised \(device.advertisedName ?? "")"
                    + (device.advertisesTimeFlipService ? ", TimeFlip service" : "")
            )
        }
        // Kept whether or not the value changed: the list is drawn from the values, and the object behind them is
        // what a connect needs.
        peripherals[device.id] = peripheral
        if found[device.id] != device {
            found[device.id] = device
            publish()
        }
        // **A reach collects here and connects nowhere.** Which device to ask first cannot be known until the scan
        // is over -- they advertise in whatever order they happen to -- so the queue is built once, from all of them,
        // in `beginTryingWhatWasFound`.
        //
        // **The one thing worth acting on immediately is the remembered identifier**, because nothing a later
        // advertisement could add would go ahead of it, and holding the window open past that point costs the rest of
        // the window for nothing. That is the archive's `mayEndEarly`, and its measurement: on 2026-08-09 a cube was
        // in the scan results at 23:54:43.5 and not acted on until 23:55:14.2, thirty-one seconds spent waiting for a
        // window that had already found its answer.
        //
        // **It is a shortcut and it is treated as one.** This identifier is not unique to a cube (finding 8,
        // `docs/timeflip2-firmware-observations.md`), so the device it names can turn out not to be this app's at
        // all -- and `tryNextCandidate` then owes the room a proper look before it may say nothing is here.
        if reaching != nil, reaching!.mayEndEarly, device.id == reaching!.preferred {
            reaching!.mayEndEarly = false
            reaching!.windowWasCutShort = true
            stop(because: "stopped: the remembered device turned up")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let attempt, attempt.id == peripheral.identifier else { return }
        connectTimeout?.invalidate()
        connectTimeout = nil
        debugLog?.record(.login, "Connected to \(peripheral.identifier.uuidString), presenting a PIN")
        let login = DeviceLogin(
            peripheral: peripheral,
            pin: attempt.presenting,
            rotatingTo: attempt.rotatingTo,
            debugLog: debugLog,
            // A reset confirmation asks nothing about the cube: it is proving a wipe and letting go.
            staysWithTheCube: resetConfirmation == nil,
            rotated: { [weak self] pin in self?.onPINChanged?(pin) },
            // **Only while this is still the cube the app is holding.** These reads land seconds after the login, by
            // which time the window may have been closed or another device chosen -- and a report acted on then would
            // write down what one cube says under a pairing that now names a different one.
            reported: { [weak self] info in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.onDeviceInfo?(attempt.id, info)
            },
            // The same guard, and it earns it more often than the one above: this goes on arriving for the life of
            // the connection, so it is the callback most likely to fire against a cube the app has let go of.
            battery: { [weak self] level in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.received(batteryLevel: level, from: attempt.id)
            },
            // The same guard again, and it earns it for the same reason: this goes on arriving for the life of the
            // connection, so a flip landing after the app let the cube go would draw a face nobody is holding.
            face: { [weak self] face in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.received(face: face, from: attempt.id)
            },
            // The same guard again: a name arriving for a cube the app has let go of would rename the pairing it
            // still has, which is the one row a rename must never get wrong -- `device_name` is what the scan filter
            // matches on.
            nameReported: { [weak self] name in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.received(name: name, from: attempt.id)
            },
            // The same guard once more, and for the same reason as the two above.
            status: { [weak self] status in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.received(status: status, from: attempt.id)
            },
            // The same guard as the three above, and for the same reason.
            systemState: { [weak self] state in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.received(systemState: state, from: attempt.id)
            },
            // The same guard again: a login that finished discovering after the app let the cube go has nothing to
            // announce, and announcing it would send a fetch down a link nobody is holding.
            ready: { [weak self] in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.debugLog?.record(.login, "The cube is ready to be asked things")
                self.onCubeReady?(attempt.id)
            },
            // The same guard once more. See `DeviceLogin.settled` for why this is a separate moment from the one
            // above rather than the same one said twice.
            settled: { [weak self] in
                guard let self, self.connectedDevice == attempt.id else { return }
                self.debugLog?.record(.login, "The cube has answered the opening questions")
                self.onCubeSettled?(attempt.id)
            }
        ) { [weak self] outcome in
            self?.finish(attempt.id, outcome)
        }
        self.login = login
        login.begin()
    }

    /// What `finish` does with a refusal is the one branch that does not end the attempt: there may be another PIN.
    private func finish(_ id: UUID, _ outcome: DeviceLoginOutcome) {
        guard let attempt, attempt.id == id else { return }
        if outcome == .wrongPIN, !attempt.remaining.isEmpty {
            debugLog?.record(.login, "Refused, and there is another PIN to try")
            retry()
            return
        }
        if outcome == .loggedIn {
            connectedDevice = id
        }
        end(id, outcome)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let attempt, attempt.id == peripheral.identifier else { return }
        debugLog?.record(.login, "Could not connect: \(error?.localizedDescription ?? "no reason given")")
        end(attempt.id, .unreachable)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier
        debugLog?.record(
            .login,
            "Disconnected from \(id.uuidString)"
                + (isDisconnectingDeliberately ? ", as asked" : ", unexpectedly")
                + (error.map { ": \($0.localizedDescription)" } ?? "")
        )
        // A disconnect this app asked for has already been accounted for by whoever asked. Only an unexpected one
        // has anything to report, and which of the two it is is the difference between a tidy close and a cube whose
        // batteries have just come out.
        guard !isDisconnectingDeliberately else {
            isDisconnectingDeliberately = false
            return
        }
        // **The cube rebooting is what a reset looks like from here**, so this drop is the sequence proceeding rather
        // than a device going away. Reported as neither, and answered by reaching for it again.
        if let confirmation = resetConfirmation, confirmation.id == id {
            connectedDevice = nil
            login = nil
            debugLog?.record(.pair, "The cube dropped the link, which is it rebooting after the reset")
            retryResetConfirmation()
            return
        }
        if let attempt, attempt.id == id {
            login = nil
            end(id, .unreachable)
            return
        }
        guard connectedDevice == id else { return }
        connectedDevice = nil
        login = nil
        onConnectionDropped?(id)
    }
}

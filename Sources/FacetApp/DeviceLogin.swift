import CoreBluetooth
import Foundation

/// One connected cube, from a live link to a verdict on a PIN.
///
/// **A conversation, not a session.** It discovers the two characteristics a login needs, writes the PIN, reads what
/// the cube says about it, and reports. It does not decide which PIN to send (`DeviceLoginRules.candidates`), does not
/// decide what the answer means (`DeviceLoginRules.verdict`), and does not connect or disconnect anything
/// (`BluetoothRadio`, which owns the central manager because CoreBluetooth insists one object does).
///
/// **It outlives the login, deliberately.** Once a PIN is accepted this stays the peripheral's delegate, so anything
/// the cube says afterwards still reaches the trace. Without that, the first thing to notice an unsolicited
/// notification would be whichever feature went looking for one, and the bytes before it would be gone.
///
/// **Massaged from `TimeFlipBLEDevice`'s probe.** The archive's `probeConnect` / `probeDiscoverTimeFlipCharacteristics`
/// / `probeAttemptLogin` are the same four steps in the same order, and its central insight is kept: verify a
/// candidate on a connection of its own before letting it near anything the app depends on. What is not kept is the
/// shape -- five continuations, a parallel `ProbeSession` mirror of every piece of live state, and a `Task`-based
/// watchdog per step, all inside a 2,481-line class that was also the event source, the history reader and the
/// settings writer. The steps here are the delegate callbacks themselves, in order, with one deadline over the lot.
@MainActor
final class DeviceLogin: NSObject {
    /// How long the whole exchange gets, from a live connection to a verdict.
    ///
    /// One deadline rather than one per step, because a cube that stops answering stops answering: which step it was
    /// on is a thing for the log to say, not a thing to give its own budget to. Generous against the archive's
    /// measurements, where the whole of connect-and-link never exceeded 5.4 seconds.
    static let timeoutSeconds: TimeInterval = 15

    private let peripheral: CBPeripheral
    private let pin: String
    private let debugLog: DebugLog?
    private let finished: (DeviceLoginOutcome) -> Void

    private var deadline: Timer?
    private var isFinished = false
    private var password: CBCharacteristic?
    private var commandResult: CBCharacteristic?
    /// Whether a value arriving on the command result characteristic is this login's answer or later traffic.
    private var isAwaitingVerdict = false

    init(
        peripheral: CBPeripheral,
        pin: String,
        debugLog: DebugLog?,
        finished: @escaping (DeviceLoginOutcome) -> Void
    ) {
        self.peripheral = peripheral
        self.pin = pin
        self.debugLog = debugLog
        self.finished = finished
        super.init()
    }

    /// Starts the exchange on a peripheral that is already connected.
    func begin() {
        peripheral.delegate = self
        deadline?.invalidate()
        deadline = Timer(timeInterval: Self.timeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.debugLog?.record(.login, "The cube stopped answering part way through the login")
                self?.finish(.timedOut)
            }
        }
        if let deadline { RunLoop.main.add(deadline, forMode: .common) }
        // Only the TimeFlip service. Anything else the cube exposes -- battery, device information -- belongs to the
        // features that read it, and asking for everything here would be several round trips spent on values nobody
        // is waiting for.
        peripheral.discoverServices([TimeFlipUUIDs.service])
    }

    private func finish(_ outcome: DeviceLoginOutcome) {
        guard !isFinished else { return }
        isFinished = true
        isAwaitingVerdict = false
        deadline?.invalidate()
        deadline = nil
        finished(outcome)
    }
}

// `@preconcurrency`, for the reason given on `BluetoothRadio`'s conformance: the manager is created with
// `queue: .main`, so these arrive on the main thread, and a `CBPeripheral` has no value form to carry across.
extension DeviceLogin: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            debugLog?.record(.login, "Service discovery failed: \(error.localizedDescription)")
            finish(.unreachable)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == TimeFlipUUIDs.service }) else {
            // **This is what tells a TimeFlip from anything else that answered the scan**, and it is a better test
            // than the name the filter used to get here: names are chosen by people and this is the hardware saying
            // what it is.
            debugLog?.record(.login, "No TimeFlip service on this device")
            finish(.notATimeFlip)
            return
        }
        peripheral.discoverCharacteristics([TimeFlipUUIDs.password, TimeFlipUUIDs.commandResult], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            debugLog?.record(.login, "Characteristic discovery failed: \(error.localizedDescription)")
            finish(.unreachable)
            return
        }
        for characteristic in service.characteristics ?? [] {
            // The properties go in the log because they are the answer to "why did that write do nothing": a
            // characteristic that turns out not to be writable is invisible otherwise.
            debugLog?.record(
                .login,
                "Found characteristic \(TimeFlipUUIDs.name(for: characteristic.uuid))"
                    + " (properties 0x\(String(characteristic.properties.rawValue, radix: 16)))"
            )
            switch characteristic.uuid {
            case TimeFlipUUIDs.password: password = characteristic
            case TimeFlipUUIDs.commandResult: commandResult = characteristic
            default: break
            }
        }
        guard let password, commandResult != nil else {
            debugLog?.record(.login, "The TimeFlip service is missing the characteristics a login needs")
            finish(.notATimeFlip)
            return
        }
        let data = Data(pin.utf8)
        debugLog?.record(.login, "Presenting a PIN")
        debugLog?.transmitted(data, to: password.uuid, type: .withResponse)
        // `.withResponse`, so a write that the cube refused is distinguishable from one it took. The verdict is read
        // only once that acknowledgement arrives, since reading before the cube has processed the write is how a
        // stale command result gets mistaken for an answer.
        isAwaitingVerdict = true
        peripheral.writeValue(data, for: password, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        debugLog?.acknowledged(characteristic.uuid, error: error)
        guard characteristic.uuid == TimeFlipUUIDs.password else { return }
        // The reason is already in the row above; what matters here is that the cube never took the PIN, so there is
        // nothing to read an answer from.
        if error != nil {
            finish(.unreachable)
            return
        }
        guard let commandResult else { return }
        peripheral.readValue(for: commandResult)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Logged before anything is made of it, and logged whatever it is: a value this app has no handler for is
        // exactly the kind of thing the trace exists to catch (see `BLETrace`).
        debugLog?.received(characteristic.value, from: characteristic.uuid, error: error)
        guard isAwaitingVerdict, characteristic.uuid == TimeFlipUUIDs.commandResult else { return }
        isAwaitingVerdict = false
        if error != nil {
            finish(.unreachable)
            return
        }
        switch DeviceLoginRules.verdict(for: characteristic.value) {
        case .accepted:
            debugLog?.record(.login, "PIN accepted")
            finish(.loggedIn)
        case .rejected:
            debugLog?.record(.login, "PIN refused")
            finish(.wrongPIN)
        case .unreadable:
            // **Not counted as a refusal.** A cube that answered with something else has not said no, and treating
            // this as a wrong PIN would spend the next candidate on a question the cube never heard. It is also the
            // shape a stale command result takes (finding 2 in `docs/timeflip2-firmware-observations.md`), which is
            // the one case where the bytes in front of you belong to somebody else's command.
            debugLog?.record(.login, "The cube's answer to the PIN could not be read")
            finish(.timedOut)
        }
    }

    /// Traffic that arrives once the login is over: a notification the cube sent unasked, or a read some later
    /// feature asked for. Nothing is done with it here beyond putting it in the trace, which is the point.
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        debugLog?.record(.login, "The cube now reports its name as \"\(peripheral.name ?? "")\"")
    }
}

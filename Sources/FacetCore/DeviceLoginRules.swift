import Foundation

/// Which PINs the app presents to a cube, and what the cube's answer means.
///
/// **Massaged from `PairingPasswordRules`**, whose policy is right and whose reasoning survives inspection: two
/// candidates, in a fixed order, and no third guess. What changes is that the verdict rule moves in beside them --
/// choosing what to send and reading what comes back are the two halves of one exchange, and in the archive they sat
/// in different files with the second one inlined in a 2,481-line delegate.
enum DeviceLoginRules {
    /// The vendor default, from `docs/TimeFlip2 BLE Protocol v4.3.md`: ASCII `000000`.
    ///
    /// Also where a cube goes back to when its batteries come out (measured 2026-08-11), which is why it stays a
    /// candidate for a cube this app has already met.
    static let defaultPIN = "000000"

    /// Six characters, which the protocol fixes: the password characteristic is six bytes wide.
    static let length = 6

    /// The PINs to try, in order.
    ///
    /// They are the states a cube in front of this app can be in: on the **vendor default**, because it is new here
    /// or has been power-cycled, or on a **PIN this app set** and wrote down. A PIN outside that set is one nobody
    /// can name, and searching for it would be a lockout dressed up as a feature -- so nothing is ever guessed here.
    ///
    /// **`stored` is a list now, where it used to be one value, and there can be two of them.** The app keeps a
    /// cube's PIN in the Keychain and, when the Keychain has refused a write, in `config.json` as well -- so the two
    /// disagreeing is a real state with a known cause, and the app genuinely does not know which of them the cube
    /// took. `DevicePINSource.stored` puts them in order and `reconcile` ends the disagreement the next time a cube
    /// answers one. Every candidate costs a whole connect (see `BluetoothRadio`), which is why the list is
    /// deduplicated and why nothing speculative is ever added to it.
    static func candidates(stored: [String]) -> [String] {
        var seen: Set<String> = []
        return ([defaultPIN] + stored)
            .filter { isWellFormed($0) && seen.insert($0).inserted }
    }

    /// The PINs to try on a cube this app is **already paired to**, in order.
    ///
    /// The same two, the other way round, and the order is the whole of the difference. A pairing is meeting a cube that
    /// is probably factory-fresh, so the default goes first; a reconnect is going back to a cube this app has already
    /// set a PIN on, so that one goes first. Presenting them the pairing way round would cost a whole reconnect
    /// (`BluetoothRadio.settleSeconds`, plus a connect) on every single reconnect, to learn what the app already knew.
    ///
    /// **The default stays on the list, and `defaultPIN`'s own note is why**: a cube whose batteries have come out is
    /// back on it (measured 2026-08-11), and that is an ordinary Tuesday rather than a lost pairing. Dropping it would
    /// turn a battery change into a Forget and a re-pair.
    ///
    /// **This departs from the archive, which presented the stored PIN and nothing else on a reconnect.** Its reasoning
    /// was that connecting is gated on already being paired, so a refused stored PIN means the pairing is no longer
    /// valid and saying so beats silently logging in to a device whose PIN the app has lost track of
    /// (`ApplicationDelegate.startDeviceEvents`). That reasoning is about *not knowing which cube answered* -- and it
    /// does not apply here, because this app reconnects by identifier: a reach names one peripheral and gets that one or
    /// nothing (`BluetoothRadio.reach`). The archive had to try every eligible cube in the room and used the PIN to work
    /// out which was its own, which is exactly the situation where presenting a public default is how you take over
    /// somebody else's device. Reaching a known identifier cannot do that.
    static func reconnectCandidates(stored: [String]) -> [String] {
        var seen: Set<String> = []
        return (stored + [defaultPIN])
            .filter { isWellFormed($0) && seen.insert($0).inserted }
    }

    /// Whether a PIN is even presentable. The characteristic is six bytes, so anything else is a bug on this side and
    /// is worth catching before it becomes a rejection that looks like the cube's fault.
    static func isWellFormed(_ pin: String) -> Bool {
        pin.utf8.count == length
    }

    /// The command that sets a new PIN: `0x30`, followed by the six bytes of it, written to `TimeFlipUUIDs.command`.
    /// Section 4 of `docs/TimeFlip2 BLE Protocol v4.3.md`, and the same byte the archive sent.
    static let setPIN: UInt8 = 0x30

    /// The command that puts a cube back to how it left the factory: `0xFF`, written on its own to
    /// `TimeFlipUUIDs.command`. It erases everything the device holds -- face colours, task settings, its name and its
    /// PIN -- and reboots.
    ///
    /// **There is nothing to read afterwards, and that is measured rather than assumed.** The archive checked live and
    /// found the command result characteristic still holding the *previous* command's answer, the cube having rebooted
    /// without writing a fresh one (`TimeFlipBLEDevice.factoryReset`). So the write being acknowledged is the whole of
    /// the evidence, which is finding 2 in `docs/timeflip2-firmware-observations.md` in its sharpest form: reading the
    /// result here would return somebody else's bytes and read as a confirmation.
    static let factoryReset: UInt8 = 0xFF

    /// What the cube said about the PIN.
    enum Verdict: Equatable {
        case accepted
        case rejected
        /// Nothing usable came back. Not a rejection: a cube that did not answer has not refused anything, and
        /// treating silence as a wrong PIN would burn the next candidate on a question that was never asked.
        case unreadable
    }

    /// Reads the command result characteristic's answer to a login.
    ///
    /// **`0x02` is acceptance and `0x01` is refusal, which is the opposite of what the spec says.** Section 4 of
    /// `docs/TimeFlip2 BLE Protocol v4.3.md` states plainly that `0x01` means the password is correct and `0x02`
    /// means it is wrong. Real hardware does the reverse: finding 4 of `docs/timeflip2-firmware-observations.md`,
    /// measured on this app on 2026-08-17 with both outcomes three seconds apart on one cube (evidence rows 361 to
    /// 375), and the archive had found the same thing before it. The root `CLAUDE.md` is explicit that a measurement
    /// beats the spec. Getting this backwards is not a subtle failure: every correct PIN would be refused and every
    /// wrong one accepted.
    ///
    /// Anything else is `unreadable` rather than a rejection, and that matters more here than it looks. Finding 2 in
    /// `docs/timeflip2-firmware-observations.md` is that this characteristic is often *not* updated and holds
    /// whatever the last command left in it, so a long or unexpected frame is a stale answer to somebody else's
    /// question. The login is a command that does update it, which is what makes reading it here legitimate at all.
    static func verdict(for value: Data?) -> Verdict {
        guard let value, let code = value.first else { return .unreadable }
        switch code {
        case 0x02: return .accepted
        case 0x01: return .rejected
        default: return .unreadable
        }
    }
}

/// How an attempt to reach a cube ended, in the words the Device tab shows.
///
/// **Five endings rather than "it didn't work"**, for the reason `ScanUnavailable` gives about empty lists: a wrong
/// PIN, a cube that is not a TimeFlip, and a cube that went away are three different problems with three different
/// things to do about them, and one message for all three sends everybody to look at the wrong one.
enum DeviceLoginOutcome: Equatable {
    /// Connected, and the cube accepted a PIN.
    case loggedIn
    /// Connected, and neither candidate was accepted.
    case wrongPIN
    /// Connected and logged in, and then the cube would not take the new PIN the app set on it.
    ///
    /// **Not `loggedIn` with a note in the log**, even though the link is up and the old PIN did work. What is
    /// unknown after a failed set is which PIN the cube is now on, and a link whose authority nobody can name is
    /// worse than no link: the next command might be refused for a reason the app would read as the cube going away.
    /// So the attempt ends, the link is dropped, and pressing the device again presents both known PINs from a fresh
    /// connection -- which is the state this whole exchange is specified in.
    case newPINRefused
    /// Connected, and it has no TimeFlip service on it. Something else answered the scan.
    case notATimeFlip
    /// It never answered, or the link dropped part way through.
    case unreachable
    /// It answered and then stopped, part way through the exchange.
    case timedOut

    func message(for name: String) -> String {
        switch self {
        case .loggedIn: return "Connected to \(name)."
        case .wrongPIN: return "\(name) refused both PINs. Take its batteries out to reset it, then try again."
        case .newPINRefused: return "\(name) would not take a new PIN. Press it again to reconnect."
        case .notATimeFlip: return "\(name) is not a TimeFlip."
        case .unreachable: return "Could not reach \(name). Flip it to wake it, then try again."
        case .timedOut: return "\(name) stopped answering."
        }
    }
}

/// How a factory reset ended, in the words the Device tab shows.
///
/// **Three endings, and the middle one is the whole point.** Sending `0xFF` and the cube actually having been erased
/// are different claims, because the command has no usable acknowledgement (`DeviceLoginRules.factoryReset`): the only
/// proof is the cube coming back on the vendor PIN, a device still holding this app's PIN plainly not having been
/// wiped. Collapsing "sent" into "done" is exactly the mistake that would let the app throw away a cube's name on the
/// strength of a command that never landed.
enum FactoryResetOutcome: Equatable {
    /// The cube came back and let the app in on the vendor PIN. The wipe took.
    case confirmed
    /// The command went out and was acknowledged, and the cube never came back on the vendor PIN inside the window.
    ///
    /// **Not a failure, and deliberately not reported as one.** The cube may be erasing slowly, or may have been
    /// carried out of range while it rebooted. What is certain is only that the app cannot say the wipe happened, so
    /// it changes nothing and says exactly that.
    case notConfirmed
    /// Nothing was sent: no cube was connected, or it would not take the command.
    case notSent

    func message(for name: String) -> String {
        switch self {
        case .confirmed: return "\(name) was reset and is back to factory settings."
        case .notConfirmed: return "\(name) did not come back after the reset, so nothing has been changed. Flip it to wake it, then try again."
        case .notSent: return "Could not send the reset to \(name)."
        }
    }
}

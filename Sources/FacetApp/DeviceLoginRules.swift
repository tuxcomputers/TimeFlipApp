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

    /// The PINs to try, in order, and there are never more than two.
    ///
    /// They are the two states a cube in front of this app can be in: on the **vendor default**, because it is new
    /// here or has been power-cycled, or on a **PIN this app set** and has kept. Neither accepted means the cube is
    /// on a PIN nobody can name, and searching for that would be a lockout dressed up as a feature -- so there is
    /// deliberately no third guess.
    ///
    /// Deduplicated, so a stored PIN that *is* the default is presented once. The second attempt costs a whole
    /// reconnect (see `BluetoothRadio`), which is a long way to go to learn nothing.
    static func candidates(stored: String?) -> [String] {
        var seen: Set<String> = []
        return [defaultPIN, stored]
            .compactMap { $0 }
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

    /// The PIN to put on a cube that has just accepted `accepted`, or `nil` to leave it on the one it has.
    ///
    /// **Why a cube's PIN is changed at all**: the vendor default is public, so a cube left on it is one that anybody
    /// within a few metres can take over. The archive did this on pairing, emulating the official app, and the
    /// reasoning survives inspection.
    ///
    /// **`target` is what decides whether anything happens**, and in this build only a developer build has one
    /// (`DeveloperMode.devicePIN`) -- see there for why a build that cannot write a random PIN down must not set one.
    ///
    /// **Massaged from `PairingPasswordRules.rotatesPassword`**, which asked a narrower question: it rotated only a
    /// cube reached on the vendor default, on the grounds that one reached on the stored PIN already holds the PIN on
    /// record. This asks whether the cube is already on the PIN this build sets, which gives the same answer in every
    /// state the archive was reasoning about, and a better one in the state it did not consider: a cube on some
    /// *other* stored PIN converges onto the one this build knows rather than being left where it was found.
    ///
    /// A PIN is never set to the value the cube already answered to. That write costs a command round trip and a
    /// second login to confirm it, which is a long way to go to change nothing.
    static func rotation(from accepted: String, to target: String?) -> String? {
        guard let target, isWellFormed(target), target != accepted else { return nil }
        return target
    }

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

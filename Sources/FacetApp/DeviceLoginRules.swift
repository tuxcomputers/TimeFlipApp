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
        case .notATimeFlip: return "\(name) is not a TimeFlip."
        case .unreachable: return "Could not reach \(name). Flip it to wake it, then try again."
        case .timedOut: return "\(name) stopped answering."
        }
    }
}

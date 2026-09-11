import Foundation

/// What the core calls one cube: a token the adapter minted and the core never reads.
///
/// **The core cannot name a cube and must not try.** Naming one is the platform's job and the two platforms do
/// it incompatibly: CoreBluetooth invents a `UUID` per host, and BlueZ has no such thing at all, only the
/// device's real Bluetooth address, `E8:DB:D8:CF:F9:0F`. Neither is derivable from the other and neither means
/// anything on the other machine.
///
/// **So this is opaque, deliberately.** The core compares two of them and orders a list of them, and does
/// nothing else with one: `DeviceScanRules.reachOrder` ranks the preferred device by equality and breaks ties by
/// this ordering so a room scanned twice is asked in the same order twice. It never parses one, never builds one
/// from parts, and never assumes a shape. Whatever an adapter puts in is handed back to that adapter unread.
///
/// **It used to be a `UUID`, which was CoreBluetooth's shape reaching into the circle** (until 2026-09-11). The
/// cost was on the far side: BlueZ had to pack six address bytes into the last six bytes of a UUID behind a
/// constant marker, and check the marker on the way back out so a Mac-written row was refused rather than
/// dialled. Eighty-four lines and six tests existed to make an address look like something it is not. A Linux
/// adapter now stores the address as the address.
///
/// **Not a name.** The cube's name is user-editable, is not unique, and is two values at once that a rename
/// moves one of, which is why `DeviceScanRules` matches on names rather than trusting one. A handle is stable
/// for as long as the pairing is, which is the whole of what identity is needed for here: no recorded time says
/// which device produced it, by design.
package struct DeviceHandle: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The adapter's own spelling. **Read this only in the adapter that wrote it.**
    package let value: String

    package init(_ value: String) {
        self.value = value
    }

    /// Ordering exists for one reason: a deterministic tiebreak when two devices sort equal on everything a
    /// person would notice. It is not a meaningful order and nothing should read one into it.
    package static func < (lhs: DeviceHandle, rhs: DeviceHandle) -> Bool {
        lhs.value < rhs.value
    }

    package var description: String { value }
}

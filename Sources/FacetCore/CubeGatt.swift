import Foundation

/// The cube's GATT table, as the thing talking to it needs: find what is there, read it, write to it, and be told
/// when it changes.
///
/// **Addressed by UUID and nothing else.** A `CBCharacteristic` is a live object CoreBluetooth hands out and is
/// meaningless anywhere else; a UUID is what the vendor's table actually names, what `docs/timeflip.md` is written
/// in, and what every adapter can look its own handle up from. `TimeFlipUUIDs.canonical(_:)` is the spelling to
/// compare on, the 16-bit shorthand in the vendor's table being one of two ways to write the same UUID.
///
/// **Five methods, because that is the whole of what the login ever did to the peripheral.** They were already a
/// funnel in `DeviceLogin` before this existed, every one of them logging and then forwarding, which is what made
/// the seam obvious: the file's other 700 lines are the sequence, the read-back discipline and the parsing, and
/// none of that is CoreBluetooth.
///
/// **Nothing here decides anything, and nothing here waits.** A deadline is the caller's, because how long to wait
/// for a cube is a fact about the protocol rather than about the radio.
@MainActor
package protocol CubeGatt: AnyObject {
    /// Where answers go. Set before anything is asked, and held weakly by the adapter.
    var events: CubeGattEvents? { get set }

    /// Ask which of these services the cube has. Empty asks for all of them, which this app never wants.
    func discoverServices(_ uuids: [String])

    /// Ask which characteristics a service has. `nil` asks for all of them.
    func discoverCharacteristics(_ uuids: [String]?, ofService service: String)

    /// Read a characteristic's value. The answer arrives on `valueArrived`.
    func read(_ characteristic: String)

    /// Ask to be told when a characteristic changes. Values then arrive on `valueArrived` like a read's.
    func subscribe(to characteristic: String)

    /// Write to a characteristic.
    ///
    /// - Parameter expectingAcknowledgement: whether the write should be acknowledged at the ATT layer, which is
    ///   `writeAcknowledged`. **It proves the bytes arrived and nothing more**, which is less than it looks: a cube
    ///   refuses every command until a PIN has been accepted, and refuses it *after* the write has succeeded. See
    ///   `CLAUDE.md`, "A command the device can be asked about is read back before it is believed".
    func write(_ payload: Data, to characteristic: String, expectingAcknowledgement: Bool)
}

/// A characteristic a service turned out to have.
///
/// **Carries whether it can notify, which is not decoration.** The listening phase subscribes to everything that
/// says it can and says so when a cube offers none, and that decision cannot be made from a UUID: it is the
/// cube's own declaration of what it will push. Nothing else about a characteristic has ever been needed here.
package struct DiscoveredCharacteristic: Equatable {
    package let uuid: String
    package let canNotify: Bool

    package init(uuid: String, canNotify: Bool) {
        self.uuid = TimeFlipUUIDs.canonical(uuid)
        self.canNotify = canNotify
    }
}

/// What comes back from the cube's GATT table.
///
/// **Every one of them carries `failed` rather than throwing or answering an optional.** The caller acts on the
/// difference: a read that failed and a read that answered nothing are not the same, and neither is a service that
/// is absent from one the radio could not ask about.
@MainActor
package protocol CubeGattEvents: AnyObject {
    /// Which services the cube turned out to have. **The list is everything found so far, not just this answer**,
    /// which matters because a caller may ask three times for three different services and each answer arrives
    /// carrying the accumulated set: nothing in the reply says which request it belongs to.
    func servicesDiscovered(_ uuids: [String], failed: String?)

    /// Which characteristics a service turned out to have.
    func characteristicsDiscovered(
        _ found: [DiscoveredCharacteristic],
        ofService service: String,
        failed: String?
    )

    /// A value, from a read or from a subscription. **Those two are indistinguishable here**, and on this hardware
    /// that is not merely an interface simplification: a read publishes a change notification of its own, so the
    /// two cannot be told apart at the wire either (`docs/linux-bluez-port-notes.md`).
    func valueArrived(_ value: Data?, from characteristic: String, failed: String?)

    /// A write reached the cube, or did not.
    func writeAcknowledged(to characteristic: String, failed: String?)

    /// The cube saying what it is called.
    ///
    /// **Not a characteristic, which is why it is its own event**: this is GAP, delivered a second or two into a
    /// connection once the platform has re-read it, and it is the one thing that ever confirms a rename. A name
    /// that has not changed arrives here too.
    func nameArrived(_ name: String)
}

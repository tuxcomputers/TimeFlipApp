import Foundation

/// The address BlueZ names a cube by, as the `UUID` the rest of this app is written around.
///
/// **The two platforms genuinely do not name a cube the same way**, and the database says so already:
/// `device_uuid` is "assigned by this Mac's CoreBluetooth stack, not by the device, so it is meaningless
/// on any other machine" (`database/011_setting.sql`). BlueZ has no such identifier -- it has the
/// device's real Bluetooth address, `E8:DB:D8:CF:F9:0F` -- while `ScannedDevice`, `CubeRadio` and the
/// `device_uuid` row are all written in terms of a `UUID`.
///
/// **So the address is carried inside a UUID rather than the model being widened.** The six address bytes
/// go in the last six bytes of the UUID and a fixed marker fills the rest, which makes the mapping
/// deterministic in both directions: the same cube is the same identifier on every launch, and the
/// address can always be read back out to make a D-Bus call with. Widening `ScannedDevice.id` to a string
/// would have reached the database, the pairing rows and every rule in between to buy nothing.
///
/// **It is not a v3 or v5 UUID**, deliberately: those hash the name and cannot be reversed, and reversing
/// is the point. The marker is arbitrary and only has to be constant -- `face70` reads as "facet" in the
/// hex, which is as much meaning as it needs.
package enum BlueZAddress {
    /// The first twenty hex digits of every identifier this makes: ten constant bytes, leaving the last
    /// six for the address. Arbitrary and only required to be constant -- it reads as `face7000` in a log,
    /// which is as much meaning as it needs.
    ///
    /// **Built as text rather than as bytes**, because `uuid_t` is a C array Swift imports as a sixteen-way
    /// tuple: it cannot be default-initialised, and writing one out element by element to save a string
    /// format would be the least readable way to reach the same sixteen bytes.
    package static let marker = "face7000-0000-0000-0000-"

    /// The identifier for a BlueZ address, or `nil` if that is not an address.
    package static func identifier(forAddress address: String) -> UUID? {
        guard let bytes = addressBytes(address) else { return nil }
        let tail = bytes.map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: marker + tail)
    }

    /// The address inside an identifier this made, or `nil` if it did not make it.
    ///
    /// **The marker is checked rather than assumed.** A `device_uuid` row written on the Mac is a perfectly
    /// valid UUID that names nothing here, and answering an address for it would send a D-Bus call to six
    /// bytes of somebody else's identifier.
    package static func address(fromIdentifier identifier: UUID) -> String? {
        let text = identifier.uuidString.lowercased()
        guard text.hasPrefix(marker) else { return nil }
        let tail = text.dropFirst(marker.count)
        guard tail.count == 12 else { return nil }
        let pairs = stride(from: 0, to: 12, by: 2).map { offset -> String in
            let start = tail.index(tail.startIndex, offsetBy: offset)
            return String(tail[start ..< tail.index(start, offsetBy: 2)]).uppercased()
        }
        return pairs.joined(separator: ":")
    }

    /// Whether an identifier is one of ours, which is the same question as whether an address can be read
    /// back out of it.
    package static func isBlueZIdentifier(_ identifier: UUID) -> Bool {
        address(fromIdentifier: identifier) != nil
    }

    /// The six bytes of `AA:BB:CC:DD:EE:FF`, in order, or `nil` if it is not that shape.
    package static func addressBytes(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard part.count == 2, let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    /// The BlueZ object path for a device on an adapter.
    ///
    /// **Built rather than looked up only where there is nothing to look up in** -- a fresh cache has no
    /// device object at all. Where the tree already holds the device, `BlueZObjectTree.device(withAddress:)`
    /// answers its real path, and that is what the radio uses: this shape is BlueZ's own and documented, but
    /// it is still a shape rather than a promise.
    package static func devicePath(adapter: String, address: String) -> String? {
        guard let bytes = addressBytes(address) else { return nil }
        let suffix = bytes.map { String(format: "%02X", $0) }.joined(separator: "_")
        return "\(adapter)/dev_\(suffix)"
    }
}

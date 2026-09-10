import Foundation

/// A run of bytes as a debug row says it: hex, and the ASCII beside it when every byte is printable.
///
/// **Moved out of `FacetMac.BLETrace` when the radio became a port.** It was written for the wire trace and
/// nothing in it is CoreBluetooth: `CubeCommandChannel` already needed it and had to be handed it as a closure
/// to get at it, which is the shape of a function on the wrong side of a line.
///
/// **Brackets rather than quotation marks**, which is not decoration: the two halves need separating or the
/// ASCII runs straight on from the hex, and every debug message is plain text -- no apostrophes, no quotation
/// marks -- because they are read back out with SQL `LIKE` patterns and both need escaping on the way (see
/// `CLAUDE.md`). Brackets need escaping nowhere, and the app already writes `(category_id 4)` in the same breath.
package enum CubeBytes {
    package static func describe(_ data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let text = printable(data) else { return hex }
        return "\(hex) (\(text))"
    }

    /// The ASCII, or `nil` where any byte is not printable. **Empty is not printable either**: a characteristic
    /// that answered with nothing is a fact worth seeing as `` rather than as an empty pair of brackets.
    private static func printable(_ data: Data) -> String? {
        guard !data.isEmpty, data.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

import Foundation

/// A D-Bus value as a plain Swift tree, so nothing above `SystemBus` sees libdbus.
///
/// **Deliberately not one case per D-Bus type.** The specification has ten numeric types and this app
/// cares about none of the distinctions: a `RSSI` is `int16`, a `MTU` is `uint16`, a battery level is a
/// byte, and every one of them is read as a number. So the numbers collapse into `integer`, and what
/// keeps its own case is what the app actually treats differently.
///
/// **`bytes` is the case this exists for.** A characteristic's value arrives as `ay`, and a face turn is
/// the app's core function -- reading it as `[UInt8]` rather than an array of ten thousand `.byte` cases
/// is the difference between a usable value and a shape somebody has to unpick.
package indirect enum DBusValue: Equatable, Sendable {
    case string(String)
    /// An object path. The same characters as a string and a different type on the wire, which matters
    /// when *sending* one: BlueZ refuses a method that wants `o` and is handed `s`.
    case objectPath(String)
    case boolean(Bool)
    case byte(UInt8)
    /// Every signed and unsigned integer width, as one thing. See the note above.
    case integer(Int64)
    case double(Double)
    /// `ay`: a characteristic value, a PIN, a command.
    case bytes([UInt8])
    case array([DBusValue])
    /// `a{sv}` and its nestings, keyed by whatever the entry's key was -- a string or an object path,
    /// both of which read back as text.
    case dictionary([String: DBusValue])
    case structure([DBusValue])
    case variant(DBusValue)
    /// A type this app has no use for, kept as a case so an unexpected reply is describable rather than
    /// silently absent.
    case unsupported

    /// The D-Bus signature for this value, which a variant has to be told before it can hold one.
    package var signature: String {
        switch self {
        case .string: return "s"
        case .objectPath: return "o"
        case .boolean: return "b"
        case .byte: return "y"
        case .integer: return "q"
        case .double: return "d"
        case .bytes: return "ay"
        case .dictionary: return "a{sv}"
        case let .variant(inner): return inner.signature
        case .array, .structure, .unsupported: return "v"
        }
    }

    // MARK: - reading what a caller expects

    /// The text, whether it arrived as a string, an object path or inside a variant.
    package var text: String? {
        switch self {
        case let .string(value), let .objectPath(value): return value
        case let .variant(inner): return inner.text
        default: return nil
        }
    }

    package var flag: Bool? {
        switch self {
        case let .boolean(value): return value
        case let .variant(inner): return inner.flag
        default: return nil
        }
    }

    package var number: Int64? {
        switch self {
        case let .integer(value): return value
        case let .byte(value): return Int64(value)
        case let .variant(inner): return inner.number
        default: return nil
        }
    }

    package var data: [UInt8]? {
        switch self {
        case let .bytes(value): return value
        case let .variant(inner): return inner.data
        default: return nil
        }
    }

    /// The members, seeing through a variant. **Every property BlueZ answers is wrapped in one**, so an
    /// array read that pattern-matches `.array` directly finds nothing -- and finds it silently, which is
    /// how `Flags` and `UUIDs` came back empty the first time this was written.
    package var items: [DBusValue]? {
        switch self {
        case let .array(value): return value
        case let .structure(value): return value
        case let .variant(inner): return inner.items
        default: return nil
        }
    }

    /// An array of strings, which is what `UUIDs` and `Flags` are.
    package var strings: [String]? {
        items.map { $0.compactMap(\.text) }
    }

    package var members: [String: DBusValue]? {
        switch self {
        case let .dictionary(value): return value
        case let .variant(inner): return inner.members
        default: return nil
        }
    }

    /// The value at a key of this dictionary, seeing through a variant on the way in and out -- which is
    /// what reading a BlueZ property is, every time.
    package subscript(key: String) -> DBusValue? {
        members?[key]
    }
}

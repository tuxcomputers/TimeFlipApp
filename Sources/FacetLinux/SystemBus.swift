#if canImport(CDBus)
import CDBus
import Foundation

/// A connection to the system message bus, and the four things this app does with one.
///
/// **The whole point of this type is that nothing above it sees libdbus.** It answers `DBusValue`, which
/// is a plain Swift tree, so the BlueZ layer is written against Swift values and the C API stops here.
/// That also means the transport can be replaced without touching anything that reads a characteristic.
///
/// **libdbus's own type constants cannot be imported.** They are `#define DBUS_TYPE_STRING ((int) 's')`,
/// a cast Swift's importer does not read, so `Kind` spells them out by value from `dbus-protocol.h`.
///
/// **Not thread-safe, and neither is libdbus by default**, so every call goes through one serial queue and
/// the connection is never touched from anywhere else. `@unchecked Sendable` is that arrangement, not a
/// claim about libdbus.
package final class SystemBus: @unchecked Sendable {
    /// D-Bus type codes, as the specification gives them. The importer cannot read the header's macros.
    enum Kind {
        static let invalid = Int32(0)
        static let byte = Int32(UInt8(ascii: "y"))
        static let boolean = Int32(UInt8(ascii: "b"))
        static let int16 = Int32(UInt8(ascii: "n"))
        static let uint16 = Int32(UInt8(ascii: "q"))
        static let int32 = Int32(UInt8(ascii: "i"))
        static let uint32 = Int32(UInt8(ascii: "u"))
        static let int64 = Int32(UInt8(ascii: "x"))
        static let uint64 = Int32(UInt8(ascii: "t"))
        static let double = Int32(UInt8(ascii: "d"))
        static let string = Int32(UInt8(ascii: "s"))
        static let objectPath = Int32(UInt8(ascii: "o"))
        static let signature = Int32(UInt8(ascii: "g"))
        static let array = Int32(UInt8(ascii: "a"))
        static let variant = Int32(UInt8(ascii: "v"))
        static let structure = Int32(UInt8(ascii: "r"))
        static let dictEntry = Int32(UInt8(ascii: "e"))
    }

    package enum Failure: Error, Equatable {
        /// The bus itself could not be reached, which on this platform means the daemon is not running.
        case noBus(String)
        /// A call was refused or timed out. Carries the D-Bus error name and message, both of which are
        /// worth keeping: `org.bluez.Error.NotConnected` says something a human-readable string does not.
        case callFailed(name: String, message: String)
        /// A reply arrived and was not the shape the caller expected.
        case unexpectedReply(String)
        case matchFailed(String)
    }

    private let connection: OpaquePointer
    private let queue = DispatchQueue(label: "au.com.tux.facet.system-bus")

    package init() throws {
        var error = DBusError()
        dbus_error_init(&error)
        defer { dbus_error_free(&error) }
        guard let connection = dbus_bus_get(DBUS_BUS_SYSTEM, &error) else {
            throw Failure.noBus(Self.text(error.message))
        }
        // **Shared rather than private, and so never closed.** `dbus_bus_get` hands back a connection the
        // library owns and reference-counts; calling `dbus_connection_close` on one is a programming error
        // libdbus complains about. Releasing our reference is the whole of the cleanup.
        self.connection = connection
    }

    deinit {
        dbus_connection_unref(connection)
    }

    // MARK: - calling a method

    /// Calls a method and answers the reply's arguments, in order.
    ///
    /// Blocking, deliberately: every call this app makes to BlueZ is a step in a sequence that cannot
    /// proceed without the answer, and the callers are already off the main actor.
    ///
    /// **The reply is discardable because several of these are made for effect**: `StartDiscovery`,
    /// `Connect` and `Set` answer nothing worth reading, and what matters about them is whether they
    /// threw. The read-backs that follow are separate calls, deliberately.
    @discardableResult
    package func call(
        destination: String,
        path: String,
        interface: String,
        method: String,
        arguments: [DBusValue] = [],
        timeoutMilliseconds: Int32 = 10_000
    ) throws -> [DBusValue] {
        try queue.sync {
            guard let message = dbus_message_new_method_call(destination, path, interface, method) else {
                throw Failure.unexpectedReply("the call could not be built")
            }
            defer { dbus_message_unref(message) }

            if !arguments.isEmpty {
                var iterator = DBusMessageIter()
                dbus_message_iter_init_append(message, &iterator)
                for argument in arguments {
                    try Self.append(argument, to: &iterator)
                }
            }

            var error = DBusError()
            dbus_error_init(&error)
            defer { dbus_error_free(&error) }
            guard let reply = dbus_connection_send_with_reply_and_block(
                connection, message, timeoutMilliseconds, &error
            ) else {
                throw Failure.callFailed(name: Self.text(error.name), message: Self.text(error.message))
            }
            defer { dbus_message_unref(reply) }
            return Self.readArguments(of: reply)
        }
    }

    // MARK: - listening for signals

    /// Adds a match rule, so signals answering it start arriving at `nextSignal`.
    ///
    /// A rule is the D-Bus spec's own syntax, e.g.
    /// `type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'`.
    package func addMatch(_ rule: String) throws {
        try queue.sync {
            var error = DBusError()
            dbus_error_init(&error)
            defer { dbus_error_free(&error) }
            dbus_bus_add_match(connection, rule, &error)
            if dbus_error_is_set(&error) != 0 {
                throw Failure.matchFailed(Self.text(error.message))
            }
            dbus_connection_flush(connection)
        }
    }

    /// The next signal to arrive, or `nil` if none did within the wait.
    ///
    /// **A poll rather than a callback**, because libdbus's dispatch wants either its own main loop or to
    /// be pumped, and pumping is the half that does not drag GLib in. The caller runs this on a thread of
    /// its own and hands what arrives to whatever is waiting.
    package func nextSignal(waitingMilliseconds: Int32 = 250) -> Signal? {
        queue.sync {
            dbus_connection_read_write(connection, waitingMilliseconds)
            while let message = dbus_connection_pop_message(connection) {
                defer { dbus_message_unref(message) }
                guard dbus_message_get_type(message) == DBUS_MESSAGE_TYPE_SIGNAL else { continue }
                return Signal(
                    path: Self.text(dbus_message_get_path(message)),
                    interface: Self.text(dbus_message_get_interface(message)),
                    member: Self.text(dbus_message_get_member(message)),
                    arguments: Self.readArguments(of: message)
                )
            }
            return nil
        }
    }

    /// One signal, as it arrived.
    package struct Signal: Equatable, Sendable {
        package let path: String
        package let interface: String
        package let member: String
        package let arguments: [DBusValue]
    }

    // MARK: - reading a message

    private static func readArguments(of message: OpaquePointer) -> [DBusValue] {
        var iterator = DBusMessageIter()
        guard dbus_message_iter_init(message, &iterator) != 0 else { return [] }
        var arguments: [DBusValue] = []
        while dbus_message_iter_get_arg_type(&iterator) != Kind.invalid {
            arguments.append(read(&iterator))
            dbus_message_iter_next(&iterator)
        }
        return arguments
    }

    /// One value at the iterator's current position, recursing into containers.
    private static func read(_ iterator: inout DBusMessageIter) -> DBusValue {
        switch dbus_message_iter_get_arg_type(&iterator) {
        case Kind.string, Kind.objectPath, Kind.signature:
            var pointer: UnsafePointer<CChar>?
            dbus_message_iter_get_basic(&iterator, &pointer)
            return .string(pointer.map { String(cString: $0) } ?? "")
        case Kind.boolean:
            var value = dbus_bool_t(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .boolean(value != 0)
        case Kind.byte:
            var value = UInt8(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .byte(value)
        case Kind.int16:
            var value = Int16(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .integer(Int64(value))
        case Kind.uint16:
            var value = UInt16(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .integer(Int64(value))
        case Kind.int32:
            var value = Int32(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .integer(Int64(value))
        case Kind.uint32:
            var value = UInt32(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .integer(Int64(value))
        case Kind.int64:
            var value = Int64(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .integer(value)
        case Kind.uint64:
            var value = UInt64(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .integer(Int64(bitPattern: value))
        case Kind.double:
            var value = Double(0)
            dbus_message_iter_get_basic(&iterator, &value)
            return .double(value)
        case Kind.variant:
            var inner = DBusMessageIter()
            dbus_message_iter_recurse(&iterator, &inner)
            return read(&inner)
        case Kind.array:
            return readArray(&iterator)
        case Kind.structure, Kind.dictEntry:
            var inner = DBusMessageIter()
            dbus_message_iter_recurse(&iterator, &inner)
            var members: [DBusValue] = []
            while dbus_message_iter_get_arg_type(&inner) != Kind.invalid {
                members.append(read(&inner))
                dbus_message_iter_next(&inner)
            }
            return .structure(members)
        default:
            return .unsupported
        }
    }

    /// **An array of bytes is `.bytes`, and an array of dict entries is `.dictionary`.** Both matter: a
    /// characteristic's value arrives as `ay` and is the whole reason this layer exists, and every BlueZ
    /// property bag is `a{sv}`. Anything else is a plain `.array`.
    private static func readArray(_ iterator: inout DBusMessageIter) -> DBusValue {
        let element = dbus_message_iter_get_element_type(&iterator)
        var inner = DBusMessageIter()
        dbus_message_iter_recurse(&iterator, &inner)

        if element == Kind.byte {
            var bytes: [UInt8] = []
            while dbus_message_iter_get_arg_type(&inner) == Kind.byte {
                var value = UInt8(0)
                dbus_message_iter_get_basic(&inner, &value)
                bytes.append(value)
                dbus_message_iter_next(&inner)
            }
            return .bytes(bytes)
        }

        if element == Kind.dictEntry {
            var entries: [String: DBusValue] = [:]
            while dbus_message_iter_get_arg_type(&inner) == Kind.dictEntry {
                var entry = DBusMessageIter()
                dbus_message_iter_recurse(&inner, &entry)
                let key = read(&entry)
                dbus_message_iter_next(&entry)
                let value = read(&entry)
                if case let .string(name) = key {
                    entries[name] = value
                }
                dbus_message_iter_next(&inner)
            }
            return .dictionary(entries)
        }

        var members: [DBusValue] = []
        while dbus_message_iter_get_arg_type(&inner) != Kind.invalid {
            members.append(read(&inner))
            dbus_message_iter_next(&inner)
        }
        return .array(members)
    }

    // MARK: - writing a message

    /// Appends one argument, with the signature D-Bus needs for a container.
    ///
    /// **Only the shapes this app sends**, which is the whole of what BlueZ is asked for: strings and
    /// object paths for the property calls, a byte array for `WriteValue`, an options dictionary that is
    /// almost always empty, and a variant for `Set`. Anything else is a programming error rather than a
    /// runtime one, so it throws where it would otherwise send something malformed.
    private static func append(_ value: DBusValue, to iterator: inout DBusMessageIter) throws {
        switch value {
        case let .string(text):
            try text.withCString { pointer in
                var pointer = Optional(pointer)
                guard dbus_message_iter_append_basic(&iterator, Kind.string, &pointer) != 0 else {
                    throw Failure.unexpectedReply("a string argument would not append")
                }
            }
        case let .objectPath(path):
            try path.withCString { pointer in
                var pointer = Optional(pointer)
                guard dbus_message_iter_append_basic(&iterator, Kind.objectPath, &pointer) != 0 else {
                    throw Failure.unexpectedReply("an object path argument would not append")
                }
            }
        case let .boolean(flag):
            var raw = dbus_bool_t(flag ? 1 : 0)
            guard dbus_message_iter_append_basic(&iterator, Kind.boolean, &raw) != 0 else {
                throw Failure.unexpectedReply("a boolean argument would not append")
            }
        case let .byte(raw):
            var raw = raw
            guard dbus_message_iter_append_basic(&iterator, Kind.byte, &raw) != 0 else {
                throw Failure.unexpectedReply("a byte argument would not append")
            }
        case let .integer(number):
            var raw = UInt16(truncatingIfNeeded: number)
            guard dbus_message_iter_append_basic(&iterator, Kind.uint16, &raw) != 0 else {
                throw Failure.unexpectedReply("a number argument would not append")
            }
        case let .bytes(bytes):
            var array = DBusMessageIter()
            guard dbus_message_iter_open_container(&iterator, Kind.array, "y", &array) != 0 else {
                throw Failure.unexpectedReply("a byte array would not open")
            }
            for byte in bytes {
                var raw = byte
                dbus_message_iter_append_basic(&array, Kind.byte, &raw)
            }
            dbus_message_iter_close_container(&iterator, &array)
        case let .dictionary(entries):
            var array = DBusMessageIter()
            guard dbus_message_iter_open_container(&iterator, Kind.array, "{sv}", &array) != 0 else {
                throw Failure.unexpectedReply("an options dictionary would not open")
            }
            for (key, item) in entries.sorted(by: { $0.key < $1.key }) {
                var entry = DBusMessageIter()
                dbus_message_iter_open_container(&array, Kind.dictEntry, nil, &entry)
                try append(.string(key), to: &entry)
                var variant = DBusMessageIter()
                dbus_message_iter_open_container(&entry, Kind.variant, item.signature, &variant)
                try append(item, to: &variant)
                dbus_message_iter_close_container(&entry, &variant)
                dbus_message_iter_close_container(&array, &entry)
            }
            dbus_message_iter_close_container(&iterator, &array)
        case let .variant(inner):
            var variant = DBusMessageIter()
            dbus_message_iter_open_container(&iterator, Kind.variant, inner.signature, &variant)
            try append(inner, to: &variant)
            dbus_message_iter_close_container(&iterator, &variant)
        case .double, .array, .structure, .unsupported:
            throw Failure.unexpectedReply("nothing this app sends is shaped like \(value)")
        }
    }

    /// A `char *` libdbus may hand back as null.
    private static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }
}
#endif
